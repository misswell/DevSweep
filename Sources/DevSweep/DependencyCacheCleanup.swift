import Foundation

struct DependencyCacheCleanupReport {
    var removed: [DependencyCacheEntry] = []
    var failures: [(DependencyCacheEntry, String)] = []
}

enum DependencyCacheCleaner {
    static func clean(preview: DependencyCachePreview, entries: [DependencyCacheEntry],
                      includeReview: Bool, rules: [DependencyProtectionRule], context: DeletionContext,
                      processes: ProcessInspecting = ProcessInspector(),
                      gitRunner: ProcessRunning = ProcessRunner.shared,
                      trash: TrashExecuting = FileManagerTrashExecutor()) -> DependencyCacheCleanupReport {
        let repository = preview.repository
        let pattern = repository.manager == .maven
            ? #"(org[.]codehaus[.]plexus[.]classworlds|org[.]apache[.]maven|(^|[ /])(mvn|mvnw|mvnd)([[:space:]]|$))"#
            : #"(^|[ /])(yarn([.]js|[.]cjs)?|yarn-[^ /]+[.]cjs|yarnpkg)([[:space:]]|$)|corepack.*[[:space:]]yarn"#
        func isIdle() -> Bool {
            processes.matchingProcessLines(containing: pattern)?.isEmpty == true
        }
        guard isIdle() else {
            return rejected(entries, because: DependencyCacheError.active)
        }

        let verified = Dictionary(uniqueKeysWithValues: preview.entries.map { ($0.id, $0) })
        var git = GitCacheProtection.read(at: repository.root, runner: gitRunner)
        var nextActivityCheck = DispatchTime.now() + .seconds(2)
        var stillIdle = true
        var report = DependencyCacheCleanupReport()
        var handled = Set<String>()
        for entry in entries where handled.insert(entry.id).inserted {
            do {
                if stillIdle, DispatchTime.now() >= nextActivityCheck {
                    stillIdle = isIdle()
                    if stillIdle { git = GitCacheProtection.read(at: repository.root, runner: gitRunner) }
                    nextActivityCheck = .now() + .seconds(2)
                }
                guard stillIdle else { throw DependencyCacheError.active }
                guard DependencyFile.hasUnredirectedPath(repository.root),
                      FileIdentity.capture(repository.root) == preview.rootIdentity,
                      verified[entry.id] == entry, let stamp = entry.stamp,
                      stamp.identity.device == preview.rootIdentity.device else {
                    throw DependencyCacheError.changed
                }
                guard canSelect(entry, repository: repository, includeReview: includeReview,
                                rules: rules, paths: context.whitelistedPaths) else {
                    throw DependencyCacheError.protected
                }
                let current = DependencyCacheInspector.inspect(URL(fileURLWithPath: entry.path.path),
                                                               repository: repository, git: git, measure: false)
                guard current.package == entry.package, current.version == entry.version, current.stamp == stamp,
                      current.status == entry.status, current.reason == entry.reason,
                      canSelect(current, repository: repository, includeReview: includeReview,
                                rules: rules, paths: context.whitelistedPaths) else {
                    throw DependencyCacheError.changed
                }

                let item = CacheItem(category: repository.category, name: entry.name, path: entry.path,
                                     size: entry.size, risk: .review, expectedFileIdentity: stamp.identity)
                try DeletionValidator.validateDependencyPackage(item: item, repository: repository, context: context)
                try trash.trash(entry.path)
                report.removed.append(entry)
            } catch {
                report.failures.append((entry, error.localizedDescription))
            }
        }
        return report
    }

    static func canSelect(_ entry: DependencyCacheEntry, repository: DependencyRepository, includeReview: Bool,
                          rules: [DependencyProtectionRule], paths: [URL]) -> Bool {
        switch entry.status(in: repository, rules: rules, paths: paths) {
        case .cleanable: return true
        case .review: return includeReview && entry.canManuallySelect
        case .protected: return false
        }
    }

    private static func rejected(_ entries: [DependencyCacheEntry], because error: Error) -> DependencyCacheCleanupReport {
        DependencyCacheCleanupReport(failures: entries.map { ($0, error.localizedDescription) })
    }
}
