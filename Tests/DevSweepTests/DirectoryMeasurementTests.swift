import Darwin
import Foundation
import XCTest
@testable import DevSweep

final class DirectoryMeasurementTests: XCTestCase {
    private let fileManager = FileManager.default

    func testCleanDuOutputIsComplete() throws {
        let result = ProcessResult(
            status: 0,
            stdout: Data("2048\t/tmp/example\n".utf8),
            stderr: Data(),
            timedOut: false
        )

        let measurement = try XCTUnwrap(DirectoryMeasurementService.interpretSingle(result))
        XCTAssertEqual(measurement.allocatedBytes, 2_097_152)
        XCTAssertTrue(measurement.isComplete)
        XCTAssertNil(measurement.warning)
    }

    func testPartialDuOutputStaysVisibleButIsMarkedIncomplete() throws {
        let result = ProcessResult(
            status: 1,
            stdout: Data("1024\t/tmp/example\n".utf8),
            stderr: Data("du: /tmp/example/locked: Permission denied\n".utf8),
            timedOut: false
        )

        let measurement = try XCTUnwrap(DirectoryMeasurementService.interpretSingle(result))
        XCTAssertEqual(measurement.allocatedBytes, 1_048_576)
        XCTAssertFalse(measurement.isComplete)
        XCTAssertEqual(measurement.warning, "有 1 个条目无法读取，实际占用可能更大")
    }

    func testTimedOutDuIsMarkedIncomplete() throws {
        let result = ProcessResult(
            status: 0,
            stdout: Data("512\t/tmp/example\n".utf8),
            stderr: Data(),
            timedOut: true
        )

        let measurement = try XCTUnwrap(DirectoryMeasurementService.interpretSingle(result))
        XCTAssertEqual(measurement.allocatedBytes, 524_288)
        XCTAssertFalse(measurement.isComplete)
        XCTAssertEqual(measurement.warning, "统计超时，未完成全部目录")
    }

    func testUnusableDuOutputRequestsFallback() {
        let empty = ProcessResult(status: 1, stdout: Data(), stderr: Data(), timedOut: false)
        XCTAssertNil(DirectoryMeasurementService.interpretSingle(empty))

        let garbage = ProcessResult(status: 0, stdout: Data("not a size\n".utf8), stderr: Data(), timedOut: false)
        XCTAssertNil(DirectoryMeasurementService.interpretSingle(garbage))
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

        let measurement = DirectoryMeasurementService.measure(root)
        XCTAssertGreaterThan(measurement.allocatedBytes, 0)
        XCTAssertFalse(measurement.isComplete)
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

        let measured = DirectoryMeasurementService.measure([small, missing, large])
        let smallSize = try XCTUnwrap(measured[small.standardizedFileURL.path])
        let largeSize = try XCTUnwrap(measured[large.standardizedFileURL.path])
        let missingMeasurement = try XCTUnwrap(measured[missing.standardizedFileURL.path])

        XCTAssertLessThan(abs(smallSize.allocatedBytes - 1_101_824), 64 * 1024)
        XCTAssertLessThan(abs(largeSize.allocatedBytes - 4_202_496), 64 * 1024)
        XCTAssertGreaterThan(largeSize.allocatedBytes, smallSize.allocatedBytes)
        XCTAssertFalse(missingMeasurement.isComplete)
        XCTAssertEqual(missingMeasurement.failureReason, "路径不存在")
    }

    func testEnumerationFallbackDeduplicatesHardLinks() throws {
        let root = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: root) }

        let original = root.appendingPathComponent("original.bin")
        try Data(repeating: 0xA5, count: 2_100_000).write(to: original)
        try fileManager.linkItem(at: original, to: root.appendingPathComponent("hardlink.bin"))

        let measurement = DirectoryMeasurementService.measureByEnumeration(root)
        XCTAssertTrue(measurement.isComplete)
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

        let measurement = DirectoryMeasurementService.measureByEnumeration(root)
        XCTAssertFalse(measurement.isComplete)
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

    private func temporaryDirectory() throws -> URL {
        let url = fileManager.temporaryDirectory.appendingPathComponent("DevSweepMeasure-\(UUID().uuidString)")
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
