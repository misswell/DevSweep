import Foundation

struct YarnClassicCachePackage {
    let name: String
    let version: String
    let classification: DependencyCacheInspector.Classification

    static func read(_ path: URL) -> Self? {
        let modules = path.appendingPathComponent("node_modules")
        guard path.lastPathComponent.hasPrefix("npm-"),
              let roots = try? DependencyCacheInspector.list(path), roots.count == 1,
              roots.first?.lastPathComponent == "node_modules", DependencyFile.isDirectory(modules),
              let top = try? DependencyCacheInspector.list(modules), top.count == 1,
              let first = top.first, DependencyFile.isDirectory(first) else { return nil }
        let scoped = first.lastPathComponent.hasPrefix("@")
        let target: URL
        if scoped {
            guard let contents = try? DependencyCacheInspector.list(first), contents.count == 1,
                  let child = contents.first, DependencyFile.isDirectory(child) else { return nil }
            target = child
        } else {
            target = first
        }

        let name = scoped ? first.lastPathComponent + "/" + target.lastPathComponent : target.lastPathComponent
        guard DependencyManager.yarn.acceptsRule(name),
              let manifest = readObject(target.appendingPathComponent("package.json")),
              manifest["name"] as? String == name,
              let version = manifest["version"] as? String, !version.isEmpty else { return nil }

        let metadata = readObject(target.appendingPathComponent(".yarn-metadata.json"))
        let remote = metadata?["remote"] as? [String: Any]
        let reference = (remote?["resolved"] ?? remote?["reference"]) as? String
        let source = reference.flatMap(URL.init(string:))
        let publicHosts: Set<String> = ["registry.yarnpkg.com", "registry.npmjs.org"]
        if !scoped, remote?["type"] as? String == "tarball",
           source?.scheme == "https", let host = source?.host?.lowercased(), publicHosts.contains(host) {
            return Self(name: name, version: version, classification: (.cleanable, "公开源下载记录", true))
        }
        let host = source?.host?.lowercased()
        let downloaded = remote?["type"] as? String == "tarball" && source?.scheme == "https" && host != nil
        return Self(name: name, version: version,
                    classification: (.review, downloaded ? "下载来源 \(host ?? "")" : "没有可核验的远程下载记录", downloaded))
    }

    private static func readObject(_ url: URL) -> [String: Any]? {
        guard let data = DependencyFile.readSmallFile(url, limit: 1_048_576) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

struct MavenCacheVersion {
    let package: String
    let version: String
    let classification: DependencyCacheInspector.Classification

    static func read(_ path: URL, root: URL, members: [URL]) -> Self? {
        let relative = Array(path.pathComponents.dropFirst(root.pathComponents.count))
        guard relative.count >= 3 else { return nil }
        let version = path.lastPathComponent
        let artifact = relative[relative.count - 2]
        let group = relative.dropLast(2).joined(separator: ".")
        let package = group + ":" + artifact
        guard DependencyManager.maven.acceptsRule(package),
              version.range(of: #"\A[A-Za-z0-9][A-Za-z0-9._+-]*\z"#, options: .regularExpression) != nil
        else { return nil }

        let tracker = members.first { $0.lastPathComponent == "_remote.repositories" }
        let artifactPrefix = artifact + "-" + version
        let snapshotPrefix = version.hasSuffix("-SNAPSHOT") ? String(artifactPrefix.dropLast("SNAPSHOT".count)) : nil
        func isVersionFile(_ name: String) -> Bool {
            name.hasPrefix(artifactPrefix + ".") || name.hasPrefix(artifactPrefix + "-")
                || snapshotPrefix.map { prefix in
                    name.hasPrefix(prefix) && name.dropFirst(prefix.count).range(
                        of: #"\A[0-9]{8}\.[0-9]{6}-[0-9]+[.-]"#, options: .regularExpression
                    ) != nil
                } == true
        }

        guard members.contains(where: { isVersionFile($0.lastPathComponent) }) else { return nil }
        func result(_ status: DependencyCacheStatus, _ reason: String, selectable: Bool = false) -> Self {
            Self(package: package, version: version, classification: (status, reason, selectable))
        }

        if members.contains(where: { $0.lastPathComponent == "maven-metadata-local.xml" }) {
            return result(.protected, "本地安装的制品")
        }
        guard let tracker, let origins = readOrigins(tracker) else {
            return result(.review, "没有可核验的远程下载记录")
        }
        if origins.values.contains(where: { $0.contains("") }) {
            return result(.protected, "本地安装的制品")
        }

        let allowedSuffixes = [".sha1", ".sha256", ".sha512", ".md5", ".lastUpdated"]
        let downloaded = Set(members.map(\.lastPathComponent).filter {
            isVersionFile($0) && origins[$0]?.isEmpty == false
        })
        let remoteIDs = Set(origins.values.flatMap { $0 })
        let metadata = Set(remoteIDs.map { "maven-metadata-" + $0 + ".xml" })
        let permitted = downloaded.union(metadata)
        guard !downloaded.isEmpty, members.allSatisfy({ item in
            guard DependencyFile.isRegular(item) else { return false }
            let file = item.lastPathComponent
            return file == "_remote.repositories" || file == "resolver-status.properties" || permitted.contains(file)
                || allowedSuffixes.contains { suffix in
                    file.hasSuffix(suffix) && permitted.contains(String(file.dropLast(suffix.count)))
                }
        }) else { return result(.review, "版本目录包含无法核验的文件") }

        // Repository IDs can be remapped to mirrors by Maven settings.
        return result(.review, "仓库记录 " + remoteIDs.sorted().joined(separator: ", "), selectable: true)
    }

    private static func readOrigins(_ tracker: URL) -> [String: Set<String>]? {
        guard let data = DependencyFile.readSmallFile(tracker, limit: 1_048_576),
              let text = String(data: data, encoding: .utf8) else { return nil }
        var origins: [String: Set<String>] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let entry = line.trimmingCharacters(in: .whitespaces)
            guard !entry.isEmpty, !entry.hasPrefix("#"), !entry.hasPrefix("!") else { continue }
            let parts = entry.dropLast().split(separator: ">", omittingEmptySubsequences: false)
            guard entry.hasSuffix("="), parts.count == 2,
                  parts[0].range(of: #"\A[A-Za-z0-9_.+-]+\z"#, options: .regularExpression) != nil,
                  parts[1].range(of: #"\A[A-Za-z0-9_.-]*\z"#, options: .regularExpression) != nil else { return nil }
            origins[String(parts[0]), default: []].insert(String(parts[1]))
        }
        return origins
    }
}

enum GitCacheProtection {
    case untracked
    case trackedPaths(Set<String>)
    case unknown

    enum Status { case untracked, tracked, unknown }

    static func read(at root: URL, runner: ProcessRunning = ProcessRunner.shared) -> Self {
        let gitVariables = ProcessInfo.processInfo.environment.keys.filter { $0.hasPrefix("GIT_") }
        let env = URL(fileURLWithPath: "/usr/bin/env")
        let command = gitVariables.sorted().flatMap { ["-u", $0] }
            + ["LC_ALL=C", "GIT_OPTIONAL_LOCKS=0", "/usr/bin/git", "-c", "core.fsmonitor=false", "-C", root.path]
        guard let probe = runner.run(executable: env, arguments: command + ["rev-parse", "--is-inside-work-tree"],
                                     environment: nil, timeout: 5), !probe.timedOut else { return .unknown }
        if probe.status == 128,
           String(data: probe.stderr, encoding: .utf8)?.hasPrefix("fatal: not a git repository") == true {
            return hasGitMarker(atOrAbove: root) ? .unknown : .untracked
        }
        guard probe.status == 0, String(data: probe.stdout, encoding: .utf8) == "true\n",
              let listing = runner.run(executable: env, arguments: command + ["ls-files", "--cached", "-z", "--", "."],
                                       environment: nil, timeout: 5), listing.status == 0, !listing.timedOut,
              let text = String(data: listing.stdout, encoding: .utf8) else { return .unknown }
        var protected = Set<String>()
        for item in text.split(separator: "\0") {
            var path = root.appendingPathComponent(String(item)).standardizedFileURL
            while path.path != root.path && PathWhitelist.contains(path, in: [root]) {
                protected.insert(PathWhitelist.protectionKey(path))
                path.deleteLastPathComponent()
            }
        }
        return .trackedPaths(protected)
    }

    private static func hasGitMarker(atOrAbove root: URL) -> Bool {
        var path = root
        while path.path != "/" {
            if FileManager.default.fileExists(atPath: path.appendingPathComponent(".git").path) { return true }
            path.deleteLastPathComponent()
        }
        return false
    }

    func status(for path: URL) -> Status {
        switch self {
        case .untracked: return .untracked
        case .unknown: return .unknown
        case .trackedPaths(let paths): return paths.contains(PathWhitelist.protectionKey(path)) ? .tracked : .untracked
        }
    }
}
