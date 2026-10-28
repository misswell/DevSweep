import Foundation

// 把 XcodeCacheCleaner 的「分类 → 可重建性 → 手动确认」产品语义移植成纯数据模型。
//
// 设计边界（重要）：
// - 本文件只有模型与纯函数：不跑 `simctl`、不读真实磁盘、不做删除、不含 UI。
//   Runtime 列表与磁盘容量一律由调用方通过参数注入。
// - 分类顺序、标题与说明沿用参考实现的 13 个默认分类（固定顺序、固定行数），
//   这样视图可以像参考实现一样无条件渲染 13 行，空分类显示 0 字节。
// - 自动清理（定时清理）永远只覆盖「可重建缓存」；归档、Runtime、不可用模拟器、
//   未登记设备与 DeviceSupport 必须由用户逐项手动确认。
// - 风险语义复用本仓库的 RiskLevel，不引入第二套风险枚举。

// MARK: - 分类

/// Xcode 存储分类。声明顺序即 UI 顺序，与参考实现 13 个默认分类一一对应。
enum XcodeStorageCategory: String, CaseIterable, Hashable {
    case derivedData
    case xcodeCaches
    case simulatorLogsCaches
    case swiftUIPreviews
    case simulatorDevices
    case unavailableSimulators
    case deviceSupport
    case deviceLogs
    case xcodeProducts
    case archives
    case xcodeLogs
    case swiftPM
    case runtimes

    var title: String {
        switch self {
        case .derivedData: return "DerivedData"
        case .xcodeCaches: return "Xcode 缓存"
        case .simulatorLogsCaches: return "模拟器日志/缓存"
        case .swiftUIPreviews: return "SwiftUI 预览"
        case .simulatorDevices: return "模拟器设备（清空数据）"
        case .unavailableSimulators: return "不可用模拟器"
        case .deviceSupport: return "iOS DeviceSupport"
        case .deviceLogs: return "设备日志"
        case .xcodeProducts: return "Xcode 产品缓存"
        case .archives: return "归档"
        case .xcodeLogs: return "Xcode 日志"
        case .swiftPM: return "SwiftPM 缓存"
        case .runtimes: return "模拟器 Runtime"
        }
    }

    /// 参考实现的简短说明，直接作为行副标题。
    var subtitle: String {
        switch self {
        case .derivedData: return "编译产物与索引（需要时会重建）"
        case .xcodeCaches: return "Xcode 缓存（可能触发少量重建或下载）"
        case .simulatorLogsCaches: return "模拟器日志/缓存（影响较小）"
        case .swiftUIPreviews: return "SwiftUI 预览数据"
        case .simulatorDevices: return "清空模拟器 App 和数据（不删除 Runtime）"
        case .unavailableSimulators: return "Runtime 已不可用的模拟器设备"
        case .deviceSupport: return "真机符号文件（连接设备时会重建）"
        case .deviceLogs: return "真机诊断日志与崩溃记录"
        case .xcodeProducts: return "Xcode 本地缓存的构建产物"
        case .archives: return "归档（删后无法导出/符号化旧版本）"
        case .xcodeLogs: return "Xcode 活动日志（历史记录会被删除）"
        case .swiftPM: return "SwiftPM 依赖缓存（可能需要重新拉取或重建）"
        case .runtimes: return "iOS/watchOS/tvOS/visionOS Runtime（删除后可重新下载）"
        }
    }

    /// 该分类的默认风险等级。
    var risk: RiskLevel {
        switch self {
        case .derivedData, .xcodeCaches, .simulatorLogsCaches, .swiftUIPreviews,
             .xcodeLogs:
            return .safe
        // 设备诊断日志删除后要等真机重新连接才会重建，与 Scanner 的规则表
        // （risk = .review）保持一致，不再算进「可重建缓存」小计。
        case .deviceLogs, .unavailableSimulators, .xcodeProducts, .archives, .swiftPM:
            return .review
        case .simulatorDevices, .deviceSupport, .runtimes:
            return .manual
        }
    }

    /// 是否属于「可重建缓存」：删除后系统会自行重建，不产生不可恢复损失，
    /// 也是定时清理唯一允许触碰的集合。
    var isRebuildable: Bool {
        risk == .safe
    }

    /// 是否允许参与「一键清理 / 定时清理」。模拟器设备清空、Runtime、归档、
    /// 不可用模拟器、DeviceSupport 在参考实现里都不允许自动清理。
    /// 是否允许参与「一键清理 / 定时清理」。
    ///
    /// 对齐参考实现（XcodeCacheCleaner 的 `allowsAutomaticClean`）：
    /// - 可重建的文件/日志类缓存允许；
    /// - Runtime 不在一键清理里（但可在本页逐条勾选删除）——参考实现给 runtimes 的
    ///   `includedInOneTapClean` 是 true、`allowsAutomaticClean` 是 false，这里保持
    ///   「不参与自动/定时清理」，避免无人值守时把系统镜像删掉；
    /// - 归档、DeviceSupport、模拟器设备清空一律手动；
    /// - 不可用模拟器在参考实现里允许（includedInOneTapClean: true），但它仍然
    ///   必须逐项勾选，所以这里保持允许，只是默认不勾选。
    var allowsAutomaticClean: Bool {
        switch self {
        case .derivedData, .xcodeCaches, .simulatorLogsCaches, .swiftUIPreviews,
             .deviceLogs, .xcodeProducts, .xcodeLogs, .swiftPM, .unavailableSimulators:
            return true
        case .simulatorDevices, .deviceSupport, .archives, .runtimes:
            return false
        }
    }

    /// 分类开关的默认状态，对齐参考实现的 `includedInOneTapClean`：
    /// DerivedData / Xcode 缓存 / 模拟器日志缓存 / SwiftUI 预览 / 不可用模拟器 /
    /// 模拟器 Runtime 默认打开；归档、DeviceSupport、设备数据、设备日志、产品缓存、
    /// Xcode 日志、SwiftPM 缓存默认关闭。
    ///
    /// 注意「开关打开」不等于「会被删除」：真正删除时还要过 `allowsAutomaticClean`
    /// 和逐条勾选（Runtime、不可用模拟器都必须逐项确认）。
    var defaultSwitchOn: Bool {
        switch self {
        case .derivedData, .xcodeCaches, .simulatorLogsCaches, .swiftUIPreviews,
             .unavailableSimulators, .runtimes:
            return true
        case .simulatorDevices, .deviceSupport, .deviceLogs, .xcodeProducts,
             .archives, .xcodeLogs, .swiftPM:
            return false
        }
    }

    /// 该分类的条目能否用普通文件删除（走废纸篓）。
    /// 模拟器设备与 Runtime 只能通过 `simctl` 管理，不能直接整目录删除。
    var usesDirectFileDeletion: Bool {
        switch self {
        case .simulatorDevices, .runtimes:
            return false
        default:
            return true
        }
    }

    /// 是否是由清单（simctl / Runtime 列表）注入的条目，而非文件系统扫描结果。
    var isRuntimeBacked: Bool {
        self == .runtimes
    }
}

// MARK: - 风险分级

/// 风险矩阵（按「分类 + 名称/路径」判定，绝不默认 `.safe`）：
///
/// | 风险 | 归属 |
/// | --- | --- |
/// | `.safe`（可重建） | DerivedData、Xcode 缓存、模拟器日志/缓存、SwiftUI Preview、SwiftPM 缓存、Xcode 产品缓存、设备日志、Xcode 日志、XCTest 克隆 |
/// | `.review`（需确认） | 归档、不可用模拟器、未登记设备、源头控制缓存 |
/// | `.manual`（手动） | DeviceSupport、Runtime、模拟器设备数据、系统级只读缓存 |
///
/// 未知名称默认 `.review`。
enum XcodeStorageRisk {
    static func risk(for category: XcodeStorageCategory) -> RiskLevel {
        category.risk
    }

    /// 由 `CacheItem` 推断风险。
    ///
    /// 只覆盖 Xcode / CoreSimulator / XCTest 三个分类；其它分类（包管理器、
    /// 语言工具链等）原样返回其自有风险，本文件不越权改写别处的判定。
    static func xcodeRisk(for item: CacheItem) -> RiskLevel {
        guard let category = XcodeStorageClassifier.XcodeCategory(categoryName: item.category) else {
            return item.risk
        }
        switch category {
        case .xcode, .xcodeLogs:
            return xcodeFileRisk(forStatement: item.name + " " + item.path.path)
        case .coreSimulator:
            return coreSimulatorRisk(for: item)
        case .xctest:
            return xctestRisk(for: item)
        }
    }

    /// 该条目是否来自 Xcode 存储分类（视图/统计只关心这些条目）。
    static func isXcodeStorageItem(_ item: CacheItem) -> Bool {
        XcodeStorageClassifier.XcodeCategory(categoryName: item.category) != nil
    }

    /// 归档目录是 `.review`，其余按「名称 + 路径」关键词判定。
    /// 判定顺序刻意从最危险（手动）到最安全，保证「DeviceSupport 里的
    /// DerivedData 字样」之类的重叠不会把只读项误判为可自动清理。
    private static func xcodeFileRisk(forStatement statement: String) -> RiskLevel {
        let lowered = statement.lowercased()

        // 1) 手动项：DeviceSupport / Runtime / 归档解析符号。
        if lowered.contains("devicesupport") || lowered.contains("runtime") {
            return .manual
        }
        // 2) 需确认项：归档（不可恢复）、源头控制相关缓存。
        if lowered.contains("archive") || lowered.contains("归档") {
            return .review
        }
        if lowered.contains("源码控制") || lowered.contains("sourcecontrol")
            || lowered.contains("git") {
            return .review
        }
        if lowered.contains("playground") || lowered.contains("sourcepackages") {
            return .review
        }
        // 设备诊断日志：删除后要等真机重新连接才会重建，属于需确认项。
        // Scanner 的规则名是 "iOS Device Logs"（含空格），必须在这里先于通用
        // "logs" 分支命中，否则会被误判成可自动清理。
        if lowered.contains("device logs") || lowered.contains("devicelogs")
            || lowered.contains("设备日志") {
            return .review
        }
        // Xcode Products：Scanner 的规则是 `.review`（项目产物，可按需重新构建）。
        if lowered.contains("products") {
            return .review
        }
        // 3) 可重建缓存。
        if lowered.contains("deriveddata") || lowered.contains("modulecache")
            || lowered.contains("buildcache") || lowered.contains("xcodebuild")
            || lowered.contains("preview") || lowered.contains("documentationcache")
            || lowered.contains("instruments") || lowered.contains("sourcekit")
            || lowered.contains("logs") || lowered.contains("缓存")
            || lowered.contains("caches") {
            return .safe
        }
        // 未识别的名称保守处理：宁可多一次确认，也不默认自动清理。
        return .review
    }

    private static func coreSimulatorRisk(for item: CacheItem) -> RiskLevel {
        // 只看名称 + 去掉 `CoreSimulator` 前缀后的路径尾部：完整路径里必然含有
        // “CoreSimulator” 组件，直接用整串会让 `cache`/`log` 关键词误命中。
        let scoped = (item.name + " " + XcodeStorageClassifier.coreSimulatorPathTail(for: item))
            .lowercased()

        // 已登记设备（含 Booted / Shutdown 状态）属于手动项：只能经 simctl 管理。
        if scoped.contains("booted") || scoped.contains("shutdown")
            || scoped.contains("booting") || scoped.contains("shuttingdown")
            || scoped.contains("shutting down") {
            return .manual
        }
        // 未登记 / 不可用设备：可清理，但要用户确认。
        if scoped.contains("未登记") || scoped.contains("orphan")
            || scoped.contains("unknown") || scoped.contains("unavailable")
            || scoped.contains("不可用") {
            return .review
        }
        // 模拟器缓存 / 日志 / temp 才是可重建缓存。
        if scoped.contains("cache") || scoped.contains("缓存")
            || scoped.contains("log") || scoped.contains("日志")
            || scoped.contains("temp") || scoped.contains("tmp") {
            return .safe
        }
        // 其余 CoreSimulator 条目按设备数据处理。
        return .manual
    }

    /// XCTest 克隆：只有在明确「未运行测试」时才可安全清理；
    /// 正在测试或状态未知一律 `.manual`，与 Scanner 的实际勾选逻辑一致。
    private static func xctestRisk(for item: CacheItem) -> RiskLevel {
        let lowered = item.name.lowercased()
        // 整个 XCTestDevices 根目录永远不能自动清理。
        if lowered.contains("全部") || item.path.path.lowercased().hasSuffix("/xctestdevices") {
            return .review
        }
        if lowered.contains("正在测试") || lowered.contains("无法确认状态") {
            return .manual
        }
        // Scanner 已经把「正在测试 / 状态未知」标成 manual 且取消勾选，
        // 这里尊重扫描结果的保守判定。
        if item.risk == .manual {
            return .manual
        }
        return .safe
    }

    /// 分类名的既有拼写归一化（Scanner 与参考实现都用这几个字符串）。
    enum XcodeCategory {
        case xcode
        case xcodeLogs
        case coreSimulator
        case xctest
    }
}

// MARK: - XCTest 克隆规划

/// XCTest clone 的清理边界：`~/Library/Developer/XCTestDevices/<UUID>` 是可重建的
/// 测试临时 clone；`~/Library/Developer/CoreSimulator/Devices` 是真实登记设备，
/// 两者绝不能合并处理。
enum XcodeXCTestClonePlanner {
    /// 测试克隆根目录（相对 home）。
    static let cloneRootRelativePath = "Library/Developer/XCTestDevices"
    /// 真实注册模拟器根目录；只能经 `xcrun simctl delete <UDID>` 管理。
    static let registeredDeviceRootRelativePath = "Library/Developer/CoreSimulator/Devices"

    enum Location: Equatable {
        /// 位于 XCTestDevices 下的 UUID clone，可重建。
        case xctestClone
        /// 位于 XCTestDevices 下但不是 UUID clone，内容未识别。
        case unclassified
        /// 真实注册设备目录，只能走 simctl。
        case registeredDevice
        /// 与本功能无关的路径。
        case unrelated
    }

    /// 按路径归类。`home` 可由调用方注入，便于测试。
    static func location(
        of path: URL,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Location {
        let homePath = home.standardizedFileURL.path
        let candidatePath = path.standardizedFileURL.path
        guard candidatePath.hasPrefix(homePath + "/") else { return .unrelated }

        // 归一化后以 “/” 开头，保证 “XCTestDevices/” 与 “XCTestDevices/xxx” 都能命中，
        // 同时避免 “XCTestDevicesOld/” 之类前缀误判。
        let relativePath = "/" + String(candidatePath.dropFirst(homePath.count + 1))
        if relativePath == "/" + registeredDeviceRootRelativePath
            || relativePath.hasPrefix("/" + registeredDeviceRootRelativePath + "/") {
            return .registeredDevice
        }

        let cloneRoot = "/" + cloneRootRelativePath
        guard relativePath.hasPrefix(cloneRoot + "/") else { return .unrelated }
        let remainder = String(relativePath.dropFirst(cloneRoot.count + 1))
        // 只有「XCTestDevices/<UUID>」这一层目录是明确可重建的 clone。
        guard !remainder.contains("/"),
              UUID(uuidString: remainder) != nil else { return .unclassified }
        return .xctestClone
    }

    /// 可清理的 clone 路径（仅 UUID 子目录，且排除真实注册设备）。
    static func cleanupCandidates(
        from paths: [URL],
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []
        for path in paths {
            guard location(of: path, home: home) == .xctestClone else { continue }
            let normalized = path.standardizedFileURL
            guard seen.insert(normalized.path).inserted else { continue }
            result.append(normalized)
        }
        return result
    }
}

// MARK: - Runtime 输入

/// 由调用方注入的单条模拟器 Runtime 摘要——本文件不运行 `simctl`。
/// 刻意使用轻量结构，避免与 Runtime 清理实现（SimulatorRuntimeCleanup）产生编译依赖。
struct SimulatorRuntimeSummary: Identifiable, Hashable {
    /// Runtime 标识，例如 `com.apple.CoreSimulator.SimRuntime.iOS-18-2`。
    let identifier: String
    /// 平台名，例如 iOS / watchOS / tvOS / visionOS。
    let platform: String
    /// 版本字符串，例如 `18.2`。
    let version: String
    let sizeBytes: Int64
    /// 是否允许删除（有设备正在使用时调用方应传 false）。
    let deletable: Bool

    init(
        identifier: String,
        platform: String,
        version: String,
        sizeBytes: Int64,
        deletable: Bool
    ) {
        self.identifier = identifier
        self.platform = platform
        self.version = version
        self.sizeBytes = sizeBytes
        self.deletable = deletable
    }

    var id: String { identifier }

    var displayName: String {
        version.isEmpty ? platform : "\(platform) \(version)"
    }

    /// 与参考实现一致：可删除才是 `.review`（需确认），否则 `.manual`。
    var risk: RiskLevel {
        deletable ? .review : .manual
    }
}

// MARK: - 摘要

/// Xcode 存储汇总：Runtime / 归档 / DeviceSupport 分平台大小 + 三档风险小计。
struct XcodeStorageSummary: Equatable {
    /// 注入的 Runtime 列表（已排序，只读）。
    let runtimeItems: [SimulatorRuntimeSummary]
    /// 按平台聚合的 Runtime 大小（iOS/watchOS/…）。
    let runtimesByPlatform: [String: Int64]
    /// 归档大小：不可恢复，必须手动确认。
    let archivesBytes: Int64
    /// 按平台聚合的 DeviceSupport 大小（iOS/watchOS/tvOS/macOS/visionOS）。
    let deviceSupportByPlatform: [String: Int64]
    /// 可重建缓存小计（`RiskLevel.safe`）。
    let rebuildableBytes: Int64
    /// 需确认小计（`RiskLevel.review`）。
    let reviewBytes: Int64
    /// 手动项小计（`RiskLevel.manual`）。
    let manualBytes: Int64
    /// 总计 = 三档小计之和 + Runtime 大小。
    let totalBytes: Int64
    /// 磁盘总量 / 可用空间，`nil` 表示调用方无法可靠取得。
    let diskTotalBytes: Int64?
    let diskAvailableBytes: Int64?

    /// - Parameters:
    ///   - items: 扫描得到的条目；只有 Xcode/CoreSimulator/XCTest 分类参与统计。
    ///   - runtimeItems: 调用方注入的 Runtime 列表（本类型不执行 simctl）。
    ///   - diskTotalBytes: 磁盘总容量，用于百分比展示。
    ///   - diskAvailableBytes: 磁盘可用空间。
    init(
        items: [CacheItem],
        runtimeItems: [SimulatorRuntimeSummary] = [],
        diskTotalBytes: Int64? = nil,
        diskAvailableBytes: Int64? = nil
    ) {
        self.init(
            classified: XcodeStorageSnapshot.Classified.build(from: items),
            runtimeItems: runtimeItems,
            diskTotalBytes: diskTotalBytes,
            diskAvailableBytes: diskAvailableBytes
        )
    }

    /// 内部入口：使用已经分好类的结果，避免 summary 与 rows 各走一遍分类。
    init(
        classified: XcodeStorageSnapshot.Classified,
        runtimeItems: [SimulatorRuntimeSummary] = [],
        diskTotalBytes: Int64? = nil,
        diskAvailableBytes: Int64? = nil
    ) {
        // Runtime：大小单独累加，不混进条目三档小计，避免视图重复计数。
        let sortedRuntimes = runtimeItems.sorted {
            ($0.platform, $0.version, $0.identifier) < ($1.platform, $1.version, $1.identifier)
        }
        self.runtimeItems = sortedRuntimes
        self.runtimesByPlatform = Dictionary(grouping: sortedRuntimes, by: \.platform)
            .mapValues { $0.reduce(0) { $0 + max(0, $1.sizeBytes) } }

        // 分类与风险都已在那唯一一趟里算好，这里只做汇总，不再逐条判定。
        self.derivedDataBytes = classified.bytes(for: .derivedData)
        self.xcodeCachesBytes = classified.bytes(for: .xcodeCaches)
        self.simulatorLogsCachesBytes = classified.bytes(for: .simulatorLogsCaches)
        self.swiftUIPreviewBytes = classified.bytes(for: .swiftUIPreviews)
        self.simulatorDeviceBytes = classified.bytes(for: .simulatorDevices)
        self.unavailableSimulatorBytes = classified.bytes(for: .unavailableSimulators)
        self.deviceLogBytes = classified.bytes(for: .deviceLogs)
        self.xcodeProductBytes = classified.bytes(for: .xcodeProducts)
        self.deviceSupportByPlatform = classified.deviceSupportByPlatform
        self.archivesBytes = classified.bytes(for: .archives)
        self.xcodeLogBytes = classified.bytes(for: .xcodeLogs)
        self.swiftPMBytes = classified.bytes(for: .swiftPM)
        let manualExtra = classified.bytes(for: .runtimes)

        self.rebuildableBytes = classified.rebuildableBytes
        self.reviewBytes = classified.reviewBytes
        self.manualBytes = classified.manualBytes + manualExtra
        self.totalBytes = classified.rebuildableBytes + classified.reviewBytes
            + classified.manualBytes + manualExtra
            + sortedRuntimes.reduce(0) { $0 + max(0, $1.sizeBytes) }
        self.diskTotalBytes = diskTotalBytes
        self.diskAvailableBytes = diskAvailableBytes
    }

    let derivedDataBytes: Int64
    let xcodeCachesBytes: Int64
    let simulatorLogsCachesBytes: Int64
    let swiftUIPreviewBytes: Int64
    let simulatorDeviceBytes: Int64
    let unavailableSimulatorBytes: Int64
    let deviceLogBytes: Int64
    let xcodeProductBytes: Int64
    let xcodeLogBytes: Int64
    let swiftPMBytes: Int64

    /// 全部已安装 Runtime 的大小。
    var runtimeBytes: Int64 {
        runtimeItems.reduce(0) { $0 + max(0, $1.sizeBytes) }
    }

    /// 可删除的 Runtime 大小。
    var deletableRuntimeBytes: Int64 {
        runtimeItems.filter(\.deletable).reduce(0) { $0 + max(0, $1.sizeBytes) }
    }

    /// DeviceSupport 合计。
    var deviceSupportBytes: Int64 {
        deviceSupportByPlatform.values.reduce(0, +)
    }

    /// 按平台排序的 DeviceSupport 明细，便于视图稳定展示。
    var deviceSupportPlatforms: [(platform: String, bytes: Int64)] {
        deviceSupportByPlatform
            .sorted { $0.key < $1.key }
            .map { (platform: $0.key, bytes: $0.value) }
    }

    var isEmpty: Bool {
        totalBytes == 0
    }

    /// 只保留 Xcode / CoreSimulator / XCTest 分类的条目，并按路径去重。
    static func xcodeStorageItems(from items: [CacheItem]) -> [CacheItem] {
        var seen = Set<String>()
        var result: [CacheItem] = []
        for item in items where XcodeStorageRisk.isXcodeStorageItem(item) {
            let key = item.path.standardizedFileURL.path
            guard seen.insert(key).inserted else { continue }
            result.append(item)
        }
        return result
    }
}

// MARK: - 分类判定（条目 → 13 分类）

enum XcodeStorageClassifier {
    /// 三个 Xcode 相关扫描分类的既有拼写。
    enum XcodeCategory {
        case xcode
        case xcodeLogs
        case coreSimulator
        case xctest

        init?(categoryName: String) {
            switch categoryName {
            case "Xcode": self = .xcode
            case "XcodeLogs", "Xcode Logs": self = .xcodeLogs
            case "CoreSimulator", "Simulator": self = .coreSimulator
            case "XCTest": self = .xctest
            default: return nil
            }
        }
    }

    /// 稳定 ID 前缀，视图可直接用作 Identifiable 的 id。
    static func rowID(for category: XcodeStorageCategory) -> String {
        "xcode.storage." + category.rawValue
    }

    /// 条目归属的 13 分类。未知内容归入风险最高、不允许自动清理的分类
    /// （Xcode 分类的未知项算 DeviceSupport 之外的手动项时按 DerivedData 展示是
    /// 不可接受的，因此统一落到 `.deviceSupport` 之外的 `.archives`——
    /// 它是 Xcode 分类里唯一「可能不可恢复」的祖先，避免被误当成可重建缓存）。
    static func category(for item: CacheItem) -> XcodeStorageCategory {
        guard let xcodeCategory = XcodeCategory(categoryName: item.category) else {
            // 非 Xcode 分类不参与概览。
            return .archives
        }

        // 名称权重最高：先看名称，避免 `~/Library/Logs/...` 这类路径组件
        // （System Logs）先把普通缓存误判成「Xcode 日志」。
        let nameStatement = item.name.lowercased()
        let pathStatement = item.path.standardizedFileURL.path.lowercased()
        let tailStatement = xcodePathTail(for: item)

        switch xcodeCategory {
        case .xcodeLogs:
            return .xcodeLogs
        case .xctest:
            // XCTest 临时 clone 是可重建的测试产物，不属于模拟器设备数据；
            // 归档到 SwiftPM 行会误导用户，因此独立落到 DerivedData 行之外的
            // 「可重建」分类由风险函数负责，这里只在 13 行里选一个可重建行。
            return .derivedData
        case .coreSimulator:
            return coreSimulatorCategory(for: item, statement: nameStatement + " " + tailStatement)
        case .xcode:
            if let byName = legacyXcodeCategory(for: item, statement: nameStatement) {
                return byName
            }
            if let byTail = legacyXcodeCategory(for: item, statement: tailStatement) {
                return byTail
            }
            if let byPath = legacyXcodeCategory(for: item, statement: pathStatement) {
                return byPath
            }
            // 完全无法识别：保守落到「需确认」的产品缓存行，绝不当作可重建缓存。
            return .xcodeProducts
        }
    }

    private static func coreSimulatorCategory(
        for item: CacheItem,
        statement: String
    ) -> XcodeStorageCategory {
        if statement.contains("未登记") || statement.contains("orphan")
            || statement.contains("不可用") || statement.contains("unavailable") {
            return .unavailableSimulators
        }
        // 只看条目名 + 「相对 CoreSimulator 根目录」的尾部，避免把路径里必然
        // 出现的 `CoreSimulator` 组件误当成 “cache/log”。
        let name = item.name.lowercased()
        let tail = Self.coreSimulatorPathTail(for: item).lowercased()
        let scoped = name + " " + tail
        if scoped.contains("log") || scoped.contains("日志")
            || scoped.contains("cache") || scoped.contains("缓存")
            || scoped.contains("temp") || scoped.contains("tmp") {
            return .simulatorLogsCaches
        }
        // 登记设备的运行数据 / 目录。
        return .simulatorDevices
    }

    /// 去掉 `~/Library/Developer/CoreSimulator/` 前缀后的路径尾部，
    /// 供分类判定使用（前缀本身含有 “CoreSimulator” 字样）。
    static func coreSimulatorPathTail(for item: CacheItem) -> String {
        let path = item.path.standardizedFileURL.path
        // `/Library/Logs/CoreSimulator/` 必须排在前面：它也包含 “CoreSimulator/”，
        // 顺序反过来会把 “Logs” 留在尾部。
        for component in ["/Library/Logs/CoreSimulator/", "/Library/Developer/CoreSimulator/"] {
            if let range = path.range(of: component) {
                return String(path[range.upperBound...])
            }
        }
        return path
    }

    /// 只处理 `category == "Xcode"` 的条目，避免与局部变量 `xcodeCategory` 同名。
    /// 返回 `nil` 表示这段文本里没有可识别的分类关键词。
    private static func legacyXcodeCategory(
        for item: CacheItem,
        statement: String
    ) -> XcodeStorageCategory? {
        // iOS Device Logs 是「设备日志」，必须先于 DeviceSupport 判定。
        if statement.contains("device logs") || statement.contains("devicelogs")
            || statement.contains("设备日志") {
            return .deviceLogs
        }
        if statement.contains("devicesupport") {
            return .deviceSupport
        }
        if statement.contains("archive") || statement.contains("归档") {
            return .archives
        }
        if statement.contains("logs") || statement.contains("日志") {
            return .xcodeLogs
        }
        if statement.contains("products") {
            return .xcodeProducts
        }
        if statement.contains("preview") {
            return .swiftUIPreviews
        }
        if statement.contains("sourcepackages") || statement.contains("swiftpm")
            || statement.contains("swift-package") || statement.contains("org.swift.swiftpm") {
            return .swiftPM
        }
        if statement.contains("deriveddata") {
            return .derivedData
        }
        if statement.contains("caches/com.apple.dt.xcode")
            || statement.contains("缓存")
            || statement.contains("cache")
            || statement.contains("modulecache")
            || statement.contains("buildcache")
            || statement.contains("instruments")
            || statement.contains("sourcekit")
            || statement.contains("documentationcache") {
            return .xcodeCaches
        }
        return nil
    }

    /// 去掉 `~/Library/` 前缀后的路径尾部，减少 “Logs/Caches” 之类通用组件的干扰。
    static func xcodePathTail(for item: CacheItem) -> String {
        let path = item.path.standardizedFileURL.path.lowercased()
        for component in ["/library/developer/xcode/", "/library/developer/",
                          "/library/caches/", "/library/logs/"] {
            if let range = path.range(of: component) {
                return String(path[range.upperBound...])
            }
        }
        return path
    }

    /// DeviceSupport 的平台名，从名称或路径尾部推断（iOS/watchOS/tvOS/macOS/visionOS）。
    static func deviceSupportPlatform(for item: CacheItem) -> String {
        let platformNames = ["iOS", "watchOS", "tvOS", "macOS", "visionOS", "xrOS"]
        let statement = item.name + " " + item.path.path
        for platform in platformNames where statement.localizedCaseInsensitiveContains(platform) {
            // 避免 "iOS" 命中 "watchOS"/"visionOS" 之类的前缀重叠：用词边界判断。
            if containsPlatformToken(platform, in: statement) {
                return platform
            }
        }
        return "其他"
    }

    private static func containsPlatformToken(_ platform: String, in text: String) -> Bool {
        guard let range = text.range(of: platform, options: .caseInsensitive) else { return false }
        // 检查前一个字符不是字母，避免 tvsOS 之类误匹配；平台名后允许空格/连字符。
        if range.lowerBound != text.startIndex {
            let previous = text[text.index(before: range.lowerBound)]
            if previous.isLetter { return false }
        }
        if range.upperBound != text.endIndex {
            let next = text[range.upperBound]
            if next.isLetter { return false }
        }
        return true
    }
}

// MARK: - 单趟快照

/// 「Xcode 空间」页面的派生数据：分类、汇总、13 行一次算完。
///
/// 早先 `XcodeStorageSummary` 与 `XcodeStorageRows.rows` 各自遍历一遍 items，
/// 且 rows 对 13 个分类各 filter 一次，等价于 13 × N 次分类判定。这两处都在
/// SwiftUI body 里被反复求值，5000 条目时单帧要 200ms 以上，页面就卡住了。
/// 现在统一成「一条目只算一次」，并且由视图缓存结果、只在该变的东西变时重算。
struct XcodeStorageSnapshot: Equatable {
    /// 一趟扫描的中间结果：分类桶 + 各类合计 + 风险小计 + DeviceSupport 分平台。
    struct Classified: Equatable {
        var byCategory: [XcodeStorageCategory: [CacheItem]] = [:]
        var bytesByCategory: [XcodeStorageCategory: Int64] = [:]
        var deviceSupportByPlatform: [String: Int64] = [:]
        var rebuildableBytes: Int64 = 0
        var reviewBytes: Int64 = 0
        var manualBytes: Int64 = 0

        func bytes(for category: XcodeStorageCategory) -> Int64 {
            bytesByCategory[category] ?? 0
        }

        /// 单趟：去重 → 分类 → 记大小 → 记风险。
        static func build(from items: [CacheItem]) -> Classified {
            var result = Classified()
            var seen = Set<String>()
            seen.reserveCapacity(items.count)
            for item in items where XcodeStorageRisk.isXcodeStorageItem(item) {
                // CacheItem.path 在 makeItem 里已标准化，这里只做字符串比较去重。
                guard seen.insert(item.path.path).inserted else { continue }
                let size = max(0, item.size)
                let category = XcodeStorageClassifier.category(for: item)
                result.byCategory[category, default: []].append(item)
                result.bytesByCategory[category, default: 0] += size
                if category == .deviceSupport {
                    result.deviceSupportByPlatform[
                        XcodeStorageClassifier.deviceSupportPlatform(for: item), default: 0
                    ] += size
                }
                switch XcodeStorageRisk.xcodeRisk(for: item) {
                case .safe: result.rebuildableBytes += size
                case .review: result.reviewBytes += size
                case .manual: result.manualBytes += size
                }
            }
            return result
        }
    }

    let classified: Classified
    let summary: XcodeStorageSummary
    let rows: [XcodeStorageRow]
    /// id → 条目。分类三态判定与清理计划都按 id 查，避免每行线性过滤大数组。
    let itemsByID: [UUID: CacheItem]

    static func empty() -> XcodeStorageSnapshot {
        build(items: [], runtimeItems: [], diskTotalBytes: nil, diskAvailableBytes: nil)
    }

    static func build(
        items: [CacheItem],
        runtimeItems: [SimulatorRuntimeSummary],
        diskTotalBytes: Int64?,
        diskAvailableBytes: Int64?
    ) -> XcodeStorageSnapshot {
        let classified = Classified.build(from: items)
        let summary = XcodeStorageSummary(
            classified: classified,
            runtimeItems: runtimeItems,
            diskTotalBytes: diskTotalBytes,
            diskAvailableBytes: diskAvailableBytes
        )
        var byID: [UUID: CacheItem] = [:]
        byID.reserveCapacity(items.count)
        for item in items { byID[item.id] = item }

        var rows: [XcodeStorageRow] = []
        rows.reserveCapacity(XcodeStorageCategory.allCases.count)
        let runtimeIDs = summary.runtimeItems.map(\.identifier)
        for category in XcodeStorageCategory.allCases {
            let matched = classified.byCategory[category] ?? []
            let size = category.isRuntimeBacked ? summary.runtimeBytes : classified.bytes(for: category)
            rows.append(XcodeStorageRow(
                id: XcodeStorageClassifier.rowID(for: category),
                title: category.title,
                subtitle: category.subtitle,
                risk: category.risk,
                sizeBytes: size,
                itemIDs: matched.map(\.id),
                runtimeIdentifiers: category.isRuntimeBacked ? runtimeIDs : [],
                isGroup: true,
                allowsAutomaticClean: category.allowsAutomaticClean
            ))
        }
        return XcodeStorageSnapshot(
            classified: classified, summary: summary, rows: rows, itemsByID: byID
        )
    }

    /// 磁盘信息变化只需要重算 summary，不重新分类。
    func withDisk(totalBytes: Int64?, availableBytes: Int64?) -> XcodeStorageSnapshot {
        guard summary.diskTotalBytes != totalBytes || summary.diskAvailableBytes != availableBytes else {
            return self
        }
        return XcodeStorageSnapshot(
            classified: classified,
            summary: XcodeStorageSummary(
                classified: classified,
                runtimeItems: summary.runtimeItems,
                diskTotalBytes: totalBytes,
                diskAvailableBytes: availableBytes
            ),
            rows: rows,
            itemsByID: itemsByID
        )
    }
}

// MARK: - 行模型

/// 一行 = 一个分类（固定 13 行）。空分类 sizeBytes 为 0。
struct XcodeStorageRow: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let risk: RiskLevel
    let sizeBytes: Int64
    /// 该行包含的 CacheItem；Runtime 行没有 CacheItem，用 runtimeIdentifiers 关联。
    let itemIDs: [UUID]
    /// 该行包含的 Runtime 标识（仅 `.runtimes` 行非空）。
    let runtimeIdentifiers: [String]
    /// 是否是可展开的分组（行本身就是分组，统一为 true）。
    let isGroup: Bool
    /// 该分类是否允许一键/定时清理。
    let allowsAutomaticClean: Bool

    /// 是否为空行（UI 可置灰但仍展示，保持固定 13 行）。
    var isEmpty: Bool {
        sizeBytes == 0 && itemIDs.isEmpty && runtimeIdentifiers.isEmpty
    }
}

enum XcodeStorageRows {
    /// 13 行，顺序固定为参考实现的默认分类顺序。
    static func rows(
        from summary: XcodeStorageSummary,
        items: [CacheItem]
    ) -> [XcodeStorageRow] {
        // 每个条目只分类一次，再按分类归并。
        //
        // 早先的写法是对 13 个分类各 `filter` 一遍全部条目，等价于 13 × N 次
        // 分类判定（每次都要 lowercased + 多次子串匹配）。5000 条时单次
        // 计算约 120ms，而这个函数在 SwiftUI body 里会被反复调用，直接表现为
        // 页面卡顿。改成单趟分组后是 O(N)。
        let storageItems = XcodeStorageSummary.xcodeStorageItems(from: items)
        var matchedByCategory: [XcodeStorageCategory: [CacheItem]] = [:]
        matchedByCategory.reserveCapacity(XcodeStorageCategory.allCases.count)
        for item in storageItems {
            matchedByCategory[XcodeStorageClassifier.category(for: item), default: []].append(item)
        }

        let runtimeIDs = summary.runtimeItems.map(\.identifier)
        return XcodeStorageCategory.allCases.map { category in
            let matched = matchedByCategory[category] ?? []
            let size: Int64
            if category.isRuntimeBacked {
                size = summary.runtimeBytes
            } else {
                size = matched.reduce(0) { $0 + max(0, $1.size) }
            }
            return XcodeStorageRow(
                id: XcodeStorageClassifier.rowID(for: category),
                title: category.title,
                subtitle: category.subtitle,
                risk: category.risk,
                sizeBytes: size,
                itemIDs: matched.map(\.id),
                runtimeIdentifiers: category.isRuntimeBacked ? runtimeIDs : [],
                isGroup: true,
                allowsAutomaticClean: category.allowsAutomaticClean
            )
        }
    }

    /// 分类的展示顺序（供视图/测试断言使用）。
    static var categoryOrder: [XcodeStorageCategory] {
        XcodeStorageCategory.allCases
    }
}

// MARK: - 活动状态与预检

/// 预检所需的活动状态。刻意不与其它模块的 XcodeActivity 同名，
/// 由调用方（扫描器/视图）负责把真实进程探测结果映射成这个枚举。
enum XcodeActivityLike: Equatable {
    case idle
    case xcodeRunning(String)
    case buildOrTestRunning(String)
    case unknown

    var displayText: String {
        switch self {
        case .idle: return "当前没有检测到 Xcode 或构建设备"
        case .xcodeRunning(let detail): return detail.isEmpty ? "Xcode 正在运行" : detail
        case .buildOrTestRunning(let detail): return detail.isEmpty ? "构建或测试正在运行" : detail
        case .unknown: return "无法确认 Xcode / 构建 / 测试状态"
        }
    }
}

/// 删除前预检结论。
enum PreflightVerdict: Equatable {
    /// 允许执行。
    case proceed(String)
    /// 允许执行，但建议先退出 Xcode / 关闭模拟器。
    case warn(String)
    /// 拒绝执行。
    case block(String)

    var text: String {
        switch self {
        case .proceed(let text): return text
        case .warn(let text): return text
        case .block(let text): return text
        }
    }

    var isBlocked: Bool {
        if case .block = self { return true }
        return false
    }

    var canProceed: Bool {
        !isBlocked
    }

    /// 主要理由的简短形式（用于按钮下方提示）。
    var shortReason: String {
        switch self {
        case .proceed: return "可以清理"
        case .warn: return "建议先退出相关进程"
        case .block: return "已阻止清理"
        }
    }
}

enum XcodeLaunchPreflight {
    /// 与构建/测试直接冲突、删除会导致构建失败或设备损坏的分类。
    static let buildSensitiveCategories: Set<XcodeStorageCategory> = [
        .derivedData,
        .runtimes,
        .deviceSupport,
        .simulatorDevices,
        .simulatorLogsCaches
    ]

    static func preflight(
        activity: XcodeActivityLike,
        targets: [CacheItem]
    ) -> PreflightVerdict {
        let categories = Set(targets.map { XcodeStorageClassifier.category(for: $0) })
        // 目标为空时也要给出一致的结论（不禁用按钮）。
        let hasBuildSensitive = !categories.isDisjoint(with: buildSensitiveCategories)
        let hasTargets = !targets.isEmpty

        switch activity {
        case .buildOrTestRunning(let detail):
            if hasBuildSensitive {
                let names = buildSensitiveCategories
                    .intersection(categories)
                    .sorted { $0.rawValue < $1.rawValue }
                    .map(\.title)
                    .joined(separator: "、")
                return .block("检测到构建/测试正在运行（\(detail.isEmpty ? "进程占用中" : detail)），"
                    + "目标包含 \(names)（DerivedData / Runtime / DeviceSupport / 模拟器相关）。"
                    + "请先结束构建或测试，再重新扫描后清理，否则可能破坏正在进行的构建或测试设备。")
            }
            if hasTargets {
                return .block("检测到构建/测试正在运行（\(detail.isEmpty ? "进程占用中" : detail)），"
                    + "清理会与正在写入的构建缓存竞争。请先结束构建或测试后再执行。")
            }
            return .block("检测到构建/测试正在运行，请先结束构建或测试后再执行清理。")

        case .xcodeRunning(let detail):
            if hasBuildSensitive {
                return .warn("Xcode 正在运行（\(detail.isEmpty ? "进程占用中" : detail)），"
                    + "目标包含 DerivedData / Runtime / DeviceSupport / 模拟器相关项。"
                    + "建议先退出 Xcode 并关闭模拟器；Xcode 持有部分文件时删除可能失败，"
                    + "但仍允许执行，不会造成不可恢复的数据损坏。")
            }
            return .warn("Xcode 正在运行（\(detail.isEmpty ? "进程占用中" : detail)），"
                + "建议先退出 Xcode 再清理，避免它立刻重建缓存、白费这次清理。仍允许执行。")

        case .unknown:
            return .warn("无法确认 Xcode、构建或测试状态。为避免破坏正在进行的任务，"
                + "建议先确认没有构建/测试在运行；本次仍允许执行，但请谨慎。")

        case .idle:
            if hasTargets {
                return .proceed("当前没有检测到 Xcode 或构建/测试进程，可以执行清理。")
            }
            return .proceed("当前没有检测到 Xcode 或构建/测试进程。")
        }
    }
}

// MARK: - 统计辅助

enum XcodeStorageMetrics {
    /// 勾选条目可回收的字节数。只统计同时满足以下三条的条目：
    /// 1. 属于 Xcode 存储分类；2. `isSelected`；3. 风险不是 `.manual`。
    /// 与 `CleanupSelection.selectedItems` 的语义保持一致。
    static func estimatedReclaimBytes(
        summary: XcodeStorageSummary,
        items: [CacheItem],
        selectedItemIDs: Set<UUID>
    ) -> Int64 {
        XcodeStorageSummary.xcodeStorageItems(from: items)
            .filter { $0.isSelected && selectedItemIDs.contains($0.id) && $0.risk != .manual }
            .reduce(0) { $0 + max(0, $1.size) }
    }

    /// 只按勾选 ID 计算的版本（不校验 `isSelected`），供已确认选择的调用方使用。
    static func reclaimBytes(items: [CacheItem], selectedItemIDs: Set<UUID>) -> Int64 {
        XcodeStorageSummary.xcodeStorageItems(from: items)
            .filter { selectedItemIDs.contains($0.id) && $0.risk != .manual }
            .reduce(0) { $0 + max(0, $1.size) }
    }

    /// 勾选条目（含可自动清理的 Runtime）的合计大小，用于「已选 N 项 · X GB」。
    static func selectedRuntimeBytes(
        summary: XcodeStorageSummary,
        selectedRuntimeIdentifiers: Set<String>
    ) -> Int64 {
        summary.runtimeItems
            .filter { $0.deletable && selectedRuntimeIdentifiers.contains($0.identifier) }
            .reduce(0) { $0 + max(0, $1.sizeBytes) }
    }

    /// 形如 `52.8 GB · 占磁盘 5.2%`；磁盘总量未知时退化为 `52.8 GB`。
    static func percentageOfDisk(_ bytes: Int64, diskTotalBytes: Int64?) -> String {
        let sizeText = max(0, bytes).devSweepFileSize
        guard let total = diskTotalBytes, total > 0 else { return sizeText }
        let ratio = Double(max(0, bytes)) / Double(total) * 100
        return sizeText + " · 占磁盘 " + formatPercent(ratio)
    }

    /// 参考实现标题格式：`Xcode 缓存 52.8 GB · 占磁盘 5.2%`。
    static func headline(
        label: String,
        bytes: Int64,
        diskTotalBytes: Int64?
    ) -> String {
        label + " " + percentageOfDisk(bytes, diskTotalBytes: diskTotalBytes)
    }

    /// 百分比文案：小于 0.1% 但非零时显示 `<0.1%`，0 显示 `0%`。
    static func formatPercent(_ value: Double) -> String {
        guard value.isFinite, value > 0 else { return "0%" }
        if value < 0.1 {
            return "<0.1%"
        }
        return String(format: "%.1f%%", value)
    }
}
