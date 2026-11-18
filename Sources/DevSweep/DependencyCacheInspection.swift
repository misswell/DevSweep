import Foundation

enum DependencyCacheStatus: String, CaseIterable, Identifiable {
    case cleanable = "可清理"
    case protected = "已保护"
    case review = "待确认"

    var id: Self { self }
}

struct DependencyCacheEntry: Identifiable, Equatable {
    let path: URL
    let package: String?
    let version: String?
    let stamp: DependencyFileStamp?
    let size: Int64
    let status: DependencyCacheStatus
    let reason: String
    let canManuallySelect: Bool

    var id: String { path.path }
    var name: String { package ?? path.lastPathComponent }

    func status(protection: DependencyProtectionIndex, paths: [URL]) -> DependencyCacheStatus {
        if package.map(protection.contains) == true
            || (!paths.isEmpty && PathWhitelist.overlaps(path, protectedPaths: paths)) {
            return .protected
        }
        return status
    }

    func permitsCleanup(status: DependencyCacheStatus, includeReview: Bool) -> Bool {
        status == .cleanable || (status == .review && includeReview && canManuallySelect)
    }

    func permitsSelection(status: DependencyCacheStatus) -> Bool {
        status != .protected && (package != nil || permitsCleanup(status: status, includeReview: true))
    }

    func protectionRule(manager: DependencyManager) -> DependencyProtectionRule? {
        package.flatMap { DependencyProtectionRule(manager: manager, value: $0) }
    }
}

struct DependencyFileStamp: Equatable {
    let identity: FileIdentity
    let modified: Date
    let bytes: Int

    init?(_ path: URL) {
        let fresh = URL(fileURLWithPath: path.path)
        guard let identity = FileIdentity.capture(fresh),
              let values = try? fresh.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
              let modified = values.contentModificationDate else { return nil }
        self.identity = identity
        self.modified = modified
        self.bytes = values.fileSize ?? 0
    }
}

struct DependencyCachePreview {
    let repository: DependencyRepository
    let rootIdentity: FileIdentity
    let entries: [DependencyCacheEntry]
}

enum DependencyCacheError: LocalizedError {
    case unavailable
    case changed
    case active
    case protected

    var errorDescription: String? {
        switch self {
        case .unavailable: return "无法读取缓存目录，或目录包含符号链接"
        case .changed: return "缓存自预览后发生变化，请刷新后再清理"
        case .active: return "检测到包管理器正在使用缓存，或无法确认进程状态"
        case .protected: return "此项已受保护，或无法安全清理"
        }
    }
}

enum DependencyCacheInspector {
    static let fileManager = FileManager.default
    static let listingKeys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
                                                .fileAllocatedSizeKey, .totalFileAllocatedSizeKey, .fileSizeKey]

    static func preview(_ repository: DependencyRepository) throws -> DependencyCachePreview {
        let root = repository.root
        guard DependencyFile.hasUnredirectedPath(root),
              let identity = FileIdentity.capture(root), identity.kind == .directory else {
            throw DependencyCacheError.unavailable
        }
        let children = try list(root)
        let git = GitCacheProtection.read(at: root)
        var entries: [DependencyCacheEntry] = []
        switch repository.manager {
        case .yarn:
            for child in children {
                try Task.checkCancellation()
                if DependencyFile.isDirectory(child),
                   child.lastPathComponent.range(of: #"\Av[1-9][0-9]*\z"#, options: .regularExpression) != nil {
                    for version in try list(child) {
                        try Task.checkCancellation()
                        entries.append(inspect(version, repository: repository, git: git, measure: true))
                    }
                } else {
                    entries.append(inspect(child, repository: repository, git: git, measure: true))
                }
            }
        case .maven:
            try collectMaven(children, depth: 0, repository: repository, git: git, entries: &entries)
        }
        return DependencyCachePreview(repository: repository, rootIdentity: identity, entries: entries.sorted {
            if $0.size == $1.size { return $0.id < $1.id }
            return $0.size > $1.size
        })
    }

    private static func collectMaven(_ children: [URL], depth: Int, repository: DependencyRepository,
                                     git: GitCacheProtection, entries: inout [DependencyCacheEntry]) throws {
        for child in children {
            try Task.checkCancellation()
            // Resolver split repositories require a layout-specific implementation.
            if depth >= 32 || (depth == 0 && ["installed", "cached"].contains(child.lastPathComponent)) {
                entries.append(unknown(child, reason: "未识别的 Maven 仓库布局", measure: false))
                continue
            }
            guard DependencyFile.isDirectory(child) else {
                if depth <= 1 {
                    entries.append(unknown(child, reason: "仓库文件", measure: true))
                }
                continue
            }
            guard let members = try? list(child) else {
                entries.append(unknown(child, reason: "无法读取目录", measure: false))
                continue
            }
            if let version = MavenCacheVersion.read(child, root: repository.root, members: members) {
                entries.append(makeEntry(child, package: version.package, version: version.version,
                                         classification: version.classification, git: git, measure: true,
                                         size: members.reduce(0) { $0 + allocatedSize($1) }))
            } else {
                try collectMaven(members, depth: depth + 1, repository: repository, git: git, entries: &entries)
            }
        }
    }

    static func inspect(_ path: URL, repository: DependencyRepository, git: GitCacheProtection,
                        measure: Bool) -> DependencyCacheEntry {
        guard DependencyFile.hasUnredirectedPath(path) else {
            return unknown(path, reason: "符号链接", measure: false)
        }
        switch repository.manager {
        case .yarn:
            if DependencyFile.isRegular(path), path.pathExtension == "zip",
               let package = YarnCacheArchive.package(at: path) {
                return makeEntry(path, package: package.name, version: package.version,
                                 classification: (.review, "归档未记录下载来源", true), git: git, measure: measure)
            }
            if DependencyFile.isDirectory(path), let classic = YarnClassicCachePackage.read(path) {
                return makeEntry(path, package: classic.name, version: classic.version,
                                 classification: classic.classification, git: git, measure: measure)
            }
        case .maven:
            if let members = try? list(path),
               let version = MavenCacheVersion.read(path, root: repository.root, members: members) {
                return makeEntry(path, package: version.package, version: version.version,
                                 classification: version.classification, git: git, measure: measure)
            }
        }
        return unknown(path, reason: "未识别的缓存条目", measure: measure)
    }

    private static func makeEntry(_ path: URL, package: String, version: String, classification: Classification,
                                  git: GitCacheProtection, measure: Bool, size: Int64? = nil) -> DependencyCacheEntry {
        let stamp = DependencyFileStamp(path)
        let outcome: Classification
        switch (git.status(for: path), stamp) {
        case (.tracked, _): outcome = (.protected, "Git 跟踪", false)
        case (.unknown, _): outcome = (.review, "无法确认 Git 跟踪状态", false)
        case (_, nil): outcome = (.review, "无法读取文件身份", false)
        default: outcome = classification
        }
        return DependencyCacheEntry(path: path, package: package, version: version, stamp: stamp,
                                    size: measure ? size ?? measuredSize(path) : 0, status: outcome.0,
                                    reason: outcome.1, canManuallySelect: outcome.2)
    }

    private static func unknown(_ path: URL, reason: String, measure: Bool) -> DependencyCacheEntry {
        DependencyCacheEntry(path: path, package: nil, version: nil, stamp: nil,
                             size: measure ? allocatedSize(path) : 0,
                             status: .review, reason: reason, canManuallySelect: false)
    }

    static func list(_ path: URL) throws -> [URL] {
        try fileManager.contentsOfDirectory(at: path, includingPropertiesForKeys: listingKeys)
            .map(\.standardizedFileURL)
    }

    private static func measuredSize(_ path: URL) -> Int64 {
        if DependencyFile.isDirectory(path) {
            return StorageMeasurementService.measureByEnumeration(path).allocatedBytes
        }
        return allocatedSize(path)
    }

    private static func allocatedSize(_ path: URL) -> Int64 {
        guard DependencyFile.isRegular(path), let values = try? path.resourceValues(forKeys: Set(listingKeys))
        else { return 0 }
        return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0)
    }

    typealias Classification = (DependencyCacheStatus, String, Bool)
}
