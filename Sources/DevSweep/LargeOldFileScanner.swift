import Foundation

/// 「大文件 / 旧文件」候选项。
///
/// 与缓存规则不同，这些文件不属于任何已知缓存：它们只是占地方、又很久没动过。
/// 因此只做**只读发现 + 用户逐项确认**，永不默认勾选，也不参与定时清理。
/// 参考 PureMac 的「大文件与旧文件」：阈值可配，且「大」与「旧」是两个独立条件。
struct LargeOldFileCandidate: Equatable, Hashable, Sendable {
    let path: URL
    let sizeBytes: Int64
    let modifiedAt: Date
}

struct LargeOldFileScanReport: Equatable, Sendable {
    let candidates: [LargeOldFileCandidate]
    let scannedFileCount: Int
    let skippedUnreadableCount: Int
    let truncatedByLimit: Bool
}

struct LargeOldFileCriteria: Equatable, Sendable {
    /// 文件大小下限。小于它的一律不看。
    var minimumBytes: Int64
    /// 修改时间早于「现在 - 天数」才算「旧」。`nil` 表示不按年龄过滤。
    var olderThanDays: Int?
    /// 最多返回多少个候选项（按大小降序），避免把几万个小文件都列出来。
    var limit: Int
    /// 扫描根目录。
    var roots: [URL]

    init(
        minimumBytes: Int64 = 100 * 1024 * 1024,
        olderThanDays: Int? = nil,
        limit: Int = 200,
        roots: [URL]
    ) {
        self.minimumBytes = minimumBytes
        self.olderThanDays = olderThanDays
        self.limit = limit
        self.roots = roots
    }
}

/// 只读枚举「大 / 旧」文件。
///
/// 刻意保守：
/// - 只统计普通文件（不跟随符号链接，不进入文件包内部）；
/// - 跳过系统与受保护目录，绝不把 `/System`、`~/Library/Developer` 之类列成候选；
/// - 绝不删除任何东西，也不写盘。
enum LargeOldFileScanner {
    /// 永不扫描的根：系统、应用、以及本仓库自己的受保护开发路径。
    static let defaultExcludedRoots: [String] = [
        "/System", "/Library", "/Applications", "/private", "/usr", "/bin",
        "/sbin", "/opt", "/Volumes", "/cores", "/dev"
    ]

    static func isExcluded(_ url: URL, home: URL) -> Bool {
        let path = url.standardizedFileURL.path
        for root in defaultExcludedRoots where path == root || path.hasPrefix(root + "/") {
            return true
        }
        // 用户目录下只排除真正不该碰的：.Trash 里已经是待删的，重复列出没有意义。
        let trash = home.appendingPathComponent(".Trash").standardizedFileURL.path
        if path == trash || path.hasPrefix(trash + "/") { return true }
        return false
    }

    static func scan(
        criteria: LargeOldFileCriteria,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default,
        now: Date = Date(),
        isCancelled: () -> Bool = { false }
    ) -> LargeOldFileScanReport {
        let keys: [URLResourceKey] = [
            .isRegularFileKey, .isSymbolicLinkKey, .fileAllocatedSizeKey,
            .fileSizeKey, .contentModificationDateKey, .isDirectoryKey
        ]
        let cutoff: Date? = criteria.olderThanDays.map {
            now.addingTimeInterval(-Double(max(0, $0)) * 86_400)
        }

        var candidates: [LargeOldFileCandidate] = []
        var scanned = 0
        var unreadable = 0

        for root in criteria.roots {
            let standardizedRoot = root.standardizedFileURL
            guard fileManager.fileExists(atPath: standardizedRoot.path) else { continue }
            guard let enumerator = fileManager.enumerator(
                at: standardizedRoot,
                includingPropertiesForKeys: keys,
                options: [.skipsPackageDescendants]
            ) else {
                unreadable += 1
                continue
            }
            for case let url as URL in enumerator {
                if isCancelled() {
                    return LargeOldFileScanReport(
                        candidates: sorted(candidates, limit: criteria.limit),
                        scannedFileCount: scanned,
                        skippedUnreadableCount: unreadable,
                        truncatedByLimit: hasMore(candidates, limit: criteria.limit)
                    )
                }
                if isExcluded(url, home: home) {
                    // 命中排除目录要连同整棵子树跳过：只 continue 会继续下探，
                    // 把 /Library、~/Applications 之类几万个子项白扫一遍。
                    if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                        enumerator.skipDescendants()
                    }
                    continue
                }
                guard let values = try? url.resourceValues(forKeys: Set(keys)) else {
                    unreadable += 1
                    continue
                }
                guard values.isDirectory != true,
                      values.isRegularFile == true,
                      values.isSymbolicLink != true else { continue }
                scanned += 1

                let bytes = Int64(values.fileAllocatedSize ?? values.fileSize ?? 0)
                guard bytes >= criteria.minimumBytes else { continue }
                guard let modified = values.contentModificationDate else { continue }
                if let cutoff, modified > cutoff { continue }

                candidates.append(
                    LargeOldFileCandidate(path: url.standardizedFileURL, sizeBytes: bytes, modifiedAt: modified)
                )
            }
        }

        return LargeOldFileScanReport(
            candidates: sorted(candidates, limit: criteria.limit),
            scannedFileCount: scanned,
            skippedUnreadableCount: unreadable,
            truncatedByLimit: hasMore(candidates, limit: criteria.limit)
        )
    }

    private static func sorted(_ items: [LargeOldFileCandidate], limit: Int) -> [LargeOldFileCandidate] {
        items.sorted {
            if $0.sizeBytes == $1.sizeBytes {
                return $0.path.path < $1.path.path
            }
            return $0.sizeBytes > $1.sizeBytes
        }
        .prefix(max(0, limit))
        .map { $0 }
    }

    private static func hasMore(_ items: [LargeOldFileCandidate], limit: Int) -> Bool {
        items.count > max(0, limit)
    }

    /// 默认扫描范围：用户主目录下常见的富内容目录。文档/桌面默认排除没有意义
    /// （用户就是要找自己的大文件），所以这里给出的是「默认起点」而非限制。
    static func defaultRoots(home: URL) -> [URL] {
        ["Downloads", "Movies", "Music", "Pictures", "Documents", "Desktop"]
            .map { home.appendingPathComponent($0) }
    }
}
