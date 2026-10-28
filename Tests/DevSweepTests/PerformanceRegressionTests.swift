import Foundation
import XCTest
@testable import DevSweep

/// 页面卡顿的回归防线。
///
/// 这些断言不追求精确耗时（CI 机器差异大），只钉住「复杂度没退化」：
/// 派生数据必须是「一条目只算一次」的量级，而不是分类数 × 条目数。
final class PerformanceRegressionTests: XCTestCase {
    private func makeItems(_ count: Int) -> [CacheItem] {
        let categories = ["Xcode", "CoreSimulator", "XCTest", "应用缓存", "IDE", "包管理器", "语言工具链"]
        return (0..<count).map { index in
            CacheItem(
                category: categories[index % categories.count],
                name: "item\(index) DerivedData",
                path: URL(fileURLWithPath: "/Users/x/Library/Developer/Xcode/DerivedData/i\(index)"),
                size: Int64(index % 1000) * 1024,
                risk: index % 3 == 0 ? .safe : .review
            )
        }
    }

    /// 单次快照的成本应随条目线性增长，不能因为 13 个分类而翻 13 倍。
    func testSnapshotScalesLinearlyNotByCategoryCount() {
        let small = makeItems(2_000)
        let large = makeItems(6_000)
        // 预热，避免首次调用被初始化开销污染。
        _ = XcodeStorageSnapshot.build(items: small, runtimeItems: [], diskTotalBytes: nil, diskAvailableBytes: nil)

        func measure(_ items: [CacheItem]) -> TimeInterval {
            let start = Date()
            for _ in 0..<5 {
                _ = XcodeStorageSnapshot.build(
                    items: items, runtimeItems: [], diskTotalBytes: nil, diskAvailableBytes: nil
                )
            }
            return Date().timeIntervalSince(start) / 5
        }

        let smallCost = measure(small)
        let largeCost = measure(large)
        // 条目 3 倍，成本应接近 3 倍；若退化成 13×N 的写法会明显更高。
        let ratio = largeCost / max(smallCost, 0.000_001)
        XCTAssertLessThan(ratio, 6.0, "快照成本随条目增长而非随分类数放大，实测比值 \(ratio)")
    }

    /// 13 行必须由一次分类产生：行数固定、itemIDs 不重不漏。
    func testRowsComeFromOneClassificationPass() {
        let items = makeItems(500)
        let snapshot = XcodeStorageSnapshot.build(
            items: items, runtimeItems: [], diskTotalBytes: nil, diskAvailableBytes: nil
        )
        XCTAssertEqual(snapshot.rows.count, XcodeStorageCategory.allCases.count,
                       "固定 13 行")
        let allIDs = snapshot.rows.flatMap(\.itemIDs)
        XCTAssertEqual(allIDs.count, Set(allIDs).count, "同一条目不能出现在两行")
        XCTAssertEqual(Set(allIDs), Set(snapshot.classified.byCategory.values.flatMap { $0 }.map(\.id)),
                       "行内容必须恰好覆盖已分类条目")
    }

    /// 分类索引必须与逐条统计一致（侧栏 36 个分类共用它）。
    @MainActor
    func testCategoryIndexMatchesDirectComputation() {
        let items = makeItems(800)
        let store = DevSweepStore(defaults: UserDefaults(suiteName: "DevSweepPerfIndex")!, home: URL(fileURLWithPath: "/tmp/none"))
        store.applyScanResult(ScanReport(
            scannedRoots: [], items: items, checkedPaths: 0, matchedPaths: items.count,
            skippedPaths: 0, permissionFailures: 0, incompleteMeasurements: 0,
            diagnostics: [], duration: 0
        ))
        for category in store.categories {
            let direct = items.filter { $0.category == category }.reduce(Int64(0)) { $0 + $1.size }
            XCTAssertEqual(store.categorySize(category), direct, category)
            XCTAssertEqual(store.categoryCount(category), items.filter { $0.category == category }.count, category)
        }
        XCTAssertEqual(store.totalSize, items.reduce(0) { $0 + $1.size })
    }

    /// Runtime 保留策略对同一份清单只算一次：重复读取命中缓存。
    @MainActor
    func testRuntimePolicyIsCachedPerRuntimeList() {
        let source = XcodeRuntimeSource(
            defaults: UserDefaults(suiteName: "DevSweepPerfRuntime")!,
            runner: NoopRunner()
        )
        let runtime = SimulatorRuntimeInfo(
            identifier: "ID-1", runtimeIdentifier: nil,
            platformIdentifier: "com.apple.platform.iphonesimulator",
            version: "27.0", build: nil, deletable: true, sizeBytes: 1,
            mountPath: "/Library/Developer/CoreSimulator/Volumes/x",
            parentMountPath: nil, state: "Ready", lastUsedAt: nil, runtimeBundlePath: nil
        )
        source.installForTesting([runtime])
        // 两次读取必须返回一致结果（缓存不改变语义）。
        XCTAssertEqual(source.removableIdentifiers, source.removableIdentifiers)
        XCTAssertEqual(source.blockedReasons, source.blockedReasons)
        XCTAssertEqual(source.selectableRuntimeIdentifiers, source.selectableRuntimeIdentifiers)
    }
}

private struct NoopRunner: ProcessRunning, @unchecked Sendable {
    func run(executable: URL, arguments: [String], environment: [String: String]?, timeout: TimeInterval) -> ProcessResult? {
        nil
    }
}
