import CoreGraphics
import Darwin
import Foundation
import XCTest
@testable import DevSweep

/// 覆盖三处缺陷：树图后台布局的取消是否真正传进遍历、根为 "/" 时的路径拼接与前缀、
/// 扫描错误分支是否也会执行取消与节点上限检查。
final class TreeModelAndCancellationTests: XCTestCase {
    private let fileManager = FileManager.default

    // MARK: - P2-6 根为 "/" 的路径拼接与前缀

    func testRootSlashPathOfAndIndexRoundTrip() {
        let snapshot = makeSyntheticSnapshot(
            rootURL: URL(fileURLWithPath: "/"),
            children: [(name: "Users", files: ["guofeng"])]
        )

        XCTAssertEqual(snapshot.rootPathPrefix, "/")
        XCTAssertEqual(snapshot.path(of: 0), "/")
        XCTAssertEqual(snapshot.path(of: 1), "/Users")
        XCTAssertEqual(snapshot.path(of: 2), "/Users/guofeng")
        XCTAssertFalse(snapshot.path(of: 1).contains("//"), "根为 / 时不能拼出 //Users")
        XCTAssertFalse(snapshot.path(of: 2).contains("//"))

        XCTAssertEqual(snapshot.index(ofPath: "/"), 0)
        XCTAssertEqual(snapshot.index(ofPath: "/Users"), 1)
        XCTAssertEqual(snapshot.index(ofPath: "/Users/guofeng"), 2)
        XCTAssertEqual(snapshot.index(ofPath: "/Users/"), 1)
        XCTAssertNil(snapshot.index(ofPath: "/Users/nobody"))
        XCTAssertNil(snapshot.index(ofPath: "/Applications"))
    }

    func testRootSlashIndexResolvesBackwardsThroughChildren() {
        let snapshot = makeSyntheticSnapshot(
            rootURL: URL(fileURLWithPath: "/"),
            children: [
                (name: "Users", files: ["guofeng", "shared"]),
                (name: "Applications", files: ["Mail.app"])
            ]
        )

        XCTAssertEqual(snapshot.index(ofPath: "/Users/shared"), 4)
        XCTAssertEqual(snapshot.path(of: 4), "/Users/shared")
        XCTAssertEqual(snapshot.path(of: 5), "/Applications/Mail.app")
        XCTAssertEqual(snapshot.index(ofPath: "/Applications/Mail.app"), 5)
        XCTAssertEqual(snapshot.depth(of: 5), 2)
    }

    func testScannedPathsKeepSingleSeparatorAndRoundTrip() throws {
        let root = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: root) }
        let nested = root.appendingPathComponent("outer/inner")
        try fileManager.createDirectory(at: nested, withIntermediateDirectories: true)
        try writeFile(nested.appendingPathComponent("payload.bin"), bytes: 4_096)

        let snapshot = DiscoveryTreeScanEngine.scan(root: root)
        let filePath = nested.appendingPathComponent("payload.bin").standardizedFileURL.path
        let index = try XCTUnwrap(snapshot.index(ofPath: filePath))

        XCTAssertEqual(snapshot.path(of: index), filePath)
        XCTAssertFalse(snapshot.path(of: index).contains("//"))
        XCTAssertEqual(snapshot.path(of: snapshot.rootIndex), snapshot.standardizedRootPath)
        XCTAssertEqual(snapshot.rootPathPrefix, snapshot.standardizedRootPath + "/")
        XCTAssertEqual(snapshot.index(ofPath: snapshot.standardizedRootPath), snapshot.rootIndex)
        XCTAssertEqual(snapshot.index(ofPath: root.path), snapshot.rootIndex)
        XCTAssertNil(snapshot.index(ofPath: root.deletingLastPathComponent()
            .appendingPathComponent("DevSweep-not-a-child-\(UUID().uuidString)").path))
    }

    // MARK: - P2-5 布局取消

    func testLayoutTraversalStopsWhenCancellationIsRequested() {
        let snapshot = makeSyntheticSnapshot(
            rootURL: URL(fileURLWithPath: "/synthetic/root"),
            children: (0..<24).map { directory in
                (name: "dir-\(directory)", files: (0..<40).map { "file-\($0).bin" })
            }
        )

        let full = NestedTreemapLayout.segments(
            in: snapshot,
            rootIndex: 0,
            size: CGSize(width: 900, height: 600)
        )
        XCTAssertGreaterThan(full.segments.count, 500, "合成快照应产生足够多的图块")

        var checks = 0
        let stopped = NestedTreemapLayout.segments(
            in: snapshot,
            rootIndex: 0,
            size: CGSize(width: 900, height: 600),
            isCancelled: {
                checks += 1
                return checks > 40
            }
        )

        XCTAssertGreaterThan(checks, 40)
        XCTAssertLessThan(stopped.segments.count, full.segments.count / 2, "取消后应在图块边界停下，而不是画完整棵树")
    }

    @MainActor
    func testModelCancelStopsInFlightLayoutAndFlagsIt() async throws {
        let snapshot = makeSyntheticSnapshot(
            rootURL: URL(fileURLWithPath: "/synthetic/root"),
            children: (0..<24).map { directory in
                (name: "dir-\(directory)", files: (0..<40).map { "file-\($0).bin" })
            }
        )
        let model = TreemapChartModel()
        model.requestLayout(
            snapshot: snapshot,
            rootIndex: 0,
            size: CGSize(width: 900, height: 600),
            parameters: NestedTreemapParameters(),
            classifier: DiscoveryClassifier(knownCacheLocations: [])
        )
        let cancellation = try XCTUnwrap(model.activeLayoutCancellation, "布局开始后应持有可取消标志")

        model.cancel()

        XCTAssertTrue(cancellation.isCancelled, "取消必须传进后台布局，而不只是丢弃结果")
        XCTAssertFalse(model.isLayoutRunning)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(model.renderedSegments.isEmpty)
        XCTAssertTrue(model.renderData.paints.isEmpty)
        XCTAssertEqual(model.layoutVersion, 0)
        XCTAssertNil(model.activeLayoutCancellation)
    }

    @MainActor
    func testSupersededRequestCancelsPreviousLayoutFlag() async throws {
        let snapshot = makeSyntheticSnapshot(
            rootURL: URL(fileURLWithPath: "/synthetic/root"),
            children: (0..<12).map { directory in
                (name: "dir-\(directory)", files: (0..<30).map { "file-\($0).bin" })
            }
        )
        let model = TreemapChartModel()
        let parameters = NestedTreemapParameters()
        let classifier = DiscoveryClassifier(knownCacheLocations: [])
        model.requestLayout(
            snapshot: snapshot,
            rootIndex: 0,
            size: CGSize(width: 400, height: 300),
            parameters: parameters,
            classifier: classifier
        )
        let first = try XCTUnwrap(model.activeLayoutCancellation)

        model.requestLayout(
            snapshot: snapshot,
            rootIndex: 0,
            size: CGSize(width: 900, height: 600),
            parameters: parameters,
            classifier: classifier
        )

        XCTAssertTrue(first.isCancelled, "新请求必须取消旧布局，旧布局不能继续算完")
        XCTAssertFalse(model.activeLayoutCancellation === first)

        try await waitForLayout(model)
        XCTAssertFalse(model.renderedSegments.isEmpty)
        let rootSegments = model.renderedSegments.filter { $0.depth == 0 }
        let covered = rootSegments.reduce(CGFloat(0)) { $0 + $1.rect.width * $1.rect.height }
        XCTAssertEqual(covered, 1, accuracy: 0.02, "只有最新一次请求的结果会被发布")
    }

    // MARK: - P2-8 扫描错误分支的取消与节点上限

    /// 目录可枚举但不可进入时，其子项都以 FTS_NS 返回，走错误分支。
    /// 取消必须在这些条目上同样生效，不能等 64 个正常条目才检查一次。
    func testScanCancelsPromptlyOnErrorDenseTree() throws {
        try XCTSkipIf(getuid() == 0, "root 会绕过目录权限，无法复现 FTS_NS")
        let root = try makeTemporaryDirectory()
        let blocked = root.appendingPathComponent("blocked")
        try fileManager.createDirectory(at: blocked, withIntermediateDirectories: true)
        for index in 0..<200 {
            try writeFile(blocked.appendingPathComponent("entry-\(index).bin"), bytes: 128)
        }
        try fileManager.setAttributes([.posixPermissions: 0o400], ofItemAtPath: blocked.path)
        defer {
            try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blocked.path)
            try? fileManager.removeItem(at: root)
        }

        var checks = 0
        let snapshot = DiscoveryTreeScanEngine.scan(root: root, options: .init(isCancelled: {
            checks += 1
            return checks > 3
        }))

        XCTAssertTrue(snapshot.wasCancelled, "错误分支不能绕过取消检查")
        XCTAssertGreaterThan(checks, 3)
        XCTAssertLessThanOrEqual(checks, 8)
        XCTAssertLessThan(snapshot.records.count, 20)
    }

    func testScanStopsAtNodeLimitOnErrorDenseTree() throws {
        try XCTSkipIf(getuid() == 0, "root 会绕过目录权限，无法复现 FTS_NS")
        let root = try makeTemporaryDirectory()
        let blocked = root.appendingPathComponent("blocked")
        try fileManager.createDirectory(at: blocked, withIntermediateDirectories: true)
        for index in 0..<300 {
            try writeFile(blocked.appendingPathComponent("entry-\(index).bin"), bytes: 128)
        }
        try fileManager.setAttributes([.posixPermissions: 0o400], ofItemAtPath: blocked.path)
        defer {
            try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blocked.path)
            try? fileManager.removeItem(at: root)
        }

        let snapshot = DiscoveryTreeScanEngine.scan(root: root, options: .init(nodeLimit: 5))

        XCTAssertTrue(snapshot.limitReached)
        XCTAssertLessThanOrEqual(snapshot.records.count, 6)
        XCTAssertLessThanOrEqual(snapshot.unreadableCount, 20, "达到节点上限后不应继续处理后续错误条目")
    }

    // MARK: - 辅助

    /// 构造一棵不依赖文件系统的合成快照：根 → 若干目录 → 每个目录若干文件。
    /// 记录的索引布局是「根、所有目录、按目录顺序排列的全部文件」。
    private func makeSyntheticSnapshot(
        rootURL: URL,
        children: [(name: String, files: [String])]
    ) -> DiscoveryTreeSnapshot {
        let directoryCount = children.count
        let totalFileCount = children.reduce(0) { $0 + $1.files.count }
        let rootName = rootURL.path == "/" ? "/" : rootURL.lastPathComponent

        var records: [DiscoveryTreeRecord] = [
            DiscoveryTreeRecord(
                name: rootName,
                parentIndex: -1,
                firstChildIndex: 0,
                childCount: Int32(directoryCount),
                allocatedBytes: Int64(totalFileCount) * 1_000,
                logicalBytes: Int64(totalFileCount) * 1_000,
                fileCount: Int32(totalFileCount),
                directoryCount: Int32(directoryCount),
                skippedCount: 0,
                isDirectory: true,
                isHidden: false,
                isCrossVolume: false,
                isSharedAllocationDeduplicated: false,
                modifiedAt: nil
            )
        ]

        var fileOffset = 0
        for child in children {
            records.append(DiscoveryTreeRecord(
                name: child.name,
                parentIndex: 0,
                firstChildIndex: Int32(directoryCount + fileOffset),
                childCount: Int32(child.files.count),
                allocatedBytes: Int64(child.files.count) * 1_000,
                logicalBytes: Int64(child.files.count) * 1_000,
                fileCount: Int32(child.files.count),
                directoryCount: 0,
                skippedCount: 0,
                isDirectory: true,
                isHidden: false,
                isCrossVolume: false,
                isSharedAllocationDeduplicated: false,
                modifiedAt: nil
            ))
            fileOffset += child.files.count
        }

        for (offset, child) in children.enumerated() {
            for name in child.files {
                records.append(DiscoveryTreeRecord(
                    name: name,
                    parentIndex: Int32(1 + offset),
                    firstChildIndex: 0,
                    childCount: 0,
                    allocatedBytes: 1_000,
                    logicalBytes: 1_000,
                    fileCount: 1,
                    directoryCount: 0,
                    skippedCount: 0,
                    isDirectory: false,
                    isHidden: false,
                    isCrossVolume: false,
                    isSharedAllocationDeduplicated: false,
                    modifiedAt: nil
                ))
            }
        }

        var childIndices: [Int32] = children.indices.map { Int32(1 + $0) }
        for offset in 0..<totalFileCount {
            childIndices.append(Int32(directoryCount + 1 + offset))
        }

        return DiscoveryTreeSnapshot(
            rootIndex: 0,
            records: records,
            childIndices: childIndices,
            rootURL: rootURL,
            scannedAt: Date(timeIntervalSince1970: 0),
            duration: 0,
            wasCancelled: false,
            limitReached: false,
            checkedCount: records.count,
            symlinkCount: 0,
            crossVolumeCount: 0,
            unreadableCount: 0,
            sharedDeduplicatedCount: 0,
            issues: []
        )
    }

    @MainActor
    private func waitForLayout(_ model: TreemapChartModel, timeout: TimeInterval = 20) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while model.isLayoutRunning && Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertFalse(model.isLayoutRunning, "布局应在超时前完成")
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = fileManager.temporaryDirectory
            .appendingPathComponent("DevSweepTreeModel-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeFile(_ url: URL, bytes: Int) throws {
        try Data(repeating: 0xA5, count: bytes).write(to: url)
    }
}
