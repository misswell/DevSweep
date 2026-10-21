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
        guard state != .complete else { return nil }
        if let failureReason { return failureReason }
        return state == .timedOut ? "统计超时，实际占用可能更大" : "部分目录无法读取，实际占用可能更大"
    }
}

enum StorageMeasurementService {
    private static let duURL = URL(fileURLWithPath: "/usr/bin/du")
    static let defaultTimeout: TimeInterval = 30

    static func measure(_ url: URL, timeout: TimeInterval = defaultTimeout) -> StorageMeasurement {
        let standardized = url.standardizedFileURL
        guard FileManager.default.fileExists(atPath: standardized.path) else {
            return StorageMeasurement(allocatedBytes: 0, state: .failed, failureReason: "路径不存在")
        }

        if let values = try? standardized.resourceValues(forKeys: [.isDirectoryKey]),
           values.isDirectory != true {
            let allocated = (try? standardized.resourceValues(forKeys: [.fileAllocatedSizeKey]))?.fileAllocatedSize
            return StorageMeasurement(allocatedBytes: Int64(allocated ?? 0))
        }

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

    /// 一次 `du` 调用测量多个目录。macOS 的 du 会在同一次调用的参数之间对硬链接去重。
    static func measure(_ urls: [URL], timeout: TimeInterval = defaultTimeout) -> [String: StorageMeasurement] {
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

        let result = ProcessRunner.run(
            executable: duURL,
            arguments: ["-sk"] + pending.map(\.path),
            timeout: timeout
        )

        if let result {
            // 按路径而不是按输出顺序对齐：某个参数在测量前消失时，
            // du 只会为其余路径输出行，按顺序 zip 会把大小配错目录。
            let parsed = parseDuOutput(result.stdout)
            for url in pending {
                guard let bytes = parsed[url.path] else { continue }
                measurements[url.path] = interpret(bytes: bytes, result: result)
            }
            if result.timedOut {
                for url in pending where measurements[url.path] == nil {
                    measurements[url.path] = StorageMeasurement(
                        allocatedBytes: 0,
                        state: .timedOut,
                        failureReason: "统计超时，未完成全部目录"
                    )
                }
                return measurements
            }
        }

        for url in pending where measurements[url.path] == nil {
            measurements[url.path] = measure(url, timeout: timeout)
        }
        return measurements
    }

    /// 把一次 `du -sk <dir>` 的输出解释为测量值；stdout 无法解析时返回 nil，
    /// 由调用方决定是否退回逐文件枚举。
    static func interpretSingle(_ result: ProcessResult) -> StorageMeasurement? {
        guard let bytes = parseDuOutput(result.stdout).values.first else { return nil }
        return interpret(bytes: bytes, result: result)
    }

    private static func interpret(bytes: Int64, result: ProcessResult) -> StorageMeasurement {
        if result.timedOut {
            return StorageMeasurement(
                allocatedBytes: bytes,
                state: .timedOut,
                failureReason: "统计超时，未完成全部目录"
            )
        }
        if result.status != 0 {
            return StorageMeasurement(
                allocatedBytes: bytes,
                state: .partial,
                failureReason: failureReason(for: result)
            )
        }
        if !result.stderr.isEmpty {
            // du 在 status 0 下仍可能报告个别路径警告；保守地按不完整处理。
            return StorageMeasurement(
                allocatedBytes: bytes,
                state: .partial,
                failureReason: failureReason(for: result)
            )
        }
        return StorageMeasurement(allocatedBytes: bytes)
    }

    private static func failureReason(for result: ProcessResult) -> String {
        let text = String(data: result.stderr, encoding: .utf8) ?? ""
        let errorLines = text
            .split(whereSeparator: \.isNewline)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .count
        if errorLines > 0 {
            return "有 \(errorLines) 个条目无法读取，实际占用可能更大"
        }
        return "未能完成占用统计，实际占用可能更大"
    }

    /// `du -sk` 每行是 "<kilobytes>\t<path>"，路径里可能有空格，所以按第一个 tab 切分。
    private static func parseDuOutput(_ data: Data) -> [String: Int64] {
        guard let text = String(data: data, encoding: .utf8) else { return [:] }
        var parsed: [String: Int64] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let tab = line.firstIndex(of: "\t") else { continue }
            let sizeField = line[..<tab].trimmingCharacters(in: .whitespaces)
            let path = String(line[line.index(after: tab)...])
            guard !path.isEmpty, let kilobytes = Int64(sizeField) else { continue }
            parsed[path] = kilobytes * 1024
        }
        return parsed
    }

    /// du 不可用或输出无法解析时的回退。硬链接按 (device, inode) 去重，
    /// 避免同一份磁盘块被多个目录重复累加。
    static func measureByEnumeration(_ url: URL) -> StorageMeasurement {
        var skippedCount = 0
        var seenInodes = Set<InodeKey>()
        var total: Int64 = 0

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
                _ = accumulate(child.path)
            }
        } else {
            skippedCount += 1
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
