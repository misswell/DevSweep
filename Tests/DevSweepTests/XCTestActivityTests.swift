import Foundation
import XCTest
@testable import DevSweep

/// XCTestDevices 识别、状态判定与删除安全的完整链路测试：
/// 进程检测 → 扫描风险状态 → 勾选 → 删除前二次确认（TOCTOU）→ 批量事务。
final class XCTestActivityTests: XCTestCase {
    private let fileManager = FileManager.default

    // MARK: - Fakes

    private final class FakeXCTestActivityInspector: XCTestActivityInspecting {
        var state: XCTestActivityState
        private(set) var callCount = 0

        init(state: XCTestActivityState) {
            self.state = state
        }

        func currentState() -> XCTestActivityState {
            callCount += 1
            return state
        }
    }

    private final class StubProcessRunner: ProcessRunning {
        enum Behavior {
            case launchFailed
            case timedOut
            case errorStatus(Int32)
            case invalidUTF8Output
            case success(String)
        }

        let behavior: Behavior

        init(behavior: Behavior) {
            self.behavior = behavior
        }

        func run(
            executable: URL,
            arguments: [String],
            environment: [String: String]?,
            timeout: TimeInterval
        ) -> ProcessResult? {
            switch behavior {
            case .launchFailed:
                return nil
            case .timedOut:
                return ProcessResult(status: 0, stdout: Data(), stderr: Data(), timedOut: true)
            case .errorStatus(let status):
                return ProcessResult(
                    status: status,
                    stdout: Data(),
                    stderr: Data("ps: illegal option".utf8),
                    timedOut: false
                )
            case .invalidUTF8Output:
                return ProcessResult(status: 0, stdout: Data([0xFF, 0xFE, 0xFC]), stderr: Data(), timedOut: false)
            case .success(let output):
                return ProcessResult(status: 0, stdout: Data(output.utf8), stderr: Data(), timedOut: false)
            }
        }
    }

    /// 不把测试产物移动到真实废纸篓；记录被清理的路径并删除文件。
    private final class TrashSpy: TrashExecuting {
        private(set) var trashedPaths: [URL] = []

        func trash(_ url: URL) throws {
            trashedPaths.append(url)
            try FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - 进程检测（ps 快照分析）

    func testIdleProcessListWithoutXCTestProcessesReportsIdle() {
        let processList = [
            "  731 /Applications/Safari.app/Contents/MacOS/Safari",
            "  999 /bin/ps -axo pid=,command=",
            " 1200 /Applications/Xcode.app/Contents/MacOS/Xcode",
            " 1300 tail -f /Users/dev/Library/Developer/XCTestDevices/07104F4C-1234-1234-1234-123456789ABC/info.plist",
            " 1400 xcodebuild -project /Users/dev/Demo/Demo.xcodeproj -showBuildSettings"
        ].joined(separator: "\n")

        let inspector = XCTestActivityInspector(
            processRunner: StubProcessRunner(behavior: .success(processList))
        )
        XCTAssertEqual(inspector.currentState(), .idle)
        XCTAssertEqual(XCTestActivityInspector.analyze(processList: processList), .idle)
    }

    func testRunningXcodebuildTestActionIsDetected() {
        let processList = [
            "  731 /Applications/Safari.app/Contents/MacOS/Safari",
            " 1234 /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild"
                + " -project /Users/dev/Demo/Demo.xcodeproj -scheme Demo"
                + " -destination platform=iOS Simulator,name=iPhone 17 Pro"
                + " test -parallel-testing-enabled NO -maximum-parallel-testing-workers 1"
        ].joined(separator: "\n")

        XCTAssertEqual(
            XCTestActivityInspector.analyze(processList: processList),
            .running(reason: "xcodebuild test")
        )
    }

    func testRunningXcodebuildTestWithoutBuildingIsDetected() {
        let processList = [
            " 1234 /usr/bin/xcodebuild -project /Users/dev/Demo/Demo.xcodeproj"
                + " -scheme Demo test-without-building"
        ].joined(separator: "\n")

        XCTAssertEqual(
            XCTestActivityInspector.analyze(processList: processList),
            .running(reason: "xcodebuild test-without-building")
        )
    }

    func testPlainXcodebuildBuildDoesNotBlockCleanup() {
        let processList = [
            " 1234 /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild"
                + " -project /Users/dev/Demo/Demo.xcodeproj -scheme Demo"
                + " -destination platform=iOS Simulator,name=iPhone 17 Pro build",
            " 1235 xcodebuild archive -project /Users/dev/Demo/Demo.xcodeproj -scheme Demo"
        ].joined(separator: "\n")

        XCTAssertEqual(XCTestActivityInspector.analyze(processList: processList), .idle)
    }

    func testStandaloneXCTestProcessIsDetected() {
        let processList = [
            " 5678 /Applications/Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform"
                + "/Developer/Library/Xcode/Agents/xctest --xctest-bundle-path /tmp/AppTests.xctest"
        ].joined(separator: "\n")

        XCTAssertEqual(
            XCTestActivityInspector.analyze(processList: processList),
            .running(reason: "xctest")
        )
    }

    func testXCTRunnerProcessIsDetected() {
        let processList = [
            " 9012 /Users/dev/Library/Developer/CoreSimulator/Devices/AAAA1111-0000-0000-0000-000000000000"
                + "/data/Containers/Bundle/Application/BBBB/XCTRunner.app/XCTRunner"
        ].joined(separator: "\n")

        XCTAssertEqual(
            XCTestActivityInspector.analyze(processList: processList),
            .running(reason: "XCTRunner")
        )
    }

    func testXCTestAgentProcessIsDetected() {
        let processList = [
            " 3456 /Applications/Xcode.app/Contents/Developer/Library/Xcode/Agents/XCTestAgent"
        ].joined(separator: "\n")

        XCTAssertEqual(
            XCTestActivityInspector.analyze(processList: processList),
            .running(reason: "XCTestAgent")
        )
    }

    func testUnusablePSOutputFallsBackToUnknown() {
        let behaviors: [StubProcessRunner.Behavior] = [
            .launchFailed,
            .timedOut,
            .errorStatus(1),
            .invalidUTF8Output
        ]
        for behavior in behaviors {
            let inspector = XCTestActivityInspector(processRunner: StubProcessRunner(behavior: behavior))
            XCTAssertEqual(inspector.currentState(), .unknown, "behavior: \(behavior)")
        }
    }

    // MARK: - 扫描：风险状态与勾选

    private func scan(home: URL, inspector: XCTestActivityInspecting) -> ScanReport {
        CacheScanner.scan(
            projectRoots: [],
            deepScan: false,
            home: home,
            includeSystemCaches: false,
            xctestActivityInspector: inspector,
            progress: { _ in },
            environment: [:]
        )
    }

    func testIdleCloneIsSafeAndSelectedByDefault() throws {
        let home = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: home) }
        let clone = try makeCloneDirectory(
            home: home,
            uuidString: "07104F4C-1234-1234-1234-123456789ABC"
        )

        let report = scan(home: home, inspector: FakeXCTestActivityInspector(state: .idle))

        let item = report.items.first { $0.path == clone.standardizedFileURL }
        XCTAssertNotNil(item, "UUID clone 应该被识别为清理候选")
        XCTAssertEqual(item?.risk, .safe)
        XCTAssertEqual(item?.isSelected, true)
        XCTAssertEqual(item?.statusTitle, "可安全清理")
    }

    func testRunningTestsForceManualRiskAndDeselect() throws {
        let home = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: home) }
        let clone = try makeCloneDirectory(
            home: home,
            uuidString: "07104F4C-1234-1234-1234-123456789ABC"
        )

        let report = scan(
            home: home,
            inspector: FakeXCTestActivityInspector(state: .running(reason: "xcodebuild test"))
        )

        let item = report.items.first { $0.path == clone.standardizedFileURL }
        XCTAssertEqual(item?.risk, .manual)
        XCTAssertEqual(item?.isSelected, false)
        XCTAssertEqual(item?.statusTitle, "正在测试")
    }

    func testUnknownActivityStateIsConservative() throws {
        let home = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: home) }
        let clone = try makeCloneDirectory(
            home: home,
            uuidString: "07104F4C-1234-1234-1234-123456789ABC"
        )

        let report = scan(home: home, inspector: FakeXCTestActivityInspector(state: .unknown))

        let item = report.items.first { $0.path == clone.standardizedFileURL }
        XCTAssertEqual(item?.risk, .manual, "无法判断状态时必须保守处理")
        XCTAssertEqual(item?.isSelected, false)
        XCTAssertEqual(item?.statusTitle, "无法确认状态")
    }

    func testCloneTitleUsesShortUUIDAndKeepsFullIDInDetails() throws {
        let home = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: home) }
        let uuidString = "07104F4C-1234-1234-1234-123456789ABC"
        let clone = try makeCloneDirectory(home: home, uuidString: uuidString)

        let report = scan(home: home, inspector: FakeXCTestActivityInspector(state: .idle))

        let item = report.items.first { $0.path == clone.standardizedFileURL }
        XCTAssertEqual(item?.name, "XCTest 克隆设备 · \(String(uuidString.prefix(8)))")
        XCTAssertFalse(item?.name.contains("child.lastPathComponent") ?? true, "不得残留旧的字符串插值 bug")
        XCTAssertFalse(item?.name.contains("-") ?? true, "标题不应包含完整 36 位 UUID")
        XCTAssertTrue(item?.details.contains(uuidString) ?? false, "完整 UUID 应该放在 details 中")
    }

    // MARK: - 清理：TOCTOU 与批量事务

    func testCleanupRechecksActivityAfterScanAndRejectsRunningTests() throws {
        let home = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: home) }
        let clone = try makeCloneDirectory(
            home: home,
            uuidString: "07104F4C-1234-1234-1234-123456789ABC"
        )

        // 扫描时没有测试在运行，条目被判定为 safe 并默认勾选。
        let report = scan(home: home, inspector: FakeXCTestActivityInspector(state: .idle))
        guard let cloneItem = report.items.first(where: { $0.path == clone.standardizedFileURL }) else {
            return XCTFail("clone 未被扫描到")
        }
        XCTAssertEqual(cloneItem.risk, .safe)

        // 用户在清理前启动了测试：删除前的二次检查必须拒绝，文件必须保留。
        let runningInspector = FakeXCTestActivityInspector(state: .running(reason: "xcodebuild test"))
        let context = DeletionContext(
            whitelistedPaths: [],
            projectRoots: [],
            home: home,
            allowedPaths: [cloneItem.path]
        )
        let trashSpy = TrashSpy()
        let cleanupReport = CacheCleaner.clean(
            [cloneItem],
            context: context,
            xctestActivityInspector: runningInspector,
            trashExecutor: trashSpy
        )

        XCTAssertTrue(cleanupReport.removed.isEmpty, "TOCTOU：扫描后启动测试时必须拒绝删除")
        XCTAssertEqual(cleanupReport.failures.first?.1, XCTestCleanupError.testsRunning.localizedDescription)
        XCTAssertTrue(fileManager.fileExists(atPath: clone.path), "运行中的 clone 必须原样保留")
        XCTAssertTrue(trashSpy.trashedPaths.isEmpty)
    }

    func testBatchCleanupChecksActivityOnlyOnce() throws {
        let home = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: home) }
        let uuids = [
            "07104F4C-1234-1234-1234-123456789ABC",
            "ABCDEF01-2345-6789-ABCD-EF0123456789",
            "FEEDFACE-0000-0000-0000-000000000000"
        ]
        let clones = try uuids.map { try makeCloneDirectory(home: home, uuidString: $0) }
        let clonePathSet = Set(clones.map { $0.standardizedFileURL.path })

        let report = scan(home: home, inspector: FakeXCTestActivityInspector(state: .idle))
        let cloneItems = report.items.filter { clonePathSet.contains($0.path.standardizedFileURL.path) }
        XCTAssertEqual(cloneItems.count, uuids.count)

        let inspector = FakeXCTestActivityInspector(state: .idle)
        let trashSpy = TrashSpy()
        let context = DeletionContext(
            whitelistedPaths: [],
            projectRoots: [],
            home: home,
            allowedPaths: cloneItems.map(\.path)
        )
        let cleanupReport = CacheCleaner.clean(
            cloneItems,
            context: context,
            xctestActivityInspector: inspector,
            trashExecutor: trashSpy
        )

        XCTAssertEqual(cleanupReport.removed.count, uuids.count)
        XCTAssertTrue(cleanupReport.failures.isEmpty)
        XCTAssertEqual(inspector.callCount, 1, "18 个 clone 一次批量清理也不允许执行多次 ps")
        for clone in clones {
            XCTAssertFalse(fileManager.fileExists(atPath: clone.path))
        }
    }

    func testBlockedCloneDoesNotCancelOtherSafeCleanups() throws {
        let home = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: home) }
        let clone = try makeCloneDirectory(
            home: home,
            uuidString: "07104F4C-1234-1234-1234-123456789ABC"
        )
        let normalCache = home.appendingPathComponent("Library/Caches/DevSweepTestNormal")
        try fileManager.createDirectory(at: normalCache, withIntermediateDirectories: true)
        try Data(repeating: 0xA5, count: 1_100_000).write(to: normalCache.appendingPathComponent("cache.bin"))
        let normalItem = CacheItem(category: "测试", name: "普通缓存", path: normalCache, size: 1_100_000)

        let scanReport = scan(home: home, inspector: FakeXCTestActivityInspector(state: .idle))
        guard let cloneItem = scanReport.items.first(where: { $0.path == clone.standardizedFileURL }) else {
            return XCTFail("clone 未被扫描到")
        }

        // 清理时检测到测试运行：clone 被拒绝，普通安全缓存必须继续完成清理。
        let runningInspector = FakeXCTestActivityInspector(state: .running(reason: "xcodebuild test"))
        let trashSpy = TrashSpy()
        let context = DeletionContext(
            whitelistedPaths: [],
            projectRoots: [],
            home: home,
            allowedPaths: [cloneItem.path, normalItem.path]
        )
        let cleanupReport = CacheCleaner.clean(
            [cloneItem, normalItem],
            context: context,
            xctestActivityInspector: runningInspector,
            trashExecutor: trashSpy
        )

        XCTAssertEqual(cleanupReport.failures.map(\.0.id), [cloneItem.id])
        XCTAssertEqual(cleanupReport.failures.first?.1, XCTestCleanupError.testsRunning.localizedDescription)
        XCTAssertEqual(cleanupReport.removed.map(\.id), [normalItem.id])
        XCTAssertTrue(fileManager.fileExists(atPath: clone.path))
        XCTAssertFalse(fileManager.fileExists(atPath: normalCache.path))
        XCTAssertEqual(trashSpy.trashedPaths, [normalCache.standardizedFileURL])
        XCTAssertEqual(runningInspector.callCount, 1)
    }

    func testNonUUIDChildrenAreNeverAutoSafe() throws {
        let home = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: home) }
        let root = home.appendingPathComponent("Library/Developer/XCTestDevices")
        let scratch = root.appendingPathComponent("ScratchStore")
        let legacy = root.appendingPathComponent("legacy-data")
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data(repeating: 0xA5, count: 1_100_000).write(to: scratch.appendingPathComponent("data.bin"))
        try Data(repeating: 0xA5, count: 1_100_000).write(to: legacy.appendingPathComponent("data.bin"))

        let report = scan(home: home, inspector: FakeXCTestActivityInspector(state: .idle))
        let xctestItems = report.items.filter { $0.category == "XCTest" }

        // 没有可识别的 UUID clone 时只允许出现保守的根目录 fallback，绝不能 safe。
        XCTAssertEqual(xctestItems.map(\.path), [root.standardizedFileURL])
        XCTAssertEqual(xctestItems.first?.risk, .review)
        XCTAssertEqual(xctestItems.first?.isSelected, false)
        XCTAssertFalse(report.items.contains { $0.risk == .safe && $0.category == "XCTest" })
        XCTAssertFalse(report.items.contains { $0.path == scratch.standardizedFileURL })

        // 混合场景：出现 UUID clone 后，clone 走动态状态，未识别内容仍然不会变成候选。
        try fileManager.removeItem(at: legacy)
        let clone = try makeCloneDirectory(
            home: home,
            uuidString: "07104F4C-1234-1234-1234-123456789ABC"
        )
        let mixedReport = scan(home: home, inspector: FakeXCTestActivityInspector(state: .idle))
        let mixedItems = mixedReport.items.filter { $0.category == "XCTest" }
        XCTAssertEqual(mixedItems.map(\.path), [clone.standardizedFileURL], "未识别的 ScratchStore 不应成为清理候选")
        XCTAssertTrue(mixedItems.allSatisfy { $0.risk == .safe && $0.isSelected })
    }

    func testSelectionMemoryDoesNotRestoreCheckmarkOntoRunningClone() {
        let clonePath = URL(fileURLWithPath: "/tmp/home/Library/Developer/XCTestDevices/07104F4C-1234-1234-1234-123456789ABC")
        let idleItem = CacheItem(
            category: "XCTest",
            name: "XCTest 克隆设备 · 07104F4C",
            path: clonePath,
            size: 1,
            risk: .safe,
            statusTitle: "可安全清理",
            isSelected: true
        )
        // 上一次扫描空闲时用户勾选过这个 clone，勾选状态按路径记忆。
        let states = [SelectionMemory.key(for: clonePath): true]

        // 重新扫描时测试正在运行（manual）：历史勾选不能被恢复。
        let runningItem = CacheItem(
            category: "XCTest",
            name: "XCTest 克隆设备 · 07104F4C",
            path: clonePath,
            size: 1,
            risk: .manual,
            statusTitle: "正在测试",
            isSelected: false
        )
        let restored = SelectionMemory.restore([runningItem], from: states)
        XCTAssertFalse(restored[0].isSelected, "manual 状态下不允许恢复历史勾选")

        // 非 manual 项目仍按记忆恢复。
        let restoredIdle = SelectionMemory.restore([idleItem], from: states)
        XCTAssertTrue(restoredIdle[0].isSelected)
    }

    // MARK: - Helpers

    private func temporaryDirectory() throws -> URL {
        let url = fileManager.temporaryDirectory.appendingPathComponent("DevSweepXCTestTests-\(UUID().uuidString)")
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    private func makeCloneDirectory(home: URL, uuidString: String) throws -> URL {
        let clone = home
            .appendingPathComponent("Library/Developer/XCTestDevices")
            .appendingPathComponent(uuidString)
        try fileManager.createDirectory(at: clone, withIntermediateDirectories: true)
        try Data(repeating: 0xA5, count: 1_100_000).write(to: clone.appendingPathComponent("device-data.bin"))
        return clone
    }
}
