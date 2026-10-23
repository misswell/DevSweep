import Foundation
import XCTest
@testable import DevSweep

/// 分布图状态：快照缓存、搜索不重扫、下钻形成的环形图层。
@MainActor
final class StorageDiscoveryStoreTests: XCTestCase {
    private let fileManager = FileManager.default
    private var suiteNames: [String] = []

    override func tearDown() {
        for name in suiteNames {
            UserDefaults.standard.removePersistentDomain(forName: name)
        }
        suiteNames = []
        super.tearDown()
    }

    func testScanBuildsSnapshotAndCachesLayerNodes() throws {
        let root = try temporaryDirectory(fileNames: (0..<6).map { "file-\($0).bin" })
        defer { try? fileManager.removeItem(at: root) }
        let store = makeStore()

        store.scan(directory: root)
        XCTAssertTrue(waitUntil { !store.isScanning && store.report != nil }, "扫描应在超时前完成")

        let report = try XCTUnwrap(store.report)
        XCTAssertEqual(store.graphNodes.count, report.allNodes.count)
        XCTAssertEqual(store.graphSnapshot.grouping.items.count, report.allNodes.count)
        XCTAssertEqual(store.graphSnapshot.totalBytes, report.totalAllocatedBytes)
        XCTAssertTrue(store.graphLevels.isEmpty, "首个目录没有祖先圈")

        let first = store.graphNodes
        let second = store.graphNodes
        XCTAssertTrue(
            first.withUnsafeBufferPointer { $0.baseAddress } == second.withUnsafeBufferPointer { $0.baseAddress },
            "同一份扫描结果应复用缓存，不重复过滤拷贝"
        )
    }

    func testSearchRebuildsSnapshotWithoutRescanning() throws {
        let root = try temporaryDirectory(fileNames: ["alpha.bin", "beta.bin", "sub-alpha.bin"])
        defer { try? fileManager.removeItem(at: root) }
        let store = makeStore()
        store.scan(directory: root)
        XCTAssertTrue(waitUntil { !store.isScanning && store.report != nil })

        let scannedAt = try XCTUnwrap(store.report).scannedAt
        let key = store.graphKey
        store.searchText = "alpha"

        XCTAssertEqual(store.graphSnapshot.matchedCount, 2)
        XCTAssertEqual(store.graphSnapshot.grouping.items.count, 2)
        XCTAssertEqual(store.graphKey, key, "搜索只改快照，不重扫")
        XCTAssertEqual(store.report?.scannedAt, scannedAt)

        store.searchText = ""
        XCTAssertEqual(store.graphSnapshot.matchedCount, 3)
    }

    func testIgnoreRemovesNodeFromChartAndKeepsItRecoverable() throws {
        let root = try temporaryDirectory(fileNames: ["one.bin", "two.bin"])
        defer { try? fileManager.removeItem(at: root) }
        let store = makeStore()
        store.scan(directory: root)
        XCTAssertTrue(waitUntil { !store.isScanning && store.report != nil })

        let node = try XCTUnwrap(store.graphNodes.first { $0.name == "one.bin" })
        store.ignore(node)
        XCTAssertEqual(store.graphSnapshot.items.count, 1)
        XCTAssertFalse(store.graphNodes.contains { $0.id == node.id })

        store.restoreIgnoredPath(node.id)
        XCTAssertEqual(store.graphSnapshot.items.count, 2)
    }

    /// 下钻把离开的层压成一圈；跳回祖先或跳到别的分支时截断，
    /// 保证内圈角度与当前层来自同一份测量，不出现父子重复累计。
    func testDrillDownBuildsAncestorRingsAndJumpBackTruncates() throws {
        let root = try temporaryDirectory(fileNames: ["a.bin", "b.bin", "c.bin"])
        defer { try? fileManager.removeItem(at: root) }
        let child = root.appendingPathComponent("child")
        let grand = child.appendingPathComponent("grand")
        let other = root.appendingPathComponent("other")
        let unrelated = try temporaryDirectory(fileNames: ["stray.bin"])
        try fileManager.createDirectory(at: grand, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: other, withIntermediateDirectories: true)
        try Data(repeating: 0x5A, count: 60_000).write(to: grand.appendingPathComponent("deep.bin"))
        try Data(repeating: 0x5A, count: 30_000).write(to: other.appendingPathComponent("loose.bin"))
        defer { try? fileManager.removeItem(at: unrelated) }
        let store = makeStore()

        store.scan(directory: root)
        XCTAssertTrue(waitUntil { !store.isScanning && store.report != nil })
        let rootLayerItems = store.graphSnapshot.grouping.items.count
        XCTAssertGreaterThan(rootLayerItems, 1)

        store.scan(directory: child)
        XCTAssertTrue(waitUntil { !store.isScanning && store.currentDirectory?.path == child.path })
        XCTAssertEqual(store.graphLevels.count, 1)
        XCTAssertEqual(store.graphLevels.first?.enteredID, child.standardizedFileURL.path, "圈里被展开的图块就是你点进去的目录")
        XCTAssertEqual(store.graphLevels.first?.items.count, rootLayerItems)

        store.scan(directory: grand)
        XCTAssertTrue(waitUntil { !store.isScanning && store.currentDirectory?.path == grand.path })
        XCTAssertEqual(store.graphLevels.map(\.enteredID), [
            child.standardizedFileURL.path,
            grand.standardizedFileURL.path
        ])

        store.scan(directory: child)
        XCTAssertTrue(waitUntil { !store.isScanning && store.currentDirectory?.path == child.path })
        XCTAssertEqual(store.graphLevels.count, 1, "回跳一层只保留到直接祖先")
        XCTAssertEqual(store.graphLevels.first?.enteredID, child.standardizedFileURL.path)

        store.scan(directory: root)
        XCTAssertTrue(waitUntil { !store.isScanning && store.currentDirectory?.path == root.path })
        XCTAssertTrue(store.graphLevels.isEmpty, "回到最初扫描的目录没有祖先圈")

        store.scan(directory: child)
        XCTAssertTrue(waitUntil { !store.isScanning && store.currentDirectory?.path == child.path })
        store.scan(directory: other)
        XCTAssertTrue(waitUntil { !store.isScanning && store.currentDirectory?.path == other.path })
        XCTAssertTrue(store.graphLevels.isEmpty, "离开的层不是兄弟目录的祖先，不能当成内圈")
        store.scan(directory: unrelated)
        XCTAssertTrue(waitUntil { !store.isScanning && store.currentDirectory?.path == unrelated.path })
        XCTAssertTrue(store.graphLevels.isEmpty, "跳到不相关的目录不能挂上旧内圈")
    }

    func testRecursiveScopeRunsRollupForCurrentDirectory() throws {
        let root = try temporaryDirectory(fileNames: ["one.bin", "two.bin"])
        defer { try? fileManager.removeItem(at: root) }
        let binary = root.appendingPathComponent("Nested.app/Contents/MacOS")
        try fileManager.createDirectory(at: binary, withIntermediateDirectories: true)
        try Data(repeating: 0x5A, count: 20_000).write(to: binary.appendingPathComponent("Bin"))
        let store = makeStore()
        store.scan(directory: root)
        XCTAssertTrue(waitUntil { !store.isScanning && store.report != nil })
        XCTAssertNil(store.rollup)

        store.graphTypeScope = .recursive
        XCTAssertTrue(waitUntil { !store.isRollupRunning && store.rollup != nil })
        let rollup = try XCTUnwrap(store.rollup)
        XCTAssertTrue(rollup.isComplete)
        XCTAssertEqual(rollup.packageCount, 1)
        XCTAssertEqual(rollup.summaries.first { $0.category == .package }?.itemCount, 1)

        store.graphTypeScope = .direct
        XCTAssertNil(store.rollup)
    }

    /// 下钻只移动图表根，不重扫文件系统；列表、类型统计与详情跟随同一份快照。
    func testChartNavigationUsesSnapshotWithoutRescanning() throws {
        let root = try temporaryDirectory(fileNames: ["a.bin"])
        defer { try? fileManager.removeItem(at: root) }
        let child = root.appendingPathComponent("child")
        let grand = child.appendingPathComponent("grand")
        try fileManager.createDirectory(at: grand, withIntermediateDirectories: true)
        try Data(repeating: 0x5A, count: 90_000).write(to: grand.appendingPathComponent("deep.bin"))
        try Data(repeating: 0x5A, count: 50_000).write(to: child.appendingPathComponent("mid.bin"))

        let store = makeStore()
        store.scan(directory: root)
        XCTAssertTrue(waitUntil { !store.isScanning && store.report != nil })
        let scannedAt = try XCTUnwrap(store.report).scannedAt
        let snapshot = try XCTUnwrap(store.treeSnapshot)
        XCTAssertEqual(store.chartRootIndex, snapshot.rootIndex)
        XCTAssertTrue(store.chartSnapshot.items.contains { $0.name == "child" })

        let childIndex = try XCTUnwrap(snapshot.index(ofPath: child.path))
        store.navigateChart(to: childIndex)
        XCTAssertEqual(store.chartRootIndex, childIndex)
        XCTAssertEqual(store.report?.scannedAt, scannedAt, "下钻不能重新扫描")
        XCTAssertEqual(Set(store.chartLayerNodes.map(\.name)), ["grand", "mid.bin"])
        XCTAssertEqual(store.chartRootPath, child.standardizedFileURL.path)
        XCTAssertTrue(store.canChartGoUp)

        let grandIndex = try XCTUnwrap(snapshot.index(ofPath: grand.path))
        store.navigateChart(to: grandIndex)
        XCTAssertEqual(Set(store.chartLayerNodes.map(\.name)), ["deep.bin"])

        store.chartGoUp()
        XCTAssertEqual(store.chartRootIndex, childIndex)
        store.chartGoBack()
        XCTAssertEqual(store.chartRootIndex, grandIndex)
        store.chartGoForward()
        XCTAssertEqual(store.chartRootIndex, childIndex)
        XCTAssertEqual(store.report?.scannedAt, scannedAt)
    }

    /// 树图快照保留低于列表阈值的条目，面积与合计才不会被阈值截断。
    func testChartSnapshotKeepsEntriesBelowListThreshold() throws {
        let root = try temporaryDirectory(fileNames: [])
        defer { try? fileManager.removeItem(at: root) }
        let child = root.appendingPathComponent("child")
        try fileManager.createDirectory(at: child, withIntermediateDirectories: true)
        try Data(repeating: 0x5A, count: 2_000_000).write(to: child.appendingPathComponent("big.bin"))
        try Data(repeating: 0x5A, count: 1_024).write(to: child.appendingPathComponent("small.bin"))

        let store = makeStore()
        // 阈值 1 MB：big.bin 保留在列表，small.bin 只出现在图表数据里。
        store.thresholdMB = 1
        store.scan(directory: root)
        XCTAssertTrue(waitUntil { !store.isScanning && store.report != nil })

        let snapshot = try XCTUnwrap(store.treeSnapshot)
        let childIndex = try XCTUnwrap(snapshot.index(ofPath: child.path))
        store.navigateChart(to: childIndex)

        XCTAssertEqual(store.chartLayerNodes.map(\.name), ["big.bin"], "列表按阈值过滤")
        XCTAssertEqual(Set(store.chartSnapshot.items.map(\.name)), ["big.bin", "small.bin"], "图表保留全部条目")
        XCTAssertEqual(store.chartSnapshot.totalBytes,
                       snapshot.children(of: childIndex).reduce(Int64(0)) { $0 + snapshot.records[Int($1)].allocatedBytes })
    }

    private func makeStore() -> StorageDiscoveryStore {
        let name = "DevSweepDiscoveryStore-\(UUID().uuidString)"
        suiteNames.append(name)
        let defaults = UserDefaults(suiteName: name)!
        // 列表阈值设 0，让小文件也进入本层条目，便于断言图表与列表一致。
        defaults.set(0, forKey: "DevSweep.discoveryThresholdMB")
        return StorageDiscoveryStore(defaults: defaults)
    }

    private func temporaryDirectory(fileNames: [String]) throws -> URL {
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("DevSweepStore-\(UUID().uuidString)")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        for name in fileNames {
            try Data(repeating: 0xA5, count: 40_000).write(to: root.appendingPathComponent(name))
        }
        return root
    }

    private func waitUntil(timeout: TimeInterval = 60, _ predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return predicate()
    }
}
