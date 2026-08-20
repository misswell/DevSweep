import AppKit
import Darwin
import Foundation

private let expectedBundleIdentifier = "com.misswell.devsweep"

private enum DevSweepUpdaterError: LocalizedError {
    case invalidArguments
    case parentDidNotExit
    case launchFailed(Int32)
    case launchVerificationFailed
    case rollbackFailed(String)

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
        case .rollbackFailed(let detail):
            return "更新失败且回滚失败：\(detail)"
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

private func waitForParent(_ pid: pid_t, logURL: URL) throws {
    switch DevSweepParentTermination.ensureExited(pid: pid) {
    case .alreadyExited:
        return
    case .terminatedBySIGTERM:
        appendLog("旧版 DevSweep 未能优雅退出，已发送 SIGTERM", to: logURL)
    case .killedBySIGKILL:
        appendLog("旧版 DevSweep 忽略 SIGTERM，已发送 SIGKILL", to: logURL)
    case .stillRunning:
        throw DevSweepUpdaterError.parentDidNotExit
    }
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

private func restoreBackup(
    _ backup: URL,
    to destination: URL,
    using fileManager: FileManager
) throws {
    guard fileManager.fileExists(atPath: backup.path) else {
        throw DevSweepUpdaterError.rollbackFailed("旧版本备份不存在")
    }

    do {
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: backup)
        } else {
            try fileManager.moveItem(at: backup, to: destination)
        }
    } catch {
        let firstAttempt = error.localizedDescription
        if fileManager.fileExists(atPath: destination.path) {
            try? fileManager.removeItem(at: destination)
        }

        do {
            try fileManager.moveItem(at: backup, to: destination)
        } catch {
            throw DevSweepUpdaterError.rollbackFailed(
                "首次恢复失败：\(firstAttempt)；再次恢复失败：\(error.localizedDescription)"
            )
        }
    }
}

private func install(_ arguments: UpdaterArguments) throws {
    let fileManager = FileManager.default
    let parent = arguments.destinationApplication.deletingLastPathComponent()
    let token = UUID().uuidString
    let incoming = parent.appendingPathComponent(".DevSweep-update-\(token).app", isDirectory: true)
    let backupName = ".DevSweep-backup-\(token).app"
    let backup = parent.appendingPathComponent(backupName, isDirectory: true)
    var needsRollback = false
    var replacementCompleted = false

    do {
        try waitForParent(arguments.parentPID, logURL: arguments.logURL)
        try fileManager.copyItem(at: arguments.sourceApplication, to: incoming)
        _ = try fileManager.replaceItemAt(
            arguments.destinationApplication,
            withItemAt: incoming,
            backupItemName: backupName,
            options: .withoutDeletingBackupItem
        )
        replacementCompleted = true
        needsRollback = true

        do {
            let pid = try launchAndVerify(arguments.destinationApplication)
            needsRollback = false
            try? fileManager.removeItem(at: backup)
            appendLog(
                "Update installed at \(arguments.destinationApplication.path); verified pid=\(pid), path=\(arguments.destinationApplication.path)",
                to: arguments.logURL
            )
        } catch let installError {
            do {
                try restoreBackup(backup, to: arguments.destinationApplication, using: fileManager)
                needsRollback = false
            } catch {
                throw DevSweepUpdaterError.rollbackFailed(
                    "新版本启动失败：\(installError.localizedDescription)；回滚失败：\(error.localizedDescription)"
                )
            }
            throw installError
        }
    } catch {
        try? fileManager.removeItem(at: incoming)

        if needsRollback {
            do {
                try restoreBackup(backup, to: arguments.destinationApplication, using: fileManager)
                needsRollback = false
                appendLog("Rollback restored the previous DevSweep bundle", to: arguments.logURL)
            } catch {
                appendLog("Rollback failed: \(error.localizedDescription)", to: arguments.logURL)
            }
        }

        appendLog("Update failed: \(error.localizedDescription)", to: arguments.logURL)
        writeFailure(error, to: arguments.failureMarkerURL)

        if replacementCompleted && !needsRollback && fileManager.fileExists(atPath: arguments.destinationApplication.path) {
            if let pid = try? launchAndVerify(arguments.destinationApplication) {
                appendLog(
                    "Rolled back and relaunched old app; verified pid=\(pid), path=\(arguments.destinationApplication.path)",
                    to: arguments.logURL
                )
            } else {
                appendLog("Rollback app could not be verified after update failure", to: arguments.logURL)
            }
        } else if needsRollback {
            appendLog(
                "The destination bundle is not known to be the previous version; refusing to relaunch it",
                to: arguments.logURL
            )
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
