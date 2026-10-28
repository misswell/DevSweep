import Foundation

// MARK: - 模型
//
// 模拟器运行时（Simulator Runtime）是 Xcode 里体积最大的可清理内容之一：
// `xcrun simctl runtime list -j` 报告的 sizeBytes 常见在 8~10 GB。
//
// 本文件只负责「运行时的 list / delete / 验证 / 保留策略」：
// - 设备（CoreSimulator/Devices）删除走 `xcrun simctl delete <UDID>`，见 SimulatorCleanupExecutor；
// - XCTest clone 走 `~/Library/Developer/XCTestDevices` 的文件清理；
// - 运行时只走 `xcrun simctl runtime delete <identifier>`，绝不动磁盘目录。
//
// 安全规则：
// 1. 先 list 再删，删除前必须重新 list 一次，只删「最新清单里仍存在且仍可删除」的 id；
// 2. 删除后轮询 `simctl runtime list` 验证，超时未消失即视为失败，并报告 remaining；
// 3. 失败逐条可读，不吞掉部分失败；设备失败与运行时失败不混在一起；
// 4. 无法解析输出时返回 nil / 抛错，绝不默认当作「没有运行时」或「删除成功」。

/// `simctl runtime list -j` 中的单个运行时。
///
/// `deletable` 刻意保留为 `Bool?`：`nil` 表示清单没有给出可删除性（例如文本兜底解析），
/// 只有明确 `true` 才允许删除。`version` 在缺失时为空字符串，方便直接展示。
struct SimulatorRuntimeInfo: Decodable, Equatable, Hashable {
    let identifier: String
    let runtimeIdentifier: String?
    let platformIdentifier: String?
    let version: String
    let build: String?
    let deletable: Bool?
    let sizeBytes: Int64?
    let mountPath: String?
    let parentMountPath: String?
    let state: String?
    let lastUsedAt: Date?
    /// 运行时 bundle 的挂载位置（`simctl runtime list -j` 的 runtimeBundlePath），
    /// 仅用于展示与兜底命令定位，删除动作永远只认 identifier。
    let runtimeBundlePath: String?

    /// 删除时使用的唯一键：`simctl runtime delete` 只接受 identifier。
    var deletionKey: String { identifier }

    init(
        identifier: String,
        runtimeIdentifier: String? = nil,
        platformIdentifier: String? = nil,
        version: String = "",
        build: String? = nil,
        deletable: Bool? = nil,
        sizeBytes: Int64? = nil,
        mountPath: String? = nil,
        parentMountPath: String? = nil,
        state: String? = nil,
        lastUsedAt: Date? = nil,
        runtimeBundlePath: String? = nil
    ) {
        self.identifier = identifier
        self.runtimeIdentifier = runtimeIdentifier
        self.platformIdentifier = platformIdentifier
        self.version = version.trimmingCharacters(in: .whitespacesAndNewlines)
        self.build = build
        self.deletable = deletable
        self.sizeBytes = sizeBytes
        self.mountPath = mountPath
        self.parentMountPath = parentMountPath
        self.state = state
        self.lastUsedAt = lastUsedAt
        self.runtimeBundlePath = runtimeBundlePath
    }

    /// 展示用的版本号；缺失时退回 identifier。
    var displayVersion: String {
        if !version.isEmpty { return version }
        let inferred = SimulatorRuntimeListParser.version(fromName: identifier)
        return inferred.isEmpty ? identifier : inferred
    }

    /// 展示用名称，例如 `iOS 26.5 (23F77)`。
    var displayName: String {
        var name = SimulatorRuntimeCleaner.platformTitle(platformIdentifier)
        let versionText = displayVersion
        if !versionText.isEmpty, versionText != identifier {
            name += " \(versionText)"
        }
        if let build, !build.isEmpty {
            name += " (\(build))"
        }
        return name
    }

    /// 格式化体积；simctl 未报告时返回「体积未知」，不猜 0 B。
    var displaySize: String {
        guard let sizeBytes, sizeBytes > 0 else { return "体积未知" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useGB, .useMB]
        return formatter.string(fromByteCount: sizeBytes)
    }

    var isReady: Bool {
        (state ?? "").caseInsensitiveCompare("Ready") == .orderedSame
    }

    /// 系统明确不允许删除。
    var isExplicitlyNotDeletable: Bool { deletable == false }

    private enum CodingKeys: String, CodingKey {
        case identifier
        case uuid
        case runtimeIdentifier
        case bundleIdentifier
        case platformIdentifier
        case version
        case runtimeVersion
        case build
        case buildversion
        case deletable
        case sizeBytes
        case mountPath
        case parentMountPath
        case state
        case lastUsedAt
        case runtimeBundlePath
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let identifier = (try? container.decodeIfPresent(String.self, forKey: .identifier))
            ?? (try? container.decodeIfPresent(String.self, forKey: .uuid))
        else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "缺少 identifier 字段"
                )
            )
        }
        self.identifier = identifier
        self.runtimeIdentifier = Self.string(.runtimeIdentifier, in: container)
        self.platformIdentifier = Self.string(.platformIdentifier, in: container)
        self.version = Self.string(.version, in: container)
            ?? Self.string(.runtimeVersion, in: container)
            ?? ""
        self.build = Self.string(.build, in: container) ?? Self.string(.buildversion, in: container)
        // 只有真正的 JSON bool 才算；字符串或数字视为未知，避免误判可删除。
        self.deletable = (try? container.decodeIfPresent(Bool.self, forKey: .deletable)) ?? nil
        if let value = try? container.decodeIfPresent(Int64.self, forKey: .sizeBytes) {
            self.sizeBytes = value
        } else if let text = Self.string(.sizeBytes, in: container) {
            self.sizeBytes = Int64(text)
        } else {
            self.sizeBytes = nil
        }
        self.mountPath = Self.string(.mountPath, in: container)
        self.parentMountPath = Self.string(.parentMountPath, in: container)
        self.state = Self.string(.state, in: container)
        self.lastUsedAt = JSONDateDecoding.date(from: Self.string(.lastUsedAt, in: container))
        self.runtimeBundlePath = Self.string(.runtimeBundlePath, in: container)
    }

    private static func string(
        _ key: CodingKeys,
        in container: KeyedDecodingContainer<CodingKeys>
    ) -> String? {
        guard let value = try? container.decodeIfPresent(String.self, forKey: key) else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// `simctl runtime list` 的 `lastUsedAt` 是 ISO8601（例如 `2026-10-24T15:26:28Z`），
/// 也见过带小数秒的写法，两种都接受。
private enum JSONDateDecoding {
    private static let formatters: [ISO8601DateFormatter] = {
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return [plain, fractional]
    }()

    static func date(from string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        if let date = formatters[0].date(from: string) { return date }
        if let date = formatters[1].date(from: string) { return date }
        return nil
    }
}

// MARK: - 版本比较

/// 只包含数字段的版本号（`26.5`、`27.0.1`），用于「每个平台保留最新版本」的判断。
///
/// 非数字版本（文本兜底输出异常）会被 `init` 拒绝，调用方随后改为「不可删除」，
/// 而不是用字符串比较草率地保留或删除。
struct RuntimeVersion: Comparable, CustomStringConvertible, Hashable {
    let components: [Int]
    let rawValue: String

    init?(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var components: [Int] = []
        for part in trimmed.split(separator: ".") {
            guard let value = Int(part), value >= 0 else { return nil }
            components.append(value)
        }
        guard !components.isEmpty else { return nil }
        self.components = components
        self.rawValue = trimmed
    }

    var description: String { rawValue }

    static func < (lhs: RuntimeVersion, rhs: RuntimeVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }
}

// MARK: - 解析

enum SimulatorRuntimeListParser {
    /// 解析 `simctl runtime list -j`。支持三种形状：
    /// 1. 根对象本身就是 `UUID -> runtime` 的 map（macOS 26 实测形状）；
    /// 2. `{"runtimes": {UUID: runtime}}`；
    /// 3. `{"runtimes": [runtime, ...]}`。
    ///
    /// 空对象返回 `[]`；不是 JSON、或 JSON 里没有一条「看起来像运行时」的记录时返回 `nil`
    /// （调用方据此改用文本兜底，而不是把未知输出当成「没有运行时」）。
    static func parseJSON(_ output: String) -> [SimulatorRuntimeInfo]? {
        let data = Data(output.utf8)
        guard !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data)
        else { return nil }

        // `simctl` 出错时可能输出 JSON 字符串或数组，直接视为无法解析。
        guard let root = object as? [String: Any] else { return nil }
        if root.isEmpty { return [] }

        if let nested = root["runtimes"] {
            let runtimes: [SimulatorRuntimeInfo]?
            if let map = nested as? [String: Any] {
                runtimes = decoded(from: map)
            } else if let list = nested as? [Any] {
                runtimes = decoded(from: list)
            } else {
                return nil
            }
            guard let runtimes, !runtimes.isEmpty else { return nil }
            return deduplicated(runtimes)
        }

        guard let runtimes = decoded(from: root), !runtimes.isEmpty else { return nil }
        return deduplicated(runtimes)
    }

    /// 解析 `simctl runtime list` 的文本输出：
    /// `iOS 26.5 (23F77) - 10DA06ED-69CE-43AC-BC36-998873EBD095 (Ready)`。
    /// `(Ready)` 是可选的。空列表（`Total Disk Images: 0`）返回 `[]`，识别失败返回 `nil`。
    static func parseText(_ output: String) -> [SimulatorRuntimeInfo]? {
        let pattern = #"^(.+?)\s+\(([^)]*)\)\s+-\s+([^\s]+)(?:\s+\(([^)]*)\))?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }

        var runtimes: [SimulatorRuntimeInfo] = []
        for rawLine in output.split(whereSeparator: { $0.isNewline }) {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let match = regex.firstMatch(in: line, range: range) else { continue }

            func capture(_ index: Int) -> String? {
                guard index < match.numberOfRanges else { return nil }
                let captureRange = match.range(at: index)
                guard captureRange.location != NSNotFound,
                      let swiftRange = Range(captureRange, in: line)
                else { return nil }
                let value = String(line[swiftRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : value
            }

            guard let nameWithVersion = capture(1),
                  let identifier = capture(3)
            else { continue }

            let build = capture(2)
            let state = capture(4)
            runtimes.append(
                SimulatorRuntimeInfo(
                    identifier: identifier,
                    runtimeIdentifier: nil,
                    platformIdentifier: platformIdentifier(from: nameWithVersion, identifier: identifier),
                    version: version(fromName: nameWithVersion),
                    build: build,
                    deletable: nil,
                    sizeBytes: nil,
                    mountPath: nil,
                    parentMountPath: nil,
                    state: state,
                    lastUsedAt: nil,
                    runtimeBundlePath: nil
                )
            )
        }

        if !runtimes.isEmpty { return deduplicated(runtimes) }
        if output.contains("Total Disk Images: 0") { return [] }
        return nil
    }

    /// 从名称和 identifier 推断平台 identifier。
    static func platformIdentifier(from name: String, identifier: String) -> String {
        let value = "\(name) \(identifier)"
        if value.localizedCaseInsensitiveContains("watchOS")
            || value.localizedCaseInsensitiveContains("watchsimulator") {
            return "com.apple.platform.watchsimulator"
        }
        if value.localizedCaseInsensitiveContains("tvOS")
            || value.localizedCaseInsensitiveContains("appletvsimulator") {
            return "com.apple.platform.appletvsimulator"
        }
        if value.localizedCaseInsensitiveContains("xrOS")
            || value.localizedCaseInsensitiveContains("visionOS")
            || value.localizedCaseInsensitiveContains("xrsimulator") {
            return "com.apple.platform.xrsimulator"
        }
        if value.localizedCaseInsensitiveContains("iOS")
            || value.localizedCaseInsensitiveContains("iphonesimulator") {
            return "com.apple.platform.iphonesimulator"
        }
        return "unknown"
    }

    /// 从 `iOS 26.5` / `Apple TV 27.0` / `com.apple.CoreSimulator.SimRuntime.iOS-26-5`
    /// 之类的名称里取出版本号；取不到返回空字符串。
    static func version(fromName name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        // 先匹配 26.5.1 这类纯数字版本，避免被平台名里的字母干扰。
        if let range = trimmed.range(of: #"[0-9]+(\.[0-9]+)*"#, options: .regularExpression) {
            return String(trimmed[range])
        }
        // `iOS-26-5` 形式的 identifier：把 `<platform>-<major>-<minor>...` 转成 26.5。
        for prefix in ["visionOS-", "watchOS-", "xrOS-", "tvOS-", "iOS-"] {
            if let range = trimmed.range(of: prefix) {
                let remainder = String(trimmed[range.upperBound...])
                    .split(separator: "-")
                    .prefix { Int($0) != nil }
                    .joined(separator: ".")
                if !remainder.isEmpty { return remainder }
            }
        }
        return ""
    }

    /// 展示用的平台名。
    static func platformTitle(_ platformIdentifier: String?) -> String {
        switch platformIdentifier ?? "" {
        case "com.apple.platform.watchsimulator": return "watchOS"
        case "com.apple.platform.appletvsimulator": return "tvOS"
        case "com.apple.platform.xrsimulator": return "visionOS"
        case "com.apple.platform.iphonesimulator": return "iOS"
        case "", "unknown": return "未知平台"
        default: return platformIdentifier ?? "未知平台"
        }
    }

    // MARK: 私有

    private static func decoded(from map: [String: Any]) -> [SimulatorRuntimeInfo]? {
        var runtimes: [SimulatorRuntimeInfo] = []
        for (key, value) in map.sorted(by: { $0.key < $1.key }) {
            guard let dictionary = value as? [String: Any],
                  let runtime = runtime(from: dictionary, fallbackIdentifier: key)
            else { continue }
            runtimes.append(runtime)
        }
        return runtimes.isEmpty ? nil : runtimes
    }

    private static func decoded(from list: [Any]) -> [SimulatorRuntimeInfo]? {
        var runtimes: [SimulatorRuntimeInfo] = []
        for value in list {
            guard let dictionary = value as? [String: Any],
                  let runtime = runtime(from: dictionary, fallbackIdentifier: nil)
            else { continue }
            runtimes.append(runtime)
        }
        return runtimes.isEmpty ? nil : runtimes
    }

    /// 把单个 JSON 字典转成运行时；不像运行时的一律丢弃，
    /// 免得把任意 JSON（例如错误信息）当成 runtime 清单。
    private static func runtime(
        from dictionary: [String: Any],
        fallbackIdentifier: String?
    ) -> SimulatorRuntimeInfo? {
        let looksLikeRuntime = dictionary["platformIdentifier"] != nil
            || dictionary["runtimeIdentifier"] != nil
            || dictionary["version"] != nil
            || dictionary["runtimeVersion"] != nil
            || dictionary["kind"] != nil
        guard looksLikeRuntime else { return nil }

        guard let identifier = (dictionary["identifier"] as? String)
            ?? (dictionary["uuid"] as? String)
            ?? fallbackIdentifier
            ?? (dictionary["runtimeIdentifier"] as? String)
            ?? (dictionary["bundleIdentifier"] as? String),
              !identifier.isEmpty
        else { return nil }

        let name = (dictionary["name"] as? String) ?? identifier
        let rawVersion = (dictionary["version"] as? String) ?? (dictionary["runtimeVersion"] as? String)
        let resolvedVersion: String
        if let rawVersion, !rawVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            resolvedVersion = rawVersion
        } else {
            resolvedVersion = version(fromName: identifier)
        }

        return SimulatorRuntimeInfo(
            identifier: identifier,
            runtimeIdentifier: dictionary["runtimeIdentifier"] as? String,
            platformIdentifier: (dictionary["platformIdentifier"] as? String)
                ?? platformIdentifier(from: name, identifier: identifier),
            version: resolvedVersion,
            build: (dictionary["build"] as? String) ?? (dictionary["buildversion"] as? String),
            deletable: dictionary["deletable"] as? Bool,
            sizeBytes: sizeBytes(from: dictionary["sizeBytes"]),
            mountPath: dictionary["mountPath"] as? String,
            parentMountPath: dictionary["parentMountPath"] as? String,
            state: dictionary["state"] as? String,
            lastUsedAt: JSONDateDecoding.date(from: dictionary["lastUsedAt"] as? String),
            runtimeBundlePath: dictionary["runtimeBundlePath"] as? String
        )
    }

    private static func sizeBytes(from value: Any?) -> Int64? {
        switch value {
        case let number as NSNumber:
            return number.int64Value
        case let text as String:
            return Int64(text.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }

    private static func deduplicated(_ runtimes: [SimulatorRuntimeInfo]) -> [SimulatorRuntimeInfo] {
        var seen: Set<String> = []
        var result: [SimulatorRuntimeInfo] = []
        for runtime in runtimes where !seen.contains(runtime.identifier) {
            seen.insert(runtime.identifier)
            result.append(runtime)
        }
        return result
    }
}

// MARK: - simctl 命令

/// 运行时相关的 simctl 命令参数与可执行文件定位。
///
/// 所有进程都通过仓库统一的 `ProcessRunning` 启动（见 ToolCleanup.swift），
/// 不在这里直接用 `Process`，方便单元测试注入假 runner。
enum SimulatorRuntimeCommand {
    /// 最新 Xcode：`simctl runtime list -j`；旧版本只有 `simctl list runtimes`。
    static func listArguments() -> [String] { ["runtime", "list", "-j"] }

    static func listTextArguments() -> [String] { ["runtime", "list"] }

    static func jsonListArgumentCandidates() -> [[String]] {
        [
            ["runtime", "list", "-j"],
            ["list", "runtimes", "-j"],
            ["list", "-j", "runtimes"]
        ]
    }

    static func textListArgumentCandidates() -> [[String]] {
        [
            ["runtime", "list"],
            ["list", "runtimes"]
        ]
    }

    /// `simctl runtime delete <identifier>`。只接受运行时 identifier，不接受设备 UDID。
    static func deleteArguments(_ id: String) -> [String] { ["runtime", "delete", id] }

    static let systemSimctlPath =
        "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources/bin/simctl"

    static func systemSimctlURL() -> URL { URL(fileURLWithPath: systemSimctlPath) }

    /// 定位 simctl：
    /// 1. 先用 `xcrun --find simctl`（跟随当前选中的 Xcode 命令行工具）；
    /// 2. 不可用时回退到 CoreSimulator 组件自带的 simctl（Xcode 已卸载也能工作）。
    ///
    /// 找不到返回 `nil`，调用方据此给出「请安装 Xcode」的提示，而不是猜测路径。
    static func resolvedSimctlPath(
        runner: any ProcessRunning & Sendable,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL? {
        if let result = runner.run(
            executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["--find", "simctl"],
            environment: nil,
            timeout: 15
        ), !result.timedOut, result.status == 0,
           let text = String(data: result.stdout, encoding: .utf8),
           let path = text.split(whereSeparator: { $0.isNewline })
               .map(String.init)
               .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
               .first(where: { !$0.isEmpty })
        {
            let expanded = path.hasPrefix("/") ? path : home.appendingPathComponent(path).path
            if FileManager.default.isExecutableFile(atPath: expanded) {
                return URL(fileURLWithPath: expanded).standardizedFileURL
            }
        }
        if FileManager.default.isExecutableFile(atPath: systemSimctlPath) {
            return systemSimctlURL()
        }
        return nil
    }

    /// 超时：list 通常 1 秒内返回，给足 60 秒避免 Xcode 首次启动拖慢；
    /// delete 需要卸载磁盘映像并回收空间，给到 120 秒。
    static let listTimeout: TimeInterval = 60
    static let deleteTimeout: TimeInterval = 120
    static let processListTimeout: TimeInterval = 5
}

// MARK: - 错误

/// 运行时清理的用户可见错误。每条都说清「做了什么、为什么失败、下一步做什么」，
/// 不做静默失败。
enum SimulatorRuntimeCleanupError: LocalizedError, Equatable {
    /// 标识符为空或包含非法字符（防止拼出意外的 simctl 参数）。
    case invalidTarget
    /// 系统明确不允许删除。
    case notRemovable(String)
    /// 是所在平台最新版本（自动策略不允许删，避免该平台没有可用运行时）。
    case latestVersionProtected(String)
    /// 删除前复核未通过：清单里已不存在，或状态已变化。
    case notInLatestList(String)
    /// 删除后轮询超时，运行时仍然存在。
    case verificationTimedOut(remaining: [String], detail: String)
    /// `simctl runtime delete` 本身失败。
    case deleteFailed(runtime: String, detail: String, remaining: [String])
    /// 找不到 simctl / 无法运行 simctl。
    case simctlUnavailable(String)
    /// list 命令失败或输出无法解析。
    case listingFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidTarget:
            return "缺少可用的 Runtime 标识符（只接受 simctl 报告的 identifier），已拒绝删除"
        case let .notRemovable(version):
            return "Runtime \(version) 由系统提供，simctl 标记为不可移除；请到 Xcode 的 Settings > Components 中管理"
        case let .latestVersionProtected(version):
            return "Runtime \(version) 是所在平台的最新版本，删除后该平台将没有可用模拟器；如需删除请先安装更高版本"
        case let .notInLatestList(version):
            return "Runtime \(version) 已不在最新 simctl 清单中，可能刚被删除；请刷新列表后再操作"
        case let .verificationTimedOut(remaining, detail):
            var text = "删除后仍未从 simctl 列表中消失：\(remaining.joined(separator: "、"))"
            if !detail.isEmpty { text += "（\(detail)）" }
            return text + "。可重启 CoreSimulatorService 或重新登录后再试"
        case let .deleteFailed(runtime, detail, remaining):
            let left = remaining.isEmpty ? "" : "；仍存在的 Runtime：\(remaining.joined(separator: "、"))"
            return "Runtime \(runtime) 删除失败：\(detail)\(left)。可以复制兜底命令到终端重试"
        case let .simctlUnavailable(detail):
            return "无法运行 simctl：\(detail)。请确认已安装 Xcode 命令行工具（xcode-select --install）后重试"
        case let .listingFailed(detail):
            return "读取模拟器 Runtime 列表失败：\(detail)。为避免误删，本次不做任何删除"
        }
    }
}

// MARK: - 保留策略

/// 删除前的保护参数。
struct SimulatorRuntimeProtection: Equatable, Sendable {
    /// 无论版本新旧都不能删除的运行时 identifier。
    var protectedIdentifiers: Set<String>
    /// 受保护的挂载/父挂载根目录（默认取仓库通用的受保护路径）。
    var protectedRoots: [URL]

    init(
        protectedIdentifiers: Set<String> = [],
        protectedRoots: [URL]? = nil,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.protectedIdentifiers = protectedIdentifiers
        self.protectedRoots = (protectedRoots ?? DeletionValidator.defaultProtectedPaths(home: home))
            .map(\.standardizedFileURL)
    }
}

/// 保留策略的单条结果：某个运行时是否属于该平台的最新版本。
struct RuntimeRemovalCandidate: Equatable, Sendable {
    let runtime: SimulatorRuntimeInfo
    /// 该平台里版本最新的一个；最新版本默认不勾选，避免一键清理删掉唯一可用的 Runtime。
    let isLatest: Bool
    /// 不可删除的原因；`nil` 表示可删除。
    let blockReason: String?

    var isRemovable: Bool { blockReason == nil }
}

/// 保留策略的汇总结果。
struct RemovableRuntimes: Equatable, Sendable {
    /// 每个平台保留的最新运行时。
    var kept: [SimulatorRuntimeInfo]
    var removable: [SimulatorRuntimeInfo]
    /// 不可删除的运行时及原因（用于界面解释，不是错误）。
    var blocked: [(runtime: SimulatorRuntimeInfo, reason: String)]

    var removableIdentifiers: [String] { removable.map(\.identifier) }
    var removableBytes: Int64 { removable.compactMap(\.sizeBytes).reduce(0, +) }

    static func == (lhs: RemovableRuntimes, rhs: RemovableRuntimes) -> Bool {
        lhs.kept.map(\.identifier) == rhs.kept.map(\.identifier)
            && lhs.removable.map(\.identifier) == rhs.removable.map(\.identifier)
            && lhs.blocked.count == rhs.blocked.count
            && zip(lhs.blocked, rhs.blocked).allSatisfy { $0.reason == $1.reason }
    }
}

// MARK: - 清理结果

struct SimulatorRuntimeCleanupOutcome: Equatable, Sendable {
    /// 已经被 simctl 删除（或删除前就已不存在）的 identifier。
    var removed: [String]
    /// 逐条失败原因，顺序与输入一致；不会吞掉部分失败。
    var failures: [(id: String, message: String)]
    /// 删除后仍在 `simctl runtime list` 中出现的 identifier。
    var remaining: [String]

    var isSuccess: Bool { failures.isEmpty && remaining.isEmpty }

    var summary: String {
        if isSuccess { return "已删除 \(removed.count) 个模拟器 Runtime" }
        var parts: [String] = []
        if !removed.isEmpty { parts.append("已删除 \(removed.count) 个") }
        if !remaining.isEmpty { parts.append("仍有 \(remaining.count) 个未消失") }
        if !failures.isEmpty { parts.append("\(failures.count) 条失败原因见下方") }
        return parts.isEmpty ? "未执行删除" : parts.joined(separator: "，")
    }

    static func == (lhs: SimulatorRuntimeCleanupOutcome, rhs: SimulatorRuntimeCleanupOutcome) -> Bool {
        lhs.removed == rhs.removed
            && lhs.remaining == rhs.remaining
            && lhs.failures.count == rhs.failures.count
            && zip(lhs.failures, rhs.failures).allSatisfy { $0.id == $1.id && $0.message == $1.message }
    }
}

// MARK: - 清理器

enum SimulatorRuntimeCleaner {
    // MARK: 列表

    /// 读取已安装的运行时。
    ///
    /// 先尝试 JSON（`runtime list -j` 等三种参数），再退回文本输出；全部失败时抛错，
    /// 而不是返回空数组——空数组意味着「没有运行时」，会让界面误以为环境干净。
    static func installedRuntimes(
        runner: any ProcessRunning & Sendable,
        timeout: TimeInterval = SimulatorRuntimeCommand.listTimeout
    ) throws -> [SimulatorRuntimeInfo] {
        guard let simctl = SimulatorRuntimeCommand.resolvedSimctlPath(runner: runner) else {
            throw SimulatorRuntimeCleanupError.simctlUnavailable(
                "xcrun --find simctl 与系统 CoreSimulator 的 simctl 都不可用"
            )
        }

        var firstError: SimulatorRuntimeCleanupError?
        var lastOutput = ""

        for arguments in SimulatorRuntimeCommand.jsonListArgumentCandidates() {
            do {
                let output = try runList(simctl: simctl, arguments: arguments, runner: runner, timeout: timeout)
                lastOutput = output
                if let runtimes = SimulatorRuntimeListParser.parseJSON(output) { return runtimes }
            } catch let error as SimulatorRuntimeCleanupError {
                firstError = firstError ?? error
                if case .simctlUnavailable = error { throw error }
            }
        }

        for arguments in SimulatorRuntimeCommand.textListArgumentCandidates() {
            do {
                let output = try runList(simctl: simctl, arguments: arguments, runner: runner, timeout: timeout)
                lastOutput = output
                if let runtimes = SimulatorRuntimeListParser.parseText(output) { return runtimes }
            } catch let error as SimulatorRuntimeCleanupError {
                firstError = firstError ?? error
            }
        }

        if let firstError { throw firstError }
        let snippet = lastOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isNewline })
            .prefix(3)
            .joined(separator: " / ")
        throw SimulatorRuntimeCleanupError.listingFailed(
            "`simctl runtime list -j` 的输出无法解析（\(snippet.isEmpty ? "无输出" : snippet)）"
        )
    }

    // MARK: 保留策略

    /// 逐条给出「是否可删除 / 是否该平台最新版本」，供扫描器生成 CacheItem。
    ///
    /// 以下情况一律不可删除：
    /// - `deletable == false`（系统明确禁止）；
    /// - identifier 在 `protection.protectedIdentifiers` 中；
    /// - mountPath / parentMountPath 命中受保护根目录；
    /// - 状态不是 Ready（下载中/损坏的运行时不动）；
    /// - 版本号无法按数字比较。
    static func removalCandidates(
        _ runtimes: [SimulatorRuntimeInfo],
        protection: SimulatorRuntimeProtection = SimulatorRuntimeProtection()
    ) -> [RuntimeRemovalCandidate] {
        // 按平台分组。
        var groups: [String: [SimulatorRuntimeInfo]] = [:]
        var order: [String] = []
        for runtime in runtimes {
            let platform = normalizedPlatform(runtime)
            if groups[platform] == nil { order.append(platform) }
            groups[platform, default: []].append(runtime)
        }

        var results: [RuntimeRemovalCandidate] = []
        for platform in order {
            let group = groups[platform] ?? []
            var versioned: [(runtime: SimulatorRuntimeInfo, version: RuntimeVersion)] = []
            for runtime in group {
                if let reason = blockReason(runtime, protection: protection) {
                    results.append(
                        RuntimeRemovalCandidate(runtime: runtime, isLatest: false, blockReason: reason)
                    )
                    continue
                }
                guard let version = RuntimeVersion(runtime.version) else {
                    results.append(
                        RuntimeRemovalCandidate(
                            runtime: runtime,
                            isLatest: false,
                            blockReason: "无法比较版本号（\(runtime.version.isEmpty ? "未知版本" : runtime.version)），已保留"
                        )
                    )
                    continue
                }
                versioned.append((runtime, version))
            }

            guard let newest = versioned.max(by: { $0.version < $1.version }) else { continue }
            for entry in versioned {
                let isLatest = entry.runtime.identifier == newest.runtime.identifier
                results.append(
                    RuntimeRemovalCandidate(
                        runtime: entry.runtime,
                        isLatest: isLatest,
                        blockReason: isLatest ? "所在平台（\(platformTitle(entry.runtime.platformIdentifier))）的最新版本，已保留" : nil
                    )
                )
            }
        }

        // 输出顺序：平台内按版本从新到旧，便于界面展示。
        return results.sorted { lhs, rhs in
            let leftPlatform = normalizedPlatform(lhs.runtime)
            let rightPlatform = normalizedPlatform(rhs.runtime)
            if leftPlatform != rightPlatform { return leftPlatform < rightPlatform }
            let left = RuntimeVersion(lhs.runtime.version)
            let right = RuntimeVersion(rhs.runtime.version)
            if let left, let right, left != right { return left > right }
            return lhs.runtime.identifier < rhs.runtime.identifier
        }
    }

    /// 保留策略的汇总：按平台分组，每个平台保留最新版本，其余可删除。
    static func removableIdentifiers(
        _ runtimes: [SimulatorRuntimeInfo],
        protection: SimulatorRuntimeProtection = SimulatorRuntimeProtection()
    ) -> RemovableRuntimes {
        var kept: [SimulatorRuntimeInfo] = []
        var removable: [SimulatorRuntimeInfo] = []
        var blocked: [(runtime: SimulatorRuntimeInfo, reason: String)] = []

        for candidate in removalCandidates(runtimes, protection: protection) {
            if let reason = candidate.blockReason {
                if candidate.isLatest {
                    kept.append(candidate.runtime)
                } else {
                    blocked.append((candidate.runtime, reason))
                }
            } else {
                removable.append(candidate.runtime)
            }
        }

        removable.sort { lhs, rhs in
            let leftPlatform = normalizedPlatform(lhs)
            let rightPlatform = normalizedPlatform(rhs)
            if leftPlatform != rightPlatform { return leftPlatform < rightPlatform }
            return lhs.identifier < rhs.identifier
        }
        return RemovableRuntimes(kept: kept, removable: removable, blocked: blocked)
    }

    /// 某个运行时是否是所在平台的最新版本。
    /// 删除前复核用它做最后一道保护（扫描结果可能是几分钟前的）。
    static func isLatest(_ runtime: SimulatorRuntimeInfo, among runtimes: [SimulatorRuntimeInfo]) -> Bool {
        let platform = normalizedPlatform(runtime)
        let siblings = runtimes.filter { normalizedPlatform($0) == platform && RuntimeVersion($0.version) != nil }
        guard let version = RuntimeVersion(runtime.version) else { return false }
        return !siblings.contains { candidate in
            candidate.identifier != runtime.identifier
                && (RuntimeVersion(candidate.version).map { version < $0 } ?? false)
        }
    }

    /// 平台显示名（`com.apple.platform.iphonesimulator` → `iOS`）。
    static func platformTitle(_ platformIdentifier: String?) -> String {
        SimulatorRuntimeListParser.platformTitle(platformIdentifier)
    }

    // MARK: 删除

    /// 逐个删除运行时，并在删除后轮询验证。
    ///
    /// - 删除前重新 list 一次，只有「最新清单里仍存在、仍明确可删除、且仍不是该平台最新版本
    ///   或不在本平台保留位」的 identifier 才会执行删除；已经消失的 identifier 视为成功；
    /// - 每个 identifier 单独执行 `simctl runtime delete`，失败逐条记录，不影响其它项；
    /// - 删除后轮询 `simctl runtime list`，直到本次提交的都消失或超时；
    ///   超时后仍在列表中的写入 `remaining`，并在 `failures` 里逐条说明；
    /// - 本函数只处理运行时，设备（CoreSimulator/Devices）永远不会在这里被删除；
    /// - 不抛错：失败都在 `SimulatorRuntimeCleanupOutcome` 里逐条可见。
    ///
    /// `sleep` / `verifier` 用于测试注入，避免真的等待 `verificationTimeout` 秒。
    static func delete(
        identifiers: [String],
        runner: any ProcessRunning & Sendable,
        protection: SimulatorRuntimeProtection = SimulatorRuntimeProtection(),
        verificationTimeout: TimeInterval = 120,
        pollInterval: TimeInterval = 2,
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        verifier: ((Int) -> Void)? = nil
    ) -> SimulatorRuntimeCleanupOutcome {
        // 去重但保持顺序：同一个 id 只删一次。
        var seen: Set<String> = []
        let requested = identifiers.filter { id in
            guard !id.isEmpty, isValidIdentifier(id) else { return false }
            return seen.insert(id).inserted
        }
        guard !requested.isEmpty else {
            return SimulatorRuntimeCleanupOutcome(removed: [], failures: [], remaining: [])
        }

        guard let simctl = SimulatorRuntimeCommand.resolvedSimctlPath(runner: runner) else {
            let message = SimulatorRuntimeCleanupError.simctlUnavailable(
                "xcrun --find simctl 与系统 CoreSimulator 的 simctl 都不可用"
            ).localizedDescription
            return SimulatorRuntimeCleanupOutcome(
                removed: [],
                failures: requested.map { (id: $0, message: message) },
                remaining: []
            )
        }

        // 1) 删除前重新读取真实状态。
        let latest: [SimulatorRuntimeInfo]
        do {
            latest = try installedRuntimes(runner: runner)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return SimulatorRuntimeCleanupOutcome(
                removed: [],
                failures: requested.map { (id: $0, message: "删除前无法确认 Runtime 列表：\(message)") },
                remaining: []
            )
        }

        let latestByID = Dictionary(
            latest.map { ($0.identifier, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var allowedIDs: Set<String> = []
        var skipReasons: [String: String] = [:]
        for candidate in removalCandidates(latest, protection: protection) {
            if let reason = candidate.blockReason {
                skipReasons[candidate.runtime.identifier] = reason
            } else {
                allowedIDs.insert(candidate.runtime.identifier)
            }
        }

        var removed: [String] = []
        var failures: [(id: String, message: String)] = []
        var submitted: [String] = []
        var submittedRuntime: [String: SimulatorRuntimeInfo] = [:]

        for identifier in requested {
            guard let current = latestByID[identifier] else {
                // 清单里已经没有它：视为已消失（可能刚被别人/别处删掉）。
                removed.append(identifier)
                continue
            }
            if current.deletable == false {
                failures.append((identifier, "simctl 标记该 Runtime 不可移除，已跳过"))
                continue
            }
            if let reason = skipReasons[identifier] {
                failures.append((identifier, "删除前复核未通过：\(reason)"))
                continue
            }
            guard allowedIDs.contains(identifier) else {
                failures.append((identifier, "删除前复核未通过：不在本次可删除清单中，已跳过"))
                continue
            }

            guard let result = runner.run(
                executable: simctl,
                arguments: SimulatorRuntimeCommand.deleteArguments(identifier),
                environment: nil,
                timeout: SimulatorRuntimeCommand.deleteTimeout
            ) else {
                failures.append((identifier, "无法启动 simctl，已跳过此 Runtime"))
                continue
            }
            if result.timedOut {
                // 超时的删除可能已经生效，交给下面的轮询验证判定。
                submitted.append(identifier)
                submittedRuntime[identifier] = current
                continue
            }
            guard result.status == 0 else {
                let detail = outputMessage(result)
                failures.append((
                    identifier,
                    detail.isEmpty
                        ? "`simctl runtime delete` 退出码 \(result.status)"
                        : "`simctl runtime delete` 失败：\(detail)"
                ))
                continue
            }
            submitted.append(identifier)
            submittedRuntime[identifier] = current
        }

        if submitted.isEmpty {
            return SimulatorRuntimeCleanupOutcome(removed: removed, failures: failures, remaining: [])
        }

        // 2) 轮询验证：只关心本次提交的 identifier。
        let deadline = Date().addingTimeInterval(max(verificationTimeout, 0))
        var remaining = submitted
        var mountedPaths: [String] = []
        var attempt = 0
        var lastListError: String?

        while true {
            attempt += 1
            verifier?(attempt)
            do {
                let current = try installedRuntimes(runner: runner)
                let presentIDs = Set(current.map(\.identifier))
                remaining = submitted.filter { presentIDs.contains($0) }
                mountedPaths = stillMountedPaths(
                    for: submitted,
                    submittedRuntimes: submittedRuntime,
                    runner: runner
                )
                lastListError = nil
                if remaining.isEmpty && mountedPaths.isEmpty { break }
            } catch {
                lastListError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }

            if Date() >= deadline { break }
            sleep(pollInterval)
        }

        if remaining.isEmpty && mountedPaths.isEmpty {
            removed.append(contentsOf: submitted)
            return SimulatorRuntimeCleanupOutcome(removed: removed, failures: failures, remaining: [])
        }

        // 3) 超时：把「已提交但仍可见」的逐条记为失败，同时保留 remaining 汇总。
        let remainingSet = Set(remaining)
        for identifier in submitted where remainingSet.contains(identifier) {
            var message = "删除后等待 \(Int(verificationTimeout)) 秒仍未从 `simctl runtime list` 中消失"
            if !mountedPaths.isEmpty {
                message += "，磁盘映像仍挂载：\(mountedPaths.joined(separator: "、"))"
            }
            if let lastListError {
                message += "（最近一次读取列表失败：\(lastListError)）"
            }
            message += "。可重启 CoreSimulatorService 或重新登录后再试"
            failures.append((identifier, message))
        }
        return SimulatorRuntimeCleanupOutcome(
            removed: removed,
            failures: failures,
            remaining: remaining.sorted()
        )
    }

    /// 删除失败时给用户的可复制终端命令（含 simctl 路径解析、运行时列表与挂载检查）。
    static func fallbackCommands(for identifiers: [String]) -> [String] {
        let head = [
            "SIMCTL=\"$(/usr/bin/xcrun --find simctl 2>/dev/null || printf '%s' '\(SimulatorRuntimeCommand.systemSimctlPath)')\""
        ]
        let deletes = identifiers.filter { isValidIdentifier($0) }
            .map { "\"$SIMCTL\" runtime delete \($0)" }
        let tail = [
            "printf '\\n--- Runtime 列表 ---\\n'",
            "\"$SIMCTL\" runtime list",
            "printf '\\n--- 挂载的模拟器映像 ---\\n'",
            "mount | grep CoreSimulator || true"
        ]
        return head + deletes + tail
    }

    /// 界面提示文案：解释删除的后果。
    static func helpText() -> String {
        "模拟器 Runtime 是 Xcode 下载的系统镜像，单个通常占用 8~10 GB。"
            + "删除后需要重新下载，期间无法用该版本启动模拟器或跑测试。"
            + "本操作只删除 Runtime，不改动已注册的模拟器设备（设备请在模拟器页面单独关机后删除）。"
    }

    /// simctl 标识符只允许字母数字与 `.-_`，且不能以 `-` 开头（防止拼出额外参数）。
    static func isValidIdentifier(_ identifier: String) -> Bool {
        guard !identifier.isEmpty, identifier.count <= 200 else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_")
        guard identifier.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        return !identifier.hasPrefix("-")
    }

    // MARK: 私有

    private static func runList(
        simctl: URL,
        arguments: [String],
        runner: any ProcessRunning & Sendable,
        timeout: TimeInterval
    ) throws -> String {
        let command = "simctl " + arguments.joined(separator: " ")
        guard let result = runner.run(
            executable: simctl,
            arguments: arguments,
            environment: nil,
            timeout: timeout
        ) else {
            throw SimulatorRuntimeCleanupError.listingFailed("无法启动 `\(command)`")
        }
        if result.timedOut {
            throw SimulatorRuntimeCleanupError.listingFailed(
                "`\(command)` 超过 \(Int(timeout)) 秒未返回"
            )
        }
        let stdout = String(data: result.stdout, encoding: .utf8) ?? ""
        guard result.status == 0 else {
            let detail = outputMessage(result)
            throw SimulatorRuntimeCleanupError.listingFailed(
                "`\(command)` 退出码 \(result.status)\(detail.isEmpty ? "" : "：\(detail)")"
            )
        }
        return stdout
    }

    private static func outputMessage(_ result: ProcessResult) -> String {
        let stderr = String(data: result.stderr, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !stderr.isEmpty { return stderr }
        return String(data: result.stdout, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func normalizedPlatform(_ runtime: SimulatorRuntimeInfo) -> String {
        if let platform = runtime.platformIdentifier, !platform.isEmpty, platform != "unknown" {
            return platform
        }
        return SimulatorRuntimeListParser.platformIdentifier(
            from: runtime.runtimeIdentifier ?? runtime.identifier,
            identifier: runtime.identifier
        )
    }

    private static func blockReason(
        _ runtime: SimulatorRuntimeInfo,
        protection: SimulatorRuntimeProtection
    ) -> String? {
        if runtime.deletable == false {
            return "simctl 标记该 Runtime 不可移除"
        }
        if protection.protectedIdentifiers.contains(runtime.identifier)
            || runtime.runtimeIdentifier.map({ protection.protectedIdentifiers.contains($0) }) == true {
            return "Runtime 在保护名单中"
        }
        for path in [runtime.mountPath, runtime.parentMountPath].compactMap({ $0 }) {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            guard url.path.hasPrefix("/") else {
                return "Runtime 报告的挂载路径不是绝对路径，已保留"
            }
            if isProtected(url, protection: protection) {
                return "Runtime 挂载在受保护路径 \(path) 下"
            }
        }
        if let state = runtime.state, !state.isEmpty, !runtime.isReady {
            return "Runtime 当前状态为 \(state)，只在 Ready 状态才删除"
        }
        return nil
    }

    private static func isProtected(_ url: URL, protection: SimulatorRuntimeProtection) -> Bool {
        for root in protection.protectedRoots {
            let rootPath = root.standardizedFileURL.path
            if rootPath == "/" { return true }
            if url.path == rootPath || url.path.hasPrefix(rootPath + "/") { return true }
        }
        return false
    }

    /// 本次提交的 Runtime 是否仍有磁盘映像挂载在系统里。
    /// `mount` 不可用或输出无法读取时返回空数组（不据此判定失败，避免误报）。
    private static func stillMountedPaths(
        for identifiers: [String],
        submittedRuntimes: [String: SimulatorRuntimeInfo],
        runner: any ProcessRunning & Sendable
    ) -> [String] {
        let paths = identifiers.flatMap { identifier -> [String] in
            guard let runtime = submittedRuntimes[identifier] else { return [] }
            return [runtime.mountPath, runtime.parentMountPath].compactMap { $0 }
        }
        guard !paths.isEmpty,
              let result = runner.run(
                  executable: URL(fileURLWithPath: "/sbin/mount"),
                  arguments: [],
                  environment: nil,
                  timeout: SimulatorRuntimeCommand.processListTimeout
              ),
              !result.timedOut,
              result.status == 0,
              let output = String(data: result.stdout, encoding: .utf8)
        else { return [] }
        return paths.filter { output.contains(" on \($0) (") }
    }
}

// MARK: - Xcode 活动提示

/// Xcode / 构建测试活动提示。
///
/// 只用于提示用户「现在删除 Runtime 可能需要重启 Xcode」，**不是拒绝条件**：
/// Runtime 删除由 simctl 负责，Xcode 打开时也能删除，只是下次启动要重新下载。
enum XcodeActivity: Equatable, Sendable {
    case idle
    case xcodeRunning(String)
    case buildOrTestRunning(String)
    case unknown

    var isBusy: Bool {
        switch self {
        case .idle, .unknown: return false
        case .xcodeRunning, .buildOrTestRunning: return true
        }
    }

    var hint: String? {
        switch self {
        case .idle:
            return nil
        case let .xcodeRunning(detail):
            return "检测到 Xcode 正在运行（\(detail)），删除 Runtime 后建议重启 Xcode 让界面刷新"
        case let .buildOrTestRunning(detail):
            return "检测到构建或测试正在运行（\(detail)），此时删除 Runtime 可能让进行中的任务失败，建议先停止"
        case .unknown:
            return "无法确认 Xcode 是否在运行，删除 Runtime 前请自行确认没有正在进行的构建"
        }
    }
}

enum XcodeActivityInspector {
    /// 读取进程列表（`ps -axo pid=,comm=` 的输出）；`ps` 不可用返回 `nil`。
    static func processList(runner: any ProcessRunning & Sendable) -> String? {
        guard let result = runner.run(
            executable: URL(fileURLWithPath: "/bin/ps"),
            arguments: ["-axo", "pid=,comm="],
            environment: nil,
            timeout: SimulatorRuntimeCommand.processListTimeout
        ), !result.timedOut, result.status == 0,
           let output = String(data: result.stdout, encoding: .utf8),
           !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return output
    }

    /// 直接取进程列表并判定活动；`ps` 失败返回 `.unknown`。
    static func runningActivity(runner: any ProcessRunning & Sendable) -> XcodeActivity {
        runningActivity(processList: processList(runner: runner))
    }

    /// 从 `ps -axo pid=,comm=` 的输出推断 Xcode 活动。
    ///
    /// 优先级：构建/测试 > Xcode 主进程；`ps` 输出为 `nil`/空/无法解析 → `.unknown`。
    /// 单行输出也接受（例如调用方用 `tr '\n' ' '` 拼成了一行）。
    static func runningActivity(processList: String?) -> XcodeActivity {
        guard let processList else { return .unknown }
        let trimmed = processList.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .unknown }

        var xcodeDetail: String?
        var parsedAnyLine = false
        // 单行输出先按「空白 + PID + 路径」的边界重新切开。
        let normalized = trimmed.contains(where: { $0.isNewline })
            ? trimmed
            : trimmed.replacingOccurrences(
                of: #"\s+(?=\d+\s+/)"#,
                with: "\n",
                options: .regularExpression
            )

        for rawLine in normalized.split(whereSeparator: { $0.isNewline }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let fields = line.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
            guard fields.count == 2, let pid = Int32(fields[0]), pid > 0 else { continue }
            parsedAnyLine = true

            let command = String(fields[1])
            let lowered = command.lowercased()
            let base = URL(fileURLWithPath: command).lastPathComponent.lowercased()

            if isBuildOrTestProcess(base: base, lowered: lowered) {
                return .buildOrTestRunning(command)
            }
            if lowered.contains("/xcode.app/contents/macos/xcode") || base == "xcode" {
                xcodeDetail = command
                continue
            }
            if isPreviewProcess(base: base, lowered: lowered) {
                return .buildOrTestRunning(command)
            }
        }

        guard parsedAnyLine else { return .unknown }
        if let xcodeDetail { return .xcodeRunning(xcodeDetail) }
        return .idle
    }

    private static func isBuildOrTestProcess(base: String, lowered: String) -> Bool {
        switch base {
        case "xcodebuild", "xctest", "xctestagent", "swift-test", "testmanagerd":
            return true
        default:
            break
        }
        return lowered.contains("xctrunner") || base.hasPrefix("swift-test")
    }

    private static func isPreviewProcess(base: String, lowered: String) -> Bool {
        if base == "previews" || base == "previewsagent" || base == "previewagent" || base == "previewsd" {
            return true
        }
        return lowered.contains("swiftui previews") || lowered.contains("/previews/")
    }
}
