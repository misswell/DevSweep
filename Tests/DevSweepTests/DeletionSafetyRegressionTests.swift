import Foundation
import XCTest
@testable import DevSweep

/// 外部审查发现的三个「安全边界」缺陷的回归测试。
///
/// 这套断言比功能测试更重要：清理工具的核心价值是不会删错东西。
final class DeletionSafetyRegressionTests: XCTestCase {
    private let fileManager = FileManager.default

    private func makeHome() throws -> URL {
        let url = fileManager.temporaryDirectory
            .appendingPathComponent("DevSweepSafety-\(UUID().uuidString)")
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        // 造出默认保护名单里出现的那些目录。
        for relative in ["Documents", "Downloads", "Library/Caches", "Library/Logs", ".Trash"] {
            try fileManager.createDirectory(
                at: url.appendingPathComponent(relative), withIntermediateDirectories: true
            )
        }
        return url
    }

    private func item(_ url: URL, kind: CleanupKind = .trash) -> CacheItem {
        CacheItem(category: "测试", name: url.lastPathComponent, path: url, size: 1,
                  risk: .safe, kind: kind, expectedFileIdentity: FileIdentity.capture(url))
    }

    // MARK: P1-2 保护路径不再被父子归并

    /// 默认保护名单里 `/`、`/Users` 会让 `PathWhitelist.normalized` 把
    /// `~/Documents`、`~/Library/Caches` 等全部归并掉。这里钉住它们都还在。
    func testDefaultProtectionKeepsHomeSubdirectories() throws {
        let home = try makeHome()
        defer { try? fileManager.removeItem(at: home) }

        let context = DeletionContext(whitelistedPaths: [], projectRoots: [], home: home)
        let protected = Set(context.protectedPaths.map(\.path))
        for relative in ["Documents", "Downloads", "Library/Caches", "Library/Logs", ".Trash", "Library"] {
            XCTAssertTrue(
                protected.contains(home.appendingPathComponent(relative).standardizedFileURL.path),
                "\(relative) 必须仍在保护名单里"
            )
        }
        XCTAssertTrue(protected.contains(home.standardizedFileURL.path), "主目录本身必须受保护")
    }

    /// 删除 `~/Documents` 这类目录必须被拒绝。
    func testDeletingProtectedHomeDirectoryIsRejected() throws {
        let home = try makeHome()
        defer { try? fileManager.removeItem(at: home) }

        for relative in ["Documents", "Downloads", "Library", "Library/Caches"] {
            let url = home.appendingPathComponent(relative)
            let context = DeletionContext(whitelistedPaths: [], projectRoots: [], home: home,
                                          allowedPaths: [url])
            XCTAssertThrowsError(try DeletionValidator.validate(item: item(url), context: context),
                                 "删除 \(relative) 必须被拒绝") { error in
                XCTAssertEqual(error as? DeletionValidationError, .protectedPath, relative)
            }
        }
    }

    /// `.trashContents` 是「保留目录、清空内容」，只允许白名单里的四个目录；
    /// `~/Documents` 这种绝不允许被清空。
    func testTrashContentsOnlyAllowedForAllowlistedRoots() throws {
        let home = try makeHome()
        defer { try? fileManager.removeItem(at: home) }

        // 允许的四个。
        for relative in ["Library/Caches", "Library/Logs", ".Trash", "Downloads"] {
            let url = home.appendingPathComponent(relative)
            let context = DeletionContext(whitelistedPaths: [], projectRoots: [], home: home,
                                          allowedPaths: [url])
            XCTAssertNoThrow(
                try DeletionValidator.validate(item: item(url, kind: .trashContents), context: context),
                "\(relative) 应允许清空内容"
            )
        }
        // 不允许的。
        for relative in ["Documents", "Library", "Desktop"] {
            let url = home.appendingPathComponent(relative)
            try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            let context = DeletionContext(whitelistedPaths: [], projectRoots: [], home: home,
                                          allowedPaths: [url])
            XCTAssertThrowsError(
                try DeletionValidator.validate(item: item(url, kind: .trashContents), context: context),
                "\(relative) 不得被「清空内容」"
            )
        }
    }

    // MARK: P1-3 历史勾选不得跨清理类型恢复

    /// 同一路径以前是普通缓存（勾选过），现在变成 toolCommand：旧勾选必须失效。
    func testSelectionMemoryDoesNotRestoreAcrossSpecialKinds() {
        let path = URL(fileURLWithPath: "/tmp/some-cache")
        let states = [SelectionMemory.key(for: path): true]

        let trash = CacheItem(category: "测试", name: "c", path: path, size: 1, risk: .safe, kind: .trash)
        XCTAssertTrue(SelectionMemory.restore([trash], from: states)[0].isSelected,
                      "普通缓存仍可恢复历史勾选")

        for kind in [CleanupKind.toolCommand, .trashContents, .timeMachineSnapshot,
                     .dockerPrune, .requestLogTrim] {
            let special = CacheItem(category: "测试", name: "c", path: path, size: 1,
                                    risk: .review, kind: kind)
            XCTAssertFalse(SelectionMemory.restore([special], from: states)[0].isSelected,
                           "\(kind) 不得恢复历史勾选")
        }
    }

    /// 即便 isSelected 被置为 true，批量清理集合也必须再次校验可批量选择。
    func testSelectedItemsFiltersOutNonBatchKinds() {
        let path = URL(fileURLWithPath: "/tmp/x")
        let sneaky = CacheItem(category: "测试", name: "c", path: path, size: 1,
                               risk: .review, kind: .toolCommand, isSelected: true)
        XCTAssertTrue(CleanupSelection.selectedItems(from: [sneaky]).isEmpty,
                      "特殊操作不得进入批量清理集合")

        let normal = CacheItem(category: "测试", name: "n", path: path, size: 1,
                               risk: .review, kind: .trash, isSelected: true)
        XCTAssertEqual(CleanupSelection.selectedItems(from: [normal]).count, 1)
    }

    // MARK: P1-1 Time Machine 快照必须真正可用

    /// 快照体积未知（size == 0），不能因此被 1 MB 门槛过滤掉；
    /// 且必须是可勾选的 .review，而不是让 UI 直接禁用的 .manual。
    func testTimeMachineEntriesSurviveSizeFilterAndAreSelectable() throws {
        XCTAssertTrue(CleanupKind.timeMachineSnapshot.isSizeAgnostic,
                      "快照体积未知，必须豁免大小门槛")

        let snapshotItem = CacheItem(
            category: "Time Machine 快照", name: "本地快照", path: URL(fileURLWithPath: "/System/Volumes/Data/.devsweep-time-machine-snapshots/2026-10-27-151925"),
            size: 0, risk: .review, kind: .timeMachineSnapshot, identifier: "2026-10-27-151925"
        )
        // 模拟扫描收尾的过滤条件。
        let minimumItemSize: Int64 = 1 * 1024 * 1024
        XCTAssertTrue(snapshotItem.size >= minimumItemSize || snapshotItem.kind.isSizeAgnostic)
        // 可手动选，但不得参与批量选择。
        XCTAssertFalse(CleanupSelection.isBatchSelectable(snapshotItem))
        XCTAssertTrue(CleanupSelection.selectedItems(from: [
            CacheItem(category: snapshotItem.category, name: snapshotItem.name,
                      path: snapshotItem.path, size: 0, risk: .review,
                      kind: .timeMachineSnapshot, identifier: snapshotItem.identifier,
                      isSelected: true)
        ]).isEmpty)
    }

    // MARK: P2-10 旧 Runtime 不默认勾选

    func testOlderRuntimeIsNotPreselected() throws {
        // 通过扫描器构造 Runtime 条目来验证默认值。
        let runtime = SimulatorRuntimeInfo(
            identifier: "OLD", runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-5",
            platformIdentifier: "com.apple.platform.iphonesimulator", version: "26.5", build: "23F77",
            deletable: true, sizeBytes: 1, mountPath: "/Library/Developer/CoreSimulator/Volumes/iOS_23F77",
            parentMountPath: nil, state: "Ready", lastUsedAt: nil, runtimeBundlePath: nil
        )
        let newer = SimulatorRuntimeInfo(
            identifier: "NEW", runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-27-0",
            platformIdentifier: "com.apple.platform.iphonesimulator", version: "27.0", build: "24A5370g",
            deletable: true, sizeBytes: 1, mountPath: "/Library/Developer/CoreSimulator/Volumes/iOS_24A5370g",
            parentMountPath: nil, state: "Ready", lastUsedAt: nil, runtimeBundlePath: nil
        )
        var collector = ScanCollector()
        let items = CacheScanner.simulatorRuntimeItems(
            runtimeLister: FixedRuntimeLister(fixedRuntimes: [runtime, newer]),
            home: URL(fileURLWithPath: "/tmp"),
            collector: &collector
        )
        XCTAssertEqual(items.count, 2)
        XCTAssertTrue(items.allSatisfy { !$0.isSelected },
                      "不可恢复的系统镜像不得默认勾选：\(items.map { ($0.name, $0.isSelected) })")
    }

    // MARK: P2-7 排序比较器严格弱序

    /// 同一路径同时出现 .trash 与 .toolCommand 时，必须稳定保留 toolCommand。
    func testSamePathPrefersToolCommandDeterministically() throws {
        let root = try makeHome()
        defer { try? fileManager.removeItem(at: root) }
        let shared = root.appendingPathComponent("shared-cache")
        try fileManager.createDirectory(at: shared.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data(repeating: 0xA5, count: 1_100_000)
            .write(to: shared.appendingPathComponent("sub/cache.bin"))

        let trash = CacheItem(category: "测试", name: "shared-cache", path: shared, size: 1_100_000, kind: .trash)
        let tool = CacheItem(category: "测试", name: "shared-cache", path: shared, size: 1_100_000,
                             kind: .toolCommand, toolAction: .pnpmStore)

        // 两种输入顺序都必须得到同一结果。
        for input in [[trash, tool], [tool, trash]] {
            let resolved = CacheScanner.nonOverlappingItems(input)
            XCTAssertEqual(resolved.count, 1, "同路径只应保留一条")
            XCTAssertEqual(resolved.first?.kind, .toolCommand,
                           "同路径必须让官方清理命令优先，否则可能误用普通删除")
        }
    }
}

private struct FixedRuntimeLister: SimulatorRuntimeListing {
    let fixedRuntimes: [SimulatorRuntimeInfo]
    func runtimes() throws -> [SimulatorRuntimeInfo] { fixedRuntimes }
}
