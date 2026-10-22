import Darwin
import Foundation

/// 按扩展名对整个目录子树做的文件类型汇总。
/// `isComplete == false` 时 `totalBytes` 只是已扫描部分的下限。
struct FileTypeRollup: Hashable {
    let summaries: [FileTypeSummary]
    let fileCount: Int
    let directoryCount: Int
    /// 作为整体归类的包目录（.app、.xcarchive、.mlpackage 等）数量。
    let packageCount: Int
    let symlinkCount: Int
    let crossVolumeCount: Int
    let unreadableCount: Int
    let scannedEntries: Int
    let isComplete: Bool
    let limitReached: Bool
    let duration: TimeInterval

    var totalBytes: Int64 {
        summaries.reduce(0) { $0 + $1.allocatedBytes }
    }

    var totalLogicalBytes: Int64 {
        summaries.reduce(0) { $0 + $1.logicalBytes }
    }

    /// 未扫完、或有读不到的条目时，合计只能当作下限。
    var isLowerBound: Bool { !isComplete || unreadableCount > 0 }

    var note: String {
        if limitReached { return "已达条目上限，实际占用可能更大" }
        if unreadableCount > 0 { return "有 \(unreadableCount) 个条目无法读取，实际占用可能更大" }
        if !isComplete { return "统计已中断，当前为已扫描部分的下限" }
        return "覆盖子树内全部常规文件"
    }
}

/// 递归文件类型聚合。规则：
/// - 普通目录自身不计数，只累加其中的文件，避免父目录和子文件重复累计；
/// - 包目录（.app / .xcarchive / .mlpackage 等）整体归类为对应类型并跳过其内部，
///   否则一个 .app 会被拆成成千上万个「编译产物」；
/// - 不跟随符号链接、不跨卷；硬链接按 (设备, inode) 去重；
/// - 有条目上限且可取消，未完成时结果标记为下限。
enum FileTypeRollupScanner {
    static let defaultEntryLimit = 300_000
    static let defaultPackageLimit = 2_000
    private static let packageChunkSize = 128

    struct Progress: Equatable {
        let phase: String
        let currentPath: String
        let scannedEntries: Int
    }

    static func scan(
        root: URL,
        entryLimit: Int = defaultEntryLimit,
        packageLimit: Int = defaultPackageLimit,
        isCancelled: () -> Bool = { false },
        progress: (Progress) -> Void = { _ in }
    ) -> FileTypeRollup {
        let startedAt = Date()
        let standardized = root.standardizedFileURL

        var stats: [FileTypeCategory: (bytes: Int64, logical: Int64, count: Int, lowerBound: Int)] = [:]
        var fileCount = 0
        var directoryCount = 0
        var symlinkCount = 0
        var crossVolumeCount = 0
        var unreadableCount = 0
        var scannedEntries = 0
        var limitReached = false
        var cancelled = false
        var packages: [(url: URL, category: FileTypeCategory)] = []

        func add(_ category: FileTypeCategory, bytes: Int64, logical: Int64, lowerBound: Bool) {
            var entry = stats[category] ?? (0, 0, 0, 0)
            entry.0 += bytes
            entry.1 += logical
            entry.2 += 1
            if lowerBound { entry.3 += 1 }
            stats[category] = entry
        }

        var rootInfo = stat()
        guard lstat(standardized.path, &rootInfo) == 0, (rootInfo.st_mode & S_IFMT) == S_IFDIR else {
            return FileTypeRollup(
                summaries: [],
                fileCount: 0,
                directoryCount: 0,
                packageCount: 0,
                symlinkCount: 0,
                crossVolumeCount: 0,
                unreadableCount: 1,
                scannedEntries: 0,
                isComplete: false,
                limitReached: false,
                duration: Date().timeIntervalSince(startedAt)
            )
        }
        let rootDevice = UInt64(rootInfo.st_dev)

        let enumerator = FileManager.default.enumerator(
            at: standardized,
            includingPropertiesForKeys: nil,
            options: [],
            errorHandler: { _, _ in
                unreadableCount += 1
                return true
            }
        )
        guard let enumerator else {
            return FileTypeRollup(
                summaries: [],
                fileCount: 0,
                directoryCount: 0,
                packageCount: 0,
                symlinkCount: 0,
                crossVolumeCount: 0,
                unreadableCount: 1,
                scannedEntries: 0,
                isComplete: false,
                limitReached: false,
                duration: Date().timeIntervalSince(startedAt)
            )
        }

        var seenInodes = Set<InodeKey>()

        for case let url as URL in enumerator {
            if isCancelled() {
                cancelled = true
                break
            }
            if scannedEntries >= entryLimit || packages.count >= packageLimit {
                limitReached = true
                break
            }
            scannedEntries += 1

            let path = url.standardizedFileURL.path
            var info = stat()
            guard lstat(path, &info) == 0 else {
                unreadableCount += 1
                continue
            }
            let fileType = info.st_mode & S_IFMT
            if fileType == S_IFLNK {
                symlinkCount += 1
                continue
            }
            guard UInt64(info.st_dev) == rootDevice else {
                crossVolumeCount += 1
                if fileType == S_IFDIR { enumerator.skipDescendants() }
                continue
            }

            if fileType == S_IFDIR {
                let category = FileTypeCategory.classify(url: url, isDirectory: true)
                if category == .folder {
                    directoryCount += 1
                    continue
                }
                // 包目录整体按一次 du 统计，不再下降。
                packages.append((url, category))
                enumerator.skipDescendants()
                continue
            }
            guard fileType == S_IFREG else { continue }

            let key = InodeKey(device: UInt64(info.st_dev), inode: UInt64(info.st_ino))
            if info.st_nlink > 1, !seenInodes.insert(key).inserted { continue }

            let allocated = Int64(info.st_blocks) * 512
            let logical = max(0, Int64(info.st_size))
            add(FileTypeCategory.classify(url: url, isDirectory: false), bytes: allocated, logical: logical, lowerBound: false)
            fileCount += 1

            if scannedEntries % 4_096 == 0 {
                progress(Progress(
                    phase: "正在递归统计文件类型",
                    currentPath: url.deletingLastPathComponent().devSweepDisplayPath,
                    scannedEntries: scannedEntries
                ))
            }
        }

        // 包目录用批量 du 统计；一次进程测多个路径，避免为每个 .app 起一个进程。
        var packageFailures = 0
        if !cancelled, !packages.isEmpty {
            for start in stride(from: 0, to: packages.count, by: packageChunkSize) {
                if isCancelled() {
                    cancelled = true
                    break
                }
                let chunk = packages[start..<min(start + packageChunkSize, packages.count)]
                progress(Progress(
                    phase: "正在统计包目录占用",
                    currentPath: chunk.first!.url.deletingLastPathComponent().devSweepDisplayPath,
                    scannedEntries: scannedEntries
                ))
                let measurements = StorageMeasurementService.measure(chunk.map(\.url))
                for package in chunk {
                    guard let measurement = measurements[package.url.standardizedFileURL.path] else {
                        packageFailures += 1
                        continue
                    }
                    if measurement.state != .complete {
                        packageFailures += 1
                    }
                    add(package.category, bytes: measurement.allocatedBytes, logical: 0, lowerBound: measurement.state != .complete)
                }
            }
        }

        let summaries = stats.map { category, entry in
            FileTypeSummary(
                category: category,
                allocatedBytes: entry.bytes,
                logicalBytes: entry.logical,
                itemCount: entry.count,
                lowerBoundCount: entry.lowerBound
            )
        }
        .sorted { lhs, rhs in
            if lhs.allocatedBytes != rhs.allocatedBytes { return lhs.allocatedBytes > rhs.allocatedBytes }
            return lhs.category.rawValue < rhs.category.rawValue
        }

        return FileTypeRollup(
            summaries: summaries,
            fileCount: fileCount,
            directoryCount: directoryCount,
            packageCount: packages.count,
            symlinkCount: symlinkCount,
            crossVolumeCount: crossVolumeCount,
            unreadableCount: unreadableCount + packageFailures,
            scannedEntries: scannedEntries,
            isComplete: !cancelled && !limitReached && unreadableCount == 0 && packageFailures == 0,
            limitReached: limitReached,
            duration: Date().timeIntervalSince(startedAt)
        )
    }

    private struct InodeKey: Hashable {
        let device: UInt64
        let inode: UInt64
    }
}
