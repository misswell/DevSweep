import Darwin
import Foundation

/// PID alone is not an identity: macOS may reuse it between scan and cleanup.
struct BackgroundProcessIdentity: Hashable, Sendable {
    let pid: Int32
    let uid: UInt32
    let startSeconds: UInt64
    let startMicroseconds: UInt64
    let executablePath: String

    var isVerified: Bool { pid > 1 && startSeconds > 0 && !executablePath.isEmpty }
    var startedAt: Date {
        Date(timeIntervalSince1970: Double(startSeconds) + Double(startMicroseconds) / 1_000_000)
    }
}

struct BackgroundProcessRecord: Equatable, Sendable {
    let identity: BackgroundProcessIdentity
    let parentPID: Int32
    let state: String
    let residentBytes: Int64
    let command: String

    var pid: Int32 { identity.pid }
    var executableName: String { URL(fileURLWithPath: identity.executablePath).lastPathComponent }
    var isZombie: Bool { state.hasPrefix("Z") }
}

protocol BackgroundProcessInspecting {
    func snapshot() throws -> [BackgroundProcessRecord]
    func currentIdentity(pid: Int32) -> BackgroundProcessIdentity?
    func hasExited(pid: Int32) -> Bool
}

struct BackgroundProcessInspector: BackgroundProcessInspecting {
    var runner: ProcessRunning = ProcessRunner.shared

    func snapshot() throws -> [BackgroundProcessRecord] {
        let output = try BackgroundCommand.output(
            runner: runner, executable: "/bin/ps",
            arguments: ["-ww", "-axo", "pid=,ppid=,uid=,stat=,rss=,command="], timeout: 5
        )
        return try Self.parse(output) { currentIdentity(pid: $0) }
    }

    static func parse(
        _ output: String,
        identity: (Int32) -> BackgroundProcessIdentity?
    ) throws -> [BackgroundProcessRecord] {
        guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BackgroundCleanupError.unavailable("无法读取进程列表")
        }
        return try output.split(whereSeparator: \.isNewline).map { line in
            let fields = line.split(maxSplits: 5, whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count == 6,
                  let pid = Int32(fields[0]), pid > 0,
                  let parent = Int32(fields[1]), parent >= 0,
                  let rawUID = Int64(fields[2]), rawUID >= Int64(Int32.min), rawUID <= Int64(UInt32.max),
                  let rss = Int64(fields[4]), rss >= 0, rss <= Int64.max / 1_024 else {
                throw BackgroundCleanupError.unavailable("进程列表格式无法确认，请重新扫描")
            }
            // ps prints special macOS accounts (for example nobody) as -2.
            let uid = UInt32(truncatingIfNeeded: rawUID)
            // Retain unverifiable rows so hidden descendants cannot silently
            // disappear from a cleanup tree. They make the entire tree read-only.
            let verified = identity(pid)
            let processIdentity = verified?.uid == uid ? verified! : BackgroundProcessIdentity(
                pid: pid, uid: uid, startSeconds: 0, startMicroseconds: 0, executablePath: ""
            )
            return BackgroundProcessRecord(
                identity: processIdentity, parentPID: parent, state: String(fields[3]),
                residentBytes: rss * 1_024, command: String(fields[5])
            )
        }
    }

    func currentIdentity(pid: Int32) -> BackgroundProcessIdentity? {
        guard pid > 1 else { return nil }
        var info = proc_bsdinfo()
        let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, expectedSize) == expectedSize,
              info.pbi_status != SZOMB else { return nil }
        // libproc defines PROC_PIDPATHINFO_MAXSIZE as (4 * MAXPATHLEN),
        // which Swift's Clang importer does not expose as a constant.
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let pathLength = proc_pidpath(pid, &path, UInt32(path.count))
        let pathError = errno
        let executable: String
        if pathLength > 0 {
            executable = String(cString: path)
        } else {
            // An app update may remove the old crashpad executable while its
            // process remains alive. Recover only this exact, kernel-named
            // helper, retaining the native UID and microsecond start identity.
            let kernelName = withUnsafeBytes(of: info.pbi_name) {
                String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
            guard pathError == ENOENT, kernelName == "browser_crashpad_handler",
                  info.pbi_uid == getuid(),
                  let output = try? BackgroundCommand.output(
                    runner: runner, executable: "/bin/ps",
                    arguments: ["-ww", "-p", String(pid), "-o", "command="], timeout: 2
                  ), let recovered = Self.deletedCodexCrashpadPath(command: output, kernelName: kernelName) else { return nil }
            executable = recovered
        }
        return BackgroundProcessIdentity(
            pid: pid, uid: info.pbi_uid, startSeconds: info.pbi_start_tvsec,
            startMicroseconds: info.pbi_start_tvusec, executablePath: executable
        )
    }

    func hasExited(pid: Int32) -> Bool {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size {
            return info.pbi_status == SZOMB
        }
        return Darwin.kill(pid, 0) != 0 && errno == ESRCH
    }

    static func deletedCodexCrashpadPath(command: String, kernelName: String) -> String? {
        guard kernelName == "browser_crashpad_handler" else { return nil }
        let command = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = command.components(separatedBy: " --").first ?? ""
        let prefix = "/Applications/ChatGPT.app/Contents/Frameworks/Codex Framework.framework/Versions/"
        let suffix = "/Helpers/browser_crashpad_handler"
        guard path.hasPrefix(prefix), path.hasSuffix(suffix) else { return nil }
        let version = path.dropFirst(prefix.count).dropLast(suffix.count)
        guard !version.isEmpty, version.contains("."), version.allSatisfy({ $0.isNumber || $0 == "." }) else { return nil }
        return path
    }
}

struct BackgroundSimulator: Decodable, Equatable, Sendable {
    let name: String
    let udid: String
    let state: String
    let isAvailable: Bool?
    var runtime: String = ""

    enum CodingKeys: String, CodingKey { case name, udid, state, isAvailable }
}

protocol BackgroundSimulatorInspecting {
    func bootedDevices() throws -> [BackgroundSimulator]
    func shutdown(udid: String) throws
}

struct BackgroundSimulatorInspector: BackgroundSimulatorInspecting {
    var runner: ProcessRunning = ProcessRunner.shared

    func bootedDevices() throws -> [BackgroundSimulator] {
        let output = try BackgroundCommand.output(
            runner: runner, executable: "/usr/bin/xcrun",
            arguments: ["simctl", "list", "devices", "booted", "--json"], timeout: 15
        )
        return try Self.parse(output)
    }

    static func parse(_ output: String) throws -> [BackgroundSimulator] {
        struct List: Decodable { let devices: [String: [BackgroundSimulator]] }
        let list = try JSONDecoder().decode(List.self, from: Data(output.utf8))
        return list.devices.flatMap { runtime, devices in
            devices.compactMap { device in
                guard device.state == "Booted", device.isAvailable != false,
                      UUID(uuidString: device.udid) != nil else { return nil }
                var result = device
                result.runtime = runtime.replacingOccurrences(of: "com.apple.CoreSimulator.SimRuntime.", with: "")
                return result
            }
        }
    }

    func shutdown(udid: String) throws {
        guard UUID(uuidString: udid) != nil else { throw BackgroundCleanupError.changed }
        _ = try BackgroundCommand.output(
            runner: runner, executable: "/usr/bin/xcrun",
            arguments: ["simctl", "shutdown", udid], timeout: 30
        )
    }
}

enum BackgroundCleanupKind: Equatable, Sendable {
    case simulator(String)
    case processTree
}

struct BackgroundCleanupItem: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let reason: String
    let protection: String?
    let kind: BackgroundCleanupKind
    let root: BackgroundProcessRecord
    let members: [BackgroundProcessRecord]

    var canClean: Bool { protection == nil }
    var residentBytes: Int64 { members.reduce(0) { $0 + $1.residentBytes } }
    var actionTitle: String {
        if case .simulator = kind { return "关闭模拟器" }
        return "结束进程"
    }
    var category: String {
        if case .simulator = kind { return "iOS Simulator" }
        return "Agent 与临时任务"
    }
}

struct BackgroundScanReport: Sendable {
    let items: [BackgroundCleanupItem]
    let warnings: [String]
}

/// Narrow allowlist: a long-lived node/python/MCP server is not, by itself,
/// evidence of a leftover. Every candidate still requires explicit selection.
struct BackgroundProcessPolicy {
    var userID: UInt32 = getuid()
    var ownPID: Int32 = getpid()
    var now = Date()
    var minimumAge: TimeInterval = 3_600

    func candidates(
        records: [BackgroundProcessRecord], simulators: [BackgroundSimulator]
    ) -> [BackgroundCleanupItem] {
        let protected = protectedPIDs(records)
        let buildProtection = simulatorProtection(records)
        var items: [BackgroundCleanupItem] = []
        var covered = Set<Int32>()
        let activeCodexVersions = Set(records.compactMap { record -> String? in
            guard record.identity.uid == userID, !record.executableName.contains("crashpad") else { return nil }
            return codexVersion(record.identity.executablePath)
        })

        for simulator in simulators {
            guard let root = records.first(where: {
                $0.executableName == "launchd_sim" && $0.identity.uid == userID
                    && $0.command.contains("/CoreSimulator/Devices/\(simulator.udid)/data/var/run/launchd_bootstrap.plist")
            }) else { continue }
            let members = tree(rootPID: root.pid, records: records)
            items.append(item(
                root: root, members: members, kind: .simulator(simulator.udid),
                title: "\(simulator.name) · \(simulator.runtime)",
                reason: "模拟器仍在运行；不用时可正常关机，设备和数据会保留。",
                protection: buildProtection ?? treeProtection(members, protected: protected)
            ))
            covered.formUnion(members.map(\.pid))
        }

        for record in records.sorted(by: { $0.pid < $1.pid }) {
            guard record.identity.uid == userID, record.identity.isVerified,
                  !record.isZombie, !protected.contains(record.pid), !covered.contains(record.pid),
                  now.timeIntervalSince(record.identity.startedAt) >= minimumAge else { continue }
            if record.executableName.hasPrefix("agent-browser"), record.parentPID == 1 {
                let members = tree(rootPID: record.pid, records: records)
                let hasUnrelatedChild = members.dropFirst().contains { child in
                    !isAutomationBrowser(child) && !child.executableName.contains("crashpad")
                }
                items.append(item(
                    root: record, members: members, title: "agent-browser 浏览器任务",
                    reason: "独立的浏览器自动化后台，已运行超过一小时；请确认任务已经结束。",
                    protection: hasUnrelatedChild ? "包含无法确认用途的子进程" : treeProtection(members, protected: protected)
                ))
                covered.formUnion(members.map(\.pid))
            } else if isAutomationBrowser(record), record.parentPID == 1,
                      record.command.contains("--headless"), !record.command.contains("--type=") {
                let members = tree(rootPID: record.pid, records: records)
                let allBrowser = members.allSatisfy { isAutomationBrowser($0) || $0.executableName.contains("crashpad") }
                items.append(item(
                    root: record, members: members, title: "无头测试浏览器",
                    reason: "浏览器位于自动化工具目录，原父进程已退出；请确认自动化任务已经结束。",
                    protection: allBrowser ? treeProtection(members, protected: protected) : "包含无法确认用途的子进程"
                ))
                covered.formUnion(members.map(\.pid))
            } else if record.executableName == "mas" {
                let args = arguments(record)
                if let action = args.first, ["list", "outdated", "info"].contains(action) {
                    let root = queryRoot(record, records: records, protected: protected)
                    guard !covered.contains(root.pid) else { continue }
                    let members = tree(rootPID: root.pid, records: records)
                    let allowedNames: Set<String> = ["mas", "zsh", "bash", "sh", "jq", "column", "rg", "grep", "head"]
                    let onlyQueries = members.allSatisfy { member in
                        allowedNames.contains(member.executableName)
                            && (member.executableName != "mas" || ["list", "outdated", "info"].contains(arguments(member).first ?? ""))
                    }
                    items.append(item(
                        root: root, members: members, title: "mas \(action) 查询任务",
                        reason: "App Store 查询已运行超过一小时，可能挂起；结束时会同时处理查询管道。",
                        protection: onlyQueries ? treeProtection(members, protected: protected) : "同一任务中还有非查询进程"
                    ))
                    covered.formUnion(members.map(\.pid))
                } else if ["install", "upgrade", "uninstall"].contains(args.first ?? "") {
                    items.append(item(
                        root: record, members: [record], title: "mas 安装或更新任务",
                        reason: "安装命令长时间未退出，需要先确认 App Store 的安装状态。",
                        protection: "安装任务受保护，请从 App Store 或原任务中取消"
                    ))
                }
            } else if record.executableName == "browser_crashpad_handler", record.parentPID == 1,
                      let version = codexVersion(record.identity.executablePath),
                      !activeCodexVersions.isEmpty, !activeCodexVersions.contains(version) {
                let members = tree(rootPID: record.pid, records: records)
                items.append(item(
                    root: record, members: members, title: "旧版 Codex 崩溃报告进程",
                    reason: "当前 Codex 已使用其他版本，仍留有 \(version) 的崩溃报告后台。",
                    protection: members.count == 1 ? treeProtection(members, protected: protected) : "含有其他子进程"
                ))
            }
        }
        return items.sorted { $0.residentBytes > $1.residentBytes }
    }

    func tree(rootPID: Int32, records: [BackgroundProcessRecord]) -> [BackgroundProcessRecord] {
        var result: [BackgroundProcessRecord] = []
        var pending = [rootPID]
        var seen = Set<Int32>()
        while !pending.isEmpty {
            let pid = pending.removeFirst()
            guard seen.insert(pid).inserted, let record = records.first(where: { $0.pid == pid }) else { continue }
            result.append(record)
            pending.append(contentsOf: records.filter { $0.parentPID == pid }.map(\.pid))
        }
        return result
    }

    func protectedPIDs(_ records: [BackgroundProcessRecord]) -> Set<Int32> {
        var protected: Set<Int32> = [0, 1, ownPID]
        var parent = records.first { $0.pid == ownPID }?.parentPID
        while let pid = parent, protected.insert(pid).inserted {
            parent = records.first { $0.pid == pid }?.parentPID
        }
        return protected
    }

    private func simulatorProtection(_ records: [BackgroundProcessRecord]) -> String? {
        for record in records where !record.isZombie {
            let name = record.executableName.lowercased()
            if name == "xcodebuild" || name == "xctest" || name == "xctestagent" || name.contains("xctrunner") {
                return "检测到构建或测试正在运行，暂不允许关闭模拟器"
            }
            if !record.identity.isVerified,
               XCTestActivityInspector.runningReason(in: record.command) != nil {
                return "无法确认构建或测试进程状态，暂不允许关闭模拟器"
            }
        }
        return nil
    }

    private func treeProtection(_ members: [BackgroundProcessRecord], protected: Set<Int32>) -> String? {
        if members.contains(where: { protected.contains($0.pid) }) { return "当前应用或其所属任务受保护" }
        if members.contains(where: { $0.identity.uid != userID }) { return "包含其他用户的进程" }
        if members.contains(where: { !$0.identity.isVerified && !$0.isZombie }) { return "部分进程身份无法确认" }
        return nil
    }

    private func item(
        root: BackgroundProcessRecord, members: [BackgroundProcessRecord],
        kind: BackgroundCleanupKind = .processTree, title: String, reason: String, protection: String?
    ) -> BackgroundCleanupItem {
        BackgroundCleanupItem(
            id: "\(root.pid):\(root.identity.startSeconds):\(root.identity.startMicroseconds)",
            title: title, reason: reason, protection: protection, kind: kind, root: root, members: members
        )
    }

    private func queryRoot(
        _ record: BackgroundProcessRecord, records: [BackgroundProcessRecord], protected: Set<Int32>
    ) -> BackgroundProcessRecord {
        var root = record
        var seen: Set<Int32> = [root.pid]
        while let parent = records.first(where: { $0.pid == root.parentPID }),
              !protected.contains(parent.pid), seen.insert(parent.pid).inserted,
              ["zsh", "bash", "sh"].contains(parent.executableName),
              parent.command.contains("/mas ") || parent.command.contains("mas list")
                || parent.command.contains("mas outdated") || parent.command.contains("mas info") {
            root = parent
        }
        return root
    }

    private func arguments(_ record: BackgroundProcessRecord) -> [String] {
        record.command.split(whereSeparator: { $0 == " " || $0 == "\t" }).dropFirst().map(String.init)
    }

    private func isAutomationBrowser(_ record: BackgroundProcessRecord) -> Bool {
        let path = record.identity.executablePath
        return (path.contains("/.agent-browser/browsers/") || path.contains("/ms-playwright/")
            || path.contains("/.cache/puppeteer/"))
            && (record.executableName.contains("Chrome") || record.executableName.contains("chromium")
                || record.executableName.contains("chrome"))
    }

    private func codexVersion(_ path: String) -> String? {
        let prefix = "/ChatGPT.app/Contents/Frameworks/Codex Framework.framework/Versions/"
        guard let range = path.range(of: prefix) else { return nil }
        return path[range.upperBound...].split(separator: "/").first.map(String.init)
    }
}

struct BackgroundProcessScanner {
    var processes: BackgroundProcessInspecting = BackgroundProcessInspector()
    var simulators: BackgroundSimulatorInspecting = BackgroundSimulatorInspector()
    var policy = BackgroundProcessPolicy()

    func scan() throws -> BackgroundScanReport {
        let records = try processes.snapshot()
        var devices: [BackgroundSimulator] = []
        var warnings: [String] = []
        do { devices = try simulators.bootedDevices() }
        catch { warnings.append("模拟器状态读取失败：\(error.localizedDescription)") }
        return BackgroundScanReport(items: policy.candidates(records: records, simulators: devices), warnings: warnings)
    }
}

protocol BackgroundProcessSignaling {
    func terminate(_ identity: BackgroundProcessIdentity) throws
}

struct BackgroundProcessSignaler: BackgroundProcessSignaling {
    var inspector: BackgroundProcessInspecting = BackgroundProcessInspector()

    func terminate(_ identity: BackgroundProcessIdentity) throws {
        guard identity.isVerified, identity.uid == getuid(), identity.pid != getpid(),
              inspector.currentIdentity(pid: identity.pid) == identity else { throw BackgroundCleanupError.changed }
        guard Darwin.kill(identity.pid, SIGTERM) == 0 else {
            if errno == ESRCH { return }
            throw BackgroundCleanupError.unavailable("无法结束 PID \(identity.pid)：\(String(cString: strerror(errno)))")
        }
    }
}

struct BackgroundProcessCleaner {
    var processes: BackgroundProcessInspecting = BackgroundProcessInspector()
    var simulators: BackgroundSimulatorInspecting = BackgroundSimulatorInspector()
    var signaler: BackgroundProcessSignaling = BackgroundProcessSignaler()
    var policy = BackgroundProcessPolicy()
    var exitTimeout: TimeInterval = 3

    func clean(_ selected: BackgroundCleanupItem) throws {
        guard selected.canClean else { throw BackgroundCleanupError.protected(selected.protection ?? "") }
        let records = try processes.snapshot()
        let devices: [BackgroundSimulator]
        if case .simulator = selected.kind { devices = try simulators.bootedDevices() }
        else { devices = [] }
        guard let current = policy.candidates(records: records, simulators: devices).first(where: { $0.id == selected.id }),
              current.canClean, current.kind == selected.kind,
              current.root.identity == selected.root.identity,
              current.root.command == selected.root.command else { throw BackgroundCleanupError.changed }

        if case .simulator(let udid) = selected.kind {
            // Simulator services legitimately come and go. Revalidate the boot
            // identity and build/test activity instead of freezing its children.
            guard processes.currentIdentity(pid: current.root.pid) == current.root.identity else {
                throw BackgroundCleanupError.changed
            }
            try simulators.shutdown(udid: udid)
            guard !(try simulators.bootedDevices()).contains(where: { $0.udid == udid }) else {
                throw BackgroundCleanupError.stillRunning
            }
            return
        }

        let expected = selected.members.filter { !$0.isZombie }
        let live = current.members.filter { !$0.isZombie }
        guard Set(expected.map(\.identity)) == Set(live.map(\.identity)),
              expected.allSatisfy({ member in
                  live.contains { $0.identity == member.identity && $0.parentPID == member.parentPID && $0.command == member.command }
              }) else { throw BackgroundCleanupError.changed }
        // Stop the task owner first so a shell cannot advance to a new command
        // when its pipe exits. Then handle the captured descendants individually.
        let ordered = [current.root] + live.reversed().filter { $0.pid != current.root.pid }
        for member in ordered {
            guard let identity = processes.currentIdentity(pid: member.pid) else {
                guard processes.hasExited(pid: member.pid) else {
                    throw BackgroundCleanupError.unavailable("无法确认 PID \(member.pid) 的身份，已停止处理")
                }
                continue
            }
            guard identity == member.identity else { throw BackgroundCleanupError.changed }
            try signaler.terminate(identity)
        }
        let deadline = Date().addingTimeInterval(exitTimeout)
        repeat {
            let exited = try live.allSatisfy { member in
                if let identity = processes.currentIdentity(pid: member.pid) { return identity != member.identity }
                guard processes.hasExited(pid: member.pid) else {
                    throw BackgroundCleanupError.unavailable("无法确认 PID \(member.pid) 是否退出，请检查原任务")
                }
                return true
            }
            if exited { return }
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < deadline
        throw BackgroundCleanupError.stillRunning
    }
}

enum BackgroundCleanupError: LocalizedError, Equatable {
    case changed
    case stillRunning
    case protected(String)
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .changed: return "进程或任务状态已变化，已跳过。请重新扫描后确认。"
        case .stillRunning: return "已请求正常退出，但仍有进程在运行；未强制结束，请检查原任务。"
        case .protected(let reason), .unavailable(let reason): return reason
        }
    }
}

private enum BackgroundCommand {
    static func output(
        runner: ProcessRunning, executable: String, arguments: [String], timeout: TimeInterval
    ) throws -> String {
        guard let result = runner.run(
            executable: URL(fileURLWithPath: executable), arguments: arguments,
            environment: ["LC_ALL": "C"], timeout: timeout
        ), !result.timedOut, result.status == 0,
              let output = String(data: result.stdout, encoding: .utf8) else {
            throw BackgroundCleanupError.unavailable("无法读取或执行 \(URL(fileURLWithPath: executable).lastPathComponent)，请稍后重试")
        }
        return output
    }
}
