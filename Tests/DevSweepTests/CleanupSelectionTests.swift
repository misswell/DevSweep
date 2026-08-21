import XCTest
@testable import DevSweep

final class CleanupSelectionTests: XCTestCase {
    func testWhitelistMatchesThePathAndItsChildren() {
        let whitelist = [URL(fileURLWithPath: "/tmp/project/target")]

        XCTAssertTrue(PathWhitelist.contains(URL(fileURLWithPath: "/tmp/project/target"), in: whitelist))
        XCTAssertTrue(PathWhitelist.contains(URL(fileURLWithPath: "/tmp/project/target/debug"), in: whitelist))
        XCTAssertFalse(PathWhitelist.contains(URL(fileURLWithPath: "/tmp/project/target-copy"), in: whitelist))
    }

    func testWhitelistNormalizationRemovesNestedPaths() {
        let paths = PathWhitelist.normalized([
            URL(fileURLWithPath: "/tmp/project/target/debug"),
            URL(fileURLWithPath: "/tmp/project/target"),
            URL(fileURLWithPath: "/tmp/other")
        ])

        XCTAssertEqual(paths.map(\.path), ["/tmp/other", "/tmp/project/target"])
    }

    func testSelectionIsScopedToVisibleItems() {
        let currentPageItem = CacheItem(
            category: "Rust / Tauri 项目",
            name: "target",
            path: URL(fileURLWithPath: "/tmp/rust-target"),
            size: 1,
            risk: .review,
            isSelected: false
        )
        let itemSelectedOnAnotherPage = CacheItem(
            category: "Xcode",
            name: "DerivedData",
            path: URL(fileURLWithPath: "/tmp/derived-data"),
            size: 2,
            isSelected: true
        )

        let selected = CleanupSelection.selectedItems(
            from: [currentPageItem, itemSelectedOnAnotherPage],
            visibleItems: [currentPageItem]
        )

        XCTAssertTrue(selected.isEmpty)
    }

    func testSelectionIncludesOnlyVisibleSelectedItems() {
        let selectedCurrentPageItem = CacheItem(
            category: "Rust / Tauri 项目",
            name: "selected-target",
            path: URL(fileURLWithPath: "/tmp/selected-target"),
            size: 1,
            isSelected: true
        )
        let unselectedCurrentPageItem = CacheItem(
            category: "Rust / Tauri 项目",
            name: "unselected-target",
            path: URL(fileURLWithPath: "/tmp/unselected-target"),
            size: 2,
            isSelected: false
        )
        let selectedOtherPageItem = CacheItem(
            category: "Xcode",
            name: "selected-derived-data",
            path: URL(fileURLWithPath: "/tmp/selected-derived-data"),
            size: 3,
            isSelected: true
        )

        let selected = CleanupSelection.selectedItems(
            from: [selectedCurrentPageItem, unselectedCurrentPageItem, selectedOtherPageItem],
            visibleItems: [selectedCurrentPageItem, unselectedCurrentPageItem]
        )

        XCTAssertEqual(selected.map(\.id), [selectedCurrentPageItem.id])
    }

    func testManualItemsAreNeverCleanupCandidates() {
        let manualItem = CacheItem(
            category: "CoreSimulator",
            name: "booted-device",
            path: URL(fileURLWithPath: "/tmp/booted-device"),
            size: 1,
            risk: .manual,
            isSelected: true
        )

        let selected = CleanupSelection.selectedItems(
            from: [manualItem],
            visibleItems: [manualItem]
        )

        XCTAssertTrue(selected.isEmpty)
    }

    func testSelectionFollowsFilteredVisibleItems() {
        let visibleLargeItem = CacheItem(
            category: "Rust / Tauri 项目",
            name: "large-target",
            path: URL(fileURLWithPath: "/tmp/large-target"),
            size: 2,
            isSelected: true
        )
        let filteredOutSmallItem = CacheItem(
            category: "Rust / Tauri 项目",
            name: "small-target",
            path: URL(fileURLWithPath: "/tmp/small-target"),
            size: 1,
            isSelected: true
        )

        let selected = CleanupSelection.selectedItems(
            from: [visibleLargeItem, filteredOutSmallItem],
            visibleItems: [visibleLargeItem]
        )

        XCTAssertEqual(selected.map(\.id), [visibleLargeItem.id])
    }
}
