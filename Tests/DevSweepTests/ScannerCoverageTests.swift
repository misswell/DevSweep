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
            progress: { _ in },
            environment: [:]
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
            progress: { _ in },
            environment: [:]
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
            progress: { _ in },
            environment: [
                "CODEX_HOME": codexHome.path,
                "XDG_CACHE_HOME": xdgCacheHome.path,
                "XDG_DATA_HOME": xdgDataHome.path,
                "CLAUDE_CONFIG_DIR": claudeConfig.path
            ]
        )
        let scannedPaths = Set(report.items.filter { $0.category == "AI Agent" }.map(\.path))

        XCTAssertTrue(scannedPaths.contains(codexHome.appendingPathComponent("logs_2.sqlite")))
        XCTAssertTrue(scannedPaths.contains(xdgCacheHome.appendingPathComponent("opencode")))
        XCTAssertTrue(scannedPaths.contains(xdgDataHome.appendingPathComponent("opencode/log")))
        XCTAssertTrue(scannedPaths.contains(claudeConfig.appendingPathComponent("debug-logs")))

    }

    func testFixedScannerFindsAuditedToolchainAndIDECaches() throws {
        let home = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: home) }

        let expectedRisks: [String: RiskLevel] = [
            ".nvm/.cache": .safe,
            ".volta/cache": .safe,
            ".sonar/cache": .safe,
            "Library/Caches/pnpm": .safe,
            "Library/Caches/com.apple.dt.instruments": .safe,
            "Library/Caches/com.apple.dt.SourceKitService": .safe,
            "Library/Caches/com.apple.dt.XcodePreviews": .safe,
            ".cache/org.swift.swiftpm": .safe,
            ".swiftpm/cache": .safe,
            ".swiftpm/repositories": .review,
            ".cocoapods/repos": .review,
            ".sbt/boot": .review,
            ".ivy2/cache": .review,
            ".coursier/cache": .review,
            ".cache/metals": .review,
            "Library/Application Support/Code/GPUCache": .safe,
            "Library/Application Support/Lingma/CachedExtensionVSIXs": .safe,
            "Library/Application Support/Trae CN/CachedData": .safe,
            "Library/Application Support/Trae CN/CachedProfilesData": .safe,
            "Library/Application Support/Windsurf/GPUCache": .safe,
            "Library/Caches/Zed": .safe,
            "Library/Application Support/ai.opencode.desktop/Cache": .safe,
            "Library/Application Support/Nova/Caches": .safe
        ]
        for relativePath in expectedRisks.keys {
            try createAllocatedCache(at: home.appendingPathComponent(relativePath))
        }

        let report = CacheScanner.scan(
            projectRoots: [],
            deepScan: false,
            home: home,
            includeSystemCaches: false,
            progress: { _ in },
            environment: [:]
        )
        let scannedItems = Dictionary(uniqueKeysWithValues: report.items.map { ($0.path, $0) })

        for (relativePath, expectedRisk) in expectedRisks {
            let path = home.appendingPathComponent(relativePath).standardizedFileURL
            XCTAssertEqual(scannedItems[path]?.risk, expectedRisk, relativePath)
        }
    }

    func testDynamicScannerFindsRelocatedToolCaches() throws {
        let home = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: home) }

        let expectedRisks: [String: RiskLevel] = [
            "relocated/nvm/.cache": .safe,
            "relocated/volta/cache": .safe,
            "relocated/sonar/cache": .safe,
            "relocated/coursier-cache": .review,
            "relocated/cocoapods-cache": .review,
            "relocated/cocoapods-repos": .review
        ]
        for relativePath in expectedRisks.keys {
            try createAllocatedCache(at: home.appendingPathComponent(relativePath))
        }

        let report = CacheScanner.scan(
            projectRoots: [],
            deepScan: false,
            home: home,
            includeSystemCaches: false,
            progress: { _ in },
            environment: [
                "NVM_DIR": "relocated/nvm",
                "VOLTA_HOME": "relocated/volta",
                "SONAR_USER_HOME": "relocated/sonar",
                "COURSIER_CACHE": "relocated/coursier-cache",
                "CP_CACHE_DIR": "relocated/cocoapods-cache",
                "CP_REPOS_DIR": "relocated/cocoapods-repos"
            ]
        )
        let scannedItems = Dictionary(uniqueKeysWithValues: report.items.map { ($0.path, $0) })

        for (relativePath, expectedRisk) in expectedRisks {
            let path = home.appendingPathComponent(relativePath).standardizedFileURL
            XCTAssertEqual(scannedItems[path]?.risk, expectedRisk, relativePath)
        }
    }

    func testDynamicScannerDerivesCocoaPodsReposFromCustomHome() throws {
        let home = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: home) }

        let repos = home.appendingPathComponent("relocated/cocoapods-home/repos")
        try createAllocatedCache(at: repos)

        let report = CacheScanner.scan(
            projectRoots: [],
            deepScan: false,
            home: home,
            includeSystemCaches: false,
            progress: { _ in },
            environment: ["CP_HOME_DIR": "relocated/cocoapods-home"]
        )

        let item = report.items.first { $0.path == repos.standardizedFileURL }
        XCTAssertEqual(item?.risk, .review)
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

    func testScannerMatchesCustomXcodeDerivedDataDirectoriesBySignature() throws {
        let root = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: root) }

        try fileManager.createDirectory(
            at: root.appendingPathComponent("CCRBar.xcodeproj"),
            withIntermediateDirectories: true
        )
        let workspaceRoot = root.appendingPathComponent("WorkspaceProject")
        try fileManager.createDirectory(
            at: workspaceRoot.appendingPathComponent("Workspace.xcworkspace"),
            withIntermediateDirectories: true
        )

        let releaseBuild = root.appendingPathComponent("build-release-0.1.5")
        try createAllocatedCache(at: releaseBuild.appendingPathComponent("ModuleCache.noindex"))
        try createAllocatedCache(at: releaseBuild.appendingPathComponent("Index.noindex"))
        try fileManager.createDirectory(
            at: releaseBuild.appendingPathComponent("Build/Products/Release/CCRBar.app"),
            withIntermediateDirectories: true
        )

        let platformReleaseBuild = root.appendingPathComponent("build-release-device")
        try createAllocatedCache(at: platformReleaseBuild.appendingPathComponent("Build"))
        try createAllocatedCache(at: platformReleaseBuild.appendingPathComponent("Index.noindex"))
        try fileManager.createDirectory(
            at: platformReleaseBuild.appendingPathComponent("Build/Products/Release-iphoneos/CCRBar.app"),
            withIntermediateDirectories: true
        )

        let archivedBuild = root.appendingPathComponent("build-release-archive")
        try createAllocatedCache(at: archivedBuild.appendingPathComponent("Build"))
        try createAllocatedCache(at: archivedBuild.appendingPathComponent("Logs"))
        try fileManager.createDirectory(
            at: archivedBuild.appendingPathComponent("Build/Archives/2026-09-02/CCRBar.xcarchive"),
            withIntermediateDirectories: true
        )

        let packagedBuild = root.appendingPathComponent("build-release-package")
        try createAllocatedCache(at: packagedBuild.appendingPathComponent("Build"))
        try createAllocatedCache(at: packagedBuild.appendingPathComponent("Logs"))
        try createAllocatedFile(at: packagedBuild.appendingPathComponent("CCRBar-0.1.7-macos.zip"))

        let workspaceBuild = workspaceRoot.appendingPathComponent("build-workspace")
        try createAllocatedCache(at: workspaceBuild.appendingPathComponent("Build"))
        try createAllocatedCache(at: workspaceBuild.appendingPathComponent("ModuleCache.noindex"))

        let testBuild = root.appendingPathComponent("build-tests-stop8")
        try createAllocatedCache(at: testBuild.appendingPathComponent("Build"))
        try createAllocatedCache(at: testBuild.appendingPathComponent("Logs"))

        let misleadingBuild = root.appendingPathComponent("build-output")
        try createAllocatedCache(at: misleadingBuild)

        let weakBuild = root.appendingPathComponent("build-weak")
        try createAllocatedCache(at: weakBuild.appendingPathComponent("Build"))

        let outsideProject = root.appendingPathComponent("ordinary")
        let outsideBuild = outsideProject.appendingPathComponent("build-release-0.1.5")
        try createAllocatedCache(at: outsideBuild.appendingPathComponent("ModuleCache.noindex"))
        try createAllocatedCache(at: outsideBuild.appendingPathComponent("Index.noindex"))

        let report = CacheScanner.scan(
            projectRoots: [root],
            deepScan: false,
            home: root.appendingPathComponent("empty-home"),
            includeSystemCaches: false,
            progress: { _ in }
        )

        let items = Dictionary(uniqueKeysWithValues: report.items.map { ($0.path, $0) })
        XCTAssertEqual(items[releaseBuild.standardizedFileURL]?.category, "Apple 项目")
        XCTAssertEqual(items[releaseBuild.standardizedFileURL]?.risk, .review)
        XCTAssertFalse(items[releaseBuild.standardizedFileURL]?.isSelected ?? true)
        XCTAssertEqual(items[testBuild.standardizedFileURL]?.category, "Apple 项目")
        XCTAssertTrue(items[platformReleaseBuild.standardizedFileURL]?.note.contains("Release 产物") ?? false)
        XCTAssertTrue(items[archivedBuild.standardizedFileURL]?.note.contains("Release 产物") ?? false)
        XCTAssertTrue(items[packagedBuild.standardizedFileURL]?.note.contains("Release 产物") ?? false)
        XCTAssertEqual(items[workspaceBuild.standardizedFileURL]?.category, "Apple 项目")
        XCTAssertNil(items[misleadingBuild.standardizedFileURL])
        XCTAssertNil(items[weakBuild.standardizedFileURL])
        XCTAssertNil(items[outsideBuild.standardizedFileURL])
    }

    func testScannerMatchesVersionedProjectReleasesAndInstallers() throws {
        let root = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: root) }

        try Data("{}".utf8).write(to: root.appendingPathComponent("package.json"))

        let releaseDirectory = root.appendingPathComponent("release-v2.5.6/final-assets")
        try createAllocatedCache(at: releaseDirectory)
        let releaseRoot = releaseDirectory.deletingLastPathComponent()

        let outputDirectory = root.appendingPathComponent("output")
        try createAllocatedCache(at: outputDirectory)

        let installer = root.appendingPathComponent("OctoShrink-2.5.24.pkg")
        try createAllocatedFile(at: installer)

        let unversionedInstaller = root.appendingPathComponent("OctoShrink-latest.pkg")
        try createAllocatedFile(at: unversionedInstaller)

        let misleadingRelease = root.appendingPathComponent("release-v2.5.7")
        try createAllocatedCache(at: misleadingRelease.appendingPathComponent("notes"))

        let report = CacheScanner.scan(
            projectRoots: [root],
            deepScan: false,
            home: root.appendingPathComponent("empty-home"),
            includeSystemCaches: false,
            progress: { _ in },
            environment: [:]
        )

        let items = Dictionary(uniqueKeysWithValues: report.items.map { ($0.path, $0) })
        XCTAssertEqual(items[releaseRoot.standardizedFileURL]?.category, "项目生成物")
        XCTAssertEqual(items[releaseRoot.standardizedFileURL]?.risk, .review)
        XCTAssertFalse(items[releaseRoot.standardizedFileURL]?.isSelected ?? true)
        XCTAssertEqual(items[outputDirectory.standardizedFileURL]?.category, "项目生成物")
        XCTAssertEqual(items[installer.standardizedFileURL]?.category, "项目生成物")
        XCTAssertEqual(items[installer.standardizedFileURL]?.risk, .review)
        XCTAssertFalse(items[installer.standardizedFileURL]?.isSelected ?? true)
        XCTAssertNil(items[unversionedInstaller.standardizedFileURL])
        XCTAssertNil(items[misleadingRelease.standardizedFileURL])
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
