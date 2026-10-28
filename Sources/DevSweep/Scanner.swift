import AppKit
import Combine
import Foundation

private struct CacheRule {
    let category: String
    let name: String
    let relativePath: String
    let risk: RiskLevel
    let note: String
}

struct GeneratedRule {
    let category: String
    let risk: RiskLevel
    let note: String
}

/// 固定缓存规则的绝对路径。发现页用它区分「已验证的已知缓存」和未知占用。
struct KnownCacheLocation: Hashable {
    let url: URL
    let category: String
    let name: String
    let risk: RiskLevel
    let note: String
}

fileprivate typealias ProcessOutput = ProcessResult

fileprivate enum DockerSupport {
    static func executableURL() -> URL? {
        let pathEntries = ProcessInfo.processInfo.environment["PATH"]?
            .split(separator: ":")
            .map { String($0) } ?? []
        let candidates = pathEntries.map { URL(fileURLWithPath: $0).appendingPathComponent("docker") } + [
            URL(fileURLWithPath: "/opt/homebrew/bin/docker"),
            URL(fileURLWithPath: "/usr/local/bin/docker"),
            URL(fileURLWithPath: "/Applications/Docker.app/Contents/Resources/bin/docker")
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func run(arguments: [String]) -> ProcessOutput? {
        guard let executable = executableURL() else { return nil }
        guard isLocalContext(executable: executable) else { return nil }
        return CacheScanner.run(executable: executable.path, arguments: arguments)
    }

    private static func isLocalContext(executable: URL) -> Bool {
        if let configuredHost = ProcessInfo.processInfo.environment["DOCKER_HOST"],
           !configuredHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return isLocalEndpoint(configuredHost)
        }

        guard let output = CacheScanner.run(
            executable: executable.path,
            arguments: ["context", "inspect", "--format", "{{.Endpoints.docker.Host}}"]
        ),
        output.status == 0,
        let text = String(data: output.stdout, encoding: .utf8) else {
            return false
        }

        let endpoints = text
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return !endpoints.isEmpty && endpoints.allSatisfy(isLocalEndpoint)
    }

    private static func isLocalEndpoint(_ value: String) -> Bool {
        let endpoint = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if endpoint.hasPrefix("unix://") { return true }
        guard let url = URL(string: endpoint), url.scheme?.lowercased() == "tcp" else { return false }
        return ["localhost", "127.0.0.1", "::1"].contains(url.host?.lowercased() ?? "")
    }
}

struct ScanCollector {
    var checkedPaths = 0
    var skippedPaths = 0
    var permissionFailures = 0
    var diagnostics: [ScanDiagnostic] = []

    mutating func checked(_ path: URL) {
        checkedPaths += 1
    }

    mutating func skipped(_ path: URL, reason: String, kind: ScanIssueKind) {
        skippedPaths += 1
        if diagnostics.count < 100 {
            diagnostics.append(ScanDiagnostic(path: path, reason: reason, kind: kind))
        }
        if kind == .inaccessible {
            permissionFailures += 1
        }
    }
}

struct CacheScanner {
    private static let fileManager = FileManager.default
    private static let minimumItemSize: Int64 = 1 * 1024 * 1024

    static func scan(
        projectRoots: [URL],
        deepScan: Bool,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        includeSystemCaches: Bool = true,
        xctestActivityInspector: XCTestActivityInspecting = XCTestActivityInspector(),
        simulatorRuntimeLister: SimulatorRuntimeListing = SimulatorRuntimeLister(),
        timeMachineSnapshotLister: TimeMachineSnapshotListing = TimeMachineSnapshotLister(),
        progress: @escaping (ScanProgress) -> Void,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ScanReport {
        let startedAt = Date()
        var collector = ScanCollector()
        let roots = normalizedRoots(projectRoots)

        progress(ScanProgress(phase: "扫描固定开发者缓存"))
        var items = fixedItems(home: home, collector: &collector, progress: progress)
        if includeSystemCaches {
            items += systemItems(collector: &collector, progress: progress)
        }

        progress(ScanProgress(
            phase: "发现可配置的工具链缓存",
            checkedPaths: collector.checkedPaths,
            matchedPaths: items.count,
            skippedPaths: collector.skippedPaths,
            permissionFailures: collector.permissionFailures
        ))
        items += dynamicItems(
            home: home,
            environment: environment,
            collector: &collector,
            progress: progress
        )

        progress(ScanProgress(
            phase: "扫描软件升级残留",
            checkedPaths: collector.checkedPaths,
            matchedPaths: items.count,
            skippedPaths: collector.skippedPaths,
            permissionFailures: collector.permissionFailures
        ))
        items += softwareUpdateResidues(
            home: home,
            includeSystemLocations: includeSystemCaches,
            collector: &collector,
            progress: progress
        )

        progress(ScanProgress(
            phase: "检查 Docker 容器资源",
            checkedPaths: collector.checkedPaths,
            matchedPaths: items.count,
            skippedPaths: collector.skippedPaths,
            permissionFailures: collector.permissionFailures
        ))
        items += dockerItems(home: home, collector: &collector, progress: progress)

        progress(ScanProgress(
            phase: "检查 AI Agent 请求日志",
            checkedPaths: collector.checkedPaths,
            matchedPaths: items.count,
            skippedPaths: collector.skippedPaths,
            permissionFailures: collector.permissionFailures
        ))
        items += requestLogItems(home: home, collector: &collector, progress: progress)

        progress(ScanProgress(
            phase: "检查模拟器和 XCTest 设备",
            checkedPaths: collector.checkedPaths,
            matchedPaths: items.count,
            skippedPaths: collector.skippedPaths,
            permissionFailures: collector.permissionFailures
        ))
        items += xctestDeviceItems(
            home: home,
            xctestActivityInspector: xctestActivityInspector,
            collector: &collector,
            progress: progress
        )
        items += simulatorItems(home: home, collector: &collector, progress: progress)

        // 模拟器 Runtime 不是普通文件缓存：必须通过 `simctl runtime delete`
        // 删除，直接删目录会让 CoreSimulator 登记与实际磁盘脱节。
        progress(ScanProgress(
            phase: "检查模拟器 Runtime",
            checkedPaths: collector.checkedPaths,
            matchedPaths: items.count,
            skippedPaths: collector.skippedPaths,
            permissionFailures: collector.permissionFailures
        ))
        items += simulatorRuntimeItems(
            runtimeLister: simulatorRuntimeLister,
            home: home,
            collector: &collector
        )

        progress(ScanProgress(
            phase: "检查 Time Machine 本地快照",
            checkedPaths: collector.checkedPaths,
            matchedPaths: items.count,
            skippedPaths: collector.skippedPaths,
            permissionFailures: collector.permissionFailures
        ))
        items += timeMachineSnapshotItems(
            snapshotLister: timeMachineSnapshotLister,
            collector: &collector
        )

        for root in roots {
            progress(ScanProgress(
                phase: deepScan ? "深度扫描项目生成物" : "扫描项目生成物",
                currentPath: root.devSweepDisplayPath,
                checkedPaths: collector.checkedPaths,
                matchedPaths: items.count,
                skippedPaths: collector.skippedPaths,
                permissionFailures: collector.permissionFailures
            ))
            items += projectArtifacts(
                in: root,
                deepScan: deepScan,
                collector: &collector,
                progress: progress
            )
        }

        // Scanner 只负责「机器上发现了什么」；白名单等用户规则由 DevSweepStore
        // 在 rebuildItems() 中统一套用，这样加入/移出白名单都不需要重新扫描。
        // 严格弱序：先比标准化路径，路径相同再让官方清理命令优先。
        // 原写法在路径不同时一律返回 false，破坏排序契约（结果顺序未定义），
        // 而随后的 nonOverlappingItems 依赖「同路径里先出现的胜出」，
        // 顺序不定就可能保留错的操作类型。
        let candidates = items
            .sorted { left, right in
                let leftPath = left.path.standardizedFileURL.path
                let rightPath = right.path.standardizedFileURL.path
                if leftPath != rightPath { return leftPath < rightPath }
                let leftRank = left.kind == .toolCommand ? 0 : 1
                let rightRank = right.kind == .toolCommand ? 0 : 1
                if leftRank != rightRank { return leftRank < rightRank }
                return left.name.localizedStandardCompare(right.name) == .orderedAscending
            }
        // 体积未知的特殊操作项（Time Machine 快照不报告单个体积）不能因为
        // size == 0 就被丢掉：它连 UI 都进不去，功能等于不存在。
        let uniqueItems = nonOverlappingItems(candidates)
        .filter { $0.size >= minimumItemSize || $0.kind.isSizeAgnostic }
        .sorted {
            if $0.size == $1.size { return $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return $0.size > $1.size
        }

        let finalProgress = ScanProgress(
            phase: "扫描完成",
            checkedPaths: collector.checkedPaths,
            matchedPaths: uniqueItems.count,
            skippedPaths: collector.skippedPaths,
            permissionFailures: collector.permissionFailures
        )
        progress(finalProgress)

        return ScanReport(
            scannedRoots: roots,
            items: uniqueItems,
            checkedPaths: collector.checkedPaths,
            matchedPaths: uniqueItems.count,
            skippedPaths: collector.skippedPaths,
            permissionFailures: collector.permissionFailures,
            incompleteMeasurements: uniqueItems.filter { $0.sizeWarning != nil }.count,
            diagnostics: collector.diagnostics,
            duration: Date().timeIntervalSince(startedAt)
        )
    }

    static func nonOverlappingItems(_ items: [CacheItem]) -> [CacheItem] {
        var kept: [CacheItem] = []
        // 「清空内容」的根目录（~/Library/Caches 等）必须与其中的叶子项共存：
        // 根条目代表「清空全部」，叶子条目代表「只清其中某项」，两者都由用户自己选。
        // 因此这类条目不做子树折叠，也不能把同名的叶子项裁掉。
        let rootsNotPruning = Set(
            items.filter { $0.kind == .trashContents }
                .map { $0.path.standardizedFileURL.path }
        )
        let candidates = items.enumerated()
            .sorted {
                let leftDepth = $0.element.path.standardizedFileURL.pathComponents.count
                let rightDepth = $1.element.path.standardizedFileURL.pathComponents.count
                if leftDepth == rightDepth {
                    let leftPath = $0.element.path.standardizedFileURL.path
                    let rightPath = $1.element.path.standardizedFileURL.path
                    if leftPath == rightPath {
                        // 同一路径既有普通删除又有官方清理命令时，必须让 toolCommand 胜出：
                        // 普通 trash 会删掉整个目录，而官方命令能保留工具自身的状态结构。
                        let leftRank = $0.element.kind == .toolCommand ? 0 : 1
                        let rightRank = $1.element.kind == .toolCommand ? 0 : 1
                        if leftRank != rightRank { return leftRank < rightRank }
                        return $0.offset < $1.offset
                    }
                    return leftPath < rightPath
                }
                return leftDepth < rightDepth
            }
            .map(\.element)

        for item in candidates {
            let itemPath = item.path.standardizedFileURL.path
            let isCovered = kept.contains { existing in
                let existingPath = existing.path.standardizedFileURL.path
                guard !rootsNotPruning.contains(existingPath) else { return false }
                return itemPath == existingPath || itemPath.hasPrefix(existingPath + "/")
            }
            if !isCovered {
                kept.append(item)
            }
        }
        return kept
    }

    /// 只需要字节数、不关心统计完整性的调用方使用；扫描列表走
    /// `StorageMeasurementService` 以保留「至少占用」标记。
    static func size(of url: URL) -> Int64 {
        StorageMeasurementService.measure(url).allocatedBytes
    }

    /// 固定缓存规则模板；只读发现页也用它标注「已知缓存」。
    private static let fixedRuleTemplates: [CacheRule] = [
        CacheRule(category: "Xcode", name: "DerivedData", relativePath: "Library/Developer/Xcode/DerivedData", risk: .safe, note: "编译后可自动重新生成"),
        CacheRule(category: "Xcode", name: "ModuleCache", relativePath: "Library/Developer/Xcode/ModuleCache.noindex", risk: .safe, note: "Clang/Swift 模块缓存，Xcode 会自动重建"),
        CacheRule(category: "Xcode", name: "BuildCache", relativePath: "Library/Developer/Xcode/BuildCache.noindex", risk: .safe, note: "Xcode 构建缓存，可重新生成"),
        CacheRule(category: "Xcode", name: "SourcePackages", relativePath: "Library/Developer/Xcode/SourcePackages", risk: .review, note: "Swift Package checkout 和仓库，删除后会重新下载"),
        CacheRule(category: "Xcode", name: "SwiftUI Preview 缓存", relativePath: "Library/Developer/Xcode/UserData/Previews", risk: .safe, note: "Preview 会自动重建"),
        CacheRule(category: "Xcode", name: "Xcode 缓存", relativePath: "Library/Caches/com.apple.dt.Xcode", risk: .safe, note: "Xcode 会自动重建缓存"),
        CacheRule(category: "Xcode", name: "xcodebuild 缓存", relativePath: "Library/Caches/com.apple.dt.xcodebuild", risk: .safe, note: "构建缓存，可重新生成"),
        CacheRule(category: "Xcode", name: "源码控制 Git 缓存", relativePath: "Library/Caches/com.apple.dt.Xcode.sourcecontrol.Git", risk: .safe, note: "Xcode 会重新获取 Git 数据"),
        CacheRule(category: "Xcode", name: "文档缓存", relativePath: "Library/Developer/Xcode/DocumentationCache", risk: .safe, note: "需要时会重新下载"),
        CacheRule(category: "Xcode", name: "Instruments 缓存", relativePath: "Library/Caches/com.apple.dt.instruments", risk: .safe, note: "Instruments 会自动重建缓存"),
        CacheRule(category: "Xcode", name: "SourceKitService 缓存", relativePath: "Library/Caches/com.apple.dt.SourceKitService", risk: .safe, note: "SourceKit 会自动重建缓存"),
        CacheRule(category: "Xcode", name: "Xcode Previews 缓存", relativePath: "Library/Caches/com.apple.dt.XcodePreviews", risk: .safe, note: "Preview 会自动重建缓存"),
        CacheRule(category: "Xcode", name: "iOS Device Logs", relativePath: "Library/Developer/Xcode/iOS Device Logs", risk: .review, note: "真机诊断日志；确认不再需要排查问题后清理"),
        CacheRule(category: "Xcode", name: "Archives", relativePath: "Library/Developer/Xcode/Archives", risk: .review, note: "可能包含发布归档，请确认后清理"),
        CacheRule(category: "Xcode", name: "Products", relativePath: "Library/Developer/Xcode/Products", risk: .review, note: "项目产物，可按需重新构建"),
        CacheRule(category: "Xcode", name: "iOS DeviceSupport", relativePath: "Library/Developer/Xcode/iOS DeviceSupport", risk: .manual, note: "删除后真机调试可能需要重新下载"),
        CacheRule(category: "Xcode", name: "watchOS DeviceSupport", relativePath: "Library/Developer/Xcode/watchOS DeviceSupport", risk: .manual, note: "删除后 Apple Watch 真机调试可能需要重新下载符号"),
        CacheRule(category: "Xcode", name: "tvOS DeviceSupport", relativePath: "Library/Developer/Xcode/tvOS DeviceSupport", risk: .manual, note: "删除后 Apple TV 真机调试可能需要重新下载符号"),
        CacheRule(category: "Xcode", name: "macOS DeviceSupport", relativePath: "Library/Developer/Xcode/macOS DeviceSupport", risk: .manual, note: "删除后 macOS 设备调试可能需要重新下载符号"),
        CacheRule(category: "Xcode", name: "visionOS DeviceSupport", relativePath: "Library/Developer/Xcode/visionOS DeviceSupport", risk: .manual, note: "删除后 Vision Pro 真机调试可能需要重新下载符号"),
        CacheRule(category: "Xcode", name: "Playgrounds", relativePath: "Library/Developer/Xcode/UserData/Playgrounds", risk: .review, note: "Playground 生成数据和缓存；请确认没有需要保留的结果"),
        CacheRule(category: "CoreSimulator", name: "模拟器缓存", relativePath: "Library/Developer/CoreSimulator/Caches", risk: .safe, note: "模拟器缓存，不含设备数据"),
        CacheRule(category: "CoreSimulator", name: "模拟器日志", relativePath: "Library/Logs/CoreSimulator", risk: .safe, note: "模拟器会重新生成日志"),

        // AI coding agents: only disposable caches and logs are included.
        // Codex databases that hold goals, memories, queue, and thread history
        // are intentionally not listed here because they are agent state.
        CacheRule(category: "AI Agent", name: "Codex 日志数据库", relativePath: ".codex/logs_2.sqlite", risk: .review, note: "Codex 日志数据库可能包含会话调试信息；确认不再需要后清理，不会触碰目标、记忆、队列或线程历史"),
        CacheRule(category: "AI Agent", name: "OpenCode 缓存", relativePath: ".cache/opencode", risk: .safe, note: "OpenCode 可重建缓存；数据、配置、状态和仓库目录不会清理"),
        CacheRule(category: "AI Agent", name: "OpenCode 日志", relativePath: ".local/share/opencode/log", risk: .review, note: "OpenCode 日志；确认不再需要排查问题后清理，数据和仓库目录不会清理"),
        // OpenCode's CLI follows XDG paths; desktop wrappers on macOS may
        // use the conventional Library locations instead.
        CacheRule(category: "AI Agent", name: "OpenCode 缓存（macOS）", relativePath: "Library/Caches/opencode", risk: .safe, note: "OpenCode 可重建缓存；数据、配置、状态和仓库目录不会清理"),
        CacheRule(category: "AI Agent", name: "OpenCode 日志（macOS）", relativePath: "Library/Application Support/opencode/log", risk: .review, note: "OpenCode 日志；确认不再需要排查问题后清理，数据、配置、状态和仓库目录不会清理"),
        CacheRule(category: "AI Agent", name: "Claude Code 调试日志", relativePath: ".claude/debug-logs", risk: .review, note: "Claude Code 调试日志可能包含提示词和路径；确认不再需要后清理，不会触碰项目、历史、凭据或任务状态"),
        CacheRule(category: "AI Agent", name: "Goose 更新缓存", relativePath: "Library/Caches/goose-updater", risk: .review, note: "Goose 更新程序下载缓存；确认没有正在进行的更新后清理"),

        CacheRule(category: "包管理器", name: "npm 下载缓存", relativePath: ".npm/_cacache", risk: .safe, note: "npm 会重新下载依赖"),
        CacheRule(category: "包管理器", name: "npm 日志", relativePath: ".npm/_logs", risk: .safe, note: "仅为 npm 日志"),
        CacheRule(category: "包管理器", name: "npx 临时包", relativePath: ".npm/_npx", risk: .safe, note: "npx 会在下次执行时重新下载临时包"),
        CacheRule(category: "包管理器", name: "npm 预编译缓存", relativePath: ".npm/_prebuilds", risk: .safe, note: "原生模块会在需要时重新下载或编译"),
        CacheRule(category: "包管理器", name: "npm（旧路径）", relativePath: ".npm-cache-user/_cacache", risk: .safe, note: "npm 会重新下载依赖"),
        CacheRule(category: "包管理器", name: "tnpm 下载缓存", relativePath: ".tnpm/_cacache", risk: .safe, note: "tnpm 会重新下载依赖"),
        CacheRule(category: "包管理器", name: "tnpm 日志", relativePath: ".tnpm/_logs", risk: .safe, note: "仅为 tnpm 日志"),
        CacheRule(category: "包管理器", name: "Yarn", relativePath: "Library/Caches/Yarn", risk: .safe, note: "Yarn 会重新下载依赖"),
        CacheRule(category: "包管理器", name: "Yarn（旧缓存）", relativePath: ".cache/yarn", risk: .safe, note: "Yarn 会重新下载依赖"),
        CacheRule(category: "包管理器", name: "Yarn 离线缓存", relativePath: ".yarn/cache", risk: .review, note: "Yarn 会重新下载依赖；离线环境下请保留"),
        CacheRule(category: "包管理器", name: "pnpm 元数据缓存", relativePath: "Library/Caches/pnpm", risk: .safe, note: "pnpm 会重新获取 registry 元数据"),
        CacheRule(category: "包管理器", name: "Bun", relativePath: ".bun/install/cache", risk: .safe, note: "Bun 会重新下载依赖"),
        CacheRule(category: "包管理器", name: "Deno", relativePath: "Library/Caches/deno", risk: .safe, note: "Deno 会重新下载依赖和工具"),
        CacheRule(category: "包管理器", name: "Deno（旧缓存）", relativePath: ".cache/deno", risk: .safe, note: "Deno 会重新下载依赖和工具"),
        CacheRule(category: "包管理器", name: "Node.js 通用缓存", relativePath: ".cache/node", risk: .safe, note: "Node.js 工具会自动重建缓存"),
        CacheRule(category: "包管理器", name: "Corepack", relativePath: "Library/Caches/node/corepack", risk: .safe, note: "Corepack 会重新下载包管理器"),
        CacheRule(category: "包管理器", name: "Playwright 浏览器缓存", relativePath: "Library/Caches/ms-playwright", risk: .review, note: "Playwright 会重新下载浏览器，确认不再需要对应版本后清理"),
        CacheRule(category: "包管理器", name: "Puppeteer 浏览器缓存", relativePath: "Library/Caches/puppeteer", risk: .review, note: "Puppeteer 会重新下载浏览器，确认不再需要对应版本后清理"),
        CacheRule(category: "包管理器", name: "CocoaPods", relativePath: "Library/Caches/CocoaPods", risk: .safe, note: "Pods 会重新下载"),
        CacheRule(category: "包管理器", name: "Homebrew 下载缓存", relativePath: "Library/Caches/Homebrew", risk: .safe, note: "Homebrew 会重新下载包"),
        CacheRule(category: "包管理器", name: "SwiftPM 下载缓存", relativePath: "Library/Caches/org.swift.swiftpm", risk: .safe, note: "SwiftPM 会重新解析依赖"),
        CacheRule(category: "包管理器", name: "SwiftPM（XDG 缓存）", relativePath: ".cache/org.swift.swiftpm", risk: .safe, note: "SwiftPM 会重新解析依赖"),
        CacheRule(category: "包管理器", name: "SwiftPM（旧缓存）", relativePath: ".swiftpm/cache", risk: .safe, note: "SwiftPM 会重新解析依赖"),
        CacheRule(category: "包管理器", name: "SwiftPM 仓库缓存", relativePath: ".swiftpm/repositories", risk: .review, note: "可能包含依赖仓库 checkout；删除后会重新下载，请确认后清理"),
        CacheRule(category: "包管理器", name: "Composer", relativePath: "Library/Caches/composer", risk: .safe, note: "Composer 会重新下载依赖"),
        CacheRule(category: "包管理器", name: "NuGet 全局包缓存", relativePath: ".nuget/packages", risk: .review, note: "NuGet 全局依赖包目录。清理后项目可以重新 restore，但可能需要大量网络下载，离线环境建议保留"),
        CacheRule(category: "包管理器", name: "CocoaPods Specs 仓库", relativePath: ".cocoapods/repos", risk: .review, note: "Specs 索引会重新下载；离线环境下请保留"),

        CacheRule(category: "语言工具链", name: "Cargo registry cache", relativePath: ".cargo/registry/cache", risk: .safe, note: "Cargo 会重新下载 crate"),
        CacheRule(category: "语言工具链", name: "Cargo registry index", relativePath: ".cargo/registry/index", risk: .safe, note: "Cargo 会重新获取 registry 索引"),
        CacheRule(category: "语言工具链", name: "Cargo registry source", relativePath: ".cargo/registry/src", risk: .review, note: "Cargo 已解压的依赖源码；删除后会重新下载，可能影响离线构建和 IDE 索引"),
        CacheRule(category: "语言工具链", name: "Cargo git checkout", relativePath: ".cargo/git/checkouts", risk: .review, note: "Cargo Git 依赖 checkout；删除后会重新获取，请确认离线构建不受影响"),
        CacheRule(category: "语言工具链", name: "Cargo git database", relativePath: ".cargo/git/db", risk: .review, note: "Cargo Git 依赖数据库；删除后会重新获取，请确认离线构建不受影响"),
        CacheRule(category: "语言工具链", name: "rustup 下载缓存", relativePath: ".rustup/downloads", risk: .safe, note: "rustup 会重新下载工具链安装包"),
        CacheRule(category: "语言工具链", name: "rustup 临时缓存", relativePath: ".rustup/tmp", risk: .safe, note: "rustup 会重新创建临时文件"),
        CacheRule(category: "语言工具链", name: "pip", relativePath: "Library/Caches/pip", risk: .safe, note: "pip 会重新下载 wheel"),
        CacheRule(category: "语言工具链", name: "pip（旧缓存）", relativePath: ".cache/pip", risk: .safe, note: "pip 会重新下载 wheel"),
        CacheRule(category: "语言工具链", name: "uv", relativePath: "Library/Caches/uv", risk: .safe, note: "uv 会重新下载包"),
        CacheRule(category: "语言工具链", name: "uv（旧缓存）", relativePath: ".cache/uv", risk: .safe, note: "uv 会重新下载包"),
        CacheRule(category: "语言工具链", name: "Poetry", relativePath: "Library/Caches/pypoetry", risk: .safe, note: "Poetry 会重新下载包"),
        CacheRule(category: "AI/ML", name: "Hugging Face 模型缓存", relativePath: ".cache/huggingface", risk: .review, note: "模型会重新下载；请确认不再需要这些模型"),
        CacheRule(category: "AI/ML", name: "PyTorch 缓存", relativePath: ".cache/torch", risk: .review, note: "PyTorch 模型和数据会重新下载；请确认后清理"),
        CacheRule(category: "AI/ML", name: "Whisper 缓存", relativePath: ".cache/whisper", risk: .review, note: "Whisper 模型会重新下载；请确认后清理"),
        CacheRule(category: "AI/ML", name: "Keras 缓存", relativePath: ".keras", risk: .review, note: "Keras 模型会重新下载；请确认后清理"),
        CacheRule(category: "AI/ML", name: "TensorFlow Hub 缓存", relativePath: ".cache/tfhub_modules", risk: .review, note: "TensorFlow Hub 模型会重新下载；请确认后清理"),
        CacheRule(category: "AI/ML", name: "Ollama 模型", relativePath: ".ollama/models", risk: .review, note: "Ollama 模型会重新下载；请确认不再需要本地模型"),
        CacheRule(category: "AI/ML", name: "LM Studio 模型缓存", relativePath: ".cache/lm-studio", risk: .review, note: "LM Studio 模型会重新下载；请确认不再需要本地模型"),
        CacheRule(category: "AI/ML", name: "LM Studio 模型（应用目录）", relativePath: "Library/Application Support/LM Studio/models", risk: .review, note: "LM Studio 模型会重新下载；请确认不再需要本地模型"),
        CacheRule(category: "AI/ML", name: "Ollama 日志", relativePath: "Library/Logs/Ollama", risk: .safe, note: "Ollama 会重新生成日志"),
        CacheRule(category: "语言工具链", name: "Conda 包缓存", relativePath: ".conda/pkgs", risk: .safe, note: "Conda 会重新下载包"),
        CacheRule(category: "语言工具链", name: "Miniconda 包缓存", relativePath: "miniconda3/pkgs", risk: .safe, note: "Conda 会重新下载包"),
        CacheRule(category: "语言工具链", name: "Miniforge 包缓存", relativePath: "miniforge3/pkgs", risk: .safe, note: "Conda 会重新下载包"),
        CacheRule(category: "语言工具链", name: "Anaconda 包缓存", relativePath: "anaconda3/pkgs", risk: .safe, note: "Conda 会重新下载包"),
        CacheRule(category: "语言工具链", name: "Go build cache", relativePath: "Library/Caches/go-build", risk: .safe, note: "Go 会重新编译"),
        CacheRule(category: "语言工具链", name: "Go modules", relativePath: "go/pkg/mod", risk: .review, note: "删除后 Go 项目需要重新下载模块"),
        CacheRule(category: "语言工具链", name: "Flutter / Dart", relativePath: ".pub-cache", risk: .review, note: "Dart/Flutter 依赖缓存。清理后可以重新获取依赖，但会增加下一次构建的网络和时间成本"),

        CacheRule(category: "JVM", name: "Gradle caches", relativePath: ".gradle/caches", risk: .safe, note: "Gradle 会重新下载依赖"),
        CacheRule(category: "JVM", name: "Gradle wrapper distributions", relativePath: ".gradle/wrapper/dists", risk: .safe, note: "Gradle wrapper 会重新下载发行版"),
        CacheRule(category: "JVM", name: "Gradle daemon", relativePath: ".gradle/daemon", risk: .review, note: "建议停止 Gradle 构建后清理"),
        CacheRule(category: "JVM", name: "Maven repository", relativePath: ".m2/repository", risk: .review, note: "Maven 会重新下载依赖"),
        CacheRule(category: "JVM", name: "Maven wrapper distributions", relativePath: ".m2/wrapper/dists", risk: .safe, note: "Maven Wrapper 会重新下载发行版"),
        CacheRule(category: "JVM", name: "sbt boot 缓存", relativePath: ".sbt/boot", risk: .review, note: "Scala/sbt 工具组件会重新下载；请确认后清理"),
        CacheRule(category: "JVM", name: "sbt launcher 缓存", relativePath: ".sbt/launchers", risk: .review, note: "sbt 启动器会重新下载；请确认后清理"),
        CacheRule(category: "JVM", name: "Ivy 依赖缓存", relativePath: ".ivy2/cache", risk: .review, note: "sbt/Ivy 依赖会重新下载；离线环境下请保留"),
        CacheRule(category: "JVM", name: "Coursier 缓存", relativePath: ".coursier/cache", risk: .review, note: "Scala/JVM 依赖会重新下载；请确认后清理"),
        CacheRule(category: "JVM", name: "Ammonite 缓存", relativePath: ".ammonite/cache", risk: .review, note: "Ammonite 会重新下载依赖；请确认后清理"),
        CacheRule(category: "JVM", name: "Metals 缓存", relativePath: ".cache/metals", risk: .review, note: "Scala IDE 索引会重新生成；请确认后清理"),
        CacheRule(category: "JVM", name: "Android SDK 临时下载", relativePath: "Library/Android/sdk/.temp", risk: .safe, note: "Android SDK 会重新下载组件"),
        CacheRule(category: "JVM", name: "Android SDK 缓存", relativePath: "Library/Android/sdk/.cache", risk: .safe, note: "Android SDK 会自动重建缓存"),
        CacheRule(category: "JVM", name: "Android 用户缓存", relativePath: ".android/cache", risk: .safe, note: "Android 工具会自动重建缓存"),
        CacheRule(category: "JVM", name: "Android 旧构建缓存", relativePath: ".android/build-cache", risk: .safe, note: "Android 工具会重新构建"),
        CacheRule(category: "JVM", name: "Bazel 缓存", relativePath: "Library/Caches/bazel", risk: .safe, note: "Bazel 会重新构建"),
        CacheRule(category: "JVM", name: "Bazel（旧缓存）", relativePath: ".cache/bazel", risk: .safe, note: "Bazel 会重新构建"),

        CacheRule(category: "语言工具链", name: "mise 缓存", relativePath: ".cache/mise", risk: .safe, note: "mise 会重新下载工具"),
        CacheRule(category: "语言工具链", name: "asdf 下载缓存", relativePath: ".asdf/downloads", risk: .safe, note: "asdf 会重新下载工具"),
        CacheRule(category: "语言工具链", name: "asdf 临时缓存", relativePath: ".asdf/tmp", risk: .safe, note: "asdf 会重新创建临时文件"),
        CacheRule(category: "语言工具链", name: "nvm 下载缓存", relativePath: ".nvm/.cache", risk: .safe, note: "nvm 会重新下载 Node.js 安装包"),
        CacheRule(category: "语言工具链", name: "Volta 下载缓存", relativePath: ".volta/cache", risk: .safe, note: "Volta 会重新下载工具链"),
        CacheRule(category: "语言工具链", name: "ccache", relativePath: ".cache/ccache", risk: .safe, note: "编译器会重新编译"),
        CacheRule(category: "语言工具链", name: "sccache", relativePath: ".cache/sccache", risk: .safe, note: "编译器会重新编译"),
        CacheRule(category: "语言工具链", name: "ccache（macOS）", relativePath: "Library/Caches/ccache", risk: .safe, note: "编译器会重新编译"),
        CacheRule(category: "语言工具链", name: "sccache（macOS）", relativePath: "Library/Caches/sccache", risk: .safe, note: "编译器会重新编译"),
        CacheRule(category: "语言工具链", name: "ccache（经典路径）", relativePath: ".ccache", risk: .safe, note: "编译器会重新编译"),
        CacheRule(category: "语言工具链", name: "Zig 全局缓存", relativePath: ".cache/zig", risk: .safe, note: "Zig 会重新生成构建缓存"),
        CacheRule(category: "Ruby", name: "Bundler 下载缓存", relativePath: ".bundle/cache", risk: .safe, note: "Bundler 会重新下载 gem"),
        CacheRule(category: "Ruby", name: "RubyGems 索引缓存", relativePath: ".gem/specs", risk: .safe, note: "RubyGems 会重新获取索引"),
        CacheRule(category: "Ruby", name: "rbenv 下载缓存", relativePath: ".rbenv/cache", risk: .safe, note: "rbenv 会重新下载安装包"),
        CacheRule(category: "Ruby", name: "CPAN 构建缓存", relativePath: ".cpan/build", risk: .safe, note: "CPAN 会重新创建构建目录"),
        CacheRule(category: "语言工具链", name: "Hex 缓存", relativePath: ".hex/cache", risk: .safe, note: "Hex 会重新下载 Elixir/Erlang 包"),
        CacheRule(category: "Python 项目", name: "pipx 缓存", relativePath: ".cache/pipx", risk: .safe, note: "pipx 会重新下载包"),
        CacheRule(category: "Python 项目", name: "pre-commit 缓存", relativePath: ".cache/pre-commit", risk: .safe, note: "pre-commit 会重新下载环境"),
        CacheRule(category: "Python 项目", name: "Jupyter 缓存", relativePath: ".cache/jupyter", risk: .safe, note: "Jupyter 会重新生成缓存"),

        CacheRule(category: "IDE", name: "VS Code Cache", relativePath: "Library/Application Support/Code/Cache", risk: .safe, note: "编辑器会自动重建"),
        CacheRule(category: "IDE", name: "VS Code CachedData", relativePath: "Library/Application Support/Code/CachedData", risk: .safe, note: "编辑器会自动重建"),
        CacheRule(category: "IDE", name: "VS Code 扩展安装包缓存", relativePath: "Library/Application Support/Code/CachedExtensionVSIXs", risk: .safe, note: "扩展更新时会重新下载安装包"),
        CacheRule(category: "IDE", name: "VS Code Code Cache", relativePath: "Library/Application Support/Code/Code Cache", risk: .safe, note: "编辑器会自动重建"),
        CacheRule(category: "IDE", name: "VS Code GPUCache", relativePath: "Library/Application Support/Code/GPUCache", risk: .safe, note: "编辑器会自动重建"),
        CacheRule(category: "IDE", name: "VS Code Service Worker", relativePath: "Library/Application Support/Code/Service Worker", risk: .review, note: "编辑器会重建；清理前建议退出 VS Code"),
        CacheRule(category: "IDE", name: "VS Code 日志", relativePath: "Library/Application Support/Code/logs", risk: .safe, note: "仅为编辑器日志"),
        CacheRule(category: "IDE", name: "VS Code 系统缓存", relativePath: "Library/Caches/com.microsoft.VSCode", risk: .safe, note: "编辑器会自动重建"),
        CacheRule(category: "IDE", name: "VS Code workspaceStorage", relativePath: "Library/Application Support/Code/User/workspaceStorage", risk: .review, note: "工作区状态和扩展数据，确认后再清理"),
        CacheRule(category: "IDE", name: "Cursor Cache", relativePath: "Library/Application Support/Cursor/Cache", risk: .safe, note: "编辑器会自动重建"),
        CacheRule(category: "IDE", name: "Cursor CachedData", relativePath: "Library/Application Support/Cursor/CachedData", risk: .safe, note: "编辑器会自动重建"),
        CacheRule(category: "IDE", name: "Cursor Code Cache", relativePath: "Library/Application Support/Cursor/Code Cache", risk: .safe, note: "编辑器会自动重建"),
        CacheRule(category: "IDE", name: "Cursor GPUCache", relativePath: "Library/Application Support/Cursor/GPUCache", risk: .safe, note: "编辑器会自动重建"),
        CacheRule(category: "IDE", name: "Cursor 扩展安装包缓存", relativePath: "Library/Application Support/Cursor/CachedExtensionVSIXs", risk: .safe, note: "扩展更新时会重新下载安装包"),
        CacheRule(category: "IDE", name: "Cursor Service Worker", relativePath: "Library/Application Support/Cursor/Service Worker", risk: .review, note: "编辑器会重建；清理前建议退出 Cursor"),
        CacheRule(category: "IDE", name: "Cursor 日志", relativePath: "Library/Application Support/Cursor/logs", risk: .safe, note: "仅为编辑器日志"),
        CacheRule(category: "IDE", name: "Cursor workspaceStorage", relativePath: "Library/Application Support/Cursor/User/workspaceStorage", risk: .review, note: "工作区状态和扩展数据，确认后再清理"),
        CacheRule(category: "IDE", name: "Lingma Cache", relativePath: "Library/Application Support/Lingma/Cache", risk: .safe, note: "Lingma 会自动重建缓存"),
        CacheRule(category: "IDE", name: "Lingma CachedData", relativePath: "Library/Application Support/Lingma/CachedData", risk: .safe, note: "Lingma 会自动重建缓存"),
        CacheRule(category: "IDE", name: "Lingma 扩展安装包缓存", relativePath: "Library/Application Support/Lingma/CachedExtensionVSIXs", risk: .safe, note: "扩展更新时会重新下载安装包"),
        CacheRule(category: "IDE", name: "Lingma CachedProfilesData", relativePath: "Library/Application Support/Lingma/CachedProfilesData", risk: .safe, note: "Lingma 会自动重建缓存"),
        CacheRule(category: "IDE", name: "Lingma Code Cache", relativePath: "Library/Application Support/Lingma/Code Cache", risk: .safe, note: "Lingma 会自动重建缓存"),
        CacheRule(category: "IDE", name: "Lingma GPUCache", relativePath: "Library/Application Support/Lingma/GPUCache", risk: .safe, note: "Lingma 会自动重建缓存"),
        CacheRule(category: "IDE", name: "Lingma DawnWebGPUCache", relativePath: "Library/Application Support/Lingma/DawnWebGPUCache", risk: .safe, note: "Lingma 会自动重建缓存"),
        CacheRule(category: "IDE", name: "Lingma DawnGraphiteCache", relativePath: "Library/Application Support/Lingma/DawnGraphiteCache", risk: .safe, note: "Lingma 会自动重建缓存"),
        CacheRule(category: "IDE", name: "Trae CN Cache", relativePath: "Library/Application Support/Trae CN/Cache", risk: .safe, note: "Trae 会自动重建缓存"),
        CacheRule(category: "IDE", name: "Trae CN CachedData", relativePath: "Library/Application Support/Trae CN/CachedData", risk: .safe, note: "Trae 会自动重建缓存"),
        CacheRule(category: "IDE", name: "Trae CN 扩展安装包缓存", relativePath: "Library/Application Support/Trae CN/CachedExtensionVSIXs", risk: .safe, note: "扩展更新时会重新下载安装包"),
        CacheRule(category: "IDE", name: "Trae CN CachedProfilesData", relativePath: "Library/Application Support/Trae CN/CachedProfilesData", risk: .safe, note: "Trae 会自动重建缓存"),
        CacheRule(category: "IDE", name: "Trae CN Code Cache", relativePath: "Library/Application Support/Trae CN/Code Cache", risk: .safe, note: "Trae 会自动重建缓存"),
        CacheRule(category: "IDE", name: "Trae CN GPUCache", relativePath: "Library/Application Support/Trae CN/GPUCache", risk: .safe, note: "Trae 会自动重建缓存"),
        CacheRule(category: "IDE", name: "Trae CN DawnWebGPUCache", relativePath: "Library/Application Support/Trae CN/DawnWebGPUCache", risk: .safe, note: "Trae 会自动重建缓存"),
        CacheRule(category: "IDE", name: "Trae CN DawnGraphiteCache", relativePath: "Library/Application Support/Trae CN/DawnGraphiteCache", risk: .safe, note: "Trae 会自动重建缓存"),
        CacheRule(category: "IDE", name: "Windsurf Cache", relativePath: "Library/Application Support/Windsurf/Cache", risk: .safe, note: "Windsurf 会自动重建缓存"),
        CacheRule(category: "IDE", name: "Windsurf CachedData", relativePath: "Library/Application Support/Windsurf/CachedData", risk: .safe, note: "Windsurf 会自动重建缓存"),
        CacheRule(category: "IDE", name: "Windsurf 扩展安装包缓存", relativePath: "Library/Application Support/Windsurf/CachedExtensionVSIXs", risk: .safe, note: "扩展更新时会重新下载安装包"),
        CacheRule(category: "IDE", name: "Windsurf Code Cache", relativePath: "Library/Application Support/Windsurf/Code Cache", risk: .safe, note: "Windsurf 会自动重建缓存"),
        CacheRule(category: "IDE", name: "Windsurf GPUCache", relativePath: "Library/Application Support/Windsurf/GPUCache", risk: .safe, note: "Windsurf 会自动重建缓存"),
        CacheRule(category: "IDE", name: "Zed 缓存", relativePath: "Library/Caches/Zed", risk: .safe, note: "Zed 会自动重建缓存"),
        CacheRule(category: "IDE", name: "Zed Node 缓存", relativePath: "Library/Application Support/Zed/node/cache", risk: .safe, note: "Zed 会自动重建缓存"),
        CacheRule(category: "IDE", name: "OpenCode Desktop Cache", relativePath: "Library/Application Support/ai.opencode.desktop/Cache", risk: .safe, note: "OpenCode Desktop 会自动重建缓存"),
        CacheRule(category: "IDE", name: "OpenCode Desktop CachedData", relativePath: "Library/Application Support/ai.opencode.desktop/CachedData", risk: .safe, note: "OpenCode Desktop 会自动重建缓存"),
        CacheRule(category: "IDE", name: "OpenCode Desktop Code Cache", relativePath: "Library/Application Support/ai.opencode.desktop/Code Cache", risk: .safe, note: "OpenCode Desktop 会自动重建缓存"),
        CacheRule(category: "IDE", name: "OpenCode Desktop GPUCache", relativePath: "Library/Application Support/ai.opencode.desktop/GPUCache", risk: .safe, note: "OpenCode Desktop 会自动重建缓存"),
        CacheRule(category: "IDE", name: "OpenCode Desktop 扩展安装包缓存", relativePath: "Library/Application Support/ai.opencode.desktop/CachedExtensionVSIXs", risk: .safe, note: "扩展更新时会重新下载安装包"),
        CacheRule(category: "IDE", name: "Nova 缓存", relativePath: "Library/Application Support/Nova/Caches", risk: .safe, note: "Nova 会自动重建缓存"),
        CacheRule(category: "IDE", name: "JetBrains 缓存", relativePath: "Library/Caches/JetBrains", risk: .safe, note: "IDE 会自动重建"),
        CacheRule(category: "IDE", name: "JetBrains 日志", relativePath: "Library/Logs/JetBrains", risk: .safe, note: "IDE 会重新生成日志"),
        CacheRule(category: "IDE", name: "Android Studio 日志", relativePath: "Library/Logs/AndroidStudio", risk: .safe, note: "Android Studio 会重新生成日志"),
        CacheRule(category: "IDE", name: "Unity Hub 缓存", relativePath: "Library/Caches/com.unity3d.unityhub", risk: .safe, note: "Unity Hub 会自动重建缓存"),

        CacheRule(category: "浏览器缓存", name: "Microsoft Edge 缓存", relativePath: "Library/Caches/Microsoft Edge", risk: .safe, note: "退出 Edge 后清理；浏览器会自动重建缓存"),
        CacheRule(category: "浏览器缓存", name: "Microsoft Edge Dev 缓存", relativePath: "Library/Caches/Microsoft Edge Dev", risk: .safe, note: "退出 Edge Dev 后清理；浏览器会自动重建缓存"),
        CacheRule(category: "浏览器缓存", name: "Microsoft Edge Beta 缓存", relativePath: "Library/Caches/Microsoft Edge Beta", risk: .safe, note: "退出 Edge Beta 后清理；浏览器会自动重建缓存"),
        CacheRule(category: "浏览器缓存", name: "Firefox 缓存", relativePath: "Library/Caches/Firefox", risk: .safe, note: "退出 Firefox 后清理；浏览器会自动重建缓存"),
        CacheRule(category: "浏览器缓存", name: "Google 应用缓存", relativePath: "Library/Caches/Google", risk: .safe, note: "退出 Chrome、Android Studio 等 Google 应用后清理；缓存会自动重建"),
        CacheRule(category: "应用缓存", name: "Google 更新下载缓存", relativePath: "Library/Application Support/Google/GoogleUpdater/crx_cache", risk: .safe, note: "Google Updater 会在需要时重新下载安装包"),
        CacheRule(category: "应用缓存", name: "媒体分析缓存", relativePath: "Library/Containers/com.apple.mediaanalysisd/Data/Library/Caches", risk: .safe, note: "macOS 媒体分析服务会重新生成缓存"),
        CacheRule(category: "应用缓存", name: "剪映缓存", relativePath: "Movies/JianyingPro/User Data/Cache", risk: .review, note: "退出剪映后清理；请先确认没有仍需使用的草稿缓存"),
        CacheRule(category: "前端工具链", name: "TypeScript 缓存", relativePath: ".cache/typescript", risk: .safe, note: "TypeScript 工具会重新生成缓存"),
        CacheRule(category: "前端工具链", name: "Electron 缓存", relativePath: ".cache/electron", risk: .safe, note: "Electron 会重新下载或生成缓存"),
        CacheRule(category: "前端工具链", name: "node-gyp 缓存", relativePath: ".cache/node-gyp", risk: .safe, note: "node-gyp 会重新下载头文件并编译"),
        CacheRule(category: "前端工具链", name: "node-gyp（经典路径）", relativePath: ".node-gyp", risk: .safe, note: "node-gyp 会重新下载头文件并编译"),
        CacheRule(category: "前端工具链", name: "Turborepo 全局缓存", relativePath: ".turbo/cache", risk: .safe, note: "Turborepo 会重新生成缓存"),
        CacheRule(category: "前端工具链", name: "Webpack 缓存", relativePath: ".cache/webpack", risk: .safe, note: "Webpack 会重新生成缓存"),
        CacheRule(category: "前端工具链", name: "ESLint 缓存", relativePath: ".cache/eslint", risk: .safe, note: "ESLint 会重新生成缓存"),
        CacheRule(category: "前端工具链", name: "Prettier 缓存", relativePath: ".cache/prettier", risk: .safe, note: "Prettier 会重新生成缓存"),
        CacheRule(category: "测试工具", name: "Cypress 浏览器缓存", relativePath: "Library/Caches/Cypress", risk: .review, note: "Cypress 会重新下载浏览器组件"),
        CacheRule(category: "测试工具", name: "Selenium 缓存", relativePath: ".cache/selenium", risk: .review, note: "Selenium Manager 会重新下载驱动和浏览器组件"),
        CacheRule(category: "测试工具", name: "SonarQube 缓存", relativePath: ".sonar/cache", risk: .safe, note: "Sonar 扫描器会重新下载分析器和插件"),

        CacheRule(category: "云与基础设施", name: "Terraform Provider 缓存", relativePath: ".terraform.d/plugin-cache", risk: .safe, note: "Terraform 会重新下载 provider"),
        CacheRule(category: "云与基础设施", name: "Helm 缓存", relativePath: "Library/Caches/helm", risk: .safe, note: "Helm 会重新获取仓库数据"),
        CacheRule(category: "云与基础设施", name: "Kubernetes 缓存", relativePath: ".kube/cache", risk: .safe, note: "kubectl 会重新获取服务端数据"),
        CacheRule(category: "云与基础设施", name: "AWS CLI 缓存", relativePath: ".aws/cli/cache", risk: .safe, note: "AWS CLI 会重新获取临时缓存"),
        CacheRule(category: "云与基础设施", name: "Google Cloud 日志", relativePath: ".config/gcloud/logs", risk: .safe, note: "仅为 gcloud 日志"),
        CacheRule(category: "云与基础设施", name: "Azure CLI 日志", relativePath: ".azure/logs", risk: .safe, note: "仅为 Azure CLI 日志"),
        CacheRule(category: "Docker", name: "Docker BuildX 缓存", relativePath: ".docker/buildx/cache", risk: .safe, note: "BuildX 会重新生成构建缓存"),
        CacheRule(category: "包管理器", name: "Homebrew 日志", relativePath: "Library/Logs/Homebrew", risk: .safe, note: "仅为 Homebrew 构建和安装日志"),

        CacheRule(category: "数据库工具", name: "Sequel Ace 缓存", relativePath: "Library/Caches/com.sequel-ace.sequel-ace", risk: .safe, note: "仅删除 Sequel Ace 的 macOS Cache 数据"),
        CacheRule(category: "数据库工具", name: "Sequel Pro 缓存", relativePath: "Library/Caches/com.eggerapps.Sequel-Pro", risk: .safe, note: "仅删除 Sequel Pro 的 macOS Cache 数据"),
        CacheRule(category: "数据库工具", name: "Redis Desktop Manager 缓存", relativePath: "Library/Caches/redis-desktop-manager", risk: .safe, note: "仅删除 Redis Desktop Manager 的 macOS Cache 数据"),
        CacheRule(category: "数据库工具", name: "RedisInsight 缓存", relativePath: "Library/Caches/com.redis.RedisInsight", risk: .safe, note: "仅删除 RedisInsight 的 macOS Cache 数据"),
        CacheRule(category: "数据库工具", name: "MongoDB Compass 缓存", relativePath: "Library/Caches/com.mongodb.compass", risk: .safe, note: "仅删除 MongoDB Compass 的 macOS Cache 数据"),
        CacheRule(category: "API / 调试工具", name: "Postman 缓存", relativePath: "Library/Caches/com.postmanlabs.mac", risk: .safe, note: "退出 Postman 后仅清理 macOS Cache 数据，不触碰工作区、请求历史或凭据"),
        CacheRule(category: "API / 调试工具", name: "Insomnia 缓存", relativePath: "Library/Caches/com.konghq.insomnia", risk: .safe, note: "退出 Insomnia 后仅清理 macOS Cache 数据，不触碰工作区或凭据"),
        CacheRule(category: "API / 调试工具", name: "TablePlus 缓存", relativePath: "Library/Caches/com.tinyapp.TablePlus", risk: .safe, note: "仅删除 TablePlus 的 macOS Cache 数据"),
        CacheRule(category: "API / 调试工具", name: "Paw 缓存", relativePath: "Library/Caches/com.getpaw.Paw", risk: .safe, note: "仅删除 Paw 的 macOS Cache 数据"),
        CacheRule(category: "API / 调试工具", name: "Charles 缓存", relativePath: "Library/Caches/com.charlesproxy.charles", risk: .safe, note: "仅删除 Charles 的 macOS Cache 数据，不触碰配置、证书或请求历史"),
        CacheRule(category: "开发工具", name: "GitHub Desktop 缓存", relativePath: "Library/Caches/com.github.GitHubDesktop", risk: .safe, note: "仅删除 GitHub Desktop 的 macOS Cache 数据，不触碰仓库或凭据"),
        CacheRule(category: "开发工具", name: "SentryCrash 诊断数据", relativePath: "Library/Caches/SentryCrash", risk: .review, note: "崩溃诊断数据；确认不再需要排查相关问题后清理"),
        CacheRule(category: "CI/CD", name: "GitLab Runner 缓存", relativePath: ".cache/gitlab-runner", risk: .safe, note: "GitLab Runner 会重新生成缓存"),
        CacheRule(category: "CI/CD", name: "GitHub Actions 缓存", relativePath: ".github/cache", risk: .safe, note: "GitHub 工具会重新生成缓存"),
        CacheRule(category: "CI/CD", name: "CircleCI 缓存", relativePath: ".circleci/cache", risk: .safe, note: "CircleCI 工具会重新生成缓存"),
        CacheRule(category: "云与基础设施", name: "Grafana 缓存", relativePath: ".grafana/cache", risk: .safe, note: "Grafana 会重新生成缓存"),

        // MARK: 参考 PureMac / dusty 补充的覆盖
        // 这些路径在我们的规则表里此前完全缺位；只新增、不改动上面任何既有条目。
        // 依据：dusty 的 CleanupTargetRegistry（developer / deep 档）与 PureMac 的
        // ScanEngine（系统垃圾、邮件附件、AI 应用），均为本机可验证的缓存目录。

        // 浏览器：Safari 的 Cache 是 WebKit 自身的磁盘缓存，退出 Safari 后可重建。
        // Brave/Arc 是 Chromium 系，缓存目录名固定，删掉只影响下次首屏加载。
        CacheRule(category: "浏览器缓存", name: "Safari 缓存", relativePath: "Library/Caches/com.apple.Safari", risk: .safe, note: "退出 Safari 后清理；WebKit 会重建缓存，不影响书签、扩展或历史记录"),
        CacheRule(category: "浏览器缓存", name: "Brave 缓存", relativePath: "Library/Caches/BraveSoftware/Brave-Browser", risk: .safe, note: "退出 Brave 后清理；浏览器会自动重建缓存"),
        CacheRule(category: "浏览器缓存", name: "Arc 缓存", relativePath: "Library/Caches/Arc", risk: .safe, note: "退出 Arc 后清理；浏览器会自动重建缓存"),

        // 通信类：只碰可重建的缓存/更新安装包，绝不碰聊天数据库与会话。
        CacheRule(category: "应用缓存", name: "Slack 缓存", relativePath: "Library/Application Support/Slack/Cache", risk: .safe, note: "退出 Slack 后清理；只会重新下载消息与文件缓存，不删除登录状态"),
        CacheRule(category: "应用缓存", name: "Slack Code Cache", relativePath: "Library/Application Support/Slack/Code Cache", risk: .safe, note: "退出 Slack 后清理；Electron 会重建脚本缓存"),
        CacheRule(category: "应用缓存", name: "Slack GPUCache", relativePath: "Library/Application Support/Slack/GPUCache", risk: .safe, note: "退出 Slack 后清理；GPU 缓存会自动重建"),
        CacheRule(category: "应用缓存", name: "Discord 缓存", relativePath: "Library/Application Support/discord/Cache", risk: .safe, note: "退出 Discord 后清理；只会重新下载媒体缓存，不删除登录状态"),
        CacheRule(category: "应用缓存", name: "Discord Code Cache", relativePath: "Library/Application Support/discord/Code Cache", risk: .safe, note: "退出 Discord 后清理；Electron 会重建脚本缓存"),
        CacheRule(category: "应用缓存", name: "Signal 缓存", relativePath: "Library/Application Support/Signal/Cache", risk: .safe, note: "退出 Signal 后清理；只重建缓存，不触碰消息数据库"),
        CacheRule(category: "应用缓存", name: "Telegram 媒体缓存", relativePath: "Library/Application Support/Telegram Desktop/tdata/user_data/cache", risk: .safe, note: "退出 Telegram 后清理；媒体会按需重新从云端下载，不触碰聊天记录"),
        CacheRule(category: "应用缓存", name: "Teams 缓存", relativePath: "Library/Containers/com.microsoft.teams2/Data/Library/Caches", risk: .safe, note: "退出 Teams 后清理容器内缓存；不触碰登录会话与频道数据"),
        CacheRule(category: "应用缓存", name: "Zoom 更新安装包", relativePath: "Library/Application Support/zoom.us/AutoUpdater", risk: .safe, note: "仅为已下载的更新安装包；Zoom 会按需重新下载"),
        CacheRule(category: "应用缓存", name: "Spotify 缓存", relativePath: "Library/Application Support/Spotify/PersistentCache", risk: .review, note: "退出 Spotify 后清理；离线曲目需要重新下载，请确认没有仍需离线收听的音乐"),
        CacheRule(category: "应用缓存", name: "Obsidian 缓存", relativePath: "Library/Application Support/obsidian/Cache", risk: .safe, note: "退出 Obsidian 后清理；只重建渲染缓存，不触碰笔记库"),

        // 构建工具：Unity 的导入缓存可重建；Go 的模块下载缓存可重新拉取（我们此前只扫 go-build）。
        CacheRule(category: "测试产物", name: "Unity 导入缓存", relativePath: "Library/Unity/cache", risk: .safe, note: "Unity 会重新导入资源；首次打开项目会稍慢"),

        // 邮件附件：两个参考项目都扫这两处；附件已随邮件保存在服务器，可重新下载。
        CacheRule(category: "应用缓存", name: "邮件附件（旧路径）", relativePath: "Library/Mail Downloads", risk: .review, note: "已下载的邮件附件；确认不再需要离线附件后清理"),
        CacheRule(category: "应用缓存", name: "邮件附件", relativePath: "Library/Containers/com.apple.mail/Data/Library/Mail Downloads", risk: .review, note: "已下载的邮件附件；确认不再需要离线附件后清理"),

    ]

    static func knownCacheLocations(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [KnownCacheLocation] {
        fixedRuleTemplates.map {
            KnownCacheLocation(
                url: home.appendingPathComponent($0.relativePath),
                category: $0.category,
                name: $0.name,
                risk: $0.risk,
                note: $0.note
            )
        }
    }

    /// 需要「清空内容、保留目录」的根目录。
    ///
    /// 这些是系统预期的目录：整目录丢进废纸篓会破坏结构（`~/Library/Caches` 缺失
    /// 会让应用创建失败，`~/Downloads` 缺失会打乱 Finder 快捷访问）。因此它们不是
    /// 普通缓存条目，而是 `kind = .trashContents`：删的是里面的子项，目录本身保留。
    /// 一律默认不勾选，必须用户逐项确认——里面可能混着他还没处理的东西。
    private struct ContentsRule {
        let category: String
        let name: String
        let relativePath: String
        let note: String
    }

    private static let contentsRuleTemplates: [ContentsRule] = [
        ContentsRule(
            category: "应用缓存",
            name: "用户缓存目录（清空内容）",
            relativePath: "Library/Caches",
            note: "清空 ~/Library/Caches 里的全部子项，目录本身保留；应用会在需要时重建缓存。默认不勾选，请先确认没有正在运行的应用依赖其中的数据"
        ),
        ContentsRule(
            category: "项目日志",
            name: "用户日志目录（清空内容）",
            relativePath: "Library/Logs",
            note: "清空 ~/Library/Logs 里的全部子项，目录本身保留；仅为日志与崩溃记录，删除后无法再排查历史问题"
        ),
        ContentsRule(
            category: "应用缓存",
            name: "废纸篓（清空）",
            relativePath: ".Trash",
            note: "清空废纸篓里的全部项目；文件将从废纸篓永久移除，不能再次恢复"
        ),
        ContentsRule(
            category: "应用缓存",
            name: "下载目录（清空内容）",
            relativePath: "Downloads",
            note: "清空 ~/Downloads 里的全部文件与子目录，目录本身保留；请先确认没有未处理的下载，安装包与文档会被一并移入废纸篓"
        )
    ]

    private static func fixedItems(
        home: URL,
        collector: inout ScanCollector,
        progress: @escaping (ScanProgress) -> Void
    ) -> [CacheItem] {
        let rules = fixedRuleTemplates

        var items: [CacheItem] = []
        for rule in rules {
            let path = home.appendingPathComponent(rule.relativePath)
            if let item = makeItem(
                category: rule.category,
                name: rule.name,
                path: path,
                risk: rule.risk,
                note: rule.note,
                collector: &collector,
                progress: progress
            ) {
                items.append(item)
            }
        }

        for rule in contentsRuleTemplates {
            let path = home.appendingPathComponent(rule.relativePath)
            if let item = makeItem(
                category: rule.category,
                name: rule.name,
                path: path,
                risk: .review,
                note: rule.note,
                collector: &collector,
                progress: progress,
                isSelected: false,
                kind: .trashContents,
                statusTitle: "清空内容"
            ) {
                items.append(item)
            }
        }
        return items
    }

    private static func systemItems(
        collector: inout ScanCollector,
        progress: @escaping (ScanProgress) -> Void
    ) -> [CacheItem] {
        let rules: [(String, String, URL, String)] = [
            (
                "CoreSimulator",
                "系统级模拟器缓存（只读）",
                URL(fileURLWithPath: "/Library/Developer/CoreSimulator/Caches"),
                "系统级缓存可能需要管理员权限；请先退出 Xcode 和所有模拟器，再手动处理"
            ),
            (
                "Xcode",
                "系统级文档缓存（只读）",
                URL(fileURLWithPath: "/Library/Developer/Xcode/DocumentationCache"),
                "系统级文档索引可能需要管理员权限；请先退出 Xcode，再手动处理"
            )
        ]

        return rules.compactMap { category, name, path, note in
            makeItem(
                category: category,
                name: name,
                path: path,
                risk: .manual,
                note: note,
                collector: &collector,
                progress: progress,
                isSelected: false
            )
        }
    }

    private static func dynamicItems(
        home: URL,
        environment: [String: String],
        collector: inout ScanCollector,
        progress: @escaping (ScanProgress) -> Void
    ) -> [CacheItem] {
        var items: [CacheItem] = []

        func add(_ category: String, _ name: String, _ path: URL, _ risk: RiskLevel, _ note: String) {
            guard path.standardizedFileURL.path != "/", path.standardizedFileURL.path != home.path else { return }
            guard let item = makeItem(
                category: category,
                name: name,
                path: path,
                risk: risk,
                note: note,
                collector: &collector,
                progress: progress
            ) else { return }
            items.append(item)
        }

        if let value = environment["CODEX_HOME"], let codexHome = expandedPath(value, home: home) {
            add(
                "AI Agent",
                "Codex 日志数据库（自定义）",
                codexHome.appendingPathComponent("logs_2.sqlite"),
                .review,
                "来自 CODEX_HOME；日志数据库可能包含会话调试信息，确认不再需要后清理"
            )
        }
        if let value = environment["XDG_CACHE_HOME"], let xdgCacheHome = expandedPath(value, home: home) {
            add(
                "AI Agent",
                "OpenCode 缓存（XDG 自定义）",
                xdgCacheHome.appendingPathComponent("opencode"),
                .safe,
                "来自 XDG_CACHE_HOME；OpenCode 会重新生成缓存，数据、配置、状态和仓库目录不会清理"
            )
        }
        if let value = environment["XDG_DATA_HOME"], let xdgDataHome = expandedPath(value, home: home) {
            add(
                "AI Agent",
                "OpenCode 日志（XDG 自定义）",
                xdgDataHome.appendingPathComponent("opencode/log"),
                .review,
                "来自 XDG_DATA_HOME；OpenCode 日志可能包含会话信息，数据、配置、状态和仓库目录不会清理"
            )
        }
        if let value = environment["CLAUDE_CONFIG_DIR"], let claudeConfig = expandedPath(value, home: home) {
            add(
                "AI Agent",
                "Claude Code 调试日志（自定义）",
                claudeConfig.appendingPathComponent("debug-logs"),
                .review,
                "来自 CLAUDE_CONFIG_DIR；调试日志可能包含提示词和路径，确认不再需要后清理"
            )
        }

        if let value = environment["NPM_CONFIG_CACHE"], let path = expandedPath(value, home: home) {
            add("包管理器", "npm 自定义缓存", path, .safe, "来自 NPM_CONFIG_CACHE，npm 会重新下载依赖")
        }
        if let value = environment["YARN_CACHE_FOLDER"], let path = expandedPath(value, home: home) {
            add("包管理器", "Yarn 自定义缓存", path, .safe, "来自 YARN_CACHE_FOLDER，Yarn 会重新下载依赖")
        }
        if let value = environment["PNPM_STORE_PATH"], let path = expandedPath(value, home: home) {
            add("包管理器", "pnpm 自定义 store", path, .review, "来自 PNPM_STORE_PATH；优先通过 pnpm store prune 清理，直接删除会影响离线开发")
        }
        if let value = environment["DENO_DIR"], let path = expandedPath(value, home: home) {
            add("包管理器", "Deno 自定义目录", path, .review, "来自 DENO_DIR；可能混合远程依赖、运行时载荷和缓存，确认后再清理")
        }
        if let value = environment["PLAYWRIGHT_BROWSERS_PATH"], value != "0", let path = expandedPath(value, home: home) {
            add("包管理器", "Playwright 自定义浏览器缓存", path, .review, "来自 PLAYWRIGHT_BROWSERS_PATH，浏览器会重新下载")
        }
        if let value = environment["PUPPETEER_CACHE_DIR"], let path = expandedPath(value, home: home) {
            add("包管理器", "Puppeteer 自定义浏览器缓存", path, .review, "来自 PUPPETEER_CACHE_DIR，浏览器会重新下载")
        }
        if let value = environment["CARGO_HOME"], let cargoHome = expandedPath(value, home: home) {
            addCargoItems(cargoHome: cargoHome, add: add)
        }
        if let value = environment["RUSTUP_HOME"], let rustupHome = expandedPath(value, home: home) {
            add("语言工具链", "rustup 自定义下载缓存", rustupHome.appendingPathComponent("downloads"), .safe, "来自 RUSTUP_HOME，rustup 会重新下载工具链")
            add("语言工具链", "rustup 自定义临时缓存", rustupHome.appendingPathComponent("tmp"), .safe, "来自 RUSTUP_HOME，rustup 会重新创建临时文件")
        }
        if let value = environment["CONDA_PKGS_DIRS"] {
            for pathValue in value.split(separator: ":") {
                if let path = expandedPath(String(pathValue), home: home) {
                    add("语言工具链", "Conda 自定义包缓存", path, .safe, "来自 CONDA_PKGS_DIRS，Conda 会重新下载包")
                }
            }
        }
        if let value = environment["PIP_CACHE_DIR"], let path = expandedPath(value, home: home) {
            add("语言工具链", "pip 自定义缓存", path, .safe, "来自 PIP_CACHE_DIR，pip 会重新下载 wheel")
        }
        if let value = environment["UV_CACHE_DIR"], let path = expandedPath(value, home: home) {
            add("语言工具链", "uv 自定义缓存", path, .safe, "来自 UV_CACHE_DIR，uv 会重新下载包")
        }
        if let value = environment["POETRY_CACHE_DIR"], let path = expandedPath(value, home: home) {
            add("语言工具链", "Poetry 自定义缓存", path, .safe, "来自 POETRY_CACHE_DIR，Poetry 会重新下载包")
        }
        if let value = environment["GOCACHE"], let path = expandedPath(value, home: home) {
            add("语言工具链", "Go 自定义 build cache", path, .safe, "来自 GOCACHE，Go 会重新编译")
        }
        if let value = environment["GOMODCACHE"], let path = expandedPath(value, home: home) {
            add("语言工具链", "Go 自定义 modules", path, .review, "来自 GOMODCACHE，删除后需要重新下载模块")
        }
        if let value = environment["GRADLE_USER_HOME"], let gradleHome = expandedPath(value, home: home) {
            add("JVM", "Gradle 自定义 caches", gradleHome.appendingPathComponent("caches"), .safe, "来自 GRADLE_USER_HOME，Gradle 会重新下载依赖")
            add("JVM", "Gradle 自定义 wrapper", gradleHome.appendingPathComponent("wrapper/dists"), .safe, "来自 GRADLE_USER_HOME，Gradle wrapper 会重新下载")
        }
        if let value = environment["MAVEN_USER_HOME"], let mavenHome = expandedPath(value, home: home) {
            add("JVM", "Maven 自定义 repository", mavenHome.appendingPathComponent("repository"), .review, "来自 MAVEN_USER_HOME，Maven 会重新下载依赖")
            add("JVM", "Maven 自定义 wrapper", mavenHome.appendingPathComponent("wrapper/dists"), .safe, "来自 MAVEN_USER_HOME，Maven Wrapper 会重新下载")
        }
        if let value = environment["NUGET_PACKAGES"], let path = expandedPath(value, home: home) {
            add("包管理器", "NuGet 自定义包目录", path, .review, "来自 NUGET_PACKAGES；清理后可能需要大量网络下载，离线环境建议保留")
        }
        if let value = environment["BUN_INSTALL_CACHE_DIR"], let path = expandedPath(value, home: home) {
            add("包管理器", "Bun 自定义缓存", path, .safe, "来自 BUN_INSTALL_CACHE_DIR，Bun 会重新下载依赖")
        }
        if let value = environment["NVM_DIR"], let nvmHome = expandedPath(value, home: home) {
            add("语言工具链", "nvm 自定义下载缓存", nvmHome.appendingPathComponent(".cache"), .safe, "来自 NVM_DIR，nvm 会重新下载 Node.js 安装包")
        }
        if let value = environment["VOLTA_HOME"], let voltaHome = expandedPath(value, home: home) {
            add("语言工具链", "Volta 自定义下载缓存", voltaHome.appendingPathComponent("cache"), .safe, "来自 VOLTA_HOME，Volta 会重新下载工具链")
        }
        if let value = environment["SONAR_USER_HOME"], let sonarHome = expandedPath(value, home: home) {
            add("测试工具", "SonarQube 自定义缓存", sonarHome.appendingPathComponent("cache"), .safe, "来自 SONAR_USER_HOME，Sonar 扫描器会重新下载分析器和插件")
        }
        if let value = environment["COURSIER_CACHE"], let path = expandedPath(value, home: home) {
            add("JVM", "Coursier 自定义缓存", path, .review, "来自 COURSIER_CACHE，Scala/JVM 依赖会重新下载")
        }
        if let value = environment["CP_CACHE_DIR"], let path = expandedPath(value, home: home) {
            add("包管理器", "CocoaPods 自定义缓存", path, .review, "来自 CP_CACHE_DIR，CocoaPods 会重新下载缓存；请确认后清理")
        }
        if let value = environment["CP_REPOS_DIR"], let path = expandedPath(value, home: home) {
            add("包管理器", "CocoaPods 自定义 Specs 仓库", path, .review, "来自 CP_REPOS_DIR，Specs 索引会重新下载；请确认后清理")
        } else if let value = environment["CP_HOME_DIR"], let cpHome = expandedPath(value, home: home) {
            add("包管理器", "CocoaPods 自定义 Specs 仓库", cpHome.appendingPathComponent("repos"), .review, "来自 CP_HOME_DIR，Specs 索引会重新下载；请确认后清理")
        }

        if let npmrc = try? String(contentsOf: home.appendingPathComponent(".npmrc"), encoding: .utf8),
           let configuredPath = configuredValue(named: "cache", in: npmrc),
           let path = expandedPath(configuredPath, home: home) {
            add("包管理器", "npm 配置缓存", path, .safe, "来自 ~/.npmrc，npm 会重新下载依赖")
        }

        let rubyGemsRoot = home.appendingPathComponent(".gem/ruby")
        for version in childDirectories(at: rubyGemsRoot, collector: &collector, progress: progress) {
            add("Ruby", "RubyGems 包缓存 · \(version.lastPathComponent)", version.appendingPathComponent("cache"), .safe, "RubyGems 会重新下载 gem 包")
        }

        let googleCache = home.appendingPathComponent("Library/Caches/Google")
        for child in childDirectories(at: googleCache, collector: &collector, progress: progress)
            where child.lastPathComponent.hasPrefix("AndroidStudio") {
            add("Android Studio", child.lastPathComponent, child, .safe, "Android Studio 会自动重建缓存")
        }

        let googleSupport = home.appendingPathComponent("Library/Application Support/Google")
        for child in childDirectories(at: googleSupport, collector: &collector, progress: progress)
            where child.lastPathComponent.hasPrefix("AndroidStudio") {
            for suffix in ["caches", "cache"] {
                add(
                    "Android Studio",
                    "\(child.lastPathComponent) \(suffix)",
                    child.appendingPathComponent(suffix),
                    .safe,
                    "Android Studio 会自动重建缓存"
                )
            }
        }

        items += electronAppSupportCaches(
            home: home,
            collector: &collector,
            progress: progress
        )

        let documents = home.appendingPathComponent("Documents")
        for browserRoot in childDirectories(at: documents, collector: &collector, progress: progress)
            where browserRoot.lastPathComponent.lowercased().hasPrefix("chrome") {
            for profile in childDirectories(at: browserRoot, collector: &collector, progress: progress)
                where profile.lastPathComponent == "Default" || profile.lastPathComponent.hasPrefix("Profile ") {
                for cacheName in ["Cache", "Code Cache"] {
                    add(
                        "浏览器缓存",
                        "自定义 Chromium \(profile.lastPathComponent) · \(cacheName)",
                        profile.appendingPathComponent(cacheName),
                        .safe,
                        "退出使用该资料目录的 Chromium 浏览器后清理；缓存会自动重建"
                    )
                }
            }
        }

        let appCache = home.appendingPathComponent("Library/Caches")
        let vendorPrefixes: [(String, String, String)] = [
            ("com.figma.", "Figma", "设计工具会自动重建缓存"),
            ("com.adobe.", "Adobe", "应用会自动重建缓存")
        ]
        for child in childDirectories(at: appCache, collector: &collector, progress: progress) {
            if let match = vendorPrefixes.first(where: { child.lastPathComponent.hasPrefix($0.0) }) {
                add("设计工具", "\(match.1) · \(child.lastPathComponent)", child, .safe, match.2)
            } else if child.lastPathComponent.hasPrefix("com.navicat.") {
                add("数据库工具", "Navicat · \(child.lastPathComponent)", child, .safe, "仅删除 Navicat 的 macOS Cache 数据，不触碰连接、密码或配置")
            } else if child.lastPathComponent.hasPrefix("com.dbeaver.") {
                add("数据库工具", "DBeaver · \(child.lastPathComponent)", child, .safe, "仅删除 DBeaver 的 macOS Cache 数据，不触碰 workspace、连接或密码")
            }
        }

        if environment["PATH"] != nil {
            items += ownerToolItems(
                home: home,
                environment: environment,
                collector: &collector,
                progress: progress
            )
        }

        if !items.contains(where: { $0.toolAction == .pnpmStore }) {
            for fallback in [
                home.appendingPathComponent("Library/pnpm/store"),
                home.appendingPathComponent(".local/share/pnpm/store")
            ] {
                add(
                    "包管理器",
                    "pnpm store（无 CLI fallback）",
                    fallback,
                    .review,
                    "未能使用 pnpm store prune；整个依赖 store 不会默认勾选，离线环境建议保留"
                )
            }
        }

        return items
    }

    /// `~/Library/Application Support/*` 下的 Electron / Chromium 系缓存目录。
    ///
    /// 这类应用（QQ/钉钉/飞书/网盘/各类桌面客户端）把缓存放在
    /// `Application Support/<App>/{Cache,Code Cache,GPUCache,DawnGraphiteCache,
    /// DawnWebGPUCache,ShaderCache}` 里，路径无统一命名规则，只能按目录名模式发现。
    /// 参考 PureMac 的「用户缓存动态发现」与 dusty 的 App Cache 目标清单。
    ///
    /// 只认这几种**纯缓存**目录名；`Local Storage`、`IndexedDB`、`Session Storage`、
    /// `databases`、`Service Worker`（可能持有离线数据/登录态）一律不碰。
    /// 另外跳过容器/系统托管目录，避免与沙盒、iCloud、钥匙串边界打架。
    private static let electronCacheDirectoryNames: Set<String> = [
        "Cache", "Code Cache", "GPUCache", "DawnGraphiteCache",
        "DawnWebGPUCache", "ShaderCache"
    ]

    /// 明确不扫描的宿主目录：系统/容器/托管型，缓存不是可自由删除的应用缓存，
    /// 或是 DevSweep 自身与 Agent 状态。
    private static let electronAppSupportExcludedHosts: Set<String> = [
        "com.apple.sharedfilelist", "CloudDocs", "MobileSync", "AddressBook",
        "CallHistoryDB", "Knowledge", "com.apple.TCC", "com.apple.mail",
        "Code", "Cursor", "Lingma", "Windsurf", "Trae CN", "Trae",
        "ai.opencode.desktop", "Zed", "Nova", "com.apple.dt.Xcode",
        "devsweep", "DevSweep", ".DS_Store"
    ]

    private static func electronAppSupportCaches(
        home: URL,
        collector: inout ScanCollector,
        progress: @escaping (ScanProgress) -> Void
    ) -> [CacheItem] {
        let support = home.appendingPathComponent("Library/Application Support")
        guard fileManager.fileExists(atPath: support.path) else { return [] }

        var items: [CacheItem] = []
        for host in childDirectories(at: support, collector: &collector, progress: progress) {
            let hostName = host.lastPathComponent
            guard !electronAppSupportExcludedHosts.contains(hostName) else { continue }
            guard !hostName.hasPrefix(".") else { continue }

            // 应用缓存目录直接在 <App>/ 下；少数 Electron 版本放在 <App>/session/ 下。
            // 两处的目录名相同，所以展示名要带上位置，否则列表里会出现两条同名条目。
            let candidateParents: [(url: URL, suffix: String)] = [
                (host, ""),
                (host.appendingPathComponent("session"), " · session")
            ]
            for parent in candidateParents {
                guard fileManager.fileExists(atPath: parent.url.path) else { continue }
                for cacheName in electronCacheDirectoryNames {
                    let cacheURL = parent.url.appendingPathComponent(cacheName)
                    guard let item = makeItem(
                        category: "应用缓存",
                        name: "\(hostName) · \(cacheName)\(parent.suffix)",
                        path: cacheURL,
                        risk: .safe,
                        note: "Electron/Chromium 系应用的渲染与脚本缓存；退出该应用后清理，应用会按需重建",
                        collector: &collector,
                        progress: progress
                    ) else { continue }
                    items.append(item)
                }
            }
        }
        return items
    }

    private static func ownerToolItems(
        home: URL,
        environment: [String: String],
        collector: inout ScanCollector,
        progress: @escaping (ScanProgress) -> Void
    ) -> [CacheItem] {
        var items: [CacheItem] = []

        func add(
            category: String,
            name: String,
            path: URL,
            action: ToolCleanupAction,
            note: String
        ) {
            guard let item = makeItem(
                category: category,
                name: name,
                path: path,
                risk: .review,
                note: note,
                collector: &collector,
                progress: progress,
                isSelected: false,
                kind: .toolCommand,
                toolAction: action
            ) else { return }
            items.append(item)
        }

        if GitHubCLISupport.executableURL(environment: environment) != nil,
           let cache = GitHubCLISupport.cacheURL(home: home, environment: environment) {
            add(
                category: "CI/CD",
                name: "GitHub CLI 缓存",
                path: cache,
                action: .githubCLI,
                note: "通过 gh config clear-cache 官方命令清理，不会进入废纸篓；清理前会跳过正在运行或状态不明的 gh"
            )
        }

        if let executable = PnpmSupport.executableURL(environment: environment),
           let store = PnpmSupport.storeURL(
               executable: executable,
               home: home,
               environment: environment
           ) {
            add(
                category: "包管理器",
                name: "pnpm store（官方 prune）",
                path: store,
                action: .pnpmStore,
                note: "通过 pnpm store prune 官方命令清理，不会进入废纸篓；清理前会跳过正在运行或状态不明的 pnpm"
            )
        }

        if let executable = UVSupport.executableURL(environment: environment),
           let cache = UVSupport.cacheURL(
               executable: executable,
               home: home,
               environment: environment
           ) {
            add(
                category: "语言工具链",
                name: "uv 缓存（官方 prune）",
                path: cache,
                action: .uvCache,
                note: "通过 uv cache prune 官方命令清理，不会进入废纸篓；清理前会跳过正在运行或状态不明的 uv"
            )
        }

        return items
    }

    private static func softwareUpdateResidues(
        home: URL,
        includeSystemLocations: Bool,
        collector: inout ScanCollector,
        progress: @escaping (ScanProgress) -> Void
    ) -> [CacheItem] {
        var roots: [(url: URL, maxDepth: Int, risk: RiskLevel)] = [
            (home.appendingPathComponent("Library/Caches"), 10, .review),
            (home.appendingPathComponent("Library/Application Support"), 8, .review),
            (home.appendingPathComponent("Library/HTTPStorages"), 8, .review)
        ]

        for container in childDirectories(
            at: home.appendingPathComponent("Library/Containers"),
            collector: &collector,
            progress: progress
        ) {
            let data = container.appendingPathComponent("Data")
            roots.append((data.appendingPathComponent("Library/Caches"), 8, .review))
            roots.append((data.appendingPathComponent("Library/Application Support"), 8, .review))
            roots.append((data.appendingPathComponent("Library/HTTPStorages"), 8, .review))
            roots.append((data.appendingPathComponent("tmp"), 6, .review))
        }

        for container in childDirectories(
            at: home.appendingPathComponent("Library/Group Containers"),
            collector: &collector,
            progress: progress
        ) {
            roots.append((container.appendingPathComponent("Library/Caches"), 8, .review))
            roots.append((container.appendingPathComponent("Library/Application Support"), 8, .review))
            roots.append((container.appendingPathComponent("Library/HTTPStorages"), 8, .review))
            roots.append((container.appendingPathComponent("tmp"), 6, .review))
        }

        if home.standardizedFileURL == fileManager.homeDirectoryForCurrentUser.standardizedFileURL {
            roots.append((fileManager.temporaryDirectory, 8, .review))
        }

        if includeSystemLocations {
            roots.append((URL(fileURLWithPath: "/Library/Caches"), 8, .manual))
            roots.append((URL(fileURLWithPath: "/Library/Application Support"), 6, .manual))
            roots.append((URL(fileURLWithPath: "/Library/Updates"), 6, .manual))
        }

        var items: [CacheItem] = []
        var scannedRoots: Set<String> = []
        for root in roots {
            let standardized = root.url.standardizedFileURL
            guard scannedRoots.insert(standardized.path).inserted else { continue }
            items += softwareUpdateResidues(
                in: standardized,
                maxDepth: root.maxDepth,
                risk: root.risk,
                collector: &collector,
                progress: progress
            )
        }
        return items
    }

    private static func softwareUpdateResidues(
        in root: URL,
        maxDepth: Int,
        risk: RiskLevel,
        collector: inout ScanCollector,
        progress: @escaping (ScanProgress) -> Void
    ) -> [CacheItem] {
        guard fileManager.fileExists(atPath: root.path),
              let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: []
              ) else { return [] }

        var items: [CacheItem] = []
        let skippedDirectoryNames: Set<String> = [
            "attachments", "databases", "documents", "indexeddb", "local storage",
            "media", "messages", "profiles", "session storage", "user", "webstorage"
        ]
        for case let url as URL in enumerator {
            let depth = url.pathComponents.count - root.pathComponents.count
            if depth > maxDepth {
                collector.skippedPaths += 1
                enumerator.skipDescendants()
                continue
            }

            collector.checked(url)
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isSymbolicLink != true else {
                enumerator.skipDescendants()
                continue
            }

            let lowercasedName = url.lastPathComponent.lowercased()
            if values.isDirectory == true,
               skippedDirectoryNames.contains(lowercasedName),
               !hasSoftwareUpdateContext(url) {
                collector.skippedPaths += 1
                enumerator.skipDescendants()
                continue
            }

            guard let residueName = softwareUpdateResidueName(
                for: url,
                isDirectory: values.isDirectory == true
            ) else {
                let currentDirectorySignalsUpdate = isSoftwareUpdateContextComponent(lowercasedName)
                if values.isDirectory == true,
                   depth >= 4,
                   !hasSoftwareUpdateContext(url),
                   !currentDirectorySignalsUpdate {
                    collector.skippedPaths += 1
                    enumerator.skipDescendants()
                }
                continue
            }

            if let item = makeItem(
                category: "应用缓存",
                name: residueName,
                path: url,
                risk: risk,
                note: risk == .manual
                    ? "系统级软件更新残留；仅展示占用，请通过对应更新程序或系统工具处理"
                    : "软件更新下载或暂存残留；确认相关应用未在更新后再清理",
                collector: &collector,
                progress: progress
            ) {
                items.append(item)
            }
            if values.isDirectory == true { enumerator.skipDescendants() }
        }
        return items
    }

    static func softwareUpdateResidueName(for url: URL, isDirectory: Bool) -> String? {
        let name = url.lastPathComponent
        let lowercasedName = name.lowercased()
        let hasContext = hasSoftwareUpdateContext(url)

        if isDirectory {
            if lowercasedName == "updated.app"
                || (lowercasedName.hasSuffix(".app") && hasContext) {
                return "暂存的软件更新"
            }
            if hasContext && (lowercasedName.hasSuffix(".download") || lowercasedName.hasSuffix(".partial")) {
                return "未完成的软件更新下载"
            }
            return nil
        }

        let archiveSuffixes = [
            ".zip", ".pkg", ".dmg", ".mar", ".patch", ".delta", ".download", ".partial",
            ".tar", ".tar.gz", ".tar.bz2", ".tar.xz"
        ]
        guard archiveSuffixes.contains(where: lowercasedName.hasSuffix) else { return nil }

        let isKnownGenericResidue = lowercasedName == "update.zip"
            || lowercasedName.hasSuffix(".mar")
            || (lowercasedName.hasPrefix("tencentdocs") && lowercasedName.hasSuffix(".zip"))
        guard isKnownGenericResidue || hasContext else { return nil }
        return "软件更新安装包"
    }

    private static func hasSoftwareUpdateContext(_ url: URL) -> Bool {
        url.deletingLastPathComponent().pathComponents.contains {
            isSoftwareUpdateContextComponent($0.lowercased())
        }
    }

    private static func isSoftwareUpdateContextComponent(_ component: String) -> Bool {
        let tokens = component
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        let exactSignals: Set<String> = [
            "update", "updates", "updater", "updaters", "upgrade", "upgrades",
            "sparkle", "squirrel", "staging", "pending"
        ]
        return tokens.contains { token in
            exactSignals.contains(token)
                || token.hasPrefix("autoupdate")
                || token.contains("softwareupdate")
                || token.hasPrefix("squirrel")
                || token.hasSuffix("updater")
        }
    }

    /// Claude Code Router 的请求日志不是「整目录丢进废纸篓」，而是按保留窗口原地裁剪：
    /// 数据库项显示可回收的空闲页 / WAL / 随过期行删除的正文，正文项显示已无日志引用的过期文件。
    private static func requestLogItems(
        home: URL,
        collector: inout ScanCollector,
        progress: @escaping (ScanProgress) -> Void
    ) -> [CacheItem] {
        let store = RequestLogStore.standard(home: home)
        guard fileManager.fileExists(atPath: store.databaseURL.path) else { return [] }
        collector.checked(store.dataDirectory)

        let inventory = RequestLogScanner().inventory(store: store)
        guard inventory.isReadable else {
            collector.skipped(
                store.databaseURL,
                reason: "无法读取请求日志数据库，已跳过 AI Agent 请求日志统计",
                kind: .unavailable
            )
            return []
        }

        progress(ScanProgress(
            phase: "统计请求日志可回收空间",
            currentPath: store.dataDirectory.devSweepDisplayPath,
            checkedPaths: collector.checkedPaths,
            matchedPaths: 0,
            skippedPaths: collector.skippedPaths,
            permissionFailures: collector.permissionFailures
        ))

        let retention = RequestLogPolicy.defaultRetentionHours
        var items: [CacheItem] = []

        if inventory.databaseReclaimableBytes >= minimumItemSize {
            let details = [
                "\(inventory.expiredRowCount) 行 \(retention) 小时前的日志",
                "空闲页 \(inventory.freePageBytes.devSweepFileSize)",
                "WAL \(inventory.writeAheadLogBytes.devSweepFileSize)",
                "随行删除的正文 \(inventory.expiredBodyBytes.devSweepFileSize)"
            ].joined(separator: " · ")
            items.append(CacheItem(
                category: "AI Agent",
                name: RequestLogTarget.database.displayName,
                path: store.databaseURL,
                size: inventory.databaseReclaimableBytes,
                details: details,
                risk: .review,
                kind: .requestLogTrim,
                identifier: RequestLogTarget.database.rawValue,
                note: "删除 \(retention) 小时前的请求日志行、其正文文件，并执行 VACUUM 回收 SQLite 空闲页；"
                    + "清理后这些记录不再出现在请求日志和用量分析里，也不能从废纸篓恢复，最近的日志会保留"
            ))
        }

        if inventory.bodiesReclaimableBytes >= minimumItemSize {
            let details = "\(inventory.orphanBodyNames.count) 个已无日志引用的 \(retention) 小时前文件 · "
                + store.bodyDirectoryURL.devSweepDisplayPath
            items.append(CacheItem(
                category: "AI Agent",
                name: RequestLogTarget.bodies.displayName,
                path: store.bodyDirectoryURL,
                size: inventory.bodiesReclaimableBytes,
                details: details,
                risk: .review,
                kind: .requestLogTrim,
                identifier: RequestLogTarget.bodies.rawValue,
                note: "只删除 \(retention) 小时前、且已没有任何日志行引用的请求/响应正文文件；"
                    + "最近的正文和仍被引用的正文都会保留，删除后不能从废纸篓恢复"
            ))
        }

        return items
    }

    private static func dockerItems(
        home: URL,
        collector: inout ScanCollector,
        progress: @escaping (ScanProgress) -> Void
    ) -> [CacheItem] {
        let dockerDataRoot = home.appendingPathComponent("Library/Containers/com.docker.docker")
        let rawDisk = dockerDataRoot.appendingPathComponent("Data/vms/0/data/Docker.raw")
        var items: [CacheItem] = []

        if let rawDiskItem = makeItem(
            category: "Docker",
            name: "Docker Desktop 虚拟磁盘（只读）",
            path: rawDisk,
            risk: .manual,
            note: "仅显示 Docker.raw 占用；不能直接删除虚拟磁盘，请使用 Docker 官方 CLI 或 Docker Desktop 的磁盘回收功能",
            collector: &collector,
            progress: progress,
            details: rawDisk.devSweepDisplayPath,
            isSelected: false,
            kind: .dockerPrune
        ) {
            items.append(rawDiskItem)
        }

        // 没有 Docker 数据目录时（例如扫描的是伪造 home），CLI 仍在运行也不能把
        // 系统级 Docker 占用算进这个目录；否则清理结果会指向不存在的路径。
        guard FileManager.default.fileExists(atPath: dockerDataRoot.path),
              DockerSupport.executableURL() != nil else { return items }
        guard let output = DockerSupport.run(arguments: ["system", "df", "--format", "{{json .}}"])
        else {
            collector.skipped(
                dockerDataRoot,
                reason: "Docker CLI 无法启动或 Docker 引擎未运行",
                kind: .unavailable
            )
            return items
        }
        guard output.status == 0 else {
            let detail = String(data: output.stderr, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            collector.skipped(
                dockerDataRoot,
                reason: detail?.isEmpty == false ? detail! : "Docker CLI 可用，但 Docker 引擎未运行或当前 context 不可用",
                kind: .unavailable
            )
            return items
        }

        collector.checked(dockerDataRoot)
        for line in String(data: output.stdout, encoding: .utf8)?.split(whereSeparator: \.isNewline) ?? [] {
            guard let data = line.data(using: .utf8),
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = payload["Type"] as? String,
                  let target = DockerCleanupTarget(dockerType: type),
                  let reclaimableText = payload["Reclaimable"] as? String,
                  let reclaimable = DockerReclaimableSize.bytes(from: reclaimableText),
                  reclaimable >= minimumItemSize else { continue }

            let virtualPath = dockerDataRoot.appendingPathComponent(".devsweep/\(target.rawValue)")
            items.append(CacheItem(
                category: "Docker",
                name: "\(target.displayName) · Docker",
                path: virtualPath,
                size: reclaimable,
                details: "Docker \(type) · \(reclaimableText)",
                risk: .review,
                kind: .dockerPrune,
                identifier: target.rawValue,
                note: target.note,
                isSelected: false
            ))
            progress(ScanProgress(
                phase: "发现 Docker 可回收资源",
                currentPath: "Docker \(type)",
                checkedPaths: collector.checkedPaths,
                matchedPaths: items.count,
                skippedPaths: collector.skippedPaths,
                permissionFailures: collector.permissionFailures
            ))
        }
        return items
    }

    private static func addCargoItems(
        cargoHome: URL,
        add: (String, String, URL, RiskLevel, String) -> Void
    ) {
        add("语言工具链", "Cargo 自定义 registry index", cargoHome.appendingPathComponent("registry/index"), .safe, "来自 CARGO_HOME，Cargo 会重新获取 registry 索引")
        add("语言工具链", "Cargo 自定义 registry cache", cargoHome.appendingPathComponent("registry/cache"), .safe, "来自 CARGO_HOME，Cargo 会重新下载 crate")
        add("语言工具链", "Cargo 自定义 registry source", cargoHome.appendingPathComponent("registry/src"), .review, "来自 CARGO_HOME；已解压依赖源码删除后会重新下载，可能影响离线构建和 IDE 索引")
        add("语言工具链", "Cargo 自定义 git checkout", cargoHome.appendingPathComponent("git/checkouts"), .review, "来自 CARGO_HOME；Git 依赖 checkout 删除后会重新获取")
        add("语言工具链", "Cargo 自定义 git database", cargoHome.appendingPathComponent("git/db"), .review, "来自 CARGO_HOME；Git 依赖数据库删除后会重新获取")
    }

    private static func xctestDeviceItems(
        home: URL,
        xctestActivityInspector: XCTestActivityInspecting,
        collector: inout ScanCollector,
        progress: @escaping (ScanProgress) -> Void
    ) -> [CacheItem] {
        let root = home.appendingPathComponent("Library/Developer/XCTestDevices")
        guard fileManager.fileExists(atPath: root.path) else { return [] }

        let children = childDirectories(at: root, collector: &collector, progress: progress)
        let clones = children.filter { UUID(uuidString: $0.lastPathComponent) != nil }

        // 只自动清理明确以 UUID 命名的 clone 子目录。XCTestDevices 根目录本身
        // 可能包含未来 Xcode 版本的新数据结构或未识别内容，永远不能因为没有
        // 测试进程就当作普通缓存自动清理。
        if clones.isEmpty {
            let note = children.isEmpty
                ? "测试克隆设备根目录；请先停止 XCTest/UI 测试后确认清理"
                : "XCTestDevices 目录包含无法识别为克隆设备的内容，不能整目录自动清理；请确认后手动处理"
            guard let item = makeItem(
                category: "XCTest",
                name: "XCTestDevices（全部）",
                path: root,
                risk: .review,
                note: note,
                collector: &collector,
                progress: progress,
                isSelected: false
            ) else { return [] }
            return [item]
        }

        // 进程状态只检测一次，所有 clone 共用同一个结果，保证状态一致
        // 且不会为每个目录重复运行 ps。
        let activityState = xctestActivityInspector.currentState()

        var items: [CacheItem] = []
        for child in clones {
            // 完整 UUID 放进 details，标题只显示短 ID，避免 36 位字符挤占列表。
            let cloneID = child.lastPathComponent
            let displayID = String(cloneID.prefix(8))
            let risk: RiskLevel
            let note: String
            let statusTitle: String
            let isSelected: Bool
            switch activityState {
            case .idle:
                risk = .safe
                note = "Xcode 测试产生的临时克隆设备。当前未检测到测试运行，删除后需要时会自动重新创建。"
                statusTitle = "可安全清理"
                isSelected = true
            case .running:
                risk = .manual
                note = "检测到 XCTest/UI 测试正在运行。请停止测试后重新扫描，运行中的测试设备不会被清理。"
                statusTitle = "正在测试"
                isSelected = false
            case .unknown:
                risk = .manual
                note = "无法确认 XCTest 是否正在运行，为避免破坏当前测试，本次禁止自动清理。"
                statusTitle = "无法确认状态"
                isSelected = false
            }
            if let item = makeItem(
                category: "XCTest",
                name: "XCTest 克隆设备 · \(displayID)",
                path: child,
                risk: risk,
                note: note,
                collector: &collector,
                progress: progress,
                isSelected: isSelected,
                statusTitle: statusTitle
            ) {
                items.append(item)
            }
        }
        return items
    }

    private static func simulatorItems(
        home: URL,
        collector: inout ScanCollector,
        progress: @escaping (ScanProgress) -> Void
    ) -> [CacheItem] {
        let devicesRoot = home.appendingPathComponent("Library/Developer/CoreSimulator/Devices")
        guard fileManager.fileExists(atPath: devicesRoot.path) else { return [] }

        guard let output = run(executable: "/usr/bin/xcrun", arguments: ["simctl", "list", "devices", "-j"]),
              output.status == 0,
              let object = try? JSONSerialization.jsonObject(with: output.stdout) as? [String: Any],
              let devicesByRuntime = object["devices"] as? [String: [[String: Any]]] else {
            collector.skipped(devicesRoot, reason: "无法运行 xcrun simctl，已显示未登记设备目录但不会自动删除", kind: .unavailable)
            return orphanSimulatorItems(
                devicesRoot: devicesRoot,
                knownIdentifiers: [],
                manualOnly: true,
                collector: &collector,
                progress: progress
            )
        }

        var items: [CacheItem] = []
        var knownIdentifiers = Set<String>()
        for runtime in devicesByRuntime.keys.sorted() {
            guard let devices = devicesByRuntime[runtime] else { continue }
            for device in devices.sorted(by: { ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "") }) {
                guard let udid = device["udid"] as? String,
                      let name = device["name"] as? String else { continue }
                knownIdentifiers.insert(udid)
                let path = devicesRoot.appendingPathComponent(udid)
                let reportedSize = (device["dataPathSize"] as? NSNumber)?.int64Value ?? 0
                let measurement = StorageMeasurementService.measure(path)
                let size = max(measurement.allocatedBytes, reportedSize)
                guard size >= minimumItemSize else { continue }
                let state = device["state"] as? String ?? "Unknown"
                let isAvailable = device["isAvailable"] as? Bool ?? true
                let risk: RiskLevel = state == "Booted" ? .manual : .review
                let note: String
                if state == "Booted" {
                    note = "设备正在运行，请先关机"
                } else if isAvailable {
                    note = "通过 simctl 删除，保持设备登记一致"
                } else {
                    note = "不可用设备，可通过 simctl 移除"
                }
                items.append(CacheItem(
                    category: "CoreSimulator",
                    name: "\(name) · \(state)",
                    path: path,
                    size: size,
                    sizeWarning: reportedSize >= measurement.allocatedBytes ? nil : measurement.warning,
                    details: "\(displayRuntime(runtime)) · \(udid)",
                    risk: risk,
                    kind: .simulatorDevice,
                    identifier: udid,
                    note: note,
                    isSelected: !isAvailable && state != "Booted"
                ))
            }
        }

        items += orphanSimulatorItems(
            devicesRoot: devicesRoot,
            knownIdentifiers: knownIdentifiers,
            manualOnly: false,
            collector: &collector,
            progress: progress
        )
        return items
    }

    private static func orphanSimulatorItems(
        devicesRoot: URL,
        knownIdentifiers: Set<String>,
        manualOnly: Bool,
        collector: inout ScanCollector,
        progress: @escaping (ScanProgress) -> Void
    ) -> [CacheItem] {
        let children = childDirectories(at: devicesRoot, collector: &collector, progress: progress)
        var items: [CacheItem] = []
        for child in children {
            let udid = child.lastPathComponent
            guard UUID(uuidString: udid) != nil, !knownIdentifiers.contains(udid) else { continue }
            let measurement = StorageMeasurementService.measure(child)
            guard measurement.allocatedBytes >= minimumItemSize else { continue }
            items.append(CacheItem(
                category: "CoreSimulator",
                name: "未登记模拟器目录 · \(udid)",
                path: child,
                size: measurement.allocatedBytes,
                sizeWarning: measurement.warning,
                details: child.devSweepDisplayPath,
                risk: .manual,
                kind: .simulatorDevice,
                identifier: udid,
                note: manualOnly ? "simctl 不可用，不能安全确认设备登记状态" : "目录未出现在 simctl 列表中，请勿直接删除",
                isSelected: false
            ))
        }
        return items
    }

    /// 把已安装的模拟器 Runtime 变成可清理条目。
    ///
    /// 语义和设备不同：
    /// - 只有 `simctl runtime delete` 能删除，条目只用于展示与选择，删除动作由
    ///   `SimulatorRuntimeDeleting` 负责；
    /// - `deletable == false`、或属于「每平台保留最新」的系统内置运行时永远不可勾选；
    /// - 旧版本默认勾选，最新版本默认不勾选，避免一键清理把唯一可用的 Runtime 删掉；
    /// - 体积来自 simctl 报告的 disk image 大小，不再 du 挂载点（只读挂载会重复计算）。
    static func simulatorRuntimeItems(
        runtimeLister: SimulatorRuntimeListing,
        home: URL,
        collector: inout ScanCollector
    ) -> [CacheItem] {
        let runtimes: [SimulatorRuntimeInfo]
        do {
            runtimes = try runtimeLister.runtimes()
        } catch {
            collector.skipped(
                home.appendingPathComponent("Library/Developer/CoreSimulator"),
                reason: "无法读取模拟器 Runtime 列表：\(error.localizedDescription)；Runtime 不会出现在本次结果里",
                kind: .unavailable
            )
            return []
        }
        guard !runtimes.isEmpty else { return [] }

        let policy = SimulatorRuntimeCleaner.removableIdentifiers(runtimes)
        let kept = Set(policy.kept.map(\.identifier))
        let removable = Set(policy.removable.map(\.identifier))
        let blockedReason = Dictionary(
            policy.blocked.map { ($0.runtime.identifier, $0.reason) },
            uniquingKeysWith: { first, _ in first }
        )

        var items: [CacheItem] = []
        items.reserveCapacity(runtimes.count)
        for runtime in runtimes {
            let platform = SimulatorRuntimeCleaner.platformTitle(runtime.platformIdentifier)
            let displayVersion = runtime.displayVersion
            let risk: RiskLevel
            let note: String
            let statusTitle: String
            let isSelected: Bool
            if removable.contains(runtime.identifier) {
                risk = .review
                note = "较旧的 Runtime：删除后需要时重新下载；仍在用它的模拟器设备会变得不可用，且不能从废纸篓恢复"
                statusTitle = "可删除"
                // 不可恢复的系统镜像不默认勾选：让用户看清版本与影响后自己决定。
                isSelected = false
            } else if kept.contains(runtime.identifier) || runtime.deletable != false {
                risk = .review
                note = "该平台最新的 Runtime：保留它才能运行模拟器；删除后需要重新下载系统镜像"
                statusTitle = "保留最新"
                isSelected = false
            } else {
                risk = .manual
                note = "simctl 标记为不可移除，不能自动清理"
                statusTitle = "不可移除"
                isSelected = false
            }
            let blocked = blockedReason[runtime.identifier].map { "（\($0)）" } ?? ""
            // 只读挂载点（/Library/Developer/CoreSimulator/Volumes/...）不是可清理
            // 路径：删除逻辑只认 identifier，这个 URL 只用于展示与白名单匹配，
            // 因此按挂载点存在与否选择，避免拿裸 identifier 伪装成本地路径。
            let displayPath = runtime.mountPath
                ?? runtime.parentMountPath
                ?? "/Library/Developer/CoreSimulator/Volumes/\(runtime.displayVersion)"
            items.append(CacheItem(
                category: "CoreSimulator",
                name: "Runtime \(displayVersion) · \(platform)",
                path: URL(fileURLWithPath: displayPath),
                size: max(runtime.sizeBytes ?? 0, 0),
                sizeWarning: runtime.sizeBytes == nil ? "simctl 未报告该 Runtime 的体积，实际占用未知" : nil,
                details: [runtime.build.map { "build \($0)" }, runtime.identifier]
                    .compactMap { $0 }
                    .joined(separator: " · "),
                risk: risk,
                kind: .simulatorRuntime,
                identifier: runtime.identifier,
                note: note + blocked,
                statusTitle: statusTitle,
                isSelected: isSelected
            ))
        }
        return items
    }

    /// Time Machine 本地快照作为可清理条目。
    ///
    /// 每个快照单独一条、永不默认勾选：快照是备份，删掉就没有这一份时间点。
    /// `com.apple.os.update-*` 不进入候选（由 TimeMachineSnapshotCleaner 过滤）。
    static func timeMachineSnapshotItems(
        snapshotLister: TimeMachineSnapshotListing,
        collector: inout ScanCollector
    ) -> [CacheItem] {
        let snapshots: [TimeMachineSnapshot]
        do {
            snapshots = try snapshotLister.snapshots()
        } catch {
            collector.skipped(
                URL(fileURLWithPath: "/"),
                reason: "无法读取 Time Machine 本地快照：\(error.localizedDescription)",
                kind: .unavailable
            )
            return []
        }
        return snapshots.map { snapshot in
            CacheItem(
                category: "Time Machine 快照",
                name: "本地快照 \(snapshot.displayName)",
                // 快照没有可直接删除的文件路径：删除只走 `tmutil deletelocalsnapshots`。
                // 这里不做成真实路径——用 "/" 或卷根都会命中「受保护路径」校验，且在
                // 界面上看起来像「要删整个磁盘」。改用一条不可解析为真实路径的标记
                // URL（位于受保护的系统快照命名空间），配合 kind == .timeMachineSnapshot
                // 在校验里按「非文件系统目标」处理。
                path: URL(fileURLWithPath: "/System/Volumes/Data/.devsweep-time-machine-snapshots/\(snapshot.dateToken)"),
                size: 0,
                sizeWarning: "Time Machine 不报告单个本地快照的体积；删除后由系统回收空间",
                details: snapshot.name,
                // 用 .review 而不是 .manual：.manual 会让复选框与「清理这一项」
                // 直接禁用，用户在界面上根本删不掉快照。逐项确认由
                // isBatchSelectable（批量入口拒绝）与执行器（删前重列、删后复核）保证。
                risk: .review,
                kind: .timeMachineSnapshot,
                identifier: snapshot.dateToken,
                note: "本地快照是 Time Machine 在磁盘上保留的一个还原点，删除后无法恢复；"
                    + "系统需要空间时本来也会自动回收最早的快照",
                statusTitle: "需逐条确认",
                isSelected: false
            )
        }
    }

    private static func projectArtifacts(
        in root: URL,
        deepScan: Bool,
        collector: inout ScanCollector,
        progress: @escaping (ScanProgress) -> Void
    ) -> [CacheItem] {
        let artifactContainerBlocklist: Set<String> = [
            "node_modules", "target", "build", "dist", "vendor", "Pods", "bin", "obj",
            "venv", ".venv", ".gradle", ".next", ".nuxt", ".output", ".turbo",
            ".parcel-cache", ".dart_tool", ".svelte-kit", "DerivedData", ".build"
        ]
        let protectedAgentRoots: Set<String> = [".codex", ".claude"]
        if artifactContainerBlocklist.contains(root.lastPathComponent)
            || protectedAgentRoots.contains(root.lastPathComponent) {
            collector.skipped(
                root,
                reason: protectedAgentRoots.contains(root.lastPathComponent)
                    ? "AI Agent 状态根目录不会作为项目根扫描"
                    : "项目根自身是已知生成物容器，已跳过其内部项目发现",
                kind: .skipped
            )
            return []
        }

        let skipNames: Set<String> = [
            ".git", ".hg", ".svn", ".Trash", "Library", "Applications", "Pictures", "Movies"
        ]
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .nameKey]
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: []
        ) else {
            collector.skipped(root, reason: "无法枚举项目目录，可能需要在系统设置中授予文件访问权限", kind: .inaccessible)
            return []
        }

        var items: [CacheItem] = []
        for case let url as URL in enumerator {
            collector.checked(url)
            if collector.checkedPaths % 64 == 0 {
                progress(ScanProgress(
                    phase: deepScan ? "深度扫描项目生成物" : "扫描项目生成物",
                    currentPath: url.devSweepDisplayPath,
                    checkedPaths: collector.checkedPaths,
                    matchedPaths: items.count,
                    skippedPaths: collector.skippedPaths,
                    permissionFailures: collector.permissionFailures
                ))
            }

            let depth = url.pathComponents.count - root.standardizedFileURL.pathComponents.count
            if !deepScan && depth > 4 && !allowsModelCacheLookup(url, root: root) {
                collector.skippedPaths += 1
                enumerator.skipDescendants()
                continue
            }

            let name = url.lastPathComponent
            if skipNames.contains(name) {
                collector.skippedPaths += 1
                enumerator.skipDescendants()
                continue
            }

            let values: URLResourceValues
            do {
                values = try url.resourceValues(forKeys: keys)
            } catch {
                collector.skipped(url, reason: "无法读取目录属性", kind: .inaccessible)
                enumerator.skipDescendants()
                continue
            }

            guard values.isSymbolicLink != true else { continue }
            if values.isDirectory != true {
                guard let releaseRule = projectReleaseFileRule(for: url) else { continue }
                if let item = makeItem(
                    category: releaseRule.category,
                    name: "\(name) · \(url.deletingLastPathComponent().lastPathComponent)",
                    path: url,
                    risk: releaseRule.risk,
                    note: releaseRule.note,
                    collector: &collector,
                    progress: progress
                ) {
                    items.append(item)
                }
                continue
            }

            guard let generatedRule = generatedRule(for: url) else { continue }

            // cargo 的 target/ 是几百 GB 的容器，整块只报一条既看不出哪里最占空间，
            // 也没法只清 incremental 而保留已编译依赖。这里拆成 artifact 级条目。
            if let cargoArtifacts = cargoTargetArtifacts(
                at: url,
                rule: generatedRule,
                collector: &collector,
                progress: progress
            ) {
                items += cargoArtifacts
                enumerator.skipDescendants()
                continue
            }

            if let item = makeItem(
                category: generatedRule.category,
                name: "\(name) · \(url.deletingLastPathComponent().lastPathComponent)",
                path: url,
                risk: generatedRule.risk,
                note: generatedRule.note,
                collector: &collector,
                progress: progress
            ) {
                items.append(item)
            }
            // Generated folders are reported as one item; don't descend into them
            // and count nested target/build/cache folders a second time.
            enumerator.skipDescendants()
        }
        return items
    }

    /// 把 cargo `target/` 拆成 artifact 级条目。返回 nil 表示这不是 cargo target，
    /// 调用方继续按普通生成物目录处理（例如 Maven 的 target/）。
    ///
    /// 结构：`target/<profile>/<artifact>`、`target/<triple>/<profile>/<artifact>`，
    /// 以及 target 根下的 `doc`/`package`/自定义输出目录。
    /// 只按结构识别，不依赖 `debug`/`release` 字面名，自定义 profile 和三元组同样生效。
    private static func cargoTargetArtifacts(
        at target: URL,
        rule: GeneratedRule,
        collector: inout ScanCollector,
        progress: @escaping (ScanProgress) -> Void
    ) -> [CacheItem]? {
        guard target.lastPathComponent == "target", rule.category == "Rust / Tauri 项目" else { return nil }
        guard isCargoTargetRoot(target) else { return nil }

        let projectName = target.deletingLastPathComponent().lastPathComponent
        let topLevel = childDirectories(at: target, collector: &collector, progress: progress)

        func artifactChildren(of directory: URL) -> [URL] {
            childDirectories(at: directory, collector: &collector, progress: progress)
                .filter { cargoArtifactNames.contains($0.lastPathComponent) }
        }

        func buildFiles(of directory: URL) -> [URL] {
            let children = (try? fileManager.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )) ?? []
            return children.filter { cargoBuildFileProfile(for: $0) != nil }
        }

        var profiles: [(url: URL, prefix: String)] = []
        var rootArtifacts: [URL] = []
        var otherDirectories: [URL] = []

        for child in topLevel {
            // cargo doc / cargo package 直接放在 target 根，不在 profile 里。
            if cargoRootArtifactNames.contains(child.lastPathComponent) {
                rootArtifacts.append(child)
                continue
            }
            if !artifactChildren(of: child).isEmpty || !buildFiles(of: child).isEmpty {
                profiles.append((child, child.lastPathComponent))
                continue
            }
            // target/<triple>/<profile>
            var foundNestedProfile = false
            for grandChild in childDirectories(at: child, collector: &collector, progress: progress)
            where !artifactChildren(of: grandChild).isEmpty || !buildFiles(of: grandChild).isEmpty {
                profiles.append((grandChild, "\(child.lastPathComponent)/\(grandChild.lastPathComponent)"))
                foundNestedProfile = true
            }
            // 既不是 profile 也不是三元组：例如 target/macos-package 这类自定义输出，
            // 仍然单独列出，避免它在列表里凭空消失。
            if !foundNestedProfile {
                otherDirectories.append(child)
            }
        }
        guard !profiles.isEmpty || !rootArtifacts.isEmpty else { return nil }

        var candidates: [(url: URL, name: String, risk: RiskLevel, note: String)] = []
        for profile in profiles {
            for file in buildFiles(of: profile.url) {
                candidates.append((
                    url: file, name: "\(file.lastPathComponent) · \(profile.prefix) · \(projectName)",
                    risk: .review,
                    note: "Rust/Tauri 编译输出文件，移入废纸篓后需重新构建；请先保留仍需使用的可执行文件或库"
                ))
            }
            for artifact in artifactChildren(of: profile.url) {
                let artifactRule = cargoArtifactRule(artifact.lastPathComponent)
                candidates.append((
                    url: artifact,
                    name: "\(artifact.lastPathComponent) · \(profile.prefix) · \(projectName)",
                    risk: artifactRule.risk,
                    note: artifactRule.note
                ))
            }
        }
        for artifact in rootArtifacts {
            let artifactRule = cargoArtifactRule(artifact.lastPathComponent)
            candidates.append((
                url: artifact,
                name: "\(artifact.lastPathComponent) · target · \(projectName)",
                risk: artifactRule.risk,
                note: artifactRule.note
            ))
        }
        for directory in otherDirectories {
            candidates.append((
                url: directory,
                name: "\(directory.lastPathComponent) · target · \(projectName)",
                risk: .review,
                note: "cargo target 下的自定义输出目录（打包或中间产物），请确认内容后清理"
            ))
        }
        guard !candidates.isEmpty else { return nil }
        // 稳定排序：du 的硬链接去重是「先测到的目录拿走共享块」，顺序必须可复现，
        // 否则同一份 target 每次扫描的单项数字都会跳动。
        candidates.sort { left, right in
            let leftKey = "\(left.url.deletingLastPathComponent().path)/\(cargoArtifactSortRank(left.url.lastPathComponent))"
            let rightKey = "\(right.url.deletingLastPathComponent().path)/\(cargoArtifactSortRank(right.url.lastPathComponent))"
            return leftKey < rightKey
        }

        // 一次 du 测完所有候选：macOS du 会在同一次调用的参数之间对硬链接去重。
        // cargo 的 deps 与 incremental 共享大量 inode，逐个测量会把同一份磁盘块算两遍。
        let measured = StorageMeasurementService.measure(candidates.map(\.url))

        // 构建进行中时 cargo 持有 target/<profile>/.cargo-lock。此时 deps/incremental
        // 正在被写入，删除会破坏构建甚至让 cargo 崩溃，因此整组标为手动处理。
        let isBuilding = cargoBuildState(ofProfiles: profiles.map(\.url) + [target]) == .building

        var items: [CacheItem] = []
        for candidate in candidates {
            guard let item = makeItem(
                category: rule.category,
                name: candidate.name,
                path: candidate.url,
                risk: isBuilding ? .manual : candidate.risk,
                note: isBuilding
                    ? "检测到 cargo 正在构建该 target（持有 .cargo-lock），为避免破坏构建已禁止清理；请等构建结束后重新扫描"
                    : candidate.note,
                collector: &collector,
                progress: progress,
                isSelected: isBuilding ? false : nil,
                statusTitle: isBuilding ? "正在构建" : nil,
                measurement: measured[candidate.url.standardizedFileURL.path]
            ) else { continue }
            items.append(item)
        }

        // 若 profile 结构异常（例如只剩最终二进制、没有 artifact 子目录），
        // 退回整目录条目，避免 cargo target 在列表里完全消失。
        guard !items.isEmpty else { return nil }
        return items
    }

    /// profile 目录内的 artifact 子目录。
    private static let cargoArtifactNames: Set<String> = [
        "deps", "incremental", "build", ".fingerprint", "examples", "doc", "package", "bundle"
    ]

    /// 直接位于 target 根（而不是 profile 里）的 artifact 目录。
    private static let cargoRootArtifactNames: Set<String> = ["doc", "package"]

    /// 测量顺序权重：让最「重」的目录先测，把共享硬链接算到它头上。
    /// 这样 deps（真正占用大头）不会因为 incremental 先测而显得很小。
    private static func cargoArtifactSortRank(_ name: String) -> String {
        switch name {
        case "deps": return "00"
        case "incremental": return "01"
        case "build": return "02"
        case "examples": return "03"
        case ".fingerprint": return "04"
        case "doc": return "05"
        case "package": return "06"
        case "bundle": return "07"
        default: return "99-\(name)"
        }
    }

    private static func cargoArtifactRule(_ name: String) -> (risk: RiskLevel, note: String) {
        switch name {
        case "incremental":
            return (.safe, "增量编译缓存，删除后下次构建变慢但结果不变；这是 cargo target 里最安全的清理项")
        case "doc":
            return (.safe, "cargo doc 生成的文档，可重新生成")
        case "deps":
            return (.review, "依赖库与测试可执行文件，删除后 cargo 会重新编译依赖")
        case "build":
            return (.review, "build script 的编译输出和 OUT_DIR，删除后重新执行 build script")
        case ".fingerprint":
            return (.review, "编译指纹，删除后会触发重新编译")
        case "examples":
            return (.review, "example 构建产物，删除后重新编译示例")
        case "package":
            return (.review, "cargo package 生成的打包产物，可重新生成")
        case "bundle":
            return (.review, "cargo-bundle 等打包工具输出的应用包，可重新生成")
        default:
            return (.review, "cargo 构建产物，可重新生成")
        }
    }

    /// 判定一个 `target/` 是否真是 cargo 产物：cargo 会在 target 根写入
    /// CACHEDIR.TAG 和 .rustc_info.json；Maven 的 target 两者都没有。
    private static func isCargoTargetRoot(_ target: URL) -> Bool {
        fileManager.fileExists(atPath: target.appendingPathComponent(".rustc_info.json").path)
            || hasValidCacheDirectoryTag(target)
    }

    fileprivate enum CargoBuildState {
        case idle
        case building
        case unknown
    }

    /// 用 cargo 自己的 `.cargo-lock` 判断是否正在构建：
    /// 以非阻塞方式尝试加 flock，加得上说明没有 cargo 进程持有它。
    /// 只读检查，不加 --wait，不会阻塞扫描；拿不到结论时返回 unknown（不改变风险）。
    fileprivate static func cargoBuildState(ofProfiles profiles: [URL]) -> CargoBuildState {
        var sawLockFile = false
        var state = CargoBuildState.idle
        for lock in profiles.flatMap({ profile in cargoLockNames.map { profile.appendingPathComponent($0) } }) {
            guard fileManager.fileExists(atPath: lock.path) else { continue }
            sawLockFile = true
            switch cargoLockIsHeld(lock) {
            case .some(true):
                return .building
            case .some(false):
                continue
            case .none:
                state = .unknown
            }
        }
        return sawLockFile ? state : .unknown
    }

    private static let cargoLockNames = [".cargo-lock", ".cargo-build-lock", ".cargo-artifact-lock"]

    static func cargoLockPaths(forArtifact path: URL) -> [URL] {
        guard let lock = cargoProfileLockPath(forArtifact: path) else { return [] }
        var directory = lock.deletingLastPathComponent()
        var paths: [URL] = []
        // Include profile, optional target triple, and target root locks.
        for _ in 0..<3 {
            paths += cargoLockNames.map { directory.appendingPathComponent($0) }
            if directory.lastPathComponent == "target" { break }
            directory.deleteLastPathComponent()
        }
        return paths
    }

    /// 返回 true 表示已有进程持有该文件的 flock（cargo 正在构建）。
    fileprivate static func cargoLockIsHeld(_ lock: URL) -> Bool? {
        let descriptor = open(lock.path, O_RDONLY)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }

        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
            flock(descriptor, LOCK_UN)
            return false
        }
        return errno == EWOULDBLOCK ? true : nil
    }

    /// 由 artifact 路径反推 cargo profile 的锁文件：
    /// `.../target/<profile>/deps` 与 `.../target/<triple>/<profile>/deps` 都覆盖。
    /// 根级的 `target/doc`、`target/package` 归到 target 根：cargo 的 `.cargo-lock` 也可能
    /// 直接放在 target 下，因此两种位置都返回候选锁路径。
    /// 只认 target 下两层的标准结构，避免把任意路径当 cargo 目标。
    static func cargoProfileLockPath(forArtifact path: URL) -> URL? {
        if let profile = cargoBuildFileProfile(for: path) {
            return profile.appendingPathComponent(".cargo-lock")
        }
        let artifact = path.standardizedFileURL
        guard cargoArtifactNames.contains(artifact.lastPathComponent) else { return nil }
        let profile = artifact.deletingLastPathComponent()

        // target/<artifact>：doc、package 直接挂在 target 根。
        if profile.lastPathComponent == "target" {
            guard cargoRootArtifactNames.contains(artifact.lastPathComponent) else { return nil }
            return profile.appendingPathComponent(".cargo-lock")
        }
        // target/<profile>/<artifact> 或 target/<triple>/<profile>/<artifact>：
        // 交叉编译时 profile 的父目录是三元组，再上一层才是 target。
        let parent = profile.deletingLastPathComponent()
        guard parent.lastPathComponent == "target"
                || parent.deletingLastPathComponent().lastPathComponent == "target"
        else { return nil }
        return profile.appendingPathComponent(".cargo-lock")
    }

    /// Direct profile outputs were previously invisible when deps/incremental
    /// had already been cleaned. Restrict files to proven Cargo output roots.
    static func cargoBuildFileProfile(for path: URL) -> URL? {
        guard !path.lastPathComponent.hasPrefix("."),
              FileIdentity.capture(path)?.kind == .regular else { return nil }
        let profile = path.deletingLastPathComponent()
        let parent = profile.deletingLastPathComponent()
        let target: URL
        if parent.lastPathComponent == "target" { target = parent }
        else if parent.deletingLastPathComponent().lastPathComponent == "target" {
            target = parent.deletingLastPathComponent()
        } else { return nil }
        guard isCargoTargetRoot(target),
              fileManager.fileExists(atPath: profile.appendingPathComponent(".cargo-lock").path)
                || fileManager.fileExists(atPath: profile.appendingPathComponent(".fingerprint").path)
                || ["debug", "release"].contains(profile.lastPathComponent)
        else { return nil }
        let outputExtensions: Set<String> = ["a", "rlib", "rmeta", "dylib", "so", "dll", "exe", "pdb", "o", "d"]
        guard outputExtensions.contains(path.pathExtension.lowercased())
                || (path.pathExtension.isEmpty && fileManager.isExecutableFile(atPath: path.path))
        else { return nil }
        return profile
    }

    private static let monorepoMarkers: Set<String> = [
        "lerna.json", "pnpm-workspace.yaml", "nx.json", "rush.json", ".git"
    ]

    private static let generatedRules: [String: GeneratedRule] = [
        "target": GeneratedRule(category: "Rust / Tauri 项目", risk: .review, note: "Rust/Tauri 编译产物，删除后 cargo build 会重新生成"),
        "node_modules": GeneratedRule(category: "Node.js 项目", risk: .review, note: "删除后 npm/pnpm/yarn install 会重新安装依赖"),
        ".build": GeneratedRule(category: "Swift 项目", risk: .review, note: "SwiftPM 编译产物，删除后会重新构建"),
        "Pods": GeneratedRule(category: "Apple 项目", risk: .review, note: "删除后 pod install 会重新生成"),
        "build": GeneratedRule(category: "项目生成物", risk: .review, note: "项目构建产物，可按需重新生成"),
        "dist": GeneratedRule(category: "项目生成物", risk: .review, note: "发布产物，可按需重新生成"),
        ".next": GeneratedRule(category: "Node.js 项目", risk: .safe, note: "Next.js 缓存和构建产物，会自动重建"),
        ".turbo": GeneratedRule(category: "Node.js 项目", risk: .safe, note: "Turborepo 缓存，会自动重建"),
        ".cache": GeneratedRule(category: "项目生成物", risk: .review, note: "项目工具缓存，删除后会重新生成"),
        ".dart_tool": GeneratedRule(category: "Flutter 项目", risk: .review, note: "Flutter/Dart 工具产物，会重新生成"),
        ".parcel-cache": GeneratedRule(category: "Node.js 项目", risk: .safe, note: "Parcel 缓存，会自动重建"),
        ".vite": GeneratedRule(category: "Node.js 项目", risk: .safe, note: "Vite 缓存，会自动重建"),
        ".svelte-kit": GeneratedRule(category: "Node.js 项目", risk: .review, note: "SvelteKit 构建产物，会重新生成"),
        "out": GeneratedRule(category: "项目生成物", risk: .review, note: "项目输出目录，可按需重新生成"),
        "coverage": GeneratedRule(category: "测试产物", risk: .safe, note: "测试覆盖率报告，可重新生成"),
        ".pytest_cache": GeneratedRule(category: "Python 项目", risk: .safe, note: "pytest 缓存，会自动重建"),
        "__pycache__": GeneratedRule(category: "Python 项目", risk: .safe, note: "Python 字节码缓存，会自动重建"),
        ".mypy_cache": GeneratedRule(category: "Python 项目", risk: .safe, note: "mypy 缓存，会自动重建"),
        ".ruff_cache": GeneratedRule(category: "Python 项目", risk: .safe, note: "Ruff 缓存，会自动重建"),
        ".venv": GeneratedRule(category: "Python 项目", risk: .review, note: "Python 虚拟环境，删除后需要重新创建并安装依赖"),
        "venv": GeneratedRule(category: "Python 项目", risk: .review, note: "Python 虚拟环境，删除后需要重新创建并安装依赖"),
        ".tox": GeneratedRule(category: "Python 项目", risk: .review, note: "tox 测试环境，删除后会重新创建"),
        ".nox": GeneratedRule(category: "Python 项目", risk: .review, note: "nox 测试环境，删除后会重新创建"),
        ".terraform": GeneratedRule(category: "项目生成物", risk: .review, note: "Terraform 工作目录，删除后需要重新初始化"),
        ".terragrunt-cache": GeneratedRule(category: "项目生成物", risk: .safe, note: "Terragrunt 下载的模块和 provider 缓存，会自动重建"),
        ".nx": GeneratedRule(category: "Node.js 项目", risk: .safe, note: "Nx 缓存，会自动重建"),
        ".angular": GeneratedRule(category: "Node.js 项目", risk: .safe, note: "Angular 缓存，会自动重建"),
        ".nuxt": GeneratedRule(category: "Node.js 项目", risk: .safe, note: "Nuxt 构建缓存，会自动重建"),
        ".output": GeneratedRule(category: "Node.js 项目", risk: .review, note: "Nuxt 输出目录，可按需重新生成"),
        ".expo": GeneratedRule(category: "Node.js 项目", risk: .review, note: "Expo 项目缓存，删除后会重新生成"),
        ".astro": GeneratedRule(category: "Node.js 项目", risk: .safe, note: "Astro 构建缓存，会自动重建"),
        "cmake-build-debug": GeneratedRule(category: "项目生成物", risk: .review, note: "CMake 构建产物，可按需重新生成"),
        "cmake-build-release": GeneratedRule(category: "项目生成物", risk: .review, note: "CMake 构建产物，可按需重新生成"),
        ".zig-cache": GeneratedRule(category: "项目生成物", risk: .safe, note: "Zig 构建缓存，会自动重建"),
        "zig-cache": GeneratedRule(category: "项目生成物", risk: .safe, note: "Zig 构建缓存，会自动重建"),
        "zig-out": GeneratedRule(category: "项目生成物", risk: .review, note: "Zig 构建输出，可按需重新生成"),
        ".cxx": GeneratedRule(category: "Android 项目", risk: .safe, note: "Android NDK/CMake 构建缓存，会自动重建"),
        "bazel-out": GeneratedRule(category: "项目生成物", risk: .safe, note: "Bazel 输出缓存，会自动重建"),
        "buck-out": GeneratedRule(category: "项目生成物", risk: .safe, note: "Buck 输出缓存，会自动重建"),
        ".gradle": GeneratedRule(category: "JVM", risk: .safe, note: "项目级 Gradle 缓存，会自动重建")
    ]

    private static let projectReleaseArchiveSuffixes = [
        ".pkg", ".dmg", ".zip", ".app.zip", ".tar.gz", ".tar.bz2", ".tar.xz",
        ".appimage", ".deb", ".msi", ".exe"
    ]

    static func generatedRule(for url: URL) -> GeneratedRule? {
        let name = url.lastPathComponent
        let parent = url.deletingLastPathComponent()
        if let rule = xcodeDerivedDataRule(for: url) {
            return rule
        }
        if name == "logs" || name == "log" {
            let projectDirectories = [parent, parent.deletingLastPathComponent()]
            guard projectDirectories.contains(where: hasProjectMarker) else { return nil }
            return GeneratedRule(category: "项目日志", risk: .review, note: "项目运行日志；确认不再需要排查问题后清理")
        }
        if name == "vendor" {
            guard fileManager.fileExists(atPath: parent.appendingPathComponent("composer.json").path) else { return nil }
            return GeneratedRule(category: "PHP 项目", risk: .review, note: "Composer 依赖，删除后 composer install 会重新安装")
        }
        if name == "build" {
            let projectDirectories = [parent, parent.deletingLastPathComponent()]
            guard projectDirectories.contains(where: hasProjectMarker) else { return nil }
            return GeneratedRule(category: "项目生成物", risk: .review, note: "项目构建产物，可按需重新生成；只有在项目标志明确时才会识别")
        }
        if name == "output" {
            guard hasProjectMarker(parent) else { return nil }
            return GeneratedRule(category: "项目生成物", risk: .review, note: "项目输出目录，可按需重新生成；请确认没有需要保留的截图或发布结果")
        }
        if let rule = projectReleaseDirectoryRule(for: url) {
            return rule
        }
        if name == "bin" || name == "obj" {
            guard directoryContainsProjectFile(parent, extensions: ["csproj", "fsproj", "vbproj"]) else { return nil }
            return GeneratedRule(category: ".NET 项目", risk: .review, note: ".NET 构建产物，删除后 dotnet build 会重新生成")
        }
        if name == "DerivedData" {
            guard directoryContainsProjectFile(parent, extensions: ["xcodeproj", "xcworkspace"]) else { return nil }
            return GeneratedRule(category: "Apple 项目", risk: .review, note: "项目内 Xcode DerivedData，删除后会重新构建")
        }
        if name == ".cxx" {
            let grandparent = parent.deletingLastPathComponent()
            guard directoryContainsNamedFile(parent, names: ["build.gradle", "build.gradle.kts"])
                    || directoryContainsNamedFile(grandparent, names: ["build.gradle", "build.gradle.kts"])
            else { return nil }
        }
        if url.lastPathComponent == "Build" && url.deletingLastPathComponent().lastPathComponent == "Carthage" {
            return GeneratedRule(category: "Apple 项目", risk: .review, note: "Carthage 构建产物，会重新下载或构建")
        }
        if url.lastPathComponent == "cache" && url.deletingLastPathComponent().lastPathComponent == ".yarn" {
            return GeneratedRule(category: "Node.js 项目", risk: .review, note: "Yarn 离线缓存，会重新下载依赖")
        }
        if url.lastPathComponent.hasPrefix("cmake-build-") {
            return GeneratedRule(category: "项目生成物", risk: .review, note: "CMake 构建产物，可按需重新生成")
        }
        // `target` 是 cargo 和 Maven/Gradle 共用的目录名，必须按内容判断归属，
        // 不能按名字直接归到 Rust，也不能让 CACHEDIR.TAG 抢先命中。
        if name == "target", let rule = targetDirectoryRule(for: url) {
            return rule
        }
        if let rule = modelCacheRule(for: url) {
            return rule
        }
        // 具名规则优先于 CACHEDIR.TAG：cargo 会在 target/ 写入 CACHEDIR.TAG，
        // 如果让 tag 抢先命中，整个 target 会被误标成「其他开发缓存 / 可直接清理」，
        // 既丢失 Rust 分类，又可能被一键勾选删除。
        if let rule = generatedRules[url.lastPathComponent] {
            return rule
        }
        if hasValidCacheDirectoryTag(url) {
            return GeneratedRule(category: "其他开发缓存", risk: .safe, note: "目录包含有效 CACHEDIR.TAG，软件声明其内容可作为缓存重建；仍受删除安全校验和白名单控制")
        }
        return nil
    }

    /// 项目内模型缓存常见于 `tools/models/cache`、`models/`、`checkpoints/` 等
    /// 不叫 `.cache` 的目录；按 HF 下载回执或「config.json + 权重文件」识别，
    /// 不按目录名直接下结论。
    private static let modelCacheContainerNames: Set<String> = [
        "cache", "model_cache", "models", "model", "checkpoints", "weights"
    ]

    private static let modelWeightExtensions: Set<String> = [
        "safetensors", "gguf", "onnx", "pt", "pth", "ckpt", "tflite", "h5", "mlmodel", "mlpackage"
    ]

    private static let modelCacheGeneratedRule = GeneratedRule(
        category: "AI/ML",
        risk: .review,
        note: "项目内模型缓存，删除后需要重新下载或重新转换；请确认模型仍可从源获取"
    )

    /// 模型缓存目录通常比普通项目生成物更深（如 `tools/models/cache/<model>`），
    /// 默认深度限制会直接跳过。只在路径出现模型容器名时放宽到第 7 层。
    private static func allowsModelCacheLookup(_ url: URL, root: URL) -> Bool {
        let rootComponents = root.standardizedFileURL.pathComponents
        let components = url.standardizedFileURL.pathComponents
        guard components.count - rootComponents.count <= 7 else { return false }
        return components.dropFirst(rootComponents.count).contains {
            modelCacheContainerNames.contains($0.lowercased())
        }
    }

    private static func modelCacheRule(for url: URL) -> GeneratedRule? {
        guard modelCacheContainerNames.contains(url.lastPathComponent.lowercased()) else { return nil }
        if isModelRepositoryDirectory(url) {
            return modelCacheGeneratedRule
        }
        guard let children = try? fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ) else { return nil }
        let holdsModels = children.contains { child in
            guard let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true,
                  values.isSymbolicLink != true
            else { return false }
            return isModelRepositoryDirectory(child)
        }
        return holdsModels ? modelCacheGeneratedRule : nil
    }

    private static func isModelRepositoryDirectory(_ directory: URL) -> Bool {
        guard let children = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ) else { return false }

        let names = Set(children.map(\.lastPathComponent))
        let hasHuggingFaceReceipt = fileManager.fileExists(
            atPath: directory.appendingPathComponent(".cache/huggingface").path
        )
        let hasWeights = children.contains { child in
            modelWeightExtensions.contains(child.pathExtension.lowercased())
        }
        if hasHuggingFaceReceipt {
            return names.contains("config.json") || hasWeights
        }
        return names.contains("config.json") && hasWeights
    }

    /// 只读发现页的模型证据：Hugging Face 的 `models--组织--模型` 仓库有
    /// snapshots / blobs 引用结构，必须按仓库整体识别，不能把子目录当独立缓存。
    static func huggingFaceModelEvidence(for url: URL) -> String? {
        guard url.lastPathComponent.hasPrefix("models--") else { return nil }
        let names = Set((try? fileManager.contentsOfDirectory(atPath: url.path)) ?? [])
        guard names.contains("snapshots") || names.contains("blobs") else { return nil }
        return "Hugging Face 模型仓库（models--…，包含 snapshots / blobs 引用结构）"
    }

    /// 项目内 `models/`、`checkpoints/` 等容器的模型证据；没有权重文件时不返回。
    static func modelDirectoryEvidence(for url: URL) -> String? {
        guard modelCacheRule(for: url) != nil else { return nil }
        if fileManager.fileExists(atPath: url.appendingPathComponent(".cache/huggingface").path) {
            return "包含 Hugging Face 下载回执和模型文件"
        }
        return "包含 config.json 与模型权重文件"
    }

    /// `target` 目录的归属判断，按证据优先级：
    /// 1. cargo 证据（`.rustc_info.json` / 带 cargo 签名的 CACHEDIR.TAG / profile 下的
    ///    `.cargo-lock`、`.fingerprint`）→ Rust；
    /// 2. 同级有 `Cargo.toml` → Rust（刚创建、还没构建的 target）；
    /// 3. Java 构建输出特征（classes、generated-sources 等）→ JVM；
    /// 4. 同级有其他项目标志 → 通用项目生成物；
    /// 5. 都没有 → nil，避免按名字误报。
    private static func targetDirectoryRule(for url: URL) -> GeneratedRule? {
        let parent = url.deletingLastPathComponent()
        if isCargoTargetRoot(url) {
            return GeneratedRule(
                category: "Rust / Tauri 项目",
                risk: .review,
                note: "Rust/Tauri 编译产物，删除后 cargo build 会重新生成"
            )
        }
        if directoryContainsNamedFile(parent, names: ["Cargo.toml"]) {
            return GeneratedRule(
                category: "Rust / Tauri 项目",
                risk: .review,
                note: "Rust/Tauri 编译产物，删除后 cargo build 会重新生成"
            )
        }
        if isJavaTargetDirectory(url) {
            return GeneratedRule(
                category: "JVM",
                risk: .review,
                note: "Maven/Gradle 构建输出（classes、生成源码、打包结果），重新构建会重新生成"
            )
        }
        if hasProjectMarker(parent) {
            return GeneratedRule(
                category: "项目生成物",
                risk: .review,
                note: "项目构建输出目录，可按需重新生成；请确认内容后清理"
            )
        }
        return nil
    }

    /// Java 构建输出特征。fastbee 这类模块可能没有 pom.xml（父工程统一管理或
    /// 只保留了 target），因此以目录内容为准，不强制要求同级构建文件。
    static func isJavaTargetDirectory(_ url: URL) -> Bool {
        guard url.lastPathComponent == "target" else { return false }
        let artifactNames: Set<String> = [
            "classes", "test-classes", "generated-sources", "generated-test-sources",
            "maven-status", "surefire-reports", "failsafe-reports", "site", "maven-archiver"
        ]
        guard let children = try? fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return false }
        let names = Set(children.map(\.lastPathComponent))
        return !names.isDisjoint(with: artifactNames)
    }

    static func hasValidCacheDirectoryTag(_ directory: URL) -> Bool {
        let tag = directory.appendingPathComponent("CACHEDIR.TAG")
        guard let values = try? tag.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory != true,
              values.isSymbolicLink != true
        else { return false }

        let signature = Data("Signature: 8a477f597d28d172789f06886806bc55".utf8)
        guard let handle = try? FileHandle(forReadingFrom: tag) else { return false }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: signature.count),
              header.count >= signature.count
        else { return false }
        return header.prefix(signature.count) == signature
    }

    private static func projectReleaseDirectoryRule(for url: URL) -> GeneratedRule? {
        let name = url.lastPathComponent
        guard name.range(
            of: #"^release[-_]v?\d+(?:\.\d+){1,3}$"#,
            options: .regularExpression
        ) != nil else { return nil }

        let projectRoot = url.deletingLastPathComponent()
        guard hasProjectMarker(projectRoot), hasProjectReleaseSignature(at: url) else { return nil }
        return GeneratedRule(
            category: "项目生成物",
            risk: .review,
            note: "项目 Release/CI 发布暂存目录，包含安装包或签名产物；确认版本已发布且不再需要后清理"
        )
    }

    private static func projectReleaseFileRule(for url: URL) -> GeneratedRule? {
        let name = url.lastPathComponent.lowercased()
        guard projectReleaseArchiveSuffixes.contains(where: name.hasSuffix),
              name.range(of: #"\d+\.\d+(?:\.\d+){0,3}"#, options: .regularExpression) != nil
        else { return nil }
        let parent = url.deletingLastPathComponent()
        guard hasProjectMarker(parent) else { return nil }

        return GeneratedRule(
            category: "项目生成物",
            risk: .review,
            note: "项目版本发布安装包或归档；确认已上传或备份后清理"
        )
    }

    private static func hasProjectReleaseSignature(at directory: URL) -> Bool {
        let directoryMarkers: Set<String> = ["ci-artifacts", "final", "final-assets", "staging", "work"]
        guard let children = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ) else {
            return false
        }

        return children.contains { child in
            let childName = child.lastPathComponent.lowercased()
            return directoryMarkers.contains(childName)
                || childName == "latest.json"
                || projectReleaseArchiveSuffixes.contains(where: childName.hasSuffix)
        }
    }

    private static func xcodeDerivedDataRule(for url: URL) -> GeneratedRule? {
        let name = url.lastPathComponent
        guard name.hasPrefix("build-"), name.count > "build-".count else { return nil }

        let projectRoot = url.deletingLastPathComponent()
        guard directoryContainsProjectFile(projectRoot, extensions: ["xcodeproj", "xcworkspace"]) else {
            return nil
        }
        guard isXcodeDerivedDataDirectory(url) else { return nil }

        let releaseOutput = containsXcodeReleaseProduct(at: url)
        let note = releaseOutput
            ? "Xcode 自定义 DerivedData，包含 Release 产物；请确认不再需要后清理"
            : "Xcode 自定义 DerivedData，删除后会重新构建；请确认后清理"
        return GeneratedRule(category: "Apple 项目", risk: .review, note: note)
    }

    private static func isXcodeDerivedDataDirectory(_ directory: URL) -> Bool {
        guard let children = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ) else {
            return false
        }

        let names = Set(children.map(\.lastPathComponent))
        let markers: Set<String> = [
            "Build", "Index.noindex", "ModuleCache.noindex", "CompilationCache.noindex",
            "SDKStatCaches.noindex", "SourcePackages", "Logs", "TestResults", "info.plist"
        ]
        return names.intersection(markers).count >= 2
    }

    private static func containsXcodeReleaseProduct(at derivedData: URL) -> Bool {
        let releaseExtensions: Set<String> = ["app", "xcarchive", "zip", "pkg", "dmg"]
        // Release archives are sometimes copied beside the DerivedData markers
        // (for example, a manually packaged ZIP at the custom path's root).
        if containsXcodeReleaseArtifact(at: derivedData, extensions: releaseExtensions, maxDepth: 0) {
            return true
        }

        let productsRoot = derivedData.appendingPathComponent("Build/Products")
        if let configurations = try? fileManager.contentsOfDirectory(
            at: productsRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ) {
            // xcodebuild uses names such as Release, Release-iphoneos and
            // Release-macosx for platform-specific configurations.
            let releaseConfigurations = configurations.filter {
                $0.lastPathComponent.lowercased().hasPrefix("release")
            }
            if releaseConfigurations.contains(where: {
                containsXcodeReleaseArtifact(at: $0, extensions: releaseExtensions, maxDepth: 1)
            }) {
                return true
            }
        }

        // Archives produced by `xcodebuild archive` commonly live below
        // Build/Archives/<timestamp>/*.xcarchive rather than Products/Release.
        let archivesRoot = derivedData.appendingPathComponent("Build/Archives")
        return containsXcodeReleaseArtifact(at: archivesRoot, extensions: ["xcarchive"], maxDepth: 2)
    }

    private static func containsXcodeReleaseArtifact(
        at directory: URL,
        extensions: Set<String>,
        maxDepth: Int
    ) -> Bool {
        guard let children = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ) else {
            return false
        }

        for child in children {
            if extensions.contains(child.pathExtension.lowercased()) {
                return true
            }
            guard maxDepth > 0,
                  let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true,
                  values.isSymbolicLink != true
            else {
                continue
            }
            if containsXcodeReleaseArtifact(at: child, extensions: extensions, maxDepth: maxDepth - 1) {
                return true
            }
        }
        return false
    }

    private static func hasProjectMarker(_ directory: URL) -> Bool {
        let markerNames: Set<String> = [
            "pom.xml", "package.json", "Cargo.toml", "Package.swift", "composer.json",
            "build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts",
            "go.mod", "pyproject.toml", "requirements.txt", "conf/application.properties",
            "terragrunt.hcl", "Gemfile", "pubspec.yaml", "Makefile", "build.zig", "build.zig.zon",
            "composer.lock", "Package.resolved"
        ]
        return directoryContainsNamedFile(directory, names: markerNames)
            || monorepoMarkers.contains { directoryContainsNamedFile(directory, names: [$0]) }
            || directoryContainsProjectFile(directory, extensions: [
                "xcodeproj", "xcworkspace", "csproj", "fsproj", "vbproj"
            ])
    }

    private static func directoryContainsProjectFile(_ directory: URL, extensions: Set<String>) -> Bool {
        guard let children = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return false }
        return children.contains { extensions.contains($0.pathExtension.lowercased()) }
    }

    private static func directoryContainsNamedFile(_ directory: URL, names: Set<String>) -> Bool {
        names.contains { fileManager.fileExists(atPath: directory.appendingPathComponent($0).path) }
    }

    private static func makeItem(
        category: String,
        name: String,
        path: URL,
        risk: RiskLevel,
        note: String,
        collector: inout ScanCollector,
        progress: @escaping (ScanProgress) -> Void,
        details: String? = nil,
        isSelected: Bool? = nil,
        kind: CleanupKind = .trash,
        identifier: String? = nil,
        toolAction: ToolCleanupAction? = nil,
        statusTitle: String? = nil,
        measurement: StorageMeasurement? = nil
    ) -> CacheItem? {
        let standardized = path.standardizedFileURL
        guard fileManager.fileExists(atPath: standardized.path) else { return nil }
        collector.checked(standardized)
        if collector.checkedPaths % 32 == 0 {
            progress(ScanProgress(
                phase: "测量缓存占用",
                currentPath: standardized.devSweepDisplayPath,
                checkedPaths: collector.checkedPaths,
                matchedPaths: 0,
                skippedPaths: collector.skippedPaths,
                permissionFailures: collector.permissionFailures
            ))
        }

        do {
            let values = try standardized.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { return nil }
        } catch {
            collector.skipped(standardized, reason: "无法读取目录属性，可能需要文件访问权限", kind: .inaccessible)
            return nil
        }

        // cargo target 拆分时会用一次 du 批量测量所有子目录，避免硬链接被重复计算。
        let measured = measurement ?? StorageMeasurementService.measure(standardized)
        guard measured.allocatedBytes >= minimumItemSize else { return nil }
        return CacheItem(
            category: category,
            name: name,
            path: standardized,
            size: measured.allocatedBytes,
            sizeWarning: measured.warning,
            details: details ?? standardized.devSweepDisplayPath,
            risk: risk,
            kind: kind,
            identifier: identifier,
            toolAction: toolAction,
            note: note,
            statusTitle: statusTitle,
            isSelected: isSelected ?? defaultSelection(for: standardized, risk: risk, kind: kind)
        )
    }

    private static func defaultSelection(
        for url: URL,
        risk: RiskLevel,
        kind: CleanupKind
    ) -> Bool {
        guard risk == .safe, kind == .trash else { return false }
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
              let modified = values.contentModificationDate
        else {
            return true
        }
        return Date().timeIntervalSince(modified) > 7 * 24 * 60 * 60
    }

    private static func childDirectories(
        at parent: URL,
        collector: inout ScanCollector,
        progress: @escaping (ScanProgress) -> Void
    ) -> [URL] {
        guard fileManager.fileExists(atPath: parent.path) else { return [] }
        collector.checked(parent)
        do {
            let children = try fileManager.contentsOfDirectory(
                at: parent,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: []
            )
            progress(ScanProgress(
                phase: "发现动态缓存目录",
                currentPath: parent.devSweepDisplayPath,
                checkedPaths: collector.checkedPaths,
                matchedPaths: 0,
                skippedPaths: collector.skippedPaths,
                permissionFailures: collector.permissionFailures
            ))
            return children.compactMap { child in
                guard let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                      values.isDirectory == true,
                      values.isSymbolicLink != true else { return nil }
                return child
            }
        } catch {
            collector.skipped(parent, reason: "目录不可读，可能需要在系统设置中授予文件访问权限", kind: .inaccessible)
            return []
        }
    }

    private static func normalizedRoots(_ roots: [URL]) -> [URL] {
        let protectedPaths = DeletionValidator.defaultProtectedPaths()
        let existing = roots
            .map { $0.standardizedFileURL.resolvingSymlinksInPath() }
            .filter { root in
                fileManager.fileExists(atPath: root.path)
                    && !protectedPaths.contains { protected in
                        protected.standardizedFileURL.path == root.path
                    }
            }
            .sorted { $0.path.count < $1.path.count }

        var result: [URL] = []
        for root in existing {
            let isNested = result.contains { parent in
                root.path == parent.path || root.path.hasPrefix(parent.path + "/")
            }
            if !isNested { result.append(root) }
        }
        return result
    }

    private static func expandedPath(_ value: String, home: URL) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let expanded = NSString(string: trimmed).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded).standardizedFileURL
        }
        return home.appendingPathComponent(expanded).standardizedFileURL
    }

    private static func configuredValue(named key: String, in contents: String) -> String? {
        for line in contents.split(whereSeparator: \.isNewline) {
            let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.hasPrefix("#") else { continue }
            let parts = text.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard parts.count == 2, parts[0] == key else { continue }
            return parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        return nil
    }

    private static func displayRuntime(_ runtime: String) -> String {
        runtime.replacingOccurrences(of: "com.apple.CoreSimulator.SimRuntime.", with: "")
    }

    fileprivate static func run(executable: String, arguments: [String]) -> ProcessOutput? {
        ProcessRunner.run(
            executable: URL(fileURLWithPath: executable),
            arguments: arguments,
            timeout: 30
        )
    }
}

protocol TrashExecuting {
    func trash(_ url: URL) throws
    /// 清空目录内容、保留目录本身。返回成功移入废纸篓的子项数量。
    /// 默认实现基于 `trash(_:)`，测试替身只需实现 `trash(_:)` 即可。
    func trashContents(keepingDirectory url: URL) throws -> Int
}

extension TrashExecuting {
    /// 清空目录内容、保留目录本身。
    ///
    /// 子项**包含符号链接本身**（`trashItem` 移走的是链接，不会跟随到目标），
    /// 因此不会因为 `~/Library/Caches` 里有个指向别处的链接就删到链接目标。
    /// 唯一需要注意的是 `contentsOfDirectory` 不递归，子目录整体移入废纸篓，
    /// 这正是「清空」的语义。
    func trashContents(keepingDirectory url: URL) throws -> Int {
        let fileManager = FileManager.default
        let children = try fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey],
            options: []
        )
        var trashed = 0
        for child in children {
            try trash(child)
            trashed += 1
        }
        return trashed
    }
}

/// cargo 构建期间拒绝清理 target 产物的原因。
enum CargoCleanupError: LocalizedError, Equatable {
    case buildInProgress

    var errorDescription: String? {
        switch self {
        case .buildInProgress:
            return "检测到 cargo 正在构建这个 target，为避免破坏构建已跳过。请等构建结束后重新扫描再清理。"
        }
    }
}

struct FileManagerTrashExecutor: TrashExecuting {
    func trash(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }
}

struct CacheCleaner {
    static func clean(
        _ items: [CacheItem],
        context: DeletionContext,
        toolExecutor: ToolCommandExecuting = ToolCleanupExecutor(),
        requestLogCleaner: RequestLogCleaner = RequestLogCleaner(),
        xctestActivityInspector: XCTestActivityInspecting = XCTestActivityInspector(),
        trashExecutor: TrashExecuting = FileManagerTrashExecutor(),
        simulatorExecutor: SimulatorCleanupExecuting = SimulatorCleanupExecutor(),
        simulatorRuntimeExecutor: SimulatorRuntimeDeleting = SimulatorRuntimeDeletingExecutor(),
        timeMachineExecutor: TimeMachineSnapshotDeleting = TimeMachineSnapshotDeletingExecutor()
    ) -> CleanupReport {
        var removed: [CacheItem] = []
        var failures: [(CacheItem, String)] = []

        // TOCTOU 防护：扫描结果可能早已过期（扫描时空闲、点击清理时测试已启动），
        // 实际删除前必须重新确认 XCTest 状态。同一次批量清理只检查一次：
        // running / unknown 时所有 XCTestDevices 项目都被拒绝，非 XCTest 缓存
        // 照常继续处理，不让整批任务因此取消。
        let hasXCTestTargets = items.contains {
            XCTestDeviceLocator.isXCTestDevicesPath($0.path, home: context.home)
        }
        let xctestVerdict: XCTestActivityState? = hasXCTestTargets
            ? xctestActivityInspector.currentState()
            : nil

        // cargo 构建的 TOCTOU 二次确认：扫描时空闲、点击清理时可能已经开跑。
        // 删除 deps/incremental 会让正在构建的 cargo 读到半截产物甚至失败，
        // 所以只要这一批里包含 cargo artifact，就在删除前重新检查一次锁文件。
        let cargoProfileLocks = items.flatMap { item -> [URL] in
            CacheScanner.cargoLockPaths(forArtifact: item.path)
        }
        let cargoIsBuilding = cargoProfileLocks.contains { CacheScanner.cargoLockIsHeld($0) == true }

        for item in items {
            do {
                if XCTestDeviceLocator.isXCTestDevicesPath(item.path, home: context.home) {
                    switch xctestVerdict ?? .unknown {
                    case .idle:
                        break
                    case .running:
                        throw XCTestCleanupError.testsRunning
                    case .unknown:
                        throw XCTestCleanupError.activityStateUnavailable
                    }
                }
                if cargoIsBuilding, CacheScanner.cargoProfileLockPath(forArtifact: item.path) != nil {
                    throw CargoCleanupError.buildInProgress
                }
                switch item.kind {
                case .trash:
                    try DeletionValidator.validate(item: item, context: context)
                    try trashExecutor.trash(item.path)
                case .trashContents:
                    // 校验的是「目录本身」：必须是同一身份的真实目录、不在白名单/
                    // 保护路径里。随后逐个把子项移入废纸篓，目录保留。
                    try DeletionValidator.validate(item: item, context: context)
                    guard let identity = item.expectedFileIdentity,
                          identity.kind == .directory else {
                        throw DeletionValidationError.unsupportedTarget
                    }
                    _ = try trashExecutor.trashContents(keepingDirectory: item.path)
                case .simulatorDevice:
                    try simulatorExecutor.delete(item, context: context)
                case .simulatorRuntime:
                    try simulatorRuntimeExecutor.delete(item, context: context)
                case .timeMachineSnapshot:
                    try timeMachineExecutor.delete(item, context: context)
                case .dockerPrune:
                    guard let rawTarget = item.identifier,
                          let target = DockerCleanupTarget(rawValue: rawTarget) else {
                        throw NSError(domain: "DevSweep", code: 2, userInfo: [NSLocalizedDescriptionKey: "缺少 Docker 清理目标"])
                    }
                    try runDockerPrune(target)
                case .toolCommand:
                    guard let action = item.toolAction else {
                        throw ToolCleanupError.commandFailed("缺少官方工具清理动作")
                    }
                    try DeletionValidator.validate(item: item, context: context)
                    try toolExecutor.execute(action: action, cacheRoot: item.path)
                case .requestLogTrim:
                    guard let rawTarget = item.identifier,
                          let target = RequestLogTarget(rawValue: rawTarget) else {
                        throw RequestLogCleanError.missingTarget
                    }
                    guard !PathWhitelist.contains(item.path, in: context.whitelistedPaths) else {
                        throw DeletionValidationError.whitelisted
                    }
                    // 清理范围只由 context.home 推导，item.path 不参与定位，避免把删除重定向到别处。
                    _ = try requestLogCleaner.trim(
                        target: target,
                        store: RequestLogStore.standard(home: context.home)
                    )
                }
                removed.append(item)
            } catch {
                failures.append((item, error.localizedDescription))
            }
        }
        return CleanupReport(removed: removed, failures: failures)
    }

    static func clean(_ items: [CacheItem]) -> CleanupReport {
        let context = DeletionContext(
            whitelistedPaths: [],
            projectRoots: [],
            allowedPaths: items.map(\.path)
        )
        return clean(items, context: context)
    }

    private static func runDockerPrune(_ target: DockerCleanupTarget) throws {
        guard let output = DockerSupport.run(arguments: target.arguments) else {
            throw NSError(domain: "DevSweep", code: 3, userInfo: [NSLocalizedDescriptionKey: "Docker CLI 不可用"])
        }
        if output.timedOut {
            throw NSError(domain: "DevSweep", code: 4, userInfo: [NSLocalizedDescriptionKey: "Docker 清理命令超时"])
        }
        guard output.status == 0 else {
            let message = String(data: output.stderr, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(domain: "DevSweep", code: Int(output.status), userInfo: [
                NSLocalizedDescriptionKey: message?.isEmpty == false ? message! : "Docker 清理命令失败"
            ])
        }
    }
}

/// 一次常用清理刷新的生命周期。generation 防止旧结果覆盖新结果，
/// cancelled 让旧任务在测量/遍历之间主动退出，而不是继续做重复 I/O。
final class QuickCleanRefreshContext: @unchecked Sendable {
    let generation: Int
    let totalCount: Int
    private let lock = NSLock()
    private var cancelled = false
    private var completedCount = 0
    private var phase = "准备刷新"
    private var finished = false

    init(generation: Int, totalCount: Int) {
        self.generation = generation
        self.totalCount = totalCount
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    var progress: (phase: String, completed: Int, total: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (phase, completedCount, totalCount)
    }

    func advance(_ count: Int = 1) {
        guard count > 0 else { return }
        lock.lock()
        completedCount = min(totalCount, completedCount + count)
        lock.unlock()
    }

    func setPhase(_ value: String) {
        lock.lock()
        phase = value
        lock.unlock()
    }

    func finish() {
        lock.lock()
        finished = true
        lock.unlock()
    }

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }
}

@MainActor
final class DevSweepStore: ObservableObject {
    private static let projectRootsKey = "DevSweep.projectRoots"
    private static let selectionStatesKey = "DevSweep.selectionStates"
    private static let whitelistedPathsKey = "DevSweep.whitelistedPaths"
    private static let quickCleanEntriesKey = "DevSweep.quickCleanEntries"
    private static let quickCleanSortKey = "DevSweep.quickCleanSort"

    @Published private(set) var items: [CacheItem] = [] {
        didSet { itemsGeneration &+= 1 }
    }
    @Published private(set) var isScanning = false
    @Published private(set) var isCleaning = false
    @Published private(set) var statusMessage = "准备扫描"
    @Published private(set) var lastError: String?
    @Published private(set) var lastReport: ScanReport?
    /// 普通清理成功后的递增标记；发现页据此重新测量受影响的目录。
    @Published private(set) var cleanupGeneration = 0
    @Published private(set) var scanProgress = ScanProgress()
    @Published private(set) var quickCleanEntries: [QuickCleanEntry] = []
    @Published private(set) var quickCleanRows: [QuickCleanRow] = []
    @Published private(set) var isRefreshingQuickClean = false
    @Published private(set) var quickCleanSort: QuickCleanSort
    @Published private(set) var transientNotice: TransientNotice?
    @Published var projectRoots: [URL]
    @Published private(set) var whitelistedPaths: [URL]
    @Published var deepScan = true
    private var selectionStates: [String: Bool]
    /// Scanner 本次发现的完整候选条目；白名单等用户规则在 rebuildItems() 中套用。
    private var rawScanItems: [CacheItem] = []
    /// 从磁盘发现页显式加入清理的条目；主扫描未覆盖的路径也要保留到本次清理完成。
    private var discoveryCleanupItems: [CacheItem] = []
    private let defaults: UserDefaults
    private let home: URL
    private let simulatorInspector: SimulatorCleanupInspecting
    private let simulatorExecutor: SimulatorCleanupExecuting
    private var transientNoticeTask: Task<Void, Never>?
    private var quickCleanRefreshGeneration = 0
    private var quickCleanRefreshContext: QuickCleanRefreshContext?
    /// 刷新进行中收到的请求合并成一次，等当前任务退出后再启动，
    /// 避免多次强制刷新同时遍历同一批目录。
    private var quickCleanRefreshQueued = false
    /// 最近一次量到的磁盘状态；刷新时逐条覆盖，页面因此不会退回「检查中…」。
    private var quickCleanSnapshotByID: [String: QuickCleanSnapshot] = [:]
    private var lastQuickCleanRefresh: Date?
    /// 扫描进行中由常用清理删掉的路径。扫描在自己的遍历里不认识这次删除，
    /// 结果套用时需要把这些还带着旧状态的条目剔除。
    private var pathsCleanedDuringScan: Set<String> = []

    /// 页面进入时的刷新节流：上百个条目重新量一次要遍历真实目录树，
    /// 反复切换侧边栏不应该每次都付这个代价。
    static let quickCleanRefreshInterval: TimeInterval = 15

    init(
        defaults: UserDefaults = .standard,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        simulatorInspector: SimulatorCleanupInspecting = SimulatorCleanupExecutor(),
        simulatorExecutor: SimulatorCleanupExecuting = SimulatorCleanupExecutor()
    ) {
        self.defaults = defaults
        self.home = home
        self.simulatorInspector = simulatorInspector
        self.simulatorExecutor = simulatorExecutor
        if let saved = defaults.array(forKey: Self.projectRootsKey) as? [String] {
            let configuredRoots = Self.normalizeProjectRoots(saved.map { URL(fileURLWithPath: $0) })
            projectRoots = saved.isEmpty
                ? []
                : (configuredRoots.isEmpty ? Self.defaultProjectRoots(home: home) : configuredRoots)
        } else {
            projectRoots = Self.defaultProjectRoots(home: home)
        }
        let savedWhitelist = defaults.array(forKey: Self.whitelistedPathsKey) as? [String] ?? []
        whitelistedPaths = PathWhitelist.normalized(savedWhitelist.map { URL(fileURLWithPath: $0) })
        if let data = defaults.data(forKey: Self.selectionStatesKey),
           let savedStates = try? JSONDecoder().decode([String: Bool].self, from: data) {
            selectionStates = savedStates
        } else {
            selectionStates = [:]
        }
        if let data = defaults.data(forKey: Self.quickCleanEntriesKey),
           let savedEntries = try? JSONDecoder().decode([QuickCleanEntry].self, from: data) {
            quickCleanEntries = QuickCleanRegistry.normalized(savedEntries)
        }
        if let saved = defaults.string(forKey: Self.quickCleanSortKey),
           let sort = QuickCleanSort(rawValue: saved) {
            quickCleanSort = sort
        } else {
            quickCleanSort = .size
        }
        rebuildQuickCleanRows()
    }

    var categories: [String] {
        let order = [
            "Xcode", "CoreSimulator", "XCTest", "Rust / Tauri 项目", "项目生成物", "Node.js 项目",
            "Apple 项目", "Swift 项目", "Flutter 项目", "Python 项目", "PHP 项目", ".NET 项目",
            "Android 项目", "测试产物", "测试工具", "包管理器", "语言工具链", "Ruby", "前端工具链",
            "CI/CD", "云与基础设施", "Docker", "AI/ML", "AI Agent", "JVM", "IDE", "数据库工具",
            "API / 调试工具", "开发工具", "Android Studio", "设计工具", "浏览器缓存", "应用缓存",
            "项目日志", "Time Machine 快照", "其他开发缓存"
        ]
        let present = Set(items.map(\.category))
        return order.filter(present.contains) + present.subtracting(order).sorted()
    }

    var totalSize: Int64 { categoryIndex.totalBytes }

    /// 分类汇总索引：侧栏每个分类都要问一次「多大、几项」，
    /// 之前每次都是一趟全量 filter+reduce（分类数 × 条目数），侧栏因此常年偏慢。
    /// 现在按 `items` 的代数缓存，条目变了才重建。
    private var categoryIndex: CategoryIndex {
        if let cachedCategoryIndex, cachedCategoryIndexGeneration == itemsGeneration {
            return cachedCategoryIndex
        }
        let index = CategoryIndex(items: items)
        cachedCategoryIndex = index
        cachedCategoryIndexGeneration = itemsGeneration
        return index
    }

    private var cachedCategoryIndex: CategoryIndex?
    private var cachedCategoryIndexGeneration: Int = -1
    /// `items` 每次整体替换时递增；用于让派生缓存失效，避免比较整个数组。
    private var itemsGeneration: Int = 0

    struct CategoryIndex {
        let totalBytes: Int64
        let bytesByCategory: [String: Int64]
        let countByCategory: [String: Int]

        init(items: [CacheItem]) {
            var bytes: [String: Int64] = [:]
            var counts: [String: Int] = [:]
            var total: Int64 = 0
            bytes.reserveCapacity(16)
            counts.reserveCapacity(16)
            for item in items {
                bytes[item.category, default: 0] += item.size
                counts[item.category, default: 0] += 1
                total += item.size
            }
            self.totalBytes = total
            self.bytesByCategory = bytes
            self.countByCategory = counts
        }
    }

    func categorySize(_ category: String?) -> Int64 {
        guard let category else { return totalSize }
        return categoryIndex.bytesByCategory[category] ?? 0
    }

    func categoryCount(_ category: String) -> Int {
        categoryIndex.countByCategory[category] ?? 0
    }

    /// 全 App 唯一的清理候选计算入口；过滤器和 Mini 模式都不再各自计算清理范围。
    var selectedCleanupItems: [CacheItem] {
        CleanupSelection.selectedItems(from: items)
    }

    /// 常用清理中当前真实存在、可一键清理的条目。
    var cleanableQuickCleanSnapshots: [QuickCleanSnapshot] {
        quickCleanSnapshotByID.values.filter { $0.entry.isAutomatic && $0.canClean }
    }

    var quickCleanSizeSummary: CapacitySummary {
        var knownBytes: Int64 = 0
        var completeCount = 0
        var partialCount = 0
        var unmeasuredCount = 0
        let snapshots = cleanableQuickCleanSnapshots
        for snapshot in snapshots {
            knownBytes += snapshot.size
            switch snapshot.measurement.state {
            case .complete: completeCount += 1
            case .partial, .timedOut: partialCount += 1
            case .failed: unmeasuredCount += 1
            }
        }
        return CapacitySummary(
            knownBytes: knownBytes,
            totalCount: snapshots.count,
            completeCount: completeCount,
            partialCount: partialCount,
            unmeasuredCount: unmeasuredCount
        )
    }

    var quickCleanSize: Int64 { quickCleanSizeSummary.knownBytes }
    var quickCleanIncompleteSizeCount: Int {
        let summary = quickCleanSizeSummary
        return summary.partialCount + summary.unmeasuredCount
    }
    var quickCleanSizeIsLowerBound: Bool { quickCleanSizeSummary.state != .complete }

    func setQuickCleanSort(_ sort: QuickCleanSort) {
        guard sort != quickCleanSort else { return }
        quickCleanSort = sort
        defaults.set(sort.rawValue, forKey: Self.quickCleanSortKey)
        rebuildQuickCleanRows()
    }

    /// 条目顺序完全由排序方式决定，不再依赖 QuickCleanRegistry 的路径长度顺序。
    /// 没量过的行排在最后，避免刷新途中整列表反复跳动。
    private func rebuildQuickCleanRows() {
        let snapshotByID = quickCleanSnapshotByID
        let rows = quickCleanEntries.map {
            QuickCleanRow(entry: $0, snapshot: snapshotByID[$0.id])
        }
        switch quickCleanSort {
        case .dateAdded:
            quickCleanRows = rows.sorted {
                if $0.entry.dateAdded != $1.entry.dateAdded { return $0.entry.dateAdded > $1.entry.dateAdded }
                return $0.id < $1.id
            }
        case .size:
            quickCleanRows = rows.sorted {
                let lhs = $0.snapshot?.size ?? -1
                let rhs = $1.snapshot?.size ?? -1
                if lhs != rhs { return lhs > rhs }
                if $0.entry.dateAdded != $1.entry.dateAdded { return $0.entry.dateAdded > $1.entry.dateAdded }
                return $0.id < $1.id
            }
        }
    }

    private func mergeQuickCleanSnapshots(_ snapshots: [QuickCleanSnapshot]) {
        guard !snapshots.isEmpty else { return }
        for snapshot in snapshots {
            quickCleanSnapshotByID[snapshot.id] = snapshot
        }
        rebuildQuickCleanRows()
    }

    /// 条目集合变化是唯一需要清理陈旧快照的地方：路径重新绑定后旧 id 不会再出现。
    private func replaceQuickCleanEntries(_ entries: [QuickCleanEntry], persist: Bool) {
        quickCleanEntries = entries
        let valid = Set(entries.map(\.id))
        quickCleanSnapshotByID = quickCleanSnapshotByID.filter { valid.contains($0.key) }
        if persist { persistQuickCleanEntries() }
        rebuildQuickCleanRows()
    }

    func scan() {
        guard !isScanning, !isCleaning else { return }
        isScanning = true
        lastError = nil
        pathsCleanedDuringScan = []
        // 重新扫描期间保留上一次的结果，避免界面闪空；新报告完成后一次性替换。
        scanProgress = ScanProgress(phase: "准备扫描")
        statusMessage = rawScanItems.isEmpty ? "正在扫描开发者缓存…" : "重新扫描中…"
        let roots = projectRoots
        let deepScan = self.deepScan

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let report = CacheScanner.scan(
                projectRoots: roots,
                deepScan: deepScan
            ) { progress in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.scanProgress = progress
                    self.statusMessage = "\(progress.phase) · 已检查 \(progress.checkedPaths) 个路径，命中 \(progress.matchedPaths) 项"
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.applyScanResult(report)
                self.isScanning = false
                self.statusMessage = "已扫描 \(report.items.count) 项，已自动选择安全项目，耗时 \(String(format: "%.1f", report.duration)) 秒"
            }
        }
    }

    /// 安装一次新的扫描结果并按用户规则重建列表；也是测试注入原始结果的入口。
    func applyScanResult(_ report: ScanReport) {
        let cleanedDuringScan = pathsCleanedDuringScan
        pathsCleanedDuringScan = []
        rawScanItems = report.items.filter {
            !cleanedDuringScan.contains(QuickCleanRegistry.key(for: $0.path))
        }
        lastReport = report
        rebuildItems()
        scanProgress = ScanProgress(
            phase: "扫描完成",
            checkedPaths: report.checkedPaths,
            matchedPaths: report.items.count,
            skippedPaths: report.skippedPaths,
            permissionFailures: report.permissionFailures
        )
        if !quickCleanEntries.isEmpty {
            refreshQuickCleanSnapshots(force: true)
        }
    }

    /// rawScanItems → 去掉白名单 → 恢复 selection memory → items。
    /// 加入/移出白名单都只调用这里，立即生效，不需要重新扫描。
    private func rebuildItems() {
        let whitelist = whitelistedPaths
        var seenPaths = Set<String>()
        let mergedItems = (rawScanItems + discoveryCleanupItems).filter { item in
            seenPaths.insert(SelectionMemory.key(for: item.path)).inserted
        }
        let visibleItems = mergedItems.filter { !PathWhitelist.contains($0.path, in: whitelist) }
        items = SelectionMemory.restore(visibleItems, from: selectionStates)
    }

    func isQuickClean(_ item: CacheItem) -> Bool {
        QuickCleanRegistry.contains(item.path, in: quickCleanEntries)
    }

    func setSelected(_ id: UUID, selected: Bool) {
        setSelected(ids: [id], selected: selected)
    }

    /// 批量设置勾选状态。勾选只覆盖可批量处理的项目；取消勾选对所有非手动项生效。
    /// 传入的 ids 由调用方决定（通常是「当前显示」的条目），过滤不影响这里的语义。
    func setSelected(ids: Set<UUID>, selected: Bool) {
        var didChange = false
        for index in items.indices where ids.contains(items[index].id) {
            let item = items[index]
            let isAllowed = selected ? CleanupSelection.isBatchSelectable(item) : item.risk != .manual
            guard isAllowed, item.isSelected != selected else { continue }
            items[index].isSelected = selected
            selectionStates[SelectionMemory.key(for: items[index].path)] = selected
            didChange = true
        }
        if didChange { persistSelectionStates() }
    }

    /// 「全选/取消当前显示」：只作用于传入的可见条目，其余条目保持不变。
    func setVisibleSelected(_ visibleItems: [CacheItem], selected: Bool) {
        let ids = Set(visibleItems
            .filter { selected ? CleanupSelection.isBatchSelectable($0) : $0.risk != .manual }
            .map(\.id))
        setSelected(ids: ids, selected: selected)
    }

    func chooseProjectRoots() {
        let panel = NSOpenPanel()
        panel.title = "选择项目扫描目录"
        panel.message = "可多选目录。DevSweep 只会查找 target、node_modules、.build 等生成物，不会读取源码内容。"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            Task { @MainActor in
                self?.addProjectRoots(panel.urls)
            }
        }
    }

    func removeProjectRoot(_ root: URL) {
        projectRoots.removeAll { $0.standardizedFileURL.path == root.standardizedFileURL.path }
        persistProjectRoots()
    }

    func restoreDefaultProjectRoots() {
        projectRoots = Self.defaultProjectRoots(home: FileManager.default.homeDirectoryForCurrentUser)
        persistProjectRoots()
    }

    func addProjectRoots(_ roots: [URL]) {
        projectRoots = Self.normalizeProjectRoots(projectRoots + roots)
        persistProjectRoots()
    }

    /// 加入白名单后条目立即从当前扫描结果消失，同时清除它的勾选状态，
    /// 不需要等下一次扫描。白名单保护优先于清理授权：同一路径不能既在
    /// 常用清理又被白名单，冲突的常用清理条目会被自动移除。
    func addToWhitelist(_ items: [CacheItem]) {
        guard !items.isEmpty, !isScanning, !isCleaning else { return }
        let updated = PathWhitelist.normalized(whitelistedPaths + items.map(\.path))
        guard updated != whitelistedPaths else { return }
        whitelistedPaths = updated
        persistWhitelist()

        // 白名单意味着之前对这些路径的选择意图作废，包括子路径。
        for item in items {
            let key = SelectionMemory.key(for: item.path)
            selectionStates = selectionStates.filter { stateKey, _ in
                stateKey != key && !stateKey.hasPrefix(key + "/")
            }
        }
        persistSelectionStates()

        // 冲突的常用清理授权一并移除（含父子路径）。
        let conflictKeys = Set(items.map { QuickCleanRegistry.key(for: $0.path) })
        let hadConflicts = quickCleanEntries.contains { entry in
            conflictKeys.contains { conflict in
                entry.id == conflict || conflict.hasPrefix(entry.id + "/") || entry.id.hasPrefix(conflict + "/")
            }
        }
        if hadConflicts {
            replaceQuickCleanEntries(QuickCleanRegistry.normalized(quickCleanEntries.filter { entry in
                !conflictKeys.contains { conflict in
                    entry.id == conflict || conflict.hasPrefix(entry.id + "/") || entry.id.hasPrefix(conflict + "/")
                }
            }), persist: true)
            refreshQuickCleanSnapshots(force: true)
        }

        rebuildItems()
        showTransientNotice(items.count == 1 ? "已加入白名单" : "已加入白名单 \(items.count) 项")
    }

    /// 移出白名单是瞬时操作：如果目录在最近一次 rawScanItems 里存在就立即恢复；
    /// 磁盘已经变化的部分由用户下次重新扫描发现。
    func removeFromWhitelist(_ path: URL) {
        guard !isScanning, !isCleaning else { return }
        let standardizedPath = path.standardizedFileURL.path
        let updated = whitelistedPaths.filter { $0.standardizedFileURL.path != standardizedPath }
        guard updated.count != whitelistedPaths.count else { return }
        whitelistedPaths = updated
        persistWhitelist()
        rebuildItems()
        showTransientNotice("已移出白名单")
    }

    /// 收藏与清理授权分开：模拟器需逐次确认，系统缓存仅供手动查看。
    @discardableResult
    func addToQuickClean(_ items: [CacheItem]) -> (added: Int, rejected: Int) {
        guard !items.isEmpty, !isScanning, !isCleaning else { return (0, items.count) }
        let whitelist = whitelistedPaths
        var newEntries: [QuickCleanEntry] = []
        var rejected = 0
        for item in items {
            guard let kind = QuickCleanInspector.registrationKind(for: item, home: home),
                  let identity = FileIdentity.capture(item.path),
                  item.expectedFileIdentity == identity,
                  !PathWhitelist.contains(item.path, in: whitelist),
                  !whitelist.contains(where: { XCTestDeviceLocator.isInside($0, of: item.path) }),
                  !QuickCleanRegistry.contains(item.path, in: quickCleanEntries)
            else {
                rejected += 1
                continue
            }
            if kind == .directory || kind == .updateArchive || kind == .cargoBuildFile {
                guard !QuickCleanInspector.isReservedPath(item.path, home: home),
                      (try? DeletionValidator.validateQuickCleanRegistration(
                        path: item.path, allowRegularFile: kind == .updateArchive || kind == .cargoBuildFile
                      )) != nil else {
                    rejected += 1
                    continue
                }
            } else {
                guard identity.kind == .directory,
                      item.path.resolvingSymlinksInPath().path == item.path.standardizedFileURL.path else {
                    rejected += 1
                    continue
                }
            }
            newEntries.append(QuickCleanEntry(
                path: QuickCleanRegistry.key(for: item.path),
                displayName: item.name,
                category: item.category,
                dateAdded: Date(),
                targetKind: kind,
                identifier: kind == .simulatorDevice ? item.identifier : nil
            ))
        }
        guard !newEntries.isEmpty else {
            showTransientNotice("没有可加入常用清理的项目", icon: "exclamationmark.circle.fill")
            return (0, rejected)
        }
        replaceQuickCleanEntries(
            QuickCleanRegistry.normalized(quickCleanEntries + newEntries), persist: true
        )
        refreshQuickCleanSnapshots(force: true)

        let added = newEntries.count
        if rejected > 0 {
            showTransientNotice("已加入常用清理 \(added) 项，\(rejected) 项不支持")
        } else {
            showTransientNotice(added == 1 ? "已加入常用清理" : "已加入常用清理 \(added) 项")
        }
        return (added, rejected)
    }

    /// 从磁盘发现页把明确识别的缓存/生成物加入本次清理。
    /// 只改变当前选择集合，不执行删除；清理时仍由 DeletionValidator 重新验证路径、
    /// 白名单、FileIdentity 和进程/构建状态。
    @discardableResult
    func addDiscoveryCleanupCandidate(_ node: DiscoveryNode) -> Bool {
        guard !isScanning, !isCleaning else {
            showTransientNotice("扫描或清理进行中，请稍后再加入", icon: "clock")
            return false
        }
        guard let candidate = node.cleanupCandidate else {
            showTransientNotice("该条目没有明确的清理规则，保持只读", icon: "lock.shield")
            return false
        }

        let key = SelectionMemory.key(for: node.path)
        if let existing = items.first(where: { SelectionMemory.key(for: $0.path) == key }) {
            guard existing.kind == .trash, CleanupSelection.isBatchSelectable(existing) else {
                showTransientNotice("该路径当前不能加入批量清理", icon: "exclamationmark.circle.fill")
                return false
            }
            setSelected(ids: [existing.id], selected: true)
            showTransientNotice("已勾选「\(existing.name)」，确认后再执行清理")
            return true
        }

        let item = CacheItem(
            category: candidate.category,
            name: candidate.name,
            path: node.path,
            size: node.measurement.allocatedBytes,
            sizeWarning: node.measurement.warning,
            details: "来自磁盘发现 · \(node.classification.title) · \(node.evidence.joined(separator: " · "))",
            risk: candidate.risk,
            kind: .trash,
            note: candidate.note,
            isSelected: false
        )
        let validationContext = DeletionContext(
            whitelistedPaths: whitelistedPaths,
            projectRoots: projectRoots,
            home: home,
            allowedPaths: [node.path]
        )
        do {
            try DeletionValidator.validate(item: item, context: validationContext)
        } catch {
            showTransientNotice("无法加入清理：\(error.localizedDescription)", icon: "exclamationmark.circle.fill")
            return false
        }

        discoveryCleanupItems.removeAll { SelectionMemory.key(for: $0.path) == key }
        discoveryCleanupItems.append(item)
        rebuildItems()
        guard let added = items.first(where: { SelectionMemory.key(for: $0.path) == key }) else {
            discoveryCleanupItems.removeAll { SelectionMemory.key(for: $0.path) == key }
            rebuildItems()
            showTransientNotice("该路径已被白名单保护，未加入清理", icon: "checkmark.shield")
            return false
        }
        setSelected(ids: [added.id], selected: true)
        statusMessage = "已从磁盘发现加入「\(added.name)」，确认后再执行清理"
        showTransientNotice("已加入本次清理，需在清理列表确认后才会删除")
        return true
    }

    func removeFromQuickClean(_ entry: QuickCleanEntry) {
        removeFromQuickClean(paths: [URL(fileURLWithPath: entry.path)])
    }

    func removeFromQuickClean(paths: [URL]) {
        guard !paths.isEmpty, !isScanning, !isCleaning else { return }
        let keys = Set(paths.map { QuickCleanRegistry.key(for: $0) })
        replaceQuickCleanEntries(
            quickCleanEntries.filter { !keys.contains($0.id) }, persist: true
        )
        refreshQuickCleanSnapshots(force: true)
        showTransientNotice("已移出常用清理")
    }

    /// 刷新快照：存在性、FileIdentity、大小都重新读取磁盘，绝不调用完整 CacheScanner。
    /// 更新安装包升级后会重新绑定到同目录唯一的新版本文件，并持久化新路径。
    /// 非强制刷新带节流：常用条目上百个，重新遍历一次真实目录树不该成为
    /// 每次切换侧边栏的固定代价。
    func refreshQuickCleanSnapshots(force: Bool = false) {
        guard force || lastQuickCleanRefresh == nil
                || Date().timeIntervalSince(lastQuickCleanRefresh!) > Self.quickCleanRefreshInterval
                || quickCleanRows.isEmpty else { return }

        // 当前刷新还没退出：登记一次请求并取消旧任务。旧任务退出后会启动新的 generation，
        // 因此强制刷新不会叠加出多个并发遍历和多个 du 进程。
        if isRefreshingQuickClean, quickCleanRefreshContext != nil {
            quickCleanRefreshQueued = true
            quickCleanRefreshContext?.cancel()
            return
        }

        startQuickCleanRefresh()
    }

    private func startQuickCleanRefresh() {
        let entries = quickCleanEntries
        let whitelist = whitelistedPaths
        let home = self.home
        let inspector = simulatorInspector
        quickCleanRefreshContext?.cancel()
        quickCleanRefreshGeneration += 1
        let generation = quickCleanRefreshGeneration
        let context = QuickCleanRefreshContext(generation: generation, totalCount: entries.count)
        quickCleanRefreshContext = context
        isRefreshingQuickClean = true
        guard !entries.isEmpty else {
            quickCleanSnapshotByID = [:]
            rebuildQuickCleanRows()
            quickCleanRefreshDidComplete(context)
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard !context.isCancelled else {
                self?.quickCleanRefreshDidComplete(context)
                return
            }
            context.setPhase("正在匹配更新安装包")
            let resolution = QuickCleanInspector.resolveVersionedEntries(
                entries, whitelistedPaths: whitelist
            )
            guard !context.isCancelled else {
                self?.quickCleanRefreshDidComplete(context)
                return
            }
            let rebound = zip(entries, resolution.entries).filter { $0.0.path != $0.1.path }
            // 文件与目录状态先发布；模拟器行需要 simctl（登记几十台设备时是秒级），
            // 排在它后面，不拖慢可清理项。
            context.setPhase("正在核对磁盘占用")
            let snapshots = QuickCleanInspector.snapshots(
                for: resolution.entries, home: home,
                simulatorInspector: inspector, notes: resolution.notes,
                isCancelled: { context.isCancelled },
                onProgress: { partial in
                    context.advance(partial.count)
                    self?.publishQuickCleanSnapshots(partial, context: context)
                }
            )
            guard !context.isCancelled else {
                self?.quickCleanRefreshDidComplete(context)
                return
            }
            self?.publishQuickCleanSnapshots(snapshots, context: context)
            if !rebound.isEmpty {
                self?.applyQuickCleanRebound(
                    resolution.entries, reboundCount: rebound.count, context: context
                )
            }
            self?.quickCleanRefreshDidComplete(context)
        }
    }

    private func quickCleanRefreshDidComplete(_ context: QuickCleanRefreshContext) {
        DispatchQueue.main.async {
            guard context.generation == self.quickCleanRefreshGeneration else { return }
            context.finish()
            if self.quickCleanRefreshContext === context {
                self.quickCleanRefreshContext = nil
            }
            if self.quickCleanRefreshQueued {
                self.quickCleanRefreshQueued = false
                self.startQuickCleanRefresh()
            } else {
                self.lastQuickCleanRefresh = Date()
                self.isRefreshingQuickClean = false
            }
        }
    }

    private func publishQuickCleanSnapshots(
        _ snapshots: [QuickCleanSnapshot], context: QuickCleanRefreshContext
    ) {
        DispatchQueue.main.async {
            guard context.generation == self.quickCleanRefreshGeneration,
                  !context.isCancelled else { return }
            self.mergeQuickCleanSnapshots(snapshots)
        }
    }

    private func applyQuickCleanRebound(
        _ entries: [QuickCleanEntry], reboundCount: Int, context: QuickCleanRefreshContext
    ) {
        DispatchQueue.main.async {
            guard context.generation == self.quickCleanRefreshGeneration,
                  !context.isCancelled else { return }
            self.replaceQuickCleanEntries(QuickCleanRegistry.normalized(entries), persist: true)
            self.rebuildItems()
            self.showTransientNotice(reboundCount == 1
                ? "常用清理已匹配更新安装包的新版本"
                : "常用清理已匹配 \(reboundCount) 个更新安装包的新版本")
        }
    }

    /// 一键清理：用户加入常用清理即代表长期授权，不再弹二次确认。
    /// 目录被清理后 Entry 保留，目录重新生成后仍可继续一键清理。
    func cleanAllQuickClean() {
        cleanQuickCleanEntries(cleanableQuickCleanSnapshots.map(\.entry))
    }

    func cleanQuickClean(_ entries: [QuickCleanEntry]) {
        cleanQuickCleanEntries(entries)
    }

    /// Called only by the per-device confirmation dialog. Identity comes from
    /// the snapshot shown before the dialog, never from a fresh replacement path.
    func deleteQuickCleanSimulator(_ entry: QuickCleanEntry, expectedIdentity: FileIdentity) {
        guard !isCleaning, entry.isSimulator,
              quickCleanEntries.contains(entry),
              SimulatorCleanupExecutor.matches(path: URL(fileURLWithPath: entry.path), udid: entry.identifier, home: home)
        else { return }
        isCleaning = true
        lastError = nil
        statusMessage = "正在核验并删除模拟器设备…"
        let path = URL(fileURLWithPath: entry.path)
        let item = CacheItem(
            category: entry.category, name: entry.displayName, path: path,
            size: quickCleanSnapshotByID[entry.id]?.size ?? 0,
            risk: .review, kind: .simulatorDevice, identifier: entry.identifier,
            expectedFileIdentity: expectedIdentity
        )
        let context = DeletionContext(
            whitelistedPaths: whitelistedPaths, projectRoots: projectRoots, home: home, allowedPaths: [path]
        )
        let executor = simulatorExecutor
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let report = CacheCleaner.clean([item], context: context, simulatorExecutor: executor)
            DispatchQueue.main.async {
                guard let self else { return }
                self.isCleaning = false
                self.applyQuickCleanCleanupResult(report)
                if report.removed.isEmpty { self.refreshQuickCleanSnapshots(force: true) }
                if let failure = report.failures.first {
                    self.lastError = failure.1
                    self.statusMessage = "模拟器未删除：\(failure.1)"
                } else {
                    self.statusMessage = "已删除模拟器设备，不能从废纸篓恢复；收藏保留并标记失效"
                    self.showTransientNotice("已删除模拟器设备")
                }
            }
        }
    }

    private func cleanQuickCleanEntries(_ entries: [QuickCleanEntry]) {
        let targets = QuickCleanRegistry.normalized(entries.filter { $0.isAutomatic && quickCleanEntries.contains($0) })
        // 常用清理自带磁盘核验，不依赖普通扫描的结果，因此普通扫描进行中也可以执行。
        guard !targets.isEmpty, !isCleaning else { return }
        isCleaning = true
        lastError = nil
        statusMessage = "正在把常用项目移入废纸篓…"
        let whitelist = whitelistedPaths
        let roots = projectRoots
        let home = home

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // 执行前重新读取磁盘状态，生成刚刚捕获 FileIdentity 的执行条目；
            // 仍然走 CacheCleaner + DeletionValidator，白名单永远拥有最高优先级。
            let freshItems = QuickCleanInspector.executableItems(for: targets)
            let context = DeletionContext(
                whitelistedPaths: whitelist,
                projectRoots: roots,
                home: home,
                allowedPaths: freshItems.map(\.path)
            )
            let report = CacheCleaner.clean(freshItems, context: context)
            DispatchQueue.main.async {
                guard let self else { return }
                self.isCleaning = false
                self.applyQuickCleanCleanupResult(report)
                if report.failures.isEmpty {
                    let removedSize = report.removed.reduce(0) { $0 + $1.size }
                    let incompleteSize = report.removed.filter { $0.sizeWarning != nil }.count
                    let sizeText = (incompleteSize > 0 ? "≥ " : "") + removedSize.devSweepFileSize
                        + (incompleteSize > 0 ? "（\(incompleteSize) 项未完整测量）" : "")
                    self.statusMessage = report.removed.isEmpty
                        ? "没有需要清理的常用项目"
                        : "已把 \(report.removed.count) 个常用项目移入废纸篓，统计占用 \(sizeText)，文件可恢复"
                    if !report.removed.isEmpty {
                        self.showTransientNotice("已移入废纸篓 \(report.removed.count) 项，统计占用 \(sizeText)")
                    }
                } else {
                    let details = report.failures.map { "\($0.0.name)：\($0.1)" }.joined(separator: "\n")
                    self.lastError = "部分常用项目未能清理：\n\(details)"
                    self.statusMessage = "已处理 \(report.removed.count) 项，\(report.failures.count) 项失败"
                }
            }
        }
    }

    /// Quick Clean 清理成功后的状态更新：Entry 永远不删除；快照重新读取磁盘后
    /// 变成「当前无内容」；rawScanItems 中同路径项目同步消失。
    func applyQuickCleanCleanupResult(_ report: CleanupReport) {
        guard !report.removed.isEmpty else { return }
        let removedPaths = Set(report.removed.map { QuickCleanRegistry.key(for: $0.path) })
        if isScanning {
            pathsCleanedDuringScan.formUnion(removedPaths)
        }
        rawScanItems.removeAll { removedPaths.contains(QuickCleanRegistry.key(for: $0.path)) }
        discoveryCleanupItems.removeAll { removedPaths.contains(QuickCleanRegistry.key(for: $0.path)) }
        cleanupGeneration += 1
        rebuildItems()
        refreshQuickCleanSnapshots(force: true)
    }

    private func showTransientNotice(_ text: String, icon: String = "checkmark.circle.fill") {
        transientNoticeTask?.cancel()
        transientNotice = TransientNotice(text, icon: icon)
        transientNoticeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            self?.transientNotice = nil
        }
    }

    func cleanSelected(ids: Set<UUID>) {
        let selected = items.filter { ids.contains($0.id) && $0.risk != .manual }
        guard !selected.isEmpty, !isCleaning else { return }
        isCleaning = true
        lastError = nil
        let includesDocker = selected.contains { $0.kind == .dockerPrune }
        let includesNonRecoverable = selected.contains { $0.kind.isNonRecoverable }
        let deletionContext = DeletionContext(
            whitelistedPaths: whitelistedPaths,
            projectRoots: projectRoots,
            home: home,
            allowedPaths: items.map(\.path)
        )
        statusMessage = includesNonRecoverable ? "正在执行选中项目的清理…" : "正在把选中项目移入废纸篓…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let toolExecutor = ToolCleanupExecutor()
            let report = CacheCleaner.clean(
                selected,
                context: deletionContext,
                toolExecutor: toolExecutor
            )
            DispatchQueue.main.async {
                guard let self else { return }
                self.isCleaning = false
                // 普通清理：被删除的条目从原始扫描结果中消失；常用清理配置则保留。
                let removedPaths = Set(report.removed.map { SelectionMemory.key(for: $0.path) })
                self.rawScanItems.removeAll { removedPaths.contains(SelectionMemory.key(for: $0.path)) }
                self.discoveryCleanupItems.removeAll { removedPaths.contains(SelectionMemory.key(for: $0.path)) }
                if !report.removed.isEmpty { self.cleanupGeneration += 1 }
                self.rebuildItems()
                for item in report.removed {
                    self.selectionStates.removeValue(forKey: SelectionMemory.key(for: item.path))
                }
                if !report.removed.isEmpty {
                    self.persistSelectionStates()
                    if !self.quickCleanEntries.isEmpty {
                        self.refreshQuickCleanSnapshots(force: true)
                    }
                    let removedSize = report.removed.reduce(0) { $0 + $1.size }
                    self.showTransientNotice("已清理 \(report.removed.count) 项，共 \(removedSize.devSweepFileSize)")
                }
                if report.failures.isEmpty {
                    self.statusMessage = includesNonRecoverable
                        ? "已处理 \(report.removed.count) 项，部分工具资源不可从废纸篓恢复"
                        : "已处理 \(report.removed.count) 项，文件可从废纸篓恢复"
                } else {
                    let details = report.failures.map { "\($0.0.name)：\($0.1)" }.joined(separator: "\n")
                    self.lastError = "部分项目未能清理：\n\(details)"
                    self.statusMessage = includesDocker
                        ? "已处理 \(report.removed.count) 项，\(report.failures.count) 项失败；Docker 或工具资源请查看错误详情"
                        : "已处理 \(report.removed.count) 项，\(report.failures.count) 项失败"
                }
            }
        }
    }

    func clearError() {
        lastError = nil
    }

    private func persistProjectRoots() {
        defaults.set(projectRoots.map(\.path), forKey: Self.projectRootsKey)
    }

    private func persistWhitelist() {
        defaults.set(whitelistedPaths.map(\.path), forKey: Self.whitelistedPathsKey)
    }

    private func persistSelectionStates() {
        guard let data = try? JSONEncoder().encode(selectionStates) else { return }
        defaults.set(data, forKey: Self.selectionStatesKey)
    }

    private func persistQuickCleanEntries() {
        guard let data = try? JSONEncoder().encode(quickCleanEntries) else { return }
        defaults.set(data, forKey: Self.quickCleanEntriesKey)
    }

    private static func defaultProjectRoots(home: URL) -> [URL] {
        let candidates = [
            "Code", "Projects", "Developer", "Development", "Work", "src", "workspace", "Repos",
            "Repositories", "dev", "software", "www", "GitHub"
        ]
            .map { home.appendingPathComponent($0) }
            + [
                home.appendingPathComponent(".codex/worktrees"),
                home.appendingPathComponent(".claude/worktrees")
            ]
        return normalizeProjectRoots(candidates)
    }

    private static func normalizeProjectRoots(_ roots: [URL]) -> [URL] {
        let protectedPaths = DeletionValidator.defaultProtectedPaths()
        let existing = roots
            .map { $0.standardizedFileURL.resolvingSymlinksInPath() }
            .filter { root in
                FileManager.default.fileExists(atPath: root.path)
                    && !protectedPaths.contains { protected in
                        protected.standardizedFileURL.path == root.path
                    }
            }
            .sorted { $0.path.count < $1.path.count }
        var result: [URL] = []
        for root in existing {
            guard !result.contains(where: { parent in
                root.path == parent.path || root.path.hasPrefix(parent.path + "/")
            }) else { continue }
            result.append(root)
        }
        return result
    }
}
