import Darwin
import Foundation

struct ProcessResult {
    let status: Int32
    let stdout: Data
    let stderr: Data
    let timedOut: Bool
}

protocol ProcessRunning {
    func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]?,
        timeout: TimeInterval
    ) -> ProcessResult?
}

struct ProcessRunner: ProcessRunning {
    static let shared = ProcessRunner()

    static func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        timeout: TimeInterval = 30
    ) -> ProcessResult? {
        shared.run(
            executable: executable,
            arguments: arguments,
            environment: environment,
            timeout: timeout
        )
    }

    func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        timeout: TimeInterval = 30
    ) -> ProcessResult? {
        let task = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        task.executableURL = executable
        task.arguments = arguments
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = outputPipe
        task.standardError = errorPipe
        if let environment {
            var mergedEnvironment = ProcessInfo.processInfo.environment
            mergedEnvironment.merge(environment) { _, new in new }
            task.environment = mergedEnvironment
        }

        var stdout = Data()
        var stderr = Data()
        let outputLock = NSLock()
        let readGroup = DispatchGroup()

        readGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            outputLock.lock()
            stdout = data
            outputLock.unlock()
            readGroup.leave()
        }
        readGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            outputLock.lock()
            stderr = data
            outputLock.unlock()
            readGroup.leave()
        }

        do {
            try task.run()
        } catch {
            outputPipe.fileHandleForReading.closeFile()
            errorPipe.fileHandleForReading.closeFile()
            readGroup.wait()
            return nil
        }

        let deadline = Date().addingTimeInterval(max(timeout, 0))
        var timedOut = false
        while task.isRunning && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }

        if task.isRunning {
            timedOut = true
            task.terminate()
            let terminationDeadline = Date().addingTimeInterval(0.25)
            while task.isRunning && Date() < terminationDeadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            }
            if task.isRunning {
                kill(task.processIdentifier, SIGKILL)
            }
        }

        task.waitUntilExit()
        readGroup.wait()
        outputLock.lock()
        let result = ProcessResult(
            status: task.terminationStatus,
            stdout: stdout,
            stderr: stderr,
            timedOut: timedOut
        )
        outputLock.unlock()
        return result
    }
}

protocol ProcessInspecting {
    func matchingProcessLines(containing token: String) -> [String]?
}

struct ProcessInspector: ProcessInspecting {
    let processRunner: ProcessRunning

    init(processRunner: ProcessRunning = ProcessRunner.shared) {
        self.processRunner = processRunner
    }

    func matchingProcessLines(containing token: String) -> [String]? {
        guard let result = processRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/pgrep"),
            arguments: ["-af", token],
            environment: nil,
            timeout: 2
        ), !result.timedOut else {
            return nil
        }

        if result.status == 1 && result.stdout.isEmpty {
            return []
        }
        guard result.status == 0 else { return nil }
        return String(data: result.stdout, encoding: .utf8)?
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { line in
                !line.contains("/pgrep ") && !line.hasSuffix(" pgrep")
            }
    }
}

protocol ExecutableLocating {
    func executableURL(named name: String, environment: [String: String]) -> URL?
}

struct ExecutableLocator: ExecutableLocating {
    func executableURL(named name: String, environment: [String: String]) -> URL? {
        let pathEntries = environment["PATH"]?
            .split(separator: ":")
            .map(String.init) ?? []
        let standardCandidates: [URL]
        switch name {
        case "gh":
            standardCandidates = [
                URL(fileURLWithPath: "/opt/homebrew/bin/gh"),
                URL(fileURLWithPath: "/usr/local/bin/gh")
            ]
        case "pnpm":
            standardCandidates = [
                URL(fileURLWithPath: "/opt/homebrew/bin/pnpm"),
                URL(fileURLWithPath: "/usr/local/bin/pnpm")
            ]
        case "uv":
            standardCandidates = [
                URL(fileURLWithPath: "/opt/homebrew/bin/uv"),
                URL(fileURLWithPath: "/usr/local/bin/uv")
            ]
        default:
            standardCandidates = []
        }

        let candidates = pathEntries.map {
            URL(fileURLWithPath: $0).appendingPathComponent(name)
        } + standardCandidates
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}

enum ToolCleanupError: LocalizedError, Equatable {
    case executableUnavailable(String)
    case processStateUnavailable(String)
    case processBusy(String)
    case unsafeCachePath
    case commandFailed(String)
    case commandTimedOut(String)

    var errorDescription: String? {
        switch self {
        case .executableUnavailable(let name): return "\(name) 不可用"
        case .processStateUnavailable(let name): return "无法可靠确认 \(name) 是否正在运行"
        case .processBusy(let name): return "\(name) 正在运行，已跳过清理"
        case .unsafeCachePath: return "工具报告的缓存路径不安全"
        case .commandFailed(let message): return message
        case .commandTimedOut(let name): return "\(name) 清理命令超时"
        }
    }
}

enum GitHubCLISupport {
    static func executableURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        locator: ExecutableLocating = ExecutableLocator()
    ) -> URL? {
        locator.executableURL(named: "gh", environment: environment)
    }

    static func cacheURL(home: URL, environment: [String: String]) -> URL? {
        let path: URL?
        if let value = environment["XDG_CACHE_HOME"] {
            path = absoluteSafePath(value, home: home)
                .map { $0.appendingPathComponent("gh") }
        } else {
            let candidates = [
                home.appendingPathComponent(".cache/gh"),
                home.appendingPathComponent("Library/Caches/gh")
            ]
            path = candidates.first { FileManager.default.fileExists(atPath: $0.path) }
        }
        guard let path else { return nil }
        return safeCacheLeaf(path, home: home)
    }

    static func clearCache(
        executable: URL,
        environment: [String: String]? = nil,
        processRunner: ProcessRunning = ProcessRunner.shared
    ) throws {
        guard let result = processRunner.run(
            executable: executable,
            arguments: ["config", "clear-cache"],
            environment: environment,
            timeout: 30
        ) else {
            throw ToolCleanupError.executableUnavailable("GitHub CLI")
        }
        try check(result, name: "GitHub CLI")
    }
}

enum PnpmSupport {
    static func executableURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        locator: ExecutableLocating = ExecutableLocator()
    ) -> URL? {
        locator.executableURL(named: "pnpm", environment: environment)
    }

    static func storeURL(
        executable: URL,
        home: URL,
        environment: [String: String]? = nil,
        processRunner: ProcessRunning = ProcessRunner.shared
    ) -> URL? {
        guard let result = processRunner.run(
            executable: executable,
            arguments: ["store", "path"],
            environment: environment,
            timeout: 5
        ), result.status == 0, !result.timedOut,
        let output = String(data: result.stdout, encoding: .utf8),
        let path = output.split(whereSeparator: \.isNewline)
            .map(String.init)
            .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { $0.hasPrefix("/") })
        else { return nil }
        return safeCacheLeaf(URL(fileURLWithPath: path), home: home)
    }

    static func pruneStore(
        executable: URL,
        environment: [String: String]? = nil,
        processRunner: ProcessRunning = ProcessRunner.shared
    ) throws {
        guard let result = processRunner.run(
            executable: executable,
            arguments: ["store", "prune"],
            environment: environment,
            timeout: 30
        ) else {
            throw ToolCleanupError.executableUnavailable("pnpm")
        }
        try check(result, name: "pnpm")
    }
}

enum UVSupport {
    static func executableURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        locator: ExecutableLocating = ExecutableLocator()
    ) -> URL? {
        locator.executableURL(named: "uv", environment: environment)
    }

    static func cacheURL(
        executable: URL,
        home: URL,
        environment: [String: String]? = nil,
        processRunner: ProcessRunning = ProcessRunner.shared
    ) -> URL? {
        guard let result = processRunner.run(
            executable: executable,
            arguments: ["cache", "dir"],
            environment: environment,
            timeout: 5
        ), result.status == 0, !result.timedOut,
        let output = String(data: result.stdout, encoding: .utf8),
        let path = output.split(whereSeparator: \.isNewline)
            .map(String.init)
            .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { $0.hasPrefix("/") })
        else { return nil }
        return safeCacheLeaf(URL(fileURLWithPath: path), home: home)
    }

    static func pruneCache(
        executable: URL,
        environment: [String: String]? = nil,
        processRunner: ProcessRunning = ProcessRunner.shared
    ) throws {
        guard let result = processRunner.run(
            executable: executable,
            arguments: ["cache", "prune"],
            environment: environment,
            timeout: 30
        ) else {
            throw ToolCleanupError.executableUnavailable("uv")
        }
        try check(result, name: "uv")
    }
}

protocol ToolCommandExecuting {
    func execute(action: ToolCleanupAction, cacheRoot: URL) throws
}

struct ToolCleanupExecutor: ToolCommandExecuting {
    let environment: [String: String]
    let home: URL
    let processRunner: ProcessRunning
    let processInspector: ProcessInspecting
    let executableLocator: ExecutableLocating

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        processRunner: ProcessRunning = ProcessRunner.shared,
        processInspector: ProcessInspecting? = nil,
        executableLocator: ExecutableLocating = ExecutableLocator()
    ) {
        self.environment = environment
        self.home = home
        self.processRunner = processRunner
        self.processInspector = processInspector ?? ProcessInspector(processRunner: processRunner)
        self.executableLocator = executableLocator
    }

    func execute(action: ToolCleanupAction, cacheRoot: URL) throws {
        switch action {
        case .githubCLI:
            guard let executable = GitHubCLISupport.executableURL(
                environment: environment,
                locator: executableLocator
            ) else {
                throw ToolCleanupError.executableUnavailable("GitHub CLI")
            }
            try ensureNotBusy("GitHub CLI", token: "gh")
            guard GitHubCLISupport.cacheURL(home: home, environment: environment)?.standardizedFileURL.path
                    == cacheRoot.standardizedFileURL.path
            else {
                throw ToolCleanupError.unsafeCachePath
            }
            try GitHubCLISupport.clearCache(
                executable: executable,
                environment: environment,
                processRunner: processRunner
            )
        case .pnpmStore:
            guard let executable = PnpmSupport.executableURL(
                environment: environment,
                locator: executableLocator
            ) else {
                throw ToolCleanupError.executableUnavailable("pnpm")
            }
            try ensureNotBusy("pnpm", token: "pnpm")
            guard PnpmSupport.storeURL(
                executable: executable,
                home: home,
                environment: environment,
                processRunner: processRunner
            )?.standardizedFileURL.path == cacheRoot.standardizedFileURL.path
            else {
                throw ToolCleanupError.unsafeCachePath
            }
            try PnpmSupport.pruneStore(
                executable: executable,
                environment: environment,
                processRunner: processRunner
            )
        case .uvCache:
            guard let executable = UVSupport.executableURL(
                environment: environment,
                locator: executableLocator
            ) else {
                throw ToolCleanupError.executableUnavailable("uv")
            }
            try ensureNotBusy("uv", token: "uv")
            guard UVSupport.cacheURL(
                executable: executable,
                home: home,
                environment: environment,
                processRunner: processRunner
            )?.standardizedFileURL.path == cacheRoot.standardizedFileURL.path
            else {
                throw ToolCleanupError.unsafeCachePath
            }
            try UVSupport.pruneCache(
                executable: executable,
                environment: environment,
                processRunner: processRunner
            )
        case .condaCache, .nixGarbageCollection:
            throw ToolCleanupError.commandFailed("\(action.displayName) 官方清理命令尚未启用")
        }
    }

    private func ensureNotBusy(_ name: String, token: String) throws {
        guard let lines = processInspector.matchingProcessLines(containing: token) else {
            throw ToolCleanupError.processStateUnavailable(name)
        }
        guard lines.isEmpty else {
            throw ToolCleanupError.processBusy(name)
        }
    }
}

private func absoluteSafePath(_ value: String, home: URL) -> URL? {
    let expanded = NSString(string: value.trimmingCharacters(in: .whitespacesAndNewlines))
        .expandingTildeInPath
    guard expanded.hasPrefix("/"), !expanded.isEmpty else { return nil }
    let path = URL(fileURLWithPath: expanded).standardizedFileURL
    let protected = DeletionValidator.defaultProtectedPaths(home: home)
    guard !protected.contains(where: { $0.standardizedFileURL.path == path.path }) else { return nil }
    return path
}

private func safeCacheLeaf(_ url: URL, home: URL) -> URL? {
    let path = url.standardizedFileURL
    guard path.isFileURL, path.path != "/", path.path != home.standardizedFileURL.path else { return nil }
    let protected = DeletionValidator.defaultProtectedPaths(home: home)
    guard !protected.contains(where: { $0.standardizedFileURL.path == path.path }) else { return nil }
    return path
}

private func check(_ result: ProcessResult, name: String) throws {
    if result.timedOut {
        throw ToolCleanupError.commandTimedOut(name)
    }
    guard result.status == 0 else {
        let message = String(data: result.stderr, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        throw ToolCleanupError.commandFailed(
            message?.isEmpty == false ? message! : "\(name) 清理命令失败"
        )
    }
}
