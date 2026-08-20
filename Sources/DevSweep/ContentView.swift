import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: DevSweepStore
    @State private var selectedCategory = "全部"
    @State private var onlySelected = false
    @State private var onlyLarge = false
    @State private var showingConfirmation = false
    @State private var showingError = false
    @State private var showingHelp = false
    @State private var showingScanDetails = false

    private let largeThreshold: Int64 = 1 * 1024 * 1024 * 1024

    private var visibleItems: [CacheItem] {
        store.items.filter { item in
            (selectedCategory == "全部" || item.category == selectedCategory) &&
            (!onlySelected || item.isSelected) &&
            (!onlyLarge || item.size >= largeThreshold)
        }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            dashboard
        }
        .frame(minWidth: 1_040, minHeight: 700)
        .task {
            if store.items.isEmpty { store.scan() }
        }
        .onChange(of: store.lastError) { value in
            showingError = value != nil
        }
        .onChange(of: store.deepScan) { _ in
            if !store.isScanning { store.scan() }
        }
        .alert("部分项目未能清理", isPresented: $showingError) {
            Button("知道了") { store.clearError() }
        } message: {
            Text(store.lastError ?? "")
        }
        .sheet(isPresented: $showingHelp) {
            HelpView()
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
        .navigationTitle("DevSweep")
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
                        EmptyStateView(selectedCategory: selectedCategory, onlyLarge: onlyLarge)
                    } else {
                        LazyVStack(spacing: 10) {
                            ForEach(visibleItems) { item in
                                CacheItemRow(item: item)
                            }
                        }
                    }
                }
                .padding(24)
            }
            bottomBar
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .confirmationDialog(
            "确认清理选中的项目？",
            isPresented: $showingConfirmation,
            titleVisibility: .visible
        ) {
            Button("移入废纸篓", role: .destructive) {
                store.cleanSelected()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将处理 \(store.selectedCount) 项，共 \(store.selectedSize.devSweepFileSize)。运行中的模拟器、未登记目录和手动项目不会自动删除。")
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
            Button {
                showingHelp = true
            } label: {
                Image(systemName: "questionmark.circle")
            }
            .buttonStyle(.borderless)
            .help("查看清理范围和安全说明")
            Button {
                store.scan()
            } label: {
                Label("重新扫描", systemImage: "arrow.clockwise")
            }
            .disabled(store.isScanning || store.isCleaning)
            .keyboardShortcut("r", modifiers: [.command])
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var overviewCard: some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("可回收空间")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(store.totalSize.devSweepFileSize)
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                Text("扫描到 \(store.items.count) 个缓存或生成物，按占用从大到小排列")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 8) {
                Text("当前选择")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(store.selectedSize.devSweepFileSize)
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .foregroundStyle(.tint)
                Text("\(store.selectedCount) 项")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(22)
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
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "folder.badge.gearshape")
                    .font(.title3)
                    .foregroundStyle(.orange)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 3) {
                    Text("项目生成物扫描范围")
                        .font(.subheadline.weight(.semibold))
                    Text("自动识别 target、node_modules、.build、Pods、build、dist、.next 等目录")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("添加目录") {
                    store.chooseProjectRoots()
                }
                .buttonStyle(.bordered)
            }

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
        .padding(14)
        .background(.quaternary.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func scanSummaryCard(_ report: ScanReport) -> some View {
        HStack(spacing: 12) {
            Image(systemName: report.permissionFailures > 0 ? "exclamationmark.triangle" : "checkmark.seal")
                .font(.title3)
                .foregroundStyle(report.permissionFailures > 0 ? .orange : .green)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text("扫描范围已确认")
                    .font(.subheadline.weight(.semibold))
                Text("检查 \(report.checkedPaths) 个路径，命中 \(report.items.count) 项，跳过 \(report.skippedPaths) 个路径")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if report.permissionFailures > 0 {
                    Text("有 \(report.permissionFailures) 个路径无法读取，点击右侧查看原因")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            Button("查看扫描详情") {
                showingScanDetails = true
            }
            .buttonStyle(.borderless)
        }
        .padding(14)
        .background(.quaternary.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var scanningState: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text(store.statusMessage)
                .font(.headline)
            Text("已检查 \(store.scanProgress.checkedPaths) 个路径 · 命中 \(store.scanProgress.matchedPaths) 项 · 跳过 \(store.scanProgress.skippedPaths) 个路径")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !store.scanProgress.currentPath.isEmpty {
                Text(store.scanProgress.currentPath)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 260)
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Toggle("只看已选", isOn: $onlySelected)
                .toggleStyle(.checkbox)
            Toggle("只看大于 1 GB", isOn: $onlyLarge)
                .toggleStyle(.checkbox)
            Button("全选当前分类") {
                store.setAllSelected(true, category: selectedCategory == "全部" ? nil : selectedCategory)
            }
            .buttonStyle(.borderless)
            Button("取消选择") {
                store.setAllSelected(false, category: selectedCategory == "全部" ? nil : selectedCategory)
            }
            .buttonStyle(.borderless)
            Spacer()
            Text("橙色项目删除前请确认；红色项目只提供说明")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var bottomBar: some View {
        HStack {
            Image(systemName: "checkmark.shield")
                .foregroundStyle(.green)
            Text("清理会优先移入废纸篓，不直接永久删除")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                showingConfirmation = true
            } label: {
                Label("清理选中项目", systemImage: "trash")
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.selectedCount == 0 || store.isCleaning || store.isScanning)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
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
        .padding(.vertical, 3)
    }
}

private struct CacheItemRow: View {
    @EnvironmentObject private var store: DevSweepStore
    let item: CacheItem

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
                if !item.note.isEmpty {
                    Text(item.note)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            Text(item.size.devSweepFileSize)
                .font(.subheadline.monospacedDigit().weight(.medium))
                .frame(minWidth: 78, alignment: .trailing)
        }
        .padding(14)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.07))
        }
    }

    private var icon: String {
        switch item.kind {
        case .simulatorDevice: return "iphone.gen3"
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

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 42))
                .foregroundStyle(.green)
            Text(selectedCategory == "全部" ? "没有发现符合条件的项目" : "这个分类目前很干净")
                .font(.headline)
            Text(onlyLarge ? "当前筛选只显示大于 1 GB 的项目，可以关闭筛选查看较小缓存。" : "可以重新扫描，或添加一个项目根目录来查找嵌套生成物。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
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
            Text("普通缓存和 XCTest 克隆设备移入 macOS 废纸篓；CoreSimulator 设备使用 simctl 删除以保持设备注册一致。红色项目不会自动删除，橙色项目默认不勾选。")
                .foregroundStyle(.secondary)
            Text("开源参考")
                .font(.headline)
            Link("macOS-dev-cache-cleaner", destination: URL(string: "https://github.com/k-angama/macOS-dev-cache-cleaner")!)
            Link("CleanMyMac CLI", destination: URL(string: "https://github.com/MacPaw/cleanmymac-cli")!)
            Spacer()
        }
        .padding(24)
        .frame(width: 620, height: 520)
    }
}
