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
