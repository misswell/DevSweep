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

private struct GeneratedRule {
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
        progress: @escaping (ScanProgress) -> Void
    ) -> ScanReport {
        let startedAt = Date()
        var collector = ScanCollector()
        let roots = normalizedRoots(projectRoots)

        progress(ScanProgress(phase: "扫描固定开发者缓存"))
        var items = fixedItems(home: home, collector: &collector, progress: progress)

        progress(ScanProgress(
            phase: "发现可配置的工具链缓存",
            checkedPaths: collector.checkedPaths,
            matchedPaths: items.count,
            skippedPaths: collector.skippedPaths,
            permissionFailures: collector.permissionFailures
        ))
        items += dynamicItems(home: home, collector: &collector, progress: progress)

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
            CacheRule(category: "Xcode", name: "Archives", relativePath: "Library/Developer/Xcode/Archives", risk: .review, note: "可能包含发布归档，请确认后清理"),
            CacheRule(category: "Xcode", name: "Products", relativePath: "Library/Developer/Xcode/Products", risk: .review, note: "项目产物，可按需重新构建"),
            CacheRule(category: "Xcode", name: "iOS DeviceSupport", relativePath: "Library/Developer/Xcode/iOS DeviceSupport", risk: .manual, note: "删除后真机调试可能需要重新下载"),
            CacheRule(category: "CoreSimulator", name: "模拟器缓存", relativePath: "Library/Developer/CoreSimulator/Caches", risk: .safe, note: "模拟器缓存，不含设备数据"),
            CacheRule(category: "CoreSimulator", name: "模拟器日志", relativePath: "Library/Logs/CoreSimulator", risk: .safe, note: "模拟器会重新生成日志"),

            CacheRule(category: "包管理器", name: "npm 下载缓存", relativePath: ".npm/_cacache", risk: .safe, note: "npm 会重新下载依赖"),
            CacheRule(category: "包管理器", name: "npm 日志", relativePath: ".npm/_logs", risk: .safe, note: "仅为 npm 日志"),
            CacheRule(category: "包管理器", name: "npm（旧路径）", relativePath: ".npm-cache-user/_cacache", risk: .safe, note: "npm 会重新下载依赖"),
            CacheRule(category: "包管理器", name: "Yarn", relativePath: "Library/Caches/Yarn", risk: .safe, note: "Yarn 会重新下载依赖"),
            CacheRule(category: "包管理器", name: "Yarn（旧缓存）", relativePath: ".cache/yarn", risk: .safe, note: "Yarn 会重新下载依赖"),
            CacheRule(category: "包管理器", name: "pnpm store", relativePath: "Library/pnpm/store", risk: .safe, note: "pnpm 会重新下载依赖"),
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
            CacheRule(category: "包管理器", name: "Composer", relativePath: "Library/Caches/composer", risk: .safe, note: "Composer 会重新下载依赖"),
            CacheRule(category: "包管理器", name: "NuGet 全局包缓存", relativePath: ".nuget/packages", risk: .safe, note: "NuGet 会重新下载包"),

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
            CacheRule(category: "JVM", name: "Android SDK 临时下载", relativePath: "Library/Android/sdk/.temp", risk: .safe, note: "Android SDK 会重新下载组件"),
            CacheRule(category: "JVM", name: "Android SDK 缓存", relativePath: "Library/Android/sdk/.cache", risk: .safe, note: "Android SDK 会自动重建缓存"),
            CacheRule(category: "JVM", name: "Android 用户缓存", relativePath: ".android/cache", risk: .safe, note: "Android 工具会自动重建缓存"),
            CacheRule(category: "JVM", name: "Android 旧构建缓存", relativePath: ".android/build-cache", risk: .safe, note: "Android 工具会重新构建"),
            CacheRule(category: "JVM", name: "Bazel 缓存", relativePath: "Library/Caches/bazel", risk: .safe, note: "Bazel 会重新构建"),
            CacheRule(category: "JVM", name: "Bazel（旧缓存）", relativePath: ".cache/bazel", risk: .safe, note: "Bazel 会重新构建"),

            CacheRule(category: "语言工具链", name: "mise 缓存", relativePath: ".cache/mise", risk: .safe, note: "mise 会重新下载工具"),
            CacheRule(category: "语言工具链", name: "asdf 下载缓存", relativePath: ".asdf/downloads", risk: .safe, note: "asdf 会重新下载工具"),
            CacheRule(category: "语言工具链", name: "asdf 临时缓存", relativePath: ".asdf/tmp", risk: .safe, note: "asdf 会重新创建临时文件"),
            CacheRule(category: "语言工具链", name: "ccache", relativePath: ".cache/ccache", risk: .safe, note: "编译器会重新编译"),
            CacheRule(category: "语言工具链", name: "sccache", relativePath: ".cache/sccache", risk: .safe, note: "编译器会重新编译"),
            CacheRule(category: "语言工具链", name: "ccache（macOS）", relativePath: "Library/Caches/ccache", risk: .safe, note: "编译器会重新编译"),
            CacheRule(category: "语言工具链", name: "sccache（macOS）", relativePath: "Library/Caches/sccache", risk: .safe, note: "编译器会重新编译"),
            CacheRule(category: "Python 项目", name: "pipx 缓存", relativePath: ".cache/pipx", risk: .safe, note: "pipx 会重新下载包"),
            CacheRule(category: "Python 项目", name: "pre-commit 缓存", relativePath: ".cache/pre-commit", risk: .safe, note: "pre-commit 会重新下载环境"),
            CacheRule(category: "Python 项目", name: "Jupyter 缓存", relativePath: ".cache/jupyter", risk: .safe, note: "Jupyter 会重新生成缓存"),

            CacheRule(category: "IDE", name: "VS Code Cache", relativePath: "Library/Application Support/Code/Cache", risk: .safe, note: "编辑器会自动重建"),
            CacheRule(category: "IDE", name: "VS Code CachedData", relativePath: "Library/Application Support/Code/CachedData", risk: .safe, note: "编辑器会自动重建"),
            CacheRule(category: "IDE", name: "VS Code 系统缓存", relativePath: "Library/Caches/com.microsoft.VSCode", risk: .safe, note: "编辑器会自动重建"),
            CacheRule(category: "IDE", name: "VS Code workspaceStorage", relativePath: "Library/Application Support/Code/User/workspaceStorage", risk: .review, note: "工作区状态和扩展数据，确认后再清理"),
            CacheRule(category: "IDE", name: "Cursor Cache", relativePath: "Library/Application Support/Cursor/Cache", risk: .safe, note: "编辑器会自动重建"),
            CacheRule(category: "IDE", name: "Cursor CachedData", relativePath: "Library/Application Support/Cursor/CachedData", risk: .safe, note: "编辑器会自动重建"),
            CacheRule(category: "IDE", name: "Cursor Code Cache", relativePath: "Library/Application Support/Cursor/Code Cache", risk: .safe, note: "编辑器会自动重建"),
            CacheRule(category: "IDE", name: "Cursor GPUCache", relativePath: "Library/Application Support/Cursor/GPUCache", risk: .safe, note: "编辑器会自动重建"),
            CacheRule(category: "IDE", name: "Cursor workspaceStorage", relativePath: "Library/Application Support/Cursor/User/workspaceStorage", risk: .review, note: "工作区状态和扩展数据，确认后再清理"),
            CacheRule(category: "IDE", name: "JetBrains 缓存", relativePath: "Library/Caches/JetBrains", risk: .safe, note: "IDE 会自动重建"),
            CacheRule(category: "IDE", name: "JetBrains 日志", relativePath: "Library/Logs/JetBrains", risk: .safe, note: "IDE 会重新生成日志"),
            CacheRule(category: "IDE", name: "Android Studio 日志", relativePath: "Library/Logs/AndroidStudio", risk: .safe, note: "Android Studio 会重新生成日志"),

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

    private static func dynamicItems(
        home: URL,
        collector: inout ScanCollector,
        progress: @escaping (ScanProgress) -> Void
    ) -> [CacheItem] {
        var items: [CacheItem] = []
        let environment = ProcessInfo.processInfo.environment

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

        if let npmrc = try? String(contentsOf: home.appendingPathComponent(".npmrc"), encoding: .utf8),
           let configuredPath = configuredValue(named: "cache", in: npmrc),
           let path = expandedPath(configuredPath, home: home) {
            add("包管理器", "npm 配置缓存", path, .safe, "来自 ~/.npmrc，npm 会重新下载依赖")
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
        ".nx": GeneratedRule(category: "Node.js 项目", risk: .safe, note: "Nx 缓存，会自动重建"),
        ".angular": GeneratedRule(category: "Node.js 项目", risk: .safe, note: "Angular 缓存，会自动重建"),
        ".nuxt": GeneratedRule(category: "Node.js 项目", risk: .safe, note: "Nuxt 构建缓存，会自动重建"),
        ".output": GeneratedRule(category: "Node.js 项目", risk: .review, note: "Nuxt 输出目录，可按需重新生成"),
        ".expo": GeneratedRule(category: "Node.js 项目", risk: .review, note: "Expo 项目缓存，删除后会重新生成"),
        "cmake-build-debug": GeneratedRule(category: "项目生成物", risk: .review, note: "CMake 构建产物，可按需重新生成"),
        "cmake-build-release": GeneratedRule(category: "项目生成物", risk: .review, note: "CMake 构建产物，可按需重新生成"),
        ".zig-cache": GeneratedRule(category: "项目生成物", risk: .safe, note: "Zig 构建缓存，会自动重建"),
        "zig-cache": GeneratedRule(category: "项目生成物", risk: .safe, note: "Zig 构建缓存，会自动重建"),
        "bazel-out": GeneratedRule(category: "项目生成物", risk: .safe, note: "Bazel 输出缓存，会自动重建"),
        "buck-out": GeneratedRule(category: "项目生成物", risk: .safe, note: "Buck 输出缓存，会自动重建"),
        ".gradle": GeneratedRule(category: "JVM", risk: .safe, note: "项目级 Gradle 缓存，会自动重建")
    ]

    private static func generatedRule(for url: URL) -> GeneratedRule? {
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
            "Apple 项目", "Swift 项目", "Flutter 项目", "Python 项目", "测试产物", "包管理器",
            "语言工具链", "AI/ML", "Docker", "JVM", "IDE", "Android Studio", "设计工具", "其他开发缓存"
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
        scan()
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
            "Code", "Projects", "Developer", "Work", "src", "workspace", "Repos", "Repositories", "dev"
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
