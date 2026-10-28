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
        selection.setItemIncluded(path: SelectionMemory.key(for: item.path), included: false)
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
}

/// 这些测试不触发任何进程调用；用一个永不返回结果的 runner 占位。
private struct NeverRunner: ProcessRunning, @unchecked Sendable {
    func run(executable: URL, arguments: [String], environment: [String: String]?, timeout: TimeInterval) -> ProcessResult? {
        nil
    }
}
