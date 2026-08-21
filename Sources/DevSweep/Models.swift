import Foundation
import SwiftUI

enum CleanupKind: String {
    case trash
    case simulatorDevice
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
