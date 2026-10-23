import Darwin
import Foundation

struct DiscoveryScanProgress: Equatable {
    let phase: String
    let currentPath: String
    let checkedCount: Int
}

struct DiscoveryReport {
    let directory: URL
    let thresholdBytes: Int64
    /// 按列表阈值过滤后的条目。
    let nodes: [DiscoveryNode]
    /// 本层全部可读条目；文件分布图用它保证面积和文件类型总量不被列表阈值截断。
    let allNodes: [DiscoveryNode]
    /// 完整层级快照，多层树图直接使用它，切换图表不会重新扫描文件系统。
    let treeSnapshot: DiscoveryTreeSnapshot
    let checkedCount: Int
    let hiddenCount: Int
    let filteredCount: Int
    let filteredBytes: Int64
    let symlinkCount: Int
    let crossVolumeCount: Int
    let issues: [ScanDiagnostic]
    let wasCancelled: Bool
    /// 达到节点上限：树图与合计都只覆盖已扫描部分，必须按下限展示。
    let limitReached: Bool
    let duration: TimeInterval
    let scannedAt: Date

    var incompleteCount: Int {
        allNodes.filter { !$0.measurement.isComplete }.count
    }

    var issueCount: Int { issues.count }

    /// 扫描时的过滤条件标识，参与图表缓存键，避免阈值变化后误用旧节点。
    var filterSignature: String {
        "\(thresholdBytes)|\(hiddenCount)|\(filteredCount)|\(filteredBytes)"
    }

    var totalAllocatedBytes: Int64 {
        allNodes.reduce(0) { $0 + $1.measurement.allocatedBytes }
    }

    var totalFileTypes: [FileTypeSummary] {
        FileTypeSummary.direct(nodes: allNodes)
    }
}

final class DiscoveryCancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func reset() {
        lock.lock()
        cancelled = false
        lock.unlock()
    }
}

/// 只读的未知占用发现器。扫描由 `DiscoveryTreeScanEngine` 一次遍历完成：
/// 不跟随符号链接、不跨越卷、不删除任何内容。本层列表与多层树图来自同一份快照，
/// 父目录只作为导航节点，不会和子目录一起参与回收空间计算。
enum UnknownStorageScanner {
    static func inventory(roots: [URL]) -> [DiscoveryRoot] {
        var seen = Set<String>()
        return roots.compactMap { root in
            let standardized = root.standardizedFileURL
            guard seen.insert(standardized.path).inserted else { return nil }
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: standardized.path, isDirectory: &isDirectory)
            return DiscoveryRoot(path: standardized, exists: exists, isDirectory: exists && isDirectory.boolValue)
        }
    }

    static func scan(
        directory: URL,
        thresholdBytes: Int64,
        knownCacheLocations: [KnownCacheLocation] = CacheScanner.knownCacheLocations(),
        isCancelled: @escaping () -> Bool = { false },
        progress: @escaping (DiscoveryScanProgress) -> Void = { _ in }
    ) -> DiscoveryReport {
        let directory = directory.standardizedFileURL
        progress(DiscoveryScanProgress(
            phase: "正在遍历目录树",
            currentPath: directory.devSweepDisplayPath,
            checkedCount: 0
        ))

        let snapshot = DiscoveryTreeScanEngine.scan(
            root: directory,
            options: .init(
                isCancelled: isCancelled,
                progress: { update in
                    progress(DiscoveryScanProgress(
                        phase: update.phase,
                        currentPath: update.currentPath,
                        checkedCount: update.checkedCount
                    ))
                }
            )
        )

        return report(
            from: snapshot,
            directory: directory,
            thresholdBytes: thresholdBytes,
            classifier: DiscoveryClassifier(knownCacheLocations: knownCacheLocations)
        )
    }

    /// 从不可变树快照派生本层列表。树图与本层列表共用同一份测量，
    /// 因此同一路径在两处的分类、占用和统计完整性不会分叉。
    static func report(
        from snapshot: DiscoveryTreeSnapshot,
        directory: URL,
        thresholdBytes: Int64,
        classifier: DiscoveryClassifier
    ) -> DiscoveryReport {
        var allNodes: [DiscoveryNode] = []
        var hiddenCount = 0
        allNodes.reserveCapacity(Int(snapshot.records.isEmpty ? 0 : snapshot.records[snapshot.rootIndex].childCount))

        for child in snapshot.children(of: snapshot.rootIndex) {
            let index = Int(child)
            guard let node = snapshot.discoveryNode(at: index, classifier: classifier) else { continue }
            if node.isHidden { hiddenCount += 1 }
            allNodes.append(node)
        }

        allNodes.sort { lhs, rhs in
            if lhs.measurement.allocatedBytes != rhs.measurement.allocatedBytes {
                return lhs.measurement.allocatedBytes > rhs.measurement.allocatedBytes
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }

        var filteredCount = 0
        var filteredBytes: Int64 = 0
        let nodes = allNodes.filter { node in
            if node.measurement.state != .complete
                || thresholdBytes <= 0
                || node.measurement.allocatedBytes >= thresholdBytes {
                return true
            }
            filteredCount += 1
            filteredBytes += node.measurement.allocatedBytes
            return false
        }

        return DiscoveryReport(
            directory: directory,
            thresholdBytes: thresholdBytes,
            nodes: nodes,
            allNodes: allNodes,
            treeSnapshot: snapshot,
            checkedCount: snapshot.checkedCount,
            hiddenCount: hiddenCount,
            filteredCount: filteredCount,
            filteredBytes: filteredBytes,
            symlinkCount: snapshot.symlinkCount,
            crossVolumeCount: snapshot.crossVolumeCount,
            issues: snapshot.issues,
            wasCancelled: snapshot.wasCancelled,
            limitReached: snapshot.limitReached,
            duration: snapshot.duration,
            scannedAt: snapshot.scannedAt
        )
    }
}
