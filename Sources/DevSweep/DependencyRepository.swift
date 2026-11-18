import Foundation

enum DependencyManager: String, Codable, CaseIterable, Identifiable {
    case yarn
    case maven

    var id: Self { self }
    var title: String { self == .yarn ? "Yarn" : "Maven" }
    var ruleExample: String {
        self == .yarn ? "@company 或 @company/package" : "com.company 或 com.company:artifact"
    }

    func acceptsRule(_ value: String) -> Bool {
        switch self {
        case .yarn:
            return value.range(of: #"\A(?:@[a-zA-Z0-9][a-zA-Z0-9._-]*(?:/[a-zA-Z0-9][a-zA-Z0-9._-]*)?|[a-zA-Z0-9][a-zA-Z0-9._-]*)\z"#,
                               options: .regularExpression) != nil
        case .maven:
            return value.range(of: #"\A[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)*(?::[A-Za-z0-9_-][A-Za-z0-9_.-]*)?\z"#,
                               options: .regularExpression) != nil
        }
    }
}

struct DependencyProtectionRule: Hashable, Identifiable {
    let manager: DependencyManager
    let value: String

    init?(manager: DependencyManager, value: String) {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard manager.acceptsRule(value) else { return nil }
        self.manager = manager
        self.value = value
    }

    var id: String { manager.rawValue + ":" + value }

    static func forPackages(_ packages: Set<String>, manager: DependencyManager) -> Set<Self> {
        Set(packages.compactMap { Self(manager: manager, value: $0) })
    }

    static func load(_ entries: [Any]) -> [Self] {
        let rules = entries.compactMap { value -> Self? in
            guard let entry = value as? [String: String],
                  let key = entry["manager"], let manager = DependencyManager(rawValue: key),
                  let value = entry["value"] else { return nil }
            return Self(manager: manager, value: value)
        }
        return Set(rules).sorted { $0.id < $1.id }
    }
}

struct DependencyProtectionIndex {
    private let manager: DependencyManager
    private let values: Set<String>

    init(manager: DependencyManager, rules: [DependencyProtectionRule]) {
        self.manager = manager
        values = Set(rules.lazy.filter { $0.manager == manager }.map(\.value))
    }

    func contains(_ package: String) -> Bool {
        if values.contains(package) { return true }
        guard !values.isEmpty else { return false }
        switch manager {
        case .yarn:
            guard package.hasPrefix("@"), let slash = package.firstIndex(of: "/") else { return false }
            return values.contains(String(package[..<slash]))
        case .maven:
            guard let colon = package.firstIndex(of: ":") else { return false }
            var group = package[..<colon]
            while true {
                if values.contains(String(group)) { return true }
                guard let dot = group.lastIndex(of: ".") else { return false }
                group = group[..<dot]
            }
        }
    }
}

struct DependencyRepository: Hashable, Identifiable {
    let manager: DependencyManager
    let root: URL

    init(manager: DependencyManager, root: URL) {
        self.manager = manager
        self.root = root.standardizedFileURL
    }

    var id: String { root.path }
    var name: String { manager == .yarn ? "Yarn 缓存" : "Maven 本地仓库" }
    var category: String { manager == .yarn ? "包管理器" : "JVM" }

    static func projectYarn(at path: URL) -> Self? {
        guard path.lastPathComponent.lowercased() == "cache",
              path.deletingLastPathComponent().lastPathComponent.lowercased() == ".yarn" else { return nil }
        return Self(manager: .yarn, root: path)
    }

    static func configured(home: URL, environment: [String: String]) -> [Self] {
        let yarnPaths = ["Library/Caches/Yarn", ".cache/yarn", ".yarn/cache", ".yarn/berry/cache"]
        var repositories = yarnPaths.map { Self(manager: .yarn, root: home.appendingPathComponent($0)) }
        let mavenHome = configuredPath(environment["MAVEN_USER_HOME"], home: home)
        repositories.append(Self(manager: .maven, root: home.appendingPathComponent(".m2/repository")))
        if let mavenHome {
            repositories.append(Self(manager: .maven, root: mavenHome.appendingPathComponent("repository")))
        }
        let settings = Set([mavenHome, home.appendingPathComponent(".m2")].compactMap { $0 })
        for folder in settings {
            if let path = MavenLocalRepositorySetting.read(from: folder.appendingPathComponent("settings.xml"), home: home) {
                repositories.append(Self(manager: .maven, root: path))
            }
        }
        if let path = configuredPath(environment["YARN_CACHE_FOLDER"], home: home) {
            repositories.append(Self(manager: .yarn, root: path))
        }
        if let path = configuredPath(environment["YARN_GLOBAL_FOLDER"], home: home) {
            repositories.append(Self(manager: .yarn, root: path.appendingPathComponent("cache")))
        }
        var seen = Set<String>()
        return repositories.filter { repository in
            let path = repository.root
            return path.path != "/" && path.path != home.standardizedFileURL.path && seen.insert(repository.id).inserted
        }
    }

    static func configuredPath(_ value: String?, home: URL) -> URL? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        let expanded = value.replacingOccurrences(of: "${user.home}", with: home.path)
        guard !expanded.contains("${") else { return nil }
        if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded).standardizedFileURL }
        if expanded.hasPrefix("~/") { return home.appendingPathComponent(String(expanded.dropFirst(2))).standardizedFileURL }
        return home.appendingPathComponent(expanded).standardizedFileURL
    }

    static func coversProjectYarn(_ path: URL) -> Bool {
        let components = path.standardizedFileURL.pathComponents.map { $0.lowercased() }
        return zip(components, components.dropFirst()).contains { $0.0 == ".yarn" && $0.1 == "cache" }
    }

    static func conflicts(with path: URL, repositories: [Self], permitting permitted: Self? = nil) -> Bool {
        if permitted == nil {
            if coversProjectYarn(path) { return true }
            let cache = path.lastPathComponent.lowercased() == ".yarn"
                ? path.appendingPathComponent("cache")
                : path.appendingPathComponent(".yarn/cache")
            if FileManager.default.fileExists(atPath: cache.path) { return true }
        }
        return repositories.contains { repository in
            guard repository != permitted else { return false }
            let root = repository.root
            let physical = root.resolvingSymlinksInPath().standardizedFileURL
            return [root, physical].contains { location in
                PathWhitelist.overlaps(path, protectedPaths: [location])
                    && (FileManager.default.fileExists(atPath: location.path)
                        || PathWhitelist.contains(path, in: [location]))
            }
        }
    }
}

private final class MavenLocalRepositorySetting: NSObject, XMLParserDelegate {
    private var elements: [String] = []
    private var value = ""

    static func read(from url: URL, home: URL) -> URL? {
        guard let data = DependencyFile.readSmallFile(url, limit: 1_048_576) else { return nil }
        let delegate = MavenLocalRepositorySetting()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else { return nil }
        return DependencyRepository.configuredPath(delegate.value, home: home)
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName: String?, attributes attributeDict: [String: String]) {
        elements.append(elementName)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if elements == ["settings", "localRepository"] { value += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName: String?) {
        elements.removeLast()
    }
}

enum DependencyFile {
    static func hasUnredirectedPath(_ url: URL) -> Bool {
        let standardized = url.standardizedFileURL
        return standardized.resolvingSymlinksInPath().standardizedFileURL.path == standardized.path
    }

    static func readSmallFile(_ url: URL, limit: Int) -> Data? {
        guard isRegular(url), let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: limit + 1), data.count <= limit else { return nil }
        return data
    }

    static func isRegular(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
        return values.isRegularFile == true && values.isSymbolicLink == false
    }

    static func isDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
        return values.isDirectory == true && values.isSymbolicLink == false
    }
}
