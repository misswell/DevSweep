import Foundation
import XCTest
@testable import DevSweep

final class DeletionSafetyTests: XCTestCase {
    private let fileManager = FileManager.default

    func testDangerousRootsAreRejected() throws {
        let temporaryHome = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: temporaryHome) }

        let paths = [
            URL(fileURLWithPath: "/"),
            temporaryHome,
            temporaryHome.appendingPathComponent("Library"),
            temporaryHome.appendingPathComponent("Documents")
        ]
        try fileManager.createDirectory(at: temporaryHome.appendingPathComponent("Library"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: temporaryHome.appendingPathComponent("Documents"), withIntermediateDirectories: true)

        for path in paths {
            let item = CacheItem(category: "测试", name: path.path, path: path, size: 1)
            let context = DeletionContext(
                whitelistedPaths: [],
                projectRoots: [],
                allowedPaths: [path],
                protectedPaths: [path]
            )
            XCTAssertThrowsError(try DeletionValidator.validate(item: item, context: context)) { error in
                XCTAssertEqual(error as? DeletionValidationError, .protectedPath, path.path)
            }
        }
    }

    func testDirectSymlinkIsRejected() throws {
        let root = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: root) }

        let important = root.appendingPathComponent("important")
        let cache = root.appendingPathComponent("cache")
        try fileManager.createDirectory(at: important, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(at: cache, withDestinationURL: important)

        let item = CacheItem(category: "测试", name: "cache", path: cache, size: 1)
        let context = DeletionContext(whitelistedPaths: [], projectRoots: [], allowedRoots: [root])

        XCTAssertThrowsError(try DeletionValidator.validate(item: item, context: context)) { error in
            XCTAssertEqual(error as? DeletionValidationError, .symbolicLink)
        }
    }

    func testAncestorSymlinkCannotEscapeAuthorizedScope() throws {
        let root = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: root) }

        let project = root.appendingPathComponent("project")
        let important = root.appendingPathComponent("important")
        let link = project.appendingPathComponent("link")
        let cache = link.appendingPathComponent("cache")
        try fileManager.createDirectory(at: project, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: important.appendingPathComponent("cache"), withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(at: link, withDestinationURL: important)

        let item = CacheItem(category: "测试", name: "cache", path: cache, size: 1)
        let context = DeletionContext(whitelistedPaths: [], projectRoots: [project])

        XCTAssertThrowsError(try DeletionValidator.validate(item: item, context: context)) { error in
            XCTAssertEqual(error as? DeletionValidationError, .symbolicLink)
        }
    }

    func testWhitelistIsRecheckedAtCleanupTime() throws {
        let root = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: root) }
        let cache = root.appendingPathComponent("cache")
        try createDirectory(at: cache)

        let item = CacheItem(category: "测试", name: "cache", path: cache, size: 1)
        let context = DeletionContext(
            whitelistedPaths: [cache],
            projectRoots: [root],
            allowedPaths: [cache]
        )
        let report = CacheCleaner.clean([item], context: context)

        XCTAssertTrue(report.removed.isEmpty)
        XCTAssertEqual(report.failures.first?.1, DeletionValidationError.whitelisted.localizedDescription)
        XCTAssertTrue(fileManager.fileExists(atPath: cache.path))
    }

    func testPathReplacementWithSymlinkIsRejected() throws {
        let root = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: root) }
        let cache = root.appendingPathComponent("cache")
        let important = root.appendingPathComponent("important")
        try createDirectory(at: cache)
        try createDirectory(at: important)

        let item = CacheItem(category: "测试", name: "cache", path: cache, size: 1)
        try fileManager.removeItem(at: cache)
        try fileManager.createSymbolicLink(at: cache, withDestinationURL: important)

        let context = DeletionContext(whitelistedPaths: [], projectRoots: [root])
        let report = CacheCleaner.clean([item], context: context)

        XCTAssertTrue(report.removed.isEmpty)
        XCTAssertEqual(report.failures.first?.1, DeletionValidationError.symbolicLink.localizedDescription)
        XCTAssertTrue(fileManager.fileExists(atPath: cache.path))
    }

    func testPathReplacementWithAnotherDirectoryIsRejectedByIdentity() throws {
        let root = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: root) }
        let cache = root.appendingPathComponent("cache")
        try createDirectory(at: cache)

        let item = CacheItem(category: "测试", name: "cache", path: cache, size: 1)
        try fileManager.removeItem(at: cache)
        try createDirectory(at: cache)

        let context = DeletionContext(whitelistedPaths: [], projectRoots: [root])
        let report = CacheCleaner.clean([item], context: context)

        XCTAssertTrue(report.removed.isEmpty)
        XCTAssertEqual(report.failures.first?.1, DeletionValidationError.pathChanged.localizedDescription)
        XCTAssertTrue(fileManager.fileExists(atPath: cache.path))
    }

    func testAuthorizedTargetKeepsItsScannedIdentity() throws {
        let root = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: root) }
        let cache = root.appendingPathComponent("cache")
        try createDirectory(at: cache)

        let item = CacheItem(category: "测试", name: "cache", path: cache, size: 1)
        let context = DeletionContext(whitelistedPaths: [], projectRoots: [root])

        XCTAssertNoThrow(try DeletionValidator.validate(item: item, context: context))
    }

    private func temporaryDirectory() throws -> URL {
        let url = fileManager.temporaryDirectory.appendingPathComponent("DevSweepDeletionTests-\(UUID().uuidString)")
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func createDirectory(at url: URL) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        try Data(repeating: 0xA5, count: 1_100_000).write(to: url.appendingPathComponent("cache.bin"))
    }
}
