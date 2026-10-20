import Foundation

struct SimulatorCleanupDevice: Decodable {
    let udid: String
    let name: String
    let state: String
    let dataPath: String?
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
