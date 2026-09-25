import Foundation

/// XCTest 测试活动的三态模型：
/// - idle：当前没有 XCTest / UI 测试在运行，明确识别的 clone 可以自动清理；
/// - running：检测到测试相关进程，运行中的 clone 不得清理；
/// - unknown：进程状态不可知（ps 失败、超时、输出不可解析），必须保守处理，
///   禁止自动清理，绝不能在无法判断时默认当作安全。
enum XCTestActivityState: Equatable {
    case idle
    case running(reason: String)
    case unknown
}

protocol XCTestActivityInspecting {
    func currentState() -> XCTestActivityState
}

/// 清理 XCTestDevices 内容时的二次确认失败原因。
enum XCTestCleanupError: LocalizedError, Equatable {
    case testsRunning
    case activityStateUnavailable

    var errorDescription: String? {
        switch self {
        case .testsRunning:
            return "XCTest/UI 测试正在运行，已跳过此项目。"
        case .activityStateUnavailable:
            return "无法确认 XCTest 运行状态，为避免影响测试，已跳过此项目。"
        }
    }
}

/// XCTest clone 删除前的路径定位。只有 ~/Library/Developer/XCTestDevices 下的
/// 项目需要二次确认；~/Library/Developer/CoreSimulator/Devices 是真实登记的
/// 模拟器，继续由 simctl 管理，两者不能合并处理。
enum XCTestDeviceLocator {
    static func devicesRoot(home: URL) -> URL {
        home.appendingPathComponent("Library/Developer/XCTestDevices")
    }

    static func isXCTestDevicesPath(_ path: URL, home: URL) -> Bool {
        isInside(path, of: devicesRoot(home: home))
    }

    static func isInside(_ path: URL, of root: URL) -> Bool {
        let pathString = path.standardizedFileURL.path
        let rootString = root.standardizedFileURL.path
        return pathString == rootString || pathString.hasPrefix(rootString + "/")
    }
}

/// 通过一次 `ps` 快照推导 XCTest 是否正在运行。普通 `xcodebuild build`、
/// `xcodebuild archive`、`-showBuildSettings` 以及"只是开着 Xcode"都不算
/// 测试运行，避免 XCTestDevices 永远无法清理。
struct XCTestActivityInspector: XCTestActivityInspecting {
    let processRunner: ProcessRunning

    init(processRunner: ProcessRunning = ProcessRunner.shared) {
        self.processRunner = processRunner
    }

    func currentState() -> XCTestActivityState {
        guard let result = processRunner.run(
            executable: URL(fileURLWithPath: "/bin/ps"),
            arguments: ["-axo", "pid=,command="],
            environment: nil,
            timeout: 5
        ), !result.timedOut else {
            return .unknown
        }
        guard result.status == 0,
              let output = String(data: result.stdout, encoding: .utf8) else {
            return .unknown
        }
        return Self.analyze(processList: output)
    }

    /// 纯函数分析：任何一行命中测试特征即判定 running，否则 idle。
    static func analyze(processList: String) -> XCTestActivityState {
        for line in processList.split(whereSeparator: \.isNewline) {
            if let reason = runningReason(in: String(line)) {
                return .running(reason: reason)
            }
        }
        return .idle
    }

    static func runningReason(in line: String) -> String? {
        if isXcodebuildCommandLine(line), let action = xcodebuildTestAction(in: line) {
            return "xcodebuild \(action)"
        }
        if containsStandaloneToken("xctest", in: line) { return "xctest" }
        if containsStandaloneToken("xctrunner", in: line) { return "XCTRunner" }
        if containsStandaloneToken("xctestagent", in: line) { return "XCTestAgent" }
        return nil
    }

    private static func isXcodebuildCommandLine(_ line: String) -> Bool {
        line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            .contains(where: { isXcodebuildToken(String($0)) })
    }

    private static func isXcodebuildToken(_ token: String) -> Bool {
        let lowered = token.lowercased()
        return lowered == "xcodebuild" || lowered.hasSuffix("/xcodebuild")
    }

    private static let xcodebuildTestActions: Set<String> = [
        "test", "test-without-building"
    ]

    /// xcodebuild 的大量选项都会消耗一个独立的值（`-destination` 的值通常不带
    /// `-` 前缀，还可能被空格拆成多个 token），只有不处于选项值位置的裸 token
    /// 才可能是命令行动作。
    private static let xcodebuildValueOptions: Set<String> = [
        "-project", "-workspace", "-scheme", "-destination", "-sdk", "-configuration",
        "-target", "-derivedDataPath", "-resultBundlePath", "-archivePath", "-exportPath",
        "-exportOptionsPlist", "-xcconfig", "-toolchain", "-arch", "-jobs",
        "-parallel-testing-enabled", "-parallel-testing-worker-count",
        "-maximum-parallel-testing-workers", "-testPlan", "-test-timeouts-enabled",
        "-only-testing", "-skip-testing", "-testLanguage", "-testRegion",
        "-default-test-run", "-testRunStorageDirectory"
    ]

    static func xcodebuildTestAction(in line: String) -> String? {
        let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let buildIndex = tokens.firstIndex(where: { isXcodebuildToken($0) }) else { return nil }
        var previousWasValueOption = false
        for token in tokens[(tokens.index(after: buildIndex))...] {
            if previousWasValueOption {
                previousWasValueOption = false
                continue
            }
            if token.hasPrefix("-") {
                previousWasValueOption = xcodebuildValueOptions.contains(token.lowercased())
                continue
            }
            let lowered = token.lowercased()
            if xcodebuildTestActions.contains(lowered) { return lowered }
        }
        return nil
    }

    /// 关键字必须以独立 token 出现：`XCTestAgent` 不应命中 `xctest`，
    /// `XCTestDevices/...` 路径也不应命中，避免把无关进程误判成测试运行。
    private static func containsStandaloneToken(_ token: String, in line: String) -> Bool {
        let lowered = line.lowercased()
        let needle = token.lowercased()
        guard !needle.isEmpty else { return false }
        var searchStart = lowered.startIndex
        while let range = lowered.range(of: needle, range: searchStart..<lowered.endIndex) {
            let beforeIsWord = range.lowerBound > lowered.startIndex
                && isWordCharacter(lowered[lowered.index(before: range.lowerBound)])
            let afterIsWord = range.upperBound < lowered.endIndex
                && isWordCharacter(lowered[range.upperBound])
            if !beforeIsWord && !afterIsWord {
                return true
            }
            searchStart = range.upperBound
        }
        return false
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }
}
