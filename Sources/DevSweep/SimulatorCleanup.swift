import Foundation

struct SimulatorCleanupDevice: Decodable {
    let udid: String
    let name: String
    let state: String
    let dataPath: String?
}

/// 扫描阶段只需要「装了哪些 Runtime」，删除动作不在这里发生。
///
/// 必须走 `xcrun simctl runtime list`：Runtime 以 disk image 形式挂载，
/// 只有 CoreSimulator 自己知道哪个版本占用多少空间、哪个版本还能删。
/// 用协议注入是为了让扫描测试不依赖真实 Xcode 环境。
protocol SimulatorRuntimeListing: Sendable {
    func runtimes() throws -> [SimulatorRuntimeInfo]
}

struct SimulatorRuntimeLister: SimulatorRuntimeListing {
    var runner: any ProcessRunning & Sendable = ProcessRunner.shared

    func runtimes() throws -> [SimulatorRuntimeInfo] {
        try SimulatorRuntimeCleaner.installedRuntimes(runner: runner)
    }
}

enum SimulatorCleanupError: LocalizedError {
    case unavailable
    case missing
    case active
    case buildOrTestRunning
    case invalidTarget

    var errorDescription: String? {
        switch self {
        case .unavailable: return "无法确认模拟器或构建/测试状态，已跳过；请稍后刷新"
        case .missing: return "设备已失效：未在 simctl 登记列表中找到此 UDID"
        case .active: return "设备未关机，已跳过；请先在后台进程页关闭模拟器"
        case .buildOrTestRunning: return "检测到构建或测试正在运行，已跳过模拟器设备"
        case .invalidTarget: return "模拟器 UDID、目录或设备身份不匹配，已拒绝删除"
        }
    }
}

protocol SimulatorCleanupInspecting: Sendable {
    func devices() throws -> [SimulatorCleanupDevice]
    func activityProtection() throws -> String?
}

protocol SimulatorCleanupExecuting: Sendable {
    func delete(_ item: CacheItem, context: DeletionContext) throws
}

/// Only an exact registered UDID can be deleted. Never trash a simulator directory.
struct SimulatorCleanupExecutor: SimulatorCleanupInspecting, SimulatorCleanupExecuting {
    var runner: any ProcessRunning & Sendable = ProcessRunner.shared

    static func matches(path: URL, udid: String?, home: URL) -> Bool {
        guard let udid, UUID(uuidString: udid) != nil else { return false }
        return path.standardizedFileURL.path == home.appendingPathComponent(
            "Library/Developer/CoreSimulator/Devices/\(udid)"
        ).standardizedFileURL.path
    }

    func devices() throws -> [SimulatorCleanupDevice] {
        struct List: Decodable { let devices: [String: [SimulatorCleanupDevice]] }
        let output = try command("/usr/bin/xcrun", ["simctl", "list", "devices", "--json"])
        guard let list = try? JSONDecoder().decode(List.self, from: output.stdout) else {
            throw SimulatorCleanupError.unavailable
        }
        let devices = list.devices.values.flatMap { $0 }
        guard devices.allSatisfy({ UUID(uuidString: $0.udid) != nil }),
              Set(devices.map(\.udid)).count == devices.count else {
            throw SimulatorCleanupError.unavailable
        }
        return devices
    }

    func activityProtection() throws -> String? {
        let output = try command("/bin/ps", ["-axo", "pid=,comm="])
        guard let text = String(data: output.stdout, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SimulatorCleanupError.unavailable
        }
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
            guard fields.count == 2, let pid = Int32(fields[0]), pid > 0 else {
                throw SimulatorCleanupError.unavailable
            }
            let name = URL(fileURLWithPath: String(fields[1])).lastPathComponent.lowercased()
            if name == "xcodebuild" || name == "xctest" || name == "xctestagent"
                || name.contains("xctrunner") || name == "swift-test" {
                return SimulatorCleanupError.buildOrTestRunning.localizedDescription
            }
        }
        return nil
    }

    func delete(_ item: CacheItem, context: DeletionContext) throws {
        guard item.kind == .simulatorDevice,
              Self.matches(path: item.path, udid: item.identifier, home: context.home),
              let udid = item.identifier else { throw SimulatorCleanupError.invalidTarget }
        try DeletionValidator.validate(item: item, context: context)
        guard !context.whitelistedPaths.contains(where: {
            XCTestDeviceLocator.isInside($0, of: item.path)
        }) else { throw DeletionValidationError.whitelisted }
        guard try activityProtection() == nil else { throw SimulatorCleanupError.buildOrTestRunning }
        guard let device = try devices().first(where: { $0.udid == udid }) else {
            throw SimulatorCleanupError.missing
        }
        guard device.state == "Shutdown" else { throw SimulatorCleanupError.active }
        if let dataPath = device.dataPath,
           URL(fileURLWithPath: dataPath).standardizedFileURL.path != item.path.appendingPathComponent("data").standardizedFileURL.path {
            throw SimulatorCleanupError.invalidTarget
        }
        // The dialog may have stayed open for minutes; validate immediately before deletion.
        try DeletionValidator.validate(item: item, context: context)
        _ = try command("/usr/bin/xcrun", ["simctl", "delete", udid])
    }

    private func command(_ executable: String, _ arguments: [String]) throws -> ProcessResult {
        guard let result = runner.run(
            executable: URL(fileURLWithPath: executable), arguments: arguments,
            environment: nil, timeout: executable == "/bin/ps" ? 5 : 30
        ), !result.timedOut, result.status == 0 else { throw SimulatorCleanupError.unavailable }
        return result
    }
}

/// Runtime 删除动作。和模拟器设备一样：只认 simctl 标识符，永远不直接删目录。
protocol SimulatorRuntimeDeleting: Sendable {
    func delete(_ item: CacheItem, context: DeletionContext) throws
}

/// 单个 Runtime 的删除执行器。
///
/// 顺序刻意保守：
/// 1. 校验 kind / identifier（只接受单一路径组件，拒绝 `--help` 之类的参数注入）；
/// 2. 白名单优先，命中即拒绝；
/// 3. 重新列一次真实清单。已经消失 = 视为成功；这段时间里它变成了本平台
///    最新版本、或被 simctl 标记为不可删除，都拒绝执行（扫描结果可能已过期）；
/// 4. 交给 `SimulatorRuntimeCleaner.delete` 做「先 list、再删、删后轮询验证」；
/// 5. 失败时把逐条原因包装成用户可读错误，绝不静默吞掉。
struct SimulatorRuntimeDeletingExecutor: SimulatorRuntimeDeleting {
    var runner: any ProcessRunning & Sendable = ProcessRunner.shared
    /// 删除后等待 CoreSimulator 真正卸载镜像的最长时间；超时才算失败。
    var verificationTimeout: TimeInterval = 120
    var pollInterval: TimeInterval = 2
    var sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }

    func delete(_ item: CacheItem, context: DeletionContext) throws {
        guard item.kind == .simulatorRuntime,
              let identifier = item.identifier,
              Self.isValidIdentifier(identifier) else {
            throw SimulatorRuntimeLookupError.invalidTarget
        }
        guard !PathWhitelist.contains(item.path, in: context.whitelistedPaths) else {
            throw DeletionValidationError.whitelisted
        }

        let installed: [SimulatorRuntimeInfo]
        do {
            installed = try SimulatorRuntimeCleaner.installedRuntimes(runner: runner)
        } catch let error as SimulatorRuntimeCleanupError {
            throw SimulatorRuntimeLookupError.listFailed(error.localizedDescription)
        }
        guard let current = installed.first(where: { $0.identifier == identifier }) else {
            // 已经不存在等于已经清理完成。
            return
        }
        let label = current.displayName
        // 只有「明确不可删除」才直接拒绝：simctl 标记不可移除、或落在保护根目录下。
        if let reason = SimulatorRuntimeCleaner.removalCandidates(installed)
            .first(where: { $0.runtime.identifier == identifier })?.blockReason,
           !(SimulatorRuntimeCleaner.removalCandidates(installed)
                .first(where: { $0.runtime.identifier == identifier })?.isLatest ?? false) {
            throw SimulatorRuntimeLookupError.stillProtected(runtime: label, reason: reason)
        }

        // 用户可能明确选择删掉某平台的唯一版本。允许，但要在结果里说清楚：
        // 该平台将没有可用模拟器（而不是静默删掉让人下次开机才发现）。
        let siblings = installed.filter {
            SimulatorRuntimeCleaner.platformTitle($0.platformIdentifier)
                == SimulatorRuntimeCleaner.platformTitle(current.platformIdentifier)
        }
        if siblings.count <= 1 {
            throw SimulatorRuntimeLookupError.lastRuntimeOfPlatform(runtime: label)
        }

        let outcome = SimulatorRuntimeCleaner.delete(
            identifiers: [identifier],
            runner: runner,
            verificationTimeout: verificationTimeout,
            pollInterval: pollInterval,
            sleep: sleep
        )
        guard outcome.isSuccess else {
            let detail = outcome.failures.first?.message
                ?? "删除后仍在运行：运行时列表里仍能看到它"
            throw SimulatorRuntimeLookupError.deletionFailed(
                runtime: label,
                detail: detail,
                remaining: outcome.remaining
            )
        }
    }

    /// simctl 既接受 UUID 也接受 SimRuntime bundle id；两者都必须是单一路径组件，
    /// 且不能以 `-` 开头（否则会被 simctl 当成选项）。
    static func isValidIdentifier(_ identifier: String) -> Bool {
        guard !identifier.isEmpty, identifier.count <= 200, !identifier.hasPrefix("-") else {
            return false
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_")
        return identifier.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}

/// Runtime 删除的用户可见错误。每条都说清「哪个 Runtime、为什么、下一步做什么」，
/// 不做静默失败；失败信息可以直接展示在清理结果里。
enum SimulatorRuntimeLookupError: LocalizedError, Equatable {
    case invalidTarget
    case listFailed(String)
    case stillProtected(runtime: String, reason: String)
    case lastRuntimeOfPlatform(runtime: String)
    case deletionFailed(runtime: String, detail: String, remaining: [String])

    var errorDescription: String? {
        switch self {
        case .invalidTarget:
            return "缺少可用的 Runtime 标识符，已拒绝删除"
        case let .listFailed(detail):
            return "清理前无法确认模拟器 Runtime 列表：\(detail)"
        case let .stillProtected(runtime, reason):
            return "Runtime \(runtime) 已跳过：\(reason)"
        case let .lastRuntimeOfPlatform(runtime):
            return "\(runtime) 是所在平台仅剩的 Runtime，删除后该平台将没有可用模拟器；"
                + "如确实需要删除，请先装一个更高版本的 Runtime 再来清理"
        case let .deletionFailed(runtime, detail, remaining):
            let left = remaining.isEmpty ? "" : "；仍存在的 Runtime：\(remaining.joined(separator: ", "))"
            return "Runtime \(runtime) 删除失败：\(detail)\(left)。可以复制兜底命令到终端重试"
        }
    }
}
