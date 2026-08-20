import AppKit
import Combine
import CryptoKit
import Foundation

enum DevSweepAppIdentity {
    static let name = "DevSweep"
    static let bundleIdentifier = "com.misswell.devsweep"
    static let githubRepository = "misswell/DevSweep"
    static let appBundleName = "DevSweep.app"
    static let executableName = "DevSweep"
    static let updaterExecutableName = "DevSweepUpdater"
    static let developerTeamIdentifier = "U8U443D7ZL"

    static func archiveName(for version: String) -> String {
        "DevSweep-\(version)-macos.zip"
    }

    static func applicationURL(in directory: URL) -> URL {
        directory.appendingPathComponent(appBundleName, isDirectory: true)
    }

    static func updaterURL(in applicationURL: URL) -> URL {
        applicationURL.appendingPathComponent("Contents/MacOS/\(updaterExecutableName)")
    }
}

struct DevSweepVersion: Comparable, Hashable, CustomStringConvertible, Sendable {
    private let components: [Int]

    init?(_ value: String) {
        let normalized = value.hasPrefix("v") ? String(value.dropFirst()) : value
        let pieces = normalized.split(separator: ".", omittingEmptySubsequences: false)
        guard !pieces.isEmpty,
              pieces.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              pieces.compactMap({ Int($0) }).count == pieces.count else {
            return nil
        }
        components = pieces.compactMap { Int($0) }
    }

    var description: String {
        components.map(String.init).joined(separator: ".")
    }

    static func == (lhs: DevSweepVersion, rhs: DevSweepVersion) -> Bool {
        normalized(lhs.components) == normalized(rhs.components)
    }

    static func < (lhs: DevSweepVersion, rhs: DevSweepVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(Self.normalized(components))
    }

    private static func normalized(_ components: [Int]) -> [Int] {
        var result = components
        while result.count > 1 && result.last == 0 {
            result.removeLast()
        }
        return result
    }
}

struct DevSweepRelease: Equatable, Sendable {
    let version: DevSweepVersion
    let releaseNotes: String
    let archiveURL: URL
    let sha256: String

    func isNewer(than currentVersion: String) -> Bool {
        guard let current = DevSweepVersion(currentVersion) else { return false }
        return current < version
    }

    static func decodeGitHubResponse(_ data: Data) throws -> DevSweepRelease {
        let response = try JSONDecoder().decode(GitHubReleaseResponse.self, from: data)
        guard !response.draft,
              !response.prerelease,
              let version = DevSweepVersion(response.tagName) else {
            throw DevSweepUpdateError.invalidRelease
        }

        let expectedName = DevSweepAppIdentity.archiveName(for: version.description)
        guard let asset = response.assets.first(where: { $0.name == expectedName }),
              asset.url.scheme == "https",
              let digest = asset.digest,
              digest.lowercased().hasPrefix("sha256:") else {
            throw DevSweepUpdateError.missingVerifiedArchive
        }

        let sha256 = String(digest.dropFirst("sha256:".count)).lowercased()
        guard sha256.count == 64, sha256.allSatisfy(\.isHexDigit) else {
            throw DevSweepUpdateError.missingVerifiedArchive
        }

        return DevSweepRelease(
            version: version,
            releaseNotes: response.body ?? "",
            archiveURL: asset.url,
            sha256: sha256
        )
    }
}

private struct GitHubReleaseResponse: Decodable {
    struct Asset: Decodable {
        let name: String
        let url: URL
        let digest: String?

        enum CodingKeys: String, CodingKey {
            case name
            case url = "browser_download_url"
            case digest
        }
    }

    let tagName: String
    let body: String?
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case body
        case draft
        case prerelease
        case assets
    }
}

enum DevSweepUpdateError: Error, Equatable, Sendable {
    case invalidRelease
    case missingVerifiedArchive
    case invalidResponse
    case digestMismatch
    case invalidApplication
    case versionMismatch
    case invalidSignature
    case wrongDeveloperTeam
    case gatekeeperRejected
    case installationUnavailable
    case updaterHelperMissing
    case commandFailed(String)
}

struct DevSweepUpdateFailure: Equatable, Sendable {
    let message: String
    let detail: String?

    var displayText: String {
        guard let detail, !detail.isEmpty else { return message }
        return "\(message)：\(detail)"
    }

    init(_ error: Error) {
        guard let error = error as? DevSweepUpdateError else {
            message = "网络请求失败"
            detail = error.localizedDescription
            return
        }

        switch error {
        case .invalidRelease, .missingVerifiedArchive, .invalidResponse:
            message = "GitHub Release 信息或安装包无效"
            detail = nil
        case .digestMismatch:
            message = "下载文件的 SHA-256 校验失败"
            detail = nil
        case .invalidApplication, .versionMismatch, .invalidSignature, .wrongDeveloperTeam, .gatekeeperRejected:
            message = "安装包签名或版本校验失败"
            detail = nil
        case .installationUnavailable:
            message = "当前应用位置不可写"
            detail = "请将 DevSweep 放入可写目录后重试"
        case .updaterHelperMissing:
            message = "当前安装缺少更新组件"
            detail = "请先手动安装包含在线更新功能的新版本"
        case .commandFailed(let command):
            message = "更新命令执行失败"
            detail = command
        }
    }

    init(previousFailure message: String) {
        self.message = "上次更新失败"
        detail = message
    }
}

enum DevSweepUpdateState: Equatable, Sendable {
    case idle
    case checking
    case upToDate
    case available(DevSweepRelease)
    case downloading(DevSweepRelease)
    case installing(DevSweepRelease)
    case failed(DevSweepUpdateFailure)

    var isBusy: Bool {
        switch self {
        case .checking, .downloading, .installing:
            return true
        default:
            return false
        }
    }

    var availableRelease: DevSweepRelease? {
        switch self {
        case .available(let release), .downloading(let release), .installing(let release):
            return release
        default:
            return nil
        }
    }
}

enum DevSweepUpdatePaths {
    static let updateLogURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/DevSweep/update.log")
    static let failureMarkerURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/DevSweep/update-failure.txt")
}

@MainActor
final class DevSweepSoftwareUpdater: ObservableObject {
    static let latestReleaseURL = URL(string: "https://api.github.com/repos/\(DevSweepAppIdentity.githubRepository)/releases/latest")!

    @Published private(set) var state: DevSweepUpdateState = .idle
    let currentVersion: String

    private let session: URLSession
    private let applicationURL: URL
    private let failureMarkerURL: URL

    init(
        currentVersion: String = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.1.0",
        session: URLSession = .shared,
        applicationURL: URL = Bundle.main.bundleURL,
        failureMarkerURL: URL = DevSweepUpdatePaths.failureMarkerURL
    ) {
        self.currentVersion = currentVersion
        self.session = session
        self.applicationURL = applicationURL
        self.failureMarkerURL = failureMarkerURL

        if let previousFailure = Self.consumeFailureMarker(at: failureMarkerURL) {
            state = .failed(DevSweepUpdateFailure(previousFailure: previousFailure))
        }
    }

    func checkForUpdates() async {
        guard !state.isBusy else { return }
        state = .checking
        do {
            let release = try await fetchLatestRelease()
            state = release.isNewer(than: currentVersion) ? .available(release) : .upToDate
        } catch {
            state = .failed(DevSweepUpdateFailure(error))
        }
    }

    func downloadAndInstall() async {
        guard case .available(let release) = state else { return }
        state = .downloading(release)
        do {
            let (downloadURL, response) = try await session.download(from: release.archiveURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw DevSweepUpdateError.invalidResponse
            }

            state = .installing(release)
            let package = try await Task.detached(priority: .userInitiated) {
                try DevSweepUpdatePackageValidator.prepare(downloadURL: downloadURL, release: release)
            }.value
            try launchInstaller(for: package)
            terminateAfterSheetsClose()
        } catch {
            state = .failed(DevSweepUpdateFailure(error))
        }
    }

    private func fetchLatestRelease() async throws -> DevSweepRelease {
        var request = URLRequest(url: Self.latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("DevSweep/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw DevSweepUpdateError.invalidResponse
        }
        return try DevSweepRelease.decodeGitHubResponse(data)
    }

    private func launchInstaller(for package: VerifiedDevSweepUpdatePackage) throws {
        let fileManager = FileManager.default
        let parent = applicationURL.deletingLastPathComponent()
        guard applicationURL.pathExtension == "app",
              Bundle(url: applicationURL)?.bundleIdentifier == DevSweepAppIdentity.bundleIdentifier,
              fileManager.isWritableFile(atPath: parent.path) else {
            throw DevSweepUpdateError.installationUnavailable
        }

        let bundledHelper = DevSweepAppIdentity.updaterURL(in: applicationURL)
        guard fileManager.isExecutableFile(atPath: bundledHelper.path) else {
            throw DevSweepUpdateError.updaterHelperMissing
        }

        let helperDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("DevSweepUpdater-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: helperDirectory, withIntermediateDirectories: true)
        let helperURL = helperDirectory.appendingPathComponent(DevSweepAppIdentity.updaterExecutableName)
        do {
            try fileManager.copyItem(at: bundledHelper, to: helperURL)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helperURL.path)

            let process = Process()
            process.executableURL = helperURL
            process.arguments = [
                String(ProcessInfo.processInfo.processIdentifier),
                package.applicationURL.path,
                applicationURL.path,
                package.workingDirectory.path,
                helperDirectory.path,
                DevSweepUpdatePaths.updateLogURL.path,
                failureMarkerURL.path
            ]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
        } catch {
            try? fileManager.removeItem(at: helperDirectory)
            throw error
        }
    }

    private func terminateAfterSheetsClose() {
        guard NSApp.windows.allSatisfy({ $0.attachedSheet == nil }) else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.terminateAfterSheetsClose()
            }
            return
        }
        NSApp.terminate(nil)
    }

    private static func consumeFailureMarker(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !message.isEmpty else {
            return nil
        }
        try? FileManager.default.removeItem(at: url)
        return message
    }
}

struct VerifiedDevSweepUpdatePackage: Sendable {
    let applicationURL: URL
    let workingDirectory: URL
}

enum DevSweepUpdatePackageValidator {
    static func prepare(downloadURL: URL, release: DevSweepRelease) throws -> VerifiedDevSweepUpdatePackage {
        let digest = try sha256(of: downloadURL)
        guard digest == release.sha256 else {
            throw DevSweepUpdateError.digestMismatch
        }

        let workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevSweepUpdate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)

        do {
            let archiveURL = workingDirectory.appendingPathComponent("update.zip")
            try FileManager.default.copyItem(at: downloadURL, to: archiveURL)
            try run("/usr/bin/ditto", arguments: ["-x", "-k", archiveURL.path, workingDirectory.path])

            let applicationURL = DevSweepAppIdentity.applicationURL(in: workingDirectory)
            guard let bundle = Bundle(url: applicationURL),
                  bundle.bundleIdentifier == DevSweepAppIdentity.bundleIdentifier,
                  let executableName = bundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String,
                  executableName == DevSweepAppIdentity.executableName,
                  FileManager.default.isExecutableFile(
                      atPath: applicationURL.appendingPathComponent("Contents/MacOS/\(executableName)").path
                  ),
                  FileManager.default.isExecutableFile(
                      atPath: DevSweepAppIdentity.updaterURL(in: applicationURL).path
                  ) else {
                throw DevSweepUpdateError.invalidApplication
            }

            let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            guard version.flatMap(DevSweepVersion.init) == release.version else {
                throw DevSweepUpdateError.versionMismatch
            }

            try run("/usr/bin/codesign", arguments: ["--verify", "--deep", "--strict", applicationURL.path])
            let signatureDetails = try run(
                "/usr/bin/codesign",
                arguments: ["--display", "--verbose=4", applicationURL.path]
            )
            guard signatureDetails.contains("TeamIdentifier=\(DevSweepAppIdentity.developerTeamIdentifier)") else {
                throw DevSweepUpdateError.wrongDeveloperTeam
            }

            do {
                try run("/usr/sbin/spctl", arguments: ["--assess", "--type", "execute", applicationURL.path])
            } catch {
                throw DevSweepUpdateError.gatekeeperRejected
            }

            return VerifiedDevSweepUpdatePackage(
                applicationURL: applicationURL,
                workingDirectory: workingDirectory
            )
        } catch {
            try? FileManager.default.removeItem(at: workingDirectory)
            throw error
        }
    }

    static func sha256(of url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    @discardableResult
    private static func run(_ executable: String, arguments: [String]) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            if executable == "/usr/bin/codesign" {
                throw DevSweepUpdateError.invalidSignature
            }
            throw DevSweepUpdateError.commandFailed(output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return output
    }
}
