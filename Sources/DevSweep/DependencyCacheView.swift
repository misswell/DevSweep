import SwiftUI

struct DependencyCacheButton: View {
    @EnvironmentObject private var store: DevSweepStore
    @State private var showingPreview = false
    let repository: DependencyRepository

    var body: some View {
        Button("按包清理") { showingPreview = true }
            .disabled(store.isCleaning || store.isScanning)
            .sheet(isPresented: $showingPreview) {
                DependencyCacheView(repository: repository)
                    .environmentObject(store)
            }
    }
}

private struct DependencyCacheView: View {
    @EnvironmentObject private var store: DevSweepStore
    @Environment(\.dismiss) private var dismiss
    @State private var preview: DependencyCachePreview?
    @State private var entriesByStatus: [DependencyCacheStatus: [DependencyCacheEntry]] = [:]
    @State private var status: DependencyCacheStatus = .cleanable
    @State private var query = ""
    @State private var selected: Set<String> = []
    @State private var showSelectedOnly = false
    @State private var includeReview = false
    @State private var loading = true
    @State private var revision = 0
    @State private var showingConfirmation = false
    @State private var loadError: String?
    @State private var outcome: String?
    @State private var failures: [String] = []
    let repository: DependencyRepository

    private var visibleEntries: [DependencyCacheEntry] {
        if showSelectedOnly { return selection }
        let entries = entriesByStatus[status] ?? []
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !search.isEmpty else { return entries }
        return entries.filter {
            $0.name.localizedStandardContains(search) || $0.version?.localizedStandardContains(search) == true
                || $0.reason.localizedStandardContains(search)
        }
    }

    private var selection: [DependencyCacheEntry] {
        (preview?.entries ?? []).filter { selected.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(repository.name).font(.title2.weight(.semibold))
                    Text(repository.root.devSweepDisplayPath)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                Button("刷新") { revision += 1 }
                    .disabled(loading || store.isCleaning)
            }
            Picker("保护状态", selection: $status) {
                ForEach(DependencyCacheStatus.allCases) { option in
                    let entries = entriesByStatus[option] ?? []
                    Text("\(option.rawValue) \(entries.count) · \(totalSize(entries))").tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(showSelectedOnly)

            if let loadError {
                Text(loadError).foregroundStyle(.red)
            }
            if let outcome {
                Text(outcome).font(.callout).foregroundStyle(.secondary)
            }
            if !failures.isEmpty {
                DisclosureGroup("查看失败详情") {
                    ScrollView {
                        Text(failures.joined(separator: "\n"))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 96)
                }
            }

            HStack {
                TextField("搜索包名、版本或来源", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .disabled(showSelectedOnly)
                Button("全选可清理") {
                    selected.formUnion(visibleEntries.map(\.id))
                }
                .disabled(loading || store.isCleaning || showSelectedOnly || status != .cleanable || visibleEntries.isEmpty)
                Button("取消全部勾选") { selected.removeAll() }
                    .disabled(selected.isEmpty || store.isCleaning)
                Toggle("只看已选", isOn: $showSelectedOnly)
            }

            if status == .review && !showSelectedOnly {
                HStack {
                    Toggle("允许选择来源待确认的包", isOn: $includeReview)
                    Spacer()
                    Button("全选待确认") {
                        selected.formUnion(visibleEntries.filter(\.canManuallySelect).map(\.id))
                    }
                    .disabled(!includeReview || loading || store.isCleaning
                              || !visibleEntries.contains(where: \.canManuallySelect))
                }
                .disabled(store.isCleaning)
                Text("先将需要保留的私有包加入白名单，再勾选确认可重新下载的版本。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            List(visibleEntries) { entry in
                entryRow(entry)
            }
            .overlay {
                if loading {
                    ProgressView("正在检查缓存…")
                } else if visibleEntries.isEmpty, loadError == nil {
                    Text("没有匹配的条目").foregroundStyle(.secondary)
                }
            }

            HStack {
                Text("已选 \(selection.count) 项 · \(totalSize(selection))")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(store.isCleaning)
                Button("移入废纸篓…", role: .destructive) { showingConfirmation = true }
                    .disabled(loading || store.isCleaning || store.isScanning || selection.isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 660, idealWidth: 740, minHeight: 475, idealHeight: 560)
        .interactiveDismissDisabled(store.isCleaning)
        .confirmationDialog("将选中的 \(selection.count) 个版本移入废纸篓？",
                            isPresented: $showingConfirmation, titleVisibility: .visible) {
            Button("移入废纸篓", role: .destructive, action: clean)
            Button("取消", role: .cancel) {}
        } message: {
            Text("已选 \(totalSize(selection))。DevSweep 会再次检查白名单、Git 跟踪状态与文件身份。")
        }
        .task(id: revision) { await refresh() }
        .onChange(of: store.dependencyProtectionRules) { _ in updateStatuses() }
        .onChange(of: store.whitelistedPaths) { _ in updateStatuses() }
        .onChange(of: includeReview) { _ in updateStatuses() }
    }

    @ViewBuilder
    private func entryRow(_ entry: DependencyCacheEntry) -> some View {
        let effectiveStatus = showSelectedOnly ? entry.status : status
        HStack(spacing: 10) {
            Toggle("选择 \(entry.name)", isOn: Binding(
                get: { selected.contains(entry.id) },
                set: { checked in
                    if checked { selected.insert(entry.id) } else { selected.remove(entry.id) }
                }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)
            .disabled(store.isCleaning || loading || effectiveStatus == .protected
                      || (effectiveStatus == .review && (!includeReview || !entry.canManuallySelect)))
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name).font(.body.weight(.medium))
                Text([entry.version, effectiveStatus != entry.status ? "白名单保护" : entry.reason]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .help(entry.path.devSweepDisplayPath)
            Spacer()
            Text(entry.size.devSweepFileSize).monospacedDigit().foregroundStyle(.secondary)
            if let name = entry.package, let rule = DependencyProtectionRule(manager: repository.manager, value: name) {
                Menu {
                    Button("保护 \(name)") { store.addDependencyProtectionRule(rule) }
                    if let groupRule = namespaceRule(for: name) {
                        Button("保护 \(groupRule.value) 下的所有包") { store.addDependencyProtectionRule(groupRule) }
                    }
                } label: {
                    Label("加入白名单", systemImage: "checkmark.shield")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(store.isCleaning || store.dependencyProtectionRules.contains(rule))
            }
        }
    }

    private func namespaceRule(for name: String) -> DependencyProtectionRule? {
        let separator: Character = repository.manager == .yarn ? "/" : ":"
        let parts = name.split(separator: separator, maxSplits: 1)
        guard parts.count == 2, let prefix = parts.first else { return nil }
        return DependencyProtectionRule(manager: repository.manager, value: String(prefix))
    }

    private func totalSize(_ entries: [DependencyCacheEntry]) -> String {
        entries.reduce(Int64(0)) { $0 + $1.size }.devSweepFileSize
    }

    private func updateStatuses() {
        let rules = store.dependencyProtectionRules
        let paths = store.whitelistedPaths
        let entries = preview?.entries ?? []
        entriesByStatus = Dictionary(grouping: entries) { $0.status(in: repository, rules: rules, paths: paths) }
        let eligible = entriesByStatus[.cleanable, default: []] +
            (includeReview ? entriesByStatus[.review, default: []].filter(\.canManuallySelect) : [])
        selected.formIntersection(Set(eligible.map(\.id)))
        if selected.isEmpty { showSelectedOnly = false }
    }

    private func refresh() async {
        loading = true
        loadError = nil
        let repository = repository
        let worker = Task.detached(priority: .userInitiated) {
            Result { try DependencyCacheInspector.preview(repository) }
        }
        let result = await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
        guard !Task.isCancelled else { return }
        switch result {
        case .success(let value):
            preview = value
        case .failure(let error):
            preview = nil
            loadError = error.localizedDescription
        }
        selected.removeAll()
        updateStatuses()
        if entriesByStatus[status, default: []].isEmpty,
           let first = [DependencyCacheStatus.cleanable, .review, .protected].first(where: {
               !entriesByStatus[$0, default: []].isEmpty
           }) {
            status = first
        }
        loading = false
    }

    private func clean() {
        guard let preview else { return }
        store.cleanDependencyCache(preview: preview, ids: selected, includeReview: includeReview) { report in
            outcome = "已移入废纸篓 \(report.removed.count) 项 · \(totalSize(report.removed))"
            failures = report.failures.map { "\($0.0.name) \($0.0.version ?? "") · \($0.1)" }
            revision += 1
        }
    }
}

struct DependencyProtectionRulesView: View {
    @EnvironmentObject private var store: DevSweepStore
    @State private var manager = DependencyManager.yarn
    @State private var value = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("依赖保护规则").font(.headline)
            HStack {
                Picker("包管理器", selection: $manager) {
                    ForEach(DependencyManager.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                TextField(manager.ruleExample, text: $value)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button("添加", action: add)
                    .disabled(DependencyProtectionRule(manager: manager, value: value) == nil || store.isCleaning)
            }
            ForEach(store.dependencyProtectionRules) { rule in
                HStack {
                    Text(rule.manager.title).foregroundStyle(.secondary)
                    Text(rule.value).monospaced().textSelection(.enabled)
                    Spacer()
                    Button("移除") { store.removeDependencyProtectionRule(rule) }
                        .disabled(store.isCleaning)
                }
            }
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
    }

    private func add() {
        guard !store.isCleaning, let rule = DependencyProtectionRule(manager: manager, value: value) else { return }
        store.addDependencyProtectionRule(rule)
        value = ""
    }
}
