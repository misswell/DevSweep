import XCTest
@testable import DevSweep

@MainActor
final class QuickCleanAndStoreRulesTests: XCTestCase {
    private var defaultsSuiteName: String?

    override func tearDown() {
        if let suiteName = defaultsSuiteName {
            UserDefaults().removePersistentDomain(forName: suiteName)
            defaultsSuiteName = nil
        }
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeStore() -> DevSweepStore {
        let suiteName = "DevSweepTests-\(UUID().uuidString)"
        defaultsSuiteName = suiteName
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return DevSweepStore(defaults: defaults)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevSweepQuickCleanTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeCacheItem(
        name: String,
        path: URL,
        risk: RiskLevel = .safe,
        kind: CleanupKind = .trash,
        isSelected: Bool? = false
    ) -> CacheItem {
        CacheItem(
            category: "Node.js 项目",
            name: name,
            path: path,
            size: 1_000,
            risk: risk,
            kind: kind,
            isSelected: isSelected
        )
    }

    private func makeReport(_ items: [CacheItem]) -> ScanReport {
        ScanReport(
            scannedRoots: [],
            items: items,
            checkedPaths: 0,
            matchedPaths: items.count,
            skippedPaths: 0,
            permissionFailures: 0,
            diagnostics: [],
            duration: 0
        )
    }

    private func makeAllocatedDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("cache-payload".utf8).write(to: url.appendingPathComponent("payload.bin"))
    }

    // MARK: - 常用清理：登记与显示

    /// 场景 1：普通扫描项加入常用清理后仍出现在列表。
    func testAddToQuickCleanKeepsItemInScanList() throws {
        let store = makeStore()
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let item = makeCacheItem(name: "node_modules", path: directory)

        store.applyScanResult(makeReport([item]))
        store.addToQuickClean([item])

        XCTAssertEqual(store.items.map(\.id), [item.id])
        XCTAssertEqual(store.quickCleanEntries.count, 1)
    }

    /// 场景 2：加入后 Row 可以查询到 Quick Clean 状态。
    func testItemReportsQuickCleanStateAfterAdding() throws {
        let store = makeStore()
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let item = makeCacheItem(name: "node_modules", path: directory)

        store.applyScanResult(makeReport([item]))
        XCTAssertFalse(store.isQuickClean(item))
        store.addToQuickClean([item])
        XCTAssertTrue(store.isQuickClean(item))
    }

    /// 场景 3：重启 Store 后 Quick Clean 配置仍存在。
    func testQuickCleanEntriesSurviveStoreRestart() throws {
        let suiteName = "DevSweepTests-\(UUID().uuidString)"
        defaultsSuiteName = suiteName
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let firstStore = DevSweepStore(defaults: defaults)
        let item = makeCacheItem(name: "target", path: directory)
        firstStore.addToQuickClean([item])

        let secondStore = DevSweepStore(defaults: defaults)
        XCTAssertEqual(secondStore.quickCleanEntries.count, 1)
        XCTAssertEqual(secondStore.quickCleanEntries.first?.path, QuickCleanRegistry.key(for: directory))
    }

    /// 场景 4 + 5：路径不存在时配置仍保留；路径重新生成后能再次识别。
    func testMissingPathKeepsEntryAndRegeneratedPathIsDetectedAgain() throws {
        let directory = try makeTemporaryDirectory()
        let entry = QuickCleanEntry(
            path: QuickCleanRegistry.key(for: directory),
            displayName: "node_modules",
            category: "Node.js 项目",
            dateAdded: Date()
        )

        try FileManager.default.removeItem(at: directory)
        var snapshot = QuickCleanInspector.snapshot(for: entry)
        XCTAssertFalse(snapshot.exists)
        XCTAssertEqual(snapshot.size, 0)

        try makeAllocatedDirectory(at: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        snapshot = QuickCleanInspector.snapshot(for: entry)
        XCTAssertTrue(snapshot.exists)
        XCTAssertGreaterThan(snapshot.size, 0)
    }

    /// 场景 6/7/8：Docker、toolCommand、manual 都不能进入常用清理。
    func testQuickCleanRejectsDockerToolCommandAndManual() throws {
        let store = makeStore()

        let dockerItem = makeCacheItem(name: "docker", path: URL(fileURLWithPath: "/tmp/devsweep-docker"), kind: .dockerPrune)
        let toolItem = makeCacheItem(name: "tool", path: URL(fileURLWithPath: "/tmp/devsweep-tool"), kind: .toolCommand)
        let manualItem = makeCacheItem(name: "manual", path: URL(fileURLWithPath: "/tmp/devsweep-manual"), risk: .manual)

        let result = store.addToQuickClean([dockerItem, toolItem, manualItem])
        XCTAssertEqual(result.added, 0)
        XCTAssertEqual(result.rejected, 3)
        XCTAssertTrue(store.quickCleanEntries.isEmpty)
    }

    /// 普通数据库等未识别文件不能进入常用清理。
    func testQuickCleanRejectsPlainFiles() throws {
        let store = makeStore()
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("logs.sqlite")
        try Data("db".utf8).write(to: file)

        let item = makeCacheItem(name: "log db", path: file)
        let result = store.addToQuickClean([item])

        XCTAssertEqual(result.added, 0)
        XCTAssertTrue(store.quickCleanEntries.isEmpty)
        XCTAssertThrowsError(try DeletionValidator.validateQuickCleanRegistration(path: file))
    }

    func testUpdateArchivesCanJoinQuickCleanAndBeExecutedAfterRegeneration() throws {
        let store = makeStore()
        let home = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let updater = home.appendingPathComponent("Library/Caches/xiaomi-mimo-desktop-updater")
        let files = [updater.appendingPathComponent("update.zip"), updater.appendingPathComponent("pending/app-1.2.3-arm64-mac.zip")]
        for file in files {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 0xA5, count: 1_100_000).write(to: file)
        }
        let report = CacheScanner.scan(
            projectRoots: [], deepScan: false, home: home, includeSystemCaches: false,
            progress: { _ in }, environment: [:]
        )
        let archives = report.items.filter { files.contains($0.path) }
        XCTAssertEqual(archives.count, 2)
        store.applyScanResult(report)
        for item in archives {
            let result = store.addToQuickClean([item])
            XCTAssertEqual(result.added, 1, item.path.lastPathComponent)
            XCTAssertTrue(store.isQuickClean(item), item.path.lastPathComponent)
        }
        XCTAssertEqual(QuickCleanInspector.executableItems(for: store.quickCleanEntries).count, 2)
        let entry = try XCTUnwrap(store.quickCleanEntries.first)
        let file = URL(fileURLWithPath: entry.path)
        try FileManager.default.removeItem(at: file)
        XCTAssertFalse(QuickCleanInspector.snapshot(for: entry).exists)
        try Data("new installer".utf8).write(to: file)
        let executable = QuickCleanInspector.executableItems(for: [entry])
        XCTAssertEqual(executable.count, 1)
        XCTAssertEqual(executable.first?.expectedFileIdentity, FileIdentity.capture(file))
        try DeletionValidator.validate(item: XCTUnwrap(executable.first), context: DeletionContext(
            whitelistedPaths: [], projectRoots: [], allowedPaths: [file]
        ))
        XCTAssertThrowsError(try DeletionValidator.validate(item: XCTUnwrap(executable.first), context: DeletionContext(
            whitelistedPaths: [file], projectRoots: [], allowedPaths: [file]
        )))
        let defaults = try XCTUnwrap(UserDefaults(suiteName: XCTUnwrap(defaultsSuiteName)))
        let restarted = DevSweepStore(defaults: defaults)
        XCTAssertEqual(restarted.quickCleanEntries.count, 2)
        XCTAssertTrue(restarted.quickCleanEntries.allSatisfy(\.isUpdateArchive))
        XCTAssertEqual(QuickCleanInspector.executableItems(for: restarted.quickCleanEntries).count, 2)
    }

    func testArchiveAuthorizationRejectsTypeChangesSymlinksAndUnrelatedFiles() throws {
        let store = makeStore()
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = directory.appendingPathComponent("update.zip")
        try Data("installer".utf8).write(to: archive)
        let item = CacheItem(category: "应用缓存", name: "软件更新安装包", path: archive, size: 9, risk: .review)
        XCTAssertEqual(store.addToQuickClean([item]).added, 1)
        let entry = try XCTUnwrap(store.quickCleanEntries.first)

        // 相同路径若被替换成目录，不能扩大原来的文件授权。
        try FileManager.default.removeItem(at: archive)
        try makeAllocatedDirectory(at: archive)
        let secondSuite = "DevSweepTypeChange-\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: secondSuite) }
        let secondStore = DevSweepStore(defaults: UserDefaults(suiteName: secondSuite)!)
        XCTAssertEqual(secondStore.addToQuickClean([item]).added, 0)
        XCTAssertFalse(QuickCleanInspector.snapshot(for: entry).exists)
        XCTAssertTrue(QuickCleanInspector.executableItems(for: [entry]).isEmpty)
        try FileManager.default.removeItem(at: archive)
        let unrelated = directory.appendingPathComponent("customer.zip")
        try Data("user data".utf8).write(to: unrelated)
        try FileManager.default.createSymbolicLink(at: archive, withDestinationURL: unrelated)
        XCTAssertFalse(QuickCleanInspector.snapshot(for: entry).exists)
        XCTAssertTrue(QuickCleanInspector.executableItems(for: [entry]).isEmpty)
        XCTAssertEqual(store.addToQuickClean([CacheItem(
            category: "应用缓存", name: "软件更新安装包", path: unrelated, size: 9, risk: .review
        )]).added, 0)
        store.addToWhitelist([item])
        XCTAssertTrue(store.quickCleanEntries.isEmpty)
    }

    func testLegacyQuickCleanConfigurationRemainsDirectoryOnly() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let entry = QuickCleanEntry(path: directory.path, displayName: "cache", category: "应用缓存", dateAdded: Date())
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(QuickCleanEntry.self, from: data)
        XCTAssertNil(decoded.targetKind)
        XCTAssertEqual(QuickCleanInspector.executableItems(for: [decoded]).count, 1)
        try FileManager.default.removeItem(at: directory)
        try Data("replacement file".utf8).write(to: directory)
        XCTAssertFalse(QuickCleanInspector.snapshot(for: decoded).exists)
        XCTAssertTrue(QuickCleanInspector.executableItems(for: [decoded]).isEmpty)
    }

    // MARK: - 常用清理与白名单互斥

    /// 场景 10 + 11：Quick Clean 与 whitelist 不能共存；加入白名单后自动退出常用清理。
    func testAddingWhitelistRemovesQuickCleanAutomatically() throws {
        let store = makeStore()
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let item = makeCacheItem(name: "target", path: directory)

        store.addToQuickClean([item])
        XCTAssertEqual(store.quickCleanEntries.count, 1)

        store.addToWhitelist([item])
        XCTAssertTrue(store.quickCleanEntries.isEmpty, "白名单保护优先于清理授权，必须自动退出常用清理")
        XCTAssertTrue(store.whitelistedPaths.contains(URL(fileURLWithPath: QuickCleanRegistry.key(for: directory))))
    }

    func testWhitelistedPathCannotJoinQuickClean() throws {
        let store = makeStore()
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let item = makeCacheItem(name: "target", path: directory)

        store.addToWhitelist([item])
        let result = store.addToQuickClean([item])

        XCTAssertEqual(result.added, 0)
        XCTAssertTrue(store.quickCleanEntries.isEmpty)
    }

    // MARK: - 白名单即时生效

    /// 场景 12：whitelist 加入后立即从 items 消失，不重新扫描。
    func testWhitelistRemovesItemFromListImmediately() throws {
        let store = makeStore()
        let item = makeCacheItem(name: "target", path: URL(fileURLWithPath: "/tmp/devsweep-project/target"))

        store.applyScanResult(makeReport([item]))
        store.addToWhitelist([item])

        XCTAssertTrue(store.items.isEmpty)
        XCTAssertEqual(store.lastReport?.items.count, 1, "原始扫描报告应保留")
    }

    /// 场景 13：whitelist 加入后 selectionStates 被清理，不会在移出后自动恢复勾选。
    func testWhitelistClearsSelectionMemory() throws {
        let store = makeStore()
        let item = makeCacheItem(name: "node_modules", path: URL(fileURLWithPath: "/tmp/devsweep-project/node_modules"))

        store.applyScanResult(makeReport([item]))
        store.setSelected(item.id, selected: true)
        store.addToWhitelist([item])
        store.removeFromWhitelist(item.path)

        XCTAssertEqual(store.items.map(\.id), [item.id])
        XCTAssertFalse(store.items[0].isSelected, "旧的选择意图应随白名单作废")
    }

    /// 场景 14：移出 whitelist 不触发完整 Scanner，也能从 rawScanItems 恢复。
    func testRemoveFromWhitelistRestoresRawScanItemsWithoutScanning() throws {
        let store = makeStore()
        let item = makeCacheItem(name: "target", path: URL(fileURLWithPath: "/tmp/devsweep-project/target"))

        store.applyScanResult(makeReport([item]))
        store.addToWhitelist([item])
        XCTAssertTrue(store.items.isEmpty)

        store.removeFromWhitelist(item.path)

        XCTAssertEqual(store.items.map(\.id), [item.id])
        XCTAssertFalse(store.isScanning)
    }

    // MARK: - 全选当前显示

    /// 场景 15 + 16：全选当前显示只影响传入的 visible item ids，过滤掉的项目不被修改。
    func testVisibleSelectionOnlyTouchesGivenIDs() throws {
        let store = makeStore()
        let first = makeCacheItem(name: "a", path: URL(fileURLWithPath: "/tmp/devsweep-a"))
        let second = makeCacheItem(name: "b", path: URL(fileURLWithPath: "/tmp/devsweep-b"))
        let third = makeCacheItem(name: "c", path: URL(fileURLWithPath: "/tmp/devsweep-c"))

        store.applyScanResult(makeReport([first, second, third]))
        // 模拟「只看已选 / 大于 1GB」过滤后只看到 first 和 second。
        store.setVisibleSelected([first, second], selected: true)

        XCTAssertTrue(store.items.first { $0.id == first.id }!.isSelected)
        XCTAssertTrue(store.items.first { $0.id == second.id }!.isSelected)
        XCTAssertFalse(store.items.first { $0.id == third.id }!.isSelected)
    }

    /// 场景 17：普通模式与 Mini 模式使用同一个 selectedCleanupItems。
    func testSelectedCleanupItemsIsTheSingleSource() throws {
        let store = makeStore()
        let selectedSafe = makeCacheItem(name: "safe", path: URL(fileURLWithPath: "/tmp/devsweep-safe"), isSelected: true)
        let unselected = makeCacheItem(name: "review", path: URL(fileURLWithPath: "/tmp/devsweep-review"), risk: .review, isSelected: false)
        let manual = makeCacheItem(name: "manual", path: URL(fileURLWithPath: "/tmp/devsweep-manual"), risk: .manual, isSelected: true)

        store.applyScanResult(makeReport([selectedSafe, unselected, manual]))

        XCTAssertEqual(
            store.selectedCleanupItems.map(\.id),
            [selectedSafe.id],
            "Mini 与普通模式都从这里取清理范围，manual 即使被标记选中也不是候选"
        )
    }

    // MARK: - QuickCleanRegistry 父子路径

    /// 场景 18：Quick Clean parent/child 不会重复登记、重复删除。
    func testParentChildPathsAreDeduplicated() throws {
        let store = makeStore()
        let parent = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let child = parent.appendingPathComponent("debug")
        try makeAllocatedDirectory(at: child)
        defer { try? FileManager.default.removeItem(at: child) }

        let parentItem = makeCacheItem(name: "target", path: parent)
        let childItem = makeCacheItem(name: "debug", path: child)
        store.addToQuickClean([parentItem, childItem])

        XCTAssertEqual(store.quickCleanEntries.count, 1, "父目录已登记时子目录不再登记")
        XCTAssertEqual(store.quickCleanEntries.first?.id, QuickCleanRegistry.key(for: parent))
    }

    // MARK: - 删除安全

    /// 场景 19：Quick Clean 对 symlink 拒绝。
    func testQuickCleanRejectsSymbolicLinks() throws {
        let target = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: target) }
        let link = target.deletingLastPathComponent().appendingPathComponent("devsweep-link-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        defer { try? FileManager.default.removeItem(at: link) }

        XCTAssertThrowsError(try DeletionValidator.validateQuickCleanRegistration(path: link))

        let entry = QuickCleanEntry(
            path: QuickCleanRegistry.key(for: link),
            displayName: "link",
            category: "其他开发缓存",
            dateAdded: Date()
        )
        let snapshot = QuickCleanInspector.snapshot(for: entry)
        XCTAssertFalse(snapshot.exists, "符号链接不能作为可清理目标出现")
        XCTAssertTrue(QuickCleanInspector.executableItems(for: [entry]).isEmpty)
    }

    /// 场景 20：Quick Clean 对 protected path 拒绝。
    func testQuickCleanRejectsProtectedPaths() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let protectedPath = home.appendingPathComponent("Documents")

        XCTAssertThrowsError(try DeletionValidator.validateQuickCleanRegistration(path: protectedPath)) { error in
            XCTAssertEqual(error as? DeletionValidationError, .protectedPath)
        }
    }

    /// 场景 21：whitelist 在删除时仍然拥有最高优先级（含 Quick Clean 的 allowedPaths 授权）。
    func testWhitelistStillWinsDuringDeletion() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("cache")
        try makeAllocatedDirectory(at: cache)

        let item = makeCacheItem(name: "cache", path: cache)
        let context = DeletionContext(
            whitelistedPaths: [cache],
            projectRoots: [root],
            allowedPaths: [cache]
        )

        XCTAssertThrowsError(try DeletionValidator.validate(item: item, context: context)) { error in
            XCTAssertEqual(error as? DeletionValidationError, .whitelisted)
        }
    }

    // MARK: - 清理后的状态

    /// 场景 22：Quick Clean 删除以后 Entry 不消失。
    func testQuickCleanEntrySurvivesAfterCleanup() throws {
        let store = makeStore()
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let item = makeCacheItem(name: "node_modules", path: directory)

        store.applyScanResult(makeReport([item]))
        store.addToQuickClean([item])
        store.applyQuickCleanCleanupResult(CleanupReport(removed: [item], failures: []))

        XCTAssertEqual(store.quickCleanEntries.count, 1, "常用清理配置必须保留，等待目录重新生成")
    }

    /// 场景 23：Quick Clean 删除以后 Snapshot 变成无内容。
    func testSnapshotBecomesEmptyAfterCleanup() throws {
        let directory = try makeTemporaryDirectory()
        let entry = QuickCleanEntry(
            path: QuickCleanRegistry.key(for: directory),
            displayName: "node_modules",
            category: "Node.js 项目",
            dateAdded: Date()
        )

        try FileManager.default.removeItem(at: directory)
        let snapshot = QuickCleanInspector.snapshot(for: entry)

        XCTAssertFalse(snapshot.exists)
        XCTAssertEqual(snapshot.size, 0)
        XCTAssertNil(snapshot.fileIdentity)
    }

    /// 场景 24：清理成功后 rawScanItems 同路径项目消失。
    func testRawScanItemsDropCleanedPaths() throws {
        let store = makeStore()
        let removedItem = makeCacheItem(name: "removed", path: URL(fileURLWithPath: "/tmp/devsweep-removed"))
        let keptItem = makeCacheItem(name: "kept", path: URL(fileURLWithPath: "/tmp/devsweep-kept"))

        store.applyScanResult(makeReport([removedItem, keptItem]))
        store.applyQuickCleanCleanupResult(CleanupReport(removed: [removedItem], failures: []))

        XCTAssertEqual(store.items.map(\.id), [keptItem.id])
    }

    /// 场景 25：重新扫描后 Quick Clean badge 自动恢复。
    func testQuickCleanBadgeRestoredAfterRescan() throws {
        let store = makeStore()
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = makeCacheItem(name: "node_modules", path: directory)

        store.applyScanResult(makeReport([original]))
        store.addToQuickClean([original])

        // CacheItem.id 是 UUID，每次扫描都会变化；重新扫描后是新对象。
        let rescanned = makeCacheItem(name: "node_modules", path: directory)
        XCTAssertNotEqual(rescanned.id, original.id)
        store.applyScanResult(makeReport([rescanned]))

        XCTAssertTrue(store.isQuickClean(rescanned), "重新扫描后同一路径应自动显示常用清理标识")
    }

    // MARK: - 一键清理执行条目

    func testExecutableItemsRequireLiveDirectories() throws {
        let directory = try makeTemporaryDirectory()
        let missingEntry = QuickCleanEntry(
            path: QuickCleanRegistry.key(for: directory.appendingPathComponent("missing")),
            displayName: "missing",
            category: "其他开发缓存",
            dateAdded: Date()
        )

        try makeAllocatedDirectory(at: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let liveEntry = QuickCleanEntry(
            path: QuickCleanRegistry.key(for: directory),
            displayName: "live",
            category: "其他开发缓存",
            dateAdded: Date()
        )

        let executable = QuickCleanInspector.executableItems(for: [missingEntry, liveEntry])

        XCTAssertEqual(executable.count, 1)
        XCTAssertEqual(executable.first?.path, URL(fileURLWithPath: liveEntry.id))
        XCTAssertNotNil(executable.first?.expectedFileIdentity, "expectedFileIdentity 必须是执行前刚刚捕获的")
        XCTAssertEqual(executable.first?.kind, .trash)
    }
}
