import AppKit
import SwiftUI

// 「Xcode 空间」页：把 XcodeCacheCleaner 的菜单栏体验移植成 DevSweep 的一个侧栏页。
//
// 边界：
// - 本文件只做 UI 与其派生数据；删除动作全部交回调用方（store / Lead 接好的执行器），
//   页面本身不直接调用 CacheCleaner，也不直接删目录。
// - Runtime 列表来自 `simctl runtime list`，但 Runtime 条目本身已经是扫描结果里的
//   `CacheItem(kind: .simulatorRuntime)`，所以「Runtime 行」的子项从 store.items 过滤，
//   不在这里另造条目。
// - 危险操作（Runtime / 归档 / 模拟器设备数据 / DeviceSupport）都需要用户显式勾选，
//   定时清理永远只覆盖可重建缓存。

// MARK: - Runtime 数据源

/// Runtime 清单、Xcode 活动状态与勾选记忆。
///
/// 与 `store.scan()` 并行：`refresh()` 在后台跑 `simctl runtime list` 与 `ps`，
/// 回主线程填 `runtimes` / `activity`。`error` 非空表示 simctl 不可用或不认清单，
/// 此时页面降级为「只处理文件缓存」，其余 12 个分类照常显示。
@MainActor
final class XcodeRuntimeSource: ObservableObject {
    /// UserDefaults key：Runtime 勾选（按 identifier 保存）。
    static let selectionDefaultsKey = "DevSweep.xcodeRuntimeSelection"

    @Published private(set) var runtimes: [SimulatorRuntimeInfo] = []
    @Published private(set) var error: String?
    @Published private(set) var activity: XcodeActivity = .unknown
    @Published private(set) var selectedRuntimeIdentifiers: Set<String> = []
    @Published private(set) var lastCheckedAt: Date?
    @Published private(set) var isRefreshing = false
    /// 最近一次删除的逐条结果；`nil` 表示本次会话还没有删除动作。
    @Published private(set) var lastOutcome: SimulatorRuntimeCleanupOutcome?
    /// 最近一次删除提交过的 identifier，用于「复制兜底命令」。
    @Published private(set) var lastSubmittedIdentifiers: [String] = []

    private let defaults: UserDefaults
    private let runner: any ProcessRunning & Sendable
    /// 记住用户是否显式调整过勾选；没有记录过一次时为 `false`，此时每次刷新都按默认策略重建。
    private let hasStoredSelection: Bool
    /// 手动删除的目标；与 `store.scan()` 的扫描互相独立。
    private let protector = SimulatorRuntimeProtection()
    private let diskInspector = XcodeDiskInspector()

    init(
        defaults: UserDefaults = .standard,
        runner: any ProcessRunning & Sendable = ProcessRunner.shared
    ) {
        self.defaults = defaults
        self.runner = runner
        self.hasStoredSelection = defaults.object(forKey: Self.selectionDefaultsKey) != nil
        if let saved = defaults.stringArray(forKey: Self.selectionDefaultsKey) {
            selectedRuntimeIdentifiers = Set(saved)
        }
    }

    // MARK: 派生数据（视图只读这些，不自己算）

    /// 注入 `XcodeStorageSummary` 的 Runtime 摘要。
    var runtimeSummaries: [SimulatorRuntimeSummary] {
        Self.summaries(for: runtimes)
    }

    /// 可删除的 identifier（每平台保留最新）。
    var removableIdentifiers: [String] {
        SimulatorRuntimeCleaner.removableIdentifiers(runtimes, protection: protector).removableIdentifiers
    }

    /// 不可删除的 Runtime 及原因，用于行内解释。
    var blockedReasons: [String: String] {
        Dictionary(
            SimulatorRuntimeCleaner.removableIdentifiers(runtimes, protection: protector)
                .blocked
                .map { ($0.runtime.identifier, $0.reason) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// 按平台分组的 Runtime，平台内版本从新到旧。
    var runtimeGroups: [XcodeRuntimeGroup] {
        let grouped = Dictionary(grouping: runtimes) {
            SimulatorRuntimeCleaner.platformTitle($0.platformIdentifier)
        }
        return grouped.keys.sorted().map { platform in
            let entries = (grouped[platform] ?? []).sorted { lhs, rhs in
                let left = RuntimeVersion(lhs.displayVersion)
                let right = RuntimeVersion(rhs.displayVersion)
                if let left, let right, left != right { return left > right }
                if (left == nil) != (right == nil) { return left != nil }
                return lhs.identifier < rhs.identifier
            }
            return XcodeRuntimeGroup(platform: platform, runtimes: entries)
        }
    }

    var activityLike: XcodeActivityLike {
        Self.activityLike(activity)
    }

    // MARK: 动作

    /// 重新读 Runtime 清单与 Xcode 活动状态。与 `store.scan()` 并行，互不等待。
    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        let runner = self.runner
        Task {
            let result = await Task.detached(priority: .utility) { () -> XcodeRuntimeRefreshResult in
                let activity = XcodeActivityInspector.runningActivity(runner: runner)
                do {
                    let runtimes = try SimulatorRuntimeCleaner.installedRuntimes(runner: runner)
                    return XcodeRuntimeRefreshResult(runtimes: runtimes, error: nil, activity: activity)
                } catch {
                    return XcodeRuntimeRefreshResult(
                        runtimes: [],
                        error: Self.readableMessage(for: error),
                        activity: activity
                    )
                }
            }.value
            self.activity = result.activity
            if let error = result.error {
                // 读不到清单时保留上一次的列表，但必须让用户看到降级原因。
                self.error = error
            } else {
                self.runtimes = result.runtimes
                self.error = nil
            }
            self.lastCheckedAt = Date()
            self.syncSelectionWithRuntimes()
            self.isRefreshing = false
        }
    }

    /// 每平台保留最新，其余默认勾选；用户显式调整过之后只清理已消失的 identifier。
    func selectionDefaults() {
        let policy = SimulatorRuntimeCleaner.removableIdentifiers(runtimes, protection: protector)
        let removable = Set(policy.removable.map(\.identifier))
        if hasStoredSelection && defaults.object(forKey: Self.selectionDefaultsKey) != nil {
            // 已存在用户偏好：只保留仍然存在且可删除的 identifier。
            let kept = selectedRuntimeIdentifiers.intersection(removable)
            if kept != selectedRuntimeIdentifiers {
                selectedRuntimeIdentifiers = kept
                persistSelection()
            }
            return
        }
        selectedRuntimeIdentifiers = removable
        persistSelection()
    }

    func setRuntimeSelected(_ identifier: String, selected: Bool) {
        guard removableIdentifiers.contains(identifier) || !selected else { return }
        if selected {
            selectedRuntimeIdentifiers.insert(identifier)
        } else {
            selectedRuntimeIdentifiers.remove(identifier)
        }
        persistSelection()
    }

    /// 「模拟器 Runtime」行开关：整组勾选/取消所有可删除的 Runtime。
    func setAllRuntimesSelected(_ selected: Bool) {
        if selected {
            selectedRuntimeIdentifiers = Set(removableIdentifiers)
        } else {
            selectedRuntimeIdentifiers.removeAll()
        }
        persistSelection()
    }

    /// 删除前把「当前勾选」再和真实清单核对一次：勾选里已经不可删除的会被剔掉。
    func takeDeletionIdentifiers() -> [String] {
        let removable = removableIdentifiers
        let ordered = removable.filter { selectedRuntimeIdentifiers.contains($0) }
        selectedRuntimeIdentifiers.subtract(Set(removable).subtracting(Set(ordered)))
        return ordered
    }

    /// 记录一次删除结果，并在成功后重新读清单（Runtime 已被 simctl 移除）。
    func record(_ outcome: SimulatorRuntimeCleanupOutcome, submitted: [String]) {
        lastOutcome = outcome
        lastSubmittedIdentifiers = submitted
        if !outcome.removed.isEmpty {
            let removed = Set(outcome.removed)
            runtimes.removeAll { removed.contains($0.identifier) }
            selectedRuntimeIdentifiers.subtract(removed)
            persistSelection()
        }
        if !outcome.isSuccess {
            refresh()
        }
    }

    func clearOutcome() {
        lastOutcome = nil
        lastSubmittedIdentifiers = []
    }

    /// 兜底命令：直接粘贴到终端重试。
    func fallbackCommandText() -> String {
        SimulatorRuntimeCleaner.fallbackCommands(for: lastSubmittedIdentifiers).joined(separator: "\n")
    }

    nonisolated static func summaries(for runtimes: [SimulatorRuntimeInfo]) -> [SimulatorRuntimeSummary] {
        let protector = SimulatorRuntimeProtection()
        let policy = SimulatorRuntimeCleaner.removableIdentifiers(runtimes, protection: protector)
        let removable = Set(policy.removable.map(\.identifier))
        return runtimes.map { runtime in
            SimulatorRuntimeSummary(
                identifier: runtime.identifier,
                platform: SimulatorRuntimeCleaner.platformTitle(runtime.platformIdentifier),
                version: runtime.displayVersion,
                sizeBytes: max(runtime.sizeBytes ?? 0, 0),
                deletable: removable.contains(runtime.identifier)
            )
        }
    }

    nonisolated static func activityLike(_ activity: XcodeActivity) -> XcodeActivityLike {
        switch activity {
        case .idle: return .idle
        case .xcodeRunning(let detail): return .xcodeRunning(detail)
        case .buildOrTestRunning(let detail): return .buildOrTestRunning(detail)
        case .unknown: return .unknown
        }
    }

    // MARK: 私有

    private func syncSelectionWithRuntimes() {
        if defaults.object(forKey: Self.selectionDefaultsKey) == nil {
            selectionDefaults()
            return
        }
        let removable = Set(removableIdentifiers)
        let kept = selectedRuntimeIdentifiers.intersection(removable)
        if kept != selectedRuntimeIdentifiers {
            selectedRuntimeIdentifiers = kept
            persistSelection()
        }
    }

    private func persistSelection() {
        defaults.set(Array(selectedRuntimeIdentifiers).sorted(), forKey: Self.selectionDefaultsKey)
    }

    nonisolated static func readableMessage(for error: Error) -> String {
        if let runtimeError = error as? SimulatorRuntimeCleanupError {
            return runtimeError.localizedDescription
        }
        let localized = (error as NSError).localizedDescription
        return localized.isEmpty ? "无法读取模拟器 Runtime 列表" : localized
    }
}

/// 后台刷新的一次性结果包（避免在 detached 任务里直接碰 actor 状态）。
private struct XcodeRuntimeRefreshResult: Sendable {
    let runtimes: [SimulatorRuntimeInfo]
    let error: String?
    let activity: XcodeActivity
}

/// 一个平台的 Runtime 分组；平台内按版本从新到旧。
struct XcodeRuntimeGroup: Identifiable, Equatable {
    let platform: String
    let runtimes: [SimulatorRuntimeInfo]

    var id: String { platform }

    var sizeBytes: Int64 {
        runtimes.reduce(0) { $0 + max($1.sizeBytes ?? 0, 0) }
    }
}

// MARK: - 磁盘容量

/// 支持卡右上角的磁盘用量。取不到就返回 `nil`，界面不显示右侧，而不是显示 0。
struct XcodeDiskSnapshot: Equatable {
    let totalBytes: Int64
    let availableBytes: Int64

    var usedBytes: Int64 { max(0, totalBytes - availableBytes) }

    var usedPercent: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(usedBytes) / Double(totalBytes) * 100
    }

    /// `磁盘：53.1 GB 可用 | 已用 95%`
    var headline: String {
        "磁盘：" + availableBytes.devSweepFileSize + " 可用 | 已用 "
            + XcodeStorageMetrics.formatPercent(usedPercent)
    }
}

struct XcodeDiskInspector {
    static let defaultPath = "/"

    func snapshot() -> XcodeDiskSnapshot? {
        Self.read(path: Self.defaultPath)
    }

    static func read(
        path: String = defaultPath,
        fileManager: FileManager = .default
    ) -> XcodeDiskSnapshot? {
        guard let attributes = try? fileManager.attributesOfFileSystem(forPath: path),
              let total = attributes[.systemSize] as? NSNumber,
              let available = attributes[.systemFreeSize] as? NSNumber,
              total.int64Value > 0,
              available.int64Value >= 0
        else { return nil }
        return XcodeDiskSnapshot(
            totalBytes: total.int64Value,
            availableBytes: min(available.int64Value, total.int64Value)
        )
    }
}

// MARK: - 选择模型

/// 分类开关 + 逐项勾选的持久化状态。
///
/// 两个 key 前缀分开存：分类开关用 "DevSweep.xcodeCategories."，逐项勾选用
/// "DevSweep.xcodeItemSelection"（按标准化路径保存，与 SelectionMemory 同语义）。
struct XcodeStorageSelection: Equatable {
    static let categoryKeyPrefix = "DevSweep.xcodeCategories."
    static let itemSelectionKey = "DevSweep.xcodeItemSelection"

    /// 打开的分类。
    private(set) var enabledCategories: Set<XcodeStorageCategory>
    /// 逐项勾选（只用于「展开后额外取消」的条目）。
    private(set) var excludedItemPaths: Set<String>

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var enabled = Set<XcodeStorageCategory>()
        for category in XcodeStorageCategory.allCases {
            let key = Self.categoryKeyPrefix + category.rawValue
            if let saved = defaults.object(forKey: key) as? Bool {
                if saved { enabled.insert(category) }
            } else if category.defaultSwitchOn {
                // 对齐参考实现：DerivedData / Xcode 缓存 / 模拟器日志缓存 /
                // SwiftUI 预览 / 不可用模拟器 / 模拟器 Runtime 默认打开，其余默认关闭。
                enabled.insert(category)
            }
        }
        self.enabledCategories = enabled
        self.excludedItemPaths = Set(defaults.stringArray(forKey: Self.itemSelectionKey) ?? [])
    }

    func isCategoryEnabled(_ category: XcodeStorageCategory) -> Bool {
        enabledCategories.contains(category)
    }

    /// 分类开关的三态。文件分类只看「分类开关 + 本轮逐项取消」；Runtime 分类由
    /// `XcodeRuntimeSource` 的逐条勾选决定，开关只代表「是否参与本次清理」。
    func categoryState(
        _ category: XcodeStorageCategory,
        row: XcodeStorageRow,
        itemsByID: [UUID: CacheItem],
        runtimeSelectedCount: Int,
        runtimeSelectableCount: Int
    ) -> XcodeCategorySelectionState {
        if category == .runtimes {
            guard runtimeSelectableCount > 0 else {
                return isCategoryEnabled(category) ? .on : .off
            }
            if runtimeSelectedCount == 0 { return .off }
            if runtimeSelectedCount == runtimeSelectableCount { return .on }
            return .mixed
        }
        guard !row.isEmpty else {
            return isCategoryEnabled(category) ? .on : .off
        }
        let total = row.itemIDs.filter { itemsByID[$0]?.risk != .manual }.count
        guard total > 0 else {
            return isCategoryEnabled(category) ? .on : .off
        }
        let chosen = row.itemIDs.filter { id in
            guard let item = itemsByID[id], item.risk != .manual else { return false }
            return isItemIncluded(path: SelectionMemory.key(for: item.path))
        }.count
        if chosen == 0 { return .off }
        if chosen == total { return .on }
        return .mixed
    }

    mutating func setCategory(
        _ category: XcodeStorageCategory,
        enabled: Bool
    ) {
        if enabled {
            enabledCategories.insert(category)
        } else {
            enabledCategories.remove(category)
        }
        defaults.set(enabled, forKey: Self.categoryKeyPrefix + category.rawValue)
    }

    /// 整行取消/恢复：文件分类只动逐项记录，Runtime 分类由 RuntimeSource 处理。
    mutating func setAllItems(
        in categories: Set<XcodeStorageCategory>,
        included: Bool,
        rows: [XcodeStorageRow],
        itemsByID: [UUID: CacheItem]
    ) {
        for row in rows {
            guard let category = XcodeStorageCategory.allCases.first(where: {
                XcodeStorageClassifier.rowID(for: $0) == row.id
            }), categories.contains(category), category != .runtimes else { continue }
            for id in row.itemIDs {
                guard let item = itemsByID[id] else { continue }
                let key = SelectionMemory.key(for: item.path)
                if included {
                    excludedItemPaths.remove(key)
                } else {
                    excludedItemPaths.insert(key)
                }
            }
        }
        persistExcluded()
    }

    func isItemIncluded(path: String) -> Bool {
        !excludedItemPaths.contains(path)
    }

    mutating func setItemIncluded(path: String, included: Bool) {
        if included {
            excludedItemPaths.remove(path)
        } else {
            excludedItemPaths.insert(path)
        }
        persistExcluded()
    }

    private mutating func persistExcluded() {
        defaults.set(Array(excludedItemPaths).sorted(), forKey: Self.itemSelectionKey)
    }
}

/// 一行分类开关的三态。
enum XcodeCategorySelectionState {
    case on
    case off
    case mixed
}

// MARK: - 清理计划

/// 一次「立即清理」要做的两件事：文件条目 + Runtime。
struct XcodeCleanupPlan: Equatable {
    var items: [CacheItem]
    var runtimeIdentifiers: [String]
    /// 勾选 Runtime 的大小合计（Runtime 的 CacheItem 体积可能缺失，单独记）。
    var runtimeBytes: Int64

    var isEmpty: Bool { items.isEmpty && runtimeIdentifiers.isEmpty }

    var totalBytes: Int64 {
        items.reduce(0) { $0 + max(0, $1.size) } + runtimeBytes
    }

    var summaryText: String {
        var parts: [String] = []
        if !items.isEmpty { parts.append("\(items.count) 个缓存条目") }
        if !runtimeIdentifiers.isEmpty { parts.append("\(runtimeIdentifiers.count) 个 Runtime") }
        return parts.isEmpty ? "没有可清理的项目" : parts.joined(separator: "、")
    }

    static func make(
        items: [CacheItem],
        selection: XcodeStorageSelection,
        rows: [XcodeStorageRow],
        selectedRuntimeIdentifiers: Set<String>,
        runtimeBytesByIdentifier: [String: Int64]
    ) -> XcodeCleanupPlan {
        var chosen: [CacheItem] = []
        for row in rows {
            guard let category = XcodeStorageCategory.allCases.first(where: {
                XcodeStorageClassifier.rowID(for: $0) == row.id
            }) else { continue }
            guard selection.isCategoryEnabled(category) else { continue }
            let wanted = Set(row.itemIDs)
            for item in items where wanted.contains(item.id) {
                guard item.risk != .manual else { continue }
                guard selection.isItemIncluded(path: SelectionMemory.key(for: item.path)) else { continue }
                chosen.append(item)
            }
        }

        let runtimeRow = rows.first {
            $0.id == XcodeStorageClassifier.rowID(for: .runtimes)
        }
        let runtimeCategoryEnabled = selection.isCategoryEnabled(.runtimes)
        let runtimeIDs = runtimeCategoryEnabled
            ? (runtimeRow?.runtimeIdentifiers ?? []).filter { selectedRuntimeIdentifiers.contains($0) }
            : []
        let runtimeBytes = runtimeIDs.reduce(Int64(0)) {
            $0 + max(0, runtimeBytesByIdentifier[$1] ?? 0)
        }
        return XcodeCleanupPlan(
            items: chosen,
            runtimeIdentifiers: runtimeIDs,
            runtimeBytes: runtimeBytes
        )
    }
}

// MARK: - 定时清理策略

enum XcodeCleanSchedule: String, CaseIterable, Identifiable, Hashable {
    case off
    case every1Hour
    case every4Hours
    case every12Hours
    case every24Hours

    static let storageKey = "DevSweep.xcodeCleanSchedule"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return "关闭"
        case .every1Hour: return "每 1 小时"
        case .every4Hours: return "每 4 小时"
        case .every12Hours: return "每 12 小时"
        case .every24Hours: return "每 24 小时"
        }
    }

    var interval: TimeInterval? {
        switch self {
        case .off: return nil
        case .every1Hour: return 3_600
        case .every4Hours: return 4 * 3_600
        case .every12Hours: return 12 * 3_600
        case .every24Hours: return 24 * 3_600
        }
    }

    static let note = "定时清理只处理可重建缓存，不会删除 Runtime、归档、DeviceSupport 或模拟器数据"
}

// MARK: - 页面

struct XcodeStorageView: View {
    @ObservedObject private var store: DevSweepStore
    @ObservedObject private var runtimeSource: XcodeRuntimeSource
    private let onCleanItems: ([CacheItem]) -> Void
    private let onDeleteRuntimes: ([String]) -> Void

    @State private var selection: XcodeStorageSelection
    @State private var expanded: Set<String> = []
    @State private var disk: XcodeDiskSnapshot?
    @State private var pendingVerdict: PreflightVerdict?
    @State private var showingPreflight = false
    @State private var lastCheckedAt: Date?
    @AppStorage(XcodeCleanSchedule.storageKey) private var scheduleRaw = XcodeCleanSchedule.off.rawValue

    init(
        store: DevSweepStore,
        runtimeSource: XcodeRuntimeSource,
        onCleanItems: @escaping ([CacheItem]) -> Void,
        onDeleteRuntimes: @escaping ([String]) -> Void
    ) {
        _store = ObservedObject(wrappedValue: store)
        _runtimeSource = ObservedObject(wrappedValue: runtimeSource)
        _selection = State(initialValue: XcodeStorageSelection())
        self.onCleanItems = onCleanItems
        self.onDeleteRuntimes = onDeleteRuntimes
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            headerCard
            if let error = runtimeSource.error {
                degradationCard(error)
            }
            if let outcome = runtimeSource.lastOutcome {
                outcomeCard(outcome)
            }
            categorySection
            actionBar
        }
        .onAppear(perform: markCheckedIfNeeded)
        .onChange(of: store.isScanning) { isScanning in
            if !isScanning { markCheckedIfNeeded() }
            if isScanning { runtimeSource.refresh() }
        }
        .onChange(of: runtimeSource.lastCheckedAt) { value in
            if let value { lastCheckedAt = value }
        }
        .alert("本次清理已被阻止", isPresented: $showingPreflight) {
            Button("知道了") { pendingVerdict = nil }
        } message: {
            Text(pendingVerdict?.text ?? "")
        }
        .confirmationDialog(
            "仍有程序正在使用这些缓存，继续清理？",
            isPresented: Binding(
                get: { pendingVerdict?.canProceed == true },
                set: { if !$0 { pendingVerdict = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("继续清理", role: .destructive) {
                if let verdict = pendingVerdict { performCleanup(verdict: verdict) }
                pendingVerdict = nil
            }
            Button("取消", role: .cancel) { pendingVerdict = nil }
        } message: {
            Text(verbatim: confirmMessageText)
        }
    }

    /// 先拼成局部字符串再交给 Text：直接内联会让 SwiftUI 的类型检查超时。
    private var confirmMessageText: String {
        let reason = pendingVerdict?.text ?? ""
        let targets = plan.summaryText
        let size = plan.totalBytes.devSweepFileSize
        return reason + "\n\n将处理 " + targets + "，合计 " + size + "。"
    }

    // MARK: 派生

    private var rows: [XcodeStorageRow] {
        XcodeStorageRows.rows(from: summary, items: store.items)
    }

    private var summary: XcodeStorageSummary {
        XcodeStorageSummary(
            items: store.items,
            runtimeItems: runtimeSource.runtimeSummaries,
            diskTotalBytes: disk?.totalBytes,
            diskAvailableBytes: disk?.availableBytes
        )
    }

    private var runtimeItemsByIdentifier: [String: CacheItem] {
        var result: [String: CacheItem] = [:]
        for item in store.items where item.kind == .simulatorRuntime {
            guard let identifier = item.identifier else { continue }
            result[identifier] = item
        }
        return result
    }

    /// 分类三态判定要用的 id → 条目映射（避免每行重复线性过滤 store.items）。
    private var itemsByID: [UUID: CacheItem] {
        var result: [UUID: CacheItem] = [:]
        result.reserveCapacity(store.items.count)
        for item in store.items {
            result[item.id] = item
        }
        return result
    }

    /// 可删除的 Runtime 数量；`selected == true` 时只数其中已被勾选的。
    private func selectableRuntimeCount(selected: Bool) -> Int {
        let removable = runtimeSource.removableIdentifiers
        guard selected else { return removable.count }
        let chosen = runtimeSource.selectedRuntimeIdentifiers
        return removable.filter { chosen.contains($0) }.count
    }

    private var runtimeBytesByIdentifier: [String: Int64] {
        var result: [String: Int64] = [:]
        for runtime in runtimeSource.runtimes {
            result[runtime.identifier] = max(runtime.sizeBytes ?? 0, 0)
        }
        for (identifier, item) in runtimeItemsByIdentifier {
            if result[identifier] == nil { result[identifier] = max(item.size, 0) }
        }
        return result
    }

    private var plan: XcodeCleanupPlan {
        XcodeCleanupPlan.make(
            items: store.items,
            selection: selection,
            rows: rows,
            selectedRuntimeIdentifiers: runtimeSource.selectedRuntimeIdentifiers,
            runtimeBytesByIdentifier: runtimeBytesByIdentifier
        )
    }

    private var schedule: XcodeCleanSchedule {
        XcodeCleanSchedule(rawValue: scheduleRaw) ?? .off
    }

    private var isBusy: Bool {
        store.isScanning || store.isCleaning || runtimeSource.isRefreshing
    }

    // MARK: 顶部摘要卡

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Image(systemName: "hammer.fill")
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 34, height: 34)
                    .background(Color.accentColor.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(XcodeStorageMetrics.headline(
                        label: "Xcode 缓存",
                        bytes: summary.totalBytes,
                        diskTotalBytes: summary.diskTotalBytes
                    ))
                    .font(.title3.weight(.semibold).monospacedDigit())
                    Text("可重建 \(summary.rebuildableBytes.devSweepFileSize) · 需确认 \(summary.reviewBytes.devSweepFileSize) · 手动 \(summary.manualBytes.devSweepFileSize)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                if let disk {
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(disk.headline)
                            .font(.subheadline.monospacedDigit().weight(.medium))
                        Text("总量 " + disk.totalBytes.devSweepFileSize)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Divider()
            HStack(spacing: 10) {
                Text("检测于 " + checkedText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if isBusy {
                    ProgressView().controlSize(.small)
                    Text(store.isScanning ? "检测中…" : (store.isCleaning ? "正在清理…" : "正在读取 Runtime…"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if store.isScanning {
                    Text(store.scanProgress.phase)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Button {
                    disk = XcodeDiskInspector().snapshot()
                    lastCheckedAt = Date()
                    store.scan()
                    runtimeSource.refresh()
                } label: {
                    Label("重新检测", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(isBusy)
                .help("重新扫描 Xcode 缓存大小，并重新读取模拟器 Runtime 与 Xcode 活动状态")
            }
        }
        .padding(16)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.08))
        }
    }

    private var checkedText: String {
        guard let date = lastCheckedAt ?? runtimeSource.lastCheckedAt else { return "尚未检测" }
        return date.formatted(date: .omitted, time: .shortened)
    }

    // MARK: 降级提示

    private func degradationCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("无法读取模拟器 Runtime，已降级为只处理文件缓存", systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.medium))
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text("其余 12 个分类不受影响；恢复 simctl 后点「重新检测」即可。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: 删除结果

    private func outcomeCard(_ outcome: SimulatorRuntimeCleanupOutcome) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label(outcome.summary, systemImage: outcome.isSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(outcome.isSuccess ? Color.green : Color.orange)
                Spacer()
                if !outcome.isSuccess {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(runtimeSource.fallbackCommandText(), forType: .string)
                    } label: {
                        Label("复制兜底命令", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                }
                Button {
                    runtimeSource.clearOutcome()
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.borderless)
                .help("关闭本次结果")
            }
            // Runtime 失败与设备失败分开展示：本页只处理 Runtime，设备永远不在这里删除。
            if !outcome.removed.isEmpty {
                Text("已删除 Runtime " + outcome.removed.joined(separator: "、"))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if !outcome.remaining.isEmpty {
                Text("Runtime 仍未消失：" + outcome.remaining.joined(separator: "、"))
                    .font(.caption.monospaced())
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
            ForEach(Array(outcome.failures.enumerated()), id: \.offset) { _, failure in
                Text(failure.id + "：" + failure.message)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
            Text("以上失败只涉及模拟器 Runtime。模拟器设备（Devices）不在本页删除，请到模拟器页面关机后单独处理。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: 分类列表

    private var categorySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Xcode 缓存分类")
                    .font(.headline)
                Text("\(XcodeStorageCategory.allCases.count) 个分类")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("已选 " + plan.summaryText + " · " + plan.totalBytes.devSweepFileSize)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if store.isScanning && store.items.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在检测 Xcode 缓存…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 12)
            }

            LazyVStack(spacing: 10) {
                ForEach(rows) { row in
                    if let category = XcodeStorageCategory.allCases.first(where: {
                        XcodeStorageClassifier.rowID(for: $0) == row.id
                    }) {
                        XcodeStorageCategoryRow(
                            row: row,
                            category: category,
                            state: selection.categoryState(
                                category,
                                row: row,
                                itemsByID: itemsByID,
                                runtimeSelectedCount: selectableRuntimeCount(selected: true),
                                runtimeSelectableCount: selectableRuntimeCount(selected: false)
                            ),
                            isExpanded: expanded.contains(row.id),
                            items: items(for: row),
                            emptyHint: emptyHint(for: category),
                            runtimeSource: runtimeSource,
                            isBusy: isBusy,
                            onToggleCategory: { enabled in
                                // 打开 = 该分类整组参与清理；关闭 = 整组退出，并撤销逐项取消记录。
                                selection.setCategory(category, enabled: enabled)
                                selection.setAllItems(
                                    in: [category], included: enabled, rows: rows, itemsByID: itemsByID
                                )
                                if category == .runtimes {
                                    runtimeSource.setAllRuntimesSelected(enabled)
                                }
                            },
                            onToggleExpanded: {
                                if expanded.contains(row.id) {
                                    expanded.remove(row.id)
                                } else {
                                    expanded.insert(row.id)
                                }
                            },
                            isItemIncluded: { path in selection.isItemIncluded(path: path) },
                            onToggleItem: { path, included in
                                selection.setItemIncluded(path: path, included: included)
                            }
                        )
                    }
                }
            }
        }
    }

    private func items(for row: XcodeStorageRow) -> [CacheItem] {
        let wanted = Set(row.itemIDs)
        return store.items.filter { wanted.contains($0.id) }
    }

    private func emptyHint(for category: XcodeStorageCategory) -> String {
        if category == .runtimes {
            return runtimeSource.error == nil ? "没有检测到可删除的模拟器 Runtime" : "读取 Runtime 列表失败"
        }
        return "没有检测到可清理的内容"
    }

    // MARK: 底部动作区

    private var actionBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Button {
                    requestCleanup()
                } label: {
                    Label("立即清理", systemImage: "trash")
                }
                .buttonStyle(.borderedProminent)
                .disabled(plan.isEmpty || isBusy)
                .help("先检查 Xcode / 构建 / 测试状态，再清理选中项")

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(plan.summaryText + " · " + plan.totalBytes.devSweepFileSize, forType: .string)
                } label: {
                    Label("复制清理清单", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .disabled(plan.isEmpty)

                Menu {
                    ForEach(XcodeCleanSchedule.allCases) { option in
                        Button {
                            scheduleRaw = option.rawValue
                        } label: {
                            if option == schedule {
                                Label(option.title, systemImage: "checkmark")
                            } else {
                                Text(option.title)
                            }
                        }
                    }
                } label: {
                    Label("定时清理：" + schedule.title, systemImage: "clock")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(XcodeCleanSchedule.note)

                Spacer(minLength: 12)
                Text("已选 " + plan.totalBytes.devSweepFileSize)
                    .font(.subheadline.monospacedDigit().weight(.semibold))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(XcodeCleanSchedule.note)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("Runtime、归档、DeviceSupport、模拟器设备数据和「不可用模拟器」需逐项勾选；标注「不可从废纸篓恢复」的项目删除后无法还原。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                if preflightPreview.isBlocked {
                    Label(preflightPreview.text, systemImage: "exclamationmark.octagon.fill")
                        .font(.caption2)
                        .foregroundStyle(.red)
                } else if case .warn = preflightPreview {
                    Label(preflightPreview.text, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.08))
        }
    }

    /// 底部常驻提示：用当前选择算一次预检，让用户在点按钮之前就看到会被阻止。
    private var preflightPreview: PreflightVerdict {
        XcodeLaunchPreflight.preflight(
            activity: runtimeSource.activityLike,
            targets: plan.items
        )
    }

    // MARK: 动作

    private func markCheckedIfNeeded() {
        disk = XcodeDiskInspector().snapshot()
        if !store.items.isEmpty || lastCheckedAt == nil {
            lastCheckedAt = Date()
        }
        runtimeSource.selectionDefaults()
        if runtimeSource.lastCheckedAt == nil && !runtimeSource.isRefreshing {
            runtimeSource.refresh()
        }
    }

    private func requestCleanup() {
        guard !plan.isEmpty else { return }
        // 点击的那一刻重新算一次预检，绝不使用渲染时的旧状态。
        let verdict = XcodeLaunchPreflight.preflight(
            activity: runtimeSource.activityLike,
            targets: plan.items
        )
        switch verdict {
        case .block:
            // 阻止态只弹 alert：没有可确认的分支。
            pendingVerdict = verdict
            showingPreflight = true
        case .warn:
            // 警告态弹确认框，用户确认后才执行。
            pendingVerdict = verdict
        case .proceed:
            performCleanup(verdict: verdict)
            pendingVerdict = nil
        }
    }

    private func performCleanup(verdict: PreflightVerdict) {
        guard verdict.canProceed else { return }
        let current = plan
        guard !current.isEmpty else { return }
        if !current.items.isEmpty {
            onCleanItems(current.items)
        }
        if !current.runtimeIdentifiers.isEmpty {
            onDeleteRuntimes(current.runtimeIdentifiers)
        }
    }
}

// MARK: - 分类行

private struct XcodeStorageCategoryRow: View {
    let row: XcodeStorageRow
    let category: XcodeStorageCategory
    let state: XcodeCategorySelectionState
    let isExpanded: Bool
    let items: [CacheItem]
    let emptyHint: String
    @ObservedObject var runtimeSource: XcodeRuntimeSource
    let isBusy: Bool
    let onToggleCategory: (Bool) -> Void
    let onToggleExpanded: () -> Void
    let isItemIncluded: (String) -> Bool
    let onToggleItem: (String, Bool) -> Void

    private var isRuntimeRow: Bool { category == .runtimes }

    private var childCount: Int {
        if isRuntimeRow {
            return runtimeSource.runtimes.count
        }
        return items.count
    }

    private var canExpand: Bool { childCount > 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Toggle("", isOn: Binding(
                    get: { state != .off },
                    set: { onToggleCategory($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(row.isEmpty || isBusyForToggle)
                .help(row.isEmpty ? "该分类当前没有内容" : "打开后在「立即清理」时处理这一分类")

                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(row.risk.color)
                    .frame(width: 32, height: 32)
                    .background(row.risk.color.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(row.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        XcodeRiskBadge(title: row.risk.title, color: row.risk.color)
                        if isRuntimeRow, state == .mixed {
                            XcodeRiskBadge(title: "部分选中", color: .orange)
                        }
                        if !row.allowsAutomaticClean {
                            XcodeRiskBadge(title: "需逐项确认", color: .secondary)
                        }
                        if requiresManualRecovery {
                            XcodeRiskBadge(title: "不可从废纸篓恢复", color: .red)
                        }
                    }
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 12)

                Text(row.sizeBytes.devSweepFileSize)
                    .font(.subheadline.monospacedDigit().weight(.medium))
                    .foregroundStyle(row.isEmpty ? Color.secondary : Color.primary)
                    .frame(minWidth: 84, alignment: .trailing)

                Button(action: onToggleExpanded) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(canExpand ? Color.secondary : Color.secondary.opacity(0.3))
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.borderless)
                .disabled(!canExpand)
                .help(canExpand ? "展开或收起子项" : emptyHint)
            }

            if isExpanded && canExpand {
                Divider()
                children
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(row.risk == .safe ? 0.07 : 0.12))
        }
    }

    @ViewBuilder
    private var children: some View {
        if isRuntimeRow {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(runtimeSource.runtimeGroups) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(group.platform + " · " + String(group.runtimes.count) + " 个版本 · "
                            + group.sizeBytes.devSweepFileSize)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(group.runtimes, id: \.identifier) { runtime in
                            XcodeRuntimeRow(
                                runtime: runtime,
                                blockReason: runtimeSource.blockedReasons[runtime.identifier],
                                isSelected: Binding(
                                    get: { runtimeSource.selectedRuntimeIdentifiers.contains(runtime.identifier) },
                                    set: { runtimeSource.setRuntimeSelected(runtime.identifier, selected: $0) }
                                ),
                                isBusy: isBusy
                            )
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(items) { item in
                    XcodeStorageItemRow(
                        item: item,
                        included: Binding(
                            get: { isItemIncluded(SelectionMemory.key(for: item.path)) },
                            set: { onToggleItem(SelectionMemory.key(for: item.path), $0) }
                        ),
                        isBusy: isBusy
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var isBusyForToggle: Bool { isBusy }

    private var subtitle: String {
        if isRuntimeRow, state == .mixed, category == .runtimes {
            return row.subtitle + "（部分版本已勾选）"
        }
        return row.subtitle
    }

    private var requiresManualRecovery: Bool {
        switch category {
        case .runtimes, .archives, .simulatorDevices, .unavailableSimulators, .deviceSupport:
            return true
        default:
            return false
        }
    }

    private var icon: String {
        switch category {
        case .derivedData: return "hammer"
        case .xcodeCaches: return "shippingbox"
        case .simulatorLogsCaches: return "doc.text"
        case .swiftUIPreviews: return "rectangle.on.rectangle"
        case .simulatorDevices: return "iphone.gen3"
        case .unavailableSimulators: return "iphone.slash"
        case .deviceSupport: return "cable.connector"
        case .deviceLogs: return "doc.badge.gearshape"
        case .xcodeProducts: return "shippingbox.and.arrow.backward"
        case .archives: return "archivebox"
        case .xcodeLogs: return "list.bullet.rectangle"
        case .swiftPM: return "swift"
        case .runtimes: return "cube.transparent"
        }
    }
}

// MARK: - 子项行

private struct XcodeRuntimeRow: View {
    let runtime: SimulatorRuntimeInfo
    let blockReason: String?
    @Binding var isSelected: Bool
    let isBusy: Bool

    private var sizeText: String {
        if let size = runtime.sizeBytes, size > 0 { return size.devSweepFileSize }
        return "体积未知"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: $isSelected)
                .labelsHidden()
                .toggleStyle(.checkbox)
                .disabled(blockReason != nil || isBusy)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(runtime.displayName)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    if let build = runtime.build, !build.isEmpty {
                        Text("build \(build)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                    }
                    if runtime.deletable == false {
                        XcodeRiskBadge(title: "不可移除", color: .red)
                    }
                }
                Text(runtime.identifier)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                if let blockReason {
                    Text(blockReason)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("删除后需重新下载；使用该版本的模拟器设备会变得不可用，不可从废纸篓恢复")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if let mount = runtime.mountPath, !mount.isEmpty {
                    Text(URL(fileURLWithPath: mount).devSweepDisplayPath)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(Text(verbatim: mount))
                }
            }
            Spacer(minLength: 12)
            Text(sizeText)
                .font(.callout.monospacedDigit().weight(.medium))
                .foregroundStyle(runtime.sizeBytes == nil ? Color.secondary : Color.primary)
                .frame(minWidth: 92, alignment: .trailing)
        }
        .padding(.vertical, 4)
    }
}

private struct XcodeStorageItemRow: View {
    let item: CacheItem
    @Binding var included: Bool
    let isBusy: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: $included)
                .labelsHidden()
                .toggleStyle(.checkbox)
                .disabled(item.risk == .manual || isBusy)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(item.name)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    XcodeRiskBadge(title: item.statusTitle ?? item.risk.title, color: item.risk.color)
                    if item.kind.isNonRecoverable {
                        XcodeRiskBadge(title: "不可从废纸篓恢复", color: .red)
                    }
                }
                Text(item.path.devSweepDisplayPath)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(Text(verbatim: item.path.path))
                if !item.note.isEmpty {
                    Text(item.note)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 12)
            Text(item.sizeText)
                .font(.callout.monospacedDigit().weight(.medium))
                .frame(minWidth: 92, alignment: .trailing)
        }
        .padding(.vertical, 4)
    }
}

/// 本页自有徽章：与 ContentView 的 RiskBadge 视觉一致，但那个是 private，不能跨文件用。
private struct XcodeRiskBadge: View {
    let title: String
    let color: Color

    var body: some View {
        Text(title)
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(color.opacity(0.11))
            .clipShape(Capsule())
    }
}
