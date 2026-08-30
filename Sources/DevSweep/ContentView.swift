import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: DevSweepStore
    @EnvironmentObject private var updater: DevSweepSoftwareUpdater
    @State private var selectedCategory = "全部"
    @State private var onlySelected = false
    @State private var onlyLarge = false
    @State private var showingConfirmation = false
    @State private var showingError = false
    @State private var showingHelp = false
    @State private var showingSettings = false
    @State private var showingScanDetails = false
    @State private var pendingCleanupItems: [CacheItem] = []

    private let largeThreshold: Int64 = 1 * 1024 * 1024 * 1024

    private var visibleItems: [CacheItem] {
        store.items.filter { item in
            (selectedCategory == "全部" || item.category == selectedCategory) &&
            (!onlySelected || item.isSelected) &&
            (!onlyLarge || item.size >= largeThreshold)
        }
    }

    private var cleanupItems: [CacheItem] {
        CleanupSelection.selectedItems(from: store.items, visibleItems: visibleItems)
    }

    private var cleanupSize: Int64 {
        cleanupItems.reduce(0) { $0 + $1.size }
    }

    private var cleanupIncludesDocker: Bool {
        cleanupItems.contains { $0.kind == .dockerPrune }
    }

    private var pendingCleanupIncludesDocker: Bool {
        pendingCleanupItems.contains { $0.kind == .dockerPrune }
    }

    private var hasScanReport: Bool {
        store.lastReport != nil
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 240, ideal: 290, max: 360)
        } detail: {
            dashboard
        }
        .frame(minWidth: 1_040, minHeight: 700)
        .task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            if case .idle = updater.state {
                await updater.checkForUpdates()
            }
        }
        .onChange(of: store.lastError) { value in
            showingError = value != nil
        }
        .alert("部分项目未能清理", isPresented: $showingError) {
            Button("知道了") { store.clearError() }
        } message: {
            Text(store.lastError ?? "")
        }
        .sheet(isPresented: $showingHelp) {
            HelpView()
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
                .environmentObject(updater)
        }
        .sheet(isPresented: $showingScanDetails) {
            if let report = store.lastReport {
                ScanDetailsView(report: report)
            } else {
                Text("暂无扫描报告")
                    .frame(width: 520, height: 260)
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 34, height: 34)
                    .background(Color.accentColor.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("DevSweep")
                        .font(.headline.weight(.semibold))
                    Text("开发者空间清理")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 10)

            List(selection: $selectedCategory) {
                Section {
                    SidebarRow(
                        title: "全部项目",
                        subtitle: "所有可发现的开发者缓存",
                        icon: "sparkles",
                        size: store.totalSize
                    )
                    .tag("全部")
                }

                Section("分类") {
                    ForEach(store.categories, id: \.self) { category in
                        SidebarRow(
                            title: category,
                            subtitle: categorySubtitle(category),
                            icon: categoryIcon(category),
                            size: store.categorySize(category)
                        )
                        .tag(category)
                    }
                }
            }
            .listStyle(.sidebar)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Divider()
                HStack {
                    Circle()
                        .fill(.green)
                        .frame(width: 8, height: 8)
                    Text("白名单缓存 + 选定项目目录")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("已配置 \(store.projectRoots.count) 个项目根目录")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                if !store.whitelistedPaths.isEmpty {
                    Text("已忽略 \(store.whitelistedPaths.count) 个目录")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Text("文件默认移入废纸篓，可恢复")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .background(.regularMaterial)
        }
    }

    private var dashboard: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    overviewCard
                    projectScopeCard

                    if let report = store.lastReport, !store.isScanning {
                        scanSummaryCard(report)
                    }

                    toolbar

                    if store.isScanning {
                        scanningState
                    } else if visibleItems.isEmpty {
                        EmptyStateView(
                            selectedCategory: selectedCategory,
                            onlyLarge: onlyLarge,
                            hasScanReport: hasScanReport
                        )
                    } else {
                        LazyVStack(spacing: 10) {
                            ForEach(visibleItems) { item in
                                CacheItemRow(item: item) { item in
                                    pendingCleanupItems = [item]
                                    showingConfirmation = true
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: 980, alignment: .leading)
                .padding(.horizontal, 30)
                .padding(.top, 26)
                .padding(.bottom, 26)
                .frame(maxWidth: .infinity)
            }
            bottomBar
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .confirmationDialog(
            pendingCleanupItems.count == 1 ? "确认清理这一项？" : "确认清理选中的项目？",
            isPresented: $showingConfirmation,
            titleVisibility: .visible
        ) {
            Button(pendingCleanupIncludesDocker ? "执行清理" : "移入废纸篓", role: .destructive) {
                let ids = Set(pendingCleanupItems.map(\.id))
                pendingCleanupItems = []
                store.cleanSelected(ids: ids)
            }
            Button("取消", role: .cancel) {
                pendingCleanupItems = []
            }
        } message: {
            Text(
                pendingCleanupIncludesDocker
                    ? "将处理 \(pendingCleanupItems.count) 项，共 \(pendingCleanupItems.reduce(0) { $0 + $1.size }.devSweepFileSize)。Docker 资源会通过官方 CLI 直接清理，不能从废纸篓恢复；普通目录会移入废纸篓。"
                    : "将处理 \(pendingCleanupItems.count) 项，共 \(pendingCleanupItems.reduce(0) { $0 + $1.size }.devSweepFileSize)。运行中的模拟器、未登记目录和手动项目不会自动删除。"
            )
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(selectedCategory == "全部" ? "开发者垃圾清理" : selectedCategory)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                Text(store.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if store.isScanning || store.isCleaning {
                ProgressView()
                    .controlSize(.small)
            } else {
                Label("\(store.items.count) 项", systemImage: "square.stack.3d.up")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(.quaternary.opacity(0.55))
                    .clipShape(Capsule())
            }
            Button {
                showingSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.bordered)
            .help("设置和更新")
            Button {
                showingHelp = true
            } label: {
                Image(systemName: "questionmark.circle")
            }
            .buttonStyle(.bordered)
            .help("查看清理范围和安全说明")
            Button {
                store.scan()
            } label: {
                Label(
                    hasScanReport ? "重新扫描" : "开始扫描",
                    systemImage: hasScanReport ? "arrow.clockwise" : "play.fill"
                )
            }
            .buttonStyle(.bordered)
            .disabled(store.isScanning || store.isCleaning)
        }
        .controlSize(.large)
        .padding(.horizontal, 30)
        .padding(.vertical, 18)
    }

    private var overviewCard: some View {
        HStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Label("可回收空间", systemImage: "externaldrive.badge.minus")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(store.totalSize.devSweepFileSize)
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                Text(
                    !hasScanReport
                        ? "点击“开始扫描”查找可清理的开发者缓存和生成物"
                        : "扫描到 \(store.items.count) 个缓存或生成物，按占用从大到小排列"
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 20)
            Rectangle()
                .fill(Color.primary.opacity(0.12))
                .frame(width: 1, height: 64)
            VStack(alignment: .trailing, spacing: 6) {
                Label("当前选择", systemImage: "checkmark.circle")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(cleanupSize.devSweepFileSize)
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .foregroundStyle(.tint)
                Text("\(cleanupItems.count) 项待清理")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 22)
        .background(
            LinearGradient(
                colors: [Color.accentColor.opacity(0.14), Color.accentColor.opacity(0.04)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.accentColor.opacity(0.15))
        }
    }

    private var projectScopeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "folder.badge.gearshape")
                    .font(.title3)
                    .foregroundStyle(.orange)
                    .frame(width: 32, height: 32)
                    .background(Color.orange.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text("项目生成物扫描范围")
                        .font(.subheadline.weight(.semibold))
                    Text("自动识别 target、node_modules、.build、Pods、build、dist、.next 等目录")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button {
                    store.chooseProjectRoots()
                } label: {
                    Label("添加目录", systemImage: "plus")
                }
                .buttonStyle(.bordered)
            }

            Divider()

            if store.projectRoots.isEmpty {
                Text("未配置项目根目录；仍会扫描 Home 下的固定开发者缓存")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 44)
            } else {
                ForEach(store.projectRoots, id: \.path) { root in
                    HStack(spacing: 8) {
                        Image(systemName: "folder")
                            .foregroundStyle(.secondary)
                        Text(root.devSweepDisplayPath)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .help(root.path)
                        Spacer()
                        Button {
                            store.removeProjectRoot(root)
                        } label: {
                            Image(systemName: "xmark.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("移除此项目根目录")
                    }
                    .padding(.leading, 44)
                }
            }

            if !store.whitelistedPaths.isEmpty {
                Divider()
                Text("忽略名单")
                    .font(.subheadline.weight(.semibold))
                    .padding(.leading, 44)
                ForEach(store.whitelistedPaths, id: \.path) { path in
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.shield")
                            .foregroundStyle(.green)
                        Text(path.devSweepDisplayPath)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .help(path.path)
                        Spacer()
                        Button {
                            store.removeFromWhitelist(path)
                        } label: {
                            Image(systemName: "xmark.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("移出忽略名单")
                        .disabled(store.isScanning || store.isCleaning)
                    }
                    .padding(.leading, 44)
                }
            }

            HStack {
                Toggle("深度扫描项目目录", isOn: $store.deepScan)
                    .toggleStyle(.checkbox)
                Text(store.deepScan ? "会递归查找嵌套项目" : "只检查较浅层级，扫描更快")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("恢复默认目录") {
                    store.restoreDefaultProjectRoots()
                }
                .buttonStyle(.borderless)
            }
            .padding(.leading, 44)
        }
        .padding(18)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.08))
        }
    }

    private func scanSummaryCard(_ report: ScanReport) -> some View {
        HStack(spacing: 12) {
            Image(systemName: report.permissionFailures > 0 ? "exclamationmark.triangle" : "checkmark.seal")
                .font(.title3)
                .foregroundStyle(report.permissionFailures > 0 ? .orange : .green)
                .frame(width: 32, height: 32)
                .background((report.permissionFailures > 0 ? Color.orange : Color.green).opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text("扫描范围已确认")
                    .font(.subheadline.weight(.semibold))
                Text("本次扫描检查 \(report.checkedPaths) 个路径，命中 \(report.items.count) 项，跳过 \(report.skippedPaths) 个路径")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if report.permissionFailures > 0 {
                    Text("有 \(report.permissionFailures) 个路径无法读取，点击右侧查看原因")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            Button {
                showingScanDetails = true
            } label: {
                Label("查看详情", systemImage: "chevron.right")
            }
            .buttonStyle(.borderless)
        }
        .padding(16)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.08))
        }
    }

    private var scanningState: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
                .frame(height: 32)
            Text(store.statusMessage)
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: 760, minHeight: 24, maxHeight: 24)
            Text("已检查 \(store.scanProgress.checkedPaths) 个路径 · 命中 \(store.scanProgress.matchedPaths) 项 · 跳过 \(store.scanProgress.skippedPaths) 个路径")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: 760, minHeight: 18, maxHeight: 18)
            Text(store.scanProgress.currentPath.isEmpty ? " " : store.scanProgress.currentPath)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 760, minHeight: 34, maxHeight: 34)
                .opacity(store.scanProgress.currentPath.isEmpty ? 0 : 1)
                .help(store.scanProgress.currentPath)
        }
        .frame(maxWidth: .infinity, minHeight: 260, maxHeight: 260)
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Label("筛选", systemImage: "line.3.horizontal.decrease.circle")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            Divider()
                .frame(height: 20)
            Toggle("只看已选", isOn: $onlySelected)
                .toggleStyle(.checkbox)
            Toggle("只看大于 1 GB", isOn: $onlyLarge)
                .toggleStyle(.checkbox)
            Spacer()
            Text("显示 \(visibleItems.count) 项")
                .font(.caption)
                .foregroundStyle(.secondary)
            Menu {
                Button("全选当前分类") {
                    store.setAllSelected(true, category: selectedCategory == "全部" ? nil : selectedCategory)
                }
                Button("取消选择") {
                    store.setAllSelected(false, category: selectedCategory == "全部" ? nil : selectedCategory)
                }
            } label: {
                Label("选择", systemImage: "checkmark.circle")
            }
            .menuStyle(.borderlessButton)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.08))
        }
    }

    private var bottomBar: some View {
        HStack {
            Image(systemName: "checkmark.shield")
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text(cleanupItems.isEmpty ? "选择项目后开始清理" : "准备清理 \(cleanupItems.count) 项")
                    .font(.subheadline.weight(.medium))
                Text(cleanupIncludesDocker ? "包含 Docker 资源，执行后不可从废纸篓恢复" : "清理会优先移入废纸篓，不直接永久删除")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                pendingCleanupItems = cleanupItems
                showingConfirmation = true
            } label: {
                Label("清理当前页选中项目", systemImage: "trash")
            }
            .buttonStyle(.borderedProminent)
            .disabled(cleanupItems.isEmpty || store.isCleaning || store.isScanning)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(.regularMaterial)
    }

    private func categorySubtitle(_ category: String) -> String {
        let count = store.items.filter { $0.category == category }.count
        return "\(count) 项"
    }

    private func categoryIcon(_ category: String) -> String {
        switch category {
        case "Xcode": return "hammer"
        case "CoreSimulator", "XCTest": return "iphone.gen3"
        case "Rust / Tauri 项目": return "shippingbox"
        case "项目生成物", "Apple 项目", "Swift 项目": return "folder.badge.gearshape"
        case "Node.js 项目": return "shippingbox.fill"
        case "Flutter 项目": return "wand.and.stars"
        case "Python 项目": return "chevron.left.forwardslash.chevron.right"
        case "测试产物": return "checkmark.seal"
        case "包管理器": return "shippingbox.fill"
        case "语言工具链": return "chevron.left.forwardslash.chevron.right"
        case "AI/ML": return "brain"
        case "Docker": return "shippingbox"
        case "JVM": return "cup.and.saucer"
        case "IDE", "Android Studio": return "text.cursor"
        case "设计工具": return "paintbrush"
        default: return "externaldrive"
        }
    }
}

private struct SidebarRow: View {
    let title: String
    let subtitle: String
    let icon: String
    let size: Int64

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .frame(width: 20)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Text(size.devSweepFileSize)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

private struct CacheItemRow: View {
    @EnvironmentObject private var store: DevSweepStore
    let item: CacheItem
    let onClean: (CacheItem) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Toggle("", isOn: Binding(
                get: { item.isSelected },
                set: { store.setSelected(item.id, selected: $0) }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)
            .disabled(item.risk == .manual)

            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(item.risk.color)
                .frame(width: 32, height: 32)
                .background(item.risk.color.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(item.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    RiskBadge(risk: item.risk)
                }
                Text(item.details)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(item.path.path)
                if !item.note.isEmpty {
                    Text(item.note)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 4) {
                Text(item.size.devSweepFileSize)
                    .font(.subheadline.monospacedDigit().weight(.medium))
                Text(item.kind == .simulatorDevice ? "模拟器设备" : item.kind == .dockerPrune ? "Docker 资源" : "缓存目录")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(minWidth: 92, alignment: .trailing)
            Menu {
                Button {
                    store.addToWhitelist([item])
                } label: {
                    Label("加入白名单", systemImage: "checkmark.shield")
                }
                .disabled(store.isScanning || store.isCleaning)

                Button {
                    NSWorkspace.shared.open(item.path)
                } label: {
                    Label("打开文件夹", systemImage: "folder")
                }
                .disabled(item.kind == .dockerPrune || store.isScanning || store.isCleaning)

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(item.path.path, forType: .string)
                } label: {
                    Label("复制完整路径", systemImage: "doc.on.doc")
                }
                .disabled(store.isScanning || store.isCleaning)

                Divider()

                Button(role: .destructive) {
                    onClean(item)
                } label: {
                    Label("清理这一项", systemImage: "trash")
                }
                .disabled(item.risk == .manual || store.isScanning || store.isCleaning)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .help("操作")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.07))
        }
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var icon: String {
        switch item.kind {
        case .simulatorDevice: return "iphone.gen3"
        case .dockerPrune: return "shippingbox"
        case .trash:
            if item.category.contains("Xcode") || item.category == "XCTest" { return "hammer" }
            if item.category.contains("项目") { return "folder.badge.gearshape" }
            return "archivebox"
        }
    }
}

private struct RiskBadge: View {
    let risk: RiskLevel

    var body: some View {
        Text(risk.title)
            .font(.caption2.weight(.medium))
            .foregroundStyle(risk.color)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(risk.color.opacity(0.11))
            .clipShape(Capsule())
    }
}

private struct EmptyStateView: View {
    let selectedCategory: String
    let onlyLarge: Bool
    let hasScanReport: Bool

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 42))
                .foregroundStyle(.green)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
    }

    private var title: String {
        guard hasScanReport else { return "准备开始扫描" }
        return selectedCategory == "全部" ? "没有发现符合条件的项目" : "这个分类目前很干净"
    }

    private var message: String {
        guard hasScanReport else { return "点击右上角“开始扫描”，扫描完成后这里会显示可清理项目。" }
        return onlyLarge ? "当前筛选只显示大于 1 GB 的项目，可以关闭筛选查看较小缓存。" : "可以重新扫描，或添加一个项目根目录来查找嵌套生成物。"
    }
}

private struct ScanDetailsView: View {
    @Environment(\.dismiss) private var dismiss
    let report: ScanReport

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "waveform.path.ecg")
                    .font(.title)
                    .foregroundStyle(.tint)
                Text("扫描详情")
                    .font(.title2.weight(.bold))
                Spacer()
                Button("完成") { dismiss() }
            }
            Divider()
            Text("实际扫描的项目根目录")
                .font(.headline)
            if report.scannedRoots.isEmpty {
                Text("未配置项目根目录；本次只扫描固定开发者缓存。")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(report.scannedRoots, id: \.path) { root in
                    Label(root.devSweepDisplayPath, systemImage: "folder")
                        .font(.caption.monospaced())
                }
            }
            Text("扫描统计")
                .font(.headline)
            Text("检查 \(report.checkedPaths) 个路径 · 命中 \(report.items.count) 项 · 跳过 \(report.skippedPaths) 个路径 · 耗时 \(String(format: "%.1f", report.duration)) 秒")
                .foregroundStyle(.secondary)
            Divider()
            Text(report.diagnostics.isEmpty ? "没有发现权限或工具问题。" : "跳过/异常路径")
                .font(.headline)
            if report.diagnostics.isEmpty {
                Label("扫描范围完整", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 9) {
                        ForEach(report.diagnostics) { diagnostic in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(diagnostic.kind.title)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(diagnostic.kind == .inaccessible ? .orange : .secondary)
                                    Text(diagnostic.path.devSweepDisplayPath)
                                        .font(.caption.monospaced())
                                        .lineLimit(1)
                                }
                                Text(diagnostic.reason)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(width: 700, height: 560)
    }
}

struct HelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "checkmark.shield.fill")
                    .font(.title)
                    .foregroundStyle(.green)
                Text("DevSweep 安全说明")
                    .font(.title2.weight(.bold))
                Spacer()
                Button("完成") { dismiss() }
            }
            Divider()
            Text("为什么能扫到更多")
                .font(.headline)
            Text("DevSweep 同时扫描 Xcode 的 ModuleCache、SourcePackages、Preview、源码控制缓存，逐个识别 XCTest 克隆设备和 CoreSimulator 设备，并递归检查你配置的多个项目根目录。目录大小用 du 校准，扫描报告会显示真正检查过的范围和权限异常。")
                .foregroundStyle(.secondary)
            Text("扫描范围")
                .font(.headline)
            Text("只扫描白名单开发者路径，以及你主动添加的项目目录。项目目录只匹配生成物名称，不会把源码、照片、文档或 Docker 虚拟磁盘当作缓存。")
                .foregroundStyle(.secondary)
            Text("清理方式")
                .font(.headline)
            Text("普通缓存和 XCTest 克隆设备移入 macOS 废纸篓；CoreSimulator 设备使用 simctl 删除以保持设备注册一致；Docker 资源使用官方 CLI 清理且不可恢复。红色项目不会自动删除，橙色项目默认不勾选。")
                .foregroundStyle(.secondary)
            Text("开源参考")
                .font(.headline)
            Link("macOS-dev-cache-cleaner", destination: URL(string: "https://github.com/k-angama/macOS-dev-cache-cleaner")!)
            Link("CleanMyMac CLI", destination: URL(string: "https://github.com/MacPaw/cleanmymac-cli")!)
            Spacer()
        }
        .padding(24)
        .frame(width: 620, height: 680)
    }
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var updater: DevSweepSoftwareUpdater

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "gearshape.fill")
                    .font(.title)
                    .foregroundStyle(.tint)
                Text("设置")
                    .font(.title2.weight(.bold))
                Spacer()
                Button("完成") { dismiss() }
            }
            Divider()
            SoftwareUpdateView(updater: updater)
            Spacer()
        }
        .padding(24)
        .frame(width: 620, height: 500)
    }
}

private struct SoftwareUpdateView: View {
    @ObservedObject var updater: DevSweepSoftwareUpdater

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("在线更新")
                .font(.headline)
            Text("从 GitHub Releases 检查经过签名和 Apple 公证的 DevSweep 版本。")
                .foregroundStyle(.secondary)
            Text("当前版本：\(updater.currentVersion)")
                .font(.caption)
                .foregroundStyle(.tertiary)

            switch updater.state {
            case .idle:
                checkButton
            case .checking:
                progress("正在检查更新…")
            case .upToDate:
                Label("已是最新版本", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                checkButton
            case .available(let release):
                Label("发现新版本 \(release.version.description)", systemImage: "arrow.down.circle.fill")
                    .foregroundStyle(.tint)
                if !release.releaseNotes.isEmpty {
                    Text("更新说明")
                        .font(.subheadline.weight(.semibold))
                    Text(release.releaseNotes)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Text("安装后 DevSweep 会自动重启。仅接受经过 SHA-256、Developer ID 和 Gatekeeper 校验的安装包。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("下载并安装") {
                    Task { await updater.downloadAndInstall() }
                }
                .buttonStyle(.borderedProminent)
            case .downloading:
                progress("正在下载更新…")
            case .installing:
                progress("正在验证并准备安装…")
            case .failed(let failure):
                Label(failure.displayText, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                checkButton
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var checkButton: some View {
        Button("检查更新") {
            Task { await updater.checkForUpdates() }
        }
        .disabled(updater.state.isBusy)
    }

    private func progress(_ message: String) -> some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(message)
                .foregroundStyle(.secondary)
        }
    }
}
