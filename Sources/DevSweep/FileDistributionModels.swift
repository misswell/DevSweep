import SwiftUI

/// 文件分布图只按扩展名做展示层分类，不把类型当成可删除性的证据。
enum FileTypeCategory: String, CaseIterable, Hashable, Identifiable {
    case image
    case video
    case audio
    case archive
    case source
    case compiled
    case aiModel
    case database
    case package
    case folder
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .image: return "图片"
        case .video: return "视频"
        case .audio: return "音频"
        case .archive: return "压缩包"
        case .source: return "开发源码"
        case .compiled: return "编译产物"
        case .aiModel: return "AI 模型"
        case .database: return "数据库"
        case .package: return "应用包"
        case .folder: return "目录（未展开）"
        case .other: return "其他"
        }
    }

    var color: Color {
        switch self {
        case .image: return .pink
        case .video: return .indigo
        case .audio: return .teal
        case .archive: return .brown
        case .source: return .blue
        case .compiled: return .orange
        case .aiModel: return .purple
        case .database: return .red
        case .package: return .cyan
        case .folder: return .gray
        case .other: return .secondary
        }
    }

    var symbolName: String {
        switch self {
        case .image: return "photo"
        case .video: return "video"
        case .audio: return "waveform"
        case .archive: return "archivebox"
        case .source: return "chevron.left.forwardslash.chevron.right"
        case .compiled: return "gearshape.2"
        case .aiModel: return "brain"
        case .database: return "cylinder"
        case .package: return "shippingbox"
        case .folder: return "folder"
        case .other: return "doc"
        }
    }

    static func classify(url: URL, isDirectory: Bool) -> FileTypeCategory {
        let fileExtension = url.pathExtension.lowercased()
        if isDirectory {
            if Self.packageExtensions.contains(fileExtension) {
                return .package
            }
            if Self.modelFileExtensions.contains(fileExtension) {
                return .aiModel
            }
            return .folder
        }
        if Self.imageExtensions.contains(fileExtension) { return .image }
        if Self.videoExtensions.contains(fileExtension) { return .video }
        if Self.audioExtensions.contains(fileExtension) { return .audio }
        if Self.archiveExtensions.contains(fileExtension) { return .archive }
        if Self.compiledExtensions.contains(fileExtension) { return .compiled }
        if Self.modelFileExtensions.contains(fileExtension) { return .aiModel }
        if Self.databaseExtensions.contains(fileExtension) { return .database }
        if Self.packageExtensions.contains(fileExtension) { return .package }
        if Self.sourceExtensions.contains(fileExtension) { return .source }
        return .other
    }

    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "heif", "webp", "gif", "tiff", "tif", "bmp",
        "icns", "svg", "psd", "raw", "cr2", "nef", "arw", "avif", "exr"
    ]
    private static let videoExtensions: Set<String> = [
        "mp4", "mov", "mkv", "avi", "webm", "m4v", "flv", "wmv", "mpg", "mpeg", "mts", "m2ts"
    ]
    private static let audioExtensions: Set<String> = [
        "mp3", "wav", "flac", "aac", "m4a", "ogg", "opus", "aiff", "alac", "wma", "caf"
    ]
    private static let archiveExtensions: Set<String> = [
        "zip", "7z", "rar", "tar", "gz", "bz2", "xz", "zst", "tgz", "tbz2", "txz",
        "dmg", "iso", "pkg", "xip"
    ]
    private static let compiledExtensions: Set<String> = [
        "o", "obj", "a", "lib", "dylib", "so", "dll", "exe", "rlib", "rmeta",
        "class", "jar", "war", "ear", "pyc", "pyo", "wasm", "bc", "ll", "pdb"
    ]
    private static let modelFileExtensions: Set<String> = [
        "gguf", "safetensors", "onnx", "pt", "pth", "ckpt", "mlmodel", "mlpackage",
        "tflite", "coreml", "ggml"
    ]
    private static let databaseExtensions: Set<String> = [
        "sqlite", "sqlite3", "db", "realm", "mdb", "accdb", "duckdb", "parquet"
    ]
    private static let packageExtensions: Set<String> = [
        "app", "framework", "xcarchive", "bundle", "xpc", "kext", "plugin", "appex"
    ]
    private static let sourceExtensions: Set<String> = [
        "swift", "m", "mm", "h", "hh", "hpp", "c", "cc", "cpp", "cxx", "rs", "go",
        "py", "pyi", "js", "jsx", "mjs", "cjs", "ts", "tsx", "java", "kt", "kts",
        "rb", "php", "cs", "fs", "fsx", "vb", "dart", "sh", "bash", "zsh", "fish",
        "lua", "r", "scala", "clj", "ex", "exs", "erl", "hs", "ml", "pl", "sql",
        "vue", "svelte", "html", "css", "scss", "sass", "less", "json", "yaml",
        "yml", "toml", "ini", "plist", "md", "txt"
    ]
}

/// 当前层按文件类型和目录汇总的占用。目录单独成项，保证图表总量与列表一致。
struct FileTypeSummary: Identifiable, Hashable {
    let category: FileTypeCategory
    let allocatedBytes: Int64
    let logicalBytes: Int64
    let itemCount: Int

    var id: String { category.rawValue }

    func share(of total: Int64) -> Double {
        total > 0 ? Double(allocatedBytes) / Double(total) : 0
    }

    static func direct(nodes: [DiscoveryNode]) -> [FileTypeSummary] {
        let grouped = Dictionary(grouping: nodes) { node in
            FileTypeCategory.classify(url: node.path, isDirectory: node.isDirectory)
        }
        return grouped.map { category, nodes in
            FileTypeSummary(
                category: category,
                allocatedBytes: nodes.reduce(0) { $0 + $1.measurement.allocatedBytes },
                logicalBytes: nodes.reduce(0) { $0 + ($1.logicalBytes ?? 0) },
                itemCount: nodes.count
            )
        }
        .sorted { lhs, rhs in
            if lhs.allocatedBytes != rhs.allocatedBytes {
                return lhs.allocatedBytes > rhs.allocatedBytes
            }
            return lhs.category.rawValue < rhs.category.rawValue
        }
    }
}

/// 由发现页分类推导出的清理候选。只有内置规则或项目生成物规则明确识别时才有值。
/// 它不构成自动清理授权：用户必须显式加入本次清理，执行前仍会重新验证。
struct DiscoveryCleanupCandidate: Hashable {
    let category: String
    let name: String
    let risk: RiskLevel
    let note: String
}

/// 图表使用的最小数据单元；`other` 保留被合并条目的真实总量和成员路径。
struct TreemapItem: Identifiable, Hashable {
    let id: String
    let name: String
    let bytes: Int64
    let memberIDs: [String]
    let isOther: Bool

    static let otherID = "distribution.other"

    static func grouped(
        nodes: [DiscoveryNode],
        maxVisible: Int = 300
    ) -> (items: [TreemapItem], unmeasuredCount: Int) {
        let positive = nodes
            .filter { $0.measurement.allocatedBytes > 0 }
            .sorted { lhs, rhs in
                if lhs.measurement.allocatedBytes != rhs.measurement.allocatedBytes {
                    return lhs.measurement.allocatedBytes > rhs.measurement.allocatedBytes
                }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        let unmeasuredCount = nodes.count - positive.count
        let limit = max(1, maxVisible)
        guard positive.count > limit else {
            return (positive.map { node in
                TreemapItem(
                    id: node.id,
                    name: node.name,
                    bytes: node.measurement.allocatedBytes,
                    memberIDs: [node.id],
                    isOther: false
                )
            }, unmeasuredCount)
        }

        let kept = Array(positive.prefix(limit - 1))
        let groupedNodes = positive.dropFirst(limit - 1)
        var items = kept.map { node in
            TreemapItem(
                id: node.id,
                name: node.name,
                bytes: node.measurement.allocatedBytes,
                memberIDs: [node.id],
                isOther: false
            )
        }
        let groupedBytes = groupedNodes.reduce(Int64(0)) { $0 + $1.measurement.allocatedBytes }
        if groupedBytes > 0 {
            items.append(TreemapItem(
                id: TreemapItem.otherID,
                name: "其他 \(groupedNodes.count) 项",
                bytes: groupedBytes,
                memberIDs: groupedNodes.map(\.id),
                isOther: true
            ))
        }
        return (items, unmeasuredCount)
    }
}
