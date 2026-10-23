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

/// 图表与详情共用的搜索条件。
enum DiscoverySearch {
    static func trimmedQuery(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func matches(_ node: DiscoveryNode, query: String) -> Bool {
        node.name.localizedCaseInsensitiveContains(query)
            || node.path.devSweepDisplayPath.localizedCaseInsensitiveContains(query)
    }

    static func filter(_ nodes: [DiscoveryNode], query: String) -> [DiscoveryNode] {
        let trimmed = trimmedQuery(query)
        guard !trimmed.isEmpty else { return nodes }
        return nodes.filter { matches($0, query: trimmed) }
    }
}

/// 当前层按文件类型和目录汇总的占用。目录单独成项，保证图表总量与列表一致。
struct FileTypeSummary: Identifiable, Hashable {
    let category: FileTypeCategory
    let allocatedBytes: Int64
    let logicalBytes: Int64
    let itemCount: Int
    /// 其中测量不完整（下限）的条目数，用于标注该分类的合计是否只是下限。
    let lowerBoundCount: Int

    init(
        category: FileTypeCategory,
        allocatedBytes: Int64,
        logicalBytes: Int64 = 0,
        itemCount: Int,
        lowerBoundCount: Int = 0
    ) {
        self.category = category
        self.allocatedBytes = allocatedBytes
        self.logicalBytes = logicalBytes
        self.itemCount = itemCount
        self.lowerBoundCount = lowerBoundCount
    }

    var id: String { category.rawValue }

    var isLowerBound: Bool { lowerBoundCount > 0 }

    func share(of total: Int64) -> Double {
        total > 0 ? Double(allocatedBytes) / Double(total) : 0
    }

    static func direct(nodes: [DiscoveryNode]) -> [FileTypeSummary] {
        let grouped = Dictionary(grouping: nodes) { node in
            FileTypeCategory.classify(url: node.path, isDirectory: node.isDirectory)
        }
        return grouped.map { category, members in
            FileTypeSummary(
                category: category,
                allocatedBytes: members.reduce(0) { $0 + $1.measurement.allocatedBytes },
                logicalBytes: members.reduce(0) { $0 + ($1.logicalBytes ?? 0) },
                itemCount: members.count,
                lowerBoundCount: members.reduce(0) {
                    $0 + ($1.measurement.state == .complete ? 0 : 1)
                }
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

/// 图表使用的最小数据单元。「其他」分组只保留成员数量和总量：
/// 超大目录不把整尾成员 ID 常驻在内存里，详情按需分页取回。
struct TreemapItem: Identifiable, Hashable {
    let id: String
    let name: String
    let bytes: Int64
    let memberCount: Int
    let isOther: Bool
    /// 图块面积只是已测量下限时为 true（含 `partial` / `timedOut` 测量）。
    let isLowerBound: Bool
    let isDirectory: Bool
    let classification: DiscoveryClassification

    static let otherID = "distribution.other"

    init(
        id: String,
        name: String,
        bytes: Int64,
        memberCount: Int = 1,
        isOther: Bool = false,
        isLowerBound: Bool = false,
        isDirectory: Bool = false,
        classification: DiscoveryClassification = .unknown
    ) {
        self.id = id
        self.name = name
        self.bytes = bytes
        self.memberCount = memberCount
        self.isOther = isOther
        self.isLowerBound = isLowerBound
        self.isDirectory = isDirectory
        self.classification = classification
    }

    init(node: DiscoveryNode) {
        self.init(
            id: node.id,
            name: node.name,
            bytes: node.measurement.allocatedBytes,
            isLowerBound: node.measurement.state != .complete,
            isDirectory: node.isDirectory,
            classification: node.classification
        )
    }

    /// 图块对应的真实路径；`id` 就是标准化后的路径。
    var url: URL { URL(fileURLWithPath: id) }
}

/// 一层目录的分组结果。绘制数量有上限，但总量、成员数和统计状态保持完整。
struct TreemapGrouping: Hashable {
    let items: [TreemapItem]
    /// 测量失败或完全没有测到占用、因此无法绘制的条目数。
    let unmeasuredCount: Int
    /// 测量完整但分配为 0 B 的条目数：不占面积，但不算统计失败。
    let emptyCount: Int
    /// 已绘制但只是占用下限的图块数。
    let lowerBoundCount: Int
    /// 本层全部测量不完整（partial / timedOut / failed）的条目数，包含无法绘制的 0 B 项。
    let incompleteCount: Int
    /// 本层（含搜索筛选后）条目的分配大小合计；含下限项时它本身也是下限。
    let totalBytes: Int64
    let isLowerBound: Bool
    /// 本层没有任何可用测量：总量连下限都无从谈起，不能显示成精确的 0 B。
    let totalIsUnknown: Bool
    /// 已绘制单项图块的 ID，用于判断选中项是否落在「其他」分组里。
    let drawnIDs: Set<String>

    static func grouped(
        nodes: [DiscoveryNode],
        maxVisible: Int = 300
    ) -> TreemapGrouping {
        let limit = max(1, maxVisible)

        // 一趟分类：只对可绘制项建索引并排序，避免整份复制 DiscoveryNode。
        var drawable: [Int] = []
        var emptyCount = 0
        var unmeasuredCount = 0
        var incompleteCount = 0
        var hasCompleteNode = false
        var totalBytes: Int64 = 0
        var lowerBoundNodeCount = 0
        for index in nodes.indices {
            let node = nodes[index]
            let isComplete = node.measurement.state == .complete
            if isComplete {
                hasCompleteNode = true
            } else {
                incompleteCount += 1
            }
            guard node.measurement.allocatedBytes > 0 else {
                if isComplete {
                    emptyCount += 1
                } else {
                    unmeasuredCount += 1
                }
                continue
            }
            if node.measurement.state == .failed {
                unmeasuredCount += 1
                continue
            }
            if !isComplete { lowerBoundNodeCount += 1 }
            totalBytes += node.measurement.allocatedBytes
            drawable.append(index)
        }
        let order = drawable.sorted { lhs, rhs in
            let lhsBytes = nodes[lhs].measurement.allocatedBytes
            let rhsBytes = nodes[rhs].measurement.allocatedBytes
            if lhsBytes != rhsBytes { return lhsBytes > rhsBytes }
            return nodes[lhs].name.localizedStandardCompare(nodes[rhs].name) == .orderedAscending
        }

        func makeResult(items: [TreemapItem]) -> TreemapGrouping {
            TreemapGrouping(
                items: items,
                unmeasuredCount: unmeasuredCount,
                emptyCount: emptyCount,
                lowerBoundCount: items.filter(\.isLowerBound).count,
                incompleteCount: incompleteCount,
                totalBytes: totalBytes,
                isLowerBound: incompleteCount > 0,
                totalIsUnknown: !nodes.isEmpty && !hasCompleteNode && totalBytes == 0,
                drawnIDs: Set(items.filter { !$0.isOther }.map(\.id))
            )
        }

        guard order.count > limit else {
            return makeResult(items: order.map { TreemapItem(node: nodes[$0]) })
        }

        var items = order.prefix(limit - 1).map { TreemapItem(node: nodes[$0]) }
        var tailBytes: Int64 = 0
        var tailMembers = 0
        var tailLowerBound = 0
        for index in order[(limit - 1)...] {
            tailBytes += nodes[index].measurement.allocatedBytes
            tailMembers += 1
            if nodes[index].measurement.state != .complete { tailLowerBound += 1 }
        }
        if tailBytes > 0 {
            items.append(TreemapItem(
                id: TreemapItem.otherID,
                name: "其他 \(tailMembers) 项",
                bytes: tailBytes,
                memberCount: tailMembers,
                isOther: true,
                isLowerBound: tailLowerBound > 0
            ))
        }
        return makeResult(items: items)
    }
}

/// 一层目录的不可变图表快照：分组、查找表和类型统计一起构建，
/// 悬停、选中这类视图状态变化不会触发对整层目录的重新排序。
struct DistributionSnapshot: Hashable {
    let grouping: TreemapGrouping
    let typeSummaries: [FileTypeSummary]
    let nodeLookup: [String: DiscoveryNode]
    let matchedCount: Int
    /// 搜索过滤后的本层条目，详情里的「其他」成员列表直接复用。
    let layerNodes: [DiscoveryNode]

    init(nodes: [DiscoveryNode], query: String) {
        let matched = DiscoverySearch.filter(nodes, query: query)
        self.grouping = TreemapGrouping.grouped(nodes: matched)
        self.typeSummaries = FileTypeSummary.direct(nodes: matched)
        self.matchedCount = matched.count
        self.layerNodes = matched
        var lookup: [String: DiscoveryNode] = [:]
        lookup.reserveCapacity(matched.count)
        for node in matched {
            lookup[node.id, default: node] = node
        }
        self.nodeLookup = lookup
    }

    var items: [TreemapItem] { grouping.items }
    var totalBytes: Int64 { grouping.totalBytes }
    var isEmptyLayer: Bool { grouping.items.isEmpty }

    /// 选中项是否属于「其他」分组：在本层匹配、可绘制，但不在单项图块里。
    func otherContains(nodeID: String?) -> Bool {
        guard let nodeID,
              let node = nodeLookup[nodeID],
              node.measurement.allocatedBytes > 0,
              node.measurement.state != .failed
        else { return false }
        return !grouping.drawnIDs.contains(nodeID)
    }

    func node(for id: String?) -> DiscoveryNode? {
        guard let id else { return nil }
        return nodeLookup[id]
    }
}

/// 「其他」分组的成员按需取回：单趟遍历只保留占用最大的有限几项，
/// 不为超大目录复制整尾成员。
enum DistributionMembers {
    static func top(
        in nodes: [DiscoveryNode],
        excluding drawnIDs: Set<String>,
        query: String,
        limit: Int
    ) -> [DiscoveryNode] {
        guard limit > 0 else { return [] }
        let trimmed = DiscoverySearch.trimmedQuery(query)
        var order: [Int] = []
        order.reserveCapacity(limit)

        for index in nodes.indices {
            let node = nodes[index]
            guard node.measurement.allocatedBytes > 0,
                  node.measurement.state != .failed,
                  !drawnIDs.contains(node.id)
            else { continue }
            if !trimmed.isEmpty, !DiscoverySearch.matches(node, query: trimmed) { continue }

            let position = order.firstIndex { candidate in
                let other = nodes[candidate]
                if other.measurement.allocatedBytes != node.measurement.allocatedBytes {
                    return other.measurement.allocatedBytes < node.measurement.allocatedBytes
                }
                return other.name.localizedStandardCompare(node.name) == .orderedDescending
            } ?? order.count
            order.insert(index, at: position)
            if order.count > limit { order.removeLast() }
        }
        return order.map { nodes[$0] }
    }

    /// 无法统计的条目（测量失败，或超时后连下限都没拿到）单独列出诊断。
    static func unmeasured(
        in nodes: [DiscoveryNode],
        query: String,
        limit: Int
    ) -> [DiscoveryNode] {
        guard limit > 0 else { return [] }
        let trimmed = DiscoverySearch.trimmedQuery(query)
        var result: [DiscoveryNode] = []
        result.reserveCapacity(limit)
        for node in nodes where node.measurement.allocatedBytes == 0 || node.measurement.state == .failed {
            guard node.measurement.state != .complete else { continue }
            if !trimmed.isEmpty, !DiscoverySearch.matches(node, query: trimmed) { continue }
            result.append(node)
            if result.count == limit { break }
        }
        return result
    }
}
