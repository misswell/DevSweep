import Darwin

enum DevSweepParentTerminationResult: Equatable {
    case alreadyExited
    case terminatedBySIGTERM
    case killedBySIGKILL
    case stillRunning
}

enum DevSweepParentTermination {
    static let pollInterval: useconds_t = 100_000
    static let defaultGracefulPolls = 50
    static let defaultSignalPolls = 50

    static func ensureExited(
        pid: pid_t,
        gracefulPolls: Int = defaultGracefulPolls,
        signalPolls: Int = defaultSignalPolls,
        isAlive: (pid_t) -> Bool = { processID in
            kill(processID, 0) == 0 || errno == EPERM
        },
        sendSignal: (pid_t, Int32) -> Bool = { processID, signal in
            kill(processID, signal) == 0 || errno == ESRCH
        },
        sleep: (useconds_t) -> Void = { usleep($0) }
    ) -> DevSweepParentTerminationResult {
        guard !waitUntilExited(
            pid: pid,
            polls: gracefulPolls,
            isAlive: isAlive,
            sleep: sleep
        ) else {
            return .alreadyExited
        }

        guard sendSignal(pid, SIGTERM) else { return .stillRunning }
        if waitUntilExited(pid: pid, polls: signalPolls, isAlive: isAlive, sleep: sleep) {
            return .terminatedBySIGTERM
        }

        guard sendSignal(pid, SIGKILL) else { return .stillRunning }
        if waitUntilExited(pid: pid, polls: signalPolls, isAlive: isAlive, sleep: sleep) {
            return .killedBySIGKILL
        }

        return .stillRunning
    }

    private static func waitUntilExited(
        pid: pid_t,
        polls: Int,
        isAlive: (pid_t) -> Bool,
        sleep: (useconds_t) -> Void
    ) -> Bool {
        for _ in 0..<polls {
            if !isAlive(pid) { return true }
            sleep(pollInterval)
        }
        return !isAlive(pid)
    }
}
