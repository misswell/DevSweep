import Foundation
import XCTest
@testable import DevSweep

final class TimeMachineSnapshotTests: XCTestCase {
    /// 脚本化的 tmutil 替身：绝不真的删除快照。
    private final class Runner: ProcessRunning, @unchecked Sendable {
        var listOutput = ""
        var listFails = false
        var listTimesOut = false
        /// 设置后：删掉的 token 才从列表里消失；为 false 时模拟「命令返回 0 但没删掉」。
        var deleteRemoves = true
        var deleteCalls: [[String]] = []
        var listCalls = 0

        func run(executable: URL, arguments: [String], environment: [String: String]?, timeout: TimeInterval) -> ProcessResult? {
            if arguments.first == "listlocalsnapshots" {
                listCalls += 1
                if listTimesOut {
                    return ProcessResult(status: 0, stdout: Data(), stderr: Data(), timedOut: true)
                }
                if listFails {
                    return ProcessResult(status: 1, stdout: Data(), stderr: Data("boom".utf8), timedOut: false)
                }
                return ProcessResult(status: 0, stdout: Data(listOutput.utf8), stderr: Data(), timedOut: false)
            }
            if arguments.first == "deletelocalsnapshots" {
                deleteCalls.append(arguments)
                if deleteRemoves, arguments.count == 2 {
                    let token = arguments[1]
                    listOutput = listOutput
                        .split(whereSeparator: \.isNewline)
                        .filter { !$0.contains(token) }
                        .joined(separator: "\n")
                }
                // 故意返回 0：验证我们对「返回 0 但没删掉」的处理。
                return ProcessResult(status: 0, stdout: Data(), stderr: Data(), timedOut: false)
            }
            return nil
        }
    }

    private let sample = """
    Snapshots for disk /:
    com.apple.TimeMachine.2026-10-27-151925.local
    com.apple.TimeMachine.2026-10-26-090000.local
    com.apple.os.update-1234A5678
    """

    func testParseKeepsOnlyTimeMachineSnapshots() {
        let snapshots = TimeMachineSnapshotCleaner.parseSnapshots(from: sample)
        XCTAssertEqual(snapshots.map(\.dateToken), ["2026-10-27-151925", "2026-10-26-090000"])
        XCTAssertFalse(snapshots.contains { $0.name.contains("os.update") }, "系统更新回滚点绝不能进候选")
        XCTAssertEqual(snapshots.first?.name, "com.apple.TimeMachine.2026-10-27-151925.local")
    }

    func testTokenValidationRejectsAnythingUnexpected() {
        for bad in ["", "abc", "2026-10-27", "2026-10-27-15192",
                    "2026-10-27-151925; rm -rf /", "../../etc/passwd",
                    "2026-13-45-999999"] {
            XCTAssertFalse(TimeMachineSnapshotCleaner.isValidToken(bad), bad)
        }
        XCTAssertTrue(TimeMachineSnapshotCleaner.isValidToken("2026-10-27-151925"))
        XCTAssertTrue(TimeMachineSnapshotCleaner.isValidToken("2026-10-27-151925Z"))
    }

    func testDeleteVerifiesSnapshotActuallyGone() throws {
        let runner = Runner()
        runner.listOutput = sample
        let snapshot = try XCTUnwrap(TimeMachineSnapshotCleaner.parseSnapshots(from: sample).first)

        try TimeMachineSnapshotCleaner.delete(snapshot, runner: runner)
        XCTAssertEqual(runner.deleteCalls.last, ["deletelocalsnapshots", "2026-10-27-151925"])
        // 直接调用 cleaner.delete：删除前不 list，删除后必须 list 一次确认。
        XCTAssertEqual(runner.listCalls, 1, "删除后必须重新列一次确认")
    }

    func testDeleteFailsWhenTmutilReturnsZeroButSnapshotRemains() throws {
        let runner = Runner()
        runner.listOutput = sample
        runner.deleteRemoves = false
        let snapshot = try XCTUnwrap(TimeMachineSnapshotCleaner.parseSnapshots(from: sample).first)

        XCTAssertThrowsError(try TimeMachineSnapshotCleaner.delete(snapshot, runner: runner)) { error in
            XCTAssertEqual(error as? TimeMachineSnapshotError,
                           .notRemoved("2026-10-27-151925"),
                           "tmutil 返回 0 但快照仍在时必须报错")
        }
    }

    func testInvalidTokenIsNeverPassedToTmutil() {
        let runner = Runner()
        let item = CacheItem(
            category: "Time Machine 快照", name: "bad", path: URL(fileURLWithPath: "/"),
            size: 0, risk: .manual, kind: .timeMachineSnapshot,
            identifier: "2026-10-27-151925; rm -rf /"
        )
        let executor = TimeMachineSnapshotDeletingExecutor(runner: runner)
        let context = DeletionContext(whitelistedPaths: [], projectRoots: [])
        XCTAssertThrowsError(try executor.delete(item, context: context))
        XCTAssertTrue(runner.deleteCalls.isEmpty)
    }

    func testExecutorSkipsSnapshotThatAlreadyDisappeared() throws {
        let runner = Runner()
        runner.listOutput = "Snapshots for disk /:\n"   // 已经没有快照了
        let item = CacheItem(
            category: "Time Machine 快照", name: "gone", path: URL(fileURLWithPath: "/"),
            size: 0, risk: .manual, kind: .timeMachineSnapshot,
            identifier: "2026-10-26-090000"
        )
        let executor = TimeMachineSnapshotDeletingExecutor(runner: runner)
        let context = DeletionContext(whitelistedPaths: [], projectRoots: [])
        XCTAssertNoThrow(try executor.delete(item, context: context))
        XCTAssertTrue(runner.deleteCalls.isEmpty, "已消失的快照不应再执行删除")
    }

    func testExecutorDeletesExistingSnapshot() throws {
        let runner = Runner()
        runner.listOutput = sample
        let item = CacheItem(
            category: "Time Machine 快照", name: "one", path: URL(fileURLWithPath: "/"),
            size: 0, risk: .manual, kind: .timeMachineSnapshot,
            identifier: "2026-10-26-090000"
        )
        let executor = TimeMachineSnapshotDeletingExecutor(runner: runner)
        let context = DeletionContext(whitelistedPaths: [], projectRoots: [])
        XCTAssertNoThrow(try executor.delete(item, context: context))
        XCTAssertEqual(runner.deleteCalls.last, ["deletelocalsnapshots", "2026-10-26-090000"])
    }

    func testScannerProducesUnselectedSnapshotItems() throws {
        let runner = Runner()
        runner.listOutput = sample
        let lister = TimeMachineSnapshotLister(runner: runner)
        var collector = ScanCollector()
        let items = CacheScanner.timeMachineSnapshotItems(snapshotLister: lister, collector: &collector)

        XCTAssertEqual(items.count, 2)
        XCTAssertTrue(items.allSatisfy { $0.kind == .timeMachineSnapshot })
        XCTAssertTrue(items.allSatisfy { $0.risk == .manual })
        XCTAssertTrue(items.allSatisfy { $0.isSelected == false }, "快照永不默认勾选")
        XCTAssertEqual(Set(items.compactMap(\.identifier)),
                       ["2026-10-27-151925", "2026-10-26-090000"])
    }

    func testScannerRecordsDiagnosticWhenTmutilFails() {
        let runner = Runner()
        runner.listFails = true
        let lister = TimeMachineSnapshotLister(runner: runner)
        var collector = ScanCollector()
        let items = CacheScanner.timeMachineSnapshotItems(snapshotLister: lister, collector: &collector)
        XCTAssertTrue(items.isEmpty)
        XCTAssertTrue(collector.diagnostics.contains { $0.reason.contains("Time Machine") })
    }

    func testFallbackCommandsAreCopyable() {
        let snapshots = TimeMachineSnapshotCleaner.parseSnapshots(from: sample)
        let commands = TimeMachineSnapshotCleaner.fallbackCommands(for: snapshots)
        XCTAssertEqual(commands.first, "/usr/bin/tmutil listlocalsnapshots /")
        XCTAssertEqual(commands.count, 3)
        XCTAssertTrue(commands[1].hasPrefix("/usr/bin/tmutil deletelocalsnapshots "))
    }
}
