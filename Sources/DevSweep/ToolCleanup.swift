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

struct ProcessRunner: ProcessRunning, Sendable {
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
        ProcessGroupExecutor.execute(
            executable: executable,
            arguments: arguments,
            environment: environment,
            timeout: timeout
        )?.result
    }
}

/// 一次外部命令执行的结果。`cancelled` 与 `timedOut` 分开保留，
/// 因为调用方对「等够了」和「被取消」的处理不同。
struct ProcessGroupOutcome {
    let result: ProcessResult
    let cancelled: Bool
}

/// 外部命令执行器：子进程运行在独立进程组里，超时就结束**整个进程组**，
/// 管道读取永远带期限。这样「父进程退出但后代进程仍握着 stdout」不会再把调用方卡死。
enum ProcessGroupExecutor {
    /// 进程退出后等待管道 EOF 的宽限。超过就强杀仍握着管道的进程，带着部分输出返回。
    static let drainGrace: TimeInterval = 2
    /// SIGTERM 之后等它自己退出的宽限。
    static let terminateGrace: TimeInterval = 0.25
    /// SIGKILL 之后等回收的宽限。
    static let killGrace: TimeInterval = 1

    static func execute(
        executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        timeout: TimeInterval,
        onStdoutChunk: ((Data) -> Void)? = nil,
        onStderrChunk: ((Data) -> Void)? = nil,
        isCancelled: (() -> Bool)? = nil
    ) -> ProcessGroupOutcome? {
        guard let spawned = ProcessGroupSpawner.spawn(
            executable: executable,
            arguments: arguments,
            environment: environment
        ) else { return nil }

        let pid = spawned.pid

        // POSIX_SPAWN_SETPGROUP(pgroup: 0) 让子进程用自身 pid 当新进程组 id，
        // 所以进程组号就是 pid（取不到时按 pid 兜底，规则一致）。
        let group = getpgid(pid) > 1 ? getpgid(pid) : pid

        let stdoutReader = BoundedPipeReader(fd: spawned.stdoutFD, chunkHandler: onStdoutChunk)
        let stderrReader = BoundedPipeReader(fd: spawned.stderrFD, chunkHandler: onStderrChunk)
        stdoutReader.start()
        stderrReader.start()

        let deadline = Date().addingTimeInterval(max(timeout, 0))
        var cancelled = false
        var waitStatus: Int32 = 0
        var reaped = false

        while true {
            if let status = reapIfExited(pid: pid) {
                waitStatus = status
                reaped = true
                break
            }
            if isCancelled?() == true {
                cancelled = true
                break
            }
            if Date() >= deadline { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }

        var timedOut = false
        if !reaped {
            timedOut = !cancelled
            // 先礼后兵：SIGTERM 发给整个进程组（孙进程一起收），宽限后整组 SIGKILL。
            signalGroup(group: group, pid: pid, signal: SIGTERM)
            if let status = waitForExit(pid: pid, within: terminateGrace) {
                waitStatus = status
                reaped = true
            } else {
                signalGroup(group: group, pid: pid, signal: SIGKILL)
                if let status = waitForExit(pid: pid, within: killGrace) {
                    waitStatus = status
                    reaped = true
                }
            }
            if !reaped {
                // SIGKILL 之后仍没回收：再发一次整组信号，然后用有界等待收尾，
                // 绝不为了回收子进程无期限阻塞。
                signalGroup(group: group, pid: pid, signal: SIGKILL)
                if let status = waitForExit(pid: pid, within: drainGrace) {
                    waitStatus = status
                    reaped = true
                } else {
                    waitStatus = SIGKILL
                }
            }
        }

        // 读取端有明确期限：先给 drainGrace，仍有进程握着管道就打死整组再给一小段收尾，
        // 最后带着已读到的部分输出返回。
        let drainDeadline = Date().addingTimeInterval(drainGrace)
        var stdoutInfo = stdoutReader.finish(until: drainDeadline)
        var stderrInfo = stderrReader.finish(until: drainDeadline)
        if !stdoutInfo.drained || !stderrInfo.drained {
            // 进程已经退出但管道仍没有 EOF：还有后代进程握着写端。整组结束它们，
            // 再给一小段收尾时间，然后带着已读到的部分输出返回。
            signalGroup(group: group, pid: pid, signal: SIGKILL)
            let closeDeadline = Date().addingTimeInterval(0.5)
            stdoutInfo = stdoutReader.finish(until: closeDeadline)
            stderrInfo = stderrReader.finish(until: closeDeadline)
        }

        return ProcessGroupOutcome(
            result: ProcessResult(
                status: exitCode(fromWaitStatus: waitStatus),
                stdout: stdoutInfo.data,
                stderr: stderrInfo.data,
                timedOut: timedOut
            ),
            cancelled: cancelled
        )
    }

    /// 只回收已退出的子进程；返回 nil 表示还在跑（或无子进程可回收时按已退出处理）。
    private static func reapIfExited(pid: pid_t) -> Int32? {
        var status: Int32 = 0
        let reaped = waitpid(pid, &status, WNOHANG)
        if reaped == pid { return status }
        if reaped == -1 && errno != EINTR { return 0 }
        return nil
    }

    private static func waitForExit(pid: pid_t, within seconds: TimeInterval) -> Int32? {
        let deadline = Date().addingTimeInterval(seconds)
        while true {
            if let status = reapIfExited(pid: pid) { return status }
            if Date() >= deadline { return nil }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }

    /// 向整个进程组发信号；组号不可用或指向我们自己时退回只打直接子进程。
    private static func signalGroup(group: pid_t, pid: pid_t, signal: Int32) {
        guard pid > 1 else { return }
        if group > 1, group != getpgrp(), group != getpid() {
            if kill(-group, signal) == 0 { return }
        }
        kill(pid, signal)
    }

    /// 与 `Process.terminationStatus` 保持一致：正常退出给退出码，被信号杀掉给信号编号。
    private static func exitCode(fromWaitStatus status: Int32) -> Int32 {
        let signal = status & 0x7f
        if signal == 0 { return (status >> 8) & 0xff }
        if signal != 0x7f { return signal }
        return (status >> 8) & 0xff
    }
}

/// 有界管道读取：读取线程用 `poll` 轮询，随时可以被要求收尾；
/// 调用方等待读取结束时永远带期限，所以不会因为某个后代进程握着写端而卡死。
final class BoundedPipeReader: @unchecked Sendable {
    private let fd: Int32
    private let chunkHandler: ((Data) -> Void)?
    private let lock = NSLock()
    private let done = DispatchSemaphore(value: 0)
    private var buffer = Data()
    private var drained = false
    private var stopRequested = false

    init(fd: Int32, chunkHandler: ((Data) -> Void)? = nil) {
        self.fd = fd
        self.chunkHandler = chunkHandler
        let flags = fcntl(fd, F_GETFL, 0)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }
    }

    func start() {
        DispatchQueue.global(qos: .utility).async { [self] in
            readLoop()
        }
    }

    /// 有界等待读取结束；超期就先要求收尾，再给一小段收尾时间，最后返回已读到的部分输出。
    func finish(until deadline: Date) -> (data: Data, drained: Bool) {
        if !waitDrained(until: deadline) {
            requestStop()
            _ = waitDrained(until: Date().addingTimeInterval(0.5))
        }
        return snapshot()
    }

    private func waitDrained(until deadline: Date) -> Bool {
        while true {
            lock.lock()
            let isDrained = drained
            lock.unlock()
            if isDrained { return true }

            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return false }
            _ = done.wait(timeout: .now() + min(remaining, 0.02))
        }
    }

    private func requestStop() {
        lock.lock()
        stopRequested = true
        lock.unlock()
    }

    private func shouldStop() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopRequested
    }

    private func snapshot() -> (data: Data, drained: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (buffer, drained)
    }

    private func readLoop() {
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        var scratch = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            descriptor.revents = 0
            let ready = poll(&descriptor, 1, 50)
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            if ready == 0 {
                // 没有数据：只有在被要求收尾时才退出，避免把慢命令的尾部输出丢掉。
                if shouldStop() { break }
                continue
            }
            let count = scratch.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return read(fd, base, raw.count)
            }
            if count > 0 {
                let chunk = Data(scratch[0..<count])
                lock.lock()
                buffer.append(chunk)
                lock.unlock()
                chunkHandler?(chunk)
                continue
            }
            if count == 0 { break }  // EOF：所有写端都关了
            if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR {
                if shouldStop() { break }
                continue
            }
            break
        }

        lock.lock()
        drained = true
        lock.unlock()
        done.signal()
        close(fd)
    }
}

/// 用 `posix_spawn` 起子进程，并用 `POSIX_SPAWN_SETPGROUP` 把它放进自己的进程组，
/// 这样超时能整组结束（孙进程也在组里），而不是只 terminate 直接子进程。
private enum ProcessGroupSpawner {
    static func spawn(
        executable: URL,
        arguments: [String],
        environment: [String: String]?
    ) -> (pid: pid_t, stdoutFD: Int32, stderrFD: Int32)? {
        var stdoutPipe: [Int32] = [-1, -1]
        var stderrPipe: [Int32] = [-1, -1]
        guard pipe(&stdoutPipe) == 0 else { return nil }
        guard pipe(&stderrPipe) == 0 else {
            close(stdoutPipe[0])
            close(stdoutPipe[1])
            return nil
        }

        func closeAllDescriptors() {
            close(stdoutPipe[0])
            close(stdoutPipe[1])
            close(stderrPipe[0])
            close(stderrPipe[1])
        }

        var fileActions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&fileActions) == 0 else {
            closeAllDescriptors()
            return nil
        }
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        posix_spawn_file_actions_addopen(&fileActions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&fileActions, stdoutPipe[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, stderrPipe[1], STDERR_FILENO)
        // 子进程不保留读端，否则 EOF 语义会依赖父进程是否还握着读取句柄。
        posix_spawn_file_actions_addclose(&fileActions, stdoutPipe[0])
        posix_spawn_file_actions_addclose(&fileActions, stderrPipe[0])

        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else {
            closeAllDescriptors()
            return nil
        }
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        // pgroup = 0：子进程以自身 pid 作为新进程组 id。
        posix_spawnattr_setpgroup(&attributes, 0)

        let path = executable.path
        var argumentPointers: [UnsafeMutablePointer<CChar>?] = ([path] + arguments).map { strdup($0) }
        argumentPointers.append(nil)
        defer { for pointer in argumentPointers { free(pointer) } }

        var environmentPointers: [UnsafeMutablePointer<CChar>?]?
        if let environment {
            var merged = ProcessInfo.processInfo.environment
            merged.merge(environment) { _, new in new }
            var pointers: [UnsafeMutablePointer<CChar>?] = merged.map { strdup("\($0.key)=\($0.value)") }
            pointers.append(nil)
            environmentPointers = pointers
        }
        defer {
            for pointer in environmentPointers ?? [] { free(pointer) }
        }

        var pid: pid_t = 0
        let spawnResult: Int32
        if let environmentPointers {
            spawnResult = posix_spawn(
                &pid, path, &fileActions, &attributes, argumentPointers, environmentPointers
            )
        } else {
            spawnResult = posix_spawn(&pid, path, &fileActions, &attributes, argumentPointers, nil)
        }

        guard spawnResult == 0, pid > 0 else {
            closeAllDescriptors()
            return nil
        }

        close(stdoutPipe[1])
        close(stderrPipe[1])
        return (pid, stdoutPipe[0], stderrPipe[0])
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
