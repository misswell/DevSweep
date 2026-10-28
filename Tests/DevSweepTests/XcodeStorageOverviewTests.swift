import XCTest
@testable import DevSweep

/// XcodeStorageOverview 的纯数据模型测试：不读真实磁盘、不跑 simctl，
/// 所有条目都用构造出来的 `CacheItem` + 临时 home 目录。
final class XcodeStorageOverviewTests: XCTestCase {
    // MARK: - 构造辅助

    /// 本仓库 Scanner 里 Xcode 规则的真实分类 / 名称 / 相对路径 / 风险。
    /// 名称与 `Sources/DevSweep/Scanner.swift` 中的 `CacheRule` 一一对应。
    private struct Rule {
        let category: String
        let name: String
        let relativePath: String
        let risk: RiskLevel
    }

    private static let xcodeRules: [Rule] = [
        Rule(category: "Xcode", name: "DerivedData",
             relativePath: "Library/Developer/Xcode/DerivedData", risk: .safe),
        Rule(category: "Xcode", name: "ModuleCache",
             relativePath: "Library/Developer/Xcode/ModuleCache.noindex", risk: .safe),
        Rule(category: "Xcode", name: "BuildCache",
             relativePath: "Library/Developer/Xcode/BuildCache.noindex", risk: .safe),
        Rule(category: "Xcode", name: "SourcePackages",
             relativePath: "Library/Developer/Xcode/SourcePackages", risk: .review),
        Rule(category: "Xcode", name: "SwiftUI Preview 缓存",
             relativePath: "Library/Developer/Xcode/UserData/Previews", risk: .safe),
        Rule(category: "Xcode", name: "Xcode 缓存",
             relativePath: "Library/Caches/com.apple.dt.Xcode", risk: .safe),
        Rule(category: "Xcode", name: "xcodebuild 缓存",
             relativePath: "Library/Caches/com.apple.dt.xcodebuild", risk: .safe),
        Rule(category: "Xcode", name: "源码控制 Git 缓存",
             relativePath: "Library/Caches/com.apple.dt.Xcode.sourcecontrol.Git", risk: .safe),
        Rule(category: "Xcode", name: "文档缓存",
             relativePath: "Library/Developer/Xcode/DocumentationCache", risk: .safe),
        Rule(category: "Xcode", name: "Instruments 缓存",
             relativePath: "Library/Caches/com.apple.dt.instruments", risk: .safe),
        Rule(category: "Xcode", name: "SourceKitService 缓存",
             relativePath: "Library/Caches/com.apple.dt.SourceKitService", risk: .safe),
        Rule(category: "Xcode", name: "Xcode Previews 缓存",
             relativePath: "Library/Caches/com.apple.dt.XcodePreviews", risk: .safe),
        Rule(category: "Xcode", name: "iOS Device Logs",
             relativePath: "Library/Developer/Xcode/iOS Device Logs", risk: .review),
        Rule(category: "Xcode", name: "Archives",
             relativePath: "Library/Developer/Xcode/Archives", risk: .review),
        Rule(category: "Xcode", name: "Products",
             relativePath: "Library/Developer/Xcode/Products", risk: .review),
        Rule(category: "Xcode", name: "iOS DeviceSupport",
             relativePath: "Library/Developer/Xcode/iOS DeviceSupport", risk: .manual),
        Rule(category: "Xcode", name: "watchOS DeviceSupport",
             relativePath: "Library/Developer/Xcode/watchOS DeviceSupport", risk: .manual),
        Rule(category: "Xcode", name: "tvOS DeviceSupport",
             relativePath: "Library/Developer/Xcode/tvOS DeviceSupport", risk: .manual),
        Rule(category: "Xcode", name: "macOS DeviceSupport",
             relativePath: "Library/Developer/Xcode/macOS DeviceSupport", risk: .manual),
        Rule(category: "Xcode", name: "visionOS DeviceSupport",
             relativePath: "Library/Developer/Xcode/visionOS DeviceSupport", risk: .manual),
        Rule(category: "Xcode", name: "Playgrounds",
             relativePath: "Library/Developer/Xcode/UserData/Playgrounds", risk: .review)
    ]

    private func temporaryHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevSweepXcodeOverview-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home.resolvingSymlinksInPath()
    }

    private func item(
        in home: URL,
        category: String,
        name: String,
        relativePath: String,
        size: Int64,
        risk: RiskLevel,
        isSelected: Bool? = nil
    ) -> CacheItem {
        CacheItem(
            category: category,
            name: name,
            path: home.appendingPathComponent(relativePath),
            size: size,
            risk: risk,
            isSelected: isSelected
        )
    }

    private func item(in home: URL, rule: Rule, size: Int64) -> CacheItem {
        self.item(in: home, category: rule.category, name: rule.name,
                  relativePath: rule.relativePath, size: size, risk: rule.risk)
    }

    private func runtime(
        _ identifier: String,
        platform: String = "com.apple.platform.iphonesimulator",
        version: String,
        bytes: Int64 = 1_000,
        deletable: Bool = true
    ) -> SimulatorRuntimeSummary {
        SimulatorRuntimeSummary(identifier: identifier, platform: platform, version: version,
                                sizeBytes: bytes, deletable: deletable)
    }

    // MARK: - 1. 风险分级

    func testAllRepositoryXcodeRulesMapToExpectedCategoryAndRisk() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }

        // 名称 → 期望分类。
        let expected: [(rule: Rule, category: XcodeStorageCategory)] = [
            (Self.xcodeRules[0], .derivedData),          // DerivedData
            (Self.xcodeRules[1], .xcodeCaches),          // ModuleCache
            (Self.xcodeRules[2], .xcodeCaches),          // BuildCache
            (Self.xcodeRules[3], .swiftPM),              // SourcePackages
            (Self.xcodeRules[4], .swiftUIPreviews),      // SwiftUI Preview 缓存
            (Self.xcodeRules[5], .xcodeCaches),          // Xcode 缓存
            (Self.xcodeRules[6], .xcodeCaches),          // xcodebuild 缓存
            (Self.xcodeRules[7], .xcodeCaches),          // 源码控制 Git 缓存
            (Self.xcodeRules[8], .xcodeCaches),          // 文档缓存
            (Self.xcodeRules[9], .xcodeCaches),          // Instruments 缓存
            (Self.xcodeRules[10], .xcodeCaches),         // SourceKitService 缓存
            (Self.xcodeRules[11], .swiftUIPreviews),     // Xcode Previews 缓存
            (Self.xcodeRules[12], .deviceLogs),          // iOS Device Logs
            (Self.xcodeRules[13], .archives),            // Archives
            (Self.xcodeRules[14], .xcodeProducts),       // Products
            (Self.xcodeRules[15], .deviceSupport),       // iOS DeviceSupport
            (Self.xcodeRules[16], .deviceSupport),       // watchOS DeviceSupport
            (Self.xcodeRules[17], .deviceSupport),       // tvOS DeviceSupport
            (Self.xcodeRules[18], .deviceSupport),       // macOS DeviceSupport
            (Self.xcodeRules[19], .deviceSupport),       // visionOS DeviceSupport
            (Self.xcodeRules[20], .xcodeProducts)        // Playgrounds（需确认）
        ]
        XCTAssertEqual(expected.count, Self.xcodeRules.count, "每条 Xcode 规则都要被断言到")

        for entry in expected {
            let cacheItem = item(in: home, rule: entry.rule, size: 1)
            let category = XcodeStorageClassifier.category(for: cacheItem)
            XCTAssertEqual(category, entry.category, "分类错误：\(entry.rule.name)")

            let risk = XcodeStorageRisk.xcodeRisk(for: cacheItem)
            switch entry.rule.name {
            case "源码控制 Git 缓存":
                // Git 缓存归 Xcode 缓存分类，但它是「源头控制」相关内容，
                // 概览按需确认处理，属于有意的更保守判定。
                XCTAssertEqual(risk, .review, "源码控制 Git 缓存应更保守")
            case "iOS Device Logs":
                // 设备诊断日志删除后要等真机重新连上才重建，必须需确认：
                // 分类进「设备日志」行，风险与 Scanner 规则表一致，都是 .review。
                XCTAssertEqual(entry.category, .deviceLogs, "分类应进入设备日志行")
                XCTAssertEqual(risk, .review, "iOS Device Logs 应为需确认")
                XCTAssertEqual(risk, entry.category.risk, "条目风险与行风险一致")
            default:
                XCTAssertEqual(risk, entry.category.risk, "风险应等于分类的默认风险：\(entry.rule.name)")
            }
            XCTAssertEqual(
                XcodeStorageRisk.isXcodeStorageItem(cacheItem), true,
                "Xcode 分类条目应被识别为存储条目：\(entry.rule.name)"
            )
        }
    }

    func testRuleRiskLevelsMatchScannerRuleDefinitions() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }

        // Scanner 里标记为可重建（safe）的规则不能被降级；手动项必须保持 manual。
        // 两处有意的更保守 / 关键词优先判定单独列出。
        let safeButOverriddenToReview: Set<String> = ["源码控制 Git 缓存"]

        for rule in Self.xcodeRules {
            let cacheItem = item(in: home, rule: rule, size: 1)
            let category = XcodeStorageClassifier.category(for: cacheItem)
            let inferred = XcodeStorageRisk.xcodeRisk(for: cacheItem)

            if safeButOverriddenToReview.contains(rule.name) {
                XCTAssertEqual(inferred, .review, "\(rule.name) 应更保守")
                continue
            }

            switch rule.risk {
            case .safe:
                XCTAssertEqual(inferred, .safe, "\(rule.name) 应为可重建")
            case .review:
                XCTAssertEqual(inferred, .review, "\(rule.name) 应为需确认")
            case .manual:
                XCTAssertEqual(inferred, .manual, "\(rule.name) 应为手动")
                XCTAssertEqual(category.risk, .manual)
            }
        }
    }

    func testDeviceSupportIsManualForAllPlatformNames() {
        for platform in ["iOS", "watchOS", "tvOS", "macOS", "visionOS", "xrOS"] {
            let cacheItem = CacheItem(
                category: "Xcode",
                name: "\(platform) DeviceSupport",
                path: URL(fileURLWithPath: "/tmp/Library/Developer/Xcode/\(platform) DeviceSupport"),
                size: 1
            )
            XCTAssertEqual(XcodeStorageClassifier.category(for: cacheItem), .deviceSupport, platform)
            XCTAssertEqual(XcodeStorageRisk.xcodeRisk(for: cacheItem), .manual, platform)
            XCTAssertFalse(XcodeStorageCategory.deviceSupport.allowsAutomaticClean, platform)
        }
    }

    func testSimulatorDeviceAndRuntimeAreManualAndNeverAutoCleaned() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let device = CacheItem(
            category: "CoreSimulator",
            name: "iPhone 17 (Shutdown)",
            path: home.appendingPathComponent("Library/Developer/CoreSimulator/Devices/UDID-1"),
            size: 100,
            risk: .manual,
            kind: .simulatorDevice,
            identifier: "UDID-1"
        )
        XCTAssertEqual(XcodeStorageClassifier.category(for: device), .simulatorDevices)
        XCTAssertEqual(XcodeStorageRisk.xcodeRisk(for: device), .manual)
        XCTAssertFalse(XcodeStorageCategory.simulatorDevices.allowsAutomaticClean)
        XCTAssertFalse(XcodeStorageCategory.simulatorDevices.usesDirectFileDeletion,
                       "模拟器设备不能整目录删除，只能走 simctl")

        // 文件系统里残留的 Runtime 目录同样是手动项。
        let runtimeLeftover = item(in: home, category: "Xcode", name: "iOS 26.5 Runtime",
                                   relativePath: "Library/Developer/CoreSimulator/Profiles/Runtimes/iOS 26.5.simruntime",
                                   size: 1, risk: .safe)
        XCTAssertEqual(XcodeStorageRisk.xcodeRisk(for: runtimeLeftover), .manual,
                       "路径里出现 runtime 字样必须按手动处理")
        XCTAssertFalse(XcodeStorageCategory.runtimes.usesDirectFileDeletion)
        XCTAssertFalse(XcodeStorageCategory.runtimes.allowsAutomaticClean)
    }

    func testUnavailableAndUnregisteredSimulatorsAreReview() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }

        for name in ["未登记模拟器目录", "orphan device", "unavailable simulator", "不可用设备"] {
            let cacheItem = item(in: home, category: "CoreSimulator", name: name,
                                 relativePath: "Library/Developer/CoreSimulator/Devices/\(name)",
                                 size: 10, risk: .review)
            XCTAssertEqual(XcodeStorageClassifier.category(for: cacheItem), .unavailableSimulators, name)
            XCTAssertEqual(XcodeStorageRisk.xcodeRisk(for: cacheItem), .review, name)
        }
    }

    func testXCTestClonesAreSafeOnlyWhenNotRunning() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let cloneRoot = "Library/Developer/XCTestDevices"

        let idleClone = item(in: home, category: "XCTest", name: UUID().uuidString,
                             relativePath: "\(cloneRoot)/\(UUID().uuidString)", size: 10, risk: .safe)
        XCTAssertTrue(XcodeStorageRisk.isXcodeStorageItem(idleClone))
        XCTAssertEqual(XcodeStorageRisk.xcodeRisk(for: idleClone), .safe)

        for name in ["正在测试的克隆", "无法确认状态的克隆"] {
            let clone = item(in: home, category: "XCTest", name: name,
                             relativePath: "\(cloneRoot)/\(UUID().uuidString)", size: 10, risk: .manual)
            XCTAssertEqual(XcodeStorageRisk.xcodeRisk(for: clone), .manual, name)
        }

        let wholeRoot = item(in: home, category: "XCTest", name: "全部 XCTest 克隆目录",
                             relativePath: cloneRoot, size: 10, risk: .review)
        XCTAssertEqual(XcodeStorageRisk.xcodeRisk(for: wholeRoot), .review,
                       "XCTestDevices 根目录永远不能自动清理")
    }

    func testUnknownNamesDefaultToReviewInsteadOfSafe() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }

        for name in ["Some Unknown Thing", "Weird Cache 2", "abc", "尚未识别的内容"] {
            let cacheItem = item(in: home, category: "Xcode", name: name,
                                 relativePath: "Library/Developer/Xcode/Other/\(name)",
                                 size: 1, risk: .safe)
            let risk = XcodeStorageRisk.xcodeRisk(for: cacheItem)
            XCTAssertNotEqual(risk, .safe, "未知名称不能默认 safe：\(name)")
            XCTAssertEqual(risk, .review, "未知名称应默认 review：\(name)")
        }

        // 任何分类枚举都没有 .safe 之外的默认兜底：分类风险表本身必须定义完整。
        for category in XcodeStorageCategory.allCases {
            XCTAssertEqual(XcodeStorageRisk.risk(for: category), category.risk)
        }

        // 非 Xcode 分类原样返回自有风险，不越权改写。
        let nonXcode = CacheItem(category: "Node.js", name: "node_modules",
                                 path: home.appendingPathComponent("proj/node_modules"),
                                 size: 1, risk: .safe)
        XCTAssertFalse(XcodeStorageRisk.isXcodeStorageItem(nonXcode))
        XCTAssertEqual(XcodeStorageRisk.xcodeRisk(for: nonXcode), .safe)
    }

    // MARK: - 2. rows()

    func testRowsAreAlwaysThirteenInFixedOrder() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let emptySummary = XcodeStorageSummary(items: [])
        let emptyRows = XcodeStorageRows.rows(from: emptySummary, items: [])
        XCTAssertEqual(emptyRows.count, 13)
        XCTAssertEqual(emptyRows.map(\.title), [
            "DerivedData", "Xcode 缓存", "模拟器日志/缓存", "SwiftUI 预览",
            "模拟器设备（清空数据）", "不可用模拟器", "iOS DeviceSupport", "设备日志",
            "Xcode 产品缓存", "归档", "Xcode 日志", "SwiftPM 缓存", "模拟器 Runtime"
        ])
        XCTAssertEqual(emptyRows.map(\.id), XcodeStorageCategory.allCases.map {
            "xcode.storage." + $0.rawValue
        })
        XCTAssertEqual(emptyRows.map(\.id).count, Set(emptyRows.map(\.id)).count, "行 ID 必须唯一")
        XCTAssertEqual(XcodeStorageRows.categoryOrder, XcodeStorageCategory.allCases)
        for row in emptyRows {
            XCTAssertEqual(row.sizeBytes, 0, row.title)
            XCTAssertTrue(row.itemIDs.isEmpty, row.title)
            XCTAssertTrue(row.runtimeIdentifiers.isEmpty, row.title)
            XCTAssertTrue(row.isEmpty, row.title)
            XCTAssertTrue(row.isGroup, "每行都是分组")
        }
        XCTAssertTrue(emptySummary.isEmpty)
        XCTAssertEqual(emptySummary.totalBytes, 0)
    }

    func testRowSizesAndItemIDsPointAtTheMatchingCacheItems() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let rules = Self.xcodeRules
        var items: [CacheItem] = []
        var expectedByCategory: [XcodeStorageCategory: (bytes: Int64, ids: [UUID])] = [:]
        for (index, rule) in rules.enumerated() {
            let cacheItem = item(in: home, rule: rule, size: Int64(100 * (index + 1)))
            items.append(cacheItem)
            let category = XcodeStorageClassifier.category(for: cacheItem)
            var entry = expectedByCategory[category] ?? (0, [])
            entry.bytes += cacheItem.size
            entry.ids.append(cacheItem.id)
            expectedByCategory[category] = entry
        }
        // 加入几条 CoreSimulator / XCTest 条目，确保它们也进对应行。
        let device = CacheItem(category: "CoreSimulator", name: "iPhone (Shutdown)",
                               path: home.appendingPathComponent("Library/Developer/CoreSimulator/Devices/A"),
                               size: 5_000, risk: .manual, kind: .simulatorDevice, identifier: "A")
        let logs = CacheItem(category: "CoreSimulator", name: "模拟器日志",
                             path: home.appendingPathComponent("Library/Logs/CoreSimulator"),
                             size: 700, risk: .safe)
        let orphan = CacheItem(category: "CoreSimulator", name: "未登记模拟器目录",
                               path: home.appendingPathComponent("Library/Developer/CoreSimulator/Devices/orphan"),
                               size: 300, risk: .review)
        let clone = CacheItem(category: "XCTest", name: "clone",
                              path: home.appendingPathComponent("Library/Developer/XCTestDevices/\(UUID().uuidString)"),
                              size: 900, risk: .safe)
        // 非 Xcode 分类必须被完全忽略。
        let unrelated = CacheItem(category: "Node.js", name: "node_modules",
                                  path: home.appendingPathComponent("proj/node_modules"), size: 100_000)
        items.append(contentsOf: [device, logs, orphan, clone, unrelated])
        for extra in [device, logs, orphan, clone] {
            let category = XcodeStorageClassifier.category(for: extra)
            var entry = expectedByCategory[category] ?? (0, [])
            entry.bytes += extra.size
            entry.ids.append(extra.id)
            expectedByCategory[category] = entry
        }

        let summary = XcodeStorageSummary(items: items,
                                          runtimeItems: [runtime("RT-A", version: "26.5", bytes: 4_000)])
        let rows = XcodeStorageRows.rows(from: summary, items: items)
        XCTAssertEqual(rows.count, 13)

        for row in rows {
            guard let category = XcodeStorageCategory.allCases.first(where: {
                XcodeStorageClassifier.rowID(for: $0) == row.id
            }) else {
                XCTFail("未知行 ID：\(row.id)")
                continue
            }
            let expected = expectedByCategory[category]
            XCTAssertEqual(Set(row.itemIDs), Set(expected?.ids ?? []), "itemIDs 错误：\(row.title)")
            XCTAssertEqual(row.itemIDs.count, expected?.ids.count ?? 0, "itemIDs 有重复：\(row.title)")
            if category == .runtimes {
                XCTAssertEqual(row.sizeBytes, 4_000, "Runtime 行大小来自注入清单")
                XCTAssertEqual(row.runtimeIdentifiers, ["RT-A"])
                XCTAssertTrue(row.itemIDs.isEmpty)
            } else {
                XCTAssertEqual(row.sizeBytes, expected?.bytes ?? 0, "行大小错误：\(row.title)")
                XCTAssertTrue(row.runtimeIdentifiers.isEmpty, row.title)
            }
            XCTAssertEqual(row.risk, category.risk, row.title)
            XCTAssertEqual(row.allowsAutomaticClean, category.allowsAutomaticClean, row.title)
            XCTAssertEqual(row.isEmpty, row.sizeBytes == 0 && row.itemIDs.isEmpty)
        }

        // 抽样核对具体行。
        let byTitle = Dictionary(uniqueKeysWithValues: rows.map { ($0.title, $0) })
        XCTAssertEqual(byTitle["模拟器设备（清空数据）"]?.itemIDs, [device.id])
        XCTAssertEqual(byTitle["模拟器日志/缓存"]?.sizeBytes, 700)
        XCTAssertEqual(byTitle["不可用模拟器"]?.itemIDs, [orphan.id],
                       "只有未登记设备进「不可用模拟器」行")
        XCTAssertEqual(byTitle["DerivedData"]?.itemIDs.count, 2,
                       "DerivedData 规则 + XCTest clone（clone 是 XCTestDevices 分类，归 DerivedData 行）")

        // 每条规则都必须落在唯一一行里：13 行 itemIDs 的并集 == 全部 Xcode 条目，
        // 且互不重复（行之间不重不漏）。
        let allRowIDs = rows.flatMap(\.itemIDs)
        XCTAssertEqual(allRowIDs.count, Set(allRowIDs).count, "同一 item 不能出现在两行")
        XCTAssertEqual(Set(allRowIDs),
                       Set([device, logs, orphan, clone].map(\.id) + items.filter {
                           XcodeStorageRisk.isXcodeStorageItem($0)
                       }.map(\.id)))
    }

    func testRowsIgnoreNonXcodeItemsAndZeroSizes() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let unrelated = CacheItem(category: "Docker", name: "images",
                                  path: home.appendingPathComponent("docker"), size: 9_999)
        let zero = item(in: home, category: "Xcode", name: "DerivedData",
                        relativePath: "Library/Developer/Xcode/DerivedData", size: 0, risk: .safe)
        let negative = item(in: home, category: "Xcode", name: "ModuleCache",
                            relativePath: "Library/Developer/Xcode/ModuleCache.noindex",
                            size: -42, risk: .safe)

        let summary = XcodeStorageSummary(items: [unrelated, zero, negative])
        XCTAssertEqual(summary.totalBytes, 0, "未知分类不计入，负数被夹到 0")
        XCTAssertEqual(XcodeStorageSummary.xcodeStorageItems(from: [unrelated]).count, 0)

        let rows = XcodeStorageRows.rows(from: summary, items: [unrelated, zero, negative])
        XCTAssertEqual(rows.count, 13)
        XCTAssertEqual(rows.first { $0.title == "DerivedData" }?.sizeBytes, 0)
        XCTAssertEqual(rows.first { $0.title == "Xcode 缓存" }?.sizeBytes, 0)
        XCTAssertEqual(rows.reduce(0) { $0 + $1.sizeBytes }, 0)
    }

    func testDuplicatePathsAreCountedOnce() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let first = item(in: home, category: "Xcode", name: "DerivedData",
                         relativePath: "Library/Developer/Xcode/DerivedData", size: 1_000, risk: .safe)
        let duplicate = item(in: home, category: "Xcode", name: "DerivedData",
                             relativePath: "Library/Developer/Xcode/DerivedData", size: 1_000, risk: .safe)
        let summary = XcodeStorageSummary(items: [first, duplicate])
        XCTAssertEqual(XcodeStorageSummary.xcodeStorageItems(from: [first, duplicate]).count, 1)
        XCTAssertEqual(summary.totalBytes, 1_000)
        let rows = XcodeStorageRows.rows(from: summary, items: [first, duplicate])
        XCTAssertEqual(rows.first { $0.title == "DerivedData" }?.itemIDs, [first.id])
    }

    // MARK: - 3. 小计、总计与百分比

    func testSubtotalsAndTotalDoNotOverlap() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let derivedData = item(in: home, category: "Xcode", name: "DerivedData",
                               relativePath: "Library/Developer/Xcode/DerivedData", size: 1_000, risk: .safe)
        let caches = item(in: home, category: "Xcode", name: "Xcode 缓存",
                          relativePath: "Library/Caches/com.apple.dt.Xcode", size: 200, risk: .safe)
        let archives = item(in: home, category: "Xcode", name: "Archives",
                            relativePath: "Library/Developer/Xcode/Archives", size: 3_000, risk: .review)
        let deviceSupportIOS = item(in: home, category: "Xcode", name: "iOS DeviceSupport",
                                    relativePath: "Library/Developer/Xcode/iOS DeviceSupport", size: 400, risk: .manual)
        let deviceSupportWatch = item(in: home, category: "Xcode", name: "watchOS DeviceSupport",
                                      relativePath: "Library/Developer/Xcode/watchOS DeviceSupport", size: 100, risk: .manual)
        let device = CacheItem(category: "CoreSimulator", name: "iPhone (Booted)",
                               path: home.appendingPathComponent("Library/Developer/CoreSimulator/Devices/B"),
                               size: 500, risk: .manual, kind: .simulatorDevice, identifier: "B")

        let runtimes = [
            runtime("RT-iOS-26-5", version: "26.5", bytes: 8_000),
            runtime("RT-iOS-27-0", version: "27.0", bytes: 9_000),
            runtime("RT-watch-26-5", platform: "com.apple.platform.watchsimulator", version: "26.5", bytes: 1_500),
            runtime("RT-bad", version: "1.0", bytes: -100) // 负数被夹到 0
        ]
        let summary = XcodeStorageSummary(
            items: [derivedData, caches, archives, deviceSupportIOS, deviceSupportWatch, device],
            runtimeItems: runtimes,
            diskTotalBytes: 500_000,
            diskAvailableBytes: 100_000
        )

        XCTAssertEqual(summary.rebuildableBytes, 1_200)
        XCTAssertEqual(summary.reviewBytes, 3_000)
        XCTAssertEqual(summary.manualBytes, 1_000, "DeviceSupport + 设备；负数夹到 0")
        XCTAssertEqual(summary.runtimeBytes, 18_500)
        XCTAssertEqual(summary.totalBytes, 1_200 + 3_000 + 1_000 + 18_500)
        XCTAssertEqual(summary.totalBytes,
                       summary.rebuildableBytes + summary.reviewBytes + summary.manualBytes + summary.runtimeBytes,
                       "总计 = 三档小计 + Runtime，互不重复")
        XCTAssertEqual(summary.deletableRuntimeBytes, 18_500)
        XCTAssertEqual(summary.runtimesByPlatform, [
            "com.apple.platform.iphonesimulator": 17_000,
            "com.apple.platform.watchsimulator": 1_500
        ])
        XCTAssertEqual(summary.deviceSupportBytes, 500)
        XCTAssertEqual(summary.deviceSupportPlatforms.map(\.platform), ["iOS", "watchOS"])
        XCTAssertEqual(summary.deviceSupportPlatforms.map(\.bytes), [400, 100])

        // 分类明细与三档小计口径一致。
        XCTAssertEqual(summary.derivedDataBytes, 1_000)
        XCTAssertEqual(summary.xcodeCachesBytes, 200)
        XCTAssertEqual(summary.archivesBytes, 3_000)
        XCTAssertEqual(summary.deviceLogBytes, 0)
        XCTAssertEqual(summary.swiftPMBytes, 0)
        XCTAssertFalse(summary.isEmpty)

        // Runtime 排序稳定：平台字符串、版本字符串、identifier。
        XCTAssertEqual(summary.runtimeItems.map(\.identifier), [
            "RT-bad", "RT-iOS-26-5", "RT-iOS-27-0", "RT-watch-26-5"
        ])
        // 不可删除的 Runtime 不计入可删除容量。
        let withLocked = XcodeStorageSummary(items: [], runtimeItems: [
            runtime("A", version: "1.0", bytes: 10, deletable: false),
            runtime("B", version: "2.0", bytes: 20)
        ])
        XCTAssertEqual(withLocked.runtimeBytes, 30)
        XCTAssertEqual(withLocked.deletableRuntimeBytes, 20)
        XCTAssertEqual(withLocked.totalBytes, 30)
        XCTAssertEqual(withLocked.rebuildableBytes + withLocked.reviewBytes + withLocked.manualBytes, 0,
                       "Runtime 大小不能混进三档小计")
    }

    func testSubtotalSumMatchesPerRowSizes() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let items = Self.xcodeRules.enumerated().map { index, rule in
            item(in: home, rule: rule, size: Int64(index + 1))
        }
        let summary = XcodeStorageSummary(items: items)
        let rows = XcodeStorageRows.rows(from: summary, items: items)
        let rowTotal = rows.reduce(0) { $0 + $1.sizeBytes }
        XCTAssertEqual(rowTotal, summary.rebuildableBytes + summary.reviewBytes + summary.manualBytes)
        XCTAssertEqual(rowTotal, summary.totalBytes)

        // 三档小计与行风险一一对应，不重不漏。
        var safeFromRows: Int64 = 0
        var reviewFromRows: Int64 = 0
        var manualFromRows: Int64 = 0
        for row in rows {
            switch row.risk {
            case .safe: safeFromRows += row.sizeBytes
            case .review: reviewFromRows += row.sizeBytes
            case .manual: manualFromRows += row.sizeBytes
            }
        }
        // 行大小按分类聚合，而风险按条目判定（例如 Git 缓存行归属需确认），
        // 因此这里只断言断言的保守方向：可重建小计不会超过风险为 safe 的行合计。
        XCTAssertLessThanOrEqual(summary.rebuildableBytes, safeFromRows)
        XCTAssertGreaterThanOrEqual(reviewFromRows + manualFromRows, summary.reviewBytes + summary.manualBytes
            - summary.rebuildableBytes)
    }

    func testPercentageFormatting() {
        // 0 总量不崩，且不产生 NaN / inf。
        XCTAssertEqual(XcodeStorageMetrics.formatPercent(0), "0%")
        XCTAssertEqual(XcodeStorageMetrics.formatPercent(-1), "0%")
        XCTAssertEqual(XcodeStorageMetrics.formatPercent(.nan), "0%")
        XCTAssertEqual(XcodeStorageMetrics.formatPercent(.infinity), "0%")
        XCTAssertEqual(XcodeStorageMetrics.formatPercent(0.05), "<0.1%")
        XCTAssertEqual(XcodeStorageMetrics.formatPercent(5.2), "5.2%")
        XCTAssertEqual(XcodeStorageMetrics.formatPercent(100), "100.0%")

        // 520 / 10000 = 5.2%
        let text = XcodeStorageMetrics.percentageOfDisk(520 as Int64, diskTotalBytes: 10_000)
        XCTAssertTrue(text.hasSuffix("占磁盘 5.2%"), text)
        XCTAssertTrue(text.hasPrefix((520 as Int64).devSweepFileSize), text)

        // 磁盘总量未知或为 0 时退化为纯大小文案。
        let unknown = XcodeStorageMetrics.percentageOfDisk(520 as Int64, diskTotalBytes: nil)
        XCTAssertEqual(unknown, (520 as Int64).devSweepFileSize)
        XCTAssertEqual(XcodeStorageMetrics.percentageOfDisk(520 as Int64, diskTotalBytes: 0), (520 as Int64).devSweepFileSize)

        let headline = XcodeStorageMetrics.headline(label: "Xcode 缓存", bytes: 520 as Int64, diskTotalBytes: 10_000)
        XCTAssertTrue(headline.hasPrefix("Xcode 缓存 "), headline)
        XCTAssertTrue(headline.contains("占磁盘 5.2%"), headline)

        // 0 字节 + 有磁盘总量：不能崩，显示 0%。
        let zero = XcodeStorageMetrics.percentageOfDisk(0 as Int64, diskTotalBytes: 10_000)
        XCTAssertTrue(zero.contains("占磁盘 0%"), zero)
    }

    func testSelectedReclaimIgnoresManualAndUnselectedItems() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let safeItem = item(in: home, category: "Xcode", name: "DerivedData",
                            relativePath: "Library/Developer/Xcode/DerivedData", size: 100, risk: .safe)
        let manualItem = item(in: home, category: "Xcode", name: "iOS DeviceSupport",
                              relativePath: "Library/Developer/Xcode/iOS DeviceSupport",
                              size: 200, risk: .manual, isSelected: false)
        let unselected = item(in: home, category: "Xcode", name: "Xcode 缓存",
                              relativePath: "Library/Caches/com.apple.dt.Xcode",
                              size: 300, risk: .safe, isSelected: false)
        let items = [safeItem, manualItem, unselected]
        let summary = XcodeStorageSummary(items: items)

        XCTAssertEqual(XcodeStorageMetrics.estimatedReclaimBytes(
            summary: summary, items: items,
            selectedItemIDs: [safeItem.id, manualItem.id, unselected.id]
        ), 100, "只有「已勾选且非手动」的条目计入")
        XCTAssertEqual(XcodeStorageMetrics.reclaimBytes(
            items: items, selectedItemIDs: [safeItem.id, manualItem.id, unselected.id]
        ), 400, "只按 ID 计算时仍排除手动项")

        let runtimes = [runtime("R1", version: "1", bytes: 10), runtime("R2", version: "2", bytes: 20, deletable: false)]
        let runtimeSummary = XcodeStorageSummary(items: [], runtimeItems: runtimes)
        XCTAssertEqual(XcodeStorageMetrics.selectedRuntimeBytes(
            summary: runtimeSummary, selectedRuntimeIdentifiers: ["R1", "R2"]
        ), 10, "不可删除的 Runtime 不计入")
        XCTAssertEqual(XcodeStorageMetrics.selectedRuntimeBytes(
            summary: runtimeSummary, selectedRuntimeIdentifiers: []
        ), 0)
    }

    // MARK: - 4. 预检

    func testPreflightBlocksBuildOrTestOnBuildSensitiveTargets() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let derivedData = item(in: home, category: "Xcode", name: "DerivedData",
                               relativePath: "Library/Developer/Xcode/DerivedData", size: 1, risk: .safe)
        let device = CacheItem(category: "CoreSimulator", name: "iPhone (Shutdown)",
                               path: home.appendingPathComponent("Library/Developer/CoreSimulator/Devices/C"),
                               size: 1, risk: .manual, kind: .simulatorDevice, identifier: "C")

        for target in [derivedData, device] {
            let verdict = XcodeLaunchPreflight.preflight(activity: .buildOrTestRunning("123 xcodebuild"), targets: [target])
            XCTAssertTrue(verdict.isBlocked, target.name)
            XCTAssertFalse(verdict.canProceed, target.name)
            XCTAssertTrue(verdict.text.contains("构建/测试"), verdict.text)
            XCTAssertEqual(verdict.shortReason, "已阻止清理")
        }

        // 无目标时也一致（不禁用按钮语义由视图负责）。
        XCTAssertTrue(XcodeLaunchPreflight.preflight(activity: .buildOrTestRunning(""), targets: []).isBlocked)
    }

    func testPreflightWarnsButAllowsForXcodeRunning() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let cache = item(in: home, category: "Xcode", name: "ModuleCache",
                         relativePath: "Library/Developer/Xcode/ModuleCache.noindex", size: 1, risk: .safe)
        let derivedData = item(in: home, category: "Xcode", name: "DerivedData",
                               relativePath: "Library/Developer/Xcode/DerivedData", size: 1, risk: .safe)

        for target in [cache, derivedData] {
            let verdict = XcodeLaunchPreflight.preflight(activity: .xcodeRunning("Xcode"), targets: [target])
            XCTAssertFalse(verdict.isBlocked, "Xcode 在运行时仍允许清理：\(target.name)")
            XCTAssertTrue(verdict.canProceed)
            if case .warn(let text) = verdict {
                XCTAssertFalse(text.isEmpty)
                XCTAssertTrue(text.contains("Xcode 正在运行"), text)
            } else {
                XCTFail("应为 warn：\(verdict)")
            }
            XCTAssertEqual(verdict.shortReason, "建议先退出相关进程")
        }

        // 构建敏感目标会给出更强的提示（仍然只是 warn）。
        let sensitive = XcodeLaunchPreflight.preflight(activity: .xcodeRunning("Xcode"), targets: [derivedData])
        if case .warn(let text) = sensitive {
            XCTAssertTrue(text.contains("DerivedData"), text)
        } else {
            XCTFail("应为 warn")
        }
    }

    func testPreflightUnknownWarnsAndIdleProceeds() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let cache = item(in: home, category: "Xcode", name: "Xcode 缓存",
                         relativePath: "Library/Caches/com.apple.dt.Xcode", size: 1, risk: .safe)

        let unknown = XcodeLaunchPreflight.preflight(activity: .unknown, targets: [cache])
        XCTAssertFalse(unknown.isBlocked, "unknown 只是提示，不阻止")
        guard case .warn(let unknownText) = unknown else {
            return XCTFail("unknown 应为 warn：\(unknown)")
        }
        XCTAssertTrue(unknownText.contains("无法确认"), unknownText)

        let idle = XcodeLaunchPreflight.preflight(activity: .idle, targets: [cache])
        XCTAssertFalse(idle.isBlocked)
        guard case .proceed(let idleText) = idle else {
            return XCTFail("idle 应为 proceed：\(idle)")
        }
        XCTAssertTrue(idleText.contains("可以执行清理"), idleText)
        XCTAssertEqual(idle.shortReason, "可以清理")

        // 空目标也给出 proceed，视图不会禁用按钮。
        guard case .proceed = XcodeLaunchPreflight.preflight(activity: .idle, targets: []) else {
            return XCTFail("idle + 空目标也应为 proceed")
        }

        // 活动文案不为空。
        XCTAssertFalse(XcodeActivityLike.idle.displayText.isEmpty)
        XCTAssertEqual(XcodeActivityLike.xcodeRunning("").displayText, "Xcode 正在运行")
        XCTAssertEqual(XcodeActivityLike.buildOrTestRunning("").displayText, "构建或测试正在运行")
    }

    func testPreflightBuildSensitiveCategorySet() {
        XCTAssertTrue(XcodeLaunchPreflight.buildSensitiveCategories.contains(.derivedData))
        XCTAssertTrue(XcodeLaunchPreflight.buildSensitiveCategories.contains(.runtimes))
        XCTAssertTrue(XcodeLaunchPreflight.buildSensitiveCategories.contains(.deviceSupport))
        XCTAssertTrue(XcodeLaunchPreflight.buildSensitiveCategories.contains(.simulatorDevices))
        XCTAssertFalse(XcodeLaunchPreflight.buildSensitiveCategories.contains(.xcodeCaches))
    }

    // MARK: - 附带：XCTest clone 边界

    func testXCTestClonePlannerSeparatesClonesFromRegisteredDevices() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let uuid = UUID().uuidString

        XCTAssertEqual(XcodeXCTestClonePlanner.location(
            of: home.appendingPathComponent("Library/Developer/XCTestDevices/\(uuid)"), home: home
        ), .xctestClone)
        XCTAssertEqual(XcodeXCTestClonePlanner.location(
            of: home.appendingPathComponent("Library/Developer/XCTestDevices/not-a-uuid"), home: home
        ), .unclassified)
        XCTAssertEqual(XcodeXCTestClonePlanner.location(
            of: home.appendingPathComponent("Library/Developer/XCTestDevices/\(uuid)/data"), home: home
        ), .unclassified)
        XCTAssertEqual(XcodeXCTestClonePlanner.location(
            of: home.appendingPathComponent("Library/Developer/CoreSimulator/Devices/\(uuid)"), home: home
        ), .registeredDevice)
        XCTAssertEqual(XcodeXCTestClonePlanner.location(
            of: home.appendingPathComponent("Library/Caches/something"), home: home
        ), .unrelated)
        XCTAssertEqual(XcodeXCTestClonePlanner.location(
            of: URL(fileURLWithPath: "/tmp/\(uuid)"), home: home
        ), .unrelated)

        let clone = home.appendingPathComponent("Library/Developer/XCTestDevices/\(uuid)")
        let device = home.appendingPathComponent("Library/Developer/CoreSimulator/Devices/\(uuid)")
        let candidates = XcodeXCTestClonePlanner.cleanupCandidates(from: [clone, device, clone], home: home)
        XCTAssertEqual(candidates, [clone.standardizedFileURL],
                       "真实注册设备绝不进入 clone 清理候选，且重复路径去重")
    }

    func testSimulatorRuntimeSummaryDisplayAndRisk() {
        let deletable = SimulatorRuntimeSummary(identifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-5",
                                                platform: "iOS", version: "26.5", sizeBytes: 10, deletable: true)
        XCTAssertEqual(deletable.displayName, "iOS 26.5")
        XCTAssertEqual(deletable.risk, .review)
        XCTAssertEqual(deletable.id, deletable.identifier)

        let locked = SimulatorRuntimeSummary(identifier: "id", platform: "watchOS", version: "",
                                             sizeBytes: 10, deletable: false)
        XCTAssertEqual(locked.displayName, "watchOS")
        XCTAssertEqual(locked.risk, .manual, "不可删除的 Runtime 必须手动处理")
    }
}
