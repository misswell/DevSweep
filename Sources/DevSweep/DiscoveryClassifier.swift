import Foundation

/// 发现页的只读分类规则。扫描器与层级树快照共用同一份实现，
/// 保证「当前层列表」和「多层树图」对同一路径给出相同结论。
struct DiscoveryClassifier {
    let knownCacheLocations: [KnownCacheLocation]
    let home: URL
    let fileManager: FileManager
    /// 规范化后的缓存根路径，按长度降序；热路径上只做字符串比较，
    /// 不再对每个节点重复解析 `standardizedFileURL`。
    private let knownCachePaths: [(path: String, location: KnownCacheLocation)]
    private let knownCachePathSet: Set<String>
    private let knownCachePrefixes: [String]
    private let homePath: String
    private let homeCacheRoots: [String]

    init(
        knownCacheLocations: [KnownCacheLocation] = CacheScanner.knownCacheLocations(),
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) {
        self.knownCacheLocations = knownCacheLocations
        self.home = home
        self.fileManager = fileManager
        self.homePath = home.standardizedFileURL.path
        self.knownCachePaths = knownCacheLocations
            .map { ($0.url.standardizedFileURL.path, $0) }
            .sorted { $0.0.count > $1.0.count }
        self.knownCachePathSet = Set(knownCachePaths.map(\.path))
        self.knownCachePrefixes = knownCachePaths.map { $0.path + "/" }
        self.homeCacheRoots = [homePath + "/Library/Caches", homePath + "/.cache"]
    }

    private static let unknownEvidence = "未命中内置缓存规则、模型/环境标记或项目生成物特征；分类前不会进入清理流程"
    private static let systemManagedPrefixes = [
        "/System", "/Library", "/usr", "/bin", "/sbin", "/private", "/Applications"
    ]

    func classify(
        url: URL,
        isDirectory: Bool
    ) -> (
        classification: DiscoveryClassification,
        confidence: CleanupConfidence,
        evidence: [String],
        cleanupCandidate: DiscoveryCleanupCandidate?
    ) {
        if let evidence = systemManagedEvidence(for: url) {
            return (.systemManaged, .verified, [evidence], nil)
        }
        if let location = exactKnownCache(for: url) {
            let candidate = location.risk == .manual ? nil : DiscoveryCleanupCandidate(
                category: location.category,
                name: location.name,
                risk: location.risk,
                note: location.note
            )
            return (.knownCache, .verified, [
                "内置缓存规则：\(location.category) · \(location.name)",
                location.note
            ], candidate)
        }
        if isDirectory, let model = aiModelEvidence(for: url) {
            return (.aiModel, model.confidence, [model.evidence], nil)
        }
        if let environment = developmentEnvironmentEvidence(for: url, isDirectory: isDirectory) {
            return (.developmentEnvironment, environment.confidence, [environment.evidence], nil)
        }
        if let evidence = knownCacheAncestorEvidence(for: url) {
            return (.knownCache, .inferred, [evidence], nil)
        }
        if let special = specialContentEvidence(for: url) {
            return (.unknown, .unknown, [special, Self.unknownEvidence], nil)
        }
        if isDirectory, let rule = CacheScanner.generatedRule(for: url) {
            let candidate = rule.risk == .manual ? nil : DiscoveryCleanupCandidate(
                category: rule.category,
                name: url.lastPathComponent,
                risk: rule.risk,
                note: rule.note
            )
            if rule.category == "其他开发缓存" {
                return (
                    .knownCache,
                    .inferred,
                    ["包含有效 CACHEDIR.TAG，软件声明其内容可作为缓存重建"],
                    candidate
                )
            }
            return (.generatedArtifact, .inferred, ["命中 \(rule.category) 生成物特征", rule.note], candidate)
        }
        return (.unknown, .unknown, [Self.unknownEvidence], nil)
    }

    /// 只按路径与扩展名判断，不访问文件系统、不做 URL 解析。
    /// 布局需要给上万个图块着色，这里必须是纯字符串运算。
    func classifyShallow(path: String, name: String, isDirectory: Bool) -> DiscoveryClassification {
        if isSystemManagedPath(path) { return .systemManaged }
        if knownCachePathSet.contains(path) { return .knownCache }
        if isDirectory {
            if path.contains("/.ollama/models")
                || path.contains("/lmstudio/models")
                || path.contains("/lm-studio/models")
                || name.hasPrefix("models--") {
                return .aiModel
            }
            if path.contains("/.nvm/versions/")
                || path.contains("/.rustup/toolchains/")
                || path.contains("/.pyenv/versions/")
                || path.contains("/JavaVirtualMachines/")
                || path.contains("/Library/Developer/Toolchains/")
                || path.contains("/Android/sdk/") {
                return .developmentEnvironment
            }
        }
        if knownCachePrefixes.contains(where: { path.hasPrefix($0) }) { return .knownCache }
        if homeCacheRoots.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            return .knownCache
        }
        if isDirectory, Self.generatedArtifactNames.contains(name) {
            return .generatedArtifact
        }
        return .unknown
    }

    private static let generatedArtifactNames: Set<String> = [
        "node_modules", "DerivedData", ".build", "build", "dist", "target",
        "__pycache__", ".next", ".nuxt", ".gradle", ".tox", "vendor", "Pods"
    ]

    private func isSystemManagedPath(_ path: String) -> Bool {
        if Self.systemManagedPrefixes.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            return true
        }
        let managedRoots = [
            home.path + "/Library/Developer/CoreSimulator",
            home.path + "/Library/Developer/XCTestDevices"
        ]
        return managedRoots.contains(where: { path == $0 || path.hasPrefix($0 + "/") })
    }

    private func systemManagedEvidence(for url: URL) -> String? {
        let path = url.standardizedFileURL.path
        if Self.systemManagedPrefixes.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            return "系统或全局安装位置，需要系统管理工具处理"
        }
        let managedRoots = [
            home.path + "/Library/Developer/CoreSimulator",
            home.path + "/Library/Developer/XCTestDevices"
        ]
        if managedRoots.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            return "由 Xcode / CoreSimulator 管理的设备目录，只能通过官方工具操作"
        }
        return nil
    }

    private func exactKnownCache(for url: URL) -> KnownCacheLocation? {
        let path = url.standardizedFileURL.path
        return knownCacheLocations.first { $0.url.standardizedFileURL.path == path }
    }

    private func knownCacheAncestorEvidence(for url: URL) -> String? {
        let path = url.standardizedFileURL.path
        let sorted = knownCacheLocations.sorted { $0.url.path.count > $1.url.path.count }
        if let location = sorted.first(where: {
            path.hasPrefix($0.url.standardizedFileURL.path + "/")
        }) {
            return "位于内置缓存「\(location.name)」内（\(location.category)）"
        }

        let conventionalRoots = [home.path + "/Library/Caches", home.path + "/.cache"]
        if let root = conventionalRoots.first(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            return "位于 \(URL(fileURLWithPath: root).devSweepDisplayPath)，按系统缓存目录约定识别"
        }
        return nil
    }

    private func aiModelEvidence(for url: URL) -> (evidence: String, confidence: CleanupConfidence)? {
        if let evidence = CacheScanner.huggingFaceModelEvidence(for: url) {
            return (evidence, .verified)
        }

        let path = url.standardizedFileURL.path
        let components = url.pathComponents

        if path.contains("/.ollama/models") {
            let names = Set((try? fileManager.contentsOfDirectory(atPath: path)) ?? [])
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

    private func developmentEnvironmentEvidence(
        for url: URL,
        isDirectory: Bool
    ) -> (evidence: String, confidence: CleanupConfidence)? {
        guard isDirectory else { return nil }
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

    private func specialContentEvidence(for url: URL) -> String? {
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
