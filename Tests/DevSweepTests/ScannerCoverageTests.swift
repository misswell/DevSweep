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
            "Library/Caches/Google"
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
        XCTAssertEqual(CacheScanner.generatedRule(for: composer.appendingPathComponent("build"))?.category, "项目生成物")

        XCTAssertNil(CacheScanner.generatedRule(for: ordinary.appendingPathComponent("vendor")))
        XCTAssertNil(CacheScanner.generatedRule(for: ordinary.appendingPathComponent("bin")))
        XCTAssertNil(CacheScanner.generatedRule(for: ordinary.appendingPathComponent("obj")))
        XCTAssertNil(CacheScanner.generatedRule(for: ordinary.appendingPathComponent("DerivedData")))
        XCTAssertNil(CacheScanner.generatedRule(for: ordinary.appendingPathComponent("build")))
    }

    // MARK: - cargo target 拆分

    private func makeCargoTarget(in root: URL) throws -> (project: URL, target: URL, debug: URL) {
        let project = root.appendingPathComponent("rust-app")
        let target = project.appendingPathComponent("target")
        let debug = target.appendingPathComponent("debug")
        try fileManager.createDirectory(at: project, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: project.appendingPathComponent("Cargo.toml"))
        try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("Signature: 8a477f597d28d172789f06886806bc55\n".utf8)
            .write(to: target.appendingPathComponent("CACHEDIR.TAG"))
        try Data("{}".utf8).write(to: target.appendingPathComponent(".rustc_info.json"))
        return (project, target, debug)
    }

    /// cargo 在 target/ 写入 CACHEDIR.TAG，不能因此把整个 target 当成
    /// 「其他开发缓存 / 可直接清理」；必须仍按 Rust 项目处理。
    func testCargoTargetKeepsRustRuleDespiteCachedirTag() throws {
        let root = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: root) }
        let (_, target, _) = try makeCargoTarget(in: root)

        let rule = CacheScanner.generatedRule(for: target)
        XCTAssertEqual(rule?.category, "Rust / Tauri 项目")
        XCTAssertEqual(rule?.risk, .review)
    }

    /// 同名 target 的 Maven 目录必须按 JVM 处理，不能被误标成 Rust。
    func testMavenTargetIsClassifiedAsJVM() throws {
        let root = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: root) }
        let module = root.appendingPathComponent("module")
        let target = module.appendingPathComponent("target")
        try fileManager.createDirectory(
            at: target.appendingPathComponent("classes"),
            withIntermediateDirectories: true
        )
        try Data("<project/>".utf8).write(to: module.appendingPathComponent("pom.xml"))

        let rule = CacheScanner.generatedRule(for: target)
        XCTAssertEqual(rule?.category, "JVM")
        XCTAssertEqual(rule?.risk, .review)
        XCTAssertTrue(CacheScanner.isJavaTargetDirectory(target))
    }

    /// cargo target 必须拆成 artifact 级条目（deps / incremental / build / ...），
    /// 而不是只报一个巨大的 target 条目。
    func testCargoTargetIsSplitIntoArtifactLevelItems() throws {
        let root = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: root) }
        let (_, target, debug) = try makeCargoTarget(in: root)

        for artifact in ["deps", "incremental", "build", ".fingerprint", "examples"] {
            try createAllocatedCache(at: debug.appendingPathComponent(artifact))
        }
        // 交叉编译：target/<triple>/<profile>/deps
        try createAllocatedCache(
            at: target.appendingPathComponent("aarch64-apple-darwin/release/deps")
        )
        // 根级 cargo doc
        try createAllocatedCache(at: target.appendingPathComponent("doc"))

        let report = CacheScanner.scan(
            projectRoots: [root],
            deepScan: true,
            home: root.appendingPathComponent("home"),
            includeSystemCaches: false,
            progress: { _ in },
            environment: [:]
        )
        let paths = Set(report.items.map(\.path))

        // target 根条目不应再出现，取而代之的是 artifact 级条目。
        XCTAssertFalse(paths.contains(target.standardizedFileURL))
        XCTAssertTrue(paths.contains(debug.appendingPathComponent("deps").standardizedFileURL))
        XCTAssertTrue(paths.contains(debug.appendingPathComponent("incremental").standardizedFileURL))
        XCTAssertTrue(paths.contains(debug.appendingPathComponent("build").standardizedFileURL))
        XCTAssertTrue(paths.contains(debug.appendingPathComponent(".fingerprint").standardizedFileURL))
        XCTAssertTrue(paths.contains(debug.appendingPathComponent("examples").standardizedFileURL))
        XCTAssertTrue(paths.contains(
            target.appendingPathComponent("aarch64-apple-darwin/release/deps").standardizedFileURL
        ))
        XCTAssertTrue(paths.contains(target.appendingPathComponent("doc").standardizedFileURL))

        let byPath = Dictionary(uniqueKeysWithValues: report.items.map { ($0.path, $0) })
        XCTAssertEqual(byPath[debug.appendingPathComponent("incremental").standardizedFileURL]?.risk, .safe)
        XCTAssertEqual(byPath[target.appendingPathComponent("doc").standardizedFileURL]?.risk, .safe)
        XCTAssertEqual(byPath[debug.appendingPathComponent("deps").standardizedFileURL]?.risk, .review)

        // 显示名要能区分 profile 和交叉编译三元组。
        XCTAssertEqual(
            byPath[debug.appendingPathComponent("deps").standardizedFileURL]?.name,
            "deps · debug · rust-app"
        )
        XCTAssertEqual(
            byPath[target.appendingPathComponent("aarch64-apple-darwin/release/deps").standardizedFileURL]?.name,
            "deps · aarch64-apple-darwin/release · rust-app"
        )
    }

    /// target 下的自定义输出目录（例如 macos-package）不能在拆分后消失。
    func testCargoTargetKeepsCustomOutputDirectories() throws {
        let root = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: root) }
        let (_, target, _) = try makeCargoTarget(in: root)
        try createAllocatedCache(at: target.appendingPathComponent("debug/deps"))
        let package = target.appendingPathComponent("macos-package")
        try createAllocatedCache(at: package)

        let report = CacheScanner.scan(
            projectRoots: [root],
            deepScan: true,
            home: root.appendingPathComponent("home"),
            includeSystemCaches: false,
            progress: { _ in },
            environment: [:]
        )
        let item = report.items.first { $0.path == package.standardizedFileURL }
        XCTAssertEqual(item?.category, "Rust / Tauri 项目")
        XCTAssertEqual(item?.risk, .review)
    }

    /// 构建进行中（cargo 持有 .cargo-lock）时，cargo artifact 必须禁止清理。
    func testCargoArtifactsAreProtectedWhileBuildHoldsLock() throws {
        let root = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: root) }
        let (_, _, debug) = try makeCargoTarget(in: root)
        try createAllocatedCache(at: debug.appendingPathComponent("incremental"))
        let lock = debug.appendingPathComponent(".cargo-lock")
        try Data().write(to: lock)

        // 模拟 cargo 持有构建锁：本进程用 flock 锁住 .cargo-lock。
        let descriptor = open(lock.path, O_RDONLY)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer {
            flock(descriptor, LOCK_UN)
            close(descriptor)
        }
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)

        let report = CacheScanner.scan(
            projectRoots: [root],
            deepScan: true,
            home: root.appendingPathComponent("home"),
            includeSystemCaches: false,
            progress: { _ in },
            environment: [:]
        )
        let item = report.items.first {
            $0.path == debug.appendingPathComponent("incremental").standardizedFileURL
        }
        XCTAssertEqual(item?.risk, .manual)
        XCTAssertEqual(item?.statusTitle, "正在构建")
        XCTAssertFalse(item?.isSelected ?? true)

        // 删除侧 TOCTOU：构建锁仍被持有，清理必须被拒绝。
        let cleanup = CacheCleaner.clean(
            [item!],
            context: DeletionContext(
                whitelistedPaths: [],
                projectRoots: [root],
                allowedPaths: [item!.path]
            )
        )
        XCTAssertTrue(cleanup.removed.isEmpty)
        XCTAssertEqual(cleanup.failures.count, 1)
        XCTAssertTrue(cleanup.failures.first?.1.contains("cargo 正在构建") ?? false)
    }

    /// 删除侧要按 artifact 路径反推出 cargo 的锁文件位置，
    /// 交叉编译（target/<triple>/<profile>）和根级 doc/package 都要覆盖。
    func testCargoArtifactPathDerivesLockLocationSafely() {
        let expected: [(String, Bool)] = [
            ("/a/b/target/debug/deps", true),
            ("/a/b/target/debug/incremental", true),
            ("/a/b/target/debug/.fingerprint", true),
            ("/a/b/target/aarch64-apple-darwin/release/deps", true),
            ("/a/b/target/wasm32-unknown-unknown/debug/incremental", true),
            ("/a/b/target/doc", true),
            ("/a/b/target/package", true),
            // 反例：不能把普通目录误判成 cargo 目标
            ("/a/b/notarget/debug/deps", false),
            ("/a/b/target/random-dir", false),
            ("/a/b/target/debug", false),
            ("/a/node_modules/deps", false),
            ("/a/b/target/x/y/z/deps", false)
        ]
        for (path, shouldResolve) in expected {
            let resolved = CacheScanner.cargoProfileLockPath(forArtifact: URL(fileURLWithPath: path))
            XCTAssertEqual(resolved != nil, shouldResolve, "unexpected result for \(path)")
        }

        // 交叉编译的锁文件应指向 profile 目录本身。
        XCTAssertEqual(
            CacheScanner.cargoProfileLockPath(
                forArtifact: URL(fileURLWithPath: "/a/b/target/aarch64-apple-darwin/release/deps")
            )?.path,
            "/a/b/target/aarch64-apple-darwin/release/.cargo-lock"
        )
    }

    /// 批量测量必须在同一批参数里对硬链接去重，否则拆分后总大小会被重复累加。
    func testBatchSizeMeasurementDeduplicatesHardLinks() throws {
        let root = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: root) }
        let first = root.appendingPathComponent("deps")
        let second = root.appendingPathComponent("incremental")
        try fileManager.createDirectory(at: first, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: second, withIntermediateDirectories: true)

        let shared = first.appendingPathComponent("shared.bin")
        try Data(repeating: 0xA5, count: 2_100_000).write(to: shared)
        try fileManager.linkItem(at: shared, to: second.appendingPathComponent("shared.bin"))
        try Data(repeating: 0xA5, count: 1_100_000)
            .write(to: second.appendingPathComponent("own.bin"))

        let measured = CacheScanner.sizes(of: [first, second])
        let firstSize = try XCTUnwrap(measured[first.standardizedFileURL.path])
        let secondSize = try XCTUnwrap(measured[second.standardizedFileURL.path])
        let total = firstSize + secondSize

        // 两个目录合计约 3.2 MB；若硬链接被重复计算会接近 5.3 MB。
        XCTAssertGreaterThan(firstSize, 0)
        XCTAssertGreaterThan(secondSize, 0)
        XCTAssertLessThan(total, 4_000_000, "hardlinked file must not be counted twice")
        XCTAssertGreaterThan(total, 3_000_000)
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

    func testDependencyStoreRisksAndCustomDenoRootAreConservative() throws {
        let home = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: home) }

        let expectedRisks: [String: RiskLevel] = [
            ".cargo/registry/cache": .safe,
            ".cargo/registry/index": .safe,
            ".cargo/registry/src": .review,
            ".cargo/git/checkouts": .review,
            ".cargo/git/db": .review,
            ".nuget/packages": .review,
            ".pub-cache": .review,
            "custom-deno": .review
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
            environment: ["DENO_DIR": "custom-deno"]
        )
        let scannedItems = Dictionary(uniqueKeysWithValues: report.items.map { ($0.path, $0) })

        for (relativePath, expectedRisk) in expectedRisks {
            let item = scannedItems[home.appendingPathComponent(relativePath).standardizedFileURL]
            XCTAssertEqual(item?.risk, expectedRisk, relativePath)
            if expectedRisk == .review {
                XCTAssertFalse(item?.isSelected ?? true, relativePath)
            }
        }
    }

    func testArtifactContainerCannotBecomeProjectRoot() throws {
        let nodeModules = try temporaryDirectory().appendingPathComponent("node_modules")
        defer { try? fileManager.removeItem(at: nodeModules.deletingLastPathComponent()) }

        let dist = nodeModules.appendingPathComponent("fake-package/dist")
        try fileManager.createDirectory(at: dist, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: nodeModules.appendingPathComponent("fake-package/package.json"))
        try Data(repeating: 0xA5, count: 1_100_000).write(to: dist.appendingPathComponent("bundle.js"))

        let report = CacheScanner.scan(
            projectRoots: [nodeModules],
            deepScan: true,
            home: nodeModules.deletingLastPathComponent().appendingPathComponent("home"),
            includeSystemCaches: false,
            progress: { _ in },
            environment: [:]
        )

        XCTAssertTrue(report.items.isEmpty)
        XCTAssertTrue(report.diagnostics.contains { $0.reason.contains("生成物容器") })
    }

    func testNormalNodeProjectStillFindsNodeModules() throws {
        let root = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: root) }

        try Data("{}".utf8).write(to: root.appendingPathComponent("package.json"))
        try createAllocatedCache(at: root.appendingPathComponent("node_modules"))

        let report = CacheScanner.scan(
            projectRoots: [root],
            deepScan: true,
            home: root.appendingPathComponent("home"),
            includeSystemCaches: false,
            progress: { _ in },
            environment: [:]
        )

        let item = report.items.first { $0.path == root.appendingPathComponent("node_modules") }
        XCTAssertEqual(item?.risk, .review)
        XCTAssertFalse(item?.isSelected ?? true)
    }

    func testMonorepoMarkersAllowNestedProjectArtifacts() throws {
        let root = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: root) }

        try Data("packages:\n  - apps/*\n".utf8).write(to: root.appendingPathComponent("pnpm-workspace.yaml"))
        let app = root.appendingPathComponent("apps/web")
        try fileManager.createDirectory(at: app, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: app.appendingPathComponent("package.json"))
        try createAllocatedCache(at: app.appendingPathComponent(".next"))

        let report = CacheScanner.scan(
            projectRoots: [root],
            deepScan: true,
            home: root.appendingPathComponent("home"),
            includeSystemCaches: false,
            progress: { _ in },
            environment: [:]
        )

        let item = report.items.first { $0.path == app.appendingPathComponent(".next") }
        XCTAssertEqual(item?.category, "Node.js 项目")
        XCTAssertEqual(item?.risk, .safe)
    }

    func testCachedirTagRequiresExactSignatureAndRegularFile() throws {
        let root = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: root) }
        let valid = root.appendingPathComponent("valid")
        let invalid = root.appendingPathComponent("invalid")
        let symlink = root.appendingPathComponent("symlink")
        let empty = root.appendingPathComponent("empty")
        for directory in [valid, invalid, symlink, empty] {
            try createAllocatedCache(at: directory)
        }

        let signature = "Signature: 8a477f597d28d172789f06886806bc55\n"
        try Data(signature.utf8).write(to: valid.appendingPathComponent("CACHEDIR.TAG"))
        try Data("Signature: invalid\n".utf8).write(to: invalid.appendingPathComponent("CACHEDIR.TAG"))
        try fileManager.createSymbolicLink(
            at: symlink.appendingPathComponent("CACHEDIR.TAG"),
            withDestinationURL: valid.appendingPathComponent("CACHEDIR.TAG")
        )
        try Data().write(to: empty.appendingPathComponent("CACHEDIR.TAG"))

        XCTAssertTrue(CacheScanner.hasValidCacheDirectoryTag(valid))
        XCTAssertFalse(CacheScanner.hasValidCacheDirectoryTag(invalid))
        XCTAssertFalse(CacheScanner.hasValidCacheDirectoryTag(symlink))
        XCTAssertFalse(CacheScanner.hasValidCacheDirectoryTag(empty))
    }

    func testCachedirTagProvidesCacheEvidenceForProjectDirectory() throws {
        let root = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: root) }
        let cache = root.appendingPathComponent("generated-cache")
        try createAllocatedCache(at: cache)
        try Data("Signature: 8a477f597d28d172789f06886806bc55\n".utf8)
            .write(to: cache.appendingPathComponent("CACHEDIR.TAG"))

        let report = CacheScanner.scan(
            projectRoots: [root],
            deepScan: true,
            home: root.appendingPathComponent("home"),
            includeSystemCaches: false,
            progress: { _ in },
            environment: [:]
        )
        let item = report.items.first { $0.path == cache.standardizedFileURL }
        XCTAssertEqual(item?.category, "其他开发缓存")
        XCTAssertEqual(item?.risk, .safe)
    }

    func testAIWorktreeCanBeScannedWithoutTreatingAgentRootAsArtifact() throws {
        let home = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: home) }
        let worktrees = home.appendingPathComponent(".codex/worktrees")
        let project = worktrees.appendingPathComponent("project")
        try fileManager.createDirectory(at: project, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: project.appendingPathComponent("package.json"))
        try createAllocatedCache(at: project.appendingPathComponent("node_modules"))

        let report = CacheScanner.scan(
            projectRoots: [worktrees],
            deepScan: true,
            home: home,
            includeSystemCaches: false,
            progress: { _ in },
            environment: [:]
        )

        XCTAssertTrue(report.items.contains { $0.path == project.appendingPathComponent("node_modules") })
        XCTAssertFalse(report.items.contains { $0.path == home.appendingPathComponent(".codex") })
        XCTAssertFalse(report.items.contains { $0.path == worktrees })
    }

    func testDangerousProjectRootIsIgnoredInsteadOfScanningWholeDisk() throws {
        let fakeHome = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: fakeHome) }

        let report = CacheScanner.scan(
            projectRoots: [URL(fileURLWithPath: "/")],
            deepScan: true,
            home: fakeHome,
            includeSystemCaches: false,
            progress: { _ in },
            environment: [:]
        )

        XCTAssertTrue(report.scannedRoots.isEmpty)
        XCTAssertFalse(report.items.contains { $0.path.path == "/" })
    }

    func testNewDatabaseAPICICachesAreScopedToExplicitLeaves() throws {
        let home = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: home) }
        let expected: [(String, String, RiskLevel)] = [
            ("Library/Caches/com.sequel-ace.sequel-ace", "数据库工具", .safe),
            ("Library/Caches/com.navicat.test", "数据库工具", .safe),
            ("Library/Caches/com.dbeaver.test", "数据库工具", .safe),
            ("Library/Caches/com.postmanlabs.mac", "API / 调试工具", .safe),
            ("Library/Caches/com.github.GitHubDesktop", "开发工具", .safe),
            ("Library/Caches/SentryCrash", "开发工具", .review),
            (".cache/gitlab-runner", "CI/CD", .safe),
            (".tnpm/_cacache", "包管理器", .safe)
        ]
        for (relativePath, _, _) in expected {
            try createAllocatedCache(at: home.appendingPathComponent(relativePath))
        }
        try createAllocatedCache(at: home.appendingPathComponent("Library/Application Support/Postman"))

        let report = CacheScanner.scan(
            projectRoots: [],
            deepScan: false,
            home: home,
            includeSystemCaches: false,
            progress: { _ in },
            environment: [:]
        )
        let items = Dictionary(uniqueKeysWithValues: report.items.map { ($0.path, $0) })
        for (relativePath, category, risk) in expected {
            let item = items[home.appendingPathComponent(relativePath).standardizedFileURL]
            XCTAssertEqual(item?.category, category, relativePath)
            XCTAssertEqual(item?.risk, risk, relativePath)
        }
        XCTAssertFalse(report.items.contains { $0.path == home.appendingPathComponent("Library/Application Support/Postman") })
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
