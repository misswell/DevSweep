import Foundation
import XCTest
@testable import DevSweep

final class DependencyCacheCleanupTests: XCTestCase {
    func testRuleMatchingUsesPackageBoundariesAndCoversFutureVersions() throws {
        let yarn = try XCTUnwrap(DependencyProtectionRule(manager: .yarn, value: " @my-company "))
        XCTAssertTrue(yarn.matches("@my-company/ui", manager: .yarn))
        XCTAssertFalse(yarn.matches("@my-company-tools/ui", manager: .yarn))
        let maven = try XCTUnwrap(DependencyProtectionRule(manager: .maven, value: "com.mycompany"))
        XCTAssertTrue(maven.matches("com.mycompany.tools:sdk", manager: .maven))
        XCTAssertFalse(maven.matches("com.mycompany2:sdk", manager: .maven))
        let exact = try XCTUnwrap(DependencyProtectionRule(manager: .maven, value: "com.mycompany:sdk"))
        XCTAssertTrue(exact.matches("com.mycompany:sdk", manager: .maven))
        XCTAssertFalse(exact.matches("com.mycompany:sdk-extra", manager: .maven))
        XCTAssertNil(DependencyProtectionRule(manager: .yarn, value: "../foo"))
    }

    @MainActor
    func testRulesPersistAndExistingPathWhitelistStillLoads() throws {
        let suite = "DevSweep.DependencyCacheTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let home = try temporaryDirectory()
        defaults.set([], forKey: "DevSweep.projectRoots")
        defaults.set([home.appendingPathComponent("preserved").path], forKey: "DevSweep.whitelistedPaths")
        let rule = try XCTUnwrap(DependencyProtectionRule(manager: .yarn, value: "@my-company"))
        let first = DevSweepStore(defaults: defaults, home: home)
        first.addDependencyProtectionRule(rule)
        first.addDependencyProtectionRule(rule)
        let second = DevSweepStore(defaults: defaults, home: home)
        XCTAssertEqual(second.dependencyProtectionRules, [rule])
        XCTAssertEqual(second.whitelistedPaths.map(\.lastPathComponent), ["preserved"])
        second.removeDependencyProtectionRule(rule)
        XCTAssertTrue(DevSweepStore(defaults: defaults, home: home).dependencyProtectionRules.isEmpty)
    }

    func testMavenCleanupOnlyMovesSelectedRemoteVersions() throws {
        let home = try temporaryDirectory()
        let root = home.appendingPathComponent(".m2/repository")
        let publicVersion = try mavenVersion("org/example/open/1.0", artifact: "open", origin: "central", at: root)
        let privateVersion = try mavenVersion("com/company/sdk/1.0", artifact: "sdk", origin: "corp", at: root)
        let privateNewVersion = try mavenVersion("com/company/sdk/2.0", artifact: "sdk", origin: "corp", at: root)
        let localVersion = try mavenVersion("com/example/here/1.0", artifact: "here", origin: "", at: root)
        let missingTracker = try mavenVersion("org/example/unknown/1.0", artifact: "unknown", origin: nil, at: root)
        let repository = DependencyRepository(manager: .maven, root: root)
        let preview = try DependencyCacheInspector.preview(repository)
        let rule = try XCTUnwrap(DependencyProtectionRule(manager: .maven, value: "com.company"))
        let entries = Dictionary(uniqueKeysWithValues: preview.entries.map { ($0.id, $0) })
        XCTAssertEqual(entries[localVersion.path]?.status, .protected, "\(preview.entries)")
        XCTAssertEqual(entries[missingTracker.path]?.canManuallySelect, false, "\(preview.entries)")
        XCTAssertEqual(entries[publicVersion.path]?.status, .review, "\(preview.entries)")
        let selection = preview.entries
        let context = DeletionContext(whitelistedPaths: [], projectRoots: [], home: home,
                                      allowedPaths: selection.map(\.path))
        let recorder = RecordingTrash()
        let report = DependencyCacheCleaner.clean(preview: preview, entries: selection, includeReview: true,
                                                  rules: [rule], context: context, processes: Activity(),
                                                  trash: recorder)
        XCTAssertEqual(recorder.paths, [publicVersion.path], "\(report.failures.map { ($0.0.reason, $0.1) })")
        XCTAssertEqual(Set(report.failures.map { $0.0.id }),
                       [privateVersion.path, privateNewVersion.path, localVersion.path, missingTracker.path])
    }

    func testNewlyLocalMavenVersionAndRunningProcessesAreRejected() throws {
        let home = try temporaryDirectory()
        let root = home.appendingPathComponent(".m2/repository")
        let target = try mavenVersion("org/example/open/1.0", artifact: "open", origin: "central", at: root)
        let preview = try DependencyCacheInspector.preview(DependencyRepository(manager: .maven, root: root))
        let context = DeletionContext(whitelistedPaths: [], projectRoots: [], home: home, allowedPaths: [target])
        let recorder = RecordingTrash()
        let active = DependencyCacheCleaner.clean(preview: preview, entries: preview.entries, includeReview: true,
                                                  rules: [], context: context, processes: Activity(lines: ["mvn"]),
                                                  trash: recorder)
        XCTAssertEqual(active.failures.count, 1)
        try Data("open-1.0.jar>=\n".utf8).write(to: target.appendingPathComponent("_remote.repositories"))
        let changed = DependencyCacheCleaner.clean(preview: preview, entries: preview.entries, includeReview: true,
                                                   rules: [], context: context, processes: Activity(), trash: recorder)
        XCTAssertEqual(changed.failures.count, 1)
        XCTAssertTrue(recorder.paths.isEmpty)
    }

    func testClassicDoesNotTreatScopedPackagesOnNpmAsPublic() throws {
        let home = try temporaryDirectory()
        let root = home.appendingPathComponent("Library/Caches/Yarn")
        for name in ["@company-private/team-ui", "left-pad"] {
            let pkg = root.appendingPathComponent("v6/npm-\(name.replacingOccurrences(of: "/", with: "-"))-1.0")
                .appendingPathComponent("node_modules/\(name)")
            try FileManager.default.createDirectory(at: pkg, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: ["name": name, "version": "1.0.0"])
                .write(to: pkg.appendingPathComponent("package.json"))
            try JSONSerialization.data(withJSONObject: ["remote": ["type": "tarball",
                "resolved": "https://registry.npmjs.org/\(name)/-/pkg.tgz"]])
                .write(to: pkg.appendingPathComponent(".yarn-metadata.json"))
        }
        let preview = try DependencyCacheInspector.preview(DependencyRepository(manager: .yarn, root: root))
        let entries = Dictionary(uniqueKeysWithValues: preview.entries.map { ($0.name, $0) })
        XCTAssertEqual(entries["@company-private/team-ui"]?.status, .review, "\(preview.entries)")
        XCTAssertEqual(entries["left-pad"]?.status, .cleanable, "\(preview.entries)")
    }

    func testBerryArchiveUsesExactScopeAndRechecksGitIndexAtCleanup() throws {
        let home = try temporaryDirectory()
        let project = home.appendingPathComponent("project")
        let root = project.appendingPathComponent(".yarn/cache")
        let packageDir = project.appendingPathComponent("node_modules/@my-team/test-app")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: packageDir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: packageDir.appendingPathComponent("package.json"))
        try run("/usr/bin/git", ["init", "-q"], at: project)
        let archive = root.appendingPathComponent("@my-team-test-app-npm-1.2.3-a1b2c3d4e5-10c0.zip")
        try run("/usr/bin/zip", ["-q", archive.path, "node_modules/@my-team/test-app/package.json"], at: project)
        let repository = DependencyRepository(manager: .yarn, root: root)
        let preview = try DependencyCacheInspector.preview(repository)
        XCTAssertEqual(preview.entries.first?.package, "@my-team/test-app")
        XCTAssertEqual(preview.entries.first?.version, "1.2.3")
        XCTAssertEqual(preview.entries.first?.status, .review)
        try run("/usr/bin/git", ["add", "-f", "--", archive.path], at: project)
        let recorder = RecordingTrash()
        let context = DeletionContext(whitelistedPaths: [], projectRoots: [project], home: home)
        let result = DependencyCacheCleaner.clean(preview: preview, entries: preview.entries, includeReview: true,
                                                  rules: [], context: context, processes: Activity(), trash: recorder)
        XCTAssertTrue(recorder.paths.isEmpty)
        XCTAssertEqual(result.failures.count, 1)
        let after = try DependencyCacheInspector.preview(repository).entries
        XCTAssertEqual(after.first?.status, .protected, "\(after)")
    }

    func testGeneralCleanupCannotRemoveManagedRootsOrAWhiteListedChild() throws {
        let home = try temporaryDirectory()
        let caches = home.appendingPathComponent("Library/Caches")
        let repo = caches.appendingPathComponent("Yarn")
        let protected = home.appendingPathComponent("unrelated/Private")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: protected, withIntermediateDirectories: true)
        let removableParent = protected.deletingLastPathComponent()
        let paths = [repo, caches, removableParent]
        let context = DeletionContext(whitelistedPaths: [protected], projectRoots: [], home: home,
                                      allowedPaths: paths)
        let items = [
            CacheItem(category: "Test", name: "Yarn", path: repo, size: 1),
            CacheItem(category: "Test", name: "Caches", path: caches, size: 1, kind: .trashContents),
            CacheItem(category: "Test", name: "Parent", path: removableParent, size: 1)
        ]
        let recorder = RecordingTrash()
        let report = CacheCleaner.clean(items, context: context, trashExecutor: recorder)
        XCTAssertTrue(recorder.paths.isEmpty)
        XCTAssertEqual(report.failures.count, 3)
    }

    func testMavenCustomRepositoryFromSettingsIsManaged() throws {
        let home = try temporaryDirectory()
        let config = home.appendingPathComponent(".m2")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try Data("<settings><localRepository>${user.home}/custom/repo</localRepository></settings>".utf8)
            .write(to: config.appendingPathComponent("settings.xml"))
        let custom = home.appendingPathComponent("custom/repo")
        XCTAssertTrue(DependencyRepository.configured(home: home, environment: [:])
            .contains(DependencyRepository(manager: .maven, root: custom)))
    }

    private func mavenVersion(_ relative: String, artifact: String, origin: String?, at root: URL) throws -> URL {
        let folder = root.appendingPathComponent(relative).standardizedFileURL
        let file = artifact + "-" + folder.lastPathComponent + ".jar"
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("jar".utf8).write(to: folder.appendingPathComponent(file))
        if let origin {
            try Data("\(file)>\(origin)=\n".utf8).write(to: folder.appendingPathComponent("_remote.repositories"))
        }
        return folder
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("DevSweepDeps-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func run(_ executable: String, _ arguments: [String], at directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
}

private struct Activity: ProcessInspecting {
    var lines: [String]? = []
    func matchingProcessLines(containing token: String) -> [String]? { lines }
}

private final class RecordingTrash: TrashExecuting {
    var paths = [String]()
    func trash(_ url: URL) throws { paths.append(url.path) }
}
