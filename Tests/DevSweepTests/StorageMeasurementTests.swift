import Darwin
import Foundation
import XCTest
@testable import DevSweep

final class StorageMeasurementTests: XCTestCase {
    private let fileManager = FileManager.default

    func testCleanDuOutputIsComplete() throws {
        let result = ProcessResult(
            status: 0,
            stdout: Data("2048\t/tmp/example\n".utf8),
            stderr: Data(),
            timedOut: false
        )

        let measurement = try XCTUnwrap(StorageMeasurementService.interpretSingle(result))
        XCTAssertEqual(measurement.allocatedBytes, 2_097_152)
        XCTAssertEqual(measurement.state, .complete)
        XCTAssertNil(measurement.warning)
    }

    func testPartialDuOutputStaysVisibleButIsMarkedIncomplete() throws {
        let result = ProcessResult(
            status: 1,
            stdout: Data("1024\t/tmp/example\n".utf8),
            stderr: Data("du: /tmp/example/locked: Permission denied\n".utf8),
            timedOut: false
        )

        let measurement = try XCTUnwrap(StorageMeasurementService.interpretSingle(result))
        XCTAssertEqual(measurement.allocatedBytes, 1_048_576)
        XCTAssertNotEqual(measurement.state, .complete)
        XCTAssertEqual(measurement.state, .partial)
        XCTAssertEqual(measurement.warning, "有 1 个条目无法读取，实际占用可能更大")
    }

    func testTimedOutDuIsMarkedIncomplete() throws {
        let result = ProcessResult(
            status: 0,
            stdout: Data("512\t/tmp/example\n".utf8),
            stderr: Data(),
            timedOut: true
        )

        let measurement = try XCTUnwrap(StorageMeasurementService.interpretSingle(result))
        XCTAssertEqual(measurement.allocatedBytes, 524_288)
        XCTAssertEqual(measurement.state, .timedOut)
        XCTAssertEqual(measurement.warning, "统计超时，未完成全部目录")
    }

    func testUnusableDuOutputRequestsFallback() {
        let empty = ProcessResult(status: 1, stdout: Data(), stderr: Data(), timedOut: false)
        XCTAssertNil(StorageMeasurementService.interpretSingle(empty))

        let garbage = ProcessResult(status: 0, stdout: Data("not a size\n".utf8), stderr: Data(), timedOut: false)
        XCTAssertNil(StorageMeasurementService.interpretSingle(garbage))
    }

    func testPermissionDeniedSubtreeIsReportedAsIncomplete() throws {
        try XCTSkipIf(getuid() == 0, "root 会绕过目录权限，无法复现读取失败")
        let root = try temporaryDirectory()
        var locked: URL?
        defer {
            if let locked { try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
            try? fileManager.removeItem(at: root)
        }

        try Data(repeating: 0xA5, count: 1_100_000).write(to: root.appendingPathComponent("readable.bin"))
        let lockedDirectory = root.appendingPathComponent("locked")
        try fileManager.createDirectory(at: lockedDirectory, withIntermediateDirectories: true)
        try Data(repeating: 0xA5, count: 2_100_000).write(to: lockedDirectory.appendingPathComponent("hidden.bin"))
        locked = lockedDirectory
        try fileManager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: lockedDirectory.path)

        let measurement = StorageMeasurementService.measure(root)
        XCTAssertGreaterThan(measurement.allocatedBytes, 0)
        XCTAssertNotEqual(measurement.state, .complete)
        XCTAssertNotNil(measurement.warning)
    }

    func testBatchMeasurementMapsSizesByPathWhenADirectoryDisappears() throws {
        let root = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: root) }

        let small = root.appendingPathComponent("small")
        let large = root.appendingPathComponent("large")
        try fileManager.createDirectory(at: small, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: large, withIntermediateDirectories: true)
        try Data(repeating: 0xA5, count: 1_100_000).write(to: small.appendingPathComponent("a.bin"))
        try Data(repeating: 0xA5, count: 4_200_000).write(to: large.appendingPathComponent("b.bin"))
        let missing = root.appendingPathComponent("missing")

        let measured = StorageMeasurementService.measure([small, missing, large])
        let smallSize = try XCTUnwrap(measured[small.standardizedFileURL.path])
        let largeSize = try XCTUnwrap(measured[large.standardizedFileURL.path])
        let missingMeasurement = try XCTUnwrap(measured[missing.standardizedFileURL.path])

        XCTAssertLessThan(abs(smallSize.allocatedBytes - 1_101_824), 64 * 1024)
        XCTAssertLessThan(abs(largeSize.allocatedBytes - 4_202_496), 64 * 1024)
        XCTAssertGreaterThan(largeSize.allocatedBytes, smallSize.allocatedBytes)
        XCTAssertEqual(missingMeasurement.state, .failed)
        XCTAssertEqual(missingMeasurement.failureReason, "路径不存在")
    }

    /// 一次批量 du 里只有一个目录出错时，不能把同批次其他目录一起降级。
    func testBatchAttributesErrorsToTheirOwnDirectory() throws {
        let result = ProcessResult(
            status: 1,
            stdout: Data("1024\t/tmp/a\n2048\t/tmp/b\n".utf8),
            stderr: Data("du: /tmp/a/sub/locked: Permission denied\n".utf8),
            timedOut: false
        )

        let measurements = StorageMeasurementService.interpretBatch(result, paths: ["/tmp/a", "/tmp/b"])
        let first = try XCTUnwrap(measurements["/tmp/a"])
        let second = try XCTUnwrap(measurements["/tmp/b"])
        XCTAssertEqual(first.state, .partial)
        XCTAssertEqual(first.skippedCount, 1)
        XCTAssertEqual(second.state, .complete)
        XCTAssertNil(second.warning)
        XCTAssertEqual(second.allocatedBytes, 2_097_152)
    }

    func testBatchStaysConservativeWhenErrorCannotBeAttributed() {
        let result = ProcessResult(
            status: 1,
            stdout: Data("1024\t/tmp/a\n2048\t/tmp/b\n".utf8),
            stderr: Data("du: /Volumes/other/broken: Input/output error\n".utf8),
            timedOut: false
        )

        let measurements = StorageMeasurementService.interpretBatch(result, paths: ["/tmp/a", "/tmp/b"])
        XCTAssertEqual(measurements.count, 2)
        for measurement in measurements.values {
            XCTAssertEqual(measurement.state, .partial)
            XCTAssertEqual(measurement.failureReason, "未能确认统计覆盖全部条目，实际占用可能更大")
        }
    }

    func testBatchMarksEveryPendingDirectoryWhenDuTimesOut() {
        let result = ProcessResult(
            status: 0,
            stdout: Data("1024\t/tmp/a\n".utf8),
            stderr: Data(),
            timedOut: true
        )

        let measurements = StorageMeasurementService.interpretBatch(result, paths: ["/tmp/a", "/tmp/b"])
        XCTAssertEqual(measurements["/tmp/a"]?.state, .timedOut)
        XCTAssertEqual(measurements["/tmp/a"]?.allocatedBytes, 1_048_576)
        XCTAssertEqual(measurements["/tmp/b"]?.state, .timedOut)
        XCTAssertEqual(measurements["/tmp/b"]?.allocatedBytes, 0)
    }

    /// 读不到 `fileAllocatedSize` 时退回 `lstat` 的块数，不能静默记成 0 B。
    func testFileMeasurementFallsBackToBlockCount() throws {
        let root = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: root) }
        let file = root.appendingPathComponent("data.bin")
        try Data(repeating: 0xA5, count: 300_000).write(to: file)

        let measurement = StorageMeasurementService.measureFile(file, allocatedSize: nil)
        XCTAssertEqual(measurement.state, .complete)
        XCTAssertGreaterThan(measurement.allocatedBytes, 250_000)
        XCTAssertEqual(measurement.allocatedBytes % 512, 0)
    }

    /// 0 B 且测量完整是有效结果，不能当成统计失败。
    func testFileMeasurementKeepsZeroByteFileAsComplete() throws {
        let root = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: root) }
        let file = root.appendingPathComponent("empty.bin")
        try Data().write(to: file)

        let explicit = StorageMeasurementService.measureFile(file, allocatedSize: 0)
        XCTAssertEqual(explicit.state, .complete)
        XCTAssertEqual(explicit.allocatedBytes, 0)

        let measured = StorageMeasurementService.measure(file)
        XCTAssertEqual(measured.state, .complete)
        XCTAssertEqual(measured.allocatedBytes, 0)
    }

    /// 稀疏文件只按实际分配的磁盘块计数，逻辑大小不参与图表面积。
    func testFileMeasurementReportsAllocatedNotLogicalSizeForSparseFile() throws {
        let root = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: root) }
        let file = root.appendingPathComponent("sparse.bin")
        fileManager.createFile(atPath: file.path, contents: Data([0x01]))
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seek(toOffset: 200_000_000)
        try handle.write(contentsOf: Data([0x02]))

        let measurement = StorageMeasurementService.measureFile(file, allocatedSize: nil)
        XCTAssertLessThan(measurement.allocatedBytes, 1_000_000, "稀疏空洞不应计入磁盘占用")
        XCTAssertGreaterThan(measurement.allocatedBytes, 0)
    }

    func testFileMeasurementReportsFailureWhenNoSizeIsAvailable() {
        let missing = URL(fileURLWithPath: "/tmp/DevSweep-definitely-missing-\(UUID().uuidString)")

        let measurement = StorageMeasurementService.measureFile(missing, allocatedSize: nil)
        XCTAssertEqual(measurement.state, .failed)
        XCTAssertEqual(measurement.failureReason, "无法读取文件占用信息")
        XCTAssertEqual(measurement.warning, "无法读取文件占用信息")
    }

    func testEnumerationFallbackDeduplicatesHardLinks() throws {
        let root = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: root) }

        let original = root.appendingPathComponent("original.bin")
        try Data(repeating: 0xA5, count: 2_100_000).write(to: original)
        try fileManager.linkItem(at: original, to: root.appendingPathComponent("hardlink.bin"))

        let measurement = StorageMeasurementService.measureByEnumeration(root)
        XCTAssertEqual(measurement.state, .complete)
        XCTAssertLessThan(measurement.allocatedBytes, 3_000_000, "硬链接不能按两份文件重复累加")
        XCTAssertGreaterThan(measurement.allocatedBytes, 2_000_000)
    }

    func testEnumerationFallbackCountsUnreadableEntries() throws {
        try XCTSkipIf(getuid() == 0, "root 会绕过目录权限，无法复现读取失败")
        let root = try temporaryDirectory()
        var locked: URL?
        defer {
            if let locked { try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
            try? fileManager.removeItem(at: root)
        }

        try Data(repeating: 0xA5, count: 1_100_000).write(to: root.appendingPathComponent("readable.bin"))
        let lockedDirectory = root.appendingPathComponent("locked")
        try fileManager.createDirectory(at: lockedDirectory, withIntermediateDirectories: true)
        locked = lockedDirectory
        try fileManager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: lockedDirectory.path)

        let measurement = StorageMeasurementService.measureByEnumeration(root)
        XCTAssertNotEqual(measurement.state, .complete)
        XCTAssertEqual(measurement.skippedCount, 1)
        XCTAssertGreaterThan(measurement.allocatedBytes, 0)
    }

    func testScanReportsIncompleteMeasurementsOnItems() throws {
        try XCTSkipIf(getuid() == 0, "root 会绕过目录权限，无法复现读取失败")
        let home = try temporaryDirectory()
        var locked: URL?
        defer {
            if let locked { try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
            try? fileManager.removeItem(at: home)
        }

        let cache = home.appendingPathComponent("Library/Caches/com.apple.dt.Xcode")
        try fileManager.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data(repeating: 0xA5, count: 1_100_000).write(to: cache.appendingPathComponent("readable.bin"))
        let lockedDirectory = cache.appendingPathComponent("locked")
        try fileManager.createDirectory(at: lockedDirectory, withIntermediateDirectories: true)
        try Data(repeating: 0xA5, count: 2_100_000).write(to: lockedDirectory.appendingPathComponent("hidden.bin"))
        locked = lockedDirectory
        try fileManager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: lockedDirectory.path)

        let report = CacheScanner.scan(
            projectRoots: [],
            deepScan: false,
            home: home,
            includeSystemCaches: false,
            progress: { _ in },
            environment: [:]
        )

        let item = try XCTUnwrap(report.items.first { $0.path == cache.standardizedFileURL })
        XCTAssertNotNil(item.sizeWarning)
        XCTAssertTrue(item.sizeText.hasPrefix("≥ "))
        XCTAssertEqual(report.incompleteMeasurements, 1)
    }

    func testEmptyDirectoryIsCompleteAndDistinctFromFailedMeasurement() throws {
        let root = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: root) }

        let empty = StorageMeasurementService.measure(root)
        XCTAssertEqual(empty.allocatedBytes, 0)
        XCTAssertEqual(empty.state, .complete)

        let missing = StorageMeasurementService.measure(root.appendingPathComponent("missing"))
        XCTAssertEqual(missing.allocatedBytes, 0)
        XCTAssertEqual(missing.state, .failed)
        XCTAssertEqual(missing.failureReason, "路径不存在")
    }

    private func temporaryDirectory() throws -> URL {
        let url = fileManager.temporaryDirectory.appendingPathComponent("DevSweepMeasure-\(UUID().uuidString)")
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
