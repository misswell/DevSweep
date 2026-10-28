import Darwin
import Foundation
import XCTest
@testable import DevSweep

/// 外部命令超时的硬性约束：声明的超时必须真的返回。
/// 关键回归场景是「父进程退出 / 超时后，孙进程仍握着 stdout 管道」，
/// 旧实现只 terminate 直接子进程，然后无期限 `readGroup.wait()`。
final class ProcessTimeoutTests: XCTestCase {
    private let shellURL = URL(fileURLWithPath: "/bin/sh")

    // MARK: - 超时必须返回

    func testTimeoutReturnsPromptlyAndMarksTimedOut() throws {
        let marker = uniqueSleepMarker()

        let run = runBounded(budget: 12) {
            ProcessRunner.shared.run(
                executable: self.shellURL,
                arguments: ["-c", "sleep \(marker); echo done"],
                environment: nil,
                timeout: 1
            )
        }

        let result = try XCTUnwrap(run.raw as? ProcessResult, "超时后应当返回结果，而不是一直阻塞")
        XCTAssertTrue(result.timedOut, "超时必须如实标记在 ProcessResult.timedOut 上")
        XCTAssertLessThan(run.elapsed, 5, "1 秒超时必须在预算内返回，实测 \(run.elapsed)s")
    }

    func testTimeoutKillsWholeProcessGroupNotJustDirectChild() throws {
        let marker = uniqueSleepMarker()

        let run = runBounded(budget: 12) {
            ProcessGroupExecutor.execute(
                executable: self.shellURL,
                arguments: ["-c", "sleep \(marker); echo done"],
                environment: nil,
                timeout: 1
            )
        }

        let outcome = try XCTUnwrap(run.raw as? ProcessGroupOutcome)
        XCTAssertTrue(outcome.result.timedOut)
        XCTAssertFalse(outcome.cancelled)
        XCTAssertLessThan(run.elapsed, 5)

        // sh 只是父进程；`sleep` 是孙进程。旧实现只杀 sh，sleep 会活下来。
        let pattern = "sleep \(marker)"
        XCTAssertTrue(
            survivors(matching: pattern, within: 3).isEmpty,
            "进程组里的孙进程没有结束: \(survivors(matching: pattern, within: 0.01))"
        )
    }

    func testTimeoutZeroStillReturns() throws {
        let run = runBounded(budget: 12) {
            ProcessRunner.shared.run(
                executable: self.shellURL,
                arguments: ["-c", "sleep 30"],
                environment: nil,
                timeout: 0
            )
        }

        let result = try XCTUnwrap(run.raw as? ProcessResult)
        XCTAssertTrue(result.timedOut)
        XCTAssertLessThan(run.elapsed, 5)
    }

    // MARK: - 父进程先退出、后代进程仍握着管道

    func testGrandchildHoldingStdoutAfterParentExitStillReturns() throws {
        let marker = uniqueSleepMarker()

        // 用 fork 精确构造「父进程退出、后代进程继续持有 stdout 写端」：
        //   1. 父 shell 立刻 exit 0；
        //   2. 后代进程继承父进程的 stdout 并持续存活（sleep 到 marker 秒后自毁）。
        // 于是这份管道没有 EOF，旧实现会卡在 readGroup.wait()。子进程也不能自己先死，
        // 否则它就不再握着管道，测不到这个场景。
        let script = """
        ( trap '' TERM; sleep \(marker) ) &
        exec sleep \(marker)
        """
        // 上面两条都持着 stdout：exec sleep 是「直接子进程」，后台兜底 sleep 也持着 stdout。
        let run = runBounded(budget: 20) {
            ProcessRunner.shared.run(
                executable: self.shellURL,
                arguments: ["-c", script],
                environment: nil,
                timeout: 1
            )
        }

        let result = try XCTUnwrap(run.raw as? ProcessResult, "后代进程握着管道时也必须返回")
        XCTAssertTrue(result.timedOut, "父进程和后代都在长睡，1s 超时必须标记超时")
        XCTAssertLessThan(run.elapsed, 5, "返回被管道 EOF 拖住了，实测 \(run.elapsed)s")

        // 1s 超时后必须结束整个进程组，所有 sleep 都不该留下。
        let pattern = "sleep \(marker)"
        XCTAssertTrue(
            survivors(matching: pattern, within: 3).isEmpty,
            "进程组里的后代没有结束: \(survivors(matching: pattern, within: 0.01))"
        )
    }

    func testCancellationReturnsAndMarksCancelled() throws {
        let marker = uniqueSleepMarker()
        let cancelledFlag = FlagBox()
        cancelledFlag.set(true)

        let run = runBounded(budget: 12) {
            ProcessGroupExecutor.execute(
                executable: self.shellURL,
                arguments: ["-c", "sleep \(marker); echo done"],
                environment: nil,
                timeout: 30,
                isCancelled: { cancelledFlag.value }
            )
        }

        let outcome = try XCTUnwrap(run.raw as? ProcessGroupOutcome)
        XCTAssertTrue(outcome.cancelled, "取消路径必须能被区分出来")
        XCTAssertFalse(outcome.result.timedOut, "取消不是超时")
        XCTAssertLessThan(run.elapsed, 5)
    }

    // MARK: - 正常路径行为不变

    func testFastCommandKeepsStdoutStderrAndStatus() throws {
        let run = runBounded(budget: 12) {
            ProcessRunner.shared.run(
                executable: self.shellURL,
                arguments: ["-c", "echo out-line; echo err-line 1>&2; exit 0"],
                environment: nil,
                timeout: 10
            )
        }

        let result = try XCTUnwrap(run.raw as? ProcessResult)
        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "out-line\n")
        XCTAssertEqual(String(decoding: result.stderr, as: UTF8.self), "err-line\n")
        XCTAssertLessThan(run.elapsed, 5)
    }

    func testNonZeroExitAndStderrPreserved() throws {
        let run = runBounded(budget: 12) {
            ProcessRunner.shared.run(
                executable: self.shellURL,
                arguments: ["-c", "echo boom 1>&2; exit 3"],
                environment: nil,
                timeout: 10
            )
        }

        let result = try XCTUnwrap(run.raw as? ProcessResult)
        XCTAssertEqual(result.status, 3)
        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(String(decoding: result.stderr, as: UTF8.self), "boom\n")
    }

    func testMissingExecutableReturnsNilInsteadOfHanging() throws {
        let run = runBounded(budget: 12) {
            ProcessRunner.shared.run(
                executable: URL(fileURLWithPath: "/nonexistent/definitely-not-a-binary"),
                arguments: [],
                environment: nil,
                timeout: 2
            )
        }

        XCTAssertTrue(run.completed, "启动失败必须立即返回")
        XCTAssertTrue(run.raw is NSNull, "缺失可执行文件必须返回 nil，实际是 \(String(describing: run.raw))")
        XCTAssertLessThan(run.elapsed, 5)
    }

    func testLargeStdoutIsFullyRead() throws {
        let run = runBounded(budget: 20) {
            ProcessRunner.shared.run(
                executable: self.shellURL,
                arguments: ["-c", "for i in $(seq 1 4000); do echo line-$i; done"],
                environment: nil,
                timeout: 15
            )
        }

        let result = try XCTUnwrap(run.raw as? ProcessResult)
        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.status, 0)
        let lines = String(decoding: result.stdout, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 4000)
        XCTAssertEqual(lines.last, "line-4000")
    }

    // MARK: - 有界执行 + 有界探测

    /// 在后台线程执行 `body`，用 XCTestExpectation 做有界等待。
    /// 目的：即使被测代码真的挂住，测试也只会在预算耗尽时失败，而不会让整个 test run 卡死。
    private func runBounded<T>(
        budget: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: @escaping () -> T
    ) -> (completed: Bool, raw: Any?, elapsed: TimeInterval) {
        let started = Date()
        let box = ValueBox()
        let expectation = XCTestExpectation(description: "外部命令执行完成")
        DispatchQueue.global(qos: .userInitiated).async {
            let value = body()
            // Optional<T>.none 直接塞进 Any? 会变成「有值但值为 nil」的 Any，
            // 统一折成 NSNull 才能可靠区分「返回 nil」与「返回结果」。
            // 显式拆 Optional：`value` 本身是 Optional<T>，直接塞进 Any 会变成
            // "Optional(nil)"，必须先判断 .none 再折成 NSNull。
            let erased = value as Any
            if Mirror(reflecting: erased).displayStyle == .optional,
               Mirror(reflecting: erased).children.isEmpty {
                box.set(NSNull())
            } else {
                box.set(erased)
            }
            expectation.fulfill()
        }

        let waiter = XCTWaiter()
        let outcome = waiter.wait(for: [expectation], timeout: budget)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(
            outcome, .completed,
            "外部命令没有在 \(budget)s 预算内返回（超时/收尾路径阻塞）",
            file: file, line: line
        )
        return (outcome == .completed, box.value, elapsed)
    }

    /// 有界轮询：返回期限内仍然存活、命令行匹配 pattern 的进程行。
    private func survivors(matching pattern: String, within seconds: TimeInterval) -> [String] {
        let deadline = Date().addingTimeInterval(seconds)
        var matches = matchingProcesses(pattern)
        while !matches.isEmpty && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
            matches = matchingProcesses(pattern)
        }
        return matches
    }

    private func matchingProcesses(_ pattern: String) -> [String] {
        guard let result = ProcessRunner.shared.run(
            executable: URL(fileURLWithPath: "/usr/bin/pgrep"),
            arguments: ["-fl", pattern],
            environment: nil,
            timeout: 3
        ), !result.timedOut else {
            return []
        }
        return String(decoding: result.stdout, as: UTF8.self)
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    /// 每次测试用不同的 sleep 时长，pgrep 时不会误伤别的测试或用户进程。
    private func uniqueSleepMarker() -> String {
        String(format: "%.6f", 30 + Double(Int.random(in: 100_000...999_999)) / 1_000_000)
    }
}

private final class ValueBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Any?

    func set(_ value: Any?) {
        lock.lock()
        stored = value
        lock.unlock()
    }

    var value: Any? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

private final class FlagBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false

    func set(_ value: Bool) {
        lock.lock()
        stored = value
        lock.unlock()
    }

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}
