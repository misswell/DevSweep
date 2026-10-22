import Darwin
import Foundation
import XCTest
@testable import DevSweep

final class UnknownStorageScannerTests: XCTestCase {
    private let fileManager = FileManager.default

    func testHiddenDirectoriesAreDiscoveredAndSortingUsesAllocatedSize() throws {
        let root = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: root) }

        try makeDirectory(root.appendingPathComponent(".hidden-cache"))
        try writeFile(root.appendingPathComponent(".hidden-cache/payload.bin"), megabytes: 2)
        try makeDirectory(root.appendingPathComponent("visible"))
        try writeFile(root.appendingPathComponent("visible/payload.bin"), megabytes: 2)
        try makeDirectory(root.appendingPathComponent("tiny"))
        try writeFile(root.appendingPathComponent("tiny/note.txt"), bytes: 16)
        try writeFile(root.appendingPathComponent("archive.bin"), megabytes: 2)

        let report = UnknownStorageScanner.scan(
            directory: root,
            thresholdBytes: 1_048_576,
            knownCacheLocations: []
        )

        let names = Set(report.nodes.map(\.name))
        XCTAssertTrue(names.contains(".hidden-cache"))
        XCTAssertTrue(names.contains("visible"))
        XCTAssertTrue(names.contains("archive.bin"))
        XCTAssertFalse(names.contains("tiny"))
        XCTAssertEqual(report.hiddenCount, 1)
        XCTAssertGreaterThanOrEqual(report.filteredCount, 1)

        let hidden = try XCTUnwrap(report.nodes.first { $0.name == ".hidden-cache" })
        XCTAssertTrue(hidden.isHidden)
        XCTAssertEqual(hidden.classification, .unknown)
        XCTAssertEqual(hidden.confidence, .unknown)
        XCTAssertFalse(hidden.evidence.isEmpty)

        let archive = try XCTUnwrap(report.nodes.first { $0.name == "archive.bin" })
        XCTAssertFalse(archive.isDirectory)
        XCTAssertGreaterThanOrEqual(archive.measurement.allocatedBytes, 1_048_576)

        let sizes = report.nodes.map(\.measurement.allocatedBytes)
        XCTAssertEqual(sizes, sizes.sorted(by: >))
    }

    func testSymbolicLinkIsSkippedInsteadOfFollowingOutsideRoot() throws {
        let root = try makeTemporaryDirectory()
        let outside = try makeTemporaryDirectory()
        defer {
            try? fileManager.removeItem(at: root)
            try? fileManager.removeItem(at: outside)
        }

        try writeFile(outside.appendingPathComponent("shared.bin"), megabytes: 2)
        try fileManager.createSymbolicLink(
            at: root.appendingPathComponent("escape"),
            withDestinationURL: outside
        )

        let report = UnknownStorageScanner.scan(
            directory: root,
            thresholdBytes: 0,
            knownCacheLocations: []
        )

        XCTAssertFalse(report.nodes.contains { $0.name == "escape" })
        XCTAssertEqual(report.symlinkCount, 1)
        XCTAssertTrue(report.issues.contains { $0.kind == .skipped && $0.reason.contains("符号链接") })
        XCTAssertTrue(fileManager.fileExists(atPath: outside.appendingPathComponent("shared.bin").path))
    }

    func testKnownCacheAndGeneratedArtifactUseContentEvidence() throws {
        let root = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: root) }

        let knownCache = root.appendingPathComponent("custom-cache")
        try makeDirectory(knownCache)
        try writeFile(knownCache.appendingPathComponent("blob.bin"), megabytes: 2)

        let nodeModules = root.appendingPathComponent("node_modules")
        try makeDirectory(nodeModules)
        try writeFile(nodeModules.appendingPathComponent("package.bin"), megabytes: 2)

        let knownLocation = KnownCacheLocation(
            url: knownCache,
            category: "测试工具",
            name: "测试缓存",
            risk: .safe,
            note: "测试用缓存规则"
        )

        let report = UnknownStorageScanner.scan(
            directory: root,
            thresholdBytes: 0,
            knownCacheLocations: [knownLocation]
        )

        let cacheNode = try XCTUnwrap(report.nodes.first { $0.name == "custom-cache" })
        XCTAssertEqual(cacheNode.classification, .knownCache)
        XCTAssertEqual(cacheNode.confidence, .verified)
        XCTAssertTrue(cacheNode.evidence.contains { $0.contains("测试缓存") })

        let artifactNode = try XCTUnwrap(report.nodes.first { $0.name == "node_modules" })
        XCTAssertEqual(artifactNode.classification, .generatedArtifact)
        XCTAssertEqual(artifactNode.confidence, .inferred)
        XCTAssertTrue(artifactNode.evidence.contains { $0.contains("Node.js") })
    }

    func testHuggingFaceRepositoryAndPythonEnvironmentAreIdentified() throws {
        let root = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: root) }

        let modelRepository = root.appendingPathComponent("models--org--model")
        try makeDirectory(modelRepository.appendingPathComponent("blobs"))
        try makeDirectory(modelRepository.appendingPathComponent("snapshots"))
        try writeFile(modelRepository.appendingPathComponent("config.json"), bytes: 32)

        let venv = root.appendingPathComponent(".venv")
        try makeDirectory(venv)
        try writeFile(venv.appendingPathComponent("pyvenv.cfg"), bytes: 64)

        let report = UnknownStorageScanner.scan(
            directory: root,
            thresholdBytes: 0,
            knownCacheLocations: []
        )

        let modelNode = try XCTUnwrap(report.nodes.first { $0.name == "models--org--model" })
        XCTAssertEqual(modelNode.classification, .aiModel)
        XCTAssertEqual(modelNode.confidence, .verified)

        let venvNode = try XCTUnwrap(report.nodes.first { $0.name == ".venv" })
        XCTAssertEqual(venvNode.classification, .developmentEnvironment)
        XCTAssertEqual(venvNode.confidence, .verified)
        XCTAssertTrue(venvNode.evidence.contains { $0.contains("pyvenv.cfg") })
    }

    func testGitMetadataIsNeverClassifiedAsCache() throws {
        let root = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: root) }

        try makeDirectory(root.appendingPathComponent(".git"))
        try writeFile(root.appendingPathComponent(".git/HEAD"), bytes: 32)

        let report = UnknownStorageScanner.scan(
            directory: root,
            thresholdBytes: 0,
            knownCacheLocations: []
        )

        let gitNode = try XCTUnwrap(report.nodes.first { $0.name == ".git" })
        XCTAssertEqual(gitNode.classification, .unknown)
        XCTAssertEqual(gitNode.confidence, .unknown)
        XCTAssertTrue(gitNode.evidence.contains { $0.contains("Git") })
    }

    func testNestedDirectoriesAreOnlyListedOneLevelAtATime() throws {
        let root = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: root) }

        let outer = root.appendingPathComponent("outer")
        let inner = outer.appendingPathComponent("inner")
        try makeDirectory(inner)
        try writeFile(inner.appendingPathComponent("payload.bin"), megabytes: 2)

        let rootReport = UnknownStorageScanner.scan(
            directory: root,
            thresholdBytes: 0,
            knownCacheLocations: []
        )
        XCTAssertEqual(rootReport.nodes.map(\.name), ["outer"])
        XCTAssertFalse(rootReport.nodes.contains { $0.name == "inner" })

        let outerReport = UnknownStorageScanner.scan(
            directory: outer,
            thresholdBytes: 0,
            knownCacheLocations: []
        )
        XCTAssertEqual(outerReport.nodes.map(\.name), ["inner"])
    }

    func testInaccessibleDirectoryStaysVisibleWithDiagnostics() throws {
        try XCTSkipIf(getuid() == 0, "root 会绕过目录权限，无法复现读取失败")
        let root = try makeTemporaryDirectory()
        let locked = root.appendingPathComponent("locked")
        defer {
            try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            try? fileManager.removeItem(at: root)
        }

        try makeDirectory(locked)
        try writeFile(locked.appendingPathComponent("hidden.bin"), megabytes: 2)
        try fileManager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)

        let report = UnknownStorageScanner.scan(
            directory: root,
            thresholdBytes: 1_073_741_824,
            knownCacheLocations: []
        )

        let node = try XCTUnwrap(report.nodes.first { $0.name == "locked" })
        XCTAssertNotEqual(node.measurement.state, .complete)
        XCTAssertEqual(node.sizeText.hasPrefix("≥") || node.sizeText == "无法统计", true)
        XCTAssertTrue(report.issues.contains { $0.path.standardizedFileURL.path == locked.standardizedFileURL.path })
    }

    func testCancellationReturnsIncompleteReportWithoutNodes() throws {
        let root = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: root) }
        try writeFile(root.appendingPathComponent("payload.bin"), megabytes: 2)

        let report = UnknownStorageScanner.scan(
            directory: root,
            thresholdBytes: 0,
            knownCacheLocations: [],
            isCancelled: { true }
        )

        XCTAssertTrue(report.wasCancelled)
        XCTAssertTrue(report.nodes.isEmpty)
    }

    func testAllNodesKeepBelowThresholdEntriesForDistribution() throws {
        let root = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: root) }

        try writeFile(root.appendingPathComponent("large.bin"), megabytes: 2)
        try writeFile(root.appendingPathComponent("small.txt"), bytes: 128)

        let report = UnknownStorageScanner.scan(
            directory: root,
            thresholdBytes: 1_048_576,
            knownCacheLocations: []
        )

        XCTAssertEqual(report.nodes.map(\.name), ["large.bin"])
        XCTAssertEqual(Set(report.allNodes.map(\.name)), ["large.bin", "small.txt"])
        XCTAssertEqual(report.filteredCount, 1)
        XCTAssertGreaterThan(report.totalAllocatedBytes, report.nodes[0].measurement.allocatedBytes)
    }

    func testExactKnownCacheExposesCleanupCandidateButUnknownDoesNot() throws {
        let root = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: root) }

        let knownCache = root.appendingPathComponent("custom-cache")
        try makeDirectory(knownCache)
        try writeFile(knownCache.appendingPathComponent("blob.bin"), megabytes: 2)
        let unknown = root.appendingPathComponent("mystery")
        try makeDirectory(unknown)
        try writeFile(unknown.appendingPathComponent("payload.bin"), megabytes: 2)

        let safeLocation = KnownCacheLocation(
            url: knownCache,
            category: "测试工具",
            name: "测试缓存",
            risk: .review,
            note: "测试用缓存规则"
        )
        let report = UnknownStorageScanner.scan(
            directory: root,
            thresholdBytes: 0,
            knownCacheLocations: [safeLocation]
        )

        let knownNode = try XCTUnwrap(report.nodes.first { $0.name == "custom-cache" })
        XCTAssertEqual(knownNode.cleanupCandidate?.category, "测试工具")
        XCTAssertEqual(knownNode.cleanupCandidate?.risk, .review)
        let unknownNode = try XCTUnwrap(report.nodes.first { $0.name == "mystery" })
        XCTAssertNil(unknownNode.cleanupCandidate)

        let manualLocation = KnownCacheLocation(
            url: knownCache,
            category: "测试工具",
            name: "手动缓存",
            risk: .manual,
            note: "只能手动处理"
        )
        let manualReport = UnknownStorageScanner.scan(
            directory: root,
            thresholdBytes: 0,
            knownCacheLocations: [manualLocation]
        )
        XCTAssertNil(manualReport.nodes.first { $0.name == "custom-cache" }?.cleanupCandidate)
    }

    func testFileMetadataDrivesTypesAndLogicalSize() throws {
        let root = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: root) }

        try writeFile(root.appendingPathComponent("photo.png"), bytes: 2_048)
        try writeFile(root.appendingPathComponent("main.swift"), bytes: 1_024)
        try makeDirectory(root.appendingPathComponent("nested"))

        let report = UnknownStorageScanner.scan(
            directory: root,
            thresholdBytes: 0,
            knownCacheLocations: []
        )

        let photo = try XCTUnwrap(report.allNodes.first { $0.name == "photo.png" })
        XCTAssertEqual(photo.fileType, .image)
        XCTAssertEqual(photo.logicalBytes, 2_048)
        XCTAssertFalse(photo.isDirectory)

        let source = try XCTUnwrap(report.allNodes.first { $0.name == "main.swift" })
        XCTAssertEqual(source.fileType, .source)

        let folder = try XCTUnwrap(report.allNodes.first { $0.name == "nested" })
        XCTAssertEqual(folder.fileType, .folder)
        XCTAssertNil(folder.logicalBytes)

        let summary = report.totalFileTypes
        XCTAssertEqual(summary.reduce(Int64(0)) { $0 + $1.allocatedBytes }, report.totalAllocatedBytes)
    }

    func testInventoryKeepsMissingRootsAndDeduplicates() throws {
        let existing = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: existing) }
        let missing = existing.appendingPathComponent("not-created")

        let inventory = UnknownStorageScanner.inventory(roots: [existing, existing, missing])

        XCTAssertEqual(inventory.count, 2)
        let existingRoot = try XCTUnwrap(inventory.first { $0.path.standardizedFileURL == existing.standardizedFileURL })
        XCTAssertTrue(existingRoot.exists)
        XCTAssertTrue(existingRoot.isDirectory)
        let missingRoot = try XCTUnwrap(inventory.first { $0.path.path == missing.standardizedFileURL.path })
        XCTAssertFalse(missingRoot.exists)
    }

    // MARK: - Fixtures

    private func makeTemporaryDirectory() throws -> URL {
        let url = fileManager.temporaryDirectory
            .appendingPathComponent("DevSweepDiscovery-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeDirectory(_ url: URL) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private func writeFile(_ url: URL, bytes: Int) throws {
        try Data(repeating: 0xA5, count: bytes).write(to: url)
    }

    private func writeFile(_ url: URL, megabytes: Int) throws {
        try writeFile(url, bytes: megabytes * 1_048_576)
    }
}
