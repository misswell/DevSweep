import Foundation
import SwiftUI

enum CleanupKind: String {
    case trash
    case simulatorDevice
    case dockerPrune
}

enum DockerCleanupTarget: String, CaseIterable, Equatable, Sendable {
    case images
    case containers
    case volumes
    case buildCache

    init?(dockerType: String) {
        switch dockerType {
        case "Images": self = .images
        case "Containers": self = .containers
        case "Local Volumes": self = .volumes
        case "Build Cache": self = .buildCache
        default: return nil
        }
    }

    var dockerType: String {
        switch self {
        case .images: return "Images"
        case .containers: return "Containers"
        case .volumes: return "Local Volumes"
        case .buildCache: return "Build Cache"
        }
    }

    var displayName: String {
        switch self {
        case .images: return "未使用镜像"
        case .containers: return "已停止容器"
        case .volumes: return "未使用卷"
        case .buildCache: return "Build Cache"
        }
    }

    var arguments: [String] {
        switch self {
        case .images: return ["image", "prune", "--all", "--force"]
        case .containers: return ["container", "prune", "--force"]
        case .volumes: return ["volume", "prune", "--all", "--force"]
        case .buildCache: return ["builder", "prune", "--all", "--force"]
        }
    }

    var note: String {
        switch self {
        case .images:
            return "通过 Docker 官方 CLI 删除未被容器使用的镜像；镜像需要时可重新拉取，不能从废纸篓恢复"
        case .containers:
            return "通过 Docker 官方 CLI 删除已停止容器及其可写层；不能从废纸篓恢复"
        case .volumes:
            return "未使用卷可能包含持久化开发数据；仅在确认内容后执行，不能从废纸篓恢复"
        case .buildCache:
            return "通过 Docker 官方 CLI 删除构建缓存；下次构建会重新执行，不能从废纸篓恢复"
        }
    }
}

enum DockerReclaimableSize {
    static func bytes(from value: String) -> Int64? {
        let sizeText = value.split(separator: "(", maxSplits: 1, omittingEmptySubsequences: true).first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !sizeText.isEmpty else { return nil }

        let numberEnd = sizeText.firstIndex { character in
            !character.isNumber && character != "." && character != ","
        } ?? sizeText.endIndex
        let numberText = String(sizeText[..<numberEnd]).replacingOccurrences(of: ",", with: "")
        guard let number = Double(numberText) else { return nil }

        let unit = String(sizeText[numberEnd...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let multiplier: Double
        switch unit {
        case "b": multiplier = 1
        case "kb": multiplier = 1_000
        case "mb": multiplier = 1_000_000
        case "gb": multiplier = 1_000_000_000
        case "tb": multiplier = 1_000_000_000_000
        case "kib": multiplier = 1_024
        case "mib": multiplier = 1_048_576
        case "gib": multiplier = 1_073_741_824
        case "tib": multiplier = 1_099_511_627_776
        default: return nil
        }
        guard number >= 0,
              number <= Double(Int64.max) / multiplier else { return nil }
        return Int64(number * multiplier)
    }
}

enum RiskLevel: String, CaseIterable {
    case safe
    case review
    case manual

    var title: String {
        switch self {
        case .safe: return "可直接清理"
        case .review: return "建议确认"
        case .manual: return "手动处理"
        }
    }

    var color: Color {
        switch self {
        case .safe: return .green
        case .review: return .orange
        case .manual: return .red
        }
    }
}

struct CacheItem: Identifiable, Hashable {
    let id: UUID
    let category: String
    let name: String
    let path: URL
    let size: Int64
    let details: String
    let risk: RiskLevel
    let kind: CleanupKind
    let identifier: String?
    let note: String
    var isSelected: Bool

    init(
        category: String,
        name: String,
        path: URL,
        size: Int64,
        details: String = "",
        risk: RiskLevel = .safe,
        kind: CleanupKind = .trash,
        identifier: String? = nil,
        note: String = "",
        isSelected: Bool? = nil
    ) {
        self.id = UUID()
        self.category = category
        self.name = name
        self.path = path
        self.size = size
        self.details = details
        self.risk = risk
        self.kind = kind
        self.identifier = identifier
        self.note = note
        self.isSelected = isSelected ?? (risk == .safe && kind == .trash)
    }
}

struct CleanupSelection {
    static func selectedItems(from items: [CacheItem], visibleItems: [CacheItem]) -> [CacheItem] {
        let visibleIDs = Set(visibleItems.map(\.id))
        return items.filter { visibleIDs.contains($0.id) && $0.isSelected && $0.risk != .manual }
    }

    static func remainingItems(from items: [CacheItem], removing removedItems: [CacheItem]) -> [CacheItem] {
        let removedIDs = Set(removedItems.map(\.id))
        return items.filter { !removedIDs.contains($0.id) }
    }
}

struct PathWhitelist {
    static func normalized(_ paths: [URL]) -> [URL] {
        let candidates = paths
            .map(\.standardizedFileURL)
            .sorted { $0.path.count < $1.path.count }

        var result: [URL] = []
        for candidate in candidates {
            let candidatePath = candidate.path
            guard !result.contains(where: { parent in
                let parentPath = parent.path
                return candidatePath == parentPath || candidatePath.hasPrefix(parentPath + "/")
            }) else { continue }
            result.append(candidate)
        }
        return result
    }

    static func contains(_ path: URL, in paths: [URL]) -> Bool {
        let candidatePath = path.standardizedFileURL.path
        return paths.contains { allowedPath in
            let allowed = allowedPath.standardizedFileURL.path
            return candidatePath == allowed || candidatePath.hasPrefix(allowed + "/")
        }
    }
}

struct CleanupReport {
    let removed: [CacheItem]
    let failures: [(CacheItem, String)]
}

enum ScanIssueKind: String, Hashable {
    case inaccessible
    case unavailable
    case skipped

    var title: String {
        switch self {
        case .inaccessible: return "无法读取"
        case .unavailable: return "工具不可用"
        case .skipped: return "已跳过"
        }
    }
}

struct ScanDiagnostic: Identifiable, Hashable {
    let id = UUID()
    let path: URL
    let reason: String
    let kind: ScanIssueKind
}

struct ScanProgress {
    let phase: String
    let currentPath: String
    let checkedPaths: Int
    let matchedPaths: Int
    let skippedPaths: Int
    let permissionFailures: Int

    init(
        phase: String = "准备扫描",
        currentPath: String = "",
        checkedPaths: Int = 0,
        matchedPaths: Int = 0,
        skippedPaths: Int = 0,
        permissionFailures: Int = 0
    ) {
        self.phase = phase
        self.currentPath = currentPath
        self.checkedPaths = checkedPaths
        self.matchedPaths = matchedPaths
        self.skippedPaths = skippedPaths
        self.permissionFailures = permissionFailures
    }
}

struct ScanReport {
    let scannedRoots: [URL]
    let items: [CacheItem]
    let checkedPaths: Int
    let matchedPaths: Int
    let skippedPaths: Int
    let permissionFailures: Int
    let diagnostics: [ScanDiagnostic]
    let duration: TimeInterval
}

extension Int64 {
    var devSweepFileSize: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}

extension URL {
    var devSweepDisplayPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}
