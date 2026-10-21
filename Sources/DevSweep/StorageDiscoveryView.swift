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

    private let defaults: UserDefaults
    private var activeFlag: DiscoveryCancellationFlag?
    private var scanGeneration = 0

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

    var visibleNodes: [DiscoveryNode] {
        (report?.nodes ?? []).filter { !ignoredPaths.contains($0.id) }
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

        currentDirectory = directory
        if report?.directory.standardizedFileURL.path != directory.path {
            report = nil
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
                self.isScanning = false
                self.activeFlag = nil
                self.phase = result.wasCancelled ? "已取消" : "扫描完成"
                // 扫描期间调整了阈值时，用新阈值重扫一次，避免界面停留在旧过滤结果。
                if !result.wasCancelled && result.thresholdBytes != self.thresholdBytes {
                    self.rescan()
                }
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

    func clearError() {
        lastError = nil
    }

    func ignore(_ node: DiscoveryNode) {
        ignoredPaths.insert(node.id)
        persistIgnoredPaths()
    }

    func restoreIgnoredPath(_ path: String) {
        ignoredPaths.remove(path)
        persistIgnoredPaths()
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

    private var nodes: [DiscoveryNode] { store.visibleNodes }

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

            if let report = store.report {
                summaryCard(report)
                if let activeRoot {
                    breadcrumbCard(report: report, root: activeRoot)
                }
                if nodes.isEmpty {
                    emptyResultCard(report)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("目录内容")
                                .font(.headline)
                            Text("按占用从大到小")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(nodes.count) 项")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                        LazyVStack(spacing: 10) {
                            ForEach(nodes) { node in
                                nodeRow(node)
                            }
                        }
                    }
                }
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
                }

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
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button("上一级") {
                    if let parent = parentDirectory(root: root) {
                        store.scan(directory: parent)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(store.currentDirectory?.standardizedFileURL.path == root.standardizedFileURL.path)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        Button {
                            store.scan(directory: root)
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
                                    store.scan(directory: component.url)
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
        HStack(alignment: .top, spacing: 12) {
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
                            store.scan(directory: node.path)
                        } label: {
                            Label("查看", systemImage: "chevron.right")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    Menu {
                        if node.canNavigate {
                            Button("查看子目录") { store.scan(directory: node.path) }
                        }
                        Button("在 Finder 中显示") {
                            NSWorkspace.shared.activateFileViewerSelecting([node.path])
                        }
                        Button("复制路径") { copyPath(node.path) }
                        Divider()
                        Button("忽略此项") { store.ignore(node) }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.2))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
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
                Text("只读页面")
                    .font(.callout.weight(.medium))
                Text("这里不提供勾选或清理操作。未知目录需要先被规则或专用清单验证，才会进入对应的清理授权流程；系统管理数据和依赖关系不明的目录保持只读。")
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
        guard let current = store.currentDirectory?.standardizedFileURL else { return [] }
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
}
