import XCTest
@testable import DevSweep

@MainActor
final class CategorySortTests: XCTestCase {
    private var suiteName: String?

    override func tearDown() {
        if let suiteName {
            UserDefaults().removePersistentDomain(forName: suiteName)
            self.suiteName = nil
        }
        super.tearDown()
    }

    private func makeStore(items: [CacheItem]) -> DevSweepStore {
        let name = "DevSweepCategorySortTests-\(UUID().uuidString)"
        suiteName = name
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let store = DevSweepStore(
            defaults: defaults,
            home: URL(fileURLWithPath: "/tmp/devsweep-category-sort-none")
        )
        store.applyScanResult(ScanReport(
            scannedRoots: [],
            items: items,
            checkedPaths: 0,
            matchedPaths: items.count,
            skippedPaths: 0,
            permissionFailures: 0,
            incompleteMeasurements: 0,
            diagnostics: [],
            duration: 0
        ))
        return store
    }

    private func item(
        _ category: String,
        _ name: String,
        size: Int64,
        risk: RiskLevel
    ) -> CacheItem {
        CacheItem(
            category: category,
            name: name,
            path: URL(fileURLWithPath: "/tmp/devsweep-category-sort/\(category)/\(name)"),
            size: size,
            risk: risk
        )
    }

    func testCleanableCapacityExcludesManualItems() {
        let store = makeStore(items: [
            item("Xcode", "DerivedData", size: 1_000, risk: .safe),
            item("Xcode", "DeviceSupport", size: 9_000, risk: .manual),
            item("Docker", "Build Cache", size: 5_000, risk: .review),
            item("Docker", "Docker.raw", size: 100_000, risk: .manual),
        ])

        XCTAssertEqual(store.categorySize("Xcode"), 10_000)
        XCTAssertEqual(store.categoryCleanableSize("Xcode"), 1_000)
        XCTAssertEqual(store.categoryCleanableCount("Xcode"), 1)
        XCTAssertEqual(store.categoryCleanableSize("Docker"), 5_000)
        XCTAssertEqual(store.categoryCleanableCount("Docker"), 1)
    }

    func testCleanableOrderPutsLargestReclaimableCategoryFirst() {
        let store = makeStore(items: [
            item("Xcode", "DerivedData", size: 1_000, risk: .safe),
            item("Xcode", "DeviceSupport", size: 9_000, risk: .manual),
            item("Docker", "Build Cache", size: 5_000, risk: .review),
            item("Docker", "Docker.raw", size: 100_000, risk: .manual),
            item("IDE", "System Cache", size: 20_000, risk: .manual),
            item("应用缓存", "App Cache", size: 5_000, risk: .safe),
        ])

        XCTAssertEqual(
            store.categories(orderedBy: .cleanable),
            ["Docker", "应用缓存", "Xcode", "IDE"],
            "按可清理容量降序；同容量保持默认分类顺序，纯手动分类排最后"
        )
        XCTAssertEqual(
            store.categories(orderedBy: .standard),
            ["Xcode", "Docker", "IDE", "应用缓存"],
            "切换到默认顺序时恢复固定分类顺序"
        )
    }
}
