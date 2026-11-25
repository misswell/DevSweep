import Darwin
import Foundation
import XCTest
@testable import DevSweep

final class TrashEmptyingTests: XCTestCase {
    private let fileManager = FileManager.default

    func testEmptiesTrashWithoutFollowingSymlinkTargets() throws {
        let home = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: home) }

        let trash = home.appendingPathComponent(".Trash")
        try fileManager.createDirectory(at: trash, withIntermediateDirectories: true)
        try Data("abc".utf8).write(to: trash.appendingPathComponent("file.txt"))
        let folder = trash.appendingPathComponent("folder")
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("12345".utf8).write(to: folder.appendingPathComponent("nested.txt"))

        let precious = home.appendingPathComponent("Documents/precious")
        try fileManager.createDirectory(at: precious, withIntermediateDirectories: true)
        try Data("keep me".utf8).write(to: precious.appendingPathComponent("keep.txt"))
        try fileManager.createSymbolicLink(
            at: trash.appendingPathComponent("link-to-documents"),
            withDestinationURL: precious
        )

        let report = FileManagerTrashEmptying(additionalTrashDirectories: [])
            .emptyTrash(home: home)

        XCTAssertTrue(report.failures.isEmpty, "\(report.failures)")
        XCTAssertEqual(report.removedCount, 3, "文件、目录和链接本身都应删除")
        XCTAssertGreaterThan(report.removedBytes, 0)
        XCTAssertTrue(fileManager.fileExists(atPath: trash.path), "废纸篓目录本身必须保留")
        XCTAssertTrue(
            try fileManager.contentsOfDirectory(atPath: trash.path).isEmpty,
            "废纸篓应已清空"
        )
        XCTAssertTrue(
            fileManager.fileExists(atPath: precious.appendingPathComponent("keep.txt").path),
            "符号链接目标绝不能被删除"
        )
    }

    func testRefusesSymlinkedTrashRoot() throws {
        let home = try temporaryDirectory()
        let outside = try temporaryDirectory()
        defer {
            try? fileManager.removeItem(at: home)
            try? fileManager.removeItem(at: outside)
        }

        try fileManager.createDirectory(
            at: outside.appendingPathComponent("real-trash"),
            withIntermediateDirectories: true
        )
        let file = outside.appendingPathComponent("real-trash/keep.txt")
        try Data("keep".utf8).write(to: file)
        try fileManager.createSymbolicLink(
            at: home.appendingPathComponent(".Trash"),
            withDestinationURL: outside.appendingPathComponent("real-trash")
        )

        let report = FileManagerTrashEmptying(additionalTrashDirectories: [])
            .emptyTrash(home: home)

        XCTAssertEqual(report.removedCount, 0)
        XCTAssertEqual(report.failures.count, 1)
        XCTAssertTrue(fileManager.fileExists(atPath: file.path))
    }

    func testMissingTrashIsANoOp() throws {
        let home = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: home) }

        let report = FileManagerTrashEmptying(additionalTrashDirectories: [])
            .emptyTrash(home: home)

        XCTAssertEqual(report, TrashEmptyingReport())
    }

    func testAdditionalVolumeTrashIsEmptied() throws {
        let home = try temporaryDirectory()
        let volume = try temporaryDirectory()
        defer {
            try? fileManager.removeItem(at: home)
            try? fileManager.removeItem(at: volume)
        }

        let volumeTrash = volume.appendingPathComponent(".Trashes/\(getuid())")
        try fileManager.createDirectory(at: volumeTrash, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: volumeTrash.appendingPathComponent("old.bin"))

        let report = FileManagerTrashEmptying(additionalTrashDirectories: [volumeTrash])
            .emptyTrash(home: home)

        XCTAssertTrue(report.failures.isEmpty, "\(report.failures)")
        XCTAssertEqual(report.removedCount, 1)
        XCTAssertTrue(
            try fileManager.contentsOfDirectory(atPath: volumeTrash.path).isEmpty
        )
    }

    func testLockedItemFailsWithoutBlockingOtherDeletions() throws {
        let home = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: home) }

        let trash = home.appendingPathComponent(".Trash")
        try fileManager.createDirectory(at: trash, withIntermediateDirectories: true)
        try Data("ok".utf8).write(to: trash.appendingPathComponent("removable.txt"))

        let locked = trash.appendingPathComponent("locked")
        try fileManager.createDirectory(at: locked, withIntermediateDirectories: true)
        try Data("inside".utf8).write(to: locked.appendingPathComponent("file.txt"))
        try fileManager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
        defer {
            try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path)
        }

        let report = FileManagerTrashEmptying(additionalTrashDirectories: [])
            .emptyTrash(home: home)

        XCTAssertEqual(report.removedCount, 1)
        XCTAssertEqual(report.failures.count, 1)
        XCTAssertFalse(fileManager.fileExists(atPath: trash.appendingPathComponent("removable.txt").path))
        XCTAssertTrue(fileManager.fileExists(atPath: locked.path))
    }

    func testTrashDirectoriesIncludeHomeAndVolumeTrash() throws {
        let home = try temporaryDirectory()
        let volume = try temporaryDirectory()
        defer {
            try? fileManager.removeItem(at: home)
            try? fileManager.removeItem(at: volume)
        }

        let directories = FileManagerTrashEmptying.trashDirectories(
            home: home,
            volumeRoots: [volume],
            userID: 501
        )

        XCTAssertEqual(
            directories.map(\.path),
            [
                home.appendingPathComponent(".Trash").path,
                volume.appendingPathComponent(".Trashes/501").path,
            ]
        )
    }

    private func temporaryDirectory() throws -> URL {
        let url = fileManager.temporaryDirectory
            .appendingPathComponent("DevSweepTrashEmptying-\(UUID().uuidString)")
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
