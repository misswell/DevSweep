import Darwin
import XCTest
@testable import DevSweepUpdater

final class UpdaterTerminationTests: XCTestCase {
    func testEscalatesToSIGTERMWhenParentDoesNotExitGracefully() {
        var phase = 0
        var signals: [Int32] = []

        let result = DevSweepParentTermination.ensureExited(
            pid: 42,
            gracefulPolls: 2,
            signalPolls: 2,
            isAlive: { _ in phase < 3 },
            sendSignal: { _, signal in
                signals.append(signal)
                if signal == SIGTERM { phase = 3 }
                return true
            },
            sleep: { _ in phase += 1 }
        )

        XCTAssertEqual(result, .terminatedBySIGTERM)
        XCTAssertEqual(signals, [SIGTERM])
    }

    func testEscalatesToSIGKILLWhenParentIgnoresSIGTERM() {
        var phase = 0
        var signals: [Int32] = []

        let result = DevSweepParentTermination.ensureExited(
            pid: 42,
            gracefulPolls: 1,
            signalPolls: 1,
            isAlive: { _ in phase < 3 },
            sendSignal: { _, signal in
                signals.append(signal)
                if signal == SIGKILL { phase = 3 }
                return true
            },
            sleep: { _ in phase += 1 }
        )

        XCTAssertEqual(result, .killedBySIGKILL)
        XCTAssertEqual(signals, [SIGTERM, SIGKILL])
    }
}
