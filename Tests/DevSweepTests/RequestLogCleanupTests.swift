import Foundation
import XCTest
@testable import DevSweep

final class RequestLogCleanupTests: XCTestCase {
    private let fileManager = FileManager.default

    // MARK: - 扫描

    func testScanReportsRequestLogReclaimableSpace() throws {
        try requireSQLite3()
        let fixture = try makeFixture()
        defer { try? fileManager.removeItem(at: fixture.home) }

        let items = try scanRequestLogItems(at: fixture.home)

        XCTAssertEqual(items.count, 2, "应分别报告日志库与过期正文")

        let databaseItem = try XCTUnwrap(items.first { $0.identifier == RequestLogTarget.database.rawValue })
        XCTAssertEqual(databaseItem.category, "AI Agent")
        XCTAssertEqual(databaseItem.kind, .requestLogTrim)
        XCTAssertEqual(databaseItem.risk, .review)
        XCTAssertEqual(databaseItem.path.standardizedFileURL, fixture.store.databaseURL)
        XCTAssertTrue(databaseItem.kind.isNonRecoverable)
        // 数据库这一项要覆盖空闲页、WAL 和随过期行一起删除的正文
        XCTAssertGreaterThanOrEqual(databaseItem.size, fixture.expiredBodyBytes)
        XCTAssertTrue(databaseItem.details.contains("2 行 24 小时前的日志"), databaseItem.details)
        XCTAssertTrue(databaseItem.note.contains("VACUUM"), databaseItem.note)

        let bodiesItem = try XCTUnwrap(items.first { $0.identifier == RequestLogTarget.bodies.rawValue })
        XCTAssertEqual(bodiesItem.kind, .requestLogTrim)
        XCTAssertEqual(bodiesItem.risk, .review)
        XCTAssertEqual(normalizedPath(bodiesItem.path), normalizedPath(fixture.store.bodyDirectoryURL))
        XCTAssertEqual(bodiesItem.size, fixture.orphanBodyBytes)
        XCTAssertTrue(bodiesItem.details.contains("1 个已无日志引用"), bodiesItem.details)

        // 默认不勾选：日志属于需要确认的清理
        XCTAssertFalse(databaseItem.isSelected)
        XCTAssertFalse(bodiesItem.isSelected)
    }

    func testScanReportsFreePageBytesAfterRowsAreDeleted() throws {
        try requireSQLite3()
        let fixture = try makeFixture()
        defer { try? fileManager.removeItem(at: fixture.home) }

        let inventory = RequestLogScanner().inventory(store: fixture.store)
        XCTAssertTrue(inventory.isReadable)
        XCTAssertEqual(inventory.expiredRowCount, 2)
        XCTAssertGreaterThan(inventory.freePageBytes, 0, "填充行删除后应留下可回收的空闲页")
        XCTAssertEqual(inventory.expiredBodyBytes, fixture.expiredBodyBytes)
        XCTAssertEqual(inventory.orphanBodyBytes, fixture.orphanBodyBytes)
        XCTAssertEqual(inventory.orphanBodyNames.count, 1)
        XCTAssertTrue(inventory.databaseReclaimableBytes >= inventory.freePageBytes)
    }

    func testScanSkipsRequestLogsThatCannotBeRead() throws {
        let home = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: home) }
        let store = RequestLogStore.standard(home: home)
        try fileManager.createDirectory(at: store.dataDirectory, withIntermediateDirectories: true)
        try Data("not a database".utf8).write(to: store.databaseURL)

        let report = CacheScanner.scan(
            projectRoots: [],
            deepScan: false,
            home: home,
            includeSystemCaches: false,
            progress: { _ in },
            environment: [:]
        )

        XCTAssertTrue(report.items.filter { $0.kind == .requestLogTrim }.isEmpty)
        XCTAssertTrue(report.diagnostics.contains { $0.path == store.databaseURL.standardizedFileURL })
    }

    func testScanIgnoresMissingRequestLogStore() throws {
        let home = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: home) }

        let report = CacheScanner.scan(
            projectRoots: [],
            deepScan: false,
            home: home,
            includeSystemCaches: false,
            progress: { _ in },
            environment: [:]
        )
        XCTAssertTrue(report.items.filter { $0.kind == .requestLogTrim }.isEmpty)
    }

    // MARK: - 数据库裁剪

    func testDatabaseTrimDeletesExpiredRowsBodiesAndTraces() throws {
        try requireSQLite3()
        let fixture = try makeFixture()
        defer { try? fileManager.removeItem(at: fixture.home) }

        let result = try RequestLogCleaner().trim(target: .database, store: fixture.store)

        XCTAssertEqual(result.deletedRowCount, 2)
        XCTAssertEqual(result.deletedFileCount, 2, "两个过期正文文件应随行删除")
        XCTAssertGreaterThan(result.reclaimedBytes, 0)

        XCTAssertEqual(try remainingRowIDs(store: fixture.store), [3])
        XCTAssertFalse(fileManager.fileExists(atPath: fixture.expiredRequestBody.path))
        XCTAssertFalse(fileManager.fileExists(atPath: fixture.expiredResponseBody.path))
        // 未处理的过期残留正文不属于数据库这一项
        XCTAssertTrue(fileManager.fileExists(atPath: fixture.orphanBody.path))
        XCTAssertTrue(fileManager.fileExists(atPath: fixture.recentBody.path))

        XCTAssertEqual(try remainingRowIDs(table: "request_route_traces", store: fixture.store), [3])
        XCTAssertEqual(try remainingRowIDs(table: "request_route_hops", store: fixture.store), [3])
        XCTAssertEqual(try count("request_log_pending_updates", store: fixture.store), 1)
        XCTAssertEqual(try count("request_log_raw_trace_events", store: fixture.store), 1)
    }

    func testDatabaseTrimShrinksDatabaseFile() throws {
        try requireSQLite3()
        let fixture = try makeFixture()
        defer { try? fileManager.removeItem(at: fixture.home) }

        let before = try allocatedSize(of: fixture.store.databaseURL)
        _ = try RequestLogCleaner().trim(target: .database, store: fixture.store)
        let after = try allocatedSize(of: fixture.store.databaseURL)

        XCTAssertLessThan(after, before, "VACUUM 之后数据库文件应真正变小")
        let inventory = RequestLogScanner().inventory(store: fixture.store)
        XCTAssertEqual(inventory.expiredRowCount, 0)
    }

    // MARK: - 正文裁剪

    func testBodyTrimRemovesOnlyUnreferencedAgedFiles() throws {
        try requireSQLite3()
        let fixture = try makeFixture()
        defer { try? fileManager.removeItem(at: fixture.home) }

        let result = try RequestLogCleaner().trim(target: .bodies, store: fixture.store)

        XCTAssertEqual(result.deletedRowCount, 0, "正文这一项不删除日志行")
        XCTAssertEqual(result.deletedFileCount, 1)
        XCTAssertEqual(result.reclaimedBytes, fixture.orphanBodyBytes)

        XCTAssertFalse(fileManager.fileExists(atPath: fixture.orphanBody.path))
        XCTAssertTrue(fileManager.fileExists(atPath: fixture.recentBody.path))
        // 被过期行引用的正文只能随行删除，不能单独删掉而留下悬空引用
        XCTAssertTrue(fileManager.fileExists(atPath: fixture.expiredRequestBody.path))
        XCTAssertEqual(try remainingRowIDs(store: fixture.store), [1, 2, 3])
    }

    func testTrimIgnoresFilesOutsideUUIDNaming() throws {
        try requireSQLite3()
        let fixture = try makeFixture()
        defer { try? fileManager.removeItem(at: fixture.home) }

        let stray = fixture.store.bodyDirectoryURL.appendingPathComponent("ab/notes.txt")
        try fileManager.createDirectory(at: stray.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x5A, count: 1_200_000).write(to: stray)

        let inventory = RequestLogScanner().inventory(store: fixture.store)
        XCTAssertEqual(inventory.orphanBodyNames, [fixture.orphanBody.lastPathComponent])

        _ = try RequestLogCleaner().trim(target: .bodies, store: fixture.store)
        XCTAssertTrue(fileManager.fileExists(atPath: stray.path))
    }

    func testTrimRejectsMissingOrUnreadableDatabase() throws {
        try requireSQLite3()
        let home = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: home) }
        let store = RequestLogStore.standard(home: home)

        XCTAssertThrowsError(try RequestLogCleaner().trim(target: .database, store: store)) { error in
            XCTAssertEqual(error as? RequestLogCleanError, .databaseUnreadable)
        }

        try fileManager.createDirectory(at: store.dataDirectory, withIntermediateDirectories: true)
        try Data("not a database".utf8).write(to: store.databaseURL)
        XCTAssertThrowsError(try RequestLogCleaner().trim(target: .bodies, store: store)) { error in
            XCTAssertEqual(error as? RequestLogCleanError, .databaseUnreadable)
        }
    }

    // MARK: - 接入清理管线

    func testCleanerTrimsStoreDerivedFromContextHome() throws {
        try requireSQLite3()
        let fixture = try makeFixture()
        defer { try? fileManager.removeItem(at: fixture.home) }

        let decoy = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: decoy) }

        // item.path 指向别处也不能改变清理位置：范围只由 context.home 决定
        let item = CacheItem(
            category: "AI Agent",
            name: RequestLogTarget.database.displayName,
            path: decoy,
            size: 2_400_000,
            risk: .review,
            kind: .requestLogTrim,
            identifier: RequestLogTarget.database.rawValue
        )
        let context = DeletionContext(
            whitelistedPaths: [],
            projectRoots: [],
            home: fixture.home,
            allowedPaths: [decoy]
        )

        let report = CacheCleaner.clean([item], context: context)

        XCTAssertTrue(report.failures.isEmpty, "\(report.failures)")
        XCTAssertEqual(report.removed.count, 1)
        XCTAssertEqual(try remainingRowIDs(store: fixture.store), [3])
        XCTAssertTrue(fileManager.fileExists(atPath: decoy.path))
    }

    func testCleaningRejectsWhitelistedRequestLogItem() throws {
        try requireSQLite3()
        let fixture = try makeFixture()
        defer { try? fileManager.removeItem(at: fixture.home) }

        let item = CacheItem(
            category: "AI Agent",
            name: RequestLogTarget.database.displayName,
            path: fixture.store.databaseURL,
            size: 2_400_000,
            risk: .review,
            kind: .requestLogTrim,
            identifier: RequestLogTarget.database.rawValue
        )
        let context = DeletionContext(
            whitelistedPaths: [fixture.store.databaseURL],
            projectRoots: [],
            home: fixture.home,
            allowedPaths: [fixture.store.databaseURL]
        )

        let report = CacheCleaner.clean([item], context: context)

        XCTAssertTrue(report.removed.isEmpty)
        XCTAssertEqual(report.failures.count, 1)
        XCTAssertEqual(try remainingRowIDs(store: fixture.store), [1, 2, 3])
    }

    func testCleaningRequestLogItemWithoutTargetFails() throws {
        try requireSQLite3()
        let fixture = try makeFixture()
        defer { try? fileManager.removeItem(at: fixture.home) }

        let item = CacheItem(
            category: "AI Agent",
            name: "缺少标识",
            path: fixture.store.databaseURL,
            size: 2_400_000,
            risk: .review,
            kind: .requestLogTrim
        )
        let context = DeletionContext(
            whitelistedPaths: [],
            projectRoots: [],
            home: fixture.home,
            allowedPaths: [fixture.store.databaseURL]
        )

        let report = CacheCleaner.clean([item], context: context)
        XCTAssertTrue(report.removed.isEmpty)
        XCTAssertEqual(report.failures.first?.1, RequestLogCleanError.missingTarget.localizedDescription)
    }

    // MARK: - 选择策略

    func testBatchSelectionSkipsRequestLogTrim() {
        let item = CacheItem(
            category: "AI Agent",
            name: RequestLogTarget.bodies.displayName,
            path: URL(fileURLWithPath: "/tmp/request-log-bodies"),
            size: 10_000_000,
            risk: .review,
            kind: .requestLogTrim,
            identifier: RequestLogTarget.bodies.rawValue
        )
        XCTAssertFalse(CleanupSelection.isBatchSelectable(item))
        XCTAssertFalse(item.isSelected)
    }

    // MARK: - Fixture

    private struct Fixture {
        let home: URL
        let store: RequestLogStore
        let expiredRequestBody: URL
        let expiredResponseBody: URL
        let recentBody: URL
        let orphanBody: URL
        let expiredBodyBytes: Int64
        let orphanBodyBytes: Int64
    }

    private func makeFixture() throws -> Fixture {
        let home = try temporaryDirectory()
        let store = RequestLogStore.standard(home: home)
        try fileManager.createDirectory(at: store.bodyDirectoryURL, withIntermediateDirectories: true)

        let expiredRequestName = "11111111-1111-4111-8111-111111111111"
        let expiredResponseName = "22222222-2222-4222-8222-222222222222"
        let recentName = "33333333-3333-4333-8333-333333333333"
        let orphanName = "44444444-4444-4444-8444-444444444444"

        let expiredRequestBody = try createBodyFile(named: expiredRequestName, store: store)
        let expiredResponseBody = try createBodyFile(named: expiredResponseName, store: store)
        let recentBody = try createBodyFile(named: recentName, store: store)
        let orphanBody = try createBodyFile(named: orphanName, store: store)

        // 老文件的时间戳必须在保留窗口之外
        let oldDate = Date().addingTimeInterval(-48 * 3600)
        for url in [expiredRequestBody, expiredResponseBody, orphanBody] {
            try fileManager.setAttributes([.modificationDate: oldDate], ofItemAtPath: url.path)
        }

        let now = Date()
        let oldTimestamp = RequestLogRetention.timestamp(now.addingTimeInterval(-48 * 3600))
        let recentTimestamp = RequestLogRetention.timestamp(now.addingTimeInterval(-60))
        let oldMilliseconds = RequestLogRetention.milliseconds(now.addingTimeInterval(-48 * 3600))

        let padding = String(repeating: "x", count: 4096)
        var script = """
        PRAGMA journal_mode = WAL;
        CREATE TABLE request_logs (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            created_at TEXT NOT NULL,
            request_body_ref TEXT NOT NULL DEFAULT '',
            response_body_ref TEXT NOT NULL DEFAULT '',
            padding TEXT NOT NULL DEFAULT ''
        );
        CREATE TABLE request_route_traces (request_log_id INTEGER PRIMARY KEY, request_id TEXT NOT NULL DEFAULT '');
        CREATE TABLE request_route_hops (id INTEGER PRIMARY KEY AUTOINCREMENT, request_log_id INTEGER NOT NULL);
        CREATE TABLE request_log_pending_updates (request_id TEXT PRIMARY KEY, received_at INTEGER NOT NULL, update_bytes INTEGER NOT NULL DEFAULT 0, update_json TEXT NOT NULL DEFAULT '');
        CREATE TABLE request_log_raw_trace_events (bundle_id TEXT PRIMARY KEY, request_id TEXT NOT NULL, processed_at INTEGER NOT NULL);
        BEGIN;
        INSERT INTO request_logs (created_at, request_body_ref, response_body_ref)
            VALUES ('\(oldTimestamp)', '\(expiredRequestName)', '\(expiredResponseName)');
        INSERT INTO request_logs (created_at) VALUES ('\(oldTimestamp)');
        INSERT INTO request_logs (created_at, request_body_ref, response_body_ref)
            VALUES ('\(recentTimestamp)', '\(recentName)', '');
        INSERT INTO request_route_traces (request_log_id) VALUES (1), (3);
        INSERT INTO request_route_hops (request_log_id) VALUES (1), (3);
        INSERT INTO request_log_pending_updates (request_id, received_at) VALUES ('old', \(oldMilliseconds)), ('new', \(RequestLogRetention.milliseconds(now)));
        INSERT INTO request_log_raw_trace_events (bundle_id, request_id, processed_at) VALUES ('old', 'a', \(oldMilliseconds)), ('new', 'b', \(RequestLogRetention.milliseconds(now)));
        """
        // 先写入再删除一批填充行，制造真实的 SQLite 空闲页
        for index in 0..<200 {
            script += "\nINSERT INTO request_logs (created_at, padding) VALUES ('\(recentTimestamp)', '\(padding)\(index)');"
        }
        script += "\nDELETE FROM request_logs WHERE padding <> '';"
        script += "\nCOMMIT;"

        try runSQL(script, database: store.databaseURL)
        try fileManager.setAttributes([.modificationDate: oldDate], ofItemAtPath: store.databaseURL.path)

        return Fixture(
            home: home,
            store: store,
            expiredRequestBody: expiredRequestBody,
            expiredResponseBody: expiredResponseBody,
            recentBody: recentBody,
            orphanBody: orphanBody,
            expiredBodyBytes: try allocatedSize(of: expiredRequestBody) + allocatedSize(of: expiredResponseBody),
            orphanBodyBytes: try allocatedSize(of: orphanBody)
        )
    }

    private func scanRequestLogItems(at home: URL) throws -> [CacheItem] {
        let report = CacheScanner.scan(
            projectRoots: [],
            deepScan: false,
            home: home,
            includeSystemCaches: false,
            progress: { _ in },
            environment: [:]
        )
        return report.items.filter { $0.kind == .requestLogTrim }
    }

    // MARK: - Helpers

    private func requireSQLite3() throws {
        try XCTSkipUnless(SQLiteCommandRunner.isAvailable, "系统 sqlite3 不可用")
    }

    private func temporaryDirectory() throws -> URL {
        let url = fileManager.temporaryDirectory.appendingPathComponent("DevSweepRequestLog-\(UUID().uuidString)")
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 目录 URL 在 standardizedFileURL 之后可能带尾斜杠，比较时统一去掉。
    private func normalizedPath(_ url: URL) -> String {
        var path = url.standardizedFileURL.path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }

    private func createBodyFile(named name: String, store: RequestLogStore) throws -> URL {
        let url = store.bodyFileURL(named: name)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0xA5, count: 1_200_000).write(to: url)
        return url
    }

    private func runSQL(_ sql: String, database: URL) throws {
        let result = try XCTUnwrap(SQLiteCommandRunner().run(
            database: database,
            sql: sql,
            readOnly: false,
            timeout: 60
        ))
        XCTAssertEqual(
            result.status,
            0,
            String(data: result.stderr, encoding: .utf8) ?? "sqlite3 失败"
        )
    }

    private func remainingRowIDs(store: RequestLogStore) throws -> [Int] {
        try remainingRowIDs(table: "request_logs", column: "id", store: store)
    }

    private func remainingRowIDs(table: String, store: RequestLogStore) throws -> [Int] {
        try remainingRowIDs(table: table, column: "request_log_id", store: store)
    }

    private func remainingRowIDs(table: String, column: String, store: RequestLogStore) throws -> [Int] {
        let lines = try XCTUnwrap(SQLiteCommandRunner().lines(
            "SELECT \(column) FROM \(table) ORDER BY \(column);",
            database: store.databaseURL
        ))
        return lines.compactMap { Int($0) }
    }

    private func count(_ table: String, store: RequestLogStore) throws -> Int {
        let value = try XCTUnwrap(SQLiteCommandRunner().scalar(
            "SELECT COUNT(*) FROM \(table);",
            database: store.databaseURL
        ))
        return Int(value)
    }

    private func allocatedSize(of url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [
            .fileSizeKey,
            .fileAllocatedSizeKey,
            .totalFileAllocatedSizeKey
        ])
        if let allocated = values.totalFileAllocatedSize ?? values.fileAllocatedSize {
            return Int64(allocated)
        }
        return Int64(values.fileSize ?? 0)
    }
}
