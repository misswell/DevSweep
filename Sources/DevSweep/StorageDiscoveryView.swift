import AppKit
import SwiftUI

/// 「磁盘发现」页的状态。扫描结果按目录保存，切换到其它页面再回来不会丢失。
@MainActor
final class StorageDiscoveryStore: ObservableObject {
    private static let customRootsKey = "DevSweep.discoveryRoots"
    private static let ignoredPathsKey = "DevSweep.discoveryIgnored"
    private static let thresholdKey = "DevSweep.discoveryThresholdMB"

    @Published private(set) var customRoots: [URL]
    @Published private(set) var ignoredPaths: Set<String>
    @Published var thresholdMB: Int {
        didSet {
            guard thresholdMB != oldValue else { return }
            defaults.set(thresholdMB, forKey: Self.thresholdKey)
            if report != nil && !isScanning {
                rescan()
            }
        }
    }
    @Published private(set) var currentDirectory: URL?
    @Published private(set) var report: DiscoveryReport?
    @Published private(set) var isScanning = false
    @Published private(set) var phase = "准备扫描"
    @Published private(set) var checkedCount = 0
    @Published private(set) var lastError: String?
    /// 图表、类型统计和列表共用的搜索条件。
    /// 「大文件 / 旧文件」模式：与目录树扫描并列的只读发现，不改变目录树结果。
    @Published var isLargeFileMode = false {
        didSet {
            guard isLargeFileMode != oldValue else { return }
            if isLargeFileMode { scanLargeOldFiles() } else { largeOldReport = nil }
        }
    }
    @Published private(set) var largeOldReport: LargeOldFileScanReport?
    @Published private(set) var isScanningLargeOldFiles = false
    /// 大文件阈值（MB）与旧文件天数；0 天数表示不按年龄过滤。
    @Published var largeFileThresholdMB = 200
    @Published var largeFileOlderThanDays = 180

    @Published var searchText = "" {
        didSet {
            guard searchText != oldValue else { return }
            rebuildGraphSnapshot()
            rebuildChartSnapshot()
        }
    }
    /// 分布图快照。只在扫描结果、忽略项或搜索条件变化时重建，
    /// 选中与悬停这类视图状态不会触发整层目录重新排序。
    @Published private(set) var graphSnapshot = DistributionSnapshot(nodes: [], query: "")
    /// 树图当前根的直接子项快照。图表、类型统计和列表都从这里取数，
    /// 下钻只切换根节点，不重新扫描文件系统。
    @Published private(set) var chartSnapshot = DistributionSnapshot(nodes: [], query: "")
    /// 多层环形图的祖先层，从靠近圆心向外排列，不含当前层。
    @Published private(set) var graphLevels: [SunburstLevel] = []
    @Published var graphTypeScope: FileTypeScope = .direct {
        didSet {
            guard graphTypeScope != oldValue else { return }
            graphTypeScope == .recursive ? runRollup() : clearRollup()
        }
    }
    @Published private(set) var rollup: FileTypeRollup?
    @Published private(set) var isRollupRunning = false
    @Published private(set) var rollupPhase: String?
    /// 多层树图当前根节点在快照中的索引。下钻只移动图表根，不重新扫描文件系统。
    @Published private(set) var chartRootIndex = 0
    /// 树图展开深度；越小越快，也越不容易出现无法阅读的细条。
    @Published var nestedDepthLimit = 5 {
        didSet { nestedDepthLimit = min(max(nestedDepthLimit, 1), 8) }
    }
    @Published private(set) var chartHistoryBack: [Int] = []
    @Published private(set) var chartHistoryForward: [Int] = []

    private let defaults: UserDefaults
    private var activeFlag: DiscoveryCancellationFlag?
    private var scanGeneration = 0
    private var graphNodesCache: (key: String, nodes: [DiscoveryNode])?
    private var activeRollupFlag: DiscoveryCancellationFlag?
    private var rollupGeneration = 0
    /// 环形图最多保留的祖先圈数，再多只会让每圈窄到无法阅读。
    private static let maxGraphLevels = 2

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let storedThreshold = defaults.object(forKey: Self.thresholdKey) as? Int {
            self.thresholdMB = storedThreshold
        } else {
            self.thresholdMB = 100
        }
        self.customRoots = (defaults.stringArray(forKey: Self.customRootsKey) ?? [])
            .map { URL(fileURLWithPath: $0) }
        self.ignoredPaths = Set(defaults.stringArray(forKey: Self.ignoredPathsKey) ?? [])
    }

    var thresholdBytes: Int64 { Int64(thresholdMB) * 1_048_576 }

    var treeSnapshot: DiscoveryTreeSnapshot? { report?.treeSnapshot }

    var chartRootPath: String? {
        guard let snapshot = treeSnapshot, snapshot.records.indices.contains(chartRootIndex) else { return nil }
        return snapshot.path(of: chartRootIndex)
    }

    /// 树图当前根的直接子项，按占用降序，并按列表阈值过滤。
    var chartLayerNodes: [DiscoveryNode] {
        layerNodes(applyThreshold: true)
    }

    /// 图表与类型统计使用的本层条目：保留低于阈值的项目，
    /// 面积和合计才不会被列表阈值截断。
    var chartSnapshotNodes: [DiscoveryNode] {
        layerNodes(applyThreshold: false)
    }

    private func layerNodes(applyThreshold: Bool) -> [DiscoveryNode] {
        guard let report, let snapshot = treeSnapshot,
              snapshot.records.indices.contains(chartRootIndex) else { return visibleNodes }
        if chartRootIndex == snapshot.rootIndex {
            return applyThreshold ? visibleNodes : graphNodes
        }
        let classifier = DiscoveryClassifier(knownCacheLocations: CacheScanner.knownCacheLocations())
        let threshold = applyThreshold ? thresholdBytes : 0
        var nodes: [DiscoveryNode] = []
        for child in snapshot.children(of: chartRootIndex) {
            guard let node = snapshot.discoveryNode(at: Int(child), classifier: classifier) else { continue }
            guard !ignoredPaths.contains(node.id) else { continue }
            if threshold > 0,
               node.measurement.state == .complete,
               node.measurement.allocatedBytes < threshold {
                continue
            }
            nodes.append(node)
        }
        _ = report
        nodes.sort { lhs, rhs in
            if lhs.measurement.allocatedBytes != rhs.measurement.allocatedBytes {
                return lhs.measurement.allocatedBytes > rhs.measurement.allocatedBytes
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        return nodes
    }

    func treeNode(atPath path: String) -> DiscoveryNode? {
        guard let snapshot = treeSnapshot, let index = snapshot.index(ofPath: path) else { return nil }
        return snapshot.discoveryNode(
            at: index,
            classifier: DiscoveryClassifier(knownCacheLocations: CacheScanner.knownCacheLocations())
        )
    }

    func chartIndex(forPath path: String) -> Int? {
        treeSnapshot?.index(ofPath: path)
    }

    var scanRootPath: String? { treeSnapshot?.rootURL.path }

    /// 目录跳转优先在已扫描快照内移动图表根；只有快照外的目录才重新扫描。
    func openDirectory(_ url: URL) {
        if let index = chartIndex(forPath: url.path) {
            navigateChart(to: index)
        } else {
            scan(directory: url)
        }
    }

    func navigateChart(to index: Int) {
        guard let snapshot = treeSnapshot, snapshot.records.indices.contains(index) else { return }
        guard index != chartRootIndex else { return }
        chartHistoryBack.append(chartRootIndex)
        chartHistoryForward.removeAll()
        chartRootIndex = index
        rebuildChartSnapshot()
    }

    func chartGoUp() {
        guard let snapshot = treeSnapshot,
              snapshot.records.indices.contains(chartRootIndex) else { return }
        let parent = Int(snapshot.records[chartRootIndex].parentIndex)
        guard parent >= 0 else { return }
        navigateChart(to: parent)
    }

    func chartGoBack() {
        guard let previous = chartHistoryBack.popLast() else { return }
        chartHistoryForward.append(chartRootIndex)
        chartRootIndex = previous
        rebuildChartSnapshot()
    }

    func chartGoForward() {
        guard let next = chartHistoryForward.popLast() else { return }
        chartHistoryBack.append(chartRootIndex)
        chartRootIndex = next
        rebuildChartSnapshot()
    }

    var canChartGoBack: Bool { !chartHistoryBack.isEmpty }
    var canChartGoForward: Bool { !chartHistoryForward.isEmpty }
    var canChartGoUp: Bool {
        guard let snapshot = treeSnapshot, snapshot.records.indices.contains(chartRootIndex) else { return false }
        return snapshot.records[chartRootIndex].parentIndex >= 0
    }

    var visibleNodes: [DiscoveryNode] {
        (report?.nodes ?? []).filter { !ignoredPaths.contains($0.id) }
    }

    /// 分布图使用的本层条目（未被列表阈值截断）。结果按扫描代次缓存，
    /// 一次视图构建里多处读取不会重复过滤和拷贝。
    var graphNodes: [DiscoveryNode] {
        let key = graphKey
        if let graphNodesCache, graphNodesCache.key == key {
            return graphNodesCache.nodes
        }
        let nodes = (report?.allNodes ?? []).filter { !ignoredPaths.contains($0.id) }
        graphNodesCache = (key, nodes)
        return nodes
    }

    /// 标识「同一份扫描结果 + 同一组忽略项」，用作派生数据的缓存键。
    /// 忽略集合必须按完整内容比较：只记录元素个数时，一次同时增删会错误命中旧缓存。
    var graphKey: String {
        guard let report else { return "none" }
        return [
            report.directory.standardizedFileURL.path,
            String(report.scannedAt.timeIntervalSince1970),
            report.filterSignature,
            String(report.allNodes.count),
            ignoredPaths.sorted().joined(separator: ",")
        ].joined(separator: "|")
    }

    func rebuildGraphSnapshot() {
        graphSnapshot = DistributionSnapshot(nodes: graphNodes, query: searchText)
    }

    func rebuildChartSnapshot() {
        chartSnapshot = DistributionSnapshot(nodes: chartSnapshotNodes, query: searchText)
    }

    func addCustomRoots(_ urls: [URL]) {
        let existing = Set(customRoots.map(\.standardizedFileURL.path))
        let additions = urls
            .map(\.standardizedFileURL)
            .filter { !existing.contains($0.path) }
        guard !additions.isEmpty else { return }
        customRoots = (customRoots + additions).sorted { $0.path < $1.path }
        persistCustomRoots()
    }

    func removeCustomRoot(_ url: URL) {
        let path = url.standardizedFileURL.path
        customRoots.removeAll { $0.standardizedFileURL.path == path }
        persistCustomRoots()
    }

    func scan(directory: URL) {
        let directory = directory.standardizedFileURL
        guard FileManager.default.fileExists(atPath: directory.path) else {
            lastError = "目录不存在：\(directory.devSweepDisplayPath)"
            return
        }

        scanGeneration += 1
        let generation = scanGeneration
        activeFlag?.cancel()
        let flag = DiscoveryCancellationFlag()
        activeFlag = flag

        updateGraphLevels(for: directory)
        clearRollup()
        currentDirectory = directory
        if report?.directory.standardizedFileURL.path != directory.path {
            report = nil
            rebuildGraphSnapshot()
        }
        isScanning = true
        lastError = nil
        phase = "准备扫描"
        checkedCount = 0

        let threshold = thresholdBytes
        let knownLocations = CacheScanner.knownCacheLocations()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = UnknownStorageScanner.scan(
                directory: directory,
                thresholdBytes: threshold,
                knownCacheLocations: knownLocations,
                isCancelled: { flag.isCancelled },
                progress: { progress in
                    Task { @MainActor [weak self] in
                        guard let self, self.scanGeneration == generation else { return }
                        self.phase = progress.phase
                        self.checkedCount = progress.checkedCount
                    }
                }
            )
            Task { @MainActor [weak self] in
                guard let self, self.scanGeneration == generation else { return }
                self.report = result
                self.chartRootIndex = result.treeSnapshot.rootIndex
                self.chartHistoryBack = []
                self.chartHistoryForward = []
                self.isScanning = false
                self.activeFlag = nil
                self.phase = result.wasCancelled ? "已取消" : "扫描完成"
                self.rebuildGraphSnapshot()
                self.rebuildChartSnapshot()
                if self.graphTypeScope == .recursive {
                    // 递归统计比单层扫描贵得多，等本层测完再开始，避免两路 I/O 抢磁盘。
                    self.runRollup()
                }
                // 扫描期间调整了阈值时，用新阈值重扫一次，避免界面停留在旧过滤结果。
                if !result.wasCancelled && result.thresholdBytes != self.thresholdBytes {
                    self.rescan()
                }
            }
        }
    }

    /// 只读扫描「大文件 / 旧文件」。与目录树扫描完全独立，互不覆盖结果。
    func scanLargeOldFiles() {
        guard !isScanningLargeOldFiles else { return }
        isScanningLargeOldFiles = true
        let home = FileManager.default.homeDirectoryForCurrentUser
        let roots = currentDirectory.map { [ $0 ] } ?? LargeOldFileScanner.defaultRoots(home: home)
        let days = largeFileOlderThanDays > 0 ? largeFileOlderThanDays : nil
        let criteria = LargeOldFileCriteria(
            minimumBytes: Int64(max(1, largeFileThresholdMB)) * 1_048_576,
            olderThanDays: days,
            limit: 200,
            roots: roots
        )
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let report = LargeOldFileScanner.scan(criteria: criteria, home: home)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.largeOldReport = report
                self.isScanningLargeOldFiles = false
            }
        }
    }

    func rescan() {
        guard let currentDirectory else { return }
        scan(directory: currentDirectory)
    }

    func cancel() {
        guard isScanning else { return }
        phase = "正在取消…"
        activeFlag?.cancel()
    }

    /// 下钻时把离开的层压成环形图的一圈；回跳到祖先或跳到别的目录时按层截断，
    /// 保证内圈角度与当前层来自同一份测量，不存在父子重复累计。
    private func updateGraphLevels(for directory: URL) {
        let target = directory.standardizedFileURL.path
        guard let current = currentDirectory?.standardizedFileURL.path else {
            graphLevels = []
            return
        }
        if target == current { return }
        // 第 index 圈是「展开 target 时离开的那一层」，回跳到 target 时它仍是直接祖先，
        // 因此保留到 index（含），只丢弃比 target 更深的圈。
        if let index = graphLevels.firstIndex(where: { $0.enteredID == target }) {
            graphLevels = Array(graphLevels.prefix(index + 1))
            return
        }
        guard report?.directory.standardizedFileURL.path == current,
              directory.deletingLastPathComponent().standardizedFileURL.path == current
        else {
            graphLevels = []
            return
        }
        // 祖先圈用未经搜索过滤的本层分组，搜索条件不改变层级结构。
        let items = TreemapGrouping.grouped(nodes: graphNodes).items
        graphLevels = Array((graphLevels + [SunburstLevel(items: items, enteredID: target)])
            .suffix(Self.maxGraphLevels))
    }

    /// 递归文件类型统计。代价明显高于单层扫描，可取消且有条目上限。
    func runRollup() {
        guard let directory = currentDirectory else {
            rollup = nil
            return
        }
        rollupGeneration += 1
        let generation = rollupGeneration
        activeRollupFlag?.cancel()
        let flag = DiscoveryCancellationFlag()
        activeRollupFlag = flag
        isRollupRunning = true
        rollup = nil
        rollupPhase = "正在准备递归统计"

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = FileTypeRollupScanner.scan(
                root: directory,
                isCancelled: { flag.isCancelled },
                progress: { progress in
                    Task { @MainActor [weak self] in
                        guard let self, self.rollupGeneration == generation else { return }
                        self.rollupPhase = "\(progress.phase)（已扫描 \(progress.scannedEntries) 项）"
                    }
                }
            )
            Task { @MainActor [weak self] in
                guard let self, self.rollupGeneration == generation else { return }
                self.rollup = result
                self.isRollupRunning = false
                self.rollupPhase = nil
                self.activeRollupFlag = nil
            }
        }
    }

    func cancelRollup() {
        rollupGeneration += 1
        activeRollupFlag?.cancel()
        activeRollupFlag = nil
        isRollupRunning = false
        rollupPhase = nil
    }

    private func clearRollup() {
        cancelRollup()
        rollup = nil
    }

    func clearError() {
        lastError = nil
    }

    func ignore(_ node: DiscoveryNode) {
        ignoredPaths.insert(node.id)
        persistIgnoredPaths()
        rebuildGraphSnapshot()
        rebuildChartSnapshot()
    }

    func restoreIgnoredPath(_ path: String) {
        ignoredPaths.remove(path)
        persistIgnoredPaths()
        rebuildGraphSnapshot()
        rebuildChartSnapshot()
    }

    private func persistCustomRoots() {
        defaults.set(customRoots.map(\.path), forKey: Self.customRootsKey)
    }

    private func persistIgnoredPaths() {
        defaults.set(ignoredPaths.sorted(), forKey: Self.ignoredPathsKey)
    }
}

struct StorageDiscoveryView: View {
    @ObservedObject var store: StorageDiscoveryStore
    let projectRoots: [URL]
    @ObservedObject var appStore: DevSweepStore
    @State private var selectedNodeID: String?

    /// 搜索条件存在 store 里，图表快照才能在条件变化时同步重建。
    private var searchText: String {
        get { store.searchText }
        nonmutating set { store.searchText = newValue }
    }

    private static let thresholdOptions: [(label: String, megabytes: Int)] = [
        ("显示全部（含小文件）", 0),
        ("100 MB", 100),
        ("200 MB", 200),
        ("500 MB", 500),
        ("1 GB", 1_024),
        ("2 GB", 2_048)
    ]

    private var developerRoots: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent("Library/Caches"),
            home.appendingPathComponent("Library/Developer"),
            home.appendingPathComponent(".cache"),
            home.appendingPathComponent(".local/share"),
            home.appendingPathComponent(".npm"),
            home.appendingPathComponent(".cargo"),
            home.appendingPathComponent(".rustup")
        ]
    }

    private var allRoots: [URL] {
        var seen = Set<String>()
        return (projectRoots + developerRoots + store.customRoots)
            .map(\.standardizedFileURL)
            .filter { seen.insert($0.path).inserted }
    }

    private var activeRoot: URL? {
        guard let current = store.currentDirectory else { return nil }
        let currentPath = current.standardizedFileURL.path
        return allRoots
            .filter { currentPath == $0.path || currentPath.hasPrefix($0.path + "/") }
            .max { $0.path.count < $1.path.count }
    }

    /// 列表跟随树图根节点：下钻后下方列表就是当前层的条目，
    /// 不需要重新扫描，也不会与图表显示不同层的数据。
    private var nodes: [DiscoveryNode] { store.chartLayerNodes }

    private var searchedNodes: [DiscoveryNode] {
        DiscoverySearch.filter(nodes, query: searchText)
    }

    private var cleanupLink: (DiscoveryNode) -> DiscoveryCleanupLink {
        { node in
            let key = SelectionMemory.key(for: node.path)
            guard let item = appStore.items.first(where: { SelectionMemory.key(for: $0.path) == key }) else {
                return .absent
            }
            return item.isSelected ? .selected : .present
        }
    }

    private var thresholdLabel: String {
        Self.thresholdOptions.first { $0.megabytes == store.thresholdMB }?.label
            ?? "\(store.thresholdMB) MB"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            scopeCard

            if store.isScanning {
                progressCard
            }

            if store.isLargeFileMode {
                largeOldFilesCard
            } else if let report = store.report {
                summaryCard(report)
                if let activeRoot {
                    breadcrumbCard(report: report, root: activeRoot)
                }
                if !store.graphNodes.isEmpty {
                    FileDistributionPanel(
                        nodes: store.graphNodes,
                        snapshot: store.graphSnapshot,
                        treeSnapshot: store.treeSnapshot,
                        chartRootIndex: store.chartRootIndex,
                        chartSnapshot: store.chartSnapshot,
                        searchText: $store.searchText,
                        selectedNodeID: $selectedNodeID,
                        typeScope: $store.graphTypeScope,
                        nestedDepthLimit: $store.nestedDepthLimit,
                        chartRootPath: store.chartRootPath,
                        canChartGoBack: store.canChartGoBack,
                        canChartGoForward: store.canChartGoForward,
                        canChartGoUp: store.canChartGoUp,
                        onChartNavigate: { store.navigateChart(to: $0) },
                        onChartBack: { store.chartGoBack() },
                        onChartForward: { store.chartGoForward() },
                        onChartUp: { store.chartGoUp() },
                        ancestorLevels: store.graphLevels,
                        rollup: store.rollup,
                        isRollupRunning: store.isRollupRunning,
                        rollupPhase: store.rollupPhase,
                        isScanning: store.isScanning,
                        onDrillDown: { store.scan(directory: $0) },
                        onIgnore: { node in
                            if selectedNodeID == node.id {
                                selectedNodeID = nil
                            }
                            store.ignore(node)
                        },
                        onRunRollup: { store.runRollup() },
                        onCancelRollup: { store.cancelRollup() },
                        cleanupLink: cleanupLink,
                        onAddToCleanup: { node in
                            _ = appStore.addDiscoveryCleanupCandidate(node)
                        }
                    )
                }
                directorySection(report: report)
            } else if !store.isScanning {
                emptyStateCard
            }

            ignoredCard
            readOnlyCard
        }
        .alert("扫描失败", isPresented: Binding(
            get: { store.lastError != nil },
            set: { if !$0 { store.clearError() } }
        )) {
            Button("知道了") { store.clearError() }
        } message: {
            Text(store.lastError ?? "")
        }
        .onChange(of: store.currentDirectory) { _ in
            selectedNodeID = nil
            searchText = ""
        }
        .onChange(of: store.chartRootIndex) { _ in
            selectedNodeID = nil
        }
        .onChange(of: store.report?.scannedAt) { _ in
            guard let selectedNodeID else { return }
            let stillPresent = selectedNodeID == TreemapItem.otherID
                || store.treeSnapshot?.index(ofPath: selectedNodeID) != nil
            if !stillPresent {
                self.selectedNodeID = nil
            }
        }
    }

    /// 「大文件 / 旧文件」结果卡：只读，每项可跳到 Finder；不提供删除按钮，
    /// 因为这里不是清理入口，避免把「发现」误当成「清理」。
    @ViewBuilder
    private var largeOldFilesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("大文件 / 旧文件")
                    .font(.headline)
                Spacer()
                Text("大于")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("大小", selection: $store.largeFileThresholdMB) {
                    ForEach([100, 200, 500, 1024, 2048], id: \.self) { mb in
                        Text(mb >= 1024 ? "\(mb / 1024) GB" : "\(mb) MB").tag(mb)
                    }
                }
                .labelsHidden().pickerStyle(.menu).frame(width: 100)
                Text("且超过")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("天数", selection: $store.largeFileOlderThanDays) {
                    Text("不限天数").tag(0)
                    ForEach([30, 90, 180, 365], id: \.self) { days in
                        Text("\(days) 天").tag(days)
                    }
                }
                .labelsHidden().pickerStyle(.menu).frame(width: 110)
                Text("未修改")
                    .font(.caption).foregroundStyle(.secondary)
                Button("重新发现") { store.scanLargeOldFiles() }
                    .disabled(store.isScanningLargeOldFiles)
            }

            if store.isScanningLargeOldFiles {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在发现大文件…").font(.caption).foregroundStyle(.secondary)
                }
            } else if let report = store.largeOldReport {
                Text("已检查 \(report.scannedFileCount) 个文件，找到 \(report.candidates.count) 项"
                    + (report.truncatedByLimit ? "（只显示最大的 200 项）" : ""))
                    .font(.caption).foregroundStyle(.secondary)

                if report.candidates.isEmpty {
                    Text("没有符合条件的文件")
                        .font(.callout).foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else {
                    VStack(spacing: 0) {
                        ForEach(report.candidates, id: \.path) { candidate in
                            HStack(spacing: 10) {
                                Image(systemName: "doc.fill")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 18)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(candidate.path.lastPathComponent)
                                        .font(.callout).lineLimit(1)
                                    Text(candidate.path.devSweepDisplayPath)
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1).truncationMode(.middle)
                                }
                                Spacer(minLength: 12)
                                Text(candidate.modifiedAt.formatted(date: .abbreviated, time: .omitted))
                                    .font(.caption2).foregroundStyle(.tertiary)
                                Text(candidate.sizeBytes.devSweepFileSize)
                                    .font(.callout.monospacedDigit().weight(.medium))
                                    .frame(minWidth: 80, alignment: .trailing)
                                Button {
                                    NSWorkspace.shared.activateFileViewerSelecting([candidate.path])
                                } label: {
                                    Image(systemName: "magnifyingglass")
                                }
                                .buttonStyle(.borderless)
                                .help("在 Finder 中显示")
                            }
                            .padding(.vertical, 5)
                            Divider()
                        }
                    }
                }
            } else {
                Text("点「重新发现」开始扫描")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Text("这里只做只读发现：不提供删除按钮，也不会加入本次清理。确认确实不需要的文件，请在 Finder 中自行处理。")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.07))
        }
    }

    @ViewBuilder
    private func directorySection(report: DiscoveryReport) -> some View {
        if searchedNodes.isEmpty {
            if nodes.isEmpty {
                emptyResultCard(report)
            } else {
                searchEmptyCard
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("目录内容")
                        .font(.headline)
                    Text(
                        searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? "按占用从大到小"
                            : "搜索匹配 \(searchedNodes.count) / \(nodes.count) 项"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(searchedNodes.count) 项")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                ScrollViewReader { proxy in
                    LazyVStack(spacing: 10) {
                        ForEach(searchedNodes) { node in
                            nodeRow(node)
                                .id(node.id)
                        }
                    }
                    .onChange(of: selectedNodeID) { value in
                        guard let value,
                              searchedNodes.contains(where: { $0.id == value })
                        else { return }
                        withAnimation(.easeInOut(duration: 0.2)) {
                            proxy.scrollTo(value, anchor: .center)
                        }
                    }
                }
            }
        }
    }

    private var searchEmptyCard: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text("没有匹配「\(searchText)」的条目")
                .font(.headline)
            Text("搜索只过滤当前层的目录列表和分布图，不会改变扫描结果。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("清除搜索") { searchText = "" }
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, minHeight: 170)
        .padding(18)
        .background(.quaternary.opacity(0.14))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var scopeCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Label("扫描范围", systemImage: "folder")
                    .font(.headline)
                Spacer()
                Button {
                    addDirectories()
                } label: {
                    Label("添加目录", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .disabled(store.isScanning)

                if store.isScanning {
                    Button("取消扫描") { store.cancel() }
                        .buttonStyle(.bordered)
                } else {
                    Button {
                        startScan()
                    } label: {
                        Label(store.currentDirectory == nil ? "开始扫描" : "重新扫描", systemImage: "magnifyingglass")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!hasAvailableRoot && store.currentDirectory == nil)
                }
            }

            HStack(spacing: 10) {
                Menu {
                    Section("项目根目录") {
                        ForEach(projectRoots, id: \.self) { root in
                            Button {
                                store.scan(directory: root)
                            } label: {
                                Text(rootLabel(root))
                            }
                            .disabled(!FileManager.default.fileExists(atPath: root.path))
                        }
                    }
                    Section("常见开发者数据目录") {
                        ForEach(developerRoots, id: \.self) { root in
                            Button {
                                store.scan(directory: root)
                            } label: {
                                Text(rootLabel(root))
                            }
                            .disabled(!FileManager.default.fileExists(atPath: root.path))
                        }
                    }
                    if !store.customRoots.isEmpty {
                        Section("自定义目录") {
                            ForEach(store.customRoots, id: \.self) { root in
                                Button {
                                    store.scan(directory: root)
                                } label: {
                                    Text(rootLabel(root))
                                }
                                .disabled(!FileManager.default.fileExists(atPath: root.path))
                            }
                        }
                    }
                    Divider()
                    Button("添加目录…") { addDirectories() }
                } label: {
                    Label(store.currentDirectory?.devSweepDisplayPath ?? "选择扫描根目录", systemImage: "folder")
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(store.isScanning)

                HStack(spacing: 6) {
                    Text("大目录阈值")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("大目录阈值", selection: $store.thresholdMB) {
                        ForEach(Self.thresholdOptions, id: \.megabytes) { option in
                            Text(option.label).tag(option.megabytes)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 190)
                    .disabled(store.isLargeFileMode)
                }

                Toggle("大文件 / 旧文件", isOn: $store.isLargeFileMode)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .help("只读发现超过阈值、且长时间未修改的文件；结果仅供查看与逐项确认，不会自动清理")

                Spacer(minLength: 0)

                if let current = store.currentDirectory {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([current])
                    } label: {
                        Label("在 Finder 中显示", systemImage: "arrow.up.forward.app")
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }

            if !store.customRoots.isEmpty {
                HStack(spacing: 6) {
                    Text("自定义：")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(store.customRoots, id: \.self) { root in
                        HStack(spacing: 4) {
                            Button(root.lastPathComponent) { store.scan(directory: root) }
                                .buttonStyle(.plain)
                                .font(.caption)
                                .help(root.path)
                            Button {
                                store.removeCustomRoot(root)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("移出自定义目录（不会删除目录）")
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.quaternary.opacity(0.5))
                        .clipShape(Capsule())
                    }
                }
            }

            Text("只读取目录结构和占用，不会修改或删除任何内容；符号链接和其他卷不会被跟随。未知目录必须先经过规则或专用清单验证，才可能进入清理流程。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .background(.quaternary.opacity(0.22))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var progressCard: some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 3) {
                Text(store.phase)
                    .font(.callout.weight(.medium))
                Text("已检查 \(store.checkedCount) 项")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("取消") { store.cancel() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(14)
        .background(.quaternary.opacity(0.22))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func summaryCard(_ report: DiscoveryReport) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Text("\(nodes.count) 项")
                    .font(.system(.headline, design: .rounded))
                if report.hiddenCount > 0 {
                    badge("本层隐藏 \(report.hiddenCount) 项")
                }
                if report.filteredCount > 0 {
                    badge("低于阈值 \(report.filteredCount) 项 · \(report.filteredBytes.devSweepFileSize)")
                }
                if store.graphNodes.count > nodes.count {
                    badge("分布图含本层全部 \(store.graphNodes.count) 项")
                }
                if report.symlinkCount > 0 {
                    badge("符号链接 \(report.symlinkCount) 个")
                }
                if report.crossVolumeCount > 0 {
                    badge("其他卷 \(report.crossVolumeCount) 项")
                }
                Spacer()
                Text("用时 \(String(format: "%.1f", report.duration)) 秒")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            HStack(spacing: 14) {
                Label("已检查 \(report.checkedCount) 项", systemImage: "checklist")
                Label(thresholdLabel, systemImage: "line.3.horizontal.decrease")
                if report.incompleteCount > 0 {
                    Label("\(report.incompleteCount) 项统计不完整，显示的是至少占用", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if report.wasCancelled {
                Label("扫描已取消，结果不完整；可以重新扫描当前目录。", systemImage: "xmark.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if report.limitReached {
                Label(
                    "条目数达到上限，只扫描了前 \(report.checkedCount) 项；合计与图块面积只是已扫描部分的下限。",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }

            if !report.issues.isEmpty {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(report.issues) { issue in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(issue.path.devSweepDisplayPath)
                                    .font(.caption.monospaced())
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .help(issue.path.path)
                                Text("\(issue.kind.title)：\(issue.reason)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.top, 6)
                } label: {
                    Label(
                        report.issues.count >= 100 ? "100 条扫描提示（已截断）" : "\(report.issueCount) 条扫描提示",
                        systemImage: "info.circle"
                    )
                    .font(.caption.weight(.medium))
                }
            }

            Text("占用为 du 分配大小的估算；APFS 克隆、压缩或共享文件的实际释放量可能不同。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .background(.quaternary.opacity(0.18))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func breadcrumbCard(report: DiscoveryReport, root: URL) -> some View {
        let currentPath = report.directory.standardizedFileURL.path
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button("上一级") {
                    if store.canChartGoUp {
                        store.chartGoUp()
                    } else if let parent = parentDirectory(root: root) {
                        store.scan(directory: parent)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!store.canChartGoUp && currentPath == root.standardizedFileURL.path)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        Button {
                            store.openDirectory(root)
                        } label: {
                            Label(root.lastPathComponent, systemImage: "externaldrive")
                        }
                        .buttonStyle(.plain)
                        .font(.caption.weight(.medium))

                        ForEach(breadcrumbComponents(from: root)) { component in
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            if component.isLast {
                                Text(component.name)
                                    .font(.caption.weight(.semibold))
                                    .lineLimit(1)
                            } else {
                                Button(component.name) {
                                    store.openDirectory(component.url)
                                }
                                .buttonStyle(.plain)
                                .font(.caption)
                            }
                        }
                    }
                }
            }
            HStack(spacing: 8) {
                Text(report.directory.devSweepDisplayPath)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(report.directory.path)
                Spacer()
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([report.directory])
                } label: {
                    Label("在 Finder 中显示", systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.16))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func nodeRow(_ node: DiscoveryNode) -> some View {
        let link = cleanupLink(node)
        let isSelected = selectedNodeID == node.id

        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: node.isDirectory ? node.classification.symbolName : "doc")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(node.classification.color)
                .frame(width: 32, height: 32)
                .background(node.classification.color.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text(node.name)
                        .font(.system(.body, design: .rounded).weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(node.path.path)
                    Text(node.classification.title)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(node.classification.color)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(node.classification.color.opacity(0.12))
                        .clipShape(Capsule())
                    if node.isHidden {
                        badge("隐藏")
                    }
                    if node.confidence == .inferred {
                        badge("推断")
                    }
                    if node.cleanupCandidate != nil {
                        statusBadge("可加入清理", color: .green)
                    }
                    if link == .present {
                        statusBadge("已加入待选", color: .blue)
                    } else if link == .selected {
                        statusBadge("已在清理列表", color: .green)
                    }
                    if let warning = node.measurement.warning {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .help(warning)
                    }
                }

                Text(node.path.devSweepDisplayPath)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(node.evidence.joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                if let modifiedAt = node.modifiedAt {
                    Text("最近修改 \(modifiedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 8) {
                Text(node.sizeText)
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(node.measurement.isComplete ? Color.primary : Color.orange)
                    .help(node.measurement.warning ?? "")
                HStack(spacing: 8) {
                    if node.canNavigate {
                        Button {
                            store.openDirectory(node.path)
                        } label: {
                            Label("查看", systemImage: "chevron.right")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    if node.cleanupCandidate != nil, link == .absent {
                        Button {
                            _ = appStore.addDiscoveryCleanupCandidate(node)
                        } label: {
                            Label("加入清理", systemImage: "plus.circle")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    Menu {
                        if node.canNavigate {
                            Button("查看子目录") { store.openDirectory(node.path) }
                        }
                        Button("在 Finder 中显示") {
                            NSWorkspace.shared.activateFileViewerSelecting([node.path])
                        }
                        Button("复制路径") { copyPath(node.path) }
                        if node.cleanupCandidate != nil {
                            Divider()
                            Button(link == .selected ? "已在本次清理中" : "加入本次清理") {
                                _ = appStore.addDiscoveryCleanupCandidate(node)
                            }
                            .disabled(link == .selected)
                        }
                        Divider()
                        Button("忽略此项") {
                            if selectedNodeID == node.id {
                                selectedNodeID = nil
                            }
                            store.ignore(node)
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
        }
        .padding(14)
        .background(isSelected ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.08))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(isSelected ? Color.accentColor.opacity(0.55) : Color.clear, lineWidth: 1.5)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            guard node.canNavigate else { return }
            selectedNodeID = node.id
            store.openDirectory(node.path)
        }
        .simultaneousGesture(
            TapGesture(count: 1).onEnded {
                selectedNodeID = node.id
            }
        )
    }

    private func emptyResultCard(_ report: DiscoveryReport) -> some View {
        VStack(spacing: 10) {
            Image(systemName: report.wasCancelled ? "xmark.circle" : "magnifyingglass")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text(emptyTitle(report))
                .font(.headline)
            Text(emptyMessage(report))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if report.filteredCount > 0 {
                Button("显示全部条目") { store.thresholdMB = 0 }
                    .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 190)
        .padding(18)
        .background(.quaternary.opacity(0.14))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func emptyTitle(_ report: DiscoveryReport) -> String {
        if report.wasCancelled { return "扫描已取消" }
        if report.checkedCount == 0 { return "目录是空的或无法读取" }
        if report.filteredCount > 0 { return "没有超过阈值的项目" }
        if !store.ignoredPaths.isEmpty { return "当前目录没有可显示的条目" }
        return "没有发现子项"
    }

    private func emptyMessage(_ report: DiscoveryReport) -> String {
        if report.wasCancelled {
            return "已测量的部分不会显示为完整结果；重新扫描当前目录可继续。"
        }
        if report.checkedCount == 0 {
            return "请检查路径是否存在，以及当前用户是否有读取权限。"
        }
        if report.filteredCount > 0 {
            return "已测量 \(report.checkedCount) 项，其中 \(report.filteredCount) 项低于 \(thresholdLabel)，共 \(report.filteredBytes.devSweepFileSize)。调低阈值可查看这些条目。"
        }
        if !store.ignoredPaths.isEmpty {
            return "当前目录的条目可能已被忽略，可在下方恢复显示。"
        }
        return "这个目录只有无法统计的条目，或内容已经被清理。"
    }

    private var emptyStateCard: some View {
        VStack(spacing: 10) {
            Image(systemName: "externaldrive")
                .font(.system(size: 38))
                .foregroundStyle(.secondary)
            Text("选择目录，查看空间去向")
                .font(.headline)
            Text("从项目根目录或常见开发者数据目录开始，逐层查看占用最大的子目录。未知条目只读展示，不会进入清理流程。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                startScan()
            } label: {
                Label("开始扫描", systemImage: "magnifyingglass")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!hasAvailableRoot)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
        .padding(18)
        .background(.quaternary.opacity(0.14))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var ignoredCard: some View {
        Group {
            if !store.ignoredPaths.isEmpty {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(store.ignoredPaths.sorted(), id: \.self) { path in
                            HStack(spacing: 8) {
                                Text(URL(fileURLWithPath: path).devSweepDisplayPath)
                                    .font(.caption.monospaced())
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .help(path)
                                Spacer()
                                Button("恢复") {
                                    store.restoreIgnoredPath(path)
                                }
                                .buttonStyle(.link)
                                .font(.caption)
                            }
                        }
                    }
                    .padding(.top, 6)
                } label: {
                    Label("已忽略 \(store.ignoredPaths.count) 项", systemImage: "eye.slash")
                        .font(.callout.weight(.medium))
                }
                .padding(14)
                .background(.quaternary.opacity(0.16))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    private var readOnlyCard: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.shield")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text("默认只读，确认后可加入清理")
                    .font(.callout.weight(.medium))
                Text("未知、系统管理、开发环境和 AI 模型条目始终只读。只有内置缓存规则或项目生成物规则明确识别的条目，才能在详情中显式加入本次清理；加入后不会立即删除，仍需在清理列表确认，并在执行前重新验证路径、白名单和文件身份。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var hasAvailableRoot: Bool {
        allRoots.contains { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func startScan() {
        if store.currentDirectory != nil {
            store.rescan()
            return
        }
        if let first = allRoots.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            store.scan(directory: first)
        }
    }

    private func rootLabel(_ root: URL) -> String {
        FileManager.default.fileExists(atPath: root.path)
            ? root.devSweepDisplayPath
            : root.devSweepDisplayPath + "（不存在）"
    }

    private func parentDirectory(root: URL) -> URL? {
        guard let current = store.currentDirectory?.standardizedFileURL else { return nil }
        let standardizedRoot = root.standardizedFileURL
        guard current.path != standardizedRoot.path else { return nil }
        let parent = current.deletingLastPathComponent()
        return PathWhitelist.contains(parent, in: [standardizedRoot]) ? parent : standardizedRoot
    }

    private struct BreadcrumbComponent: Identifiable {
        let url: URL
        let name: String
        let isLast: Bool
        var id: String { url.path }
    }

    private func breadcrumbComponents(from root: URL) -> [BreadcrumbComponent] {
        guard let current = store.chartRootPath.map({ URL(fileURLWithPath: $0).standardizedFileURL }) else { return [] }
        let rootPath = root.standardizedFileURL.path
        let currentPath = current.path
        guard currentPath.hasPrefix(rootPath + "/") else { return [] }
        let parts = currentPath.dropFirst(rootPath.count).split(separator: "/").map(String.init)
        var accumulated = root.standardizedFileURL
        var result: [BreadcrumbComponent] = []
        for (index, part) in parts.enumerated() {
            accumulated.appendPathComponent(part)
            result.append(BreadcrumbComponent(
                url: accumulated,
                name: part,
                isLast: index == parts.count - 1
            ))
        }
        return result
    }

    private func addDirectories() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.prompt = "添加扫描目录"
        panel.message = "选择要只读扫描的开发目录；不会自动扫描整个磁盘或用户目录"
        guard panel.runModal() == .OK else { return }
        store.addCustomRoots(panel.urls)
        if let first = panel.urls.first {
            store.scan(directory: first)
        }
    }

    private func copyPath(_ url: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url.path, forType: .string)
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(.quaternary.opacity(0.5))
            .clipShape(Capsule())
    }

    private func statusBadge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
    }
}
