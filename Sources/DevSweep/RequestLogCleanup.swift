import Foundation

/// Claude Code Router（CCR）把每个请求写进 `~/.claude-code-router/app-data`：
///
/// - `request-logs.sqlite`：日志行与路由 trace。SQLite 删除行之后不会自动缩小文件，
///   被删行的空间会长期停在空闲页里（实测可达数百 MB）；
/// - `request-log-bodies/`：按 UUID 前两位分片的请求/响应正文文件。CCR 内置保留策略
///   删行时会顺带删除对应文件，但历史残留和未被任何日志引用的文件会一直留在磁盘上。
///
/// DevSweep 不把这两个位置整体扔进废纸篓（那会连最近的日志一起清掉、并让请求日志界面
/// 失去排查依据），而是按统一的小时保留窗口在原地裁剪：删过期行、删过期正文、回收空闲页。
enum RequestLogPolicy {
    /// 默认只保留最近 24 小时的请求日志。
    static let defaultRetentionHours = 24
    static let relativeDataDirectory = ".claude-code-router/app-data"
    static let databaseName = "request-logs.sqlite"
    static let bodyDirectoryName = "request-log-bodies"

    /// 正文文件是 `<分片>/<UUID>`，分片目录名必须是文件名前两位。
    static let bodyNameLength = 36
}

/// 数据库与正文目录分开计数、分开执行，用户可以只处理其中一部分。
enum RequestLogTarget: String, CaseIterable {
    case database
    case bodies

    var displayName: String {
        switch self {
        case .database: return "Claude Code Router 请求日志库"
        case .bodies: return "Claude Code Router 过期请求正文"
        }
    }
}

struct RequestLogStore: Equatable {
    let dataDirectory: URL
    let databaseURL: URL
    let bodyDirectoryURL: URL

    init(dataDirectory: URL) {
        let standardized = dataDirectory.standardizedFileURL
        self.dataDirectory = standardized
        self.databaseURL = standardized.appendingPathComponent(RequestLogPolicy.databaseName)
        self.bodyDirectoryURL = standardized.appendingPathComponent(RequestLogPolicy.bodyDirectoryName)
    }

    /// 清理只允许发生在这个由 home 推导出来的标准位置；
    /// 扫描结果里的 path 不会被当作删除依据。
    static func standard(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> RequestLogStore {
        RequestLogStore(dataDirectory: home.appendingPathComponent(RequestLogPolicy.relativeDataDirectory))
    }

    var writeAheadLogURL: URL {
        URL(fileURLWithPath: databaseURL.path + "-wal")
    }

    func bodyFileURL(named name: String) -> URL {
        bodyDirectoryURL
            .appendingPathComponent(String(name.prefix(2)))
            .appendingPathComponent(name)
    }
}

enum RequestLogRetention {
    static func cutoff(hours: Int, now: Date) -> Date {
        now.addingTimeInterval(-Double(max(hours, 0)) * 3600)
    }

    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// `created_at` 以 `2026-09-17T10:36:47.610Z` 形式存储，定宽字符串可以直接比较。
    static func timestamp(_ date: Date) -> String {
        formatter.string(from: date)
    }

    static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }
}

struct RequestLogBodyFile {
    let url: URL
    let name: String
    let size: Int64
    let modifiedAt: Date
}

struct RequestLogInventory {
    var databaseExists = false
    var bodyDirectoryExists = false
    var isReadable = false
    var expiredRowCount = 0
    var expiredBodyNames: Set<String> = []
    var expiredBodyBytes: Int64 = 0
    var orphanBodyNames: [String] = []
    var orphanBodyBytes: Int64 = 0
    var freePageBytes: Int64 = 0
    var writeAheadLogBytes: Int64 = 0

    /// 清理数据库这一项能拿回的空间：空闲页 + WAL + 随过期行一起删除的正文。
    var databaseReclaimableBytes: Int64 {
        freePageBytes + writeAheadLogBytes + expiredBodyBytes
    }

    /// 正文目录里已经没有任何日志引用的过期文件。
    var bodiesReclaimableBytes: Int64 {
        orphanBodyBytes
    }

    var reclaimableBytes: Int64 {
        databaseReclaimableBytes + bodiesReclaimableBytes
    }
}

// MARK: - sqlite3 访问

protocol SQLiteCommandRunning {
    func run(database: URL, sql: String, readOnly: Bool, timeout: TimeInterval) -> ProcessResult?
}

struct SQLiteCommandRunner: SQLiteCommandRunning {
    static let executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")

    static var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: executableURL.path)
    }

    func run(database: URL, sql: String, readOnly: Bool, timeout: TimeInterval) -> ProcessResult? {
        guard Self.isAvailable else { return nil }
        let busyTimeoutSeconds = max(1, min(Int(timeout.rounded(.down)), 15))
        var arguments = ["-cmd", ".timeout \(busyTimeoutSeconds * 1000)"]
        if readOnly {
            arguments.insert("-readonly", at: 0)
        }
        arguments.append(database.path)
        arguments.append(sql)
        return ProcessRunner.run(
            executable: Self.executableURL,
            arguments: arguments,
            timeout: timeout
        )
    }
}

extension SQLiteCommandRunning {
    func scalar(
        _ sql: String,
        database: URL,
        readOnly: Bool = true,
        timeout: TimeInterval = 15
    ) -> Int64? {
        guard let result = run(database: database, sql: sql, readOnly: readOnly, timeout: timeout),
              !result.timedOut,
              result.status == 0,
              let text = String(data: result.stdout, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines)
        else { return nil }
        return Int64(text)
    }

    func lines(
        _ sql: String,
        database: URL,
        readOnly: Bool = true,
        timeout: TimeInterval = 15
    ) -> [String]? {
        guard let result = run(database: database, sql: sql, readOnly: readOnly, timeout: timeout),
              !result.timedOut,
              result.status == 0,
              let text = String(data: result.stdout, encoding: .utf8)
        else { return nil }
        return text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    func tables(database: URL, timeout: TimeInterval = 15) -> Set<String>? {
        guard let names = lines(
            "SELECT name FROM sqlite_master WHERE type = 'table';",
            database: database,
            timeout: timeout
        ) else { return nil }
        return Set(names)
    }
}

// MARK: - 扫描

struct RequestLogScanner {
    private let fileManager: FileManager
    private let sqlite: SQLiteCommandRunning

    init(
        fileManager: FileManager = .default,
        sqlite: SQLiteCommandRunning = SQLiteCommandRunner()
    ) {
        self.fileManager = fileManager
        self.sqlite = sqlite
    }

    func inventory(
        store: RequestLogStore,
        retentionHours: Int = RequestLogPolicy.defaultRetentionHours,
        now: Date = Date()
    ) -> RequestLogInventory {
        var inventory = RequestLogInventory()
        inventory.databaseExists = fileManager.fileExists(atPath: store.databaseURL.path)
        inventory.bodyDirectoryExists = fileManager.fileExists(atPath: store.bodyDirectoryURL.path)
        guard inventory.databaseExists, SQLiteCommandRunner.isAvailable else { return inventory }

        let cutoff = RequestLogRetention.cutoff(hours: retentionHours, now: now)
        let timestamp = RequestLogRetention.timestamp(cutoff)
        let database = store.databaseURL

        // 读不到库（被锁、损坏、权限不足）时不产出任何结论，避免按错误的数据去删文件。
        guard let expiredRowCount = sqlite.scalar(
            "SELECT COUNT(*) FROM request_logs WHERE created_at < '\(timestamp)';",
            database: database
        ),
        let expiredRefs = sqlite.lines(
            """
            SELECT request_body_ref FROM request_logs WHERE created_at < '\(timestamp)' AND request_body_ref <> ''
            UNION
            SELECT response_body_ref FROM request_logs WHERE created_at < '\(timestamp)' AND response_body_ref <> '';
            """,
            database: database
        ),
        let survivingRefs = sqlite.lines(
            """
            SELECT request_body_ref FROM request_logs WHERE created_at >= '\(timestamp)' AND request_body_ref <> ''
            UNION
            SELECT response_body_ref FROM request_logs WHERE created_at >= '\(timestamp)' AND response_body_ref <> '';
            """,
            database: database
        )
        else { return inventory }

        inventory.isReadable = true
        inventory.expiredRowCount = Int(expiredRowCount)

        if let freePages = sqlite.scalar("PRAGMA freelist_count;", database: database),
           let pageSize = sqlite.scalar("PRAGMA page_size;", database: database) {
            inventory.freePageBytes = freePages * pageSize
        }
        inventory.writeAheadLogBytes = allocatedSize(of: store.writeAheadLogURL)

        let expiredNames = Set(expiredRefs)
        let survivingNames = Set(survivingRefs)
        for file in bodyFiles(in: store.bodyDirectoryURL) {
            if expiredNames.contains(file.name) {
                inventory.expiredBodyNames.insert(file.name)
                inventory.expiredBodyBytes += file.size
                continue
            }
            guard !survivingNames.contains(file.name) else { continue }
            // 只处理早于保留窗口的文件，避免删掉刚写入、日志行还没落库的在途文件。
            guard file.modifiedAt < cutoff else { continue }
            inventory.orphanBodyNames.append(file.name)
            inventory.orphanBodyBytes += file.size
        }

        return inventory
    }

    /// 枚举 `<bodies>/<分片>/<UUID>`；只看分片目录下的普通文件，忽略符号链接和其他命名。
    func bodyFiles(in directory: URL) -> [RequestLogBodyFile] {
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .fileAllocatedSizeKey,
            .totalFileAllocatedSizeKey,
            .contentModificationDateKey
        ]
        guard let shards = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [RequestLogBodyFile] = []
        for shard in shards {
            guard let shardValues = try? shard.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  shardValues.isDirectory == true,
                  shardValues.isSymbolicLink != true,
                  let entries = try? fileManager.contentsOfDirectory(
                      at: shard,
                      includingPropertiesForKeys: keys,
                      options: [.skipsHiddenFiles]
                  )
            else { continue }

            for entry in entries {
                guard let values = try? entry.resourceValues(forKeys: Set(keys)),
                      values.isRegularFile == true,
                      values.isSymbolicLink != true
                else { continue }
                let name = entry.lastPathComponent
                guard RequestLogCleaner.isBodyFileName(name) else { continue }
                files.append(RequestLogBodyFile(
                    url: entry,
                    name: name,
                    size: allocatedBytes(values: values),
                    modifiedAt: values.contentModificationDate ?? .distantPast
                ))
            }
        }
        return files
    }

    private func allocatedSize(of url: URL) -> Int64 {
        guard let values = try? url.resourceValues(forKeys: [
            .fileSizeKey,
            .fileAllocatedSizeKey,
            .totalFileAllocatedSizeKey
        ]) else { return 0 }
        return allocatedBytes(values: values)
    }

    private func allocatedBytes(values: URLResourceValues) -> Int64 {
        if let allocated = values.totalFileAllocatedSize ?? values.fileAllocatedSize {
            return Int64(allocated)
        }
        return Int64(values.fileSize ?? 0)
    }
}

// MARK: - 清理

enum RequestLogCleanError: LocalizedError, Equatable {
    case sqliteUnavailable
    case databaseUnreadable
    case commandFailed(String)
    case missingTarget

    var errorDescription: String? {
        switch self {
        case .sqliteUnavailable:
            return "系统 sqlite3 不可用，无法安全裁剪请求日志"
        case .databaseUnreadable:
            return "无法读取请求日志数据库，已跳过清理"
        case .commandFailed(let message):
            return message.isEmpty ? "请求日志清理命令失败" : message
        case .missingTarget:
            return "缺少请求日志清理目标"
        }
    }
}

struct RequestLogTrimResult: Equatable {
    let deletedRowCount: Int
    let deletedFileCount: Int
    let reclaimedBytes: Int64
}

struct RequestLogCleaner {
    private let fileManager: FileManager
    private let sqlite: SQLiteCommandRunning
    private let scanner: RequestLogScanner

    init(
        fileManager: FileManager = .default,
        sqlite: SQLiteCommandRunning = SQLiteCommandRunner()
    ) {
        self.fileManager = fileManager
        self.sqlite = sqlite
        self.scanner = RequestLogScanner(fileManager: fileManager, sqlite: sqlite)
    }

    static func isBodyFileName(_ name: String) -> Bool {
        guard name.count == RequestLogPolicy.bodyNameLength else { return false }
        return name.allSatisfy { $0.isHexDigit || $0 == "-" }
    }

    /// 在保留窗口内不动的正文文件不会被删除；清理范围永远重新计算，不依赖扫描时的快照。
    func trim(
        target: RequestLogTarget,
        store: RequestLogStore,
        retentionHours: Int = RequestLogPolicy.defaultRetentionHours,
        now: Date = Date()
    ) throws -> RequestLogTrimResult {
        guard SQLiteCommandRunner.isAvailable else { throw RequestLogCleanError.sqliteUnavailable }

        let inventory = scanner.inventory(store: store, retentionHours: retentionHours, now: now)
        guard inventory.databaseExists, inventory.isReadable else {
            throw RequestLogCleanError.databaseUnreadable
        }

        switch target {
        case .bodies:
            let deleted = try deleteBodyFiles(named: inventory.orphanBodyNames, store: store)
            return RequestLogTrimResult(
                deletedRowCount: 0,
                deletedFileCount: deleted.count,
                reclaimedBytes: deleted.bytes
            )

        case .database:
            let sizeBefore = allocatedSize(of: store.databaseURL) + allocatedSize(of: store.writeAheadLogURL)
            try deleteExpiredRows(
                store: store,
                timestamp: RequestLogRetention.timestamp(
                    RequestLogRetention.cutoff(hours: retentionHours, now: now)
                ),
                milliseconds: RequestLogRetention.milliseconds(
                    RequestLogRetention.cutoff(hours: retentionHours, now: now)
                )
            )
            let deleted = try deleteBodyFiles(named: Array(inventory.expiredBodyNames), store: store)
            compactDatabase(store: store)
            let sizeAfter = allocatedSize(of: store.databaseURL) + allocatedSize(of: store.writeAheadLogURL)
            return RequestLogTrimResult(
                deletedRowCount: inventory.expiredRowCount,
                deletedFileCount: deleted.count,
                reclaimedBytes: max(0, sizeBefore - sizeAfter) + deleted.bytes
            )
        }
    }

    private func deleteExpiredRows(store: RequestLogStore, timestamp: String, milliseconds: Int64) throws {
        guard let tables = sqlite.tables(database: store.databaseURL) else {
            throw RequestLogCleanError.databaseUnreadable
        }

        var statements = ["PRAGMA foreign_keys = ON;", "BEGIN IMMEDIATE;"]
        statements.append("DELETE FROM request_logs WHERE created_at < '\(timestamp)';")
        if tables.contains("request_route_hops") {
            statements.append(
                "DELETE FROM request_route_hops WHERE request_log_id NOT IN (SELECT id FROM request_logs);"
            )
        }
        if tables.contains("request_route_traces") {
            statements.append(
                "DELETE FROM request_route_traces WHERE request_log_id NOT IN (SELECT id FROM request_logs);"
            )
        }
        if tables.contains("request_log_pending_updates") {
            statements.append("DELETE FROM request_log_pending_updates WHERE received_at < \(milliseconds);")
        }
        if tables.contains("request_log_raw_trace_events") {
            statements.append("DELETE FROM request_log_raw_trace_events WHERE processed_at < \(milliseconds);")
        }
        statements.append("COMMIT;")

        guard let result = sqlite.run(
            database: store.databaseURL,
            sql: statements.joined(separator: "\n"),
            readOnly: false,
            timeout: 120
        ) else {
            throw RequestLogCleanError.sqliteUnavailable
        }
        try validate(result, fallback: "删除过期请求日志失败")
    }

    /// VACUUM 需要写锁而且会重写整库；失败（例如路由器正持有写事务）不影响已经删掉的行和文件。
    private func compactDatabase(store: RequestLogStore) {
        guard let result = sqlite.run(
            database: store.databaseURL,
            sql: "VACUUM;",
            readOnly: false,
            timeout: 180
        ), !result.timedOut, result.status == 0 else { return }

        _ = sqlite.run(
            database: store.databaseURL,
            sql: "PRAGMA wal_checkpoint(TRUNCATE);",
            readOnly: false,
            timeout: 15
        )
    }

    private func deleteBodyFiles(
        named names: [String],
        store: RequestLogStore
    ) throws -> (count: Int, bytes: Int64) {
        guard !names.isEmpty else { return (0, 0) }
        let bodyDirectory = store.bodyDirectoryURL.standardizedFileURL
        let resolvedBodyDirectory = bodyDirectory.resolvingSymlinksInPath().standardizedFileURL
        var count = 0
        var bytes: Int64 = 0

        for name in Set(names).sorted() {
            // 只接受形如 UUID 的文件名，并且必须落在标准正文目录内。
            guard Self.isBodyFileName(name) else { continue }
            let candidate = store.bodyFileURL(named: name).standardizedFileURL
            let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
            guard resolved.path.hasPrefix(resolvedBodyDirectory.path + "/") else { continue }
            guard let values = try? candidate.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
                .fileAllocatedSizeKey,
                .totalFileAllocatedSizeKey
            ]), values.isRegularFile == true, values.isSymbolicLink != true else { continue }

            let size = Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0)
            do {
                try fileManager.removeItem(at: candidate)
                count += 1
                bytes += size
            } catch {
                throw RequestLogCleanError.commandFailed(
                    "删除 \(name) 失败：\(error.localizedDescription)"
                )
            }
        }
        return (count, bytes)
    }

    private func validate(_ result: ProcessResult, fallback: String) throws {
        if result.timedOut {
            throw RequestLogCleanError.commandFailed("\(fallback)：命令超时")
        }
        guard result.status == 0 else {
            let message = String(data: result.stderr, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw RequestLogCleanError.commandFailed(message.isEmpty ? fallback : message)
        }
    }

    private func allocatedSize(of url: URL) -> Int64 {
        guard let values = try? url.resourceValues(forKeys: [
            .fileSizeKey,
            .fileAllocatedSizeKey,
            .totalFileAllocatedSizeKey
        ]) else { return 0 }
        if let allocated = values.totalFileAllocatedSize ?? values.fileAllocatedSize {
            return Int64(allocated)
        }
        return Int64(values.fileSize ?? 0)
    }
}
