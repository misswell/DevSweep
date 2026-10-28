import Foundation

/// 一个 Time Machine 本地快照。
///
/// 只接受 `com.apple.TimeMachine.*` 的快照：`com.apple.os.update-*` 是系统更新回滚点，
/// 删掉会让 macOS 无法回退更新，永远不作为候选项（参考 dusty 的同一约束）。
struct TimeMachineSnapshot: Equatable, Hashable, Sendable {
    /// `tmutil` 报告的完整名称，例如 `com.apple.TimeMachine.2026-10-27-151925.local`。
    let name: String
    /// `tmutil deletelocalsnapshots` 需要的日期参数，例如 `2026-10-27-151925`。
    let dateToken: String
    /// 界面展示用的本地时间文案。
    let displayDate: Date?

    var displayName: String {
        guard let displayDate else { return dateToken }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: displayDate)
    }
}

enum TimeMachineSnapshotError: LocalizedError, Equatable {
    case tmutilUnavailable(String)
    case invalidToken(String)
    case notRemoved(String)

    var errorDescription: String? {
        switch self {
        case let .tmutilUnavailable(detail):
            return "无法运行 tmutil：\(detail)"
        case let .invalidToken(token):
            return "快照日期参数不合法（\(token)），已拒绝删除"
        case let .notRemoved(token):
            return "快照 \(token) 删除后仍出现在 tmutil 列表里；可以复制兜底命令到终端重试"
        }
    }
}

/// 列出 / 删除 Time Machine 本地快照。
///
/// 关键约束：
/// - 只处理 `com.apple.TimeMachine.*`；
/// - `tmutil deletelocalsnapshots` 即使失败也可能返回 0，因此**必须重新列一次确认真的消失**；
/// - 日期参数只接受 `yyyy-MM-dd-HHmmss` 形态，避免把任意字符串拼进命令行。
enum TimeMachineSnapshotCleaner {
    static let namePrefix = "com.apple.TimeMachine."
    static let osUpdatePrefix = "com.apple.os.update-"
    static let nameSuffix = ".local"

    private static let tokenFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter
    }()

    static func listArguments() -> [String] { ["listlocalsnapshots", "/"] }
    static func deleteArguments(_ token: String) -> [String] { ["deletelocalsnapshots", token] }

    static func isDeletableName(_ name: String) -> Bool {
        guard name.hasPrefix(namePrefix), !name.hasPrefix(osUpdatePrefix) else { return false }
        let token = token(from: name)
        return isValidToken(token)
    }

    /// `com.apple.TimeMachine.2026-10-27-151925.local` → `2026-10-27-151925`
    static func token(from name: String) -> String {
        guard name.hasPrefix(namePrefix) else { return "" }
        var rest = String(name.dropFirst(namePrefix.count))
        if rest.hasSuffix(nameSuffix) {
            rest = String(rest.dropLast(nameSuffix.count))
        }
        return rest
    }

    /// 只接受 `yyyy-MM-dd-HHmmss`：可选末尾 `Z`，其余字符一律拒绝。
    static func isValidToken(_ token: String) -> Bool {
        guard token.count == 17 || token.count == 18 else { return false }
        let pattern = #"^\d{4}-\d{2}-\d{2}-\d{6}Z?$"#
        guard token.range(of: pattern, options: .regularExpression) != nil else { return false }
        return date(fromToken: token) != nil
    }

    static func date(fromToken token: String) -> Date? {
        let normalized = token.hasSuffix("Z") ? String(token.dropLast()) : token
        return tokenFormatter.date(from: normalized)
    }

    /// 解析 `tmutil listlocalsnapshots /` 输出：只保留 Time Machine 快照。
    static func parseSnapshots(from output: String) -> [TimeMachineSnapshot] {
        output.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard isDeletableName(line) else { return nil }
            let token = token(from: line)
            return TimeMachineSnapshot(
                name: line,
                dateToken: token,
                displayDate: date(fromToken: token)
            )
        }
    }

    static func listSnapshots(
        runner: any ProcessRunning & Sendable,
        timeout: TimeInterval = 30
    ) throws -> [TimeMachineSnapshot] {
        guard let result = runner.run(
            executable: URL(fileURLWithPath: "/usr/bin/tmutil"),
            arguments: listArguments(),
            environment: nil,
            timeout: timeout
        ), !result.timedOut else {
            throw TimeMachineSnapshotError.tmutilUnavailable("列出本地快照超时或无法启动")
        }
        guard result.status == 0 else {
            let detail = String(data: result.stderr, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw TimeMachineSnapshotError.tmutilUnavailable(
                detail.isEmpty ? "tmutil 退出码 \(result.status)" : detail
            )
        }
        let output = String(data: result.stdout, encoding: .utf8) ?? ""
        return parseSnapshots(from: output)
    }

    /// 删除一个快照，并以「重新列出后确实消失」作为成功判据。
    static func delete(
        _ snapshot: TimeMachineSnapshot,
        runner: any ProcessRunning & Sendable,
        deleteTimeout: TimeInterval = 300
    ) throws {
        guard isValidToken(snapshot.dateToken) else {
            throw TimeMachineSnapshotError.invalidToken(snapshot.dateToken)
        }
        _ = runner.run(
            executable: URL(fileURLWithPath: "/usr/bin/tmutil"),
            arguments: deleteArguments(snapshot.dateToken),
            environment: nil,
            timeout: deleteTimeout
        )
        // tmutil 可能返回 0 但什么都没删，必须复核。
        let remaining = try listSnapshots(runner: runner)
        guard !remaining.contains(where: { $0.dateToken == snapshot.dateToken }) else {
            throw TimeMachineSnapshotError.notRemoved(snapshot.dateToken)
        }
    }

    /// 可复制到终端的兜底命令。
    static func fallbackCommands(for snapshots: [TimeMachineSnapshot]) -> [String] {
        ["/usr/bin/tmutil listlocalsnapshots /"]
            + snapshots.map { "/usr/bin/tmutil deletelocalsnapshots \($0.dateToken)" }
    }
}

/// 删除动作的抽象，便于把 Time Machine 快照接进统一的清理流程与测试替身。
protocol TimeMachineSnapshotDeleting: Sendable {
    func delete(_ item: CacheItem, context: DeletionContext) throws
}

struct TimeMachineSnapshotDeletingExecutor: TimeMachineSnapshotDeleting {
    var runner: any ProcessRunning & Sendable = ProcessRunner.shared

    func delete(_ item: CacheItem, context: DeletionContext) throws {
        guard item.kind == .timeMachineSnapshot,
              let token = item.identifier,
              TimeMachineSnapshotCleaner.isValidToken(token) else {
            throw TimeMachineSnapshotError.invalidToken(item.identifier ?? "")
        }
        guard !PathWhitelist.contains(item.path, in: context.whitelistedPaths) else {
            throw DeletionValidationError.whitelisted
        }
        // 删除前重新列一次：快照可能已被 macOS 自己回收，或磁盘已经换过。
        let current = try TimeMachineSnapshotCleaner.listSnapshots(runner: runner)
        guard let snapshot = current.first(where: { $0.dateToken == token }) else {
            // 已经不存在视为完成，不报错。
            return
        }
        try TimeMachineSnapshotCleaner.delete(snapshot, runner: runner)
    }
}

/// 扫描阶段的快照枚举（协议注入，测试不跑真实 tmutil）。
protocol TimeMachineSnapshotListing: Sendable {
    func snapshots() throws -> [TimeMachineSnapshot]
}

struct TimeMachineSnapshotLister: TimeMachineSnapshotListing {
    var runner: any ProcessRunning & Sendable = ProcessRunner.shared

    func snapshots() throws -> [TimeMachineSnapshot] {
        try TimeMachineSnapshotCleaner.listSnapshots(runner: runner)
    }
}
