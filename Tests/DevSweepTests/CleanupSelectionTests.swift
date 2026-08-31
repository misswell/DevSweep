import XCTest
@testable import DevSweep

final class CleanupSelectionTests: XCTestCase {
    func testSelectionMemoryRestoresExplicitSelectionStates() {
        let selectedItem = CacheItem(
            category: "Xcode",
            name: "DerivedData",
            path: URL(fileURLWithPath: "/tmp/derived-data"),
            size: 1,
            isSelected: true
        )
        let unselectedItem = CacheItem(
            category: "Xcode",
            name: "ModuleCache",
            path: URL(fileURLWithPath: "/tmp/module-cache"),
            size: 1,
            isSelected: true
        )

        let restored = SelectionMemory.restore(
            [selectedItem, unselectedItem],
            from: [SelectionMemory.key(for: unselectedItem.path): false]
        )

        XCTAssertTrue(restored[0].isSelected)
        XCTAssertFalse(restored[1].isSelected)
    }

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

    func testExcludingWhitelistedItemsRemovesCoveredItemsOnly() {
        let parent = CacheItem(
            category: "Rust / Tauri 项目",
            name: "target",
            path: URL(fileURLWithPath: "/tmp/project/target"),
            size: 3,
            isSelected: true
        )
        let child = CacheItem(
            category: "Rust / Tauri 项目",
            name: "debug",
            path: URL(fileURLWithPath: "/tmp/project/target/debug"),
            size: 2,
            isSelected: false
        )
        let sibling = CacheItem(
            category: "Xcode",
            name: "DerivedData",
            path: URL(fileURLWithPath: "/tmp/project/DerivedData"),
            size: 1,
            isSelected: false
        )

        let remaining = CleanupSelection.excludingWhitelistedItems(
            from: [parent, child, sibling],
            whitelist: [parent.path]
        )

        XCTAssertEqual(remaining.map(\.id), [sibling.id])
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

    func testRemainingItemsRemovesOnlySuccessfullyCleanedItems() {
        let removedItem = CacheItem(
            category: "Xcode",
            name: "removed",
            path: URL(fileURLWithPath: "/tmp/removed"),
            size: 1
        )
        let failedItem = CacheItem(
            category: "Xcode",
            name: "failed",
            path: URL(fileURLWithPath: "/tmp/failed"),
            size: 2
        )
        let untouchedItem = CacheItem(
            category: "Node.js 项目",
            name: "untouched",
            path: URL(fileURLWithPath: "/tmp/untouched"),
            size: 3
        )

        let remaining = CleanupSelection.remainingItems(
            from: [removedItem, failedItem, untouchedItem],
            removing: [removedItem]
        )

        XCTAssertEqual(remaining.map(\.id), [failedItem.id, untouchedItem.id])
    }

    func testScannerDoesNotReturnOverlappingParentAndChildItems() {
        let parent = CacheItem(
            category: "其他开发缓存",
            name: "cache",
            path: URL(fileURLWithPath: "/tmp/devsweep-cache"),
            size: 100
        )
        let child = CacheItem(
            category: "Python 项目",
            name: "pip",
            path: URL(fileURLWithPath: "/tmp/devsweep-cache/pip"),
            size: 50
        )
        let sibling = CacheItem(
            category: "Xcode",
            name: "DerivedData",
            path: URL(fileURLWithPath: "/tmp/devsweep-derived-data"),
            size: 25
        )

        let normalized = CacheScanner.nonOverlappingItems([child, sibling, parent])

        XCTAssertEqual(normalized.map(\.path), [parent.path, sibling.path])
    }
}
