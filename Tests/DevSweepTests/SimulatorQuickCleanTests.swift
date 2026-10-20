import XCTest
@testable import DevSweep

final class SimulatorQuickCleanTests: XCTestCase {
    private let udid = "00EADC08-A9A0-4820-BEC3-E4EA016ECB15"

    // Scripted fake; each test owns its runner and does not mutate it while a store task runs.
    private final class Runner: ProcessRunning, @unchecked Sendable {
        var state = "Shutdown"
        var processes = "1 /sbin/launchd\n123 /usr/bin/ps"
        var missing = false
        var failListing = false
        var failProcessList = false
        var failDelete = false
        var onList: (() -> Void)?
        var deletes: [[String]] = []
        var path = ""
        var deviceID = "00EADC08-A9A0-4820-BEC3-E4EA016ECB15"
        func run(executable: URL, arguments: [String], environment: [String: String]?, timeout: TimeInterval) -> ProcessResult? {
            if executable.path == "/bin/ps" {
                if failProcessList { return nil }
                return ProcessResult(status: 0, stdout: Data(processes.utf8), stderr: Data(), timedOut: false)
            }
            if arguments.prefix(2) == ["simctl", "delete"] {
                deletes.append(arguments)
                return ProcessResult(status: failDelete ? 1 : 0, stdout: Data(), stderr: Data(), timedOut: false)
            }
            if failListing { return nil }
            onList?()
            let devices: [[String: String]] = missing ? [] : [
                ["udid": deviceID, "name": "iPhone", "state": state, "dataPath": path]
            ]
            let data = try! JSONSerialization.data(withJSONObject: ["devices": ["iOS-27-0": devices]])
            return ProcessResult(status: 0, stdout: data, stderr: Data(), timedOut: false)
        }
    }

    private func fixture() throws -> (URL, URL, Runner, CacheItem, DeletionContext) {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        let path = home.appendingPathComponent("Library/Developer/CoreSimulator/Devices/\(udid)")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        let runner = Runner()
        runner.path = path.appendingPathComponent("data").path
        let item = CacheItem(category: "CoreSimulator", name: "iPhone", path: path, size: 10,
                             risk: .review, kind: .simulatorDevice, identifier: udid)
        let context = DeletionContext(whitelistedPaths: [], projectRoots: [], home: home, allowedPaths: [path])
        return (home, path, runner, item, context)
    }

    private func entry(path: URL) -> QuickCleanEntry {
        QuickCleanEntry(path: path.path, displayName: "iPhone", category: "CoreSimulator", dateAdded: Date(),
                        targetKind: .simulatorDevice, identifier: udid)
    }

    func testShutdownDeviceUsesOnlyExactSimctlDelete() throws {
        let (home, path, runner, item, context) = try fixture()
        defer { try? FileManager.default.removeItem(at: home) }
        let report = CacheCleaner.clean([item], context: context, simulatorExecutor: SimulatorCleanupExecutor(runner: runner))
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertEqual(report.removed.count, 1)
        XCTAssertEqual(runner.deletes, [["simctl", "delete", udid]])
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path), "The fake command never deletes real simulator data")
    }

    func testBootedUnknownMissingAndUnavailableDevicesNeverDelete() throws {
        for scenario in ["Booted", "Unknown", "missing", "unavailable", "wrongPath", "wrongUDID"] {
            let (home, _, runner, item, context) = try fixture()
            defer { try? FileManager.default.removeItem(at: home) }
            switch scenario {
            case "missing": runner.missing = true
            case "unavailable": runner.failListing = true
            case "wrongPath": runner.path += "/other"
            case "wrongUDID": runner.deviceID = UUID().uuidString
            default: runner.state = scenario
            }
            let report = CacheCleaner.clean([item], context: context, simulatorExecutor: SimulatorCleanupExecutor(runner: runner))
            XCTAssertEqual(report.failures.count, 1, scenario)
            XCTAssertTrue(runner.deletes.isEmpty, scenario)
        }
    }

    func testBuildTestOrUnknownProcessStateNeverDeletes() throws {
        for process in ["1 /usr/bin/xcodebuild", "1 /usr/bin/xctest", "1 /Apps/Demo.xctrunner", "", "bad row"] {
            let (home, _, runner, item, context) = try fixture()
            defer { try? FileManager.default.removeItem(at: home) }
            runner.processes = process
            let report = CacheCleaner.clean([item], context: context, simulatorExecutor: SimulatorCleanupExecutor(runner: runner))
            XCTAssertEqual(report.failures.count, 1, process)
            XCTAssertTrue(runner.deletes.isEmpty)
        }
        let (home, _, runner, item, context) = try fixture()
        defer { try? FileManager.default.removeItem(at: home) }
        runner.failProcessList = true
        XCTAssertThrowsError(try SimulatorCleanupExecutor(runner: runner).delete(item, context: context))
        XCTAssertTrue(runner.deletes.isEmpty)
    }

    func testWhiteListProtectsParentAndChildAndChangedIdentity() throws {
        for mode in ["parent", "child", "changed"] {
            let (home, path, runner, item, _) = try fixture()
            defer { try? FileManager.default.removeItem(at: home) }
            let whitelist = mode == "parent" ? [path.deletingLastPathComponent()] :
                (mode == "child" ? [path.appendingPathComponent("data")] : [])
            if mode == "changed" {
                runner.onList = {
                    try! FileManager.default.moveItem(at: path, to: path.appendingPathExtension("old"))
                    try! FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
                }
            }
            let context = DeletionContext(whitelistedPaths: whitelist, projectRoots: [], home: home, allowedPaths: [path])
            XCTAssertThrowsError(try SimulatorCleanupExecutor(runner: runner).delete(item, context: context))
            XCTAssertTrue(runner.deletes.isEmpty, mode)
        }
    }

    func testSimulatorAndManualEntriesNeverBecomeTrashItems() throws {
        let (home, path, runner, item, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: home) }
        let simulator = entry(path: path)
        XCTAssertEqual(QuickCleanInspector.registrationKind(for: item, home: home), .simulatorDevice)
        let manual = QuickCleanEntry(path: path.path, displayName: "system", category: "CoreSimulator", dateAdded: Date(), targetKind: .manual)
        XCTAssertTrue(QuickCleanInspector.executableItems(for: [simulator, manual]).isEmpty)
        let snapshots = QuickCleanInspector.snapshots(for: [simulator, manual], home: home,
                                                    simulatorInspector: SimulatorCleanupExecutor(runner: runner))
        XCTAssertTrue(snapshots[0].canClean)
        XCTAssertFalse(snapshots[1].canClean)
        runner.state = "Booted"
        XCTAssertFalse(QuickCleanInspector.snapshots(for: [simulator], home: home,
            simulatorInspector: SimulatorCleanupExecutor(runner: runner))[0].canClean)
        runner.state = "Shutdown"
        runner.missing = true
        XCTAssertFalse(QuickCleanInspector.snapshots(for: [simulator], home: home,
            simulatorInspector: SimulatorCleanupExecutor(runner: runner))[0].canClean)
    }

    func testSystemCacheCanOnlyBeCollectedAsManual() {
        for path in QuickCleanInspector.manualPaths {
            let item = CacheItem(category: "CoreSimulator", name: "system", path: URL(fileURLWithPath: path), size: 10, risk: .manual)
            XCTAssertEqual(QuickCleanInspector.registrationKind(for: item), .manual)
            XCTAssertThrowsError(try DeletionValidator.validateQuickCleanRegistration(path: item.path))
        }
        let item = CacheItem(category: "test", name: "manual", path: URL(fileURLWithPath: "/tmp/other"), size: 10, risk: .manual)
        XCTAssertNil(QuickCleanInspector.registrationKind(for: item))
        let devicePath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Developer/CoreSimulator/Devices/\(udid)")
        XCTAssertThrowsError(try DeletionValidator.validateQuickCleanRegistration(path: devicePath))
    }

    func testSimulatorCannotBeDowngradedToTrashOrRedirectedBySymlink() throws {
        let (home, path, runner, item, context) = try fixture()
        defer { try? FileManager.default.removeItem(at: home) }
        let trash = CacheItem(category: "CoreSimulator", name: "device", path: path, size: 10)
        XCTAssertThrowsError(try DeletionValidator.validate(item: trash, context: context))
        let destination = home.appendingPathComponent("replacement")
        try FileManager.default.moveItem(at: path, to: destination)
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: destination)
        XCTAssertThrowsError(try SimulatorCleanupExecutor(runner: runner).delete(item, context: context))
        XCTAssertTrue(runner.deletes.isEmpty)
    }

    @MainActor
    func testStorePersistsUDIDAndAutomaticActionsExcludeDevices() throws {
        let (home, path, runner, item, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: home) }
        let suite = "SimulatorQuickCleanTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let inspector = SimulatorCleanupExecutor(runner: runner)
        let store = DevSweepStore(defaults: defaults, home: home, simulatorInspector: inspector, simulatorExecutor: inspector)
        XCTAssertEqual(store.addToQuickClean([item]).added, 1)
        let saved = try XCTUnwrap(store.quickCleanEntries.first)
        XCTAssertEqual(saved.identifier, udid)
        XCTAssertTrue(saved.isSimulator)
        let restarted = DevSweepStore(defaults: defaults, home: home, simulatorInspector: inspector, simulatorExecutor: inspector)
        XCTAssertEqual(restarted.quickCleanEntries.first?.identifier, udid)
        store.cleanQuickClean([saved])
        store.cleanAllQuickClean()
        XCTAssertFalse(store.isCleaning)
        XCTAssertTrue(runner.deletes.isEmpty)
        XCTAssertEqual(QuickCleanInspector.snapshots(for: [entry(path: path)], home: home, simulatorInspector: inspector).count, 1)
    }
}
