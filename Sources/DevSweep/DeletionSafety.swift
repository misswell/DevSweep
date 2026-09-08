import Foundation

struct FileIdentity: Hashable {
    enum Kind: String, Hashable {
        case regular
        case directory
        case other
    }

    let device: UInt64
    let inode: UInt64
    let kind: Kind

    static func capture(_ url: URL) -> FileIdentity? {
        let fileManager = FileManager.default
        let standardized = url.standardizedFileURL
        guard standardized.isFileURL,
              fileManager.fileExists(atPath: standardized.path),
              let values = try? standardized.resourceValues(forKeys: [.isSymbolicLinkKey]),
              values.isSymbolicLink != true,
              let attributes = try? fileManager.attributesOfItem(atPath: standardized.path)
        else {
            return nil
        }

        let kind: Kind
        switch attributes[.type] as? FileAttributeType {
        case .some(.typeRegular): kind = .regular
        case .some(.typeDirectory): kind = .directory
        default: kind = .other
        }

        let device = (attributes[.systemNumber] as? NSNumber)?.uint64Value ?? 0
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        return FileIdentity(device: device, inode: inode, kind: kind)
    }
}

struct DeletionContext {
    let home: URL
    let whitelistedPaths: [URL]
    let projectRoots: [URL]
    let allowedRoots: [URL]
    let allowedPaths: [URL]
    let protectedPaths: [URL]

    init(
        whitelistedPaths: [URL],
        projectRoots: [URL],
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        allowedRoots: [URL] = [],
        allowedPaths: [URL] = [],
        protectedPaths: [URL]? = nil
    ) {
        self.home = home.standardizedFileURL
        self.whitelistedPaths = PathWhitelist.normalized(whitelistedPaths)
        self.projectRoots = Self.normalized(projectRoots)
        self.allowedRoots = Self.normalized(allowedRoots)
        self.allowedPaths = Self.normalized(allowedPaths)
        self.protectedPaths = PathWhitelist.normalized(
            protectedPaths ?? DeletionValidator.defaultProtectedPaths(home: home)
        )
    }

    private static func normalized(_ paths: [URL]) -> [URL] {
        paths.map(\.standardizedFileURL)
    }
}

enum DeletionValidationError: LocalizedError, Equatable {
    case pathMissing
    case symbolicLink
    case protectedPath
    case whitelisted
    case outsideAllowedScope
    case pathChanged
    case unsupportedTarget

    var errorDescription: String? {
        switch self {
        case .pathMissing:
            return "目标已经不存在"
        case .symbolicLink:
            return "目标或其父路径包含符号链接，已拒绝清理"
        case .protectedPath:
            return "目标是受保护的系统、用户或扫描根目录"
        case .whitelisted:
            return "目标已加入白名单"
        case .outsideAllowedScope:
            return "目标已经超出本次扫描授权范围"
        case .pathChanged:
            return "目标在扫描后发生变化，已拒绝清理"
        case .unsupportedTarget:
            return "目标类型不支持自动清理"
        }
    }
}

struct DeletionValidator {
    private static let fileManager = FileManager.default

    static func defaultProtectedPaths(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [URL] {
        [
            URL(fileURLWithPath: "/"),
            URL(fileURLWithPath: "/System"),
            URL(fileURLWithPath: "/Library"),
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/Users"),
            URL(fileURLWithPath: "/private"),
            URL(fileURLWithPath: "/Volumes"),
            home,
            home.appendingPathComponent("Library"),
            home.appendingPathComponent("Desktop"),
            home.appendingPathComponent("Documents"),
            home.appendingPathComponent("Downloads"),
            home.appendingPathComponent("Pictures"),
            home.appendingPathComponent("Movies"),
            home.appendingPathComponent("Music"),
            home.appendingPathComponent("Public"),
            home.appendingPathComponent(".Trash"),
            home.appendingPathComponent("Library/Caches"),
            home.appendingPathComponent("Library/Developer"),
            home.appendingPathComponent("Library/Logs")
        ]
    }

    static func validate(
        item: CacheItem,
        context: DeletionContext
    ) throws {
        guard item.kind == .trash || item.kind == .toolCommand else {
            throw DeletionValidationError.unsupportedTarget
        }

        let standardized = item.path.standardizedFileURL
        guard standardized.isFileURL,
              fileManager.fileExists(atPath: standardized.path)
        else {
            throw DeletionValidationError.pathMissing
        }

        guard let values = try? standardized.resourceValues(forKeys: [.isSymbolicLinkKey]),
              values.isSymbolicLink != true
        else {
            throw DeletionValidationError.symbolicLink
        }

        let physical = standardized.resolvingSymlinksInPath().standardizedFileURL
        guard physical.path == standardized.path else {
            throw DeletionValidationError.symbolicLink
        }

        let exactProtectedPaths = context.protectedPaths
            + context.projectRoots
            + context.allowedRoots
        guard !containsExact(standardized, in: exactProtectedPaths) else {
            throw DeletionValidationError.protectedPath
        }

        guard !PathWhitelist.contains(standardized, in: context.whitelistedPaths),
              !PathWhitelist.contains(physical, in: context.whitelistedPaths)
        else {
            throw DeletionValidationError.whitelisted
        }

        guard isWithinAuthorizedScope(
            standardized: standardized,
            physical: physical,
            context: context
        ) else {
            throw DeletionValidationError.outsideAllowedScope
        }

        guard let expectedIdentity = item.expectedFileIdentity,
              let currentIdentity = FileIdentity.capture(standardized),
              expectedIdentity == currentIdentity,
              currentIdentity.kind == .regular || currentIdentity.kind == .directory
        else {
            throw DeletionValidationError.pathChanged
        }
    }

    private static func isWithinAuthorizedScope(
        standardized: URL,
        physical: URL,
        context: DeletionContext
    ) -> Bool {
        let roots = (context.projectRoots + context.allowedRoots).filter {
            !containsExact($0, in: context.protectedPaths)
        }
        let isAuthorizedByRoot = roots.contains { root in
            isEqualOrDescendant(standardized, of: root)
                && isEqualOrDescendant(physical, of: root.resolvingSymlinksInPath())
        }
        let isAuthorizedByExactPath = context.allowedPaths.contains { path in
            path.path == standardized.path
        }
        return isAuthorizedByRoot || isAuthorizedByExactPath
    }

    private static func containsExact(_ path: URL, in paths: [URL]) -> Bool {
        paths.contains { $0.standardizedFileURL.path == path.standardizedFileURL.path }
    }

    private static func isEqualOrDescendant(_ path: URL, of root: URL) -> Bool {
        let pathString = path.standardizedFileURL.path
        let rootString = root.standardizedFileURL.path
        return pathString == rootString || pathString.hasPrefix(rootString + "/")
    }
}
