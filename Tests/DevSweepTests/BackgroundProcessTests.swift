import Darwin
import Foundation
import XCTest
@testable import DevSweep

final class BackgroundProcessTests: XCTestCase {
    private let udid = "00EAD0C8-A9A0-4820-BEC3-E4EA016ECB15"
    private var policy: BackgroundProcessPolicy {
        BackgroundProcessPolicy(userID: 501, ownPID: 900, now: Date(timeIntervalSince1970: 10_000))
    }

    private func record(
        _ pid: Int32, parent: Int32 = 1, path: String = "/usr/local/bin/agent-browser",
        command: String? = nil, uid: UInt32 = 501, start: UInt64 = 100,
        state: String = "S"
    ) -> BackgroundProcessRecord {
        BackgroundProcessRecord(
            identity: BackgroundProcessIdentity(
                pid: pid, uid: uid, startSeconds: start, startMicroseconds: 10, executablePath: path
            ), parentPID: parent, state: state, residentBytes: 1_024, command: command ?? path
        )
    }

    private var simulator: BackgroundSimulator {
        BackgroundSimulator(name: "iPhone", udid: udid, state: "Booted", isAvailable: true, runtime: "iOS-26-5")
    }

    private func simulatorRoot() -> BackgroundProcessRecord {
        record(101, path: "/usr/libexec/launchd_sim", command:
            "launchd_sim /Users/dev/Library/Developer/CoreSimulator/Devices/\(udid)/data/var/run/launchd_bootstrap.plist")
    }

    func testSnapshotParsingPreservesCommandsWithSpacesAndUnverifiedDescendants() throws {
        let known = record(101).identity
        let rows = try BackgroundProcessInspector.parse(
            "101 1 501 S 12 /Applications/Google Chrome.app/Chrome --headless=new\n102 101 501 S 2 unknown\n103 1 -2 S 0 nobody"
        ) { $0 == 101 ? known : nil }
        XCTAssertEqual(rows[0].command, "/Applications/Google Chrome.app/Chrome --headless=new")
        XCTAssertEqual(rows[0].residentBytes, 12 * 1_024)
        XCTAssertEqual(rows[1].parentPID, 101)
        XCTAssertFalse(rows[1].identity.isVerified)
        XCTAssertEqual(rows[2].identity.uid, UInt32(bitPattern: -2))
        XCTAssertThrowsError(try BackgroundProcessInspector.parse("not a process list") { _ in nil })
        XCTAssertThrowsError(try BackgroundProcessInspector.parse("") { _ in nil })
    }

    func testSimulatorJSONOnlyIncludesValidBootedDevices() throws {
        let output = """
        {"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-26-5":[
          {"name":"iPhone","udid":"\(udid)","state":"Booted","isAvailable":true},
          {"name":"Off","udid":"\(udid)","state":"Shutdown","isAvailable":true},
          {"name":"Bad","udid":"--all","state":"Booted","isAvailable":true},
          {"name":"Unavailable","udid":"\(udid)","state":"Booted","isAvailable":false}
        ]}}
        """
        let devices = try BackgroundSimulatorInspector.parse(output)
        XCTAssertEqual(devices, [simulator])
        XCTAssertThrowsError(try BackgroundSimulatorInspector.parse("{}"))
    }

    func testUnknownProcessesAndNormalServicesAreNotCandidates() {
        let rows = [
            record(101, path: "/opt/homebrew/bin/node", command: "node /work/server.js"),
            record(102, path: "/usr/bin/python3", command: "python3 server.py"),
            record(103, path: "/opt/homebrew/bin/bun", command: "bun claude-mem --daemon"),
            record(104, path: "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT"),
            record(105, path: "/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node", command: "node ./server.mjs"),
            record(106, path: "/Applications/Claude Code Router.app/Contents/MacOS/Claude Code Router"),
            record(107, path: "/usr/local/bin/agent-browser", state: "Z")
        ]
        XCTAssertTrue(policy.candidates(records: rows, simulators: []).isEmpty)
    }

    func testBrowserTreeIncludesChildrenAndRequiresReview() {
        let root = record(101)
        let child = record(102, parent: 101, path: "/Users/dev/.agent-browser/browsers/chrome/Google Chrome for Testing")
        let item = policy.candidates(records: [root, child], simulators: []).first!
        XCTAssertEqual(item.members.map(\.pid), [101, 102])
        XCTAssertEqual(item.residentBytes, 2_048)
        XCTAssertTrue(item.canClean)
        XCTAssertFalse(policy.candidates(records: [record(103, start: 9_500)], simulators: []).contains { $0.canClean })
    }

    func testOtherUserOrUnrelatedChildProtectsBrowserTree() {
        for child in [
            record(102, parent: 101, path: "/Users/dev/.agent-browser/browsers/chrome/Chrome", uid: 502),
            record(102, parent: 101, path: "/usr/bin/python3"),
            record(102, parent: 101, path: "", start: 0)
        ] {
            XCTAssertFalse(policy.candidates(records: [record(101), child], simulators: []).first!.canClean)
        }
        XCTAssertTrue(policy.candidates(records: [record(101, uid: 502)], simulators: []).isEmpty)
    }

    func testOrphanBrowserHelpersAreNotOfferedAsHeadlessBrowserRoots() {
        let path = "/Users/dev/.agent-browser/browsers/chrome/"
        let records = [
            record(101, path: path + "Chrome", command: "Chrome --headless=new"),
            record(102, path: path + "chrome_crashpad_handler"),
            record(103, path: path + "Chrome Helper", command: "Chrome Helper --type=renderer"),
            record(104, path: "/Applications/Google Chrome.app/Chrome", command: "Chrome --headless=new")
        ]
        XCTAssertEqual(policy.candidates(records: records, simulators: []).map { $0.root.pid }, [101])
    }

    func testCurrentApplicationAndAncestorsAreProtected() {
        let rows = [record(101), record(900, parent: 101, path: "/Applications/DevSweep.app/Contents/MacOS/DevSweep")]
        XCTAssertTrue(policy.candidates(records: rows, simulators: []).isEmpty)
    }

    func testMasQueriesIncludePipeButInstallationIsProtected() {
        let rows = [
            record(101, parent: 800, path: "/bin/zsh", command: "/bin/zsh -c mas list | head -5"),
            record(102, parent: 101, path: "/opt/homebrew/bin/mas", command: "/opt/homebrew/bin/mas list"),
            record(103, parent: 101, path: "/usr/bin/head", command: "head -5"),
            record(104, path: "/opt/homebrew/bin/mas", command: "mas install --force 497799835")
        ]
        let items = policy.candidates(records: rows, simulators: [])
        XCTAssertEqual(items.count, 2)
        XCTAssertTrue(items.first { $0.root.pid == 101 }!.canClean)
        XCTAssertEqual(items.first { $0.root.pid == 101 }!.members.count, 3)
        XCTAssertFalse(items.first { $0.root.pid == 104 }!.canClean)
    }

    func testMasQueryDoesNotTerminateUnrelatedSiblingOrInstallation() {
        for sibling in [
            record(103, parent: 101, path: "/opt/homebrew/bin/mas", command: "mas install 123"),
            record(103, parent: 101, path: "/usr/bin/curl", command: "curl example.com")
        ] {
            let rows = [
                record(101, path: "/bin/zsh", command: "/bin/zsh -c mas list"),
                record(102, parent: 101, path: "/opt/homebrew/bin/mas", command: "mas list"), sibling
            ]
            XCTAssertFalse(policy.candidates(records: rows, simulators: []).first!.canClean)
        }
    }

    func testOnlyOldCodexCrashpadIsOffered() {
        let prefix = "/Applications/ChatGPT.app/Contents/Frameworks/Codex Framework.framework/Versions/"
        let rows = [
            record(101, path: prefix + "154/Helpers/browser_crashpad_handler"),
            record(102, path: prefix + "155/Helpers/browser_crashpad_handler"),
            record(103, path: prefix + "155/Helpers/Codex (Renderer)")
        ]
        XCTAssertEqual(policy.candidates(records: rows, simulators: []).map { $0.root.pid }, [101])
        XCTAssertTrue(policy.candidates(records: Array(rows.prefix(2)), simulators: []).isEmpty)
    }

    func testDeletedCrashpadRecoveryRequiresExactPathAndKernelName() {
        let path = "/Applications/ChatGPT.app/Contents/Frameworks/Codex Framework.framework/Versions/154.0.8037.57/Helpers/browser_crashpad_handler"
        XCTAssertEqual(BackgroundProcessInspector.deletedCodexCrashpadPath(
            command: path + " --monitor-self", kernelName: "browser_crashpad_handler"
        ), path)
        XCTAssertNil(BackgroundProcessInspector.deletedCodexCrashpadPath(command: path, kernelName: "node"))
        XCTAssertNil(BackgroundProcessInspector.deletedCodexCrashpadPath(
            command: path.replacingOccurrences(of: "154.0.8037.57", with: "../../Other"), kernelName: "browser_crashpad_handler"
        ))
        XCTAssertNil(BackgroundProcessInspector.deletedCodexCrashpadPath(
            command: "/Other/App/browser_crashpad_handler", kernelName: "browser_crashpad_handler"
        ))
    }

    func testSimulatorIsProtectedDuringBuildTestOrUnknownTestIdentity() {
        for process in [
            record(102, path: "/usr/bin/xcodebuild", command: "xcodebuild build"),
            record(102, path: "/usr/bin/xctest"),
            record(102, path: "/tmp/AppUITests-Runner.app/AppUITests-XCTRunner"),
            record(102, path: "", command: "xcodebuild test", start: 0)
        ] {
            let items = policy.candidates(records: [simulatorRoot(), process], simulators: [simulator])
            XCTAssertEqual(items.count, 1)
            XCTAssertFalse(items[0].canClean)
        }
        XCTAssertTrue(policy.candidates(records: [simulatorRoot()], simulators: [simulator]).first!.canClean)
    }

    func testProcessCleanupRejectsReusedPIDOrChangedTreeBeforeSignaling() throws {
        let original = record(101)
        let item = policy.candidates(records: [original], simulators: []).first!
        for changed in [
            [record(101, start: 200)],
            [original, record(102, parent: 101, path: "/Users/dev/.agent-browser/browsers/chrome/Chrome")],
            [record(101, parent: 800)],
            [record(101, command: "agent-browser changed-arguments")]
        ] {
            let processes = FakeProcesses(changed)
            let signals = FakeSignaler(processes)
            let cleaner = BackgroundProcessCleaner(processes: processes, simulators: FakeSimulators([]), signaler: signals, policy: policy)
            XCTAssertThrowsError(try cleaner.clean(item))
            XCTAssertTrue(signals.sent.isEmpty)
        }
    }

    func testProcessCleanupStopsOwnerBeforeDescendantsAndVerifiesExit() throws {
        let rows = [record(101), record(102, parent: 101, path: "/Users/dev/.agent-browser/browsers/chrome/Chrome")]
        let item = policy.candidates(records: rows, simulators: []).first!
        let processes = FakeProcesses(rows)
        let signals = FakeSignaler(processes)
        try BackgroundProcessCleaner(processes: processes, simulators: FakeSimulators([]), signaler: signals, policy: policy).clean(item)
        XCTAssertEqual(signals.sent, [101, 102])
        XCTAssertTrue(processes.records.isEmpty)
    }

    func testProcessThatIgnoresTerminationReportsFailureWithoutForceKill() {
        let rows = [record(101)]
        let processes = FakeProcesses(rows)
        let signals = FakeSignaler(processes)
        signals.exitsOnSignal = false
        let cleaner = BackgroundProcessCleaner(
            processes: processes, simulators: FakeSimulators([]), signaler: signals, policy: policy, exitTimeout: 0
        )
        XCTAssertThrowsError(try cleaner.clean(policy.candidates(records: rows, simulators: []).first!)) {
            XCTAssertEqual($0 as? BackgroundCleanupError, .stillRunning)
        }
        XCTAssertEqual(signals.sent, [101])
    }

    func testSimulatorCleanupUsesShutdownAndPreservesDevice() throws {
        let processes = FakeProcesses([simulatorRoot()])
        let devices = FakeSimulators([simulator])
        let signals = FakeSignaler(processes)
        let item = policy.candidates(records: processes.records, simulators: devices.devices).first!
        try BackgroundProcessCleaner(processes: processes, simulators: devices, signaler: signals, policy: policy).clean(item)
        XCTAssertEqual(devices.shutdowns, [udid])
        XCTAssertTrue(signals.sent.isEmpty)
    }

    func testSimulatorCleanupRechecksTestsAndRebootIdentity() {
        let original = simulatorRoot()
        let item = policy.candidates(records: [original], simulators: [simulator]).first!
        for rows in [
            [original, record(102, path: "/usr/bin/xcodebuild", command: "xcodebuild test")],
            [record(101, path: original.identity.executablePath, command: original.command, start: 200)]
        ] {
            let processes = FakeProcesses(rows)
            let devices = FakeSimulators([simulator])
            XCTAssertThrowsError(try BackgroundProcessCleaner(
                processes: processes, simulators: devices, signaler: FakeSignaler(processes), policy: policy
            ).clean(item))
            XCTAssertTrue(devices.shutdowns.isEmpty)
        }
    }

    func testInspectionFailureCannotTurnIntoPermissionToClean() {
        let rows = [record(101)]
        let processes = FakeProcesses(rows)
        processes.failSnapshot = true
        let signals = FakeSignaler(processes)
        let cleaner = BackgroundProcessCleaner(processes: processes, simulators: FakeSimulators([]), signaler: signals, policy: policy)
        XCTAssertThrowsError(try cleaner.clean(policy.candidates(records: rows, simulators: []).first!))
        XCTAssertTrue(signals.sent.isEmpty)
    }

    func testUnverifiableLiveProcessIsNotReportedAsExited() {
        let rows = [record(101)]
        let item = policy.candidates(records: rows, simulators: []).first!
        let processes = FakeProcesses(rows)
        processes.failIdentity = true
        let signals = FakeSignaler(processes)
        XCTAssertThrowsError(try BackgroundProcessCleaner(
            processes: processes, simulators: FakeSimulators([]), signaler: signals, policy: policy
        ).clean(item))
        XCTAssertTrue(signals.sent.isEmpty)
    }

    func testNativeTerminationRejectsChangedIdentityAndEndsOnlyTestOwnedProcess() throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sleep")
        task.arguments = ["10"]
        try task.run()
        defer {
            if task.isRunning { task.terminate() }
            task.waitUntilExit()
        }
        let inspector = BackgroundProcessInspector()
        let identity = try XCTUnwrap(inspector.currentIdentity(pid: task.processIdentifier))
        let signaler = BackgroundProcessSignaler(inspector: inspector)
        let changed = BackgroundProcessIdentity(
            pid: identity.pid, uid: identity.uid, startSeconds: identity.startSeconds + 1,
            startMicroseconds: identity.startMicroseconds, executablePath: identity.executablePath
        )
        XCTAssertThrowsError(try signaler.terminate(changed))
        XCTAssertTrue(task.isRunning)
        XCTAssertThrowsError(try signaler.terminate(try XCTUnwrap(inspector.currentIdentity(pid: getpid()))))
        try signaler.terminate(identity)
        let deadline = Date().addingTimeInterval(2)
        while task.isRunning && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertFalse(task.isRunning)
    }

    func testNativeProcessSnapshotAndReadOnlyScan() throws {
        let inspector = BackgroundProcessInspector()
        let identity = try XCTUnwrap(inspector.currentIdentity(pid: getpid()))
        XCTAssertEqual(identity.uid, getuid())
        XCTAssertTrue(identity.isVerified)
        XCTAssertLessThanOrEqual(identity.startedAt, Date())
        XCTAssertTrue(try inspector.snapshot().contains { $0.identity == identity })
        // A real read-only scan exercises ps/libproc and simctl integration;
        // it neither starts a simulator nor sends a signal.
        let report = try BackgroundProcessScanner().scan()
        print("Background scan: \(report.items.count) candidates, \(report.warnings.count) warnings")
        for item in report.items {
            print("  \(item.title): PID \(item.root.pid), \(item.members.count) processes, \(item.canClean ? "review" : "protected")")
        }
    }
}

private final class FakeProcesses: BackgroundProcessInspecting {
    var records: [BackgroundProcessRecord]
    var failSnapshot = false
    var failIdentity = false
    init(_ records: [BackgroundProcessRecord]) { self.records = records }
    func snapshot() throws -> [BackgroundProcessRecord] {
        if failSnapshot { throw BackgroundCleanupError.unavailable("ps failed") }
        return records
    }
    func currentIdentity(pid: Int32) -> BackgroundProcessIdentity? {
        failIdentity ? nil : records.first { $0.pid == pid }?.identity
    }
    func hasExited(pid: Int32) -> Bool { !records.contains { $0.pid == pid } }
}

private final class FakeSignaler: BackgroundProcessSignaling {
    let processes: FakeProcesses
    var sent: [Int32] = []
    var exitsOnSignal = true
    init(_ processes: FakeProcesses) { self.processes = processes }
    func terminate(_ identity: BackgroundProcessIdentity) throws {
        sent.append(identity.pid)
        if exitsOnSignal { processes.records.removeAll { $0.identity == identity } }
    }
}

private final class FakeSimulators: BackgroundSimulatorInspecting {
    var devices: [BackgroundSimulator]
    var shutdowns: [String] = []
    init(_ devices: [BackgroundSimulator]) { self.devices = devices }
    func bootedDevices() throws -> [BackgroundSimulator] { devices }
    func shutdown(udid: String) throws {
        shutdowns.append(udid)
        devices.removeAll { $0.udid == udid }
    }
}
