import Darwin
import Foundation

enum MeasurementState: String, Hashable {
    case complete
    case partial
    case failed
    case timedOut
}

/// 目录占用的测量结果。只有 `state == .complete` 时 `allocatedBytes` 才是精确值；
/// 其余状态必须按「至少占用」或「无法统计」展示。
struct StorageMeasurement: Hashable {
    let allocatedBytes: Int64
    let state: MeasurementState
    let skippedCount: Int
    let failureReason: String?

    init(
        allocatedBytes: Int64,
        state: MeasurementState = .complete,
        skippedCount: Int = 0,
        failureReason: String? = nil
    ) {
        self.allocatedBytes = allocatedBytes
        self.state = state
        self.skippedCount = skippedCount
        self.failureReason = failureReason
    }

    var isComplete: Bool { state == .complete }

    var warning: String? {
        switch state {
        case .complete: return nil
        case .failed: return failureReason ?? "无法统计该条目占用"
        case .timedOut: return failureReason ?? "统计超时，实际占用可能更大"
        case .partial: return failureReason ?? "部分目录无法读取，实际占用可能更大"
        }
    }
}

enum StorageMeasurementService {
    private static let duURL = URL(fileURLWithPath: "/usr/bin/du")
    static let defaultTimeout: TimeInterval = 30

    private static let metricsLock = NSLock()
    private static var duInvocationCountValue = 0
    /// 测量服务启动的 du 进程数；用于验证批量路径不会再逐项起进程。
    static var duInvocationCount: Int {
        metricsLock.lock()
        defer { metricsLock.unlock() }
        return duInvocationCountValue
    }
    static func resetDuInvocationCount() {
        metricsLock.lock()
        duInvocationCountValue = 0
        metricsLock.unlock()
    }
    private static func recordDuInvocation() {
        metricsLock.lock()
        duInvocationCountValue += 1
        metricsLock.unlock()
    }

    static func measure(_ url: URL, timeout: TimeInterval = defaultTimeout) -> StorageMeasurement {
        let standardized = url.standardizedFileURL
        guard FileManager.default.fileExists(atPath: standardized.path) else {
            return StorageMeasurement(allocatedBytes: 0, state: .failed, failureReason: "路径不存在")
        }

        if let values = try? standardized.resourceValues(forKeys: [.isDirectoryKey]),
           values.isDirectory != true {
            return measureFile(standardized, allocatedSize: (try? standardized.resourceValues(
                forKeys: [.fileAllocatedSizeKey]
            ))?.fileAllocatedSize)
        }

        recordDuInvocation()
        guard let result = ProcessRunner.run(
            executable: duURL,
            arguments: ["-sk", standardized.path],
            timeout: timeout
        ) else {
            return measureByEnumeration(standardized)
        }

        if let measurement = interpretSingle(result) {
            return measurement
        }
        // 超时后 stdout 通常没有可解析结果；这时退回逐文件枚举会把整个扫描拖得更久。
        if result.timedOut {
            return StorageMeasurement(
                allocatedBytes: 0,
                state: .timedOut,
                failureReason: "统计超时，未完成全部目录"
            )
        }
        return measureByEnumeration(standardized)
    }

    /// 单个文件（非目录）的占用。缺少 `fileAllocatedSize` 属性时退回 `lstat` 的块数，
    /// 两者都拿不到才算失败：把读不到的占用记成 0 B 会让图表静默丢项。
    static func measureFile(_ url: URL, allocatedSize: Int?) -> StorageMeasurement {
        if let allocatedSize, allocatedSize >= 0 {
            return StorageMeasurement(allocatedBytes: Int64(allocatedSize))
        }
        var info = stat()
        if lstat(url.path, &info) == 0 {
            return StorageMeasurement(allocatedBytes: Int64(info.st_blocks) * 512)
        }
        return StorageMeasurement(
            allocatedBytes: 0,
            state: .failed,
            failureReason: "无法读取文件占用信息"
        )
    }

    /// 一次 `du` 调用测量多个目录。macOS 的 du 会在同一次调用的参数之间对硬链接去重。
    static func measure(_ urls: [URL], timeout: TimeInterval = defaultTimeout) -> [String: StorageMeasurement] {
        measureAll(urls, timeout: timeout)
    }

    /// 目录集合的统一测量入口：只要有参数预算，就只起一个 `du` 进程，
    /// 让整个集合共享硬链接去重状态，而不是拆成互不相干的批次。
    /// `onMeasurement` 在读取到每个目录的输出时立即回调，便于界面增量发布；
    /// 进程结束后返回的字典才是经过错误归属校正的最终结果。
    static func measureAll(
        _ urls: [URL],
        timeout: TimeInterval = defaultTimeout,
        isCancelled: () -> Bool = { false },
        onMeasurement: ((String, StorageMeasurement) -> Void)? = nil
    ) -> [String: StorageMeasurement] {
        let standardized = urls.map(\.standardizedFileURL)
        guard !standardized.isEmpty else { return [:] }

        var measurements: [String: StorageMeasurement] = [:]
        var pending: [URL] = []
        for url in standardized {
            if FileManager.default.fileExists(atPath: url.path) {
                pending.append(url)
            } else {
                measurements[url.path] = StorageMeasurement(
                    allocatedBytes: 0,
                    state: .failed,
                    failureReason: "路径不存在"
                )
            }
        }
        guard !pending.isEmpty else { return measurements }

        let paths = pending.map(\.path)
        guard fitsArgumentBudget(paths), !isCancelled() else {
            // 参数超长或已取消：退回共享 inode 集合的枚举，仍然保证一次遍历内的全局去重。
            let enumerated = measureByEnumeration(pending, isCancelled: isCancelled)
            for (path, measurement) in enumerated {
                measurements[path] = measurement
                onMeasurement?(path, measurement)
            }
            return measurements
        }

        guard let streamed = runDu(paths, timeout: timeout, isCancelled: isCancelled,
                                   onMeasurement: onMeasurement) else {
            let enumerated = measureByEnumeration(pending, isCancelled: isCancelled)
            measurements.merge(enumerated) { _, latest in latest }
            return measurements
        }
        measurements.merge(streamed) { _, latest in latest }
        return measurements
    }

    /// 单次 `du` 进程，一边读取输出一边回调每个目录的结果。
    private static func runDu(
        _ paths: [String],
        timeout: TimeInterval,
        isCancelled: () -> Bool,
        onMeasurement: ((String, StorageMeasurement) -> Void)?
    ) -> [String: StorageMeasurement]? {
        recordDuInvocation()
        let task = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        task.executableURL = duURL
        task.arguments = ["-sk"] + paths
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = outputPipe
        task.standardError = errorPipe

        guard (try? task.run()) != nil else {
            outputPipe.fileHandleForReading.closeFile()
            errorPipe.fileHandleForReading.closeFile()
            return nil
        }

        let lock = NSLock()
        var parsed: [String: Int64] = [:]
        var stderrData = Data()
        let readGroup = DispatchGroup()

        readGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            var buffer = Data()
            let handle = outputPipe.fileHandleForReading
            while true {
                guard let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty else { break }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[buffer.startIndex..<newline]
                    buffer.removeSubrange(buffer.startIndex...newline)
                    guard let (path, bytes) = parseDuLine(line) else { continue }
                    lock.lock()
                    parsed[path] = bytes
                    lock.unlock()
                    onMeasurement?(path, StorageMeasurement(allocatedBytes: bytes))
                }
            }
            if let (path, bytes) = parseDuLine(buffer) {
                lock.lock()
                parsed[path] = bytes
                lock.unlock()
                onMeasurement?(path, StorageMeasurement(allocatedBytes: bytes))
            }
            readGroup.leave()
        }

        readGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            lock.lock()
            stderrData = data
            lock.unlock()
            readGroup.leave()
        }

        let deadline = Date().addingTimeInterval(max(timeout, 0))
        var cancelled = false
        var timedOut = false
        while task.isRunning && Date() < deadline {
            if isCancelled() {
                cancelled = true
                break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        if task.isRunning {
            timedOut = !cancelled
            task.terminate()
            let terminationDeadline = Date().addingTimeInterval(0.25)
            while task.isRunning && Date() < terminationDeadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            }
            if task.isRunning {
                kill(task.processIdentifier, SIGKILL)
            }
        }
        task.waitUntilExit()
        readGroup.wait()

        lock.lock()
        let parsedSnapshot = parsed
        let stderrSnapshot = stderrData
        lock.unlock()

        let result = ProcessResult(
            status: task.terminationStatus,
            stdout: Data(),
            stderr: stderrSnapshot,
            timedOut: timedOut || cancelled
        )
        let errors = attributeErrors(result, to: paths)
        var measurements: [String: StorageMeasurement] = [:]
        for path in paths {
            if let bytes = parsedSnapshot[path] {
                if cancelled {
                    measurements[path] = StorageMeasurement(
                        allocatedBytes: bytes, state: .timedOut,
                        skippedCount: errors.counts[path] ?? 0,
                        failureReason: "本次刷新已取消"
                    )
                } else {
                    measurements[path] = interpret(
                        bytes: bytes,
                        timedOut: timedOut,
                        errorCount: errors.counts[path] ?? 0,
                        hasUnattributedError: errors.hasUnattributed
                    )
                }
            } else if timedOut || cancelled {
                measurements[path] = StorageMeasurement(
                    allocatedBytes: 0, state: .timedOut,
                    failureReason: cancelled ? "本次刷新已取消" : "统计超时，未完成全部目录"
                )
            } else {
                measurements[path] = StorageMeasurement(
                    allocatedBytes: 0, state: .failed,
                    failureReason: "路径已变化或无法统计"
                )
            }
        }
        return measurements
    }

    /// 参数总量必须同时满足字节预算和进程框架的 4096 个 argv 硬上限，
    /// 并为环境变量和内部参数留出余量。
    private static func fitsArgumentBudget(_ paths: [String]) -> Bool {
        let argumentMax = Int(sysconf(_SC_ARG_MAX))
        guard argumentMax > 0, paths.count <= 4_000 else { return false }
        let byteCount = paths.reduce(0) { $0 + $1.utf8.count + 1 }
        return byteCount + 64 * 1024 < argumentMax
    }

    /// 一次枚举多个目录，共享同一个 inode 集合，避免跨目录硬链接被重复累计。
    private static func measureByEnumeration(
        _ urls: [URL],
        isCancelled: () -> Bool
    ) -> [String: StorageMeasurement] {
        var seenInodes = Set<InodeKey>()
        var measurements: [String: StorageMeasurement] = [:]
        for url in urls {
            if isCancelled() {
                measurements[url.path] = StorageMeasurement(
                    allocatedBytes: 0, state: .timedOut, failureReason: "本次刷新已取消"
                )
                continue
            }
            measurements[url.path] = measureByEnumeration(url, seenInodes: &seenInodes, isCancelled: isCancelled)
        }
        return measurements
    }

    /// 把一次批量 `du -sk` 的输出生成各被测目录的测量值。
    /// 按路径而不是按输出顺序对齐：某个参数在测量前消失时，du 只会为其余路径输出行，
    /// 按顺序 zip 会把大小配错目录。没有输出的目录不出现在结果里（超时除外），
    /// 由调用方决定是否逐项回退。
    static func interpretBatch(_ result: ProcessResult, paths: [String]) -> [String: StorageMeasurement] {
        let parsed = parseDuOutput(result.stdout)
        let errors = attributeErrors(result, to: paths)
        var measurements: [String: StorageMeasurement] = [:]
        for path in paths {
            guard let bytes = parsed[path] else { continue }
            measurements[path] = interpret(
                bytes: bytes,
                timedOut: result.timedOut,
                errorCount: errors.counts[path] ?? 0,
                hasUnattributedError: errors.hasUnattributed
            )
        }
        if result.timedOut {
            for path in paths where measurements[path] == nil {
                measurements[path] = StorageMeasurement(
                    allocatedBytes: 0,
                    state: .timedOut,
                    failureReason: "统计超时，未完成全部目录"
                )
            }
        }
        return measurements
    }

    /// 把一次 `du -sk <dir>` 的输出解释为测量值；stdout 无法解析时返回 nil，
    /// 由调用方决定是否退回逐文件枚举。
    static func interpretSingle(_ result: ProcessResult) -> StorageMeasurement? {
        let parsed = parseDuOutput(result.stdout)
        guard let entry = parsed.first else { return nil }
        let errors = attributeErrors(result, to: [entry.key])
        return interpret(
            bytes: entry.value,
            timedOut: result.timedOut,
            errorCount: errors.counts[entry.key] ?? 0,
            hasUnattributedError: errors.hasUnattributed
        )
    }

    /// 把 `du` 的错误输出归属到具体被测目录。归属不到任何目录的错误只能保守地
    /// 降级全部结果；能定位到某个子条目的错误不应该污染同批次的其他目录。
    private static func attributeErrors(
        _ result: ProcessResult,
        to paths: [String]
    ) -> (counts: [String: Int], hasUnattributed: Bool) {
        let lines = stderrLines(result.stderr)
        guard !lines.isEmpty || result.status != 0 else {
            return ([:], false)
        }
        guard !lines.isEmpty else {
            // 非零退出但没有任何错误文本，无法判断影响范围。
            return ([:], true)
        }

        var counts: [String: Int] = [:]
        var unattributed = 0
        for line in lines {
            guard let errorPath = errorPath(from: line),
                  let owner = paths.first(where: { isPath(errorPath, insideOrEqual: $0) })
            else {
                unattributed += 1
                continue
            }
            counts[owner, default: 0] += 1
        }
        return (counts, unattributed > 0)
    }

    private static func isPath(_ candidate: String, insideOrEqual container: String) -> Bool {
        candidate == container || candidate.hasPrefix(container + "/")
    }

    private static func stderrLines(_ data: Data) -> [String] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// du 的错误行形如 `du: /some/path: Permission denied`。路径本身可能含冒号，
    /// 所以取最后一个 `: ` 之前的部分作为候选路径。
    private static func errorPath(from line: String) -> String? {
        guard line.hasPrefix("du:") else { return nil }
        var body = String(line.dropFirst(3))
        if body.hasPrefix(" ") { body.removeFirst() }
        guard let separator = body.range(of: ": ", options: .backwards) else {
            return body.isEmpty ? nil : body
        }
        let candidate = String(body[..<separator.lowerBound])
        return candidate.isEmpty ? nil : candidate
    }

    private static func interpret(
        bytes: Int64,
        timedOut: Bool,
        errorCount: Int,
        hasUnattributedError: Bool
    ) -> StorageMeasurement {
        if timedOut {
            return StorageMeasurement(
                allocatedBytes: bytes,
                state: .timedOut,
                skippedCount: errorCount,
                failureReason: "统计超时，未完成全部目录"
            )
        }
        if errorCount > 0 {
            return StorageMeasurement(
                allocatedBytes: bytes,
                state: .partial,
                skippedCount: errorCount,
                failureReason: "有 \(errorCount) 个条目无法读取，实际占用可能更大"
            )
        }
        if hasUnattributedError {
            // 出错但无法定位归属，保守按下限展示。
            return StorageMeasurement(
                allocatedBytes: bytes,
                state: .partial,
                failureReason: "未能确认统计覆盖全部条目，实际占用可能更大"
            )
        }
        // 错误已归属到同批次的其他目录，且本目录有完整输出：本目录仍是精确值。
        return StorageMeasurement(allocatedBytes: bytes)
    }

    /// `du -sk` 每行是 "<kilobytes>\t<path>"，路径里可能有空格，所以按第一个 tab 切分。
    private static func parseDuLine(_ data: Data) -> (path: String, bytes: Int64)? {
        let line = String(decoding: data, as: UTF8.self)
        guard let tab = line.firstIndex(of: "\t") else { return nil }
        let sizeField = line[..<tab].trimmingCharacters(in: .whitespaces)
        let path = String(line[line.index(after: tab)...])
        guard !path.isEmpty, let kilobytes = Int64(sizeField) else { return nil }
        return (path, kilobytes * 1024)
    }

    private static func parseDuOutput(_ data: Data) -> [String: Int64] {
        guard let text = String(data: data, encoding: .utf8) else { return [:] }
        var parsed: [String: Int64] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let entry = parseDuLine(Data(line.utf8)) else { continue }
            parsed[entry.path] = entry.bytes
        }
        return parsed
    }

    /// du 不可用或输出无法解析时的回退。硬链接按 (device, inode) 去重，
    /// 避免同一份磁盘块被多个目录重复累加。
    static func measureByEnumeration(_ url: URL) -> StorageMeasurement {
        var seenInodes = Set<InodeKey>()
        return measureByEnumeration(url, seenInodes: &seenInodes, isCancelled: { false })
    }

    /// 多个目录共享同一个 `seenInodes`，跨目录的硬链接也只计一次。
    private static func measureByEnumeration(
        _ url: URL,
        seenInodes: inout Set<InodeKey>,
        isCancelled: () -> Bool
    ) -> StorageMeasurement {
        var skippedCount = 0
        var total: Int64 = 0
        var cancelled = false

        func accumulate(_ path: String) -> Bool {
            var info = stat()
            guard lstat(path, &info) == 0 else {
                skippedCount += 1
                return false
            }
            let key = InodeKey(device: UInt64(info.st_dev), inode: UInt64(info.st_ino))
            guard seenInodes.insert(key).inserted else { return false }
            total += Int64(info.st_blocks) * 512
            return true
        }

        guard FileManager.default.fileExists(atPath: url.path) else {
            return StorageMeasurement(allocatedBytes: 0, state: .failed, failureReason: "路径不存在")
        }
        _ = accumulate(url.path)

        if let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: nil,
            options: [],
            errorHandler: { _, _ in
                skippedCount += 1
                return true
            }
        ) {
            for case let child as URL in enumerator {
                if isCancelled() {
                    cancelled = true
                    break
                }
                _ = accumulate(child.path)
            }
        } else {
            skippedCount += 1
        }

        if cancelled {
            return StorageMeasurement(
                allocatedBytes: total,
                state: .timedOut,
                skippedCount: skippedCount,
                failureReason: "本次刷新已取消"
            )
        }
        if skippedCount > 0 {
            return StorageMeasurement(
                allocatedBytes: total,
                state: .partial,
                skippedCount: skippedCount,
                failureReason: "有 \(skippedCount) 个条目无法读取，实际占用可能更大"
            )
        }
        return StorageMeasurement(allocatedBytes: total)
    }

    private struct InodeKey: Hashable {
        let device: UInt64
        let inode: UInt64
    }
}
