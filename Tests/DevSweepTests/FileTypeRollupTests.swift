import Darwin
import Foundation
import XCTest
@testable import DevSweep

final class FileTypeRollupTests: XCTestCase {
    private let fileManager = FileManager.default

    /// 普通目录自身不计数，否则父目录会和里面的文件重复累计。
    func testRollupDoesNotDoubleCountDirectories() throws {
        let root = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: root) }
        let nested = root.appendingPathComponent("build/Debug")
        try fileManager.createDirectory(at: nested, withIntermediateDirectories: true)
        try write(100_000, to: nested.appendingPathComponent("lib.a"))

        let rollup = FileTypeRollupScanner.scan(root: root)

        XCTAssertEqual(rollup.fileCount, 1)
        XCTAssertEqual(rollup.directoryCount, 2)
        XCTAssertNil(rollup.summaries.first { $0.category == .folder }, "目录不是文件类型，不应进入合计")
        XCTAssertGreaterThanOrEqual(rollup.totalBytes, 100_000)
        XCTAssertLessThan(rollup.totalBytes, 200_000, "目录不能按内容再计一次")
        XCTAssertTrue(rollup.isComplete)
        XCTAssertFalse(rollup.isLowerBound)
    }

    /// 包目录整体算一项，不能被拆成成千上万个「编译产物」。
    func testRollupKeepsPackageDirectoryAsOneEntry() throws {
        let root = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: root) }
        try write(300_000, to: root.appendingPathComponent("Foo.app/Contents/MacOS/Foo"))
        try write(2_000, to: root.appendingPathComponent("Foo.app/Contents/Info.plist"))

        let rollup = FileTypeRollupScanner.scan(root: root)

        XCTAssertEqual(rollup.packageCount, 1)
        let package = try XCTUnwrap(rollup.summaries.first { $0.category == .package })
        XCTAssertEqual(package.itemCount, 1)
        XCTAssertGreaterThanOrEqual(package.allocatedBytes, 300_000)
        XCTAssertNil(rollup.summaries.first { $0.category == .compiled })
        XCTAssertNil(rollup.summaries.first { $0.category == .source })
        XCTAssertEqual(rollup.fileCount, 0, "包内部文件不再单独计数")
    }

    /// 模型包按 AI 模型归类，应用框架按应用包归类，两者都不下降。
    func testRollupSeparatesModelPackageFromAppPackage() throws {
        let root = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: root) }
        try write(50_000, to: root.appendingPathComponent("weights.mlpackage/Data/weights.bin"))
        try fileManager.createDirectory(
            at: root.appendingPathComponent("Bar.framework"),
            withIntermediateDirectories: true
        )

        let rollup = FileTypeRollupScanner.scan(root: root)

        XCTAssertEqual(rollup.packageCount, 2)
        XCTAssertEqual(rollup.summaries.first { $0.category == .aiModel }?.itemCount, 1)
        XCTAssertEqual(rollup.summaries.first { $0.category == .package }?.itemCount, 1)
        XCTAssertEqual(rollup.fileCount, 0)
    }

    func testRollupSkipsSymlinksAndDeduplicatesHardLinks() throws {
        let root = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: root) }
        let original = root.appendingPathComponent("data.bin")
        try write(200_000, to: original)
        try fileManager.linkItem(at: original, to: root.appendingPathComponent("hard.bin"))
        try fileManager.createSymbolicLink(
            at: root.appendingPathComponent("link.bin"),
            withDestinationURL: original
        )

        let rollup = FileTypeRollupScanner.scan(root: root)

        XCTAssertEqual(rollup.symlinkCount, 1)
        XCTAssertEqual(rollup.fileCount, 1, "硬链接只算一份，符号链接不计入文件数")
        XCTAssertGreaterThanOrEqual(rollup.totalBytes, 200_000)
        XCTAssertLessThan(rollup.totalBytes, 300_000, "同一份磁盘块不能按两份计")
        XCTAssertTrue(rollup.isComplete)
    }

    /// 包目录内部文件与外部硬链接必须共用同一份 inode 去重。
    func testRollupDeduplicatesHardLinkBetweenPackageAndOutside() throws {
        let root = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: root) }
        let inside = root.appendingPathComponent("Foo.app/Contents/data.bin")
        try write(300_000, to: inside)
        try fileManager.linkItem(at: inside, to: root.appendingPathComponent("outside.bin"))

        let rollup = FileTypeRollupScanner.scan(root: root)

        XCTAssertEqual(rollup.packageCount, 1)
        XCTAssertGreaterThan(rollup.totalBytes, 250_000)
        XCTAssertLessThan(rollup.totalBytes, 500_000, "同一份磁盘块不能按包内、包外各计一次")
        XCTAssertTrue(rollup.isComplete)
        XCTAssertEqual(rollup.state, .complete)
    }

    /// 取消和跨卷都必须反映在汇总状态里，不能只改提示文字。
    func testRollupStateMatchesCompleteness() {
        let emptyCancelled = FileTypeRollup(
            summaries: [], fileCount: 0, directoryCount: 0, packageCount: 0,
            symlinkCount: 0, crossVolumeCount: 0, unreadableCount: 0,
            scannedEntries: 0, isComplete: false, limitReached: false, duration: 0
        )
        XCTAssertEqual(emptyCancelled.state, .unknown)
        XCTAssertTrue(emptyCancelled.isLowerBound)

        let crossVolume = FileTypeRollup(
            summaries: [FileTypeSummary(category: .source, allocatedBytes: 1_000, itemCount: 1)],
            fileCount: 1, directoryCount: 0, packageCount: 0,
            symlinkCount: 0, crossVolumeCount: 2, unreadableCount: 0,
            scannedEntries: 1, isComplete: false, limitReached: false, duration: 0
        )
        XCTAssertEqual(crossVolume.state, .lowerBound)
        XCTAssertTrue(crossVolume.isLowerBound)
        XCTAssertTrue(crossVolume.note.contains("跨卷"), crossVolume.note)
    }

    func testRollupMarksUnfinishedScanAsLowerBound() throws {
        let root = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: root) }
        for index in 0..<40 {
            try write(10_000, to: root.appendingPathComponent("file-\(index).bin"))
        }

        let full = FileTypeRollupScanner.scan(root: root)
        XCTAssertEqual(full.fileCount, 40)
        XCTAssertTrue(full.isComplete)

        let limited = FileTypeRollupScanner.scan(root: root, entryLimit: 10)
        XCTAssertTrue(limited.limitReached)
        XCTAssertFalse(limited.isComplete)
        XCTAssertTrue(limited.isLowerBound)
        XCTAssertEqual(limited.note, "已达条目上限，实际占用可能更大")
        XCTAssertLessThan(limited.fileCount, full.fileCount)
        XCTAssertLessThan(limited.totalBytes, full.totalBytes)

        let cancelled = FileTypeRollupScanner.scan(root: root, isCancelled: { true })
        XCTAssertFalse(cancelled.isComplete)
        XCTAssertTrue(cancelled.isLowerBound)
        XCTAssertEqual(cancelled.scannedEntries, 0)
        XCTAssertEqual(cancelled.note, "统计已中断，当前为已扫描部分的下限")
    }

    func testRollupReportsUnreadableEntriesAsIncomplete() throws {
        try XCTSkipIf(getuid() == 0, "root 会绕过目录权限，无法复现读取失败")
        let root = try temporaryDirectory()
        var locked: URL?
        defer {
            if let locked { try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
            try? fileManager.removeItem(at: root)
        }

        try write(100_000, to: root.appendingPathComponent("readable.bin"))
        let lockedDirectory = root.appendingPathComponent("locked")
        try fileManager.createDirectory(at: lockedDirectory, withIntermediateDirectories: true)
        locked = lockedDirectory
        try fileManager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: lockedDirectory.path)

        let rollup = FileTypeRollupScanner.scan(root: root)
        XCTAssertGreaterThan(rollup.unreadableCount, 0)
        XCTAssertFalse(rollup.isComplete)
        XCTAssertTrue(rollup.isLowerBound)
        XCTAssertGreaterThan(rollup.totalBytes, 0)
    }

    func testRollupFailsOnMissingRoot() {
        let rollup = FileTypeRollupScanner.scan(
            root: URL(fileURLWithPath: "/private/tmp/DevSweep-rollup-missing-\(UUID().uuidString)")
        )

        XCTAssertTrue(rollup.summaries.isEmpty)
        XCTAssertFalse(rollup.isComplete)
        XCTAssertEqual(rollup.unreadableCount, 1)
    }

    private func write(_ bytes: Int, to url: URL) throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(repeating: 0xA5, count: bytes).write(to: url)
    }

    private func temporaryDirectory() throws -> URL {
        let url = fileManager.temporaryDirectory.appendingPathComponent("DevSweepRollup-\(UUID().uuidString)")
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
