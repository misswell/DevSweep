import Foundation
import XCTest
@testable import DevSweep

final class ToolCleanupTests: XCTestCase {
    func testGitHubCLICleanupUsesOfficialCommand() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("xdg/gh")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)

        let runner = StubProcessRunner(results: [ProcessResult(status: 0, stdout: Data(), stderr: Data(), timedOut: false)])
        let executor = ToolCleanupExecutor(
            environment: ["XDG_CACHE_HOME": root.appendingPathComponent("xdg").path],
            home: root,
            processRunner: runner,
            processInspector: StubProcessInspector(lines: []),
            executableLocator: StubExecutableLocator(path: root.appendingPathComponent("bin/gh"))
        )

        XCTAssertNoThrow(try executor.execute(action: .githubCLI, cacheRoot: cache))
        XCTAssertEqual(runner.calls.first?.arguments, ["config", "clear-cache"])
    }

    func testBusyGitHubCLISkipsWithoutRunningCommand() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("xdg/gh")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let runner = StubProcessRunner(results: [])
        let executor = ToolCleanupExecutor(
            environment: ["XDG_CACHE_HOME": root.appendingPathComponent("xdg").path],
            home: root,
            processRunner: runner,
            processInspector: StubProcessInspector(lines: ["123 gh auth status"]),
            executableLocator: StubExecutableLocator(path: root.appendingPathComponent("bin/gh"))
        )

        XCTAssertThrowsError(try executor.execute(action: .githubCLI, cacheRoot: cache)) { error in
            XCTAssertEqual(error as? ToolCleanupError, .processBusy("GitHub CLI"))
        }
        XCTAssertTrue(runner.calls.isEmpty)
    }

    func testUnknownProcessStateFailsClosed() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("xdg/gh")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let runner = StubProcessRunner(results: [])
        let executor = ToolCleanupExecutor(
            environment: ["XDG_CACHE_HOME": root.appendingPathComponent("xdg").path],
            home: root,
            processRunner: runner,
            processInspector: StubProcessInspector(lines: nil),
            executableLocator: StubExecutableLocator(path: root.appendingPathComponent("bin/gh"))
        )

        XCTAssertThrowsError(try executor.execute(action: .githubCLI, cacheRoot: cache)) { error in
            XCTAssertEqual(error as? ToolCleanupError, .processStateUnavailable("GitHub CLI"))
        }
        XCTAssertTrue(runner.calls.isEmpty)
    }

    func testUnsafeOwnerPathIsRejected() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("wrong")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let runner = StubProcessRunner(results: [ProcessResult(status: 0, stdout: Data(), stderr: Data(), timedOut: false)])
        let executor = ToolCleanupExecutor(
            environment: ["XDG_CACHE_HOME": root.appendingPathComponent("xdg").path],
            home: root,
            processRunner: runner,
            processInspector: StubProcessInspector(lines: []),
            executableLocator: StubExecutableLocator(path: root.appendingPathComponent("bin/gh"))
        )

        XCTAssertThrowsError(try executor.execute(action: .githubCLI, cacheRoot: cache)) { error in
            XCTAssertEqual(error as? ToolCleanupError, .unsafeCachePath)
        }
        XCTAssertTrue(runner.calls.isEmpty)
    }

    func testCommandFailureAndTimeoutAreReported() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("xdg/gh")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)

        for result in [
            ProcessResult(status: 2, stdout: Data(), stderr: Data("failed".utf8), timedOut: false),
            ProcessResult(status: 9, stdout: Data(), stderr: Data(), timedOut: true)
        ] {
            let runner = StubProcessRunner(results: [result])
            let executor = ToolCleanupExecutor(
                environment: ["XDG_CACHE_HOME": root.appendingPathComponent("xdg").path],
                home: root,
                processRunner: runner,
                processInspector: StubProcessInspector(lines: []),
                executableLocator: StubExecutableLocator(path: root.appendingPathComponent("bin/gh"))
            )

            XCTAssertThrowsError(try executor.execute(action: .githubCLI, cacheRoot: cache)) { error in
                if result.timedOut {
                    XCTAssertEqual(error as? ToolCleanupError, .commandTimedOut("GitHub CLI"))
                } else {
                    XCTAssertEqual(error as? ToolCleanupError, .commandFailed("failed"))
                }
            }
        }
    }

    func testPnpmAndUVRejectRelativeReportedPaths() throws {
        let runner = StubProcessRunner(results: [
            ProcessResult(status: 0, stdout: Data("relative/store\n".utf8), stderr: Data(), timedOut: false),
            ProcessResult(status: 0, stdout: Data("relative/cache\n".utf8), stderr: Data(), timedOut: false)
        ])
        let executable = URL(fileURLWithPath: "/tmp/fake-tool")
        let home = URL(fileURLWithPath: "/tmp/fake-home")

        XCTAssertNil(PnpmSupport.storeURL(executable: executable, home: home, processRunner: runner))
        XCTAssertNil(UVSupport.cacheURL(executable: executable, home: home, processRunner: runner))
        XCTAssertEqual(runner.calls.map(\.arguments), [["store", "path"], ["cache", "dir"]])
    }

    func testToolCommandIsRecheckedAgainstWhitelist() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let item = CacheItem(
            category: "CI/CD",
            name: "GitHub CLI",
            path: cache,
            size: 1,
            kind: .toolCommand,
            toolAction: .githubCLI,
            isSelected: false
        )
        let context = DeletionContext(
            whitelistedPaths: [cache],
            projectRoots: [root],
            allowedPaths: [cache]
        )
        let executor = RecordingToolExecutor()
        let report = CacheCleaner.clean([item], context: context, toolExecutor: executor)

        XCTAssertTrue(report.removed.isEmpty)
        XCTAssertTrue(executor.actions.isEmpty)
        XCTAssertEqual(report.failures.first?.1, DeletionValidationError.whitelisted.localizedDescription)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DevSweepToolTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private struct RecordedCall {
    let executable: URL
    let arguments: [String]
}

private final class StubProcessRunner: ProcessRunning {
    var results: [ProcessResult]
    var calls: [RecordedCall] = []

    init(results: [ProcessResult]) {
        self.results = results
    }

    func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]?,
        timeout: TimeInterval
    ) -> ProcessResult? {
        calls.append(RecordedCall(executable: executable, arguments: arguments))
        guard !results.isEmpty else { return nil }
        return results.removeFirst()
    }
}

private struct StubProcessInspector: ProcessInspecting {
    let lines: [String]?

    func matchingProcessLines(containing token: String) -> [String]? {
        lines
    }
}

private struct StubExecutableLocator: ExecutableLocating {
    let path: URL

    func executableURL(named name: String, environment: [String: String]) -> URL? {
        path
    }
}

private final class RecordingToolExecutor: ToolCommandExecuting {
    var actions: [ToolCleanupAction] = []

    func execute(action: ToolCleanupAction, cacheRoot: URL) throws {
        actions.append(action)
    }
}
