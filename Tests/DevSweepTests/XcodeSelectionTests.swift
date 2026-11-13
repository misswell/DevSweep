import Foundation
import XCTest
@testable import DevSweep

/// 「Xcode 空间」里两个曾经点不动的选择路径：
/// 1. 手动项（DeviceSupport 等）的复选框曾经被 `.disabled(risk == .manual)` 锁死，
///    但分类开关又把它算成「已包含」，用户看到勾着却取消不掉；
/// 2. Runtime 的勾选曾经要求「必须是比最新版本旧的版本」，于是每个平台只剩一个
///    版本时永远点不动。
@MainActor
final class XcodeSelectionTests: XCTestCase {
    private let defaultsSuite = "DevSweepXcodeSelectionTests"

    override func tearDown() {
        UserDefaults(suiteName: defaultsSuite)?.removePersistentDomain(forName: defaultsSuite)
        super.tearDown()
    }

    private func makeSelection() {
        UserDefaults(suiteName: defaultsSuite)?.removePersistentDomain(forName: defaultsSuite)
    }

    // MARK: - 手动项可取消

    func testManualItemCanBeExcludedFromThePlan() {
        makeSelection()
        var selection = XcodeStorageSelection(defaults: UserDefaults(suiteName: defaultsSuite)!)

        let item = CacheItem(
            category: "Xcode",
            name: "iOS DeviceSupport",
            path: URL(fileURLWithPath: "/tmp/devicesupport"),
            size: 100,
            risk: .manual,
            isSelected: false
        )
        let row = XcodeStorageRow(
            id: XcodeStorageClassifier.rowID(for: .deviceSupport),
            title: "iOS DeviceSupport",
            subtitle: "",
            risk: .manual,
            sizeBytes: 100,
            itemIDs: [item.id],
            runtimeIdentifiers: [],
            isGroup: true,
            allowsAutomaticClean: false
        )
        let category = XcodeStorageCategory.deviceSupport
        selection.setCategory(category, enabled: true)

        // 默认包含 → 计划里出现。
        var plan = XcodeCleanupPlan.make(
            items: [item], selection: selection, rows: [row],
            selectedRuntimeIdentifiers: [], runtimeBytesByIdentifier: [:]
        )
        XCTAssertEqual(plan.items.count, 1, "手动项被分类开关包含时应进入计划")

        // 用户显式取消 → 必须真的从计划里消失（这是曾经点不动的那个问题）。
        let key = SelectionMemory.key(for: item.path)
        selection.setItemSelected(false, path: key, in: category, siblings: [key])
        plan = XcodeCleanupPlan.make(
            items: [item], selection: selection, rows: [row],
            selectedRuntimeIdentifiers: [], runtimeBytesByIdentifier: [:]
        )
        XCTAssertTrue(plan.items.isEmpty, "取消勾选后必须不再进入计划")

        // 三态也要反映出来，而不是一直显示为「开」。
        let state = selection.categoryState(
            category, row: row, itemsByID: [item.id: item],
            runtimeSelectedCount: 0, runtimeSelectableCount: 0
        )
        XCTAssertEqual(state, .off, "取消全部子项后分类应显示为关")
    }

    // MARK: - 分类开关与子项复选框同步

    private func makeItem(
        _ name: String,
        path: String,
        size: Int64,
        risk: RiskLevel = .review
    ) -> CacheItem {
        CacheItem(
            category: "Xcode",
            name: name,
            path: URL(fileURLWithPath: path),
            size: size,
            risk: risk
        )
    }

    private func makeRow(_ category: XcodeStorageCategory, items: [CacheItem]) -> XcodeStorageRow {
        XcodeStorageRow(
            id: XcodeStorageClassifier.rowID(for: category),
            title: category.title,
            subtitle: category.subtitle,
            risk: category.risk,
            sizeBytes: items.reduce(0) { $0 + max(0, $1.size) },
            itemIDs: items.map(\.id),
            runtimeIdentifiers: [],
            isGroup: true,
            allowsAutomaticClean: category.allowsAutomaticClean
        )
    }

    /// 开关、复选框、清理计划必须始终是同一件事：用户看到的勾选 == 会被处理的条目。
    func testSwitchChildrenAndPlanStayInSync() {
        makeSelection()
        var selection = XcodeStorageSelection(defaults: UserDefaults(suiteName: defaultsSuite)!)
        let first = makeItem("First.xcarchive", path: "/tmp/DevSweep/First.xcarchive", size: 10)
        let second = makeItem("Second.xcarchive", path: "/tmp/DevSweep/Second.xcarchive", size: 20)
        let row = makeRow(.archives, items: [first, second])
        let itemsByID = [first.id: first, second.id: second]
        let keys = [SelectionMemory.key(for: first.path), SelectionMemory.key(for: second.path)]

        func state() -> XcodeCategorySelectionState {
            selection.categoryState(
                .archives, row: row, itemsByID: itemsByID,
                runtimeSelectedCount: 0, runtimeSelectableCount: 0
            )
        }
        func checkedCount() -> Int {
            keys.filter { selection.isItemSelected($0, in: .archives) }.count
        }
        func planCount() -> Int {
            XcodeCleanupPlan.make(
                items: [first, second], selection: selection, rows: [row],
                selectedRuntimeIdentifiers: [], runtimeBytesByIdentifier: [:]
            ).items.count
        }

        // 「归档」默认关闭：开关关、子项都不显示为已勾、计划为空。
        XCTAssertFalse(selection.isCategoryEnabled(.archives))
        XCTAssertEqual(state(), .off)
        XCTAssertEqual(checkedCount(), 0, "开关关着时子项不能显示为已勾")
        XCTAssertEqual(planCount(), 0, "显示为未勾的条目不能进入计划")

        // 打开开关 → 子项全部勾上，计划同步。
        selection.setCategory(.archives, enabled: true)
        selection.setAllItems(in: [.archives], included: true, rows: [row], itemsByID: itemsByID)
        XCTAssertEqual(state(), .on)
        XCTAssertEqual(checkedCount(), 2)
        XCTAssertEqual(planCount(), 2)

        // 取消一个 → 部分选中，计划只剩一个。
        selection.setItemSelected(false, path: keys[0], in: .archives, siblings: keys)
        XCTAssertEqual(state(), .mixed)
        XCTAssertEqual(checkedCount(), 1)
        XCTAssertEqual(planCount(), 1)

        // 再取消最后一个 → 开关必须回到关，计划为空（不能停在「开」）。
        selection.setItemSelected(false, path: keys[1], in: .archives, siblings: keys)
        XCTAssertEqual(state(), .off)
        XCTAssertEqual(checkedCount(), 0)
        XCTAssertEqual(planCount(), 0)
        XCTAssertFalse(selection.isCategoryEnabled(.archives), "全部取消后分类开关也要关掉")
    }

    /// 分类开关关着时直接点某个子项：只勾这一项，不能把同分类其它项一起带成勾选。
    func testCheckingOneChildOfDisabledCategoryChecksOnlyThatChild() {
        makeSelection()
        var selection = XcodeStorageSelection(defaults: UserDefaults(suiteName: defaultsSuite)!)
        let first = makeItem("First.xcarchive", path: "/tmp/DevSweep/First.xcarchive", size: 10)
        let second = makeItem("Second.xcarchive", path: "/tmp/DevSweep/Second.xcarchive", size: 20)
        let row = makeRow(.archives, items: [first, second])
        let keys = [SelectionMemory.key(for: first.path), SelectionMemory.key(for: second.path)]

        selection.setItemSelected(true, path: keys[0], in: .archives, siblings: keys)

        XCTAssertTrue(selection.isCategoryEnabled(.archives))
        XCTAssertTrue(selection.isItemSelected(keys[0], in: .archives))
        XCTAssertFalse(selection.isItemSelected(keys[1], in: .archives), "兄弟项不能被一起勾上")

        let plan = XcodeCleanupPlan.make(
            items: [first, second], selection: selection, rows: [row],
            selectedRuntimeIdentifiers: [], runtimeBytesByIdentifier: [:]
        )
        XCTAssertEqual(plan.items.map(\.id), [first.id], "计划里只能有用户勾的那一项")
        let state = selection.categoryState(
            .archives, row: row, itemsByID: [first.id: first, second.id: second],
            runtimeSelectedCount: 0, runtimeSelectableCount: 0
        )
        XCTAssertEqual(state, .mixed)
    }

    // MARK: - Runtime 开关只看可勾选集合

    /// 每平台最新版本会被保留策略挡下（可勾选数为 0），此时开关必须是关；
    /// 以前会回落到「Runtime 分类默认打开」，于是出现开关开、子项一个没勾。
    func testRuntimeSwitchStateUsesSelectableRuntimesOnly() {
        makeSelection()
        let selection = XcodeStorageSelection(defaults: UserDefaults(suiteName: defaultsSuite)!)
        let row = XcodeStorageRow(
            id: XcodeStorageClassifier.rowID(for: .runtimes),
            title: XcodeStorageCategory.runtimes.title,
            subtitle: XcodeStorageCategory.runtimes.subtitle,
            risk: .manual,
            sizeBytes: 8_000_000_000,
            itemIDs: [],
            runtimeIdentifiers: ["R1"],
            isGroup: true,
            allowsAutomaticClean: false
        )

        func state(selected: Int, selectable: Int) -> XcodeCategorySelectionState {
            selection.categoryState(
                .runtimes, row: row, itemsByID: [:],
                runtimeSelectedCount: selected, runtimeSelectableCount: selectable
            )
        }

        XCTAssertEqual(state(selected: 0, selectable: 0), .off, "没有可勾选的 Runtime 时开关必须关")
        XCTAssertEqual(state(selected: 0, selectable: 1), .off, "有可勾选但没勾时开关必须关")
        XCTAssertEqual(state(selected: 1, selectable: 1), .on)
        XCTAssertEqual(state(selected: 1, selectable: 2), .mixed)
    }

    // MARK: - Runtime 最新版本也可选

    func testNewestRuntimeIsSelectable() {
        let source = XcodeRuntimeSource(
            defaults: UserDefaults(suiteName: defaultsSuite)!,
            runner: NeverRunner()
        )
        // 只有一个 iOS 27.0（就是「本平台最新版本」）。以前永远选不中。
        let only = SimulatorRuntimeInfo(
            identifier: "C921E11F-A3CA-49B7-B19A-1B3250611292",
            runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-27-0",
            platformIdentifier: "com.apple.platform.iphonesimulator",
            version: "27.0",
            build: "24A5370g",
            deletable: true,
            sizeBytes: 8_000_000_000,
            mountPath: "/Library/Developer/CoreSimulator/Volumes/iOS_24A5370g",
            parentMountPath: "/System/Library/AssetsV2/x/AssetData",
            state: "Ready",
            lastUsedAt: nil,
            runtimeBundlePath: nil
        )
        source.installForTesting([only])

        XCTAssertTrue(source.selectableRuntimeIdentifiers.contains(only.identifier),
                      "平台唯一/最新版本必须可以被勾选")
        source.setRuntimeSelected(only.identifier, selected: true)
        XCTAssertEqual(source.selectedRuntimeIdentifiers, [only.identifier])
        XCTAssertEqual(source.takeDeletionIdentifiers(), [only.identifier])

        source.setRuntimeSelected(only.identifier, selected: false)
        XCTAssertTrue(source.selectedRuntimeIdentifiers.isEmpty)
    }

    func testRuntimeMarkedUndeletableStaysUnselectable() {
        let source = XcodeRuntimeSource(
            defaults: UserDefaults(suiteName: defaultsSuite)!,
            runner: NeverRunner()
        )
        let locked = SimulatorRuntimeInfo(
            identifier: "LOCKED-ID",
            runtimeIdentifier: nil,
            platformIdentifier: "com.apple.platform.iphonesimulator",
            version: "27.0",
            build: nil,
            deletable: false,
            sizeBytes: 1,
            mountPath: "/Library/Developer/CoreSimulator/Volumes/iOS_27",
            parentMountPath: nil,
            state: "Ready",
            lastUsedAt: nil,
            runtimeBundlePath: nil
        )
        source.installForTesting([locked])
        XCTAssertFalse(source.selectableRuntimeIdentifiers.contains(locked.identifier))
        source.setRuntimeSelected(locked.identifier, selected: true)
        XCTAssertTrue(source.selectedRuntimeIdentifiers.isEmpty, "simctl 标记不可移除的不能勾选")
    }

    /// 开关原本关着时直接点某一条 Runtime：只勾这一条，
    /// 不能把上次启动留下的其它勾选一起带出来。
    func testSelectOnlyRuntimeDropsEarlierSelections() {
        let source = XcodeRuntimeSource(
            defaults: UserDefaults(suiteName: defaultsSuite)!,
            runner: NeverRunner()
        )
        func runtime(_ identifier: String, version: String) -> SimulatorRuntimeInfo {
            SimulatorRuntimeInfo(
                identifier: identifier,
                runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-" + version.replacingOccurrences(of: ".", with: "-"),
                platformIdentifier: "com.apple.platform.iphonesimulator",
                version: version,
                build: nil,
                deletable: true,
                sizeBytes: 1_000_000,
                mountPath: "/Library/Developer/CoreSimulator/Volumes/\(identifier)",
                parentMountPath: nil,
                state: "Ready",
                lastUsedAt: nil,
                runtimeBundlePath: nil
            )
        }
        let older = runtime("OLD-RUNTIME", version: "26.4")
        let newest = runtime("NEW-RUNTIME", version: "27.0")
        source.installForTesting([older, newest])

        source.setAllRuntimesSelected(true)
        XCTAssertEqual(source.selectedRuntimeIdentifiers, ["OLD-RUNTIME", "NEW-RUNTIME"])

        source.selectOnlyRuntime("NEW-RUNTIME")
        XCTAssertEqual(source.selectedRuntimeIdentifiers, ["NEW-RUNTIME"])
    }
}

/// 这些测试不触发任何进程调用；用一个永不返回结果的 runner 占位。
private struct NeverRunner: ProcessRunning, @unchecked Sendable {
    func run(executable: URL, arguments: [String], environment: [String: String]?, timeout: TimeInterval) -> ProcessResult? {
        nil
    }
}
