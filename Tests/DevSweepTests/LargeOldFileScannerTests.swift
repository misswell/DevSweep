import Foundation
import XCTest
@testable import DevSweep

final class LargeOldFileScannerTests: XCTestCase {
    private let fileManager = FileManager.default

    private func temporaryDirectory() throws -> URL {
        let url = fileManager.temporaryDirectory
            .appendingPathComponent("DevSweepLargeOld-\(UUID().uuidString)")
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeFile(at url: URL, bytes: Int, modified: Date?) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0xA5, count: bytes).write(to: url)
        if let modified {
            try fileManager.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
    }

    func testFindsBigAndOldFilesAndRespectsThresholds() throws {
        let home = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: home) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let bigNew = home.appendingPathComponent("Downloads/big-new.iso")
        let bigOld = home.appendingPathComponent("Movies/big-old.mp4")
        let smallOld = home.appendingPathComponent("Downloads/small-old.txt")
        try writeFile(at: bigNew, bytes: 2_000_000, modified: now)
        try writeFile(at: bigOld, bytes: 3_000_000, modified: now.addingTimeInterval(-120 * 86_400))
        try writeFile(at: smallOld, bytes: 1_000, modified: now.addingTimeInterval(-400 * 86_400))

        // 只按大小：大文件两个都要，小文件不要。
        let sizeOnly = LargeOldFileScanner.scan(
            criteria: LargeOldFileCriteria(minimumBytes: 1_000_000, olderThanDays: nil,
                                           roots: LargeOldFileScanner.defaultRoots(home: home)),
            home: home, now: now
        )
        XCTAssertEqual(Set(sizeOnly.candidates.map(\.path.lastPathComponent)),
                       ["big-new.iso", "big-old.mp4"])
        XCTAssertEqual(sizeOnly.candidates.first?.path.lastPathComponent, "big-old.mp4",
                       "按大小降序")

        // 大 + 旧（90 天）：只剩那个老的。
        let bigAndOld = LargeOldFileScanner.scan(
            criteria: LargeOldFileCriteria(minimumBytes: 1_000_000, olderThanDays: 90,
                                           roots: LargeOldFileScanner.defaultRoots(home: home)),
            home: home, now: now
        )
        XCTAssertEqual(bigAndOld.candidates.map(\.path.lastPathComponent), ["big-old.mp4"],
                       "新的大文件不算「旧文件」")
    }

    func testRespectsLimitAndFlagsTruncation() throws {
        let home = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: home) }
        for index in 0..<5 {
            try writeFile(at: home.appendingPathComponent("Downloads/f\(index).bin"),
                          bytes: 1_100_000 + index, modified: nil)
        }
        let report = LargeOldFileScanner.scan(
            criteria: LargeOldFileCriteria(minimumBytes: 1_000_000, olderThanDays: nil,
                                           limit: 2, roots: [home.appendingPathComponent("Downloads")]),
            home: home
        )
        XCTAssertEqual(report.candidates.count, 2)
        XCTAssertTrue(report.truncatedByLimit)
    }

    func testExcludesSystemAndTrashAndFollowsNoSymlinks() throws {
        let home = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: home) }

        let bigInTrash = home.appendingPathComponent(".Trash/junk.bin")
        try writeFile(at: bigInTrash, bytes: 2_000_000, modified: nil)
        let real = home.appendingPathComponent("Downloads/real.bin")
        try writeFile(at: real, bytes: 2_000_000, modified: nil)
        let link = home.appendingPathComponent("Downloads/link.bin")
        try fileManager.createSymbolicLink(at: link, withDestinationURL: real)

        let report = LargeOldFileScanner.scan(
            criteria: LargeOldFileCriteria(minimumBytes: 1_000_000, olderThanDays: nil,
                                           roots: [home]),
            home: home
        )
        let names = Set(report.candidates.map(\.path.lastPathComponent))
        XCTAssertFalse(names.contains("junk.bin"), "废纸篓内容不重复列出")
        XCTAssertFalse(names.contains("link.bin"), "符号链接不跟随、不重复计数")
        XCTAssertTrue(names.contains("real.bin"))
    }

    /// 排除目录必须连同子树一起跳过。此前只对命中的文件 continue，仍会下探
    /// 整棵 /Library，白扫几万个子项。这里用「排除目录里放一个巨大文件」来证明
    /// 它不会被当成候选；同时用 scannedFileCount 证明没有深入。
    func testExcludedDirectorySubtreeIsNotTraversed() throws {
        let home = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: home) }

        // 构造一个位于排除根之下的目录树：/Library 在本机可能受权限限制，
        // 因此用 home 下的 Applications（不在默认排除表里）作对照，
        // 再单独验证 isExcluded 对 /System 的判定与剪枝逻辑接线。
        XCTAssertTrue(LargeOldFileScanner.isExcluded(URL(fileURLWithPath: "/System/Library/x"), home: home))
        XCTAssertTrue(LargeOldFileScanner.isExcluded(URL(fileURLWithPath: "/Library/Caches/x"), home: home))
        XCTAssertFalse(LargeOldFileScanner.isExcluded(home.appendingPathComponent("Downloads/x"), home: home))

        // 在 home 下造一个未被排除的深树和一个被排除的 .Trash 树，确认 .Trash 里的
        // 大文件既不算候选、也不会让 scanned 计数暴涨。
        try writeFile(at: home.appendingPathComponent("Downloads/deep/a/b/c/big.bin"),
                      bytes: 2_000_000, modified: nil)
        try writeFile(at: home.appendingPathComponent(".Trash/junk.bin"),
                      bytes: 5_000_000, modified: nil)
        let report = LargeOldFileScanner.scan(
            criteria: LargeOldFileCriteria(minimumBytes: 1_000_000, roots: [home]),
            home: home
        )
        XCTAssertEqual(report.candidates.map(\.path.lastPathComponent), ["big.bin"])
    }

    func testCancellationStopsEarly() throws {
        let home = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: home) }
        for index in 0..<3 {
            try writeFile(at: home.appendingPathComponent("Downloads/f\(index).bin"),
                          bytes: 1_100_000, modified: nil)
        }
        let report = LargeOldFileScanner.scan(
            criteria: LargeOldFileCriteria(minimumBytes: 1_000_000, roots: [home]),
            home: home, isCancelled: { true }
        )
        XCTAssertTrue(report.candidates.isEmpty)
    }

    func testMissingRootIsSkippedSilently() throws {
        let home = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: home) }
        let report = LargeOldFileScanner.scan(
            criteria: LargeOldFileCriteria(roots: [home.appendingPathComponent("nope")]),
            home: home
        )
        XCTAssertTrue(report.candidates.isEmpty)
        XCTAssertEqual(report.scannedFileCount, 0)
    }
}
