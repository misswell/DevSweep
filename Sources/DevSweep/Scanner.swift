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

fileprivate struct ProcessOutput {
    let status: Int32
    let stdout: Data
    let stderr: Data
}

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

private struct ScanCollector {
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
        whitelistedPaths: [URL] = [],
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        includeSystemCaches: Bool = true,
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
            phase: "检查模拟器和 XCTest 设备",
            checkedPaths: collector.checkedPaths,
            matchedPaths: items.count,
            skippedPaths: collector.skippedPaths,
            permissionFailures: collector.permissionFailures
        ))
        items += xctestDeviceItems(home: home, collector: &collector, progress: progress)
        items += simulatorItems(home: home, collector: &collector, progress: progress)

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

        let uniqueItems = nonOverlappingItems(
            items.filter { !PathWhitelist.contains($0.path, in: whitelistedPaths) }
        )
        .filter { $0.size >= minimumItemSize }
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
            diagnostics: collector.diagnostics,
            duration: Date().timeIntervalSince(startedAt)
        )
    }

    static func nonOverlappingItems(_ items: [CacheItem]) -> [CacheItem] {
        var kept: [CacheItem] = []
        let candidates = items.enumerated()
            .sorted {
                let leftDepth = $0.element.path.standardizedFileURL.pathComponents.count
                let rightDepth = $1.element.path.standardizedFileURL.pathComponents.count
                if leftDepth == rightDepth {
                    let leftPath = $0.element.path.standardizedFileURL.path
                    let rightPath = $1.element.path.standardizedFileURL.path
                    if leftPath == rightPath { return $0.offset < $1.offset }
                    return leftPath < rightPath
                }
                return leftDepth < rightDepth
            }
            .map(\.element)

        for item in candidates {
            let itemPath = item.path.standardizedFileURL.path
            let isCovered = kept.contains { existing in
                let existingPath = existing.path.standardizedFileURL.path
                return itemPath == existingPath || itemPath.hasPrefix(existingPath + "/")
            }
            if !isCovered {
                kept.append(item)
            }
        }
        return kept
    }

    static func size(of url: URL) -> Int64 {
        guard fileManager.fileExists(atPath: url.path) else { return 0 }

        if let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileAllocatedSizeKey]),
           values.isDirectory != true {
            return Int64(values.fileAllocatedSize ?? 0)
        }

        // du is faster and more complete for large trees than walking every file
        // through FileManager. It also reports allocated disk blocks, which matches
        // what Finder and macOS storage management usually show.
        if let output = run(executable: "/usr/bin/du", arguments: ["-sk", url.path]),
           let firstLine = String(data: output.stdout, encoding: .utf8)?
                .split(whereSeparator: \.isNewline)
                .first,
           let kilobytes = firstLine.split(whereSeparator: { $0 == " " || $0 == "\t" }).first,
           let value = Int64(kilobytes),
           value > 0 {
            return value * 1024
        }

        return enumeratedSize(of: url)
    }

    private static func fixedItems(
        home: URL,
        collector: inout ScanCollector,
        progress: @escaping (ScanProgress) -> Void
    ) -> [CacheItem] {
        let rules: [CacheRule] = [
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
            CacheRule(category: "包管理器", name: "Yarn", relativePath: "Library/Caches/Yarn", risk: .safe, note: "Yarn 会重新下载依赖"),
            CacheRule(category: "包管理器", name: "Yarn（旧缓存）", relativePath: ".cache/yarn", risk: .safe, note: "Yarn 会重新下载依赖"),
            CacheRule(category: "包管理器", name: "Yarn 离线缓存", relativePath: ".yarn/cache", risk: .review, note: "Yarn 会重新下载依赖；离线环境下请保留"),
            CacheRule(category: "包管理器", name: "pnpm store", relativePath: "Library/pnpm/store", risk: .safe, note: "pnpm 会重新下载依赖"),
            CacheRule(category: "包管理器", name: "pnpm 元数据缓存", relativePath: "Library/Caches/pnpm", risk: .safe, note: "pnpm 会重新获取 registry 元数据"),
            CacheRule(category: "包管理器", name: "pnpm store（Linux 兼容路径）", relativePath: ".local/share/pnpm/store", risk: .safe, note: "pnpm 会重新下载依赖"),
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
            CacheRule(category: "包管理器", name: "NuGet 全局包缓存", relativePath: ".nuget/packages", risk: .safe, note: "NuGet 会重新下载包"),
            CacheRule(category: "包管理器", name: "CocoaPods Specs 仓库", relativePath: ".cocoapods/repos", risk: .review, note: "Specs 索引会重新下载；离线环境下请保留"),

            CacheRule(category: "语言工具链", name: "Cargo registry cache", relativePath: ".cargo/registry/cache", risk: .safe, note: "Cargo 会重新下载 crate"),
            CacheRule(category: "语言工具链", name: "Cargo registry index", relativePath: ".cargo/registry/index", risk: .safe, note: "Cargo 会重新获取 registry 索引"),
            CacheRule(category: "语言工具链", name: "Cargo registry source", relativePath: ".cargo/registry/src", risk: .safe, note: "Cargo 会重新下载 crate 源码"),
            CacheRule(category: "语言工具链", name: "Cargo git checkout", relativePath: ".cargo/git/checkouts", risk: .safe, note: "Cargo 会重新检出依赖"),
            CacheRule(category: "语言工具链", name: "Cargo git database", relativePath: ".cargo/git/db", risk: .safe, note: "Cargo 会重新获取依赖"),
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
            CacheRule(category: "语言工具链", name: "Flutter / Dart", relativePath: ".pub-cache", risk: .safe, note: "Pub 会重新下载依赖"),

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
            CacheRule(category: "项目日志", name: "用户日志目录", relativePath: "logs", risk: .review, note: "用户主目录下的日志；确认不再需要排查问题后清理"),

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

        ]

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
            add("包管理器", "pnpm 自定义 store", path, .safe, "来自 PNPM_STORE_PATH，pnpm 会重新下载依赖")
        }
        if let value = environment["DENO_DIR"], let path = expandedPath(value, home: home) {
            add("包管理器", "Deno 自定义缓存", path, .safe, "来自 DENO_DIR，Deno 会重新下载依赖和工具")
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
            add("包管理器", "NuGet 自定义包缓存", path, .safe, "来自 NUGET_PACKAGES，NuGet 会重新下载包")
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
            guard let match = vendorPrefixes.first(where: { child.lastPathComponent.hasPrefix($0.0) }) else { continue }
            add("设计工具", "\(match.1) · \(child.lastPathComponent)", child, .safe, match.2)
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

    private static func softwareUpdateResidueName(for url: URL, isDirectory: Bool) -> String? {
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

        guard DockerSupport.executableURL() != nil else { return items }
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
        add("语言工具链", "Cargo 自定义 registry source", cargoHome.appendingPathComponent("registry/src"), .safe, "来自 CARGO_HOME，Cargo 会重新下载 crate 源码")
        add("语言工具链", "Cargo 自定义 git", cargoHome.appendingPathComponent("git"), .safe, "来自 CARGO_HOME，Cargo 会重新获取依赖")
    }

    private static func xctestDeviceItems(
        home: URL,
        collector: inout ScanCollector,
        progress: @escaping (ScanProgress) -> Void
    ) -> [CacheItem] {
        let root = home.appendingPathComponent("Library/Developer/XCTestDevices")
        guard fileManager.fileExists(atPath: root.path) else { return [] }

        let children = childDirectories(at: root, collector: &collector, progress: progress)
            .filter { UUID(uuidString: $0.lastPathComponent) != nil }

        if children.isEmpty {
            if let item = makeItem(
                category: "XCTest",
                name: "XCTestDevices（全部）",
                path: root,
                risk: .review,
                note: "测试克隆设备；请先停止 XCTest/UI 测试后清理",
                collector: &collector,
                progress: progress
            ) {
                return [item]
            }
            return []
        }

        var items: [CacheItem] = []
        for child in children {
            if let item = makeItem(
                category: "XCTest",
                name: "XCTest 克隆设备 · (child.lastPathComponent)",
                path: child,
                risk: .review,
                note: "请先停止 XCTest/UI 测试；删除后测试会重新创建",
                collector: &collector,
                progress: progress
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
                let measuredSize = size(of: path)
                let size = max(measuredSize, reportedSize)
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
            let measuredSize = size(of: child)
            guard measuredSize >= minimumItemSize else { continue }
            items.append(CacheItem(
                category: "CoreSimulator",
                name: "未登记模拟器目录 · \(udid)",
                path: child,
                size: measuredSize,
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

    private static func projectArtifacts(
        in root: URL,
        deepScan: Bool,
        collector: inout ScanCollector,
        progress: @escaping (ScanProgress) -> Void
    ) -> [CacheItem] {
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
            if !deepScan && depth > 4 {
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

            guard let generatedRule = generatedRule(for: url) else { continue }
            do {
                let values = try url.resourceValues(forKeys: keys)
                guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
            } catch {
                collector.skipped(url, reason: "无法读取目录属性", kind: .inaccessible)
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

    static func generatedRule(for url: URL) -> GeneratedRule? {
        let name = url.lastPathComponent
        let parent = url.deletingLastPathComponent()
        if name == "logs" || name == "log" {
            let projectDirectories = [parent, parent.deletingLastPathComponent()]
            guard projectDirectories.contains(where: hasProjectMarker) else { return nil }
            return GeneratedRule(category: "项目日志", risk: .review, note: "项目运行日志；确认不再需要排查问题后清理")
        }
        if name == "vendor" {
            guard fileManager.fileExists(atPath: parent.appendingPathComponent("composer.json").path) else { return nil }
            return GeneratedRule(category: "PHP 项目", risk: .review, note: "Composer 依赖，删除后 composer install 会重新安装")
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
        return generatedRules[url.lastPathComponent]
    }

    private static func hasProjectMarker(_ directory: URL) -> Bool {
        let markerNames: Set<String> = [
            "pom.xml", "package.json", "Cargo.toml", "Package.swift", "composer.json",
            "build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts",
            "go.mod", "pyproject.toml", "requirements.txt", "conf/application.properties"
        ]
        return directoryContainsNamedFile(directory, names: markerNames)
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
        identifier: String? = nil
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

        let measuredSize = size(of: standardized)
        guard measuredSize >= minimumItemSize else { return nil }
        return CacheItem(
            category: category,
            name: name,
            path: standardized,
            size: measuredSize,
            details: details ?? standardized.devSweepDisplayPath,
            risk: risk,
            kind: kind,
            identifier: identifier,
            note: note,
            isSelected: isSelected
        )
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
        let existing = roots
            .map { $0.standardizedFileURL.resolvingSymlinksInPath() }
            .filter { fileManager.fileExists(atPath: $0.path) }
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

    private static func enumeratedSize(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .fileAllocatedSizeKey,
            .totalFileAllocatedSizeKey
        ]
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: []
        ) else { return 0 }

        var total: Int64 = 0
        for case let child as URL in enumerator {
            guard let values = try? child.resourceValues(forKeys: keys),
                  values.isSymbolicLink != true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }

    fileprivate static func run(executable: String, arguments: [String]) -> ProcessOutput? {
        let task = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = outputPipe
        task.standardError = errorPipe
        do {
            try task.run()
            task.waitUntilExit()
            return ProcessOutput(
                status: task.terminationStatus,
                stdout: outputPipe.fileHandleForReading.readDataToEndOfFile(),
                stderr: errorPipe.fileHandleForReading.readDataToEndOfFile()
            )
        } catch {
            return nil
        }
    }
}

struct CacheCleaner {
    static func clean(_ items: [CacheItem]) -> CleanupReport {
        var removed: [CacheItem] = []
        var failures: [(CacheItem, String)] = []

        for item in items {
            do {
                switch item.kind {
                case .trash:
                    try FileManager.default.trashItem(at: item.path, resultingItemURL: nil)
                case .simulatorDevice:
                    guard let udid = item.identifier else {
                        throw NSError(domain: "DevSweep", code: 1, userInfo: [NSLocalizedDescriptionKey: "缺少模拟器 UDID"])
                    }
                    try runSimctlDelete(udid: udid)
                case .dockerPrune:
                    guard let rawTarget = item.identifier,
                          let target = DockerCleanupTarget(rawValue: rawTarget) else {
                        throw NSError(domain: "DevSweep", code: 2, userInfo: [NSLocalizedDescriptionKey: "缺少 Docker 清理目标"])
                    }
                    try runDockerPrune(target)
                }
                removed.append(item)
            } catch {
                failures.append((item, error.localizedDescription))
            }
        }
        return CleanupReport(removed: removed, failures: failures)
    }

    private static func runSimctlDelete(udid: String) throws {
        let task = Process()
        let errorPipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        task.arguments = ["simctl", "delete", udid]
        task.standardInput = FileHandle.nullDevice
        task.standardError = errorPipe
        try task.run()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(domain: "DevSweep", code: Int(task.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: message?.isEmpty == false ? message! : "simctl 删除失败"
            ])
        }
    }

    private static func runDockerPrune(_ target: DockerCleanupTarget) throws {
        guard let output = DockerSupport.run(arguments: target.arguments) else {
            throw NSError(domain: "DevSweep", code: 3, userInfo: [NSLocalizedDescriptionKey: "Docker CLI 不可用"])
        }
        guard output.status == 0 else {
            let message = String(data: output.stderr, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(domain: "DevSweep", code: Int(output.status), userInfo: [
                NSLocalizedDescriptionKey: message?.isEmpty == false ? message! : "Docker 清理命令失败"
            ])
        }
    }
}

@MainActor
final class DevSweepStore: ObservableObject {
    private static let projectRootsKey = "DevSweep.projectRoots"
    private static let selectionStatesKey = "DevSweep.selectionStates"
    private static let whitelistedPathsKey = "DevSweep.whitelistedPaths"

    @Published private(set) var items: [CacheItem] = []
    @Published private(set) var isScanning = false
    @Published private(set) var isCleaning = false
    @Published private(set) var statusMessage = "准备扫描"
    @Published private(set) var lastError: String?
    @Published private(set) var lastReport: ScanReport?
    @Published private(set) var scanProgress = ScanProgress()
    @Published var projectRoots: [URL]
    @Published private(set) var whitelistedPaths: [URL]
    @Published var deepScan = true
    private var selectionStates: [String: Bool]

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        if let saved = UserDefaults.standard.array(forKey: Self.projectRootsKey) as? [String] {
            let configuredRoots = Self.normalizeProjectRoots(saved.map { URL(fileURLWithPath: $0) })
            projectRoots = saved.isEmpty
                ? []
                : (configuredRoots.isEmpty ? Self.defaultProjectRoots(home: home) : configuredRoots)
        } else {
            projectRoots = Self.defaultProjectRoots(home: home)
        }
        let savedWhitelist = UserDefaults.standard.array(forKey: Self.whitelistedPathsKey) as? [String] ?? []
        whitelistedPaths = PathWhitelist.normalized(savedWhitelist.map { URL(fileURLWithPath: $0) })
        if let data = UserDefaults.standard.data(forKey: Self.selectionStatesKey),
           let savedStates = try? JSONDecoder().decode([String: Bool].self, from: data) {
            selectionStates = savedStates
        } else {
            selectionStates = [:]
        }
    }

    var categories: [String] {
        let order = [
            "Xcode", "CoreSimulator", "XCTest", "Rust / Tauri 项目", "项目生成物", "Node.js 项目",
            "Apple 项目", "Swift 项目", "Flutter 项目", "Python 项目", "PHP 项目", ".NET 项目",
            "Android 项目", "测试产物", "测试工具", "包管理器", "语言工具链", "Ruby", "前端工具链",
            "云与基础设施", "AI/ML", "AI Agent", "Docker", "JVM", "IDE", "Android Studio", "设计工具",
            "浏览器缓存", "应用缓存", "项目日志", "其他开发缓存"
        ]
        let present = Set(items.map(\.category))
        return order.filter(present.contains) + present.subtracting(order).sorted()
    }

    var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }

    func categorySize(_ category: String?) -> Int64 {
        guard let category else { return totalSize }
        return items.filter { $0.category == category }.reduce(0) { $0 + $1.size }
    }

    func scan() {
        guard !isScanning, !isCleaning else { return }
        isScanning = true
        lastError = nil
        lastReport = nil
        scanProgress = ScanProgress(phase: "准备扫描")
        statusMessage = "正在扫描开发者缓存…"
        let roots = projectRoots
        let deepScan = self.deepScan
        let whitelist = whitelistedPaths

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let report = CacheScanner.scan(
                projectRoots: roots,
                deepScan: deepScan,
                whitelistedPaths: whitelist
            ) { progress in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.scanProgress = progress
                    self.statusMessage = "\(progress.phase) · 已检查 \(progress.checkedPaths) 个路径，命中 \(progress.matchedPaths) 项"
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.items = SelectionMemory.restore(report.items, from: self.selectionStates)
                self.lastReport = report
                self.scanProgress = ScanProgress(
                    phase: "扫描完成",
                    checkedPaths: report.checkedPaths,
                    matchedPaths: report.items.count,
                    skippedPaths: report.skippedPaths,
                    permissionFailures: report.permissionFailures
                )
                self.isScanning = false
                self.statusMessage = "已扫描 \(report.items.count) 项，耗时 \(String(format: "%.1f", report.duration)) 秒"
            }
        }
    }

    func setSelected(_ id: UUID, selected: Bool) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        guard items[index].risk != .manual else { return }
        items[index].isSelected = selected
        selectionStates[SelectionMemory.key(for: items[index].path)] = selected
        persistSelectionStates()
    }

    func setAllSelected(_ selected: Bool, category: String? = nil) {
        var didChange = false
        for index in items.indices where category == nil || items[index].category == category {
            if items[index].risk != .manual && (selected == false || items[index].kind != .dockerPrune) {
                if items[index].isSelected != selected {
                    items[index].isSelected = selected
                    selectionStates[SelectionMemory.key(for: items[index].path)] = selected
                    didChange = true
                }
            }
        }
        if didChange { persistSelectionStates() }
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

    func addToWhitelist(_ items: [CacheItem]) {
        guard !items.isEmpty, !isScanning, !isCleaning else { return }
        let updated = PathWhitelist.normalized(whitelistedPaths + items.map(\.path))
        guard updated != whitelistedPaths else { return }
        whitelistedPaths = updated
        persistWhitelist()
        statusMessage = items.count == 1
            ? "已加入白名单"
            : "已加入白名单 \(items.count) 项"
    }

    func removeFromWhitelist(_ path: URL) {
        guard !isScanning, !isCleaning else { return }
        let standardizedPath = path.standardizedFileURL.path
        whitelistedPaths.removeAll { $0.standardizedFileURL.path == standardizedPath }
        persistWhitelist()
        scan()
    }

    func cleanSelected(ids: Set<UUID>) {
        let selected = items.filter { ids.contains($0.id) && $0.risk != .manual }
        guard !selected.isEmpty, !isCleaning else { return }
        isCleaning = true
        lastError = nil
        let includesDocker = selected.contains { $0.kind == .dockerPrune }
        statusMessage = includesDocker ? "正在执行选中项目的清理…" : "正在把选中项目移入废纸篓…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let report = CacheCleaner.clean(selected)
            DispatchQueue.main.async {
                guard let self else { return }
                self.isCleaning = false
                let remainingItems = CleanupSelection.remainingItems(from: self.items, removing: report.removed)
                self.items = remainingItems
                for item in report.removed {
                    self.selectionStates.removeValue(forKey: SelectionMemory.key(for: item.path))
                }
                if !report.removed.isEmpty { self.persistSelectionStates() }
                if report.failures.isEmpty {
                    self.statusMessage = includesDocker
                        ? "已处理 \(report.removed.count) 项，普通目录可从废纸篓恢复，Docker 资源不可恢复"
                        : "已处理 \(report.removed.count) 项，文件可从废纸篓恢复"
                } else {
                    let details = report.failures.map { "\($0.0.name)：\($0.1)" }.joined(separator: "\n")
                    self.lastError = "部分项目未能清理：\n\(details)"
                    self.statusMessage = includesDocker
                        ? "已处理 \(report.removed.count) 项，\(report.failures.count) 项失败；Docker 资源请查看错误详情"
                        : "已处理 \(report.removed.count) 项，\(report.failures.count) 项失败"
                }
            }
        }
    }

    func clearError() {
        lastError = nil
    }

    private func persistProjectRoots() {
        UserDefaults.standard.set(projectRoots.map(\.path), forKey: Self.projectRootsKey)
    }

    private func persistWhitelist() {
        UserDefaults.standard.set(whitelistedPaths.map(\.path), forKey: Self.whitelistedPathsKey)
    }

    private func persistSelectionStates() {
        guard let data = try? JSONEncoder().encode(selectionStates) else { return }
        UserDefaults.standard.set(data, forKey: Self.selectionStatesKey)
    }

    private static func defaultProjectRoots(home: URL) -> [URL] {
        let candidates = [
            "Code", "Projects", "Developer", "Work", "src", "workspace", "Repos", "Repositories", "dev", "software"
        ]
            .map { home.appendingPathComponent($0) }
        return normalizeProjectRoots(candidates)
    }

    private static func normalizeProjectRoots(_ roots: [URL]) -> [URL] {
        let existing = roots
            .map { $0.standardizedFileURL.resolvingSymlinksInPath() }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
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
