import XCTest
@testable import DevSweep

/// 常用清理的刷新代价与行顺序。
///
/// 进页面只核对已收藏路径的磁盘占用：目录合并成少量 `du`、可清理项先出现在列表上、
/// `simctl` 与重复进入页面的重测都排在后面；清理自带磁盘核验，因此不等刷新完成。
@MainActor
final class QuickCleanRefreshTests: XCTestCase {
    private var defaultsSuiteName: String?

    override func tearDown() {
        if let suiteName = defaultsSuiteName {
            UserDefaults().removePersistentDomain(forName: suiteName)
            defaultsSuiteName = nil
        }
        super.tearDown()
    }

    // MARK: - Helpers

    /// 只记录调用次数；`hold()` 之后 `devices()` 挂起，用来模拟几十台设备登记时 simctl 还没返回。
    private final class Inspector: SimulatorCleanupInspecting, @unchecked Sendable {
        private let lock = NSLock()
        private var callCount = 0
        private var listed: [SimulatorCleanupDevice] = []
        private var released = true

        var calls: Int { synced { callCount } }
        var listedDevices: [SimulatorCleanupDevice] {
            get { synced { listed } }
            set { lock.lock(); listed = newValue; lock.unlock() }
        }
        func hold() { lock.lock(); released = false; lock.unlock() }
        func release() { lock.lock(); released = true; lock.unlock() }
        private func synced<T>(_ body: () -> T) -> T {
            lock.lock(); defer { lock.unlock() }; return body()
        }

        func devices() throws -> [SimulatorCleanupDevice] {
            lock.lock(); callCount += 1; lock.unlock()
            while !synced({ released }) { usleep(2_000) }
            return listedDevices
        }

        func activityProtection() throws -> String? { nil }
    }

    private func makeStore(home: URL, inspector: Inspector) -> DevSweepStore {
        let suiteName = "DevSweepQuickCleanRefreshTests-\(UUID().uuidString)"
        defaultsSuiteName = suiteName
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return DevSweepStore(defaults: defaults, home: home, simulatorInspector: inspector)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevSweepQuickCleanRefreshTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 写入不可压缩内容，避免文件系统压缩让「按大小排序」断言依赖不真实的占用。
    private func makeAllocatedDirectory(at url: URL, bytes: Int) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: "/dev/urandom"))
        let payload = try XCTUnwrap(handle.read(upToCount: bytes))
        try handle.close()
        try payload.write(to: url.appendingPathComponent("payload.bin"))
    }

    private func directoryEntry(_ url: URL, name: String = "cache") -> QuickCleanEntry {
        QuickCleanEntry(
            path: QuickCleanRegistry.key(for: url), displayName: name,
            category: "其他开发缓存", dateAdded: Date(), targetKind: .directory
        )
    }

    private func simulatorEntry(_ url: URL, udid: String) -> QuickCleanEntry {
        QuickCleanEntry(
            path: QuickCleanRegistry.key(for: url), displayName: "iPhone",
            category: "CoreSimulator", dateAdded: Date(),
            targetKind: .simulatorDevice, identifier: udid
        )
    }

    private func makeDirectoryItem(_ url: URL, name: String) -> CacheItem {
        CacheItem(category: "Node.js 项目", name: name, path: url, size: 1_000)
    }

    private func makeSimulatorItem(_ url: URL, udid: String) -> CacheItem {
        CacheItem(category: "CoreSimulator", name: "iPhone", path: url, size: 1_000,
                  risk: .review, kind: .simulatorDevice, identifier: udid)
    }

    private func simulatorDirectory(in home: URL, udid: String, bytes: Int = 64_000) throws -> URL {
        let path = home.appendingPathComponent("Library/Developer/CoreSimulator/Devices/\(udid)")
        try makeAllocatedDirectory(at: path, bytes: bytes)
        return path
    }

    private func waitUntil(timeout: TimeInterval = 30, _ predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return predicate()
    }

    // MARK: - 快照与条目一一对应

    /// 结果必须与传入条目一一对应、顺序一致：同一路径上的两条条目不能合并成一行。
    func testSnapshotsMatchEntriesOneToOneAndInOrder() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let live = root.appendingPathComponent("live")
        try makeAllocatedDirectory(at: live, bytes: 64_000)

        let snapshots = QuickCleanInspector.snapshots(for: [
            directoryEntry(root.appendingPathComponent("missing"), name: "missing"),
            directoryEntry(live, name: "first"),
            directoryEntry(live, name: "second")
        ])

        XCTAssertEqual(snapshots.count, 3)
        XCTAssertEqual(snapshots.map(\.entry.displayName), ["missing", "first", "second"])
        XCTAssertFalse(snapshots[0].exists)
        XCTAssertEqual(snapshots[0].size, 0)
        XCTAssertFalse(snapshots[0].canClean)
        XCTAssertGreaterThan(snapshots[1].size, 0)
        XCTAssertEqual(snapshots[1].size, snapshots[2].size, "同一目录的两行显示同一个占用")
        XCTAssertTrue(snapshots[2].canClean)
    }

    /// 空安装包仍是精确测量：0 B 不能和「没量到」混为一谈。
    func testEmptyUpdateArchiveMeasuresAsCompleteZero() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent("Library/Caches/orca-updater/update.zip")
        try FileManager.default.createDirectory(at: archive.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data().write(to: archive)

        let entry = QuickCleanEntry(
            path: QuickCleanRegistry.key(for: archive), displayName: "软件更新安装包",
            category: "应用缓存", dateAdded: Date(), targetKind: .updateArchive
        )
        let snapshot = QuickCleanInspector.snapshot(for: entry)

        XCTAssertTrue(snapshot.exists)
        XCTAssertEqual(snapshot.size, 0)
        XCTAssertNil(snapshot.note, "0 B 是量到的结果，不该标成下限")
        XCTAssertTrue(snapshot.canClean)
    }

    // MARK: - 批量测量

    /// 同一次 `du` 会在参数之间对硬链接去重，因此各行相加等于真正可回收的总量；
    /// 逐项起进程会同一个 inode 计入两次。
    func testHardlinkedDirectoriesAreNotCountedTwice() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first")
        let second = root.appendingPathComponent("second")
        try makeAllocatedDirectory(at: first, bytes: 1_000_000)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        let shared = first.appendingPathComponent("payload.bin")
        try FileManager.default.linkItem(at: shared, to: second.appendingPathComponent("payload.bin"))
        try Data(repeating: 0x5A, count: 200_000).write(to: second.appendingPathComponent("own.bin"))

        let solo = StorageMeasurementService.measure(first).allocatedBytes
            + StorageMeasurementService.measure(second).allocatedBytes
        let batched = QuickCleanInspector.snapshots(for: [directoryEntry(first), directoryEntry(second)])
            .reduce(0) { $0 + $1.size }

        XCTAssertGreaterThan(solo, 0)
        XCTAssertGreaterThan(batched, 0)
        XCTAssertLessThan(batched, solo, "分批测量会让共享的磁盘块被重复计入")
    }

    /// 收藏的路径消失时只影响那一行：同批次的其他目录仍拿到精确占用。
    func testMissingEntryOnlyAffectsItsOwnRow() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var entries: [QuickCleanEntry] = []
        var urls: [URL] = []
        for index in 0..<3 {
            let directory = root.appendingPathComponent("cache-\(index)")
            try makeAllocatedDirectory(at: directory, bytes: 64_000)
            urls.append(directory)
            entries.append(directoryEntry(directory, name: "cache-\(index)"))
        }
        let missing = root.appendingPathComponent("cache-gone")
        try FileManager.default.createDirectory(at: missing, withIntermediateDirectories: true)
        entries.append(directoryEntry(missing, name: "gone"))
        try FileManager.default.removeItem(at: missing)

        let snapshots = QuickCleanInspector.snapshots(for: entries)

        XCTAssertEqual(snapshots.count, 4)
        for (index, url) in urls.enumerated() {
            let snapshot = snapshots[index]
            XCTAssertEqual(snapshot.size, StorageMeasurementService.measure(url).allocatedBytes,
                           "批量输出的大小必须配到正确的目录")
            XCTAssertNil(snapshot.note)
            XCTAssertTrue(snapshot.canClean)
        }
        XCTAssertFalse(snapshots[3].exists)
        XCTAssertEqual(snapshots[3].size, 0)
        XCTAssertFalse(snapshots[3].canClean)
    }

    /// 有读不到的子目录时，占用只能标成下限，不能假装是精确值。
    func testUnreadableSubtreeReportsLowerBound() throws {
        try XCTSkipIf(geteuid() == 0, "root 不受目录权限限制，测不到读取失败")
        let root = try makeTemporaryDirectory()
        let sealed = root.appendingPathComponent("sealed")
        try makeAllocatedDirectory(at: root, bytes: 64_000)
        try makeAllocatedDirectory(at: sealed, bytes: 64_000)
        defer {
            chmod(sealed.path, 0o755)
            try? FileManager.default.removeItem(at: root)
        }
        chmod(sealed.path, 0o000)

        let snapshot = QuickCleanInspector.snapshot(for: directoryEntry(root))

        XCTAssertTrue(snapshot.exists)
        XCTAssertGreaterThan(snapshot.size, 0, "读不到的子目录不该把整行清零")
        let note = try XCTUnwrap(snapshot.note)
        XCTAssertTrue(note.contains("可能更大"), note)
        XCTAssertTrue(snapshot.canClean, "占用只是下限不影响清理授权，删除仍走逐次核验")
    }

    // MARK: - 发布顺序

    /// 可清理项先发布，`simctl` 排在后面：登记几十台设备时按钮不用等它跑完。
    func testAutomaticSnapshotsPublishBeforeSimulatorLookup() throws {
        let home = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let udid = UUID().uuidString
        let device = try simulatorDirectory(in: home, udid: udid)
        let cache = home.appendingPathComponent("Library/Caches/pkg")
        try makeAllocatedDirectory(at: cache, bytes: 64_000)
        let inspector = Inspector()
        inspector.listedDevices = [
            SimulatorCleanupDevice(udid: udid, name: "iPhone", state: "Shutdown",
                                   dataPath: device.appendingPathComponent("data").path)
        ]

        var publishes: [[String]] = []
        let snapshots = QuickCleanInspector.snapshots(
            for: [directoryEntry(cache, name: "pkg"), simulatorEntry(device, udid: udid)],
            home: home,
            simulatorInspector: inspector
        ) { publishes.append($0.map(\.entry.displayName)) }

        XCTAssertEqual(publishes.first, ["pkg"], "模拟器状态不该挡在可清理项前面")
        XCTAssertEqual(snapshots.map(\.entry.displayName), ["pkg", "iPhone"])
        XCTAssertEqual(inspector.calls, 1, "一次刷新只查询一遍设备登记")
        XCTAssertTrue(snapshots[1].canClean)
    }

    // MARK: - 行顺序

    /// 默认按占用大小排序：大的在前，没量到的行排在最后，整列表不会反复跳动。
    func testRowsSortBySizeWithUnmeasuredRowLast() throws {
        let home = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let inspector = Inspector()
        inspector.hold()
        defer { inspector.release() }
        let store = makeStore(home: home, inspector: inspector)

        let big = home.appendingPathComponent("Library/Caches/big")
        try makeAllocatedDirectory(at: big, bytes: 2_000_000)
        let small = home.appendingPathComponent("Library/Caches/small")
        try makeAllocatedDirectory(at: small, bytes: 128_000)
        let udid = UUID().uuidString
        let device = try simulatorDirectory(in: home, udid: udid, bytes: 512_000)
        let gone = home.appendingPathComponent("Library/Caches/gone")
        try makeAllocatedDirectory(at: gone, bytes: 64_000)

        XCTAssertEqual(store.addToQuickClean([makeDirectoryItem(big, name: "big")]).added, 1)
        XCTAssertEqual(store.addToQuickClean([makeDirectoryItem(small, name: "small")]).added, 1)
        XCTAssertEqual(store.addToQuickClean([makeSimulatorItem(device, udid: udid)]).added, 1)
        XCTAssertEqual(store.addToQuickClean([makeDirectoryItem(gone, name: "gone")]).added, 1)
        try FileManager.default.removeItem(at: gone)

        // simctl 还卡着，但已量过的行已经按占用排好，未量到的模拟器行垫底。
        XCTAssertTrue(waitUntil {
            store.quickCleanRows.allSatisfy { $0.entry.isSimulator || $0.snapshot != nil }
        }, "刷新中途也应把可清理项先排出来")
        let held = store.quickCleanRows
        XCTAssertEqual(held.map(\.entry.displayName), ["big", "small", "gone", "iPhone"])
        XCTAssertNil(held.last?.snapshot, "还没量到的行不能被当成 0 B 混进中间")

        inspector.release()
        XCTAssertTrue(waitUntil { !store.isRefreshingQuickClean })
        XCTAssertEqual(store.quickCleanRows.map(\.entry.displayName), ["big", "iPhone", "small", "gone"],
                       "模拟器行量完后要回到它真实的大小位置")

        store.setQuickCleanSort(.dateAdded)
        XCTAssertEqual(store.quickCleanRows.map(\.entry.displayName), ["gone", "iPhone", "small", "big"],
                       "按加入时间时最新的在前，与占用无关")
    }

    /// 排序方式是用户的选择，必须跨启动保留；默认按大小。
    func testSortModeDefaultsToSizeAndPersists() throws {
        let home = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = makeStore(home: home, inspector: Inspector())
        XCTAssertEqual(store.quickCleanSort, .size)

        store.setQuickCleanSort(.dateAdded)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: XCTUnwrap(defaultsSuiteName)))
        XCTAssertEqual(DevSweepStore(defaults: defaults, home: home).quickCleanSort, .dateAdded)
    }

    // MARK: - 进入页面的节流

    /// 反复切换侧边栏不该每次都重新遍历上百棵真实目录树。
    func testEnteringPageAgainWithinThrottleSkipsRemeasurement() throws {
        let home = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let inspector = Inspector()
        let store = makeStore(home: home, inspector: inspector)
        let cache = home.appendingPathComponent("Library/Caches/pkg")
        try makeAllocatedDirectory(at: cache, bytes: 64_000)
        let udid = UUID().uuidString
        let device = try simulatorDirectory(in: home, udid: udid)

        XCTAssertEqual(store.addToQuickClean([
            makeDirectoryItem(cache, name: "pkg"), makeSimulatorItem(device, udid: udid)
        ]).added, 2)
        XCTAssertTrue(waitUntil { !store.isRefreshingQuickClean })
        XCTAssertEqual(inspector.calls, 1)
        XCTAssertEqual(store.quickCleanRows.count, 2)

        store.refreshQuickCleanSnapshots()
        XCTAssertEqual(inspector.calls, 1, "节流窗口内重复进页面不再查询设备")
        XCTAssertFalse(store.isRefreshingQuickClean)
        XCTAssertEqual(store.quickCleanRows.filter { $0.snapshot == nil }.count, 0,
                       "跳过重测时保留上一次的数量，不退回「检查中…」")

        store.refreshQuickCleanSnapshots(force: true)
        XCTAssertTrue(waitUntil { inspector.calls == 2 && !store.isRefreshingQuickClean })
    }

    // MARK: - 清理不等刷新

    /// 刷新只是核对磁盘占用；清理自己会在删除前重新核验，因此不必等刷新跑完。
    func testCleanupRunsWhileRefreshStillWaitsForSimctl() throws {
        let home = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let inspector = Inspector()
        inspector.hold()
        defer { inspector.release() }
        let store = makeStore(home: home, inspector: inspector)
        let cache = home.appendingPathComponent("Library/Caches/pkg")
        try makeAllocatedDirectory(at: cache, bytes: 64_000)
        let udid = UUID().uuidString
        let device = try simulatorDirectory(in: home, udid: udid)
        let vanished = home.appendingPathComponent("Library/Caches/vanished")
        try makeAllocatedDirectory(at: vanished, bytes: 64_000)

        XCTAssertEqual(store.addToQuickClean([
            makeDirectoryItem(cache, name: "pkg"), makeSimulatorItem(device, udid: udid),
            makeDirectoryItem(vanished, name: "vanished")
        ]).added, 3)
        try FileManager.default.removeItem(at: vanished)

        XCTAssertTrue(waitUntil { !store.cleanableQuickCleanSnapshots.isEmpty })
        XCTAssertTrue(store.isRefreshingQuickClean, "前提：simctl 仍未返回")
        let row = try XCTUnwrap(store.quickCleanRows.first { $0.entry.displayName == "pkg" })
        XCTAssertTrue(try XCTUnwrap(row.snapshot).canClean, "刷新进行中的行就该能点")

        let entry = try XCTUnwrap(store.quickCleanEntries.first { $0.displayName == "vanished" })
        store.cleanQuickClean([entry])
        XCTAssertTrue(waitUntil { store.statusMessage.contains("没有需要清理") },
                      "清理不能因为刷新进行中就被吞掉：\(store.statusMessage)")
        XCTAssertFalse(store.isCleaning)
        XCTAssertTrue(store.isRefreshingQuickClean, "清理不该把还在进行的刷新挤掉")

        inspector.release()
        XCTAssertTrue(waitUntil { !store.isRefreshingQuickClean })
        XCTAssertEqual(store.quickCleanRows.count, 3)
        XCTAssertTrue(store.quickCleanRows.allSatisfy { $0.snapshot != nil },
                      "过期刷新的发布必须丢弃，行数与快照保持一致")
    }
}
