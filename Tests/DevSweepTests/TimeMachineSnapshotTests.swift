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
        /// 删除后需要多少次列表刷新才真正消失；用来模拟系统延迟卸载。
        var deletionLagsListCalls = 0
        var deleteCalls: [[String]] = []
        var listCalls = 0
        private var pendingRemoval: String?

        func run(executable: URL, arguments: [String], environment: [String: String]?, timeout: TimeInterval) -> ProcessResult? {
            if arguments.first == "listlocalsnapshots" {
                listCalls += 1
                if listTimesOut {
                    return ProcessResult(status: 0, stdout: Data(), stderr: Data(), timedOut: true)
                }
                if listFails {
                    return ProcessResult(status: 1, stdout: Data(), stderr: Data("boom".utf8), timedOut: false)
                }
                if let pending = pendingRemoval {
                    if deletionLagsListCalls > 1 {
                        deletionLagsListCalls -= 1
                    } else {
                        listOutput = listOutput
                            .split(whereSeparator: \.isNewline)
                            .filter { !$0.contains(pending) }
                            .joined(separator: "\n")
                        pendingRemoval = nil
                    }
                }
                return ProcessResult(status: 0, stdout: Data(listOutput.utf8), stderr: Data(), timedOut: false)
            }
            if arguments.first == "deletelocalsnapshots" {
                deleteCalls.append(arguments)
                if deleteRemoves, arguments.count == 2 {
                    let token = arguments[1]
                    if deletionLagsListCalls > 0 {
                        // 模拟「命令已生效，但列表要过几次刷新才更新」。
                        pendingRemoval = token
                    } else {
                        listOutput = listOutput
                            .split(whereSeparator: \.isNewline)
                            .filter { !$0.contains(token) }
                            .joined(separator: "\n")
                    }
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

    /// 系统在 tmutil 返回后才把快照从列表摘掉：单次检查会误报失败，
    /// 轮询复核必须把它等到消失为止。
    func testDeleteWaitsForLaggedRemovalBeforeReportingFailure() throws {
        let runner = Runner()
        runner.listOutput = sample
        runner.deletionLagsListCalls = 3   // 头几次刷新仍能看到
        let snapshot = try XCTUnwrap(TimeMachineSnapshotCleaner.parseSnapshots(from: sample).first)

        XCTAssertNoThrow(try TimeMachineSnapshotCleaner.delete(
            snapshot, runner: runner,
            verificationTimeout: 5, pollInterval: 0, sleep: { _ in }
        ), "延迟消失不应被判为失败")
    }

    func testDeleteFailsWhenTmutilReturnsZeroButSnapshotRemains() throws {
        let runner = Runner()
        runner.listOutput = sample
        runner.deleteRemoves = false
        let snapshot = try XCTUnwrap(TimeMachineSnapshotCleaner.parseSnapshots(from: sample).first)

        // 轮询复核会一直等到超时，所以这里必须注入短超时，否则单个用例要跑满 30 秒。
        XCTAssertThrowsError(try TimeMachineSnapshotCleaner.delete(
            snapshot, runner: runner,
            verificationTimeout: 0.2, pollInterval: 0, sleep: { _ in }
        )) { error in
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
        // .review 而非 .manual：.manual 会让 UI 的复选框与「清理这一项」直接禁用，
        // 快照就在界面里彻底没法删（这是外部审查发现的 P1）。
        XCTAssertTrue(items.allSatisfy { $0.risk == .review })
        XCTAssertTrue(items.allSatisfy { $0.isSelected == false }, "快照永不默认勾选")
        XCTAssertFalse(CleanupSelection.isBatchSelectable(items[0]), "快照不得进入批量选择")
        XCTAssertEqual(Set(items.compactMap(\.identifier)),
                       ["2026-10-27-151925", "2026-10-26-090000"])
    }

    /// 快照条目不能用 "/" 当路径：那会命中受保护路径校验，并且在界面上看起来
    /// 像一个可以「删除整个根目录」的条目。这里钉住它指向快照卷、且能通过校验。
    func testSnapshotItemPointsAtVolumeNotRootAndValidates() throws {
        let runner = Runner()
        runner.listOutput = sample
        let lister = TimeMachineSnapshotLister(runner: runner)
        var collector = ScanCollector()
        let items = CacheScanner.timeMachineSnapshotItems(snapshotLister: lister, collector: &collector)

        let first = try XCTUnwrap(items.first)
        XCTAssertNotEqual(first.path.standardizedFileURL.path, "/", "不能用根目录当快照路径")

        // 用真实 home 构造上下文，确认这条条目不会被当成受保护路径直接拒掉。
        let home = FileManager.default.homeDirectoryForCurrentUser
        let context = DeletionContext(
            whitelistedPaths: [], projectRoots: [], home: home,
            allowedPaths: [first.path]
        )
        XCTAssertNoThrow(try DeletionValidator.validate(item: first, context: context),
                         "快照条目应当能通过校验；真正的删除由 tmutil 执行器负责")
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
