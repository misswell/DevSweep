import Foundation
import XCTest
@testable import DevSweep

final class ScannerCoverageTests: XCTestCase {
    private let fileManager = FileManager.default

    func testFixedScannerFindsNewDeveloperCaches() throws {
        let home = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: home) }

        let expectedPaths = [
            ".npm/_npx",
            ".bundle/cache",
            ".node-gyp",
            "Library/Application Support/Code/CachedExtensionVSIXs"
        ]
        for relativePath in expectedPaths {
            try createAllocatedCache(at: home.appendingPathComponent(relativePath))
        }

        let report = CacheScanner.scan(
            projectRoots: [],
            deepScan: false,
            home: home,
            includeSystemCaches: false,
            environment: [:],
            progress: { _ in }
        )
        let scannedPaths = Set(report.items.map(\.path))

        for relativePath in expectedPaths {
            XCTAssertTrue(scannedPaths.contains(home.appendingPathComponent(relativePath).standardizedFileURL))
        }
    }

    func testScannerFindsAgentCachesAndLogsWithoutTouchingAgentState() throws {
        let home = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: home) }

        let expectedPaths = [
            ".codex/logs_2.sqlite",
            ".cache/opencode",
            ".local/share/opencode/log",
            "Library/Caches/opencode",
            "Library/Application Support/opencode/log",
            ".claude/debug-logs",
            "Library/Caches/goose-updater"
        ]
        for relativePath in expectedPaths {
            let path = home.appendingPathComponent(relativePath)
            if path.pathExtension == "sqlite" {
                try createAllocatedFile(at: path)
            } else {
                try createAllocatedCache(at: path)
            }
        }

        // Codex keeps goals, memories, queue, and thread history alongside logs;
        // those databases are agent state and must never be cleanup candidates.
        for database in [
            "goals_1.sqlite", "memories_1.sqlite", "queue_1.sqlite",
            "state_5.sqlite", "thread_history_1.sqlite"
        ] {
            try createAllocatedFile(at: home.appendingPathComponent(".codex/\(database)"))
        }
        try createAllocatedCache(at: home.appendingPathComponent(".local/share/opencode/data"))
        try createAllocatedCache(at: home.appendingPathComponent(".claude/projects"))
        try createAllocatedCache(at: home.appendingPathComponent(
            "Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev"
        ))

        let report = CacheScanner.scan(
            projectRoots: [],
            deepScan: false,
            home: home,
            includeSystemCaches: false,
            environment: [:],
            progress: { _ in }
        )
        let agentItems = report.items.filter { $0.category == "AI Agent" }
        let scannedPaths = Set(agentItems.map(\.path))
        let allScannedPaths = Set(report.items.map(\.path))

        for relativePath in expectedPaths {
            XCTAssertTrue(
                scannedPaths.contains(home.appendingPathComponent(relativePath).standardizedFileURL),
                "missing agent cleanup candidate: \(relativePath)"
            )
        }
        XCTAssertEqual(agentItems.count, expectedPaths.count)

        let logsItem = agentItems.first { $0.path == home.appendingPathComponent(".codex/logs_2.sqlite") }
        XCTAssertEqual(logsItem?.risk, .review)
        XCTAssertFalse(logsItem?.isSelected ?? true)
        XCTAssertEqual(
            agentItems.first { $0.path == home.appendingPathComponent(".cache/opencode") }?.risk,
            .safe
        )
        XCTAssertEqual(
            agentItems.first { $0.path == home.appendingPathComponent("Library/Caches/opencode") }?.risk,
            .safe
        )
        XCTAssertEqual(
            agentItems.first { $0.path == home.appendingPathComponent(".claude/debug-logs") }?.risk,
            .review
        )
        XCTAssertEqual(
            agentItems.first { $0.path == home.appendingPathComponent("Library/Caches/goose-updater") }?.risk,
            .review
        )

        let excludedPaths = [
            ".codex/goals_1.sqlite", ".codex/memories_1.sqlite", ".codex/queue_1.sqlite",
            ".codex/state_5.sqlite", ".codex/thread_history_1.sqlite",
            ".local/share/opencode/data", ".claude/projects",
            "Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev"
        ].map { home.appendingPathComponent($0).standardizedFileURL }
        for path in excludedPaths {
            XCTAssertFalse(allScannedPaths.contains(path), "agent state must not be scanned: \(path.path)")
        }
    }

    func testScannerFindsAgentCachesInConfiguredEnvironmentHomes() throws {
        let home = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: home) }

        let codexHome = home.appendingPathComponent("custom-codex")
        let xdgCacheHome = home.appendingPathComponent("custom-xdg-cache")
        let xdgDataHome = home.appendingPathComponent("custom-xdg-data")
        let claudeConfig = home.appendingPathComponent("custom-claude")
        try createAllocatedFile(at: codexHome.appendingPathComponent("logs_2.sqlite"))
        try createAllocatedCache(at: xdgCacheHome.appendingPathComponent("opencode"))
        try createAllocatedCache(at: xdgDataHome.appendingPathComponent("opencode/log"))
        try createAllocatedCache(at: claudeConfig.appendingPathComponent("debug-logs"))

        let report = CacheScanner.scan(
            projectRoots: [],
            deepScan: false,
            home: home,
            includeSystemCaches: false,
            environment: [
                "CODEX_HOME": codexHome.path,
                "XDG_CACHE_HOME": xdgCacheHome.path,
                "XDG_DATA_HOME": xdgDataHome.path,
                "CLAUDE_CONFIG_DIR": claudeConfig.path
            ],
            progress: { _ in }
        )
        let scannedPaths = Set(report.items.filter { $0.category == "AI Agent" }.map(\.path))

        XCTAssertTrue(scannedPaths.contains(codexHome.appendingPathComponent("logs_2.sqlite")))
        XCTAssertTrue(scannedPaths.contains(xdgCacheHome.appendingPathComponent("opencode")))
        XCTAssertTrue(scannedPaths.contains(xdgDataHome.appendingPathComponent("opencode/log")))
        XCTAssertTrue(scannedPaths.contains(claudeConfig.appendingPathComponent("debug-logs")))
    }

    func testFixedScannerFindsScriptInspiredApplicationCaches() throws {
        let home = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: home) }

        let expectedPaths = [
            "Library/Caches/Microsoft Edge",
            "Library/Caches/Firefox",
            "Library/Application Support/Google/GoogleUpdater/crx_cache",
            "Library/Containers/com.apple.mediaanalysisd/Data/Library/Caches",
            "Movies/JianyingPro/User Data/Cache",
            "Library/Caches/Google",
            "logs"
        ]
        for relativePath in expectedPaths {
            try createAllocatedCache(at: home.appendingPathComponent(relativePath))
        }

        let report = CacheScanner.scan(
            projectRoots: [],
            deepScan: false,
            home: home,
            includeSystemCaches: false,
            progress: { _ in }
        )
        let scannedPaths = Set(report.items.map(\.path))

        for relativePath in expectedPaths {
            XCTAssertTrue(scannedPaths.contains(home.appendingPathComponent(relativePath).standardizedFileURL))
        }
    }

    func testAmbiguousProjectArtifactsRequireMatchingProjectMarkers() throws {
        let root = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: root) }

        let composer = root.appendingPathComponent("composer")
        let dotnet = root.appendingPathComponent("dotnet")
        let xcode = root.appendingPathComponent("xcode")
        let ordinary = root.appendingPathComponent("ordinary")
        for directory in [composer, dotnet, xcode, ordinary] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try Data().write(to: composer.appendingPathComponent("composer.json"))
        try Data().write(to: dotnet.appendingPathComponent("Example.csproj"))
        try fileManager.createDirectory(at: xcode.appendingPathComponent("Example.xcodeproj"), withIntermediateDirectories: true)

        XCTAssertEqual(CacheScanner.generatedRule(for: composer.appendingPathComponent("vendor"))?.category, "PHP 项目")
        XCTAssertEqual(CacheScanner.generatedRule(for: dotnet.appendingPathComponent("bin"))?.category, ".NET 项目")
        XCTAssertEqual(CacheScanner.generatedRule(for: dotnet.appendingPathComponent("obj"))?.category, ".NET 项目")
        XCTAssertEqual(CacheScanner.generatedRule(for: xcode.appendingPathComponent("DerivedData"))?.category, "Apple 项目")

        XCTAssertNil(CacheScanner.generatedRule(for: ordinary.appendingPathComponent("vendor")))
        XCTAssertNil(CacheScanner.generatedRule(for: ordinary.appendingPathComponent("bin")))
        XCTAssertNil(CacheScanner.generatedRule(for: ordinary.appendingPathComponent("obj")))
        XCTAssertNil(CacheScanner.generatedRule(for: ordinary.appendingPathComponent("DerivedData")))
    }

    func testNewProjectArtifactRulesCoverModernToolchains() throws {
        let root = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: root) }

        XCTAssertNotNil(CacheScanner.generatedRule(for: root.appendingPathComponent(".terragrunt-cache")))
        XCTAssertNotNil(CacheScanner.generatedRule(for: root.appendingPathComponent(".astro")))
        XCTAssertNotNil(CacheScanner.generatedRule(for: root.appendingPathComponent("zig-out")))

        let android = root.appendingPathComponent("android/app")
        try fileManager.createDirectory(at: android, withIntermediateDirectories: true)
        try Data().write(to: android.appendingPathComponent("build.gradle"))
        XCTAssertEqual(CacheScanner.generatedRule(for: android.appendingPathComponent(".cxx"))?.category, "Android 项目")
        XCTAssertNil(CacheScanner.generatedRule(for: root.appendingPathComponent(".cxx")))
    }

    func testProjectLogsRequireAProjectMarker() throws {
        let root = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: root) }

        let service = root.appendingPathComponent("service")
        let nestedApp = service.appendingPathComponent("app")
        let ordinary = root.appendingPathComponent("ordinary")
        try fileManager.createDirectory(at: nestedApp, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: ordinary, withIntermediateDirectories: true)
        try Data().write(to: service.appendingPathComponent("pom.xml"))

        let nacos = root.appendingPathComponent("nacos")
        try fileManager.createDirectory(at: nacos.appendingPathComponent("conf"), withIntermediateDirectories: true)
        try Data().write(to: nacos.appendingPathComponent("conf/application.properties"))

        let directRule = CacheScanner.generatedRule(for: service.appendingPathComponent("logs"))
        let nestedRule = CacheScanner.generatedRule(for: nestedApp.appendingPathComponent("log"))

        XCTAssertEqual(directRule?.category, "项目日志")
        XCTAssertEqual(directRule?.risk, .review)
        XCTAssertEqual(nestedRule?.category, "项目日志")
        XCTAssertEqual(CacheScanner.generatedRule(for: nacos.appendingPathComponent("logs"))?.category, "项目日志")
        XCTAssertNil(CacheScanner.generatedRule(for: ordinary.appendingPathComponent("logs")))
    }

    func testDeepScanFindsNestedApplicationLogs() throws {
        let root = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: root) }

        let service = root.appendingPathComponent("company/product/service")
        let logs = service.appendingPathComponent("app/logs")
        try fileManager.createDirectory(at: logs, withIntermediateDirectories: true)
        try Data().write(to: service.appendingPathComponent("pom.xml"))
        try Data(repeating: 0xA5, count: 1_100_000).write(to: logs.appendingPathComponent("service.log"))

        let report = CacheScanner.scan(
            projectRoots: [root],
            deepScan: true,
            home: root.appendingPathComponent("empty-home"),
            includeSystemCaches: false,
            progress: { _ in }
        )

        XCTAssertTrue(report.items.contains { $0.path == logs.standardizedFileURL && $0.category == "项目日志" })
    }

    func testScannerFindsNestedSoftwareUpdateResidues() throws {
        let home = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: home) }

        let expectedPaths = [
            "Library/Caches/Mozilla/updates/0/update.mar",
            "Library/Caches/SomeUpdater/staging/update.zip",
            "Library/Caches/TencentDocs/downloads/TencentDocs-9.9.9.zip"
        ]
        for relativePath in expectedPaths {
            let file = home.appendingPathComponent(relativePath)
            try fileManager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 0xA5, count: 1_100_000).write(to: file)
        }

        let report = CacheScanner.scan(
            projectRoots: [],
            deepScan: false,
            home: home,
            includeSystemCaches: false,
            progress: { _ in }
        )
        let scannedPaths = Set(report.items.map(\.path))

        for relativePath in expectedPaths {
            XCTAssertTrue(scannedPaths.contains(home.appendingPathComponent(relativePath).standardizedFileURL))
        }
    }

    func testScannerFindsUpdateResiduesAcrossCommonUserLocations() throws {
        let home = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: home) }

        let expectedPaths = [
            "Library/Application Support/Acme/Updater/staging/Acme-2.0.dmg",
            "Library/Application Support/Acme/Updater/downloads/archive.tar",
            "Library/Containers/com.acme.app/Data/Library/Application Support/Squirrel/pending/update.pkg",
            "Library/Containers/com.acme.app/Data/Library/HTTPStorages/Updater/pending/update.delta",
            "Library/Group Containers/group.acme/Library/Caches/Sparkle/downloads/release.zip",
            "Library/Group Containers/group.acme/Library/HTTPStorages/Sparkle/downloads/release.patch",
            "Library/HTTPStorages/com.acme/updates/update.patch"
        ]
        for relativePath in expectedPaths {
            let file = home.appendingPathComponent(relativePath)
            try fileManager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 0xA5, count: 1_100_000).write(to: file)
        }

        let unrelatedArchive = home.appendingPathComponent("Library/Application Support/Acme/Documents/archive.zip")
        try fileManager.createDirectory(at: unrelatedArchive.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0xA5, count: 1_100_000).write(to: unrelatedArchive)
        let misleadingArchive = home.appendingPathComponent("Library/Application Support/Acme/customer-update.zip")
        try Data(repeating: 0xA5, count: 1_100_000).write(to: misleadingArchive)
        let partialDownload = home.appendingPathComponent("Library/Application Support/Acme/Updater/pending/App.download")
        try createAllocatedCache(at: partialDownload)

        let report = CacheScanner.scan(
            projectRoots: [],
            deepScan: false,
            home: home,
            includeSystemCaches: false,
            progress: { _ in }
        )
        let scannedPaths = Set(report.items.map(\.path))

        for relativePath in expectedPaths {
            XCTAssertTrue(scannedPaths.contains(home.appendingPathComponent(relativePath).standardizedFileURL))
        }
        XCTAssertTrue(scannedPaths.contains(partialDownload.standardizedFileURL))
        XCTAssertFalse(scannedPaths.contains(unrelatedArchive.standardizedFileURL))
        XCTAssertFalse(scannedPaths.contains(misleadingArchive.standardizedFileURL))
    }

    func testScannerFindsCachesInCustomChromiumProfiles() throws {
        let home = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: home) }

        let expectedPaths = [
            "Documents/chrome/Default/Cache",
            "Documents/chrome2/Profile 1/Code Cache"
        ]
        for relativePath in expectedPaths {
            try createAllocatedCache(at: home.appendingPathComponent(relativePath))
        }

        let report = CacheScanner.scan(
            projectRoots: [],
            deepScan: false,
            home: home,
            includeSystemCaches: false,
            progress: { _ in }
        )
        let scannedPaths = Set(report.items.map(\.path))

        for relativePath in expectedPaths {
            XCTAssertTrue(scannedPaths.contains(home.appendingPathComponent(relativePath).standardizedFileURL))
        }
    }

    private func temporaryDirectory() throws -> URL {
        let url = fileManager.temporaryDirectory.appendingPathComponent("DevSweepTests-\(UUID().uuidString)")
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func createAllocatedCache(at directory: URL) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(repeating: 0xA5, count: 1_100_000).write(to: directory.appendingPathComponent("cache.bin"))
    }

    private func createAllocatedFile(at file: URL) throws {
        try fileManager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0xA5, count: 1_100_000).write(to: file)
    }
}
