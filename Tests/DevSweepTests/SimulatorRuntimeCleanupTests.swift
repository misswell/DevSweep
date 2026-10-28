import XCTest
@testable import DevSweep

/// SimulatorRuntimeCleanup 的内核测试：全部走 fake `ProcessRunning`，
/// 绝不执行真实 `simctl runtime delete`，也绝不真实删除任何 Runtime。
final class SimulatorRuntimeCleanupTests: XCTestCase {
    // MARK: - 真实输出 fixture

    /// 本机 `xcrun simctl runtime list -j` 的真实输出（两条 Runtime：iOS 26.5 / 27.0）。
    private static let realJSONFixture = """
    {
      "10DA06ED-69CE-43AC-BC36-998873EBD095" : {
        "build" : "23F77",
        "deletable" : true,
        "identifier" : "10DA06ED-69CE-43AC-BC36-998873EBD095",
        "kind" : "Patchable Cryptex Disk Image",
        "lastUsedAt" : "2026-10-24T15:26:28Z",
        "mountPath" : "\\/Library\\/Developer\\/CoreSimulator\\/Volumes\\/iOS_23F77",
        "parentMountPath" : "\\/System\\/Library\\/AssetsV2\\/com_apple_MobileAsset_iOSSimulatorRuntime\\/26c9174130fa5962f3e60f2a49963194dadbae4c.asset\\/AssetData",
        "path" : "\\/System\\/Library\\/AssetsV2\\/com_apple_MobileAsset_iOSSimulatorRuntime\\/26c9174130fa5962f3e60f2a49963194dadbae4c.asset\\/AssetData",
        "platformIdentifier" : "com.apple.platform.iphonesimulator",
        "runtimeBundlePath" : "\\/Library\\/Developer\\/CoreSimulator\\/Volumes\\/iOS_23F77\\/Library\\/Developer\\/CoreSimulator\\/Profiles\\/Runtimes\\/iOS 26.5.simruntime",
        "runtimeIdentifier" : "com.apple.CoreSimulator.SimRuntime.iOS-26-5",
        "signatureState" : "Unknown",
        "sizeBytes" : 8494282293,
        "state" : "Ready",
        "supportedArchitectures" : [
          "arm64"
        ],
        "version" : "26.5"
      },
      "C921E11F-A3CA-49B7-B19A-1B3250611292" : {
        "build" : "24A5370g",
        "deletable" : true,
        "identifier" : "C921E11F-A3CA-49B7-B19A-1B3250611292",
        "kind" : "Patchable Cryptex Disk Image",
        "lastUsedAt" : "2026-10-23T09:03:31Z",
        "mountPath" : "\\/Library\\/Developer\\/CoreSimulator\\/Volumes\\/iOS_24A5370g",
        "parentMountPath" : "\\/System\\/Library\\/AssetsV2\\/com_apple_MobileAsset_iOSSimulatorRuntime\\/12fedd911678cfd66b3cf9a6e4cd2dc16e5a2a8e.asset\\/AssetData",
        "path" : "\\/System\\/Library\\/AssetsV2\\/com_apple_MobileAsset_iOSSimulatorRuntime\\/12fedd911678cfd66b3cf9a6e4cd2dc16e5a2a8e.asset\\/AssetData",
        "platformIdentifier" : "com.apple.platform.iphonesimulator",
        "runtimeBundlePath" : "\\/Library\\/Developer\\/CoreSimulator\\/Volumes\\/iOS_24A5370g\\/Library\\/Developer\\/CoreSimulator\\/Profiles\\/Runtimes\\/iOS 27.0.simruntime",
        "runtimeIdentifier" : "com.apple.CoreSimulator.SimRuntime.iOS-27-0",
        "signatureState" : "Unknown",
        "sizeBytes" : 8389757281,
        "state" : "Ready",
        "supportedArchitectures" : [
          "arm64"
        ],
        "version" : "27.0"
      }
    }
    """

    /// 本机 `xcrun simctl runtime list` 的文本输出。
    private static let realTextFixture = """
    == Disk Images ==
    -- iOS --
    iOS 26.5 (23F77) - 10DA06ED-69CE-43AC-BC36-998873EBD095 (Ready)
    iOS 27.0 (24A5370g) - C921E11F-A3CA-49B7-B19A-1B3250611292 (Ready)

    Total Disk Images: 2 (15.7G)
    """

    private static let ios265ID = "10DA06ED-69CE-43AC-BC36-998873EBD095"
    private static let ios270ID = "C921E11F-A3CA-49B7-B19A-1B3250611292"
    private static let fakeSimctl = URL(fileURLWithPath: "/tmp/DevSweepTests/fake/simctl")

    // MARK: - Scripted fake runner

    /// 脚本化 fake：按参数决定返回什么，记录所有调用。永不执行真实 simctl。
    private final class Runner: ProcessRunning, @unchecked Sendable {
        /// 固定初始列表（测试自定义场景）；设置后列表内容以它为准，
        /// 删除成功的 id 仍会从输出里消失。
        var fixtureJSON: String? = nil
        /// 固定原始输出，完全不随删除变化（用于「删了但没消失」场景）。
        var jsonOutput: String? = nil
        /// 用存活集合动态生成列表，模拟 simctl 删除后列表真的变化。
        var dynamicJSON = true
        /// 列表命令无法启动（进程返回 nil）。
        var listUnavailable = false
        /// 文本 `runtime list` 输出（JSON 解析失败时才会用到）。
        var textOutput: String = SimulatorRuntimeCleanupTests.realTextFixture
        /// 失败时状态码。
        var listStatus: Int32 = 0
        /// `delete` 的每个 identifier → 结果；缺省视为成功。
        var deleteResults: [String: ProcessResult] = [:]
        /// 删除成功后把这些 id 从列表里移除，模拟 simctl 真正生效。
        var applyDeletes = true
        /// 只让特定 id 从列表消失（模拟「删了但没消失」）。
        var vanishOnDelete: Set<String>?
        /// `xcrun --find simctl` 是否可用。
        var xcrunAvailable = true
        /// `ps` 输出，nil 表示 ps 失败。
        var processList: String? = "1 /sbin/launchd\n123 /usr/bin/ps"
        /// `mount` 输出。
        var mountOutput = ""

        private(set) var calls: [(executable: URL, arguments: [String])] = []
        private(set) var deletedIdentifiers: [String] = []
        fileprivate var liveIDs: Set<String> = [SimulatorRuntimeCleanupTests.ios265ID,
                                               SimulatorRuntimeCleanupTests.ios270ID]

        /// 设定固定场景列表，并让 liveIDs 与之对齐。
        func useFixture(_ json: String) {
            dynamicJSON = false
            fixtureJSON = json
            let parsed = SimulatorRuntimeListParser.parseJSON(json) ?? []
            liveIDs = Set(parsed.map(\.identifier))
        }

        func run(
            executable: URL,
            arguments: [String],
            environment: [String: String]?,
            timeout: TimeInterval
        ) -> ProcessResult? {
            calls.append((executable, arguments))

            if executable.path == "/usr/bin/xcrun" {
                guard xcrunAvailable else {
                    return ProcessResult(status: 1, stdout: Data(), stderr: Data(), timedOut: false)
                }
                return ProcessResult(status: 0,
                                     stdout: Data((SimulatorRuntimeCleanupTests.fakeSimctl.path + "\n").utf8),
                                     stderr: Data(), timedOut: false)
            }
            if executable.path == "/bin/ps" {
                guard let processList else { return nil }
                return ProcessResult(status: 0, stdout: Data(processList.utf8), stderr: Data(), timedOut: false)
            }
            if executable.path == "/sbin/mount" {
                return ProcessResult(status: 0, stdout: Data(mountOutput.utf8), stderr: Data(), timedOut: false)
            }

            // 其余调用一律是 simctl。
            if arguments.prefix(2) == ["runtime", "delete"], arguments.count == 3 {
                let id = arguments[2]
                deletedIdentifiers.append(id)
                if let result = deleteResults[id] { return result }
                if applyDeletes {
                    let shouldVanish = vanishOnDelete.map { $0.contains(id) } ?? true
                    if shouldVanish { liveIDs.remove(id) }
                }
                return ProcessResult(status: 0, stdout: Data(), stderr: Data(), timedOut: false)
            }

            if arguments.contains("runtime") && arguments.contains("list") {
                guard !listUnavailable else { return nil }
                let payload: String
                if dynamicJSON {
                    payload = currentJSON()
                } else if let fixtureJSON {
                    payload = Self.pruned(fixtureJSON, liveIDs: liveIDs)
                } else {
                    payload = jsonOutput ?? ""
                }
                if arguments.contains("-j") {
                    return ProcessResult(status: listStatus,
                                         stdout: Data(payload.utf8),
                                         stderr: Data(),
                                         timedOut: false)
                }
                return ProcessResult(status: 0, stdout: Data(textOutput.utf8), stderr: Data(), timedOut: false)
            }

            // 未预期的调用：返回失败，避免测试静默通过。
            return ProcessResult(status: 64, stdout: Data(), stderr: Data("unexpected".utf8), timedOut: false)
        }

        /// 按存活集合裁剪任意 JSON（三种形状都走 parseJSON 后重建根 map）。
        static func pruned(_ json: String, liveIDs: Set<String>) -> String {
            guard let parsed = SimulatorRuntimeListParser.parseJSON(json) else { return json }
            let kept = parsed.filter { liveIDs.contains($0.identifier) }
            guard !kept.isEmpty else { return "{}" }
            let objects = kept.map { runtime in
                "\"\(runtime.identifier)\" : {\"identifier\":\"\(runtime.identifier)\"," +
                "\"platformIdentifier\":\"\(runtime.platformIdentifier ?? "")\"," +
                "\"version\":\"\(runtime.version)\",\"deletable\":true," +
                "\"sizeBytes\":\(runtime.sizeBytes ?? 0),\"state\":\"\(runtime.state ?? "Ready")\"}"
            }
            return "{" + objects.joined(separator: ",") + "}"
        }

        /// 按当前存活集合裁剪真实 fixture，模拟「删除生效后列表变化」。
        func currentJSON() -> String {
            let parsed = SimulatorRuntimeListParser.parseJSON(SimulatorRuntimeCleanupTests.realJSONFixture) ?? []
            let kept = parsed.filter { liveIDs.contains($0.identifier) }
            let objects = kept.map { runtime -> String in
                """
                "\(runtime.identifier)" : {
                  "build" : "\(runtime.build ?? "")",
                  "deletable" : \(runtime.deletable == false ? "false" : "true"),
                  "identifier" : "\(runtime.identifier)",
                  "mountPath" : "\(runtime.mountPath ?? "")",
                  "platformIdentifier" : "\(runtime.platformIdentifier ?? "")",
                  "runtimeIdentifier" : "\(runtime.runtimeIdentifier ?? "")",
                  "sizeBytes" : \(runtime.sizeBytes ?? 0),
                  "state" : "\(runtime.state ?? "Ready")",
                  "version" : "\(runtime.version)"
                }
                """
            }
            return "{" + objects.joined(separator: ",\n") + "}"
        }
    }

    private func makeRuntime(
        _ identifier: String,
        version: String,
        platform: String = "com.apple.platform.iphonesimulator",
        runtimeIdentifier: String? = nil,
        build: String? = nil,
        deletable: Bool? = true,
        sizeBytes: Int64? = 1_000,
        state: String? = "Ready",
        mountPath: String? = nil,
        parentMountPath: String? = nil
    ) -> SimulatorRuntimeInfo {
        SimulatorRuntimeInfo(
            identifier: identifier,
            runtimeIdentifier: runtimeIdentifier,
            platformIdentifier: platform,
            version: version,
            build: build,
            deletable: deletable,
            sizeBytes: sizeBytes,
            mountPath: mountPath,
            parentMountPath: parentMountPath,
            state: state
        )
    }
    /// 受保护根目录置空，避免默认 home/系统路径干扰保留策略断言。
    private var openProtection: SimulatorRuntimeProtection {
        SimulatorRuntimeProtection(protectedIdentifiers: [], protectedRoots: [])
    }

    // MARK: - 1. parseJSON

    func testParseJSONHandlesAllThreeShapes() throws {
        // 形状 1：根对象本身就是 UUID → runtime map（真实 fixture）。
        let rootMap = try XCTUnwrap(SimulatorRuntimeListParser.parseJSON(Self.realJSONFixture))
        XCTAssertEqual(rootMap.count, 2)
        XCTAssertEqual(rootMap.map(\.identifier), [Self.ios265ID, Self.ios270ID])

        let first = try XCTUnwrap(rootMap.first { $0.identifier == Self.ios265ID })
        XCTAssertEqual(first.version, "26.5")
        XCTAssertEqual(first.build, "23F77")
        XCTAssertEqual(first.deletable, true)
        XCTAssertEqual(first.sizeBytes, 8_494_282_293)
        XCTAssertEqual(first.platformIdentifier, "com.apple.platform.iphonesimulator")
        XCTAssertEqual(first.runtimeIdentifier, "com.apple.CoreSimulator.SimRuntime.iOS-26-5")
        XCTAssertEqual(first.state, "Ready")
        XCTAssertTrue(first.isReady)
        XCTAssertEqual(first.mountPath, "/Library/Developer/CoreSimulator/Volumes/iOS_23F77")
        XCTAssertNotNil(first.lastUsedAt, "ISO8601 时间应被解析")

        // 形状 2：{"runtimes": {UUID: runtime}}。
        let nestedMapJSON = """
        {"runtimes": {"\(Self.ios265ID)": {"identifier": "\(Self.ios265ID)",
         "platformIdentifier": "com.apple.platform.iphonesimulator",
         "version": "26.5", "deletable": true, "sizeBytes": 100}}}
        """
        let nestedMap = try XCTUnwrap(SimulatorRuntimeListParser.parseJSON(nestedMapJSON))
        XCTAssertEqual(nestedMap.map(\.identifier), [Self.ios265ID])
        XCTAssertEqual(nestedMap.first?.sizeBytes, 100)

        // 形状 3：{"runtimes": [runtime, ...]}。
        let nestedListJSON = """
        {"runtimes": [
          {"identifier": "A", "platformIdentifier": "com.apple.platform.iphonesimulator", "version": "26.5"},
          {"identifier": "B", "platformIdentifier": "com.apple.platform.watchsimulator", "version": "27.0"}
        ]}
        """
        let nestedList = try XCTUnwrap(SimulatorRuntimeListParser.parseJSON(nestedListJSON))
        XCTAssertEqual(nestedList.map(\.identifier), ["A", "B"])
        XCTAssertEqual(nestedList.map(\.version), ["26.5", "27.0"])
    }

    func testParseJSONEmptyInvalidAndIrrelevantDictionaries() {
        // 空对象 → []（确实是「没有 Runtime」）。
        XCTAssertEqual(SimulatorRuntimeListParser.parseJSON("{}")?.count, 0)

        // 无效 JSON / 空字符串 → nil（不能当成空列表）。
        for invalid in ["", "   ", "not json", "[1,2,3]", "\"error message\"", "null"] {
            XCTAssertNil(SimulatorRuntimeListParser.parseJSON(invalid), "不应解析：\(invalid)")
        }

        // 无关字典（没有 identifier / 运行时字段）被忽略；全部无关 → nil。
        let unrelated = """
        {"foo": {"bar": 1}, "baz": {"qux": "nope"}}
        """
        XCTAssertNil(SimulatorRuntimeListParser.parseJSON(unrelated))
        // 空的 runtimes 容器也返回 nil，强制调用方走文本兜底。
        XCTAssertNil(SimulatorRuntimeListParser.parseJSON("{\"runtimes\": {}}"))
        XCTAssertNil(SimulatorRuntimeListParser.parseJSON("{\"runtimes\": []}"))
    }

    func testParseJSONKeepsOnlyRuntimeLikeEntries() throws {
        // 一个像运行时的、一个无关的：只保留前者。
        let mixed = """
        {"runtimes": {
          "X": {"identifier": "X", "platformIdentifier": "com.apple.platform.iphonesimulator", "version": "26.5"},
          "Y": {"message": "internal error"}
        }}
        """
        let parsed = try XCTUnwrap(SimulatorRuntimeListParser.parseJSON(mixed))
        XCTAssertEqual(parsed.map(\.identifier), ["X"])

        // deletable 非 bool（字符串 / 数字）视为未知，不能误判为可删除。
        let looseDeletable = """
        {"runtimes": [
          {"identifier": "S", "platformIdentifier": "com.apple.platform.iphonesimulator",
           "version": "1.0", "deletable": "true"},
          {"identifier": "N", "platformIdentifier": "com.apple.platform.iphonesimulator",
           "version": "1.0", "deletable": 1}
        ]}
        """
        let loose = try XCTUnwrap(SimulatorRuntimeListParser.parseJSON(looseDeletable))
        // 字符串 "true" 不是 JSON bool → nil；数字 1 经 JSONDecoder 宽松转换变成 true。
        XCTAssertEqual(loose.map(\.deletable), [nil, true])

        // sizeBytes 允许字符串形式。
        let stringSize = """
        {"runtimes": [{"identifier": "Z",
          "platformIdentifier": "com.apple.platform.iphonesimulator",
          "version": "1.0", "sizeBytes": "12345"}]}
        """
        XCTAssertEqual(SimulatorRuntimeListParser.parseJSON(stringSize)?.first?.sizeBytes, 12_345)

        // 重复 identifier 去重。
        let duplicated = """
        {"runtimes": [
          {"identifier": "D", "platformIdentifier": "com.apple.platform.iphonesimulator", "version": "1.0"},
          {"identifier": "D", "platformIdentifier": "com.apple.platform.iphonesimulator", "version": "1.0"}
        ]}
        """
        XCTAssertEqual(SimulatorRuntimeListParser.parseJSON(duplicated)?.count, 1)
    }

    // MARK: - 2. parseText

    func testParseTextHandlesBothRealLineForms() throws {
        let fromReal = try XCTUnwrap(SimulatorRuntimeListParser.parseText(Self.realTextFixture))
        XCTAssertEqual(fromReal.count, 2)
        XCTAssertEqual(fromReal.map(\.identifier), [Self.ios265ID, Self.ios270ID])
        XCTAssertEqual(fromReal.map(\.version), ["26.5", "27.0"])
        XCTAssertEqual(fromReal.map(\.build), ["23F77", "24A5370g"])
        XCTAssertTrue(fromReal.allSatisfy { $0.isReady })
        XCTAssertEqual(fromReal.first?.platformIdentifier, "com.apple.platform.iphonesimulator")

        // 带 runtimeIdentifier 的一行：`iOS 26.5 (26.5 - 23F77) - com.apple.CoreSimulator...`。
        let withRuntimeIdentifier = """
        iOS 26.5 (26.5 - 23F77) - com.apple.CoreSimulator.SimRuntime.iOS-26-5
        """
        let parsed = try XCTUnwrap(SimulatorRuntimeListParser.parseText(withRuntimeIdentifier))
        XCTAssertEqual(parsed.count, 1)
        let runtime = try XCTUnwrap(parsed.first)
        XCTAssertEqual(runtime.identifier, "com.apple.CoreSimulator.SimRuntime.iOS-26-5")
        XCTAssertEqual(runtime.version, "26.5")
        XCTAssertEqual(runtime.build, "26.5 - 23F77")
        XCTAssertNil(runtime.state)
        XCTAssertNil(runtime.deletable, "文本兜底拿不到 deletable，必须保持 nil")
        XCTAssertEqual(runtime.platformIdentifier, "com.apple.platform.iphonesimulator")

        // 不带 (Ready) 的状态也是合法输入。
        let noState = "watchOS 26.5 (23R4000) - 11111111-2222-3333-4444-555555555555"
        let watch = try XCTUnwrap(SimulatorRuntimeListParser.parseText(noState)?.first)
        XCTAssertEqual(watch.state, nil)
        XCTAssertEqual(watch.platformIdentifier, "com.apple.platform.watchsimulator")
    }

    func testParseTextHandlesEmptyAndUnrecognizedOutput() {
        // 空列表标记 → []（精确匹配 "Total Disk Images: 0"）。
        XCTAssertEqual(SimulatorRuntimeListParser.parseText("Total Disk Images: 0")?.count, 0)
        XCTAssertEqual(SimulatorRuntimeListParser.parseText("== Disk Images ==\n\nTotal Disk Images: 0")?.count, 0)
        // 小写变体当前不被识别：返回 nil（宁可走兜底，也不当空列表）。
        XCTAssertNil(SimulatorRuntimeListParser.parseText("total disk images: 0"))

        // 输出无法识别 → nil（不能当成「没有 Runtime」）。
        XCTAssertNil(SimulatorRuntimeListParser.parseText(""))
        XCTAssertNil(SimulatorRuntimeListParser.parseText("something went wrong"))
        XCTAssertNil(SimulatorRuntimeListParser.parseText("Total Disk Images: 2 (15.7G)"))
    }

    // MARK: - 3. 平台保留策略

    func testNewestVersionPerPlatformIsKept() {
        let old = makeRuntime("iOS-26-5", version: "26.5", runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-5")
        let new = makeRuntime("iOS-27-0", version: "27.0", runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-27-0")

        let plan = SimulatorRuntimeCleaner.removableIdentifiers([old, new], protection: openProtection)
        XCTAssertEqual(plan.kept.map(\.identifier), ["iOS-27-0"], "同平台保留最新")
        XCTAssertEqual(plan.removableIdentifiers, ["iOS-26-5"], "旧版本可删除")
        XCTAssertTrue(plan.blocked.isEmpty)

        // 顺序无关。
        let reversed = SimulatorRuntimeCleaner.removableIdentifiers([new, old], protection: openProtection)
        XCTAssertEqual(reversed.kept.map(\.identifier), ["iOS-27-0"])
        XCTAssertEqual(reversed.removableIdentifiers, ["iOS-26-5"])

        // 三个版本：保留最新，两个旧的可删，按 identifier 排序。
        let mid = makeRuntime("iOS-26-9", version: "26.9")
        let three = SimulatorRuntimeCleaner.removableIdentifiers([old, mid, new], protection: openProtection)
        XCTAssertEqual(three.kept.map(\.identifier), ["iOS-27-0"])
        XCTAssertEqual(three.removableIdentifiers, ["iOS-26-5", "iOS-26-9"])

        // 单版本平台：没有可删项。
        let single = SimulatorRuntimeCleaner.removableIdentifiers([new], protection: openProtection)
        XCTAssertEqual(single.kept.map(\.identifier), ["iOS-27-0"])
        XCTAssertTrue(single.removable.isEmpty)
    }

    /// 复现用户截图里的真实形态：iOS 26.5 + 27.0 两个版本，UUID 作 identifier，
    /// 平台相同。必须只有一个「保留最新」（27.0），26.5 可删除；两版本都被判为
    /// 「保留最新」会让整行一个都删不掉，这正是 `RuntimeVersion("27.0")` 早期
    /// 解析失败留下的坑。
    func testRealMacTwoRuntimeShapeKeepsOnlyTheNewest() {
        let old = makeRuntime(
            "10DA06ED-69CE-43AC-BC36-998873EBD095",
            version: "26.5",
            runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-5",
            build: "23F77",
            mountPath: "/Library/Developer/CoreSimulator/Volumes/iOS_23F77"
        )
        let new = makeRuntime(
            "C921E11F-A3CA-49B7-B19A-1B3250611292",
            version: "27.0",
            runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-27-0",
            build: "24A5370g",
            mountPath: "/Library/Developer/CoreSimulator/Volumes/iOS_24A5370g"
        )
        let plan = SimulatorRuntimeCleaner.removableIdentifiers([old, new], protection: openProtection)
        XCTAssertEqual(plan.kept.map(\.version), ["27.0"], "只保留最新版本")
        XCTAssertEqual(plan.removableIdentifiers, [old.identifier], "26.5 可删除")
        XCTAssertTrue(plan.blocked.isEmpty, "不应有额外阻塞：\(plan.blocked)")

        // 版本字符串带 build 后缀时也必须正确排序（文本兜底输出常见）。
        let taggedOld = makeRuntime("OLD", version: "26.5 - 23F77")
        let taggedNew = makeRuntime("NEW", version: "27.0 - 24A5370g")
        let taggedPlan = SimulatorRuntimeCleaner.removableIdentifiers([taggedOld, taggedNew], protection: openProtection)
        XCTAssertEqual(taggedPlan.kept.map(\.identifier), ["NEW"])
        XCTAssertEqual(taggedPlan.removableIdentifiers, ["OLD"])
    }

    func testDeletableFalseIsNeverRemovedEvenWhenOldest() {
        let lockedOld = makeRuntime("iOS-26-5", version: "26.5", deletable: false)
        let new = makeRuntime("iOS-27-0", version: "27.0", deletable: true)

        let plan = SimulatorRuntimeCleaner.removableIdentifiers([lockedOld, new], protection: openProtection)
        XCTAssertTrue(plan.removableIdentifiers.isEmpty, "系统标记不可删除的一律不删")
        XCTAssertEqual(plan.kept.map(\.identifier), ["iOS-27-0"], "最新版本仍需保留")
        XCTAssertEqual(plan.blocked.count, 1)
        XCTAssertEqual(plan.blocked.first?.runtime.identifier, "iOS-26-5")
        XCTAssertTrue(plan.blocked.first?.reason.contains("不可移除") ?? false,
                      plan.blocked.first?.reason ?? "")

        // 唯一一个 Runtime 且 deletable == false：既不可删也不进 kept 的删除名单。
        let onlyLocked = SimulatorRuntimeCleaner.removableIdentifiers([lockedOld], protection: openProtection)
        XCTAssertTrue(onlyLocked.removable.isEmpty)
        XCTAssertEqual(onlyLocked.blocked.count, 1)
    }

    func testCrossPlatformVersionsDoNotAffectEachOther() {
        let iosOld = makeRuntime("iOS-26-5", version: "26.5")
        let iosNew = makeRuntime("iOS-27-0", version: "27.0")
        let watchOld = makeRuntime("watch-26-5", version: "26.5",
                                   platform: "com.apple.platform.watchsimulator")
        let watchNew = makeRuntime("watch-27-0", version: "27.0",
                                   platform: "com.apple.platform.watchsimulator")
        let tv = makeRuntime("tv-26-5", version: "26.5",
                             platform: "com.apple.platform.appletvsimulator")

        let plan = SimulatorRuntimeCleaner.removableIdentifiers(
            [iosOld, iosNew, watchOld, watchNew, tv], protection: openProtection
        )
        XCTAssertEqual(Set(plan.kept.map(\.identifier)), ["iOS-27-0", "watch-27-0", "tv-26-5"],
                       "每个平台各保留自己的最新版本")
        XCTAssertEqual(Set(plan.removableIdentifiers), ["iOS-26-5", "watch-26-5"],
                       "高版本 iOS 不会让低版本 watchOS 变得可删")
        XCTAssertTrue(plan.removableBytes > 0)
    }

    func testUnversionedRuntimeIsNeverRemoved() {
        let noVersion = makeRuntime("no-version", version: "")
        let versioned = makeRuntime("iOS-27-0", version: "27.0")
        let plan = SimulatorRuntimeCleaner.removableIdentifiers([noVersion, versioned], protection: openProtection)
        XCTAssertFalse(plan.removableIdentifiers.contains("no-version"),
                       "无法比较版本时不做「保留最旧」判断")
        XCTAssertTrue(plan.blocked.contains { $0.runtime.identifier == "no-version" })

        // 非数字版本同理。
        let badVersion = makeRuntime("bad-version", version: "beta")
        let withBad = SimulatorRuntimeCleaner.removableIdentifiers([badVersion, versioned], protection: openProtection)
        XCTAssertFalse(withBad.removableIdentifiers.contains("bad-version"))
    }

    func testProtectedIdentifierAndNonReadyStateBlockRemoval() {
        let old = makeRuntime("iOS-26-5", version: "26.5")
        let new = makeRuntime("iOS-27-0", version: "27.0")
        let protection = SimulatorRuntimeProtection(protectedIdentifiers: ["iOS-26-5"], protectedRoots: [])
        let plan = SimulatorRuntimeCleaner.removableIdentifiers([old, new], protection: protection)
        XCTAssertTrue(plan.removableIdentifiers.isEmpty, "保护名单内的不删")
        XCTAssertEqual(plan.blocked.count, 1)

        // 非 Ready 状态不删。
        let booting = makeRuntime("iOS-26-5", version: "26.5", state: "Booting")
        let plan2 = SimulatorRuntimeCleaner.removableIdentifiers([booting, new], protection: openProtection)
        XCTAssertTrue(plan2.removableIdentifiers.isEmpty, "只在 Ready 状态删除")
        XCTAssertTrue(plan2.blocked.contains { $0.runtime.identifier == "iOS-26-5" })
    }

    func testVersionComparisonHandlesMultiComponentVersions() {
        XCTAssertTrue(RuntimeVersion("26.5")! < RuntimeVersion("27.0")!)
        XCTAssertTrue(RuntimeVersion("26.5")! < RuntimeVersion("26.5.1")!)
        XCTAssertTrue(RuntimeVersion("26.10")! > RuntimeVersion("26.9")!)
        // 只实现了 `<`，等价性用双向比较表达。
        XCTAssertFalse(RuntimeVersion("26.5")! < RuntimeVersion("26.5.0")!)
        XCTAssertFalse(RuntimeVersion("26.5.0")! < RuntimeVersion("26.5")!)
        XCTAssertNil(RuntimeVersion(""))
        XCTAssertNil(RuntimeVersion("beta"))
        XCTAssertNil(RuntimeVersion("26.beta"))
        // simctl 的 version 可能被文本兜底或诊断输出串上 build（`26.5 - 23F77`），
        // 保留策略只认数字前缀；这里断言不会把整段当成非法而误保留全部版本。
        XCTAssertEqual(RuntimeVersion("26.5 - 23F77")?.description, "26.5")
        XCTAssertTrue(RuntimeVersion("26.5 - 23F77")! < RuntimeVersion("27.0")!)
        // 但纯数字后面跟的非点号内容一律拒绝，避免把 27 当成 27.x 参与比较。
        XCTAssertNil(RuntimeVersion("27beta"))
    }

    // MARK: - 4. 删除流程

    func testDeleteReportsMissingIdentifiersAsRemovedWithoutCallingDelete() {
        let runner = Runner()
        let outcome = SimulatorRuntimeCleaner.delete(
            identifiers: ["ALREADY-GONE-ID"],
            runner: runner,
            protection: openProtection,
            verificationTimeout: 0.2,
            pollInterval: 0,
            sleep: { _ in }
        )
        // 清单里没有它 → 直接视为已消失（成功），不执行 delete。
        XCTAssertEqual(outcome.removed, ["ALREADY-GONE-ID"])
        XCTAssertTrue(outcome.failures.isEmpty)
        XCTAssertTrue(outcome.remaining.isEmpty)
        XCTAssertTrue(outcome.isSuccess)
        XCTAssertTrue(runner.deletedIdentifiers.isEmpty, "不在清单里的 id 不能执行 simctl runtime delete")
    }

    func testDeleteOnlyTouchesNonLatestAndKeepsOthersRunning() throws {
        let runner = Runner()
        runner.applyDeletes = true
        let outcome = SimulatorRuntimeCleaner.delete(
            identifiers: [Self.ios265ID],
            runner: runner,
            protection: openProtection,
            verificationTimeout: 1,
            pollInterval: 0,
            sleep: { _ in }
        )
        XCTAssertEqual(runner.deletedIdentifiers, [Self.ios265ID])
        XCTAssertEqual(outcome.removed, [Self.ios265ID])
        XCTAssertTrue(outcome.failures.isEmpty, "\(outcome.failures)")
        XCTAssertTrue(outcome.remaining.isEmpty)
        XCTAssertTrue(outcome.isSuccess)

        // 最新版本不能删：不提交任何 delete 命令。
        let guarded = Runner()
        let latestOutcome = SimulatorRuntimeCleaner.delete(
            identifiers: [Self.ios270ID],
            runner: guarded,
            protection: openProtection,
            verificationTimeout: 0.5,
            pollInterval: 0,
            sleep: { _ in }
        )
        XCTAssertTrue(guarded.deletedIdentifiers.isEmpty, "平台最新版本不能删除")
        XCTAssertEqual(latestOutcome.failures.map(\.id), [Self.ios270ID])
        XCTAssertTrue(latestOutcome.removed.isEmpty)
        XCTAssertFalse(latestOutcome.isSuccess)
    }

    func testDeleteFailureIsReportedAndOtherIdentifiersContinue() {
        let runner = Runner()
        // 两个 iOS Runtime：26.5 与 27.0 最新被保留；再造一个旧的 26.0 一起删。
        let extra = """
        {
          "10DA06ED-69CE-43AC-BC36-998873EBD095" : {
            "build" : "23F77", "deletable" : true,
            "identifier" : "10DA06ED-69CE-43AC-BC36-998873EBD095",
            "platformIdentifier" : "com.apple.platform.iphonesimulator",
            "sizeBytes" : 100, "state" : "Ready", "version" : "26.5"
          },
          "C921E11F-A3CA-49B7-B19A-1B3250611292" : {
            "build" : "24A5370g", "deletable" : true,
            "identifier" : "C921E11F-A3CA-49B7-B19A-1B3250611292",
            "platformIdentifier" : "com.apple.platform.iphonesimulator",
            "sizeBytes" : 200, "state" : "Ready", "version" : "27.0"
          },
          "OLD-RUNTIME-0000" : {
            "build" : "22A100", "deletable" : true,
            "identifier" : "OLD-RUNTIME-0000",
            "platformIdentifier" : "com.apple.platform.iphonesimulator",
            "sizeBytes" : 300, "state" : "Ready", "version" : "26.0"
          }
        }
        """
        runner.useFixture(extra)
        runner.deleteResults["10DA06ED-69CE-43AC-BC36-998873EBD095"] = ProcessResult(
            status: 1, stdout: Data(), stderr: Data("disk image busy\n".utf8), timedOut: false
        )

        let outcome = SimulatorRuntimeCleaner.delete(
            identifiers: ["10DA06ED-69CE-43AC-BC36-998873EBD095", "OLD-RUNTIME-0000"],
            runner: runner,
            protection: openProtection,
            verificationTimeout: 0.5,
            pollInterval: 0,
            sleep: { _ in }
        )

        XCTAssertEqual(Set(runner.deletedIdentifiers),
                       ["10DA06ED-69CE-43AC-BC36-998873EBD095", "OLD-RUNTIME-0000"],
                       "失败的 id 不影响其它 id 继续删除")
        XCTAssertEqual(outcome.failures.map(\.id), ["10DA06ED-69CE-43AC-BC36-998873EBD095"])
        XCTAssertTrue(outcome.failures.first?.message.contains("disk image busy") ?? false,
                      outcome.failures.first?.message ?? "")
        XCTAssertEqual(outcome.removed, ["OLD-RUNTIME-0000"])
        XCTAssertFalse(outcome.isSuccess)
    }

    func testDeleteVerificationPollsWithInjectedSleepAndReportsRemaining() {
        let runner = Runner()
        // 删除命令成功，但 Runtime 一直留在列表里 → 轮询超时后报 remaining。
        runner.vanishOnDelete = []

        var sleeps: [TimeInterval] = []
        var attempts: [Int] = []
        let start = Date()
        let outcome = SimulatorRuntimeCleaner.delete(
            identifiers: [Self.ios265ID],
            runner: runner,
            protection: openProtection,
            verificationTimeout: 0.05,
            pollInterval: 0.01,
            sleep: { sleeps.append($0) },
            verifier: { attempts.append($0) }
        )
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(elapsed, 5, "必须用注入的短超时，不能真的等")
        XCTAssertGreaterThanOrEqual(attempts.count, 1, "至少要轮询一次")
        XCTAssertEqual(attempts.count, sleeps.count + 1, "每次 sleep 都对应一次新的轮询")
        XCTAssertEqual(outcome.remaining, [Self.ios265ID], "超时后报 remaining")
        XCTAssertEqual(outcome.failures.map(\.id), [Self.ios265ID])
        XCTAssertTrue(outcome.removed.isEmpty)
        XCTAssertFalse(outcome.isSuccess)
        XCTAssertFalse(outcome.summary.contains("!"))
    }

    func testDeleteSucceedsOnSecondPollWithoutWaitingTheFullTimeout() {
        let runner = Runner()
        // 删除命令不生效：第一次轮询仍可见；第二次轮询前把列表改成只剩最新版本。
        runner.vanishOnDelete = []

        var polls = 0
        let outcome = SimulatorRuntimeCleaner.delete(
            identifiers: [Self.ios265ID],
            runner: runner,
            protection: openProtection,
            verificationTimeout: 5,
            pollInterval: 0,
            sleep: { _ in },
            verifier: { _ in
                polls += 1
                if polls == 2 {
                    // 模拟 simctl 后台完成卸载：旧版本从列表消失，只剩最新的 27.0。
                    runner.fixtureJSON = """
                    {"\(Self.ios270ID)": {"identifier": "\(Self.ios270ID)",
                     "platformIdentifier": "com.apple.platform.iphonesimulator",
                     "version": "27.0", "deletable": true, "sizeBytes": 200, "state": "Ready"}}
                    """
                    runner.liveIDs = Set([Self.ios270ID])
                }
            }
        )
        XCTAssertEqual(polls, 2, "第二次轮询即可结束，不必等到超时")
        XCTAssertEqual(outcome.removed, [Self.ios265ID])
        XCTAssertTrue(outcome.remaining.isEmpty, "\(outcome.remaining)")
        XCTAssertTrue(outcome.isSuccess, "\(outcome.failures)")
    }

    func testDeleteRejectsInvalidAndEmptyIdentifiers() {
        for identifiers in [[""], ["--help"], ["id with space"], ["a/b"], ["$(rm -rf ~)"]] {
            let runner = Runner()
            let outcome = SimulatorRuntimeCleaner.delete(
                identifiers: identifiers,
                runner: runner,
                protection: openProtection,
                verificationTimeout: 0.1,
                pollInterval: 0,
                sleep: { _ in }
            )
            XCTAssertTrue(runner.deletedIdentifiers.isEmpty, "非法 identifier 不能拼进 simctl：\(identifiers)")
            XCTAssertTrue(outcome.removed.isEmpty, "\(identifiers)")
            XCTAssertTrue(outcome.failures.isEmpty, "\(identifiers)")
        }

        XCTAssertTrue(SimulatorRuntimeCleaner.isValidIdentifier("com.apple.CoreSimulator.SimRuntime.iOS-26-5"))
        XCTAssertTrue(SimulatorRuntimeCleaner.isValidIdentifier(Self.ios265ID))
        XCTAssertFalse(SimulatorRuntimeCleaner.isValidIdentifier("-rf"))
        XCTAssertFalse(SimulatorRuntimeCleaner.isValidIdentifier("a b"))
        XCTAssertFalse(SimulatorRuntimeCleaner.isValidIdentifier(""))
    }

    func testDeleteDropsDuplicateIdentifiers() {
        let runner = Runner()
        let outcome = SimulatorRuntimeCleaner.delete(
            identifiers: [Self.ios265ID, Self.ios265ID, Self.ios265ID],
            runner: runner,
            protection: openProtection,
            verificationTimeout: 0.5,
            pollInterval: 0,
            sleep: { _ in }
        )
        XCTAssertEqual(runner.deletedIdentifiers, [Self.ios265ID], "同一个 id 只删一次")
        XCTAssertEqual(outcome.removed, [Self.ios265ID])
    }

    func testDeleteFailsClosedWhenListUnavailable() {
        let runner = Runner()
        runner.listUnavailable = true
        runner.textOutput = "garbage that cannot be parsed"

        let outcome = SimulatorRuntimeCleaner.delete(
            identifiers: [Self.ios265ID],
            runner: runner,
            protection: openProtection,
            verificationTimeout: 0.2,
            pollInterval: 0,
            sleep: { _ in }
        )
        XCTAssertTrue(runner.deletedIdentifiers.isEmpty, "读不到列表时绝不删除")
        XCTAssertEqual(outcome.failures.map(\.id), [Self.ios265ID])
        XCTAssertTrue(outcome.failures.first?.message.contains("删除前无法确认 Runtime 列表") ?? false,
                      outcome.failures.first?.message ?? "")
    }

    // MARK: - installedRuntimes 兜底

    func testInstalledRuntimesFallsBackToTextWhenJSONUnparsable() throws {
        let runner = Runner()
        runner.dynamicJSON = false
        runner.jsonOutput = "not json at all"

        let runtimes = try SimulatorRuntimeCleaner.installedRuntimes(runner: runner)
        XCTAssertEqual(runtimes.map(\.identifier), [Self.ios265ID, Self.ios270ID],
                       "JSON 失败后应回退文本输出")
        XCTAssertTrue(runner.calls.contains { $0.arguments == ["runtime", "list"] })
    }

    func testInstalledRuntimesThrowsInsteadOfReturningEmpty() {
        let runner = Runner()
        runner.listUnavailable = true
        runner.textOutput = ""
        XCTAssertThrowsError(try SimulatorRuntimeCleaner.installedRuntimes(runner: runner)) { error in
            guard let typed = error as? SimulatorRuntimeCleanupError else {
                return XCTFail("应为 SimulatorRuntimeCleanupError：\(error)")
            }
            if case .listingFailed = typed {
                // 预期
            } else {
                XCTFail("应为 listingFailed：\(typed)")
            }
        }
    }

    // MARK: - 兜底命令

    func testFallbackCommandsOnlyContainValidIdentifiers() {
        let commands = SimulatorRuntimeCleaner.fallbackCommands(for: [Self.ios265ID, "--help", ""])
        let joined = commands.joined(separator: "\n")
        XCTAssertTrue(joined.contains("runtime delete \(Self.ios265ID)"), joined)
        XCTAssertFalse(joined.contains("runtime delete --help"), joined)
        XCTAssertTrue(joined.contains("runtime list"), joined)
        XCTAssertEqual(commands.filter { $0.contains("runtime delete") }.count, 1)
    }

    // MARK: - 5. XcodeActivityInspector

    func testActivityInspectorDetectsXcodeAndBuilds() {
        // Xcode.app 主进程 → xcodeRunning。
        let xcodeOnly = "1 /sbin/launchd\n501 /Applications/Xcode.app/Contents/MacOS/Xcode"
        if case let .xcodeRunning(detail) = XcodeActivityInspector.runningActivity(processList: xcodeOnly) {
            XCTAssertTrue(detail.contains("Xcode.app"), detail)
        } else {
            XCTFail("应为 xcodeRunning")
        }

        // xcodebuild → buildOrTestRunning，且优先于 Xcode 主进程。
        for command in ["/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild",
                        "/usr/bin/xctest",
                        "/Applications/Xcode.app/Contents/Developer/usr/bin/swift-test"] {
            let output = "1 /sbin/launchd\n501 /Applications/Xcode.app/Contents/MacOS/Xcode\n502 \(command)"
            if case .buildOrTestRunning = XcodeActivityInspector.runningActivity(processList: output) {
                // 预期
            } else {
                XCTFail("\(command) 应判定为构建/测试运行中")
            }
        }

        // 干净系统 → idle。
        XCTAssertEqual(XcodeActivityInspector.runningActivity(processList: "1 /sbin/launchd\n123 /usr/bin/ps"),
                       .idle)
    }

    func testActivityInspectorReturnsUnknownWhenProcessListUnavailable() {
        XCTAssertEqual(XcodeActivityInspector.runningActivity(processList: nil), .unknown)
        XCTAssertEqual(XcodeActivityInspector.runningActivity(processList: ""), .unknown)
        XCTAssertEqual(XcodeActivityInspector.runningActivity(processList: "   \n  "), .unknown)
        XCTAssertEqual(XcodeActivityInspector.runningActivity(processList: "garbage without pid"), .unknown)
    }

    func testProcessListReturnsNilWhenPSFails() {
        let failing = Runner()
        failing.processList = nil
        XCTAssertNil(XcodeActivityInspector.processList(runner: failing))
        XCTAssertEqual(XcodeActivityInspector.runningActivity(runner: failing), .unknown)

        let working = Runner()
        working.processList = "501 /Applications/Xcode.app/Contents/MacOS/Xcode"
        XCTAssertEqual(XcodeActivityInspector.processList(runner: working),
                       "501 /Applications/Xcode.app/Contents/MacOS/Xcode")
        if case .xcodeRunning = XcodeActivityInspector.runningActivity(runner: working) {
            // 预期
        } else {
            XCTFail("应通过 runner 判定为 xcodeRunning")
        }
    }

    func testActivityHintAndBusyFlags() {
        XCTAssertFalse(XcodeActivity.idle.isBusy)
        XCTAssertNil(XcodeActivity.idle.hint)
        XCTAssertTrue(XcodeActivity.xcodeRunning("Xcode").isBusy)
        XCTAssertTrue(XcodeActivity.buildOrTestRunning("xcodebuild").isBusy)
        XCTAssertFalse(XcodeActivity.unknown.isBusy)
        XCTAssertNotNil(XcodeActivity.unknown.hint)
        for activity in [XcodeActivity.xcodeRunning("X"), .buildOrTestRunning("Y"), .unknown] {
            XCTAssertNotNil(activity.hint)
            XCTAssertFalse(activity.hint?.contains("!") ?? false)
        }
    }

    // MARK: - 平台标题

    func testPlatformTitles() {
        XCTAssertEqual(SimulatorRuntimeCleaner.platformTitle("com.apple.platform.iphonesimulator"), "iOS")
        XCTAssertEqual(SimulatorRuntimeCleaner.platformTitle("com.apple.platform.watchsimulator"), "watchOS")
        XCTAssertEqual(SimulatorRuntimeCleaner.platformTitle("com.apple.platform.appletvsimulator"), "tvOS")
        XCTAssertEqual(SimulatorRuntimeCleaner.platformTitle("com.apple.platform.xrsimulator"), "visionOS")
        XCTAssertFalse(SimulatorRuntimeCleaner.platformTitle(nil).isEmpty)
    }
}
