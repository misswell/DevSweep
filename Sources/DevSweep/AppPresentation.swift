import AppKit
import Combine
import Foundation

/// Dock / 菜单栏显示方式的持久化设置。
///
/// 隐藏 Dock 图标后必须保留菜单栏图标，否则应用没有任何入口；
/// 因此菜单栏图标是安全兜底，不允许在 Dock 图标隐藏时关闭。
@MainActor
final class AppPresentationController: ObservableObject {
    static let showDockIconKey = "DevSweep.showDockIcon"
    static let showMenuBarIconKey = "DevSweep.showMenuBarIcon"

    @Published private(set) var showDockIcon: Bool
    @Published private(set) var showMenuBarIcon: Bool

    private let defaults: UserDefaults
    private let activationPolicyHandler: (Bool) -> Void

    init(
        defaults: UserDefaults = .standard,
        activationPolicyHandler: @escaping (Bool) -> Void = { showDock in
            NSApplication.shared.setActivationPolicy(showDock ? .regular : .accessory)
        }
    ) {
        self.defaults = defaults
        self.activationPolicyHandler = activationPolicyHandler
        defaults.register(defaults: [
            Self.showDockIconKey: true,
            Self.showMenuBarIconKey: true,
        ])

        let showDock = defaults.bool(forKey: Self.showDockIconKey)
        let showMenuBar = defaults.bool(forKey: Self.showMenuBarIconKey)
        showDockIcon = showDock
        if !showDock && !showMenuBar {
            // 旧配置或手动改 defaults 后也不能把应用锁在后台。
            showMenuBarIcon = true
            defaults.set(true, forKey: Self.showMenuBarIconKey)
        } else {
            showMenuBarIcon = showMenuBar
        }
    }

    func applyActivationPolicy() {
        activationPolicyHandler(showDockIcon)
    }

    func setShowDockIcon(_ visible: Bool) {
        guard visible != showDockIcon else { return }
        if !visible && !showMenuBarIcon {
            setShowMenuBarIcon(true)
        }
        showDockIcon = visible
        defaults.set(visible, forKey: Self.showDockIconKey)
        applyActivationPolicy()
    }

    func setShowMenuBarIcon(_ visible: Bool) {
        // Dock 已隐藏时菜单栏是唯一入口，拒绝关闭。
        guard visible || showDockIcon else { return }
        guard visible != showMenuBarIcon else { return }
        showMenuBarIcon = visible
        defaults.set(visible, forKey: Self.showMenuBarIconKey)
    }
}

// MARK: - 定时策略

enum AutoCleanupMode: String, CaseIterable, Identifiable {
    case interval
    case dailyTime

    var id: String { rawValue }

    var title: String {
        switch self {
        case .interval: return "按时间间隔"
        case .dailyTime: return "每天定时"
        }
    }
}

enum AutoTrashEmptyTiming: String, CaseIterable, Identifiable {
    case beforeScan
    case afterCleanup

    var id: String { rawValue }

    var title: String {
        switch self {
        case .beforeScan: return "扫描前清空"
        case .afterCleanup: return "清理后清空"
        }
    }
}

/// 纯计算部分：不持有 Timer、不读取磁盘，便于直接测试补跑语义。
struct AutoCleanupSchedule: Equatable {
    var isEnabled: Bool = false
    var mode: AutoCleanupMode = .interval
    var intervalHours: Int = 6
    var dailyHour: Int = 3
    var dailyMinute: Int = 0

    /// 错过计划后（例如应用当时没运行）在启动后稍等再执行，避免和启动流程抢资源。
    static let catchUpDelay: TimeInterval = 30

    var interval: TimeInterval {
        TimeInterval(min(max(intervalHours, 1), 24)) * 3_600
    }

    /// 返回下一次应执行的日期；`lastRunAt` 应传入「上次执行 / 本次启用」中较晚的时间，
    /// 这样刚启用时不会因为旧的执行记录立刻补跑。
    func nextFireDate(
        after now: Date,
        lastRunAt: Date?,
        calendar: Calendar = .current
    ) -> Date? {
        guard isEnabled else { return nil }
        switch mode {
        case .interval:
            guard let lastRunAt else {
                return now.addingTimeInterval(interval)
            }
            let due = lastRunAt.addingTimeInterval(interval)
            return max(due, now.addingTimeInterval(Self.catchUpDelay))
        case .dailyTime:
            if let lastRunAt,
               let today = calendar.date(
                   bySettingHour: dailyHour, minute: dailyMinute, second: 0, of: now
               ),
               today <= now,
               lastRunAt < today {
                return now.addingTimeInterval(Self.catchUpDelay)
            }
            return nextDailyOccurrence(after: now, calendar: calendar)
        }
    }

    private func nextDailyOccurrence(after now: Date, calendar: Calendar) -> Date? {
        var components = DateComponents()
        components.hour = dailyHour
        components.minute = dailyMinute
        components.second = 0
        return calendar.nextDate(
            after: now,
            matching: components,
            matchingPolicy: .nextTime,
            repeatedTimePolicy: .first,
            direction: .forward
        )
    }
}

/// 按间隔或每天固定时间扫描，并把「常用清理」里长期授权的项目移入废纸篓。
/// 只负责排期和状态展示，实际扫描/删除仍走 DevSweepStore 的既有安全校验。
@MainActor
final class AutoCleanupScheduler: ObservableObject {
    enum StorageKey {
        static let enabled = "DevSweep.autoCleanupEnabled"
        static let mode = "DevSweep.autoCleanupMode"
        static let intervalHours = "DevSweep.autoCleanupIntervalHours"
        static let dailyHour = "DevSweep.autoCleanupDailyHour"
        static let dailyMinute = "DevSweep.autoCleanupDailyMinute"
        static let autoCleanQuickClean = "DevSweep.autoCleanupQuickClean"
        static let autoEmptyTrash = "DevSweep.autoCleanupEmptyTrash"
        static let autoEmptyTrashTiming = "DevSweep.autoCleanupEmptyTrashTiming"
        static let lastRunAt = "DevSweep.autoCleanupLastRunAt"
        static let lastResult = "DevSweep.autoCleanupLastResult"
        static let armedAt = "DevSweep.autoCleanupArmedAt"
    }

    static let intervalOptions = [1, 2, 3, 4, 6, 8, 12, 24]

    @Published private(set) var schedule: AutoCleanupSchedule
    @Published private(set) var autoCleanQuickClean: Bool
    @Published private(set) var autoEmptyTrash: Bool
    @Published private(set) var autoEmptyTrashTiming: AutoTrashEmptyTiming
    @Published private(set) var isRunning = false
    @Published private(set) var nextRunAt: Date?
    @Published private(set) var lastRunAt: Date?
    @Published private(set) var lastResult: String?

    private let store: DevSweepStore
    private let defaults: UserDefaults
    private var timer: Timer?
    private var started = false
    /// 本次启用 / 最近一次改配置的时间，用于避免设置刚改完就立刻补跑。
    private var armedAt: Date?

    init(store: DevSweepStore, defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
        defaults.register(defaults: [
            StorageKey.enabled: false,
            StorageKey.mode: AutoCleanupMode.interval.rawValue,
            StorageKey.intervalHours: 6,
            StorageKey.dailyHour: 3,
            StorageKey.dailyMinute: 0,
            StorageKey.autoCleanQuickClean: true,
            StorageKey.autoEmptyTrash: false,
            StorageKey.autoEmptyTrashTiming: AutoTrashEmptyTiming.afterCleanup.rawValue,
        ])

        schedule = AutoCleanupSchedule(
            isEnabled: defaults.bool(forKey: StorageKey.enabled),
            mode: AutoCleanupMode(rawValue: defaults.string(forKey: StorageKey.mode) ?? "") ?? .interval,
            intervalHours: min(max(defaults.integer(forKey: StorageKey.intervalHours), 1), 24),
            dailyHour: min(max(defaults.integer(forKey: StorageKey.dailyHour), 0), 23),
            dailyMinute: min(max(defaults.integer(forKey: StorageKey.dailyMinute), 0), 59)
        )
        autoCleanQuickClean = defaults.object(forKey: StorageKey.autoCleanQuickClean) as? Bool ?? true
        autoEmptyTrash = defaults.object(forKey: StorageKey.autoEmptyTrash) as? Bool ?? false
        autoEmptyTrashTiming = AutoTrashEmptyTiming(
            rawValue: defaults.string(forKey: StorageKey.autoEmptyTrashTiming) ?? ""
        ) ?? .afterCleanup

        let lastRunStamp = defaults.double(forKey: StorageKey.lastRunAt)
        lastRunAt = lastRunStamp > 0 ? Date(timeIntervalSince1970: lastRunStamp) : nil
        lastResult = defaults.string(forKey: StorageKey.lastResult)
        let armedStamp = defaults.double(forKey: StorageKey.armedAt)
        armedAt = armedStamp > 0 ? Date(timeIntervalSince1970: armedStamp) : nil
    }

    var isEnabled: Bool { schedule.isEnabled }
    var mode: AutoCleanupMode { schedule.mode }
    var intervalHours: Int { schedule.intervalHours }
    var dailyHour: Int { schedule.dailyHour }
    var dailyMinute: Int { schedule.dailyMinute }

    var dailyTime: Date {
        Calendar.current.date(
            bySettingHour: schedule.dailyHour,
            minute: schedule.dailyMinute,
            second: 0,
            of: Date()
        ) ?? Date()
    }

    /// 应用启动后调用；重复调用不会创建第二个 Timer。
    func start() {
        guard !started else { return }
        started = true
        reschedule()
    }

    func setEnabled(_ enabled: Bool) {
        guard schedule.isEnabled != enabled else { return }
        var updated = schedule
        updated.isEnabled = enabled
        apply(updated, rearm: enabled)
    }

    func setMode(_ mode: AutoCleanupMode) {
        guard schedule.mode != mode else { return }
        var updated = schedule
        updated.mode = mode
        apply(updated, rearm: true)
    }

    func setIntervalHours(_ hours: Int) {
        let clamped = min(max(hours, 1), 24)
        guard schedule.intervalHours != clamped else { return }
        var updated = schedule
        updated.intervalHours = clamped
        apply(updated, rearm: true)
    }

    func setDailyTime(_ date: Date) {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        let hour = components.hour ?? schedule.dailyHour
        let minute = components.minute ?? schedule.dailyMinute
        guard schedule.dailyHour != hour || schedule.dailyMinute != minute else { return }
        var updated = schedule
        updated.dailyHour = hour
        updated.dailyMinute = minute
        apply(updated, rearm: true)
    }

    func setAutoCleanQuickClean(_ value: Bool) {
        guard autoCleanQuickClean != value else { return }
        autoCleanQuickClean = value
        defaults.set(value, forKey: StorageKey.autoCleanQuickClean)
    }

    func setAutoEmptyTrash(_ value: Bool) {
        guard autoEmptyTrash != value else { return }
        autoEmptyTrash = value
        defaults.set(value, forKey: StorageKey.autoEmptyTrash)
    }

    func setAutoEmptyTrashTiming(_ timing: AutoTrashEmptyTiming) {
        guard autoEmptyTrashTiming != timing else { return }
        autoEmptyTrashTiming = timing
        defaults.set(timing.rawValue, forKey: StorageKey.autoEmptyTrashTiming)
    }

    /// 立即执行一次；未启用定时也会执行，但不改变下次定时时间。
    func runNow() {
        guard !isRunning, !store.isScanning, !store.isCleaning else { return }
        isRunning = true
        nextRunAt = nil
        timer?.invalidate()
        timer = nil
        let cleanQuickClean = autoCleanQuickClean
        let emptyTrash = autoEmptyTrash
        let emptyTrashBeforeScan = autoEmptyTrashTiming == .beforeScan
        store.runScheduledMaintenance(
            cleanQuickClean: cleanQuickClean,
            emptyTrash: emptyTrash,
            emptyTrashBeforeScan: emptyTrashBeforeScan
        ) { [weak self] outcome in
            Task { @MainActor in
                self?.finish(
                    outcome: outcome,
                    cleanRequested: cleanQuickClean,
                    emptyTrashRequested: emptyTrash,
                    emptyTrashBeforeScan: emptyTrashBeforeScan
                )
            }
        }
    }

    private func apply(_ updated: AutoCleanupSchedule, rearm: Bool) {
        guard updated != schedule else { return }
        schedule = updated
        persist(updated)
        if rearm {
            armedAt = Date()
            defaults.set(armedAt!.timeIntervalSince1970, forKey: StorageKey.armedAt)
        }
        reschedule()
    }

    private func persist(_ schedule: AutoCleanupSchedule) {
        defaults.set(schedule.isEnabled, forKey: StorageKey.enabled)
        defaults.set(schedule.mode.rawValue, forKey: StorageKey.mode)
        defaults.set(schedule.intervalHours, forKey: StorageKey.intervalHours)
        defaults.set(schedule.dailyHour, forKey: StorageKey.dailyHour)
        defaults.set(schedule.dailyMinute, forKey: StorageKey.dailyMinute)
    }

    /// 上次执行时间和本次启用时间取较晚者：刚启用或刚改配置时不会因为旧记录立刻补跑。
    private var referenceDate: Date? {
        switch (lastRunAt, armedAt) {
        case let (run?, armed?): return max(run, armed)
        case let (run?, nil): return run
        case let (nil, armed?): return armed
        case (nil, nil): return nil
        }
    }

    private func reschedule() {
        timer?.invalidate()
        timer = nil
        guard schedule.isEnabled else {
            nextRunAt = nil
            return
        }
        let now = Date()
        guard let fireDate = schedule.nextFireDate(after: now, lastRunAt: referenceDate) else {
            nextRunAt = nil
            return
        }
        nextRunAt = fireDate
        startTimer(fireDate: fireDate)
    }

    private func startTimer(fireDate: Date) {
        let timer = Timer(fire: fireDate, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.fireScheduledRun()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func fireScheduledRun() {
        timer = nil
        guard schedule.isEnabled else {
            reschedule()
            return
        }
        guard !isRunning else {
            reschedule()
            return
        }
        guard !store.isScanning, !store.isCleaning else {
            scheduleRetry(after: 5 * 60)
            return
        }
        runNow()
    }

    private func scheduleRetry(after delay: TimeInterval) {
        timer?.invalidate()
        let fireDate = Date().addingTimeInterval(delay)
        nextRunAt = fireDate
        startTimer(fireDate: fireDate)
    }

    private func finish(
        outcome: ScheduledMaintenanceOutcome,
        cleanRequested: Bool,
        emptyTrashRequested: Bool,
        emptyTrashBeforeScan: Bool
    ) {
        isRunning = false
        switch outcome {
        case .busy:
            scheduleRetry(after: 5 * 60)
        case .completed(let summary):
            let finishedAt = Date()
            lastRunAt = finishedAt
            defaults.set(finishedAt.timeIntervalSince1970, forKey: StorageKey.lastRunAt)
            armedAt = finishedAt
            defaults.set(finishedAt.timeIntervalSince1970, forKey: StorageKey.armedAt)
            let result = Self.resultText(
                for: summary,
                cleanRequested: cleanRequested,
                emptyTrashRequested: emptyTrashRequested,
                emptyTrashBeforeScan: emptyTrashBeforeScan
            )
            lastResult = result
            defaults.set(result, forKey: StorageKey.lastResult)
            reschedule()
        }
    }

    private static func resultText(
        for summary: ScheduledMaintenanceSummary,
        cleanRequested: Bool,
        emptyTrashRequested: Bool,
        emptyTrashBeforeScan: Bool
    ) -> String {
        var parts = ["扫描 \(summary.scannedItemCount) 项"]
        if cleanRequested {
            if summary.removedCount > 0 {
                parts.append("清理 \(summary.removedCount) 项 \(summary.removedBytes.devSweepFileSize)")
            } else if summary.quickCleanTargetCount > 0 {
                parts.append("没有可清理的常用项")
            } else {
                parts.append("暂无常用项")
            }
        } else if !emptyTrashRequested {
            parts.append("仅扫描")
        }
        if summary.failureCount > 0 {
            parts.append("清理失败 \(summary.failureCount) 项")
        }
        if emptyTrashRequested {
            let prefix = emptyTrashBeforeScan ? "扫描前清空废纸篓" : "清理后清空废纸篓"
            if summary.emptyTrashFailureCount > 0 {
                parts.append(
                    "\(prefix) \(summary.emptyTrashRemovedCount) 项成功、\(summary.emptyTrashFailureCount) 项失败"
                )
            } else if summary.emptyTrashRemovedCount > 0 {
                parts.append(
                    "\(prefix) \(summary.emptyTrashRemovedCount) 项 \(summary.emptyTrashBytes.devSweepFileSize)"
                )
            } else {
                parts.append("\(prefix)：废纸篓已空")
            }
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - 共享对象

/// App 级共享对象：SwiftUI 场景、AppDelegate 的菜单栏菜单和自动清理任务
/// 必须操作同一个 store，否则菜单栏状态与主窗口会各说各话。
@MainActor
final class AppServices {
    static let shared = AppServices()

    let store: DevSweepStore
    let updater: DevSweepSoftwareUpdater
    let presentation: AppPresentationController
    let scheduler: AutoCleanupScheduler

    private init() {
        let store = DevSweepStore()
        self.store = store
        updater = DevSweepSoftwareUpdater()
        presentation = AppPresentationController()
        scheduler = AutoCleanupScheduler(store: store)
    }
}

func devSweepShortTimestamp(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateFormat = "MM-dd HH:mm"
    return formatter.string(from: date)
}
