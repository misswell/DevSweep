import Darwin
import Foundation

/// 一次「清空废纸篓」的结果。只统计真正删除成功的顶层项目，
/// 便于定时任务摘要和设置页展示。
struct TrashEmptyingReport: Equatable {
    var removedCount = 0
    var removedBytes: Int64 = 0
    var failures: [String] = []
}

protocol TrashEmptying {
    /// 永久删除当前用户废纸篓中的项目，目录本身保留。
    /// `home` 必须是真实用户主目录；外接卷的 `.Trashes/<uid>` 也会一并处理。
    func emptyTrash(home: URL) -> TrashEmptyingReport
}

/// 直接删除废纸篓内容，行为等同 Finder 的「清空废纸篓」，但只在后台执行、
/// 不启动 Finder。所有目标都必须是可确认的真实目录；符号链接根目录会被拒绝，
/// 删除的只是 `.Trash` 下的子项，链接本身也不会跟随到目标。
struct FileManagerTrashEmptying: TrashEmptying {
    private let fileManager: FileManager
    /// 测试注入；nil 表示读取当前挂载的本地卷。
    private let additionalTrashDirectories: [URL]?

    init(
        fileManager: FileManager = .default,
        additionalTrashDirectories: [URL]? = nil
    ) {
        self.fileManager = fileManager
        self.additionalTrashDirectories = additionalTrashDirectories
    }

    func emptyTrash(home: URL) -> TrashEmptyingReport {
        let trashDirectories: [URL]
        if let additionalTrashDirectories {
            trashDirectories = Self.uniqued(
                [home.appendingPathComponent(".Trash")] + additionalTrashDirectories
            )
        } else {
            let volumeRoots = fileManager.mountedVolumeURLs(
                includingResourceValuesForKeys: [.volumeIsLocalKey, .volumeIsReadOnlyKey],
                options: []
            ) ?? []
            trashDirectories = Self.trashDirectories(home: home, volumeRoots: volumeRoots)
        }

        var report = TrashEmptyingReport()
        for directory in trashDirectories {
            empty(directory, into: &report)
        }
        return report
    }

    /// 首页废纸篓 + 每个本地可写卷上属于当前用户的 `.Trashes`。
    /// 不存在、只读或系统卷上的目录会在执行时安静跳过。
    static func trashDirectories(
        home: URL,
        volumeRoots: [URL],
        userID: uid_t = getuid()
    ) -> [URL] {
        let homeTrash = home.appendingPathComponent(".Trash")
        let volumeTrashes = volumeRoots.compactMap { volume -> URL? in
            let values = try? volume.resourceValues(
                forKeys: [.volumeIsLocalKey, .volumeIsReadOnlyKey]
            )
            if values?.volumeIsLocal == false || values?.volumeIsReadOnly == true {
                return nil
            }
            return volume.appendingPathComponent(".Trashes/\(userID)")
        }
        return uniqued([homeTrash] + volumeTrashes)
    }

    private func empty(_ directory: URL, into report: inout TrashEmptyingReport) {
        let standardized = directory.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: standardized.path, isDirectory: &isDirectory) else {
            return
        }
        guard isDirectory.boolValue else {
            report.failures.append("\(standardized.path)：废纸篓路径不是目录")
            return
        }
        guard let values = try? standardized.resourceValues(
            forKeys: [.isSymbolicLinkKey, .isDirectoryKey]
        ), values.isSymbolicLink != true, values.isDirectory == true else {
            report.failures.append("\(standardized.path)：废纸篓路径不是真实目录，已跳过")
            return
        }

        let children: [URL]
        do {
            children = try fileManager.contentsOfDirectory(
                at: standardized,
                includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey],
                options: []
            )
        } catch {
            report.failures.append("\(standardized.path)：\(error.localizedDescription)")
            return
        }

        for child in children {
            let size = allocatedSize(of: child)
            do {
                try fileManager.removeItem(at: child)
                report.removedCount += 1
                report.removedBytes += size
            } catch {
                report.failures.append("\(child.path)：\(error.localizedDescription)")
            }
        }
    }

    /// 删除前统计大小。符号链接只算链接自身，绝不跟随到目标。
    private func allocatedSize(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey,
            .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey
        ]
        guard let values = try? url.resourceValues(forKeys: keys),
              values.isSymbolicLink != true else {
            return 0
        }
        if values.isRegularFile == true {
            return Self.allocatedBytes(values)
        }
        guard values.isDirectory == true,
              let enumerator = fileManager.enumerator(
                  at: url,
                  includingPropertiesForKeys: Array(keys),
                  options: [],
                  errorHandler: { _, _ in true }
              ) else {
            return 0
        }

        var total: Int64 = 0
        while let child = enumerator.nextObject() as? URL {
            guard let childValues = try? child.resourceValues(forKeys: keys),
                  childValues.isSymbolicLink != true,
                  childValues.isRegularFile == true else { continue }
            total += Self.allocatedBytes(childValues)
        }
        return total
    }

    private static func allocatedBytes(_ values: URLResourceValues) -> Int64 {
        Int64(
            values.totalFileAllocatedSize
                ?? values.fileAllocatedSize
                ?? values.fileSize
                ?? 0
        )
    }

    private static func uniqued(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls
            .map(\.standardizedFileURL)
            .filter { seen.insert($0.path).inserted }
    }
}
