import Darwin
import Foundation

struct DiscoveryScanProgress: Equatable {
    let phase: String
    let currentPath: String
    let checkedCount: Int
}

struct DiscoveryReport {
    let directory: URL
    let thresholdBytes: Int64
    let nodes: [DiscoveryNode]
    let checkedCount: Int
    let hiddenCount: Int
    let filteredCount: Int
    let filteredBytes: Int64
    let symlinkCount: Int
    let crossVolumeCount: Int
    let issues: [ScanDiagnostic]
    let wasCancelled: Bool
    let duration: TimeInterval
    let scannedAt: Date

    var incompleteCount: Int {
        nodes.filter { !$0.measurement.isComplete }.count
    }

    var issueCount: Int { issues.count }
}

final class DiscoveryCancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func reset() {
        lock.lock()
        cancelled = false
        lock.unlock()
    }
}

/// 只读的未知占用发现器：每次只列举一个目录的直接子项并测量其占用。
/// 不跟随符号链接、不跨越卷、不删除任何内容；父目录只作为导航节点，
/// 不会和子目录一起参与回收空间计算。
enum UnknownStorageScanner {
    static let measurementChunkSize = 16
    private static let measurementTimeout: TimeInterval = 30
    private static let unknownEvidence = "未命中内置缓存规则、模型/环境标记或项目生成物特征；分类前不会进入清理流程"
    private static let systemManagedPrefixes = [
        "/System", "/Library", "/usr", "/bin", "/sbin", "/private", "/Applications"
    ]

    static func inventory(roots: [URL]) -> [DiscoveryRoot] {
        var seen = Set<String>()
        return roots.compactMap { root in
            let standardized = root.standardizedFileURL
            guard seen.insert(standardized.path).inserted else { return nil }
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: standardized.path, isDirectory: &isDirectory)
            return DiscoveryRoot(path: standardized, exists: exists, isDirectory: exists && isDirectory.boolValue)
        }
    }

    static func scan(
        directory: URL,
        thresholdBytes: Int64,
        knownCacheLocations: [KnownCacheLocation] = CacheScanner.knownCacheLocations(),
        isCancelled: () -> Bool = { false },
        progress: (DiscoveryScanProgress) -> Void = { _ in }
    ) -> DiscoveryReport {
        let startedAt = Date()
        let directory = directory.standardizedFileURL
        var issues: [ScanDiagnostic] = []
        var candidates: [Candidate] = []
        var measurements: [String: StorageMeasurement] = [:]
        var checkedCount = 0
        var hiddenCount = 0
        var symlinkCount = 0
        var crossVolumeCount = 0
        var cancelled = false

        func recordIssue(_ url: URL, _ reason: String, kind: ScanIssueKind) {
            guard issues.count < 100 else { return }
            issues.append(ScanDiagnostic(path: url, reason: reason, kind: kind))
        }

        func finish() -> DiscoveryReport {
            var nodes: [DiscoveryNode] = []
            var filteredCount = 0
            var filteredBytes: Int64 = 0

            for candidate in candidates {
                guard let measurement = measurements[candidate.url.path] else { continue }
                let kept = measurement.state != .complete
                    || thresholdBytes <= 0
                    || measurement.allocatedBytes >= thresholdBytes
                guard kept else {
                    filteredCount += 1
                    filteredBytes += measurement.allocatedBytes
                    continue
                }
                let classified = classify(
                    url: candidate.url,
                    isDirectory: candidate.isDirectory,
                    knownCacheLocations: knownCacheLocations
                )
                nodes.append(DiscoveryNode(
                    path: candidate.url,
                    name: candidate.url.lastPathComponent,
                    measurement: measurement,
                    classification: classified.classification,
                    confidence: classified.confidence,
                    evidence: classified.evidence,
                    isDirectory: candidate.isDirectory,
                    isHidden: candidate.isHidden,
                    modifiedAt: candidate.modifiedAt
                ))
                if let warning = measurement.warning {
                    recordIssue(
                        candidate.url,
                        warning,
                        kind: measurement.state == .timedOut ? .skipped : .inaccessible
                    )
                }
            }

            nodes.sort { lhs, rhs in
                if lhs.measurement.allocatedBytes != rhs.measurement.allocatedBytes {
                    return lhs.measurement.allocatedBytes > rhs.measurement.allocatedBytes
                }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }

            return DiscoveryReport(
                directory: directory,
                thresholdBytes: thresholdBytes,
                nodes: nodes,
                checkedCount: checkedCount,
                hiddenCount: hiddenCount,
                filteredCount: filteredCount,
                filteredBytes: filteredBytes,
                symlinkCount: symlinkCount,
                crossVolumeCount: crossVolumeCount,
                issues: issues,
                wasCancelled: cancelled,
                duration: Date().timeIntervalSince(startedAt),
                scannedAt: startedAt
            )
        }

        guard !isCancelled() else {
            cancelled = true
            return finish()
        }
        guard FileManager.default.fileExists(atPath: directory.path) else {
            recordIssue(directory, "目录不存在", kind: .unavailable)
            return finish()
        }

        var rootInfo = stat()
        guard lstat(directory.path, &rootInfo) == 0, (rootInfo.st_mode & S_IFMT) == S_IFDIR else {
            recordIssue(directory, "不是可读取的目录", kind: .unavailable)
            return finish()
        }
        let rootDevice = UInt64(rootInfo.st_dev)
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isHiddenKey, .contentModificationDateKey]

        let children: [URL]
        do {
            children = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: keys,
                options: []
            )
        } catch {
            recordIssue(directory, "无法读取目录内容：\(error.localizedDescription)", kind: .inaccessible)
            return finish()
        }

        progress(DiscoveryScanProgress(
            phase: "正在检查目录内容",
            currentPath: directory.devSweepDisplayPath,
            checkedCount: 0
        ))

        for child in children.sorted(by: {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }) {
            if isCancelled() {
                cancelled = true
                return finish()
            }
            checkedCount += 1
            let child = child.standardizedFileURL
            let values = try? child.resourceValues(forKeys: Set(keys))

            if values?.isSymbolicLink == true {
                symlinkCount += 1
                recordIssue(child, "符号链接，未跟随", kind: .skipped)
                continue
            }

            var info = stat()
            guard lstat(child.path, &info) == 0 else {
                recordIssue(child, "无法读取路径信息", kind: .inaccessible)
                continue
            }
            guard UInt64(info.st_dev) == rootDevice else {
                crossVolumeCount += 1
                recordIssue(child, "位于其他卷或挂载点，未跨越扫描", kind: .skipped)
                continue
            }

            let fileType = info.st_mode & S_IFMT
            let isDirectory = fileType == S_IFDIR
            guard isDirectory || fileType == S_IFREG else {
                recordIssue(child, "非常规文件类型，未统计", kind: .skipped)
                continue
            }

            let isHidden = values?.isHidden == true || child.lastPathComponent.hasPrefix(".")
            if isHidden { hiddenCount += 1 }
            candidates.append(Candidate(
                url: child,
                isDirectory: isDirectory,
                isHidden: isHidden,
                modifiedAt: values?.contentModificationDate
            ))
        }

        for candidate in candidates where !candidate.isDirectory {
            if isCancelled() {
                cancelled = true
                return finish()
            }
            measurements[candidate.url.path] = StorageMeasurementService.measure(candidate.url)
        }

        let directories = candidates.filter(\.isDirectory).map(\.url)
        var measuredDirectories = 0
        for start in stride(from: 0, to: directories.count, by: measurementChunkSize) {
            if isCancelled() {
                cancelled = true
                return finish()
            }
            let end = min(start + measurementChunkSize, directories.count)
            let chunk = Array(directories[start..<end])
            progress(DiscoveryScanProgress(
                phase: "正在测量目录占用（\(measuredDirectories) / \(directories.count)）",
                currentPath: (chunk.first ?? directory).devSweepDisplayPath,
                checkedCount: checkedCount
            ))
            let chunkMeasurements = StorageMeasurementService.measure(
                chunk,
                timeout: measurementTimeout
            )
            measurements.merge(chunkMeasurements) { _, latest in latest }
            measuredDirectories += chunk.count
        }

        return finish()
    }

    private struct Candidate {
        let url: URL
        let isDirectory: Bool
        let isHidden: Bool
        let modifiedAt: Date?
    }

    private static func classify(
        url: URL,
        isDirectory: Bool,
        knownCacheLocations: [KnownCacheLocation]
    ) -> (classification: DiscoveryClassification, confidence: CleanupConfidence, evidence: [String]) {
        if let evidence = systemManagedEvidence(for: url) {
            return (.systemManaged, .verified, [evidence])
        }
        if let location = exactKnownCache(for: url, in: knownCacheLocations) {
            return (.knownCache, .verified, [
                "内置缓存规则：\(location.category) · \(location.name)",
                location.note
            ])
        }
        if isDirectory, let model = aiModelEvidence(for: url) {
            return (.aiModel, model.confidence, [model.evidence])
        }
        if let environment = developmentEnvironmentEvidence(for: url, isDirectory: isDirectory) {
            return (.developmentEnvironment, environment.confidence, [environment.evidence])
        }
        if let evidence = knownCacheAncestorEvidence(for: url, in: knownCacheLocations) {
            return (.knownCache, .inferred, [evidence])
        }
        if let special = specialContentEvidence(for: url) {
            return (.unknown, .unknown, [special, unknownEvidence])
        }
        if isDirectory, let rule = CacheScanner.generatedRule(for: url) {
            if rule.category == "其他开发缓存" {
                return (.knownCache, .inferred, ["包含有效 CACHEDIR.TAG，软件声明其内容可作为缓存重建"])
            }
            return (.generatedArtifact, .inferred, ["命中 \(rule.category) 生成物特征", rule.note])
        }
        return (.unknown, .unknown, [unknownEvidence])
    }

    private static func systemManagedEvidence(for url: URL) -> String? {
        let path = url.standardizedFileURL.path
        if systemManagedPrefixes.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            return "系统或全局安装位置，需要系统管理工具处理"
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let managedRoots = [
            home + "/Library/Developer/CoreSimulator",
            home + "/Library/Developer/XCTestDevices"
        ]
        if managedRoots.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            return "由 Xcode / CoreSimulator 管理的设备目录，只能通过官方工具操作"
        }
        return nil
    }

    private static func exactKnownCache(for url: URL, in locations: [KnownCacheLocation]) -> KnownCacheLocation? {
        let path = url.standardizedFileURL.path
        return locations.first { $0.url.standardizedFileURL.path == path }
    }

    private static func knownCacheAncestorEvidence(for url: URL, in locations: [KnownCacheLocation]) -> String? {
        let path = url.standardizedFileURL.path
        let sorted = locations.sorted { $0.url.path.count > $1.url.path.count }
        if let location = sorted.first(where: {
            path.hasPrefix($0.url.standardizedFileURL.path + "/")
        }) {
            return "位于内置缓存「\(location.name)」内（\(location.category)）"
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let conventionalRoots = [home + "/Library/Caches", home + "/.cache"]
        if let root = conventionalRoots.first(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            return "位于 \(URL(fileURLWithPath: root).devSweepDisplayPath)，按系统缓存目录约定识别"
        }
        return nil
    }

    private static func aiModelEvidence(for url: URL) -> (evidence: String, confidence: CleanupConfidence)? {
        if let evidence = CacheScanner.huggingFaceModelEvidence(for: url) {
            return (evidence, .verified)
        }

        let path = url.standardizedFileURL.path
        let components = url.pathComponents

        if path.contains("/.ollama/models") {
            let names = Set((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [])
            if url.lastPathComponent == "models",
               names.contains("manifests") || names.contains("blobs") {
                return ("Ollama 模型目录：manifest 引用内容寻址 blob，模型之间可能共用文件", .verified)
            }
            return ("位于 Ollama 模型目录内；删除模型应使用 ollama 官方命令", .inferred)
        }
        if components.contains(where: { $0.hasPrefix("models--") }) {
            return ("位于 Hugging Face 模型仓库内；snapshots 通过符号链接引用 blobs", .inferred)
        }
        if path.contains("/.lmstudio/models")
            || path.contains("/lm-studio/models")
            || path.contains("/LM Studio/models") {
            return ("LM Studio 模型目录；不同配置可能共用同一模型文件", .inferred)
        }
        if let evidence = CacheScanner.modelDirectoryEvidence(for: url) {
            return (evidence, .inferred)
        }
        return nil
    }

    private static func developmentEnvironmentEvidence(
        for url: URL,
        isDirectory: Bool
    ) -> (evidence: String, confidence: CleanupConfidence)? {
        guard isDirectory else { return nil }
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: url.appendingPathComponent("pyvenv.cfg").path) {
            return ("包含 pyvenv.cfg，是 Python 虚拟环境", .verified)
        }
        if fileManager.fileExists(atPath: url.appendingPathComponent("conda-meta").path) {
            return ("包含 conda-meta，是 Conda 环境", .verified)
        }

        let parent = url.deletingLastPathComponent().pathComponents
        func parentEnds(with suffix: [String]) -> Bool {
            Array(parent.suffix(suffix.count)) == suffix
        }

        if parentEnds(with: [".nvm", "versions", "node"]) {
            return ("nvm 管理的 Node.js 版本", .verified)
        }
        if parentEnds(with: [".rustup", "toolchains"]) {
            return ("rustup 管理的 Rust 工具链", .verified)
        }
        if parentEnds(with: [".pyenv", "versions"]) {
            return ("pyenv 管理的 Python 版本", .verified)
        }
        if parentEnds(with: [".volta", "tools", "image", "node"]) {
            return ("Volta 管理的 Node.js 版本", .verified)
        }
        if parentEnds(with: ["Library", "Java", "JavaVirtualMachines"]) {
            return ("已安装的 JDK", .verified)
        }
        if parentEnds(with: ["Library", "Developer", "Toolchains"]) {
            return ("已安装的 Swift 工具链", .verified)
        }
        for component in ["platforms", "build-tools", "system-images"] {
            if parentEnds(with: ["Library", "Android", "sdk", component]) {
                return ("Android SDK \(component) 组件", .verified)
            }
        }
        if parent.count >= 3, Array(parent.suffix(3).prefix(2)) == [".asdf", "installs"] {
            return ("asdf 管理的工具版本", .verified)
        }
        if parent.count >= 3, Array(parent.suffix(3).prefix(2)) == ["mise", "installs"] {
            return ("mise 管理的工具版本", .verified)
        }
        if parent.count >= 3, Array(parent.suffix(3).prefix(2)) == [".sdkman", "candidates"] {
            return ("SDKMAN 管理的 JDK/SDK 版本", .verified)
        }
        return nil
    }

    private static func specialContentEvidence(for url: URL) -> String? {
        if url.lastPathComponent.lowercased() == ".git" {
            return "Git 仓库元数据；不属于可重建缓存"
        }
        let fileExtension = url.pathExtension.lowercased()
        if ["app", "framework", "xcarchive", "photoslibrary", "aplibrary"].contains(fileExtension) {
            return "应用或媒体资料包；需要用户确认内容，不按缓存处理"
        }
        if ["sqlite", "sqlite3", "db", "realm"].contains(fileExtension) {
            return "数据库文件；可能包含不可重建的数据"
        }
        return nil
    }
}
