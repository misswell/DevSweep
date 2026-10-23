import Foundation

/// 层级扫描中的一个文件或目录。节点集中存放在连续数组里，父子关系用索引表示，
/// 不为每个节点保存完整 URL；路径只在展示或操作时按父链还原。
struct DiscoveryTreeRecord {
    let name: String
    let parentIndex: Int32
    var firstChildIndex: Int32 = 0
    var childCount: Int32 = 0
    /// 文件自身分配大小；目录为自身元数据块加全部后代。
    var allocatedBytes: Int64 = 0
    var logicalBytes: Int64 = 0
    /// 子树内的常规文件数；文件自身为 1。
    var fileCount: Int32 = 0
    /// 子树内的目录数，不含自身。
    var directoryCount: Int32 = 0
    /// 子树内无法读取或统计的条目数，用于把父目录标记为下限。
    var skippedCount: Int32 = 0
    let isDirectory: Bool
    let isHidden: Bool
    /// 位于其他卷或挂载点，未进入其内容。
    let isCrossVolume: Bool
    /// 硬链接或共享块已被同一扫描中的其他文件计入，此节点自身不再重复累计。
    let isSharedAllocationDeduplicated: Bool
    let modifiedAt: Date?

    var isIncomplete: Bool { skippedCount > 0 }
}

/// 一次扫描的不可变快照。扫描线程构建完成后不再修改，UI 只读。
struct DiscoveryTreeSnapshot {
    let rootIndex: Int
    let records: [DiscoveryTreeRecord]
    /// 按父节点连续存放的子节点索引。
    let childIndices: [Int32]
    let rootURL: URL
    let scannedAt: Date
    let duration: TimeInterval
    let wasCancelled: Bool
    let limitReached: Bool
    let checkedCount: Int
    let symlinkCount: Int
    let crossVolumeCount: Int
    let unreadableCount: Int
    let sharedDeduplicatedCount: Int
    let issues: [ScanDiagnostic]

    /// 快照标识，用作布局缓存键的一部分。
    var version: String {
        "\(rootURL.path)|\(scannedAt.timeIntervalSince1970)|\(records.count)|\(limitReached)"
    }

    var isEmpty: Bool { records.isEmpty }

    func record(at index: Int) -> DiscoveryTreeRecord? {
        guard records.indices.contains(index) else { return nil }
        return records[index]
    }

    func children(of index: Int) -> ArraySlice<Int32> {
        guard records.indices.contains(index) else { return [][...] }
        let record = records[index]
        guard record.childCount > 0 else { return [][...] }
        let start = Int(record.firstChildIndex)
        let end = start + Int(record.childCount)
        guard start >= 0, end <= childIndices.count else { return [][...] }
        return childIndices[start..<end]
    }

    func path(of index: Int) -> String {
        guard records.indices.contains(index) else { return rootURL.path }
        var components: [String] = []
        var cursor = index
        var guardCount = 0
        while cursor != rootIndex, records.indices.contains(cursor), guardCount < records.count {
            components.append(records[cursor].name)
            let parent = Int(records[cursor].parentIndex)
            if parent < 0 || parent == cursor { break }
            cursor = parent
            guardCount += 1
        }
        guard !components.isEmpty else { return rootURL.path }
        return rootURL.path + "/" + components.reversed().joined(separator: "/")
    }

    func url(of index: Int) -> URL {
        URL(fileURLWithPath: path(of: index))
    }

    /// 从根按名称逐段查找，不为全部节点常驻一份路径字典。
    func index(ofPath path: String) -> Int? {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        let rootPath = rootURL.standardizedFileURL.path
        if standardized == rootPath { return rootIndex }
        guard standardized.hasPrefix(rootPath + "/") else { return nil }
        let components = standardized.dropFirst(rootPath.count + 1).split(separator: "/")
        var cursor = rootIndex
        for component in components {
            let name = String(component)
            var found: Int?
            for child in children(of: cursor) where records[Int(child)].name == name {
                found = Int(child)
                break
            }
            guard let next = found else { return nil }
            cursor = next
        }
        return cursor
    }

    /// 节点到根的距离，根为 0。
    func depth(of index: Int) -> Int {
        var depth = 0
        var cursor = index
        while cursor != rootIndex, records.indices.contains(cursor) {
            let parent = Int(records[cursor].parentIndex)
            if parent < 0 || parent == cursor { break }
            cursor = parent
            depth += 1
            if depth > 4_096 { break }
        }
        return depth
    }

    func measurement(at index: Int) -> StorageMeasurement {
        guard let record = record(at: index) else {
            return StorageMeasurement(allocatedBytes: 0, state: .failed, failureReason: "节点不存在")
        }
        if record.skippedCount > 0 {
            return StorageMeasurement(
                allocatedBytes: record.allocatedBytes,
                state: .partial,
                skippedCount: Int(record.skippedCount),
                failureReason: "子树中有 \(record.skippedCount) 个条目无法读取，实际占用可能更大"
            )
        }
        if record.isCrossVolume {
            return StorageMeasurement(
                allocatedBytes: record.allocatedBytes,
                state: .partial,
                skippedCount: 1,
                failureReason: "位于其他卷或挂载点，未进入其内容"
            )
        }
        return StorageMeasurement(allocatedBytes: record.allocatedBytes)
    }

    func discoveryNode(at index: Int, classifier: DiscoveryClassifier) -> DiscoveryNode? {
        guard let record = record(at: index) else { return nil }
        let url = url(of: index)
        let classified = classifier.classify(url: url, isDirectory: record.isDirectory)
        return DiscoveryNode(
            path: url,
            name: record.name,
            measurement: measurement(at: index),
            classification: classified.classification,
            confidence: classified.confidence,
            evidence: classified.evidence,
            isDirectory: record.isDirectory,
            isHidden: record.isHidden,
            modifiedAt: record.modifiedAt,
            logicalBytes: record.isDirectory ? nil : record.logicalBytes,
            cleanupCandidate: classified.cleanupCandidate
        )
    }
}
