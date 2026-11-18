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
    private struct CleanupPlan {
        let entries: [DependencyCacheEntry]
        let reviewCount: Int
        let retainedCount: Int
    }

    @EnvironmentObject private var store: DevSweepStore
    @Environment(\.dismiss) private var dismiss
    @State private var preview: DependencyCachePreview?
    @State private var entriesByStatus: [DependencyCacheStatus: [DependencyCacheEntry]] = [:]
    @State private var statusByID: [String: DependencyCacheStatus] = [:]
    @State private var status: DependencyCacheStatus = .cleanable
    @State private var query = ""
    @State private var selected: Set<String> = []
    @State private var showSelectedOnly = false
    @State private var loading = true
    @State private var revision = 0
    @State private var showingConfirmation = false
    @State private var pendingCleanup: CleanupPlan?
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
        let visible = visibleEntries
        let currentIDs = Set(visible.filter(isSelectable).map(\.id))
        let allCurrentSelected = !currentIDs.isEmpty && currentIDs.isSubset(of: selected)
        let selection = self.selection
        let packages = Set(selection.compactMap(\.package))
        let cleanupEntries = selection.filter {
            $0.permitsCleanup(status: effectiveStatus($0), includeReview: true)
        }
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

            HStack(spacing: 10) {
                TextField("搜索包名、版本或来源", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .disabled(showSelectedOnly)
                Button(allCurrentSelected ? "取消选择当前结果" : "全选当前结果") {
                    if allCurrentSelected {
                        selected.subtract(currentIDs)
                    } else {
                        selected.formUnion(currentIDs)
                    }
                }
                .disabled(loading || store.isCleaning || showSelectedOnly || currentIDs.isEmpty)
                Toggle("只看已选", isOn: $showSelectedOnly)
                    .disabled(selected.isEmpty)
            }

            if status != .protected || showSelectedOnly {
                Text("勾选包后可批量加入白名单。同一个包只添加一条规则，保护所有版本。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            List(visible) { entry in
                entryRow(entry)
            }
            .overlay {
                if loading {
                    ProgressView("正在检查缓存…")
                } else if visible.isEmpty, loadError == nil {
                    Text("没有匹配的条目").foregroundStyle(.secondary)
                }
            }

            HStack {
                Text("已选 \(selection.count) 个版本 · \(totalSize(selection))")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                if !selected.isEmpty {
                    Button("清空") { selected.removeAll() }
                        .buttonStyle(.borderless)
                        .disabled(store.isCleaning)
                }
                Spacer()
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(store.isCleaning)
                Button(packages.isEmpty ? "加入白名单" : "加入白名单（\(packages.count) 个包）") {
                    addSelectedToWhitelist(packages)
                }
                .buttonStyle(.borderedProminent)
                .disabled(loading || store.isCleaning || packages.isEmpty)
                Button("移入废纸篓…", role: .destructive) {
                    pendingCleanup = CleanupPlan(
                        entries: cleanupEntries,
                        reviewCount: cleanupEntries.filter { effectiveStatus($0) == .review }.count,
                        retainedCount: selection.count - cleanupEntries.count
                    )
                    showingConfirmation = true
                }
                .disabled(loading || store.isCleaning || store.isScanning || cleanupEntries.isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 660, idealWidth: 740, minHeight: 475, idealHeight: 560)
        .interactiveDismissDisabled(store.isCleaning)
        .confirmationDialog("确认移入废纸篓？", isPresented: $showingConfirmation,
                            titleVisibility: .visible, presenting: pendingCleanup) { plan in
            Button("移入废纸篓", role: .destructive) { clean(plan) }
            Button("取消", role: .cancel) {}
        } message: { plan in
            Text(cleanupMessage(plan))
        }
        .task(id: revision) { await refresh() }
        .onChange(of: store.dependencyProtectionRules) { _ in updateStatuses() }
        .onChange(of: store.whitelistedPaths) { _ in updateStatuses() }
        .onChange(of: selected.isEmpty) { if $0 { showSelectedOnly = false } }
    }

    @ViewBuilder
    private func entryRow(_ entry: DependencyCacheEntry) -> some View {
        let effectiveStatus = effectiveStatus(entry)
        HStack(spacing: 10) {
            Toggle("选择 \(entry.name)", isOn: Binding(
                get: { selected.contains(entry.id) },
                set: { checked in
                    if checked { selected.insert(entry.id) } else { selected.remove(entry.id) }
                }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)
            .disabled(store.isCleaning || loading || !isSelectable(entry))
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
            if let rule = entry.protectionRule(manager: repository.manager) {
                Menu {
                    Button("保护 \(rule.value)") { store.addDependencyProtectionRule(rule) }
                    if let groupRule = namespaceRule(for: rule.value) {
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
        let size = entries.reduce(Int64(0)) { $0 + $1.size }
        return size == 0 ? "0 KB" : size.devSweepFileSize
    }

    private func effectiveStatus(_ entry: DependencyCacheEntry) -> DependencyCacheStatus {
        statusByID[entry.id] ?? entry.status
    }

    private func isSelectable(_ entry: DependencyCacheEntry) -> Bool {
        entry.permitsSelection(status: effectiveStatus(entry))
    }

    private func updateStatuses() {
        let protection = DependencyProtectionIndex(manager: repository.manager, rules: store.dependencyProtectionRules)
        let paths = store.whitelistedPaths
        let entries = preview?.entries ?? []
        let statuses = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0.status(protection: protection, paths: paths)) })
        statusByID = statuses
        entriesByStatus = Dictionary(grouping: entries) { statuses[$0.id] ?? $0.status }
        selected = selected.filter { statuses[$0] != nil && statuses[$0] != .protected }
    }

    private func addSelectedToWhitelist(_ packages: Set<String>) {
        let rules = DependencyProtectionRule.forPackages(packages, manager: repository.manager)
        let count = store.addDependencyProtectionRules(rules)
        guard count > 0 else { return }
        outcome = "已将 \(count) 个包加入白名单"
        failures = []
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

    private func cleanupMessage(_ plan: CleanupPlan) -> String {
        var message = "将移入废纸篓 \(plan.entries.count) 个版本，共 \(totalSize(plan.entries))。"
        if plan.reviewCount > 0 {
            message += "其中 \(plan.reviewCount) 个版本的来源待确认。请确认仍可重新下载。"
        }
        if plan.retainedCount > 0 {
            message += "另外 \(plan.retainedCount) 个所选版本会保留。"
        }
        return message
    }

    private func clean(_ plan: CleanupPlan) {
        guard let preview else { return }
        store.cleanDependencyCache(preview: preview, ids: Set(plan.entries.map(\.id)), includeReview: plan.reviewCount > 0) { report in
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
