import AppKit
import Darwin
import Foundation

private let expectedBundleIdentifier = "com.misswell.devsweep"

private enum DevSweepUpdaterError: LocalizedError {
    case invalidArguments
    case parentDidNotExit
    case launchFailed(Int32)
    case launchVerificationFailed

    var errorDescription: String? {
        switch self {
        case .invalidArguments:
            return "更新程序参数无效"
        case .parentDidNotExit:
            return "DevSweep 未能在超时时间内退出"
        case .launchFailed(let status):
            return "启动 DevSweep 失败，open 退出码：\(status)"
        case .launchVerificationFailed:
            return "未找到路径正确的新 DevSweep 进程"
        }
    }
}

private struct UpdaterArguments {
    let parentPID: pid_t
    let sourceApplication: URL
    let destinationApplication: URL
    let stagingDirectory: URL
    let helperDirectory: URL
    let logURL: URL
    let failureMarkerURL: URL

    init() throws {
        let values = CommandLine.arguments
        guard values.count == 8,
              let parentPID = pid_t(values[1]),
              parentPID > 0 else {
            throw DevSweepUpdaterError.invalidArguments
        }

        self.parentPID = parentPID
        sourceApplication = URL(fileURLWithPath: values[2])
        destinationApplication = URL(fileURLWithPath: values[3])
        stagingDirectory = URL(fileURLWithPath: values[4])
        helperDirectory = URL(fileURLWithPath: values[5])
        logURL = URL(fileURLWithPath: values[6])
        failureMarkerURL = URL(fileURLWithPath: values[7])
    }
}

private func appendLog(_ message: String, to url: URL) {
    let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
    try? FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    if !FileManager.default.fileExists(atPath: url.path) {
        try? Data(line.utf8).write(to: url, options: .atomic)
        return
    }
    guard let handle = try? FileHandle(forWritingTo: url) else { return }
    defer { try? handle.close() }
    _ = try? handle.seekToEnd()
    try? handle.write(contentsOf: Data(line.utf8))
}

private func writeFailure(_ error: Error, to url: URL) {
    let message = error.localizedDescription
    try? FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try? Data(message.utf8).write(to: url, options: .atomic)
}

private func waitForParent(_ pid: pid_t) throws {
    for _ in 0..<600 {
        if kill(pid, 0) != 0 { return }
        usleep(100_000)
    }
    throw DevSweepUpdaterError.parentDidNotExit
}

private func normalizedPath(_ url: URL) -> String {
    url.standardizedFileURL.resolvingSymlinksInPath().path
}

private func applications(at url: URL) -> [NSRunningApplication] {
    NSRunningApplication.runningApplications(withBundleIdentifier: expectedBundleIdentifier)
        .filter { application in
            guard let bundleURL = application.bundleURL else { return false }
            return normalizedPath(bundleURL) == normalizedPath(url)
        }
}

private func waitForApplication(at url: URL, excluding pids: Set<pid_t>) throws -> pid_t {
    for _ in 0..<200 {
        if let application = applications(at: url).first(where: {
            !pids.contains($0.processIdentifier) && !$0.isTerminated
        }) {
            return application.processIdentifier
        }
        usleep(100_000)
    }
    throw DevSweepUpdaterError.launchVerificationFailed
}

private func launchAndVerify(_ application: URL) throws -> pid_t {
    let existingPIDs = Set(applications(at: application).map(\.processIdentifier))
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = ["-n", application.path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw DevSweepUpdaterError.launchFailed(process.terminationStatus)
    }
    return try waitForApplication(at: application, excluding: existingPIDs)
}

private func install(_ arguments: UpdaterArguments) throws {
    try waitForParent(arguments.parentPID)

    let fileManager = FileManager.default
    let parent = arguments.destinationApplication.deletingLastPathComponent()
    let token = UUID().uuidString
    let incoming = parent.appendingPathComponent(".DevSweep-update-\(token).app", isDirectory: true)
    let backupName = ".DevSweep-backup-\(token).app"
    let backup = parent.appendingPathComponent(backupName, isDirectory: true)

    do {
        try fileManager.copyItem(at: arguments.sourceApplication, to: incoming)
        _ = try fileManager.replaceItemAt(
            arguments.destinationApplication,
            withItemAt: incoming,
            backupItemName: backupName,
            options: .withoutDeletingBackupItem
        )

        do {
            let pid = try launchAndVerify(arguments.destinationApplication)
            try? fileManager.removeItem(at: backup)
            appendLog(
                "Update installed at \(arguments.destinationApplication.path); verified pid=\(pid), path=\(arguments.destinationApplication.path)",
                to: arguments.logURL
            )
        } catch {
            if fileManager.fileExists(atPath: backup.path) {
                _ = try? fileManager.replaceItemAt(
                    arguments.destinationApplication,
                    withItemAt: backup
                )
            }
            throw error
        }
    } catch {
        try? fileManager.removeItem(at: incoming)
        if !fileManager.fileExists(atPath: arguments.destinationApplication.path),
           fileManager.fileExists(atPath: backup.path) {
            try? fileManager.moveItem(at: backup, to: arguments.destinationApplication)
        }

        appendLog("Update failed: \(error.localizedDescription)", to: arguments.logURL)
        writeFailure(error, to: arguments.failureMarkerURL)

        if fileManager.fileExists(atPath: arguments.destinationApplication.path) {
            if let pid = try? launchAndVerify(arguments.destinationApplication) {
                appendLog(
                    "Rolled back and relaunched old app; verified pid=\(pid), path=\(arguments.destinationApplication.path)",
                    to: arguments.logURL
                )
            } else {
                appendLog("Rollback app could not be verified after update failure", to: arguments.logURL)
            }
        }
        throw error
    }
}

do {
    let arguments = try UpdaterArguments()
    defer {
        try? FileManager.default.removeItem(at: arguments.stagingDirectory)
        try? FileManager.default.removeItem(at: arguments.helperDirectory)
    }
    try install(arguments)
} catch {
    let fallbackLog = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/DevSweep/update.log")
    appendLog("Updater terminated: \(error.localizedDescription)", to: fallbackLog)
    exit(1)
}
