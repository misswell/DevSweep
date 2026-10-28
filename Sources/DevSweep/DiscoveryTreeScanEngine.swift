import Darwin
import Foundation

/// 一次遍历构建完整目录树。使用 `fts(3)` 做迭代式深度优先扫描：
/// 不跟随符号链接、不跨卷、逐条目读取元数据，目录在离开时把自身汇总并入父节点。
/// 扫描线程只构建局部快照，完成后一次性交给调用方；取消或超限时保留已扫描部分并标记不完整。
enum DiscoveryTreeScanEngine {
    /// 节点上限保护内存：每条记录约 100 字节，三百万条约 300 MB。
    static let defaultNodeLimit = 3_000_000
    private static let issueLimit = 100

    struct Progress: Equatable {
        let phase: String
        let currentPath: String
        let checkedCount: Int
        let directoryCount: Int
    }

    struct Options {
        var nodeLimit: Int = defaultNodeLimit
        var isCancelled: () -> Bool = { false }
        var progress: (Progress) -> Void = { _ in }
    }

    static func scan(root: URL, options: Options = Options()) -> DiscoveryTreeSnapshot {
        let startedAt = Date()
        let rootURL = root.standardizedFileURL
        var builder = Builder(rootURL: rootURL, nodeLimit: max(options.nodeLimit, 1))
        defer { builder.finish() }

        guard !options.isCancelled() else {
            builder.wasCancelled = true
            return builder.snapshot(scannedAt: startedAt, duration: Date().timeIntervalSince(startedAt))
        }

        var rootInfo = stat()
        guard lstat(rootURL.path, &rootInfo) == 0 else {
            builder.recordRootIssue(rootURL, "目录不存在或无法读取")
            return builder.snapshot(scannedAt: startedAt, duration: Date().timeIntervalSince(startedAt))
        }
        guard (rootInfo.st_mode & S_IFMT) == S_IFDIR else {
            builder.recordRootIssue(rootURL, "不是可读取的目录")
            return builder.snapshot(scannedAt: startedAt, duration: Date().timeIntervalSince(startedAt))
        }
        let rootDevice = UInt64(rootInfo.st_dev)

        var pathPointer = strdup(rootURL.path)
        defer { free(pathPointer) }
        var arguments: [UnsafeMutablePointer<CChar>?] = [pathPointer, nil]
        guard let stream = fts_open(&arguments, FTS_PHYSICAL | FTS_NOCHDIR, nil) else {
            builder.recordRootIssue(rootURL, "无法开始遍历目录")
            return builder.snapshot(scannedAt: startedAt, duration: Date().timeIntervalSince(startedAt))
        }
        defer { fts_close(stream) }

        var openDirectories: [Int] = []
        var lastProgressAt = Date()
        var lastProgressCount = 0
        var entryCount = 0

        while let entry = fts_read(stream) {
            let info = Int32(entry.pointee.fts_info)
            entryCount += 1

            // 取消与节点上限检查放在每次迭代的公共入口：错误分支（FTS_ERR / FTS_NS）
            // 与各 FTS_DNR 子分支都先经过这里，不会因为 continue 跳过退出条件。
            if options.isCancelled() {
                builder.wasCancelled = true
                break
            }
            if builder.reachedLimit {
                builder.limitReached = true
                break
            }

            if entryCount % 512 == 0 {
                if Date().timeIntervalSince(lastProgressAt) > 0.15
                    || entryCount - lastProgressCount >= 8_192 {
                    lastProgressAt = Date()
                    lastProgressCount = entryCount
                    options.progress(Progress(
                        phase: "正在遍历目录树",
                        currentPath: URL(fileURLWithPath: String(cString: entry.pointee.fts_path)).devSweepDisplayPath,
                        checkedCount: entryCount,
                        directoryCount: builder.directoryCount
                    ))
                }
            }

            if info == FTS_ERR || info == FTS_NS {
                // FTS_NS / FTS_ERR 不是目录生命周期事件，直接作为无法统计的条目挂在当前目录下。
                // FTS_DNR 走下面的目录分支，避免同一目录被记两次。
                builder.noteError(entry, kind: info)
                builder.appendUnreadableEntry(entry, parent: openDirectories.last)
                continue
            }

            switch info {
            case FTS_D:
                let parent = openDirectories.last
                guard let statPointer = entry.pointee.fts_statp else {
                    builder.appendUnreadableEntry(entry, parent: parent)
                    continue
                }
                let isCrossVolume = UInt64(statPointer.pointee.st_dev) != rootDevice
                let index = builder.append(
                    entry: entry,
                    stat: statPointer.pointee,
                    parent: parent,
                    isDirectory: true,
                    isCrossVolume: isCrossVolume,
                    unreadable: false
                )
                openDirectories.append(index)
                if isCrossVolume {
                    builder.crossVolumeCount += 1
                    builder.noteIssue(
                        path: builder.path(of: index),
                        reason: "位于其他卷或挂载点，未跨越扫描",
                        kind: .skipped
                    )
                    // FTS_SKIP 后 fts 不会再发 FTS_DP，必须立即出栈并汇总，
                    // 否则后续父目录的 FTS_DP 会错误地弹出这一层。
                    _ = fts_set(stream, entry, FTS_SKIP)
                    openDirectories.removeLast()
                    builder.closeDirectory(index, parent: openDirectories.last)
                }

            case FTS_DP:
                if let index = openDirectories.popLast() {
                    builder.closeDirectory(index, parent: openDirectories.last)
                }

            case FTS_F:
                guard let statPointer = entry.pointee.fts_statp else { continue }
                _ = builder.append(
                    entry: entry,
                    stat: statPointer.pointee,
                    parent: openDirectories.last,
                    isDirectory: false,
                    isCrossVolume: false,
                    unreadable: false
                )

            case FTS_SL, FTS_SLNONE:
                builder.symlinkCount += 1
                builder.noteIssue(
                    path: String(cString: entry.pointee.fts_path),
                    reason: "符号链接，未跟随",
                    kind: .skipped
                )

            case FTS_DNR:
                // 可 stat 但不可读的目录会先收到 FTS_D 再收到 FTS_DNR；此时节点已经入栈，
                // 只标记不可读，不能重复创建，否则路径会变成 locked/locked。
                if let top = openDirectories.last,
                   builder.records.indices.contains(top),
                   builder.records[top].name == DiscoveryTreeScanEngine.entryName(entry) {
                    builder.unreadableCount += 1
                    builder.records[top].skippedCount += 1
                    builder.noteIssue(
                        path: builder.path(of: top),
                        reason: "无法读取目录内容",
                        kind: .inaccessible
                    )
                    // fts 不会为这个目录再发 FTS_DP，立即出栈并汇总。
                    openDirectories.removeLast()
                    builder.closeDirectory(top, parent: openDirectories.last)
                    continue
                }
                guard let statPointer = entry.pointee.fts_statp else {
                    builder.appendUnreadableEntry(entry, parent: openDirectories.last)
                    continue
                }
                let index = builder.append(
                    entry: entry,
                    stat: statPointer.pointee,
                    parent: openDirectories.last,
                    isDirectory: true,
                    isCrossVolume: false,
                    unreadable: true
                )
                builder.unreadableCount += 1
                builder.noteIssue(
                    path: builder.path(of: index),
                    reason: "无法读取目录内容",
                    kind: .inaccessible
                )
                builder.closeDirectory(index, parent: openDirectories.last)

            default:
                break
            }

            if builder.reachedLimit {
                builder.limitReached = true
                break
            }
        }

        // 中途停止时把仍打开的目录按由深到浅汇总，已扫描部分仍然有效。
        while let index = openDirectories.popLast() {
            builder.closeDirectory(index, parent: openDirectories.last)
        }
        if builder.reachedLimit {
            builder.limitReached = true
        }

        options.progress(Progress(
            phase: builder.wasCancelled ? "已取消" : "扫描完成",
            currentPath: rootURL.devSweepDisplayPath,
            checkedCount: entryCount,
            directoryCount: builder.directoryCount
        ))
        return builder.snapshot(scannedAt: startedAt, duration: Date().timeIntervalSince(startedAt))
    }

    /// `fts_name` 在 Swift 里是不可变元组，无法直接取 C 字符串；从路径尾部按
    /// `fts_namelen` 截取同名子串，避免为每个条目先构造完整路径字符串。
    static func entryName(_ entry: UnsafeMutablePointer<FTSENT>) -> String {
        let nameLength = Int(entry.pointee.fts_namelen)
        guard nameLength > 0, let pathPointer = entry.pointee.fts_path else { return "" }
        let pathLength = strlen(pathPointer)
        guard pathLength >= nameLength else { return String(cString: pathPointer) }
        return String(cString: pathPointer + (pathLength - nameLength))
    }

    private struct Builder {
        let rootURL: URL
        let nodeLimit: Int

        var records: [DiscoveryTreeRecord] = []
        var parentIndices: [Int32] = []
        var issues: [ScanDiagnostic] = []
        var wasCancelled = false
        var limitReached = false
        var reachedLimit = false
        var symlinkCount = 0
        var crossVolumeCount = 0
        var unreadableCount = 0
        var sharedDeduplicatedCount = 0
        var directoryCount = 0
        var checkedEntries = 0
        var seenInodes = Set<InodeKey>()
        private var finalized = false

        init(rootURL: URL, nodeLimit: Int) {
            self.rootURL = rootURL
            self.nodeLimit = nodeLimit
            records.reserveCapacity(4_096)
            parentIndices.reserveCapacity(4_096)
        }

        mutating func recordRootIssue(_ url: URL, _ reason: String) {
            noteIssue(path: url.path, reason: reason, kind: .unavailable)
        }

        mutating func noteIssue(path: String, reason: String, kind: ScanIssueKind) {
            guard issues.count < DiscoveryTreeScanEngine.issueLimit else { return }
            issues.append(ScanDiagnostic(
                path: URL(fileURLWithPath: path),
                reason: reason,
                kind: kind
            ))
        }

        mutating func noteError(_ entry: UnsafeMutablePointer<FTSENT>, kind: Int32) {
            guard issues.count < DiscoveryTreeScanEngine.issueLimit else { return }
            unreadableCount += 1
            let path = String(cString: entry.pointee.fts_path)
            let reason: String
            switch kind {
            case FTS_DNR: reason = "无法读取目录内容"
            case FTS_NS: reason = "无法读取路径信息"
            default: reason = "遍历时发生错误"
            }
            noteIssue(path: path, reason: reason, kind: .inaccessible)
        }

        mutating func appendUnreadableEntry(
            _ entry: UnsafeMutablePointer<FTSENT>,
            parent: Int?
        ) {
            unreadableCount += 1
            guard let parent, records.indices.contains(parent) else { return }
            guard records.count < nodeLimit else {
                reachedLimit = true
                return
            }
            let name = DiscoveryTreeScanEngine.entryName(entry)
            records.append(DiscoveryTreeRecord(
                name: name,
                parentIndex: Int32(parent),
                allocatedBytes: 0,
                logicalBytes: 0,
                fileCount: 0,
                directoryCount: 0,
                skippedCount: 1,
                isDirectory: false,
                isHidden: name.hasPrefix("."),
                isCrossVolume: false,
                isSharedAllocationDeduplicated: false,
                modifiedAt: nil
            ))
            parentIndices.append(Int32(parent))
            records[parent].skippedCount += 1
        }

        mutating func append(
            entry: UnsafeMutablePointer<FTSENT>,
            stat info: stat,
            parent: Int?,
            isDirectory: Bool,
            isCrossVolume: Bool,
            unreadable: Bool
        ) -> Int {
            guard records.count < nodeLimit else {
                reachedLimit = true
                if let parent, records.indices.contains(parent) {
                    records[parent].skippedCount += 1
                }
                return -1
            }

            let name: String
            if parent == nil {
                name = rootURL.lastPathComponent.isEmpty ? rootURL.path : rootURL.lastPathComponent
            } else {
                name = DiscoveryTreeScanEngine.entryName(entry)
            }

            var allocated = Int64(info.st_blocks) * 512
            var deduplicated = false
            if !isDirectory, (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink > 1 {
                let key = InodeKey(device: UInt64(info.st_dev), inode: UInt64(info.st_ino))
                if !seenInodes.insert(key).inserted {
                    allocated = 0
                    deduplicated = true
                    sharedDeduplicatedCount += 1
                }
            }

            checkedEntries += 1
            let index = records.count
            records.append(DiscoveryTreeRecord(
                name: name,
                parentIndex: parent.map { Int32($0) } ?? -1,
                allocatedBytes: allocated,
                logicalBytes: isDirectory ? 0 : max(0, Int64(info.st_size)),
                fileCount: isDirectory ? 0 : 1,
                directoryCount: 0,
                skippedCount: unreadable ? 1 : 0,
                isDirectory: isDirectory,
                isHidden: name.hasPrefix(".") || (info.st_flags & UInt32(UF_HIDDEN)) != 0,
                isCrossVolume: isCrossVolume,
                isSharedAllocationDeduplicated: deduplicated,
                modifiedAt: Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)
                    + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000)
            ))
            parentIndices.append(parent.map { Int32($0) } ?? -1)
            if isDirectory { directoryCount += 1 }
            if let parent, records.indices.contains(parent) {
                if isDirectory {
                    // 目录自身的大小在离开遍历栈时连同子树一起并入父目录。
                    if unreadable { records[parent].skippedCount = Self.addClamped(records[parent].skippedCount, 1) }
                } else {
                    records[parent].allocatedBytes = Self.addClamped(records[parent].allocatedBytes, allocated)
                    records[parent].logicalBytes = Self.addClamped(records[parent].logicalBytes, records[index].logicalBytes)
                    records[parent].fileCount = Self.addClamped(records[parent].fileCount, 1)
                }
            }
            return index
        }

        /// 目录离开遍历栈时，把自己的汇总并入父目录。
        mutating func closeDirectory(_ index: Int, parent: Int?) {
            guard records.indices.contains(index) else { return }
            let record = records[index]
            guard let parent, records.indices.contains(parent) else { return }
            records[parent].allocatedBytes = Self.addClamped(records[parent].allocatedBytes, record.allocatedBytes)
            records[parent].logicalBytes = Self.addClamped(records[parent].logicalBytes, record.logicalBytes)
            records[parent].fileCount = Self.addClamped(records[parent].fileCount, record.fileCount)
            records[parent].directoryCount = Self.addClamped(
                records[parent].directoryCount,
                Self.addClamped(record.directoryCount, 1)
            )
            records[parent].skippedCount = Self.addClamped(records[parent].skippedCount, record.skippedCount)
        }

        func path(of index: Int) -> String {
            guard records.indices.contains(index) else { return rootURL.path }
            var components: [String] = []
            var cursor = index
            var guardCount = 0
            while records.indices.contains(cursor), records[cursor].parentIndex >= 0, guardCount < records.count {
                components.append(records[cursor].name)
                cursor = Int(records[cursor].parentIndex)
                guardCount += 1
            }
            guard !components.isEmpty else { return rootURL.path }
            // 根为 "/" 时不能拼出 "//Users"，前缀直接就是 "/"。
            let prefix = rootURL.path == "/" ? "/" : rootURL.path + "/"
            return prefix + components.reversed().joined(separator: "/")
        }

        mutating func finish() {
            guard !finalized else { return }
            finalized = true
        }

        func snapshot(scannedAt: Date, duration: TimeInterval) -> DiscoveryTreeSnapshot {
            let topology = Self.flattenTopology(records: records, parentIndices: parentIndices)
            var spans = records
            for index in spans.indices {
                spans[index].firstChildIndex = 0
                spans[index].childCount = 0
            }
            // childIndices 按父节点分组连续存放，区间起点就是前缀和。
            for index in 1..<max(spans.count, 1) {
                let parent = Int(parentIndices[index])
                guard parent >= 0, parent < spans.count else { continue }
                spans[parent].childCount += 1
            }
            var cursor: Int32 = 0
            for index in spans.indices {
                spans[index].firstChildIndex = cursor
                cursor += spans[index].childCount
            }
            return DiscoveryTreeSnapshot(
                rootIndex: 0,
                records: spans,
                childIndices: topology,
                rootURL: rootURL,
                scannedAt: scannedAt,
                duration: duration,
                wasCancelled: wasCancelled,
                limitReached: limitReached,
                checkedCount: checkedEntries,
                symlinkCount: symlinkCount,
                crossVolumeCount: crossVolumeCount,
                unreadableCount: unreadableCount,
                sharedDeduplicatedCount: sharedDeduplicatedCount,
                issues: issues
            )
        }

        /// 把「每个节点记录父索引」转换成连续的子节点区间：
        /// 先计数、再前缀和、最后按节点顺序稳定放置，子节点保持扫描顺序。
        static func flattenTopology(records: [DiscoveryTreeRecord], parentIndices: [Int32]) -> [Int32] {
            guard !records.isEmpty else { return [] }
            var childCounts = [Int32](repeating: 0, count: records.count)
            for index in 1..<records.count {
                let parent = Int(parentIndices[index])
                if parent >= 0, parent < records.count {
                    childCounts[parent] += 1
                }
            }
            var starts = [Int32](repeating: 0, count: records.count)
            var cursor: Int32 = 0
            for index in records.indices {
                starts[index] = cursor
                cursor += childCounts[index]
            }
            var placement = starts
            var children = [Int32](repeating: 0, count: Int(cursor))
            for index in 1..<records.count {
                let parent = Int(parentIndices[index])
                guard parent >= 0, parent < records.count else { continue }
                children[Int(placement[parent])] = Int32(index)
                placement[parent] += 1
            }
            return children
        }

        static func addClamped(_ lhs: Int64, _ rhs: Int64) -> Int64 {
            let (sum, overflow) = lhs.addingReportingOverflow(rhs)
            return overflow ? Int64.max : sum
        }

        static func addClamped(_ lhs: Int32, _ rhs: Int32) -> Int32 {
            let (sum, overflow) = lhs.addingReportingOverflow(rhs)
            return overflow ? Int32.max : sum
        }
    }

    private struct InodeKey: Hashable {
        let device: UInt64
        let inode: UInt64
    }
}
