import Darwin
import Foundation
import XCTest
@testable import DevSweep

/// 层级扫描快照：一次遍历同时给出本层列表和多层树图所需的数据。
final class DiscoveryTreeScanTests: XCTestCase {
    private let fileManager = FileManager.default

    func testSnapshotBuildsFullHierarchyInOnePass() throws {
        let root = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: root) }
        let nested = root.appendingPathComponent("outer/inner")
        try fileManager.createDirectory(at: nested, withIntermediateDirectories: true)
        try writeFile(nested.appendingPathComponent("payload.bin"), bytes: 2_000_000)
        try writeFile(root.appendingPathComponent("loose.bin"), bytes: 1_000_000)

        let snapshot = DiscoveryTreeScanEngine.scan(root: root)

        XCTAssertEqual(snapshot.records[snapshot.rootIndex].childCount, 2)
        let names = snapshot.children(of: snapshot.rootIndex).map { snapshot.records[Int($0)].name }
        XCTAssertEqual(Set(names), ["outer", "loose.bin"])

        let outerPath = root.appendingPathComponent("outer").standardizedFileURL.path
        let outerIndex = try XCTUnwrap(snapshot.index(ofPath: outerPath))
        XCTAssertEqual(snapshot.records[outerIndex].childCount, 1)

        let innerPath = root.appendingPathComponent("outer/inner").standardizedFileURL.path
        let innerIndex = try XCTUnwrap(snapshot.index(ofPath: innerPath))
        XCTAssertEqual(snapshot.records[innerIndex].childCount, 1)
        XCTAssertEqual(snapshot.depth(of: innerIndex), 2)

        let payloadPath = nested.appendingPathComponent("payload.bin").standardizedFileURL.path
        let payloadIndex = try XCTUnwrap(snapshot.index(ofPath: payloadPath))
        XCTAssertEqual(snapshot.records[payloadIndex].name, "payload.bin")
        XCTAssertEqual(snapshot.path(of: payloadIndex), payloadPath)
    }

    /// 目录占用是子树汇总，不是每层重新跑一次 du；父目录和子目录不会被重复累计。
    func testDirectoryTotalsAreSubtreeSumsWithoutDoubleCounting() throws {
        let root = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: root) }
        let first = root.appendingPathComponent("a/deep")
        let second = root.appendingPathComponent("b")
        try fileManager.createDirectory(at: first, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: second, withIntermediateDirectories: true)
        try writeFile(first.appendingPathComponent("one.bin"), bytes: 3_000_000)
        try writeFile(second.appendingPathComponent("two.bin"), bytes: 1_000_000)

        let snapshot = DiscoveryTreeScanEngine.scan(root: root)

        let aIndex = try XCTUnwrap(snapshot.index(ofPath: root.appendingPathComponent("a").path))
        let deepIndex = try XCTUnwrap(snapshot.index(ofPath: first.path))
        let bIndex = try XCTUnwrap(snapshot.index(ofPath: second.path))
        let deepBytes = snapshot.records[deepIndex].allocatedBytes
        XCTAssertGreaterThanOrEqual(deepBytes, 3_000_000)
        XCTAssertEqual(snapshot.records[aIndex].allocatedBytes, deepBytes, "a 的合计只由子项汇总一次")
        let total = snapshot.records[aIndex].allocatedBytes + snapshot.records[bIndex].allocatedBytes
        XCTAssertEqual(snapshot.records[snapshot.rootIndex].allocatedBytes, total)
        XCTAssertGreaterThanOrEqual(total, 4_000_000)
    }

    func testSymbolicLinksAreNotFollowed() throws {
        let root = try makeTemporaryDirectory()
        let outside = try makeTemporaryDirectory()
        defer {
            try? fileManager.removeItem(at: root)
            try? fileManager.removeItem(at: outside)
        }
        try writeFile(outside.appendingPathComponent("secret.bin"), bytes: 1_500_000)
        try fileManager.createSymbolicLink(
            at: root.appendingPathComponent("escape"),
            withDestinationURL: outside
        )

        let snapshot = DiscoveryTreeScanEngine.scan(root: root)

        XCTAssertEqual(snapshot.symlinkCount, 1)
        XCTAssertNil(snapshot.index(ofPath: root.appendingPathComponent("escape").path))
        XCTAssertLessThan(snapshot.records[snapshot.rootIndex].allocatedBytes, 1_500_000)
    }

    func testHardLinksAreCountedOnceAcrossTheTree() throws {
        let root = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: root) }
        let original = root.appendingPathComponent("a/original.bin")
        let link = root.appendingPathComponent("b/link.bin")
        try fileManager.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writeFile(original, bytes: 2_000_000)
        try fileManager.linkItem(at: original, to: link)

        let snapshot = DiscoveryTreeScanEngine.scan(root: root)

        XCTAssertEqual(snapshot.sharedDeduplicatedCount, 1)
        XCTAssertLessThan(snapshot.records[snapshot.rootIndex].allocatedBytes, 3_500_000)
        let aIndex = try XCTUnwrap(snapshot.index(ofPath: root.appendingPathComponent("a").path))
        let bIndex = try XCTUnwrap(snapshot.index(ofPath: root.appendingPathComponent("b").path))
        let combined = snapshot.records[aIndex].allocatedBytes + snapshot.records[bIndex].allocatedBytes
        XCTAssertEqual(combined, snapshot.records[snapshot.rootIndex].allocatedBytes)
    }

    func testUnreadableSubtreePropagatesIncompleteState() throws {
        try XCTSkipIf(getuid() == 0, "root 会绕过目录权限，无法复现读取失败")
        let root = try makeTemporaryDirectory()
        let locked = root.appendingPathComponent("locked")
        defer {
            try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            try? fileManager.removeItem(at: root)
        }
        try fileManager.createDirectory(at: locked, withIntermediateDirectories: true)
        try writeFile(locked.appendingPathComponent("hidden.bin"), bytes: 1_000_000)
        try fileManager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)

        let snapshot = DiscoveryTreeScanEngine.scan(root: root)

        let index = try XCTUnwrap(snapshot.index(ofPath: locked.path))
        XCTAssertGreaterThan(snapshot.records[index].skippedCount, 0)
        XCTAssertGreaterThan(snapshot.records[snapshot.rootIndex].skippedCount, 0)
        let measurement = snapshot.measurement(at: snapshot.rootIndex)
        XCTAssertNotEqual(measurement.state, .complete)
        XCTAssertGreaterThan(snapshot.unreadableCount, 0)
        XCTAssertTrue(snapshot.issues.contains { $0.kind == .inaccessible })
    }

    func testCancellationKeepsPartialSnapshotAndStopsEarly() throws {
        let root = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: root) }
        for index in 0..<200 {
            try fileManager.createDirectory(
                at: root.appendingPathComponent("dir-\(index)"),
                withIntermediateDirectories: true
            )
            try writeFile(root.appendingPathComponent("dir-\(index)/file.bin"), bytes: 4_096)
        }

        var reads = 0
        let snapshot = DiscoveryTreeScanEngine.scan(root: root, options: .init(
            isCancelled: {
                reads += 1
                return reads > 2
            }
        ))

        XCTAssertTrue(snapshot.wasCancelled)
        XCTAssertLessThan(snapshot.records.count, 401)
        XCTAssertGreaterThanOrEqual(snapshot.records.count, 1)
    }

    func testNodeLimitStopsAndMarksResultIncomplete() throws {
        let root = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: root) }
        for index in 0..<40 {
            try writeFile(root.appendingPathComponent("file-\(index).bin"), bytes: 4_096)
        }

        let snapshot = DiscoveryTreeScanEngine.scan(root: root, options: .init(nodeLimit: 10))

        XCTAssertTrue(snapshot.limitReached)
        XCTAssertLessThanOrEqual(snapshot.records.count, 11)
        XCTAssertGreaterThan(snapshot.records[snapshot.rootIndex].skippedCount, 0)
    }

    /// 报告与本层列表必须来自同一份快照：列表里的占用等于树里对应节点的子树合计。
    func testReportDerivedFromSnapshotMatchesTreeTotals() throws {
        let root = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root.appendingPathComponent("alpha/nested"), withIntermediateDirectories: true)
        try writeFile(root.appendingPathComponent("alpha/nested/a.bin"), bytes: 2_500_000)
        try writeFile(root.appendingPathComponent("beta.bin"), bytes: 1_200_000)

        let snapshot = DiscoveryTreeScanEngine.scan(root: root)
        let report = UnknownStorageScanner.report(
            from: snapshot,
            directory: root,
            thresholdBytes: 0,
            classifier: DiscoveryClassifier(knownCacheLocations: [])
        )

        XCTAssertEqual(report.nodes.map(\.name).sorted(), ["alpha", "beta.bin"])
        XCTAssertEqual(report.treeSnapshot.version, snapshot.version)
        let alpha = try XCTUnwrap(report.nodes.first { $0.name == "alpha" })
        let alphaIndex = try XCTUnwrap(snapshot.index(ofPath: alpha.id))
        XCTAssertEqual(alpha.measurement.allocatedBytes, snapshot.records[alphaIndex].allocatedBytes)
        XCTAssertEqual(report.totalAllocatedBytes, snapshot.records[snapshot.rootIndex].allocatedBytes)
    }

    func testShallowClassificationMatchesFullClassificationForCommonPaths() throws {
        let home = fileManager.homeDirectoryForCurrentUser
        let classifier = DiscoveryClassifier(knownCacheLocations: [])
        let cases: [(String, Bool)] = [
            (home.appendingPathComponent("Library/Caches").path, true),
            (home.appendingPathComponent("Library/Caches/com.example.app").path, true),
            (home.appendingPathComponent("projects/app/node_modules").path, true),
            (home.appendingPathComponent("projects/app/src").path, true),
            ("/System/Library/CoreServices", true),
            (home.appendingPathComponent("Documents/notes").path, true)
        ]
        for (path, isDirectory) in cases {
            let full = classifier.classify(url: URL(fileURLWithPath: path), isDirectory: isDirectory).classification
            let shallow = classifier.classifyShallow(
                path: path,
                name: URL(fileURLWithPath: path).lastPathComponent,
                isDirectory: isDirectory
            )
            XCTAssertEqual(shallow, full, path)
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = fileManager.temporaryDirectory
            .appendingPathComponent("DevSweepTree-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeFile(_ url: URL, bytes: Int) throws {
        try Data(repeating: 0xA5, count: bytes).write(to: url)
    }
}
