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

    /// 勾选状态不受显示影响：送进来的清理范围里，当前没有显示出来的项目
    /// 仍然是清理候选，过滤器绝对不能偷偷改变清理范围。
    func testSelectionIsNotScopedToVisibleItems() {
        let visibleUnselectedItem = CacheItem(
            category: "Rust / Tauri 项目",
            name: "visible-target",
            path: URL(fileURLWithPath: "/tmp/visible-target"),
            size: 1,
            isSelected: false
        )
        let hiddenSelectedItem = CacheItem(
            category: "Xcode",
            name: "DerivedData",
            path: URL(fileURLWithPath: "/tmp/derived-data"),
            size: 2,
            isSelected: true
        )

        let selected = CleanupSelection.selectedItems(from: [visibleUnselectedItem, hiddenSelectedItem])

        XCTAssertEqual(selected.map(\.id), [hiddenSelectedItem.id])
    }

    func testSelectionIncludesOnlySelectedItems() {
        let selectedItem = CacheItem(
            category: "Rust / Tauri 项目",
            name: "selected-target",
            path: URL(fileURLWithPath: "/tmp/selected-target"),
            size: 1,
            isSelected: true
        )
        let unselectedItem = CacheItem(
            category: "Rust / Tauri 项目",
            name: "unselected-target",
            path: URL(fileURLWithPath: "/tmp/unselected-target"),
            size: 2,
            isSelected: false
        )

        let selected = CleanupSelection.selectedItems(from: [selectedItem, unselectedItem])

        XCTAssertEqual(selected.map(\.id), [selectedItem.id])
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

        let selected = CleanupSelection.selectedItems(from: [manualItem])

        XCTAssertTrue(selected.isEmpty)
    }

    /// 侧栏分类决定清理范围：分类页的清理候选只有该分类勾选的项目，
    /// 切换分类不改动其它分类的勾选（切走不等于取消勾选）。
    func testSidebarCategoryScopesCleanupCandidates() {
        let selectedXcodeItem = CacheItem(
            category: "Xcode",
            name: "DerivedData",
            path: URL(fileURLWithPath: "/tmp/xcode-derived-data"),
            size: 2,
            isSelected: true
        )
        let unselectedXcodeItem = CacheItem(
            category: "Xcode",
            name: "ModuleCache",
            path: URL(fileURLWithPath: "/tmp/xcode-module-cache"),
            size: 1,
            isSelected: false
        )
        let selectedNodeItem = CacheItem(
            category: "Node.js 项目",
            name: "node_modules",
            path: URL(fileURLWithPath: "/tmp/node-modules"),
            size: 3,
            isSelected: true
        )
        let items = [selectedXcodeItem, unselectedXcodeItem, selectedNodeItem]

        let inXcode = CleanupSelection.selectedItems(
            from: SidebarDestination.category("Xcode").items(from: items)
        )
        let inAll = CleanupSelection.selectedItems(
            from: SidebarDestination.all.items(from: items)
        )

        XCTAssertEqual(inXcode.map(\.id), [selectedXcodeItem.id], "分类页只显示并只清理本分类的勾选")
        XCTAssertEqual(inAll.map(\.id), [selectedXcodeItem.id, selectedNodeItem.id])
        XCTAssertEqual(items.map(\.isSelected), [true, false, true], "切换分类不改动其它分类的勾选")
    }

    /// 非列表页面（常用清理 / 白名单 / 后台进程）没有缓存清理范围。
    func testNonListDestinationsHaveNoCacheScope() {
        let item = CacheItem(
            category: "Xcode",
            name: "DerivedData",
            path: URL(fileURLWithPath: "/tmp/xcode-derived-data"),
            size: 1,
            isSelected: true
        )

        for destination in [SidebarDestination.quickClean, .whitelist, .backgroundProcesses] {
            XCTAssertTrue(destination.items(from: [item]).isEmpty, "\(destination) 不应有缓存清理范围")
        }
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
