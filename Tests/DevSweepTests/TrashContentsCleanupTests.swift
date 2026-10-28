import Foundation
import XCTest
@testable import DevSweep

/// 「清空内容、保留目录」的清理语义。
///
/// 这是 `~/Library/Caches`、`~/Library/Logs`、`~/.Trash`、`~/Downloads` 唯一可接受的
/// 删除方式：目录本身必须留下，只把子项移入废纸篓；并且目录身份被换过就必须拒绝。
final class TrashContentsCleanupTests: XCTestCase {
    private let fileManager = FileManager.default

    /// 记录哪些路径被移入废纸篓，不做真实删除。
    private final class RecordingTrashExecutor: TrashExecuting, @unchecked Sendable {
        var trashed: [String] = []
        var failOn: Set<String> = []

        func trash(_ url: URL) throws {
            if failOn.contains(url.lastPathComponent) {
                throw NSError(domain: "test", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "模拟失败"])
            }
            trashed.append(url.standardizedFileURL.path)
        }
    }

    private func makeContentsItem(at url: URL) -> CacheItem {
        CacheItem(
            category: "应用缓存",
            name: url.lastPathComponent,
            path: url,
            size: 3,
            risk: .review,
            kind: .trashContents,
            note: "测试",
            statusTitle: "清空内容",
            isSelected: false
        ).withIdentity()
    }

    private func context(for paths: [URL], home: URL) -> DeletionContext {
        DeletionContext(
            whitelistedPaths: [],
            projectRoots: [],
            home: home,
            allowedPaths: paths
        )
    }

    func testTrashContentsKeepsDirectoryAndTrashesEachChild() throws {
        let home = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: home) }

        let caches = home.appendingPathComponent("Library/Caches")
        try fileManager.createDirectory(at: caches.appendingPathComponent("a"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: caches.appendingPathComponent("b"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: caches.appendingPathComponent("c.txt"))

        let executor = RecordingTrashExecutor()
        let item = makeContentsItem(at: caches)
        let report = CacheCleaner.clean(
            [item],
            context: context(for: [caches], home: home),
            trashExecutor: executor
        )

        XCTAssertTrue(report.failures.isEmpty, "\(report.failures)")
        XCTAssertEqual(report.removed.count, 1)
        XCTAssertTrue(fileManager.fileExists(atPath: caches.path), "目录本身必须保留")
        XCTAssertEqual(executor.trashed.count, 3, "三个子项都要进废纸篓")
        XCTAssertEqual(Set(executor.trashed.map { ($0 as NSString).lastPathComponent }),
                       ["a", "b", "c.txt"])
        // 目录本身绝不能被当成一个子项移走。
        XCTAssertFalse(executor.trashed.contains(caches.standardizedFileURL.path))
    }

    /// `~/Library/Caches` 里可能有指向别处的符号链接。清空时移走的必须是链接本身，
    /// 而不是链接目标；否则「清空一个缓存目录」会删到目录外的东西。
    func testTrashContentsTrashesSymlinkItselfNotItsTarget() throws {
        let home = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: home) }

        let caches = home.appendingPathComponent("Library/Caches")
        let realData = home.appendingPathComponent("Documents/precious")
        try fileManager.createDirectory(at: caches, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: realData, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: realData.appendingPathComponent("inside"), withIntermediateDirectories: true)
        let link = caches.appendingPathComponent("link-to-documents")
        try fileManager.createSymbolicLink(at: link, withDestinationURL: realData)

        let executor = RecordingTrashExecutor()
        let item = makeContentsItem(at: caches)
        let report = CacheCleaner.clean(
            [item], context: context(for: [caches], home: home), trashExecutor: executor
        )

        XCTAssertTrue(report.failures.isEmpty, "\(report.failures)")
        // 被移入废纸篓的是链接自身。
        XCTAssertEqual(executor.trashed.map { ($0 as NSString).lastPathComponent }, ["link-to-documents"])
        // 目标绝不能被当成子项。
        XCTAssertFalse(executor.trashed.contains { $0.contains("precious") })
        XCTAssertFalse(executor.trashed.contains { $0.contains("inside") })
    }

    func testTrashContentsRejectsItemWhoseIdentityChanged() throws {
        let home = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: home) }

        let caches = home.appendingPathComponent("Library/Caches")
        try fileManager.createDirectory(at: caches, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: caches.appendingPathComponent("c.txt"))

        var item = makeContentsItem(at: caches)
        // 模拟「扫描之后目录被替换」：拿一份不匹配的身份。
        item = item.replacingIdentity(
            FileIdentity(device: 0, inode: 1, kind: .directory)
        )

        let executor = RecordingTrashExecutor()
        let report = CacheCleaner.clean(
            [item],
            context: context(for: [caches], home: home),
            trashExecutor: executor
        )

        XCTAssertEqual(report.removed.count, 0)
        XCTAssertEqual(report.failures.count, 1)
        XCTAssertTrue(executor.trashed.isEmpty, "身份不符时一个子项都不能动")
        XCTAssertTrue(fileManager.fileExists(atPath: caches.path))
    }

    func testTrashContentsRefusesRegularFileTarget() throws {
        let home = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: home) }

        let file = home.appendingPathComponent("Downloads/installer.dmg")
        try fileManager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: file)

        // 等价于「用户把 ~/Downloads 当成本身就是个文件来清空」：必须拒绝。
        let item = CacheItem(
            category: "应用缓存", name: "installer.dmg", path: file, size: 1,
            risk: .review, kind: .trashContents, isSelected: false
        ).withIdentity()

        let executor = RecordingTrashExecutor()
        let report = CacheCleaner.clean(
            [item],
            context: context(for: [file], home: home),
            trashExecutor: executor
        )
        XCTAssertEqual(report.removed.count, 0)
        XCTAssertEqual(report.failures.count, 1)
        XCTAssertTrue(executor.trashed.isEmpty)
    }

    func testTrashContentsRespectsWhitelist() throws {
        let home = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: home) }

        let caches = home.appendingPathComponent("Library/Caches")
        try fileManager.createDirectory(at: caches.appendingPathComponent("a"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: caches.appendingPathComponent("c.txt"))

        let executor = RecordingTrashExecutor()
        let item = makeContentsItem(at: caches)
        let report = CacheCleaner.clean(
            [item],
            context: DeletionContext(
                whitelistedPaths: [caches],
                projectRoots: [],
                home: home,
                allowedPaths: [caches]
            ),
            trashExecutor: executor
        )
        XCTAssertEqual(report.removed.count, 0)
        XCTAssertEqual(report.failures.count, 1)
        XCTAssertTrue(executor.trashed.isEmpty)
    }

    private func temporaryDirectory() throws -> URL {
        let url = fileManager.temporaryDirectory
            .appendingPathComponent("DevSweepTrashContents-\(UUID().uuidString)")
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private extension CacheItem {
    /// 测试辅助：补上 `expectedFileIdentity`（真实扫描时由 makeItem 填入）。
    func withIdentity() -> CacheItem {
        CacheItem(
            category: category,
            name: name,
            path: path,
            size: size,
            sizeWarning: sizeWarning,
            details: details,
            risk: risk,
            kind: kind,
            identifier: identifier,
            toolAction: toolAction,
            expectedFileIdentity: FileIdentity.capture(path),
            note: note,
            statusTitle: statusTitle,
            isSelected: isSelected
        )
    }

    func replacingIdentity(_ identity: FileIdentity?) -> CacheItem {
        CacheItem(
            category: category,
            name: name,
            path: path,
            size: size,
            sizeWarning: sizeWarning,
            details: details,
            risk: risk,
            kind: kind,
            identifier: identifier,
            toolAction: toolAction,
            expectedFileIdentity: identity,
            note: note,
            statusTitle: statusTitle,
            isSelected: isSelected
        )
    }
}
