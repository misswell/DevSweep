import AppKit
import SwiftUI

/// A single compatibility point for the macOS 26 glass redesign.
///
/// `glassEffect` is only available on macOS 26, while DevSweep still supports
/// macOS 13 and older toolchains. The API also only exists in the macOS 26 SDK,
/// so building with an older Xcode fails even inside `#available`; the
/// compile-time check keeps the project buildable there and both paths share
/// the same material fallback.
private struct DevSweepSurfaceModifier: ViewModifier {
    let cornerRadius: CGFloat

    @ViewBuilder
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            content
                .glassEffect(
                    .regular,
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
        } else {
            materialSurface(content)
        }
        #else
        materialSurface(content)
        #endif
    }

    @ViewBuilder
    private func materialSurface(_ content: Content) -> some View {
        content
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.primary.opacity(0.08))
            }
    }
}

private extension View {
    func devSweepSurface(cornerRadius: CGFloat = 12) -> some View {
        modifier(DevSweepSurfaceModifier(cornerRadius: cornerRadius))
    }
}

/// The translucent layer applied above a material background on macOS 26.
/// Older SDKs and older systems simply get the material background unchanged.
private struct DevSweepGlassLayerModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            content.glassEffect(.regular)
        } else {
            content
        }
        #else
        content
        #endif
    }
}

private extension View {
    func devSweepGlassLayer() -> some View {
        modifier(DevSweepGlassLayerModifier())
    }
}

struct MiniModeWindowPlacement {
    static func expandedFrame(
        from miniFrame: CGRect,
        normalFrame: CGRect?,
        visibleFrame: CGRect,
        fallbackSize: CGSize = CGSize(width: 1_040, height: 700)
    ) -> CGRect {
        let requestedSize = normalFrame?.size ?? fallbackSize
        let width = min(max(requestedSize.width, 1), max(visibleFrame.width, 1))
        let height = min(max(requestedSize.height, 1), max(visibleFrame.height, 1))

        // Keep the edge closest to the screen center fixed while expanding away
        // from the edge where the mini window currently lives.
        let isOnRightSide = miniFrame.midX >= visibleFrame.midX
        let proposedX = isOnRightSide ? miniFrame.maxX - width : miniFrame.minX
        let proposedY = miniFrame.maxY - height
        let minX = visibleFrame.minX
        let maxX = visibleFrame.maxX - width
        let minY = visibleFrame.minY
        let maxY = visibleFrame.maxY - height

        return CGRect(
            x: min(max(proposedX, minX), maxX),
            y: min(max(proposedY, minY), maxY),
            width: width,
            height: height
        )
    }
}

/// Sidebar 不再用一个 `selectedCategory: String` 承担全部导航。
enum SidebarDestination: Hashable {
    case all
    case quickClean
    case whitelist
    case category(String)
}

struct ContentView: View {
    @EnvironmentObject private var store: DevSweepStore
    @EnvironmentObject private var updater: DevSweepSoftwareUpdater
    @State private var destination: SidebarDestination = .all
    @State private var onlySelected = false
    @State private var onlyQuickClean = false
    @State private var onlyLarge = false
    @State private var showingConfirmation = false
    @State private var showingQuickCleanHint = false
    @State private var showingError = false
    @State private var showingHelp = false
    @State private var showingSettings = false
    @State private var showingScanDetails = false
    @State private var pendingCleanupItems: [CacheItem] = []
    @State private var pendingQuickCleanItems: [CacheItem] = []
    @State private var savedNormalWindowFrame: NSRect?
    @AppStorage("DevSweep.miniMode") private var miniMode = false
    @AppStorage("DevSweep.quickCleanHintAcknowledged") private var quickCleanHintAcknowledged = false

    private let largeThreshold: Int64 = 1 * 1024 * 1024 * 1024

    private var showsCacheList: Bool {
        switch destination {
        case .all, .category: return true
        case .quickClean, .whitelist: return false
        }
    }

    /// 过滤器只决定「当前看到什么」，永远不影响清理范围。
    private var visibleItems: [CacheItem] {
        store.items.filter { item in
            let matchesCategory: Bool
            switch destination {
            case .all:
                matchesCategory = true
            case .category(let category):
                matchesCategory = item.category == category
            case .quickClean, .whitelist:
                matchesCategory = false
            }
            return matchesCategory
                && (!onlySelected || item.isSelected)
                && (!onlyQuickClean || store.isQuickClean(item))
                && (!onlyLarge || item.size >= largeThreshold)
        }
    }

    /// 清理范围永远等于 store.selectedCleanupItems，与当前页面和过滤器无关。
    private var selectedCleanupSize: Int64 {
        store.selectedCleanupItems.reduce(0) { $0 + $1.size }
    }

    private var selectedCleanupIncludesNonRecoverable: Bool {
        store.selectedCleanupItems.contains { $0.kind.isNonRecoverable }
    }

    private var pendingCleanupIncludesNonRecoverable: Bool {
        pendingCleanupItems.contains { $0.kind.isNonRecoverable }
    }

    private var hasScanReport: Bool {
        store.lastReport != nil
    }

    private var headerTitle: String {
        switch destination {
        case .all: return "开发者垃圾清理"
        case .quickClean: return "常用清理"
        case .whitelist: return "白名单"
        case .category(let category): return category
        }
    }

    var body: some View {
        Group {
            if miniMode {
                MiniModeView(
                    hasScanReport: hasScanReport,
                    onExit: exitMiniMode,
                    onCleanup: { items in
                        pendingCleanupItems = items
                        showingConfirmation = true
                    },
                    onAddToQuickClean: { requestAddToQuickClean([$0]) }
                )
            } else {
                NavigationSplitView {
                    sidebar
                        .navigationSplitViewColumnWidth(min: 240, ideal: 290, max: 360)
                } detail: {
                    dashboard
                }
                .frame(minWidth: 1_040, minHeight: 700)
            }
        }
        .overlay(alignment: .top) {
            if let notice = store.transientNotice {
                TransientNoticeView(notice: notice)
                    .padding(.top, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .id(notice.id)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: store.transientNotice)
        .confirmationDialog(
            pendingCleanupItems.count == 1 ? "确认清理这一项？" : "确认清理选中的项目？",
            isPresented: $showingConfirmation,
            titleVisibility: .visible
        ) {
            Button(pendingCleanupIncludesNonRecoverable ? "执行清理" : "移入废纸篓", role: .destructive) {
                let ids = Set(pendingCleanupItems.map(\.id))
                pendingCleanupItems = []
                store.cleanSelected(ids: ids)
            }
            Button("取消", role: .cancel) {
                pendingCleanupItems = []
            }
        } message: {
            Text(
                pendingCleanupIncludesNonRecoverable
                    ? "将处理 \(pendingCleanupItems.count) 项，共 \(pendingCleanupItems.reduce(0) { $0 + $1.size }.devSweepFileSize)。部分项目会通过开发工具自己的清理命令执行，不会进入废纸篓；普通目录会移入废纸篓。"
                    : "将处理 \(pendingCleanupItems.count) 项，共 \(pendingCleanupItems.reduce(0) { $0 + $1.size }.devSweepFileSize)。运行中的模拟器、未登记目录和手动项目不会自动删除。"
            )
        }
        .alert("加入常用清理？", isPresented: $showingQuickCleanHint) {
            Button("加入常用清理") {
                store.addToQuickClean(pendingQuickCleanItems)
                pendingQuickCleanItems = []
            }
            Button("加入并不再提示") {
                quickCleanHintAcknowledged = true
                store.addToQuickClean(pendingQuickCleanItems)
                pendingQuickCleanItems = []
            }
            Button("取消", role: .cancel) {
                pendingQuickCleanItems = []
            }
        } message: {
            Text("加入常用清理后，即使该目录被清理后重新生成，以后仍可从「常用清理」中直接一键清理。仅建议用于 node_modules、target、DerivedData 等可重新生成目录。")
        }
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

            List(selection: $destination) {
                Section("概览") {
                    SidebarRow(
                        title: "全部项目",
                        subtitle: "所有可发现的开发者缓存",
                        icon: "sparkles",
                        size: store.totalSize
                    )
                    .tag(SidebarDestination.all)
                    SidebarRow(
                        title: "常用清理",
                        subtitle: "\(store.quickCleanEntries.count) 个长期授权目录",
                        icon: "bolt.fill",
                        size: store.quickCleanSize
                    )
                    .tag(SidebarDestination.quickClean)
                    SidebarRow(
                        title: "白名单",
                        subtitle: "\(store.whitelistedPaths.count) 个永久保护目录",
                        icon: "checkmark.shield",
                        size: nil
                    )
                    .tag(SidebarDestination.whitelist)
                }

                Section("分类") {
                    ForEach(store.categories, id: \.self) { category in
                        SidebarRow(
                            title: category,
                            subtitle: categorySubtitle(category),
                            icon: categoryIcon(category),
                            size: store.categorySize(category)
                        )
                        .tag(SidebarDestination.category(category))
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
                    Text("普通清理移入废纸篓，可恢复")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("已配置 \(store.projectRoots.count) 个项目根目录")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text("常用清理 \(store.quickCleanEntries.count) 项 · 白名单 \(store.whitelistedPaths.count) 个目录")
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
            if showsCacheList {
                Divider()
                if store.isScanning && hasScanReport {
                    rescanBanner
                    Divider()
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch destination {
                    case .all, .category:
                        overviewCard
                        projectScopeCard

                        if let report = store.lastReport, !store.isScanning {
                            scanSummaryCard(report)
                        }

                        toolbar

                        if store.isScanning && !hasScanReport {
                            scanningState
                        } else if visibleItems.isEmpty {
                            EmptyStateView(
                                title: emptyStateTitle,
                                message: emptyStateMessage
                            )
                        } else {
                            LazyVStack(spacing: 10) {
                                ForEach(visibleItems) { item in
                                    CacheItemRow(item: item, onClean: onCleanSingleItem) { rowItem in
                                        requestAddToQuickClean([rowItem])
                                    }
                                }
                            }
                        }
                    case .quickClean:
                        QuickCleanPageView()
                    case .whitelist:
                        WhitelistPageView()
                    }
                }
                .frame(maxWidth: 980, alignment: .leading)
                .padding(.horizontal, 30)
                .padding(.top, 26)
                .padding(.bottom, 26)
                .frame(maxWidth: .infinity)
            }
            if showsCacheList {
                bottomBar
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .background {
            Color.clear.devSweepGlassLayer()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(headerTitle)
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
                enterMiniMode()
            } label: {
                Label("迷你", systemImage: "rectangle.compress.vertical")
            }
            .buttonStyle(.bordered)
            .help("切换到迷你模式")
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

    /// 重新扫描期间保留旧列表，只在顶部显示进度；勾选和清理操作暂时禁用。
    private var rescanBanner: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text("重新扫描中…")
                    .font(.subheadline.weight(.semibold))
                Text("已检查 \(store.scanProgress.checkedPaths) 个路径 · 命中 \(store.scanProgress.matchedPaths) 项")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("扫描完成前暂时禁用勾选与清理")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 10)
        .background(Color.accentColor.opacity(0.08))
    }

    private var emptyStateTitle: String {
        guard hasScanReport else { return "准备开始扫描" }
        if case .category = destination { return "这个分类目前很干净" }
        return "没有发现符合条件的项目"
    }

    private var emptyStateMessage: String {
        guard hasScanReport else {
            return "点击右上角“开始扫描”，扫描完成后这里会显示可清理项目。"
        }
        return onlyLarge
            ? "当前筛选只显示大于 1 GB 的项目，可以关闭筛选查看较小缓存。"
            : "可以重新扫描，或添加一个项目根目录来查找嵌套生成物。"
    }

    private func onCleanSingleItem(_ item: CacheItem) {
        pendingCleanupItems = [item]
        showingConfirmation = true
    }

    /// 第一次加入常用清理时出现一次安全说明，之后不再重复。
    private func requestAddToQuickClean(_ items: [CacheItem]) {
        if quickCleanHintAcknowledged {
            store.addToQuickClean(items)
            return
        }
        pendingQuickCleanItems = items
        showingQuickCleanHint = true
    }

    private func enterMiniMode() {
        if let window = activeDevSweepWindow() {
            savedNormalWindowFrame = window.frame
        }
        miniMode = true
    }

    private func exitMiniMode() {
        let window = activeDevSweepWindow()
        let miniFrame = window?.frame
        let normalFrame = savedNormalWindowFrame
        let fallbackSize = window.map {
            $0.frameRect(
                forContentRect: NSRect(
                    origin: .zero,
                    size: CGSize(width: 1_040, height: 700)
                )
            ).size
        } ?? CGSize(width: 1_040, height: 700)

        miniMode = false

        guard let window, let miniFrame else { return }

        // SwiftUI applies the full-mode content size on the next run loop. Apply
        // the placement after that update, and once more after its window resize
        // animation has settled so the window remains inside the visible frame.
        let applyPlacement = {
            guard let visibleFrame = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
            let targetFrame = MiniModeWindowPlacement.expandedFrame(
                from: miniFrame,
                normalFrame: normalFrame,
                visibleFrame: visibleFrame,
                fallbackSize: fallbackSize
            )
            window.setFrame(targetFrame, display: true, animate: true)
        }

        DispatchQueue.main.async {
            applyPlacement()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                applyPlacement()
            }
        }
    }

    private func activeDevSweepWindow() -> NSWindow? {
        if let keyWindow = NSApp.keyWindow, keyWindow.isVisible {
            return keyWindow
        }
        return NSApp.windows.first { $0.isVisible && $0.contentView != nil }
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
                Text(selectedCleanupSize.devSweepFileSize)
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .foregroundStyle(.tint)
                Text("\(store.selectedCleanupItems.count) 项待清理")
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
                .help(Text(verbatim: store.scanProgress.currentPath))
        }
        .frame(maxWidth: .infinity, minHeight: 260, maxHeight: 260)
    }

    /// 列表头 checkbox：□ 全未选 / − 部分已选 / ✓ 全部已选。
    private var visibleSelectionStateIcon: String {
        let selectable = visibleItems.filter { $0.risk != .manual }
        guard !selectable.isEmpty else { return "square" }
        if selectable.allSatisfy(\.isSelected) { return "checkmark.square.fill" }
        if selectable.contains(where: \.isSelected) { return "minus.square" }
        return "square"
    }

    private var allVisibleSelected: Bool {
        let selectable = visibleItems.filter { $0.risk != .manual }
        return !selectable.isEmpty && selectable.allSatisfy(\.isSelected)
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Button {
                store.setVisibleSelected(visibleItems, selected: !allVisibleSelected)
            } label: {
                Image(systemName: visibleSelectionStateIcon)
                    .font(.body.weight(.medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
            .disabled(visibleItems.isEmpty || store.isScanning || store.isCleaning)
            .help(allVisibleSelected ? "取消当前显示选择" : "全选当前显示")

            Label("筛选", systemImage: "line.3.horizontal.decrease.circle")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            Divider()
                .frame(height: 20)
            Toggle("只看已选", isOn: $onlySelected)
                .toggleStyle(.checkbox)
            Toggle("常用清理", isOn: $onlyQuickClean)
                .toggleStyle(.checkbox)
            Toggle("只看大于 1 GB", isOn: $onlyLarge)
                .toggleStyle(.checkbox)
            Spacer()
            Text("显示 \(visibleItems.count) 项 · 已选 \(store.selectedCleanupItems.count) 项")
                .font(.caption)
                .foregroundStyle(.secondary)
            Menu {
                Button("全选当前显示") {
                    store.setVisibleSelected(visibleItems, selected: true)
                }
                Button("取消当前显示选择") {
                    store.setVisibleSelected(visibleItems, selected: false)
                }
                Divider()
                Button {
                    requestAddToQuickClean(store.selectedCleanupItems)
                } label: {
                    Label("加入常用清理", systemImage: "bolt.fill")
                }
                Button {
                    store.addToWhitelist(store.selectedCleanupItems)
                } label: {
                    Label("加入白名单", systemImage: "checkmark.shield")
                }
            } label: {
                Label("操作", systemImage: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .disabled(store.isScanning || store.isCleaning)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .devSweepSurface(cornerRadius: 10)
    }

    private var bottomBar: some View {
        HStack {
            Image(systemName: "checkmark.shield")
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text(store.selectedCleanupItems.isEmpty
                    ? "选择项目后开始清理"
                    : "已选 \(store.selectedCleanupItems.count) 项 · \(selectedCleanupSize.devSweepFileSize)")
                    .font(.subheadline.weight(.medium))
                Text(selectedCleanupIncludesNonRecoverable
                    ? "包含官方工具或设备清理，执行后不可从废纸篓恢复"
                    : "普通目录将移入废纸篓，可随时恢复")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                pendingCleanupItems = store.selectedCleanupItems
                showingConfirmation = true
            } label: {
                Label("清理 \(store.selectedCleanupItems.count) 项", systemImage: "trash")
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.selectedCleanupItems.isEmpty || store.isCleaning || store.isScanning)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(.regularMaterial)
        .background {
            Color.clear.devSweepGlassLayer()
        }
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
        case "AI Agent": return "sparkles"
        case "Docker": return "shippingbox"
        case "JVM": return "cup.and.saucer"
        case "IDE", "Android Studio": return "text.cursor"
        case "设计工具": return "paintbrush"
        default: return "externaldrive"
        }
    }
}

/// 顶部短暂提示（1.5～2 秒自动消失），与常驻 statusMessage 分开。
private struct TransientNoticeView: View {
    let notice: TransientNotice

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: notice.icon)
                .foregroundStyle(notice.icon.hasPrefix("exclamation") ? Color.orange : Color.green)
            Text(notice.text)
                .font(.subheadline.weight(.medium))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .overlay {
            Capsule().stroke(Color.primary.opacity(0.08))
        }
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
    }
}

/// 常用清理页面：独立展示长期授权目录，不要求先完整扫描。
private struct QuickCleanPageView: View {
    @EnvironmentObject private var store: DevSweepStore

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            QuickCleanHeaderCard(
                cleanableCount: store.cleanableQuickCleanSnapshots.count,
                cleanableSize: store.quickCleanSize,
                isBusy: store.isCleaning || store.isScanning,
                onCleanAll: { store.cleanAllQuickClean() }
            )

            if store.quickCleanEntries.isEmpty {
                QuickCleanEmptyView()
            } else {
                VStack(spacing: 10) {
                    ForEach(store.quickCleanEntries) { entry in
                        QuickCleanEntryRow(
                            entry: entry,
                            snapshot: store.quickCleanSnapshots.first { $0.id == entry.id },
                            onClean: { store.cleanQuickClean([entry]) }
                        )
                    }
                }
            }
        }
        .onAppear {
            store.refreshQuickCleanSnapshots()
        }
    }
}

private struct QuickCleanHeaderCard: View {
    let cleanableCount: Int
    let cleanableSize: Int64
    let isBusy: Bool
    let onCleanAll: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "bolt.fill")
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 34, height: 34)
                .background(Color.accentColor.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text("你长期授权的可再生成目录")
                    .font(.subheadline.weight(.semibold))
                Text("这些目录清理后重新出现，仍可继续一键清理；全部通过废纸篓，可恢复。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 2) {
                Text("当前可清理")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("\(cleanableCount) 项 · \(cleanableSize.devSweepFileSize)")
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.tint)
            }
            Button {
                onCleanAll()
            } label: {
                Label("一键清理全部", systemImage: "bolt.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(cleanableCount == 0 || isBusy)
            .help("常用清理已代表长期授权，点击后直接移入废纸篓，不再二次确认")
        }
        .padding(16)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.08))
        }
    }
}

private struct QuickCleanEntryRow: View {
    @EnvironmentObject private var store: DevSweepStore
    let entry: QuickCleanEntry
    let snapshot: QuickCleanSnapshot?
    let onClean: () -> Void

    private var pathURL: URL {
        URL(fileURLWithPath: entry.path)
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder")
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 32, height: 32)
                .background(Color.accentColor.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.displayName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(pathURL.devSweepDisplayPath)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(Text(verbatim: entry.path))
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 4) {
                Text(statusText)
                    .font(.subheadline.monospacedDigit().weight(.medium))
                    .foregroundStyle(snapshot?.exists == true ? Color.primary : Color.secondary)
                Text(entry.dateAdded.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(minWidth: 110, alignment: .trailing)

            Button("清理") {
                onClean()
            }
            .buttonStyle(.bordered)
            .disabled(canClean == false)
            .help("直接移入废纸篓")

            Menu {
                Button {
                    store.removeFromQuickClean(entry)
                } label: {
                    Label("移出常用清理", systemImage: "bolt.slash")
                }
                .disabled(store.isScanning || store.isCleaning)

                Divider()

                Button {
                    NSWorkspace.shared.open(pathURL)
                } label: {
                    Label("打开文件夹", systemImage: "folder")
                }
                .disabled(snapshot?.exists != true)

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entry.path, forType: .string)
                } label: {
                    Label("复制完整路径", systemImage: "doc.on.doc")
                }
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
    }

    private var canClean: Bool {
        guard let snapshot, snapshot.exists, snapshot.fileIdentity != nil else { return false }
        return !store.isScanning && !store.isCleaning
    }

    private var statusText: String {
        guard let snapshot else { return "检查中…" }
        return snapshot.exists ? snapshot.size.devSweepFileSize : "当前无内容"
    }
}

private struct QuickCleanEmptyView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "bolt.slash")
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
            Text("还没有常用清理目录")
                .font(.headline)
            Text("在扫描结果中找到 node_modules、target、DerivedData 等可重新生成目录，点 ⋯ 选择「加入常用清理」。之后即使目录被清理后重新生成，也可以在这里一键清理。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 560)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
        .padding(.top, 20)
    }
}

/// 白名单页面：这些目录永远不会出现在清理结果中。
private struct WhitelistPageView: View {
    @EnvironmentObject private var store: DevSweepStore

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.title3)
                    .foregroundStyle(.green)
                    .frame(width: 34, height: 34)
                    .background(Color.green.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text("这些目录不会出现在清理结果中")
                        .font(.subheadline.weight(.semibold))
                    Text("即使再次扫描也不会被清理；移出白名单后会立即恢复最近一次扫描结果。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Text("\(store.whitelistedPaths.count) 个目录")
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .background(.background)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.primary.opacity(0.08))
            }

            if store.whitelistedPaths.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.shield")
                        .font(.system(size: 42))
                        .foregroundStyle(.secondary)
                    Text("白名单是空的")
                        .font(.headline)
                    Text("在扫描结果的 ⋯ 菜单中选择「加入白名单」，被保护的目录会立即从清理结果中消失。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 560)
                }
                .frame(maxWidth: .infinity, minHeight: 220)
                .padding(.top, 20)
            } else {
                VStack(spacing: 10) {
                    ForEach(store.whitelistedPaths, id: \.path) { path in
                        WhitelistRow(path: path) {
                            store.removeFromWhitelist(path)
                        }
                    }
                }
            }
        }
    }
}

private struct WhitelistRow: View {
    @EnvironmentObject private var store: DevSweepStore
    let path: URL
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
            Text(path.devSweepDisplayPath)
                .font(.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(Text(verbatim: path.path))
            Spacer(minLength: 8)
            Button("移出") {
                onRemove()
            }
            .buttonStyle(.bordered)
            .disabled(store.isScanning || store.isCleaning)
            .help("移出白名单后立即恢复最近一次扫描结果")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.07))
        }
    }
}

private struct MiniModeView: View {
    @EnvironmentObject private var store: DevSweepStore

    let hasScanReport: Bool
    let onExit: () -> Void
    let onCleanup: ([CacheItem]) -> Void
    let onAddToQuickClean: (CacheItem) -> Void

    /// Mini 模式与普通模式使用同一个清理范围计算，切换模式不改变执行内容。
    private var cleanupItems: [CacheItem] {
        store.selectedCleanupItems
    }

    private var cleanupSize: Int64 {
        cleanupItems.reduce(0) { $0 + $1.size }
    }

    private var cleanupIncludesNonRecoverable: Bool {
        cleanupItems.contains { $0.kind.isNonRecoverable }
    }

    var body: some View {
        VStack(spacing: 0) {
            miniHeader
            Divider()
            mainContent
            miniBottomBar
        }
        .frame(width: 360, height: 640)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var miniHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
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
                    Text("迷你模式")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Button {
                    onExit()
                } label: {
                    Image(systemName: "rectangle.expand.vertical")
                }
                .buttonStyle(.borderless)
                .help("返回完整模式")
            }

            HStack(spacing: 8) {
                Label(
                    hasScanReport ? "\(store.items.count) 项" : "尚未扫描",
                    systemImage: "square.stack.3d.up"
                )
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                Spacer(minLength: 8)
                if store.isScanning || store.isCleaning {
                    ProgressView()
                        .controlSize(.small)
                    Text(store.statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("\(cleanupItems.count) 项待清理")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var mainContent: some View {
        Group {
            if store.isScanning && !hasScanReport {
                scanningState
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    summary
                    HStack(spacing: 8) {
                        Text("缓存项目")
                            .font(.subheadline.weight(.semibold))
                        Spacer(minLength: 8)
                        Text("\(store.items.count) 项")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    if store.items.isEmpty {
                        emptyState
                    } else {
                        itemList
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "externaldrive.badge.minus")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 42, height: 42)
                    .background(Color.accentColor.opacity(0.13))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("可回收空间")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(store.totalSize.devSweepFileSize)
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
                Spacer(minLength: 8)
            }

            Divider()
                .opacity(0.65)

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("待清理")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(cleanupItems.count) 项")
                        .font(.subheadline.weight(.semibold))
                }
                Spacer(minLength: 8)
                Text(cleanupSize.devSweepFileSize)
                    .font(.title3.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            if !hasScanReport {
                Text("点击下方“扫描”查找开发者缓存和生成物")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(16)
        .background(
            LinearGradient(
                colors: [Color.accentColor.opacity(0.16), Color.accentColor.opacity(0.05)],
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

    private var itemList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(store.items) { item in
                    MiniItemRow(item: item, onAddToQuickClean: onAddToQuickClean)
                }
            }
            .padding(.bottom, 2)
        }
        .scrollIndicators(.automatic)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var scanningState: some View {
        VStack(spacing: 10) {
            Spacer(minLength: 0)
            Image(systemName: "magnifyingglass.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.tint)
            ProgressView()
                .controlSize(.large)
            Text(store.statusMessage)
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text("已检查 \(store.scanProgress.checkedPaths) 个路径 · 命中 \(store.scanProgress.matchedPaths) 项 · 跳过 \(store.scanProgress.skippedPaths) 个")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
            if !store.scanProgress.currentPath.isEmpty {
                Text(store.scanProgress.currentPath)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .help(Text(verbatim: store.scanProgress.currentPath))
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 0)
            Image(systemName: hasScanReport ? "checkmark.circle" : "sparkles")
                .font(.system(size: 34))
                .foregroundStyle(.green)
            Text(hasScanReport ? "没有可清理项目" : "准备开始扫描")
                .font(.headline)
            Text(hasScanReport ? "当前扫描范围内没有符合条件的项目" : "点击下方“扫描”查找开发者缓存和生成物")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .minimumScaleFactor(0.85)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var miniBottomBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Menu {
                    Button("全选当前显示") {
                        store.setVisibleSelected(store.items, selected: true)
                    }
                    Button("取消当前显示选择") {
                        store.setVisibleSelected(store.items, selected: false)
                    }
                } label: {
                    Label("选择", systemImage: "checkmark.circle")
                }
                .menuStyle(.borderlessButton)
                .help("选择项目")
                .disabled(store.items.isEmpty || store.isScanning || store.isCleaning)

                Spacer(minLength: 8)

                Text(cleanupItems.isEmpty ? "未选择项目" : "已选 \(cleanupItems.count) 项")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            HStack(spacing: 8) {
                Button {
                    store.scan()
                } label: {
                    Label(
                        hasScanReport ? "重新扫描" : "扫描",
                        systemImage: hasScanReport ? "arrow.clockwise" : "play.fill"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(store.isScanning || store.isCleaning)

                Button {
                    onCleanup(cleanupItems)
                } label: {
                    Label("清理", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(cleanupItems.isEmpty || store.isScanning || store.isCleaning)
            }

            Text(
                cleanupItems.isEmpty
                    ? "扫描后选择项目即可清理"
                    : cleanupIncludesNonRecoverable
                        ? "官方工具或设备资源清理后不可恢复"
                        : "普通目录会优先移入废纸篓"
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
        }
        .controlSize(.regular)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.regularMaterial)
    }
}

private struct MiniItemRow: View {
    @EnvironmentObject private var store: DevSweepStore
    let item: CacheItem
    let onAddToQuickClean: (CacheItem) -> Void

    private var isQuickClean: Bool {
        store.isQuickClean(item)
    }

    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(
                get: { item.isSelected },
                set: { store.setSelected(item.id, selected: $0) }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)
            .disabled(item.risk == .manual || store.isScanning || store.isCleaning)

            Circle()
                .fill(item.risk.color)
                .frame(width: 7, height: 7)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(item.name)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    if isQuickClean {
                        Image(systemName: "bolt.fill")
                            .font(.caption2)
                            .foregroundStyle(.tint)
                            .help("已加入常用清理")
                    }
                }
                Text(item.details)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(Text(verbatim: item.path.path))
            }
            Spacer(minLength: 8)
            Text(item.size.devSweepFileSize)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .contextMenu {
            if isQuickClean {
                Button {
                    store.removeFromQuickClean(paths: [item.path])
                } label: {
                    Label("移出常用清理", systemImage: "bolt.slash")
                }
            } else {
                Button {
                    onAddToQuickClean(item)
                } label: {
                    Label("加入常用清理", systemImage: "bolt.fill")
                }
                .disabled(item.kind != .trash || item.risk == .manual)
            }
            Button {
                store.addToWhitelist([item])
            } label: {
                Label("加入白名单", systemImage: "checkmark.shield")
            }
            Divider()
            Button {
                NSWorkspace.shared.open(item.path)
            } label: {
                Label("打开文件夹", systemImage: "folder")
            }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.path.path, forType: .string)
            } label: {
                Label("复制路径", systemImage: "doc.on.doc")
            }
        }
    }
}

private struct SidebarRow: View {
    let title: String
    let subtitle: String
    let icon: String
    let size: Int64?

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
            if let size {
                Text(size.devSweepFileSize)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct CacheItemRow: View {
    @EnvironmentObject private var store: DevSweepStore
    let item: CacheItem
    let onClean: (CacheItem) -> Void
    let onAddToQuickClean: (CacheItem) -> Void

    private var isQuickClean: Bool {
        store.isQuickClean(item)
    }

    private var actionsDisabled: Bool {
        store.isScanning || store.isCleaning
    }

    var body: some View {
        HStack(spacing: 12) {
            Toggle("", isOn: Binding(
                get: { item.isSelected },
                set: { store.setSelected(item.id, selected: $0) }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)
            .disabled(item.risk == .manual || actionsDisabled)

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
                    // Badge 顺序：风险 → 常用清理。XCTest clone 等动态状态项
                    // 用自己的状态文字（可安全清理 / 正在测试 / 无法确认状态）。
                    RiskBadge(title: item.statusTitle ?? item.risk.title, color: item.risk.color)
                    if isQuickClean {
                        QuickCleanBadge()
                    }
                }
                Text(item.details)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(Text(verbatim: item.path.path))
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
                Text(itemKindTitle)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(minWidth: 92, alignment: .trailing)
            Menu {
                if isQuickClean {
                    Button {
                        store.removeFromQuickClean(paths: [item.path])
                    } label: {
                        Label("移出常用清理", systemImage: "bolt.slash")
                    }
                    .disabled(actionsDisabled)
                } else {
                    Button {
                        onAddToQuickClean(item)
                    } label: {
                        Label("加入常用清理", systemImage: "bolt.fill")
                    }
                    .disabled(item.kind != .trash || item.risk == .manual || actionsDisabled)
                }

                Button {
                    store.addToWhitelist([item])
                } label: {
                    Label("加入白名单", systemImage: "checkmark.shield")
                }
                .disabled(actionsDisabled)

                Divider()

                Button {
                    NSWorkspace.shared.open(item.path)
                } label: {
                    Label("打开文件夹", systemImage: "folder")
                }
                .disabled(item.kind == .dockerPrune || actionsDisabled)

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(item.path.path, forType: .string)
                } label: {
                    Label("复制完整路径", systemImage: "doc.on.doc")
                }
                .disabled(actionsDisabled)

                Divider()

                Button(role: .destructive) {
                    onClean(item)
                } label: {
                    Label("清理这一项", systemImage: "trash")
                }
                .disabled(item.risk == .manual || actionsDisabled)
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
        case .toolCommand: return "wrench.and.screwdriver"
        case .requestLogTrim: return "cylinder.split.1x2"
        case .trash:
            if item.category.contains("Xcode") || item.category == "XCTest" { return "hammer" }
            if item.category.contains("项目") { return "folder.badge.gearshape" }
            if item.category == "AI Agent" { return "sparkles" }
            return "archivebox"
        }
    }

    private var itemKindTitle: String {
        switch item.kind {
        case .simulatorDevice: return "模拟器设备"
        case .dockerPrune: return "Docker 资源"
        case .toolCommand: return "官方清理命令"
        case .requestLogTrim: return "就地裁剪日志"
        case .trash: return "缓存目录"
        }
    }
}

/// 常用清理标识：扁平、小尺寸、accent tint；不再使用已被大量占用的 sparkles。
private struct QuickCleanBadge: View {
    var body: some View {
        Label("常用清理", systemImage: "bolt.fill")
            .font(.caption2.weight(.medium))
            .foregroundStyle(.tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.accentColor.opacity(0.11))
            .clipShape(Capsule())
    }
}

private struct RiskBadge: View {
    let title: String
    let color: Color

    var body: some View {
        Text(title)
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(color.opacity(0.11))
            .clipShape(Capsule())
    }
}

private struct EmptyStateView: View {
    let title: String
    let message: String

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
                        .help(Text(verbatim: root.path))
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
                                        .truncationMode(.middle)
                                        .help(Text(verbatim: diagnostic.path.path))
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
            Text("四种状态")
                .font(.headline)
            Text("已选择：本次准备清理。常用清理：长期授权的可再生成目录，可随时一键清理。白名单：永远忽略，不允许清理。白名单保护优先于一切清理授权。")
                .foregroundStyle(.secondary)
            Text("清理方式")
                .font(.headline)
            Text("普通缓存和 XCTest 克隆设备移入 macOS 废纸篓；常用清理目录同样移入废纸篓且不再二次确认；CoreSimulator 设备使用 simctl 删除以保持设备注册一致；Docker 资源使用官方 CLI 清理且不可恢复。红色项目不会自动删除，橙色项目默认不勾选。")
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
