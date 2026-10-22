import AppKit
import SwiftUI

enum DistributionChartMode: String, CaseIterable, Identifiable {
    case treemap
    case sunburst

    var id: String { rawValue }

    var title: String {
        switch self {
        case .treemap: return "矩形树图"
        case .sunburst: return "环形图"
        }
    }

    var symbolName: String {
        switch self {
        case .treemap: return "square.grid.2x2"
        case .sunburst: return "circle.dashed"
        }
    }
}

enum FileTypeMetric: String, CaseIterable, Identifiable {
    case bytes
    case count

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bytes: return "按占用"
        case .count: return "按数量"
        }
    }
}

/// 类型统计的范围。`recursive` 会额外遍历整棵子树，代价明显更高，由用户显式开启。
enum FileTypeScope: String, CaseIterable, Identifiable {
    case direct
    case recursive

    var id: String { rawValue }

    var title: String {
        switch self {
        case .direct: return "当前层"
        case .recursive: return "递归子树"
        }
    }

    var help: String {
        switch self {
        case .direct: return "只统计这一层展开后的条目，未展开的目录整体按「目录」计入。"
        case .recursive: return "遍历整个子树按扩展名汇总，包目录（.app、.xcarchive 等）整体归类，不重复累计父目录。"
        }
    }
}

/// 发现页条目与当前清理列表的关系。加入清理并不等于删除，执行前仍会重新验证。
enum DiscoveryCleanupLink: Equatable {
    case absent
    case present
    case selected
}

/// 文件分布面板：图表、类型统计和详情共用同一份 `DistributionSnapshot`。
/// 快照由 store 在扫描结果或搜索条件变化时构建一次，视图这里只做展示，
/// 选中、悬停这类状态变化不会重新排序整层目录。
/// 图表只把直接子项按占用布局，不会把父目录和子目录重复累计。
struct FileDistributionPanel: View {
    let nodes: [DiscoveryNode]
    let snapshot: DistributionSnapshot
    @Binding var searchText: String
    @Binding var selectedNodeID: String?
    @Binding var typeScope: FileTypeScope
    /// 祖先层（从靠近圆心向外），不含当前层；只有环形图使用。
    let ancestorLevels: [SunburstLevel]
    let rollup: FileTypeRollup?
    let isRollupRunning: Bool
    let rollupPhase: String?
    let isScanning: Bool
    let onDrillDown: (URL) -> Void
    let onIgnore: (DiscoveryNode) -> Void
    let onRunRollup: () -> Void
    let onCancelRollup: () -> Void
    let cleanupLink: (DiscoveryNode) -> DiscoveryCleanupLink
    let onAddToCleanup: (DiscoveryNode) -> Void

    @State private var mode: DistributionChartMode = .treemap
    @State private var typeMetric: FileTypeMetric = .bytes

    private var grouping: TreemapGrouping { snapshot.grouping }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            chartCard
            typeCard
        }
    }

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Label("文件分布", systemImage: "chart.bar.xaxis")
                    .font(.headline)
                totalText
                if isScanning {
                    Label("扫描进行中，当前为上一次结果", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Spacer()
                searchField
                Picker("图表类型", selection: $mode) {
                    ForEach(DistributionChartMode.allCases) { option in
                        Label(option.title, systemImage: option.symbolName).tag(option)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 176)
            }

            if grouping.isLowerBound {
                Label(
                    "含 \(grouping.lowerBoundCount) 项统计不完整，面积与角度只是已测量下限，不代表真实占比",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            HStack(alignment: .top, spacing: 16) {
                chartSection
                Divider()
                DistributionDetailPanel(
                    selectedNodeID: selectedNodeID,
                    items: grouping.items,
                    snapshot: snapshot,
                    nodes: nodes,
                    grouping: grouping,
                    onDrillDown: drillDown,
                    onIgnore: onIgnore,
                    cleanupLink: cleanupLink,
                    onAddToCleanup: onAddToCleanup,
                    onSelect: { selectedNodeID = $0 }
                )
                .frame(width: 300, height: 390)
            }

            chartFootnote
        }
        .padding(16)
        .background(.quaternary.opacity(0.2))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var totalText: some View {
        Text("\(snapshot.matchedCount) 项 · \(grouping.isLowerBound ? "≥ " : "")\(grouping.totalBytes.devSweepFileSize)")
            .font(.caption)
            .foregroundStyle(grouping.isLowerBound ? Color.orange : Color.secondary)
            .monospacedDigit()
    }

    private var chartSection: some View {
        Group {
            if grouping.items.isEmpty {
                chartPlaceholder
            } else {
                switch mode {
                case .treemap:
                    TreemapChartView(
                        items: grouping.items,
                        selectedNodeID: selectedNodeID,
                        onSelect: { selectedNodeID = $0 },
                        onDrillDown: drillDown
                    )
                case .sunburst:
                    SunburstChartView(
                        levels: sunburstLevels,
                        selectedNodeID: selectedNodeID,
                        onSelect: { selectedNodeID = $0 },
                        onDrillDown: drillDown
                    )
                }
            }
        }
        .frame(height: 330)
        .frame(maxWidth: .infinity)
        .background(Color.primary.opacity(0.035))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// 当前层作为最外圈；祖先层按从内到外排列。
    private var sunburstLevels: [SunburstLevel] {
        ancestorLevels + [SunburstLevel(items: grouping.items, enteredID: nil)]
    }

    private func drillDown(_ item: TreemapItem) {
        guard item.isDirectory, !item.isOther else { return }
        selectedNodeID = item.id
        onDrillDown(item.url)
    }

    private func drillDown(_ node: DiscoveryNode) {
        guard node.canNavigate else { return }
        selectedNodeID = node.id
        onDrillDown(node.path)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("搜索名称或路径", text: $searchText)
                .textFieldStyle(.plain)
                .font(.caption)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("清除搜索")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .frame(width: 210)
    }

    @ViewBuilder
    private var chartFootnote: some View {
        HStack(spacing: 12) {
            Text(mode == .treemap
                 ? "面积按分配大小计算，虚线边框表示只是下限"
                 : "角度按分配大小计算，内圈是上一层目录")
            if grouping.emptyCount > 0 {
                Text("\(grouping.emptyCount) 项无占用（0 B）")
                    .foregroundStyle(.secondary)
            }
            if grouping.unmeasuredCount > 0 {
                Label("\(grouping.unmeasuredCount) 项无法统计，未绘制" +
                      (selectedNodeID == nil ? "；点击右侧「诊断」查看" : ""),
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            if grouping.items.count > 1, grouping.items.contains(where: \.isOther) {
                Text("超出绘制上限的条目合并为「其他」，总量按真实大小计算")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .lineLimit(1)
    }

    private var chartPlaceholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(DiscoverySearch.trimmedQuery(searchText).isEmpty
                 ? "本层没有可绘制的占用数据"
                 : "没有匹配搜索的条目")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var typeCard: some View {
        let summaries = activeSummaries
        let totalMetric = summaries.reduce(Int64(0)) { $0 + metricValue(of: $1) }

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Label("文件类型分布", systemImage: "chart.pie")
                    .font(.headline)
                Text(typeScope.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(typeScope.help)
                if let rollupNote = rollup?.note, typeScope == .recursive {
                    Text(rollupNote)
                        .font(.caption)
                        .foregroundStyle(rollup?.isLowerBound == true ? Color.orange : Color.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if isRollupRunning {
                    ProgressView().controlSize(.small)
                    Button("取消") { onCancelRollup() }
                        .controlSize(.small)
                }
                Picker("统计范围", selection: $typeScope) {
                    ForEach(FileTypeScope.allCases) { scope in
                        Text(scope.title).tag(scope)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 150)
                Picker("统计方式", selection: $typeMetric) {
                    ForEach(FileTypeMetric.allCases) { metric in
                        Text(metric.title).tag(metric)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 150)
            }

            if summaries.isEmpty {
                recursivePlaceholder
            } else {
                VStack(spacing: 8) {
                    ForEach(summaries) { summary in
                        typeRow(
                            summary,
                            value: metricValue(of: summary),
                            total: totalMetric
                        )
                    }
                }
            }

            Text(typeFootnote)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background(.quaternary.opacity(0.18))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var activeSummaries: [FileTypeSummary] {
        let summaries: [FileTypeSummary]
        switch typeScope {
        case .direct: summaries = snapshot.typeSummaries
        case .recursive: summaries = rollup?.summaries ?? []
        }
        guard typeMetric == .count else { return summaries }
        return summaries.sorted { lhs, rhs in
            if lhs.itemCount != rhs.itemCount { return lhs.itemCount > rhs.itemCount }
            return lhs.allocatedBytes > rhs.allocatedBytes
        }
    }

    private var typeFootnote: String {
        switch typeScope {
        case .direct:
            return "目录未展开，整体按「目录」计入；类型只按扩展名判断，不代表可清理性。合计\(grouping.isLowerBound ? "含统计不完整条目，为下限" : "基于本层已测量数据")。"
        case .recursive:
            guard let rollup else {
                return "递归统计需要遍历整棵子树，代价高于当前层统计。"
            }
            return "已扫描 \(rollup.scannedEntries) 个条目：\(rollup.fileCount) 个文件、\(rollup.directoryCount) 个普通目录、\(rollup.packageCount) 个包目录；符号链接 \(rollup.symlinkCount) 个未跟随，跨卷 \(rollup.crossVolumeCount) 个未进入。包目录按整体归类，父目录不重复累计。"
        }
    }

    @ViewBuilder
    private var recursivePlaceholder: some View {
        if isRollupRunning {
            Label(rollupPhase ?? "正在递归统计…", systemImage: "hourglass")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 54)
        } else if typeScope == .recursive {
            VStack(alignment: .leading, spacing: 6) {
                Text("这一层还没有递归统计结果。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(rollup == nil ? "开始递归统计" : "重新递归统计") { onRunRollup() }
                    .controlSize(.small)
            }
            .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
        } else {
            Text("当前筛选下没有可统计的条目。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 54)
        }
    }

    private func metricValue(of summary: FileTypeSummary) -> Int64 {
        typeMetric == .bytes ? summary.allocatedBytes : Int64(summary.itemCount)
    }

    private func typeRow(_ summary: FileTypeSummary, value: Int64, total: Int64) -> some View {
        let fraction = total > 0 ? Double(value) / Double(total) : 0
        let bytesText = (summary.isLowerBound ? "≥ " : "") + summary.allocatedBytes.devSweepFileSize
        let valueText = typeMetric == .bytes ? bytesText : "\(summary.itemCount) 项"
        let percentText = String(format: "%.0f%%", fraction * 100)

        return HStack(spacing: 10) {
            Circle()
                .fill(summary.category.color)
                .frame(width: 8, height: 8)
            Image(systemName: summary.category.symbolName)
                .font(.caption2)
                .foregroundStyle(summary.category.color)
                .frame(width: 14)
            Text(summary.category.title)
                .font(.caption.weight(.medium))
                .frame(width: 86, alignment: .leading)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.06))
                    if fraction > 0 {
                        Capsule()
                            .fill(summary.category.color.opacity(0.72))
                            .frame(width: max(2, proxy.size.width * CGFloat(fraction)))
                    }
                }
            }
            .frame(height: 6)
            Text(valueText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(summary.isLowerBound ? Color.orange : Color.primary)
                .frame(width: 92, alignment: .trailing)
            Text(percentText)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
        }
        .help("""
        \(summary.category.title)：\(summary.itemCount) 项，\
        分配大小 \(bytesText)，逻辑大小 \(summary.logicalBytes.devSweepFileSize)\
        \(summary.isLowerBound ? "，其中 \(summary.lowerBoundCount) 项统计不完整" : "")
        """)
    }
}

/// 矩形树图画布。悬停状态只保存在本视图内：指针移动不会让父面板重新派生数据。
/// 绘制项已由分组上限截断，布局代价与目录大小无关。
private struct TreemapChartView: View {
    let items: [TreemapItem]
    let selectedNodeID: String?
    let onSelect: (String?) -> Void
    let onDrillDown: (TreemapItem) -> Void

    @State private var hovered: TreemapItem?

    var body: some View {
        GeometryReader { proxy in
            let rects = TreemapLayout.layout(items: items, in: proxy.size)
            Canvas { context, _ in
                draw(rects, in: &context)
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    let next = rects.first { $0.frame.contains(location) }?.item
                    if next?.id != hovered?.id { hovered = next }
                case .ended:
                    hovered = nil
                }
            }
            .gesture(
                SpatialTapGesture(count: 2).onEnded { value in
                    handleTap(at: value.location, rects: rects, drillDown: true)
                }
            )
            .simultaneousGesture(
                SpatialTapGesture(count: 1).onEnded { value in
                    handleTap(at: value.location, rects: rects, drillDown: false)
                }
            )
            .overlay(alignment: .topLeading) { hoverCaption }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("矩形树图，按占用显示当前目录内容")
        }
    }

    @ViewBuilder
    private var hoverCaption: some View {
        if let hovered {
            HStack(spacing: 6) {
                Text(hovered.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text((hovered.isLowerBound ? "≥ " : "") + hovered.bytes.devSweepFileSize)
                    .monospacedDigit()
                    .foregroundStyle(hovered.isLowerBound ? Color.orange : Color.secondary)
                if hovered.isOther {
                    Text("\(hovered.memberCount) 项")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.regularMaterial)
            .clipShape(Capsule())
            .padding(6)
            .allowsHitTesting(false)
        }
    }

    private func draw(_ rects: [TreemapRect], in context: inout GraphicsContext) {
        for rect in rects {
            let frame = rect.frame.insetBy(dx: 1, dy: 1)
            guard frame.width > 0.5, frame.height > 0.5 else { continue }

            let baseColor = rect.item.classification.color
            let isSelected = rect.item.id == selectedNodeID
            let isHovered = rect.item.id == hovered?.id
            let path = Path(
                roundedRect: frame,
                cornerRadius: min(4, min(frame.width, frame.height) / 3)
            )
            context.fill(path, with: .color(baseColor.opacity(isSelected ? 0.48 : isHovered ? 0.32 : 0.18)))
            // 虚线边框：这块面积只是已测量下限。
            context.stroke(
                path,
                with: .color(baseColor.opacity(isSelected || isHovered ? 0.95 : 0.42)),
                style: StrokeStyle(
                    lineWidth: isSelected ? 2 : 0.8,
                    dash: rect.item.isLowerBound ? [4, 3] : []
                )
            )

            guard frame.width > 64, frame.height > 30 else { continue }
            let name = abbreviated(rect.item.name, maxWidth: frame.width - 10)
            context.draw(
                Text(name)
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(.primary),
                at: CGPoint(x: frame.minX + 5, y: frame.minY + 5),
                anchor: .topLeading
            )
            if frame.height > 44 {
                context.draw(
                    Text((rect.item.isLowerBound ? "≥ " : "") + rect.item.bytes.devSweepFileSize)
                        .font(.caption2)
                        .foregroundColor(rect.item.isLowerBound ? .orange : .secondary),
                    at: CGPoint(x: frame.minX + 5, y: frame.minY + 20),
                    anchor: .topLeading
                )
            }
        }
    }

    private func handleTap(at location: CGPoint, rects: [TreemapRect], drillDown: Bool) {
        guard let rect = rects.first(where: { $0.frame.contains(location) }) else {
            if !drillDown { onSelect(nil) }
            return
        }
        if drillDown {
            onDrillDown(rect.item)
        } else {
            onSelect(rect.item.id)
        }
    }

    private func abbreviated(_ name: String, maxWidth: CGFloat) -> String {
        let limit = max(1, Int(maxWidth / 6.4))
        guard name.count > limit else { return name }
        return String(name.prefix(max(1, limit - 1))) + "…"
    }
}

/// 多层环形图。每层一段半径区间，子层扇区落在父层被展开图块的角度内。
private struct SunburstChartView: View {
    let levels: [SunburstLevel]
    let selectedNodeID: String?
    let onSelect: (String?) -> Void
    let onDrillDown: (TreemapItem) -> Void

    @State private var hovered: SunburstSector?

    private var outermostLevel: Int { max(0, levels.count - 1) }

    var body: some View {
        GeometryReader { proxy in
            let sectors = SunburstLayout.layout(levels: levels)
            Canvas { context, size in
                draw(sectors, size: size, in: &context)
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    let next = SunburstLayout.sector(at: location, in: proxy.size, sectors: sectors)
                    if next?.id != hovered?.id { hovered = next }
                case .ended:
                    hovered = nil
                }
            }
            .gesture(
                SpatialTapGesture(count: 2).onEnded { value in
                    handleTap(at: value.location, in: proxy.size, sectors: sectors, drillDown: true)
                }
            )
            .simultaneousGesture(
                SpatialTapGesture(count: 1).onEnded { value in
                    handleTap(at: value.location, in: proxy.size, sectors: sectors, drillDown: false)
                }
            )
            .overlay(alignment: .topLeading) { hoverCaption }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(levels.count > 1
                                ? "多层环形分布图，内圈是上一层目录"
                                : "环形分布图，按占用显示当前目录内容")
        }
    }

    @ViewBuilder
    private var hoverCaption: some View {
        if let hovered {
            HStack(spacing: 6) {
                Text("第 \(hovered.level + 1) 圈")
                    .foregroundStyle(.secondary)
                Text(hovered.item.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text((hovered.item.isLowerBound ? "≥ " : "") + hovered.item.bytes.devSweepFileSize)
                    .monospacedDigit()
                    .foregroundStyle(hovered.item.isLowerBound ? Color.orange : Color.secondary)
            }
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.regularMaterial)
            .clipShape(Capsule())
            .padding(6)
            .allowsHitTesting(false)
        }
    }

    private func draw(_ sectors: [SunburstSector], size: CGSize, in context: inout GraphicsContext) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = min(size.width, size.height) / 2

        for sector in sectors {
            let outerRadius = radius * sector.outerRadius
            let innerRadius = radius * sector.innerRadius
            guard outerRadius > innerRadius else { continue }

            var path = Path()
            path.addArc(
                center: center,
                radius: outerRadius,
                startAngle: .degrees(sector.startAngle - 90),
                endAngle: .degrees(sector.endAngle - 90),
                clockwise: false
            )
            path.addArc(
                center: center,
                radius: innerRadius,
                startAngle: .degrees(sector.endAngle - 90),
                endAngle: .degrees(sector.startAngle - 90),
                clockwise: true
            )
            path.closeSubpath()

            let baseColor = sector.item.classification.color
            let isSelected = sector.level == outermostLevel && sector.item.id == selectedNodeID
            let isHovered = hovered?.id == sector.id
            // 内圈只是上下文，用更淡的填充区分。
            let isAncestor = sector.level != outermostLevel
            let fillOpacity: Double = isSelected ? 0.5 : isHovered ? 0.34 : isAncestor ? 0.14 : 0.22
            context.fill(path, with: .color(baseColor.opacity(fillOpacity)))
            context.stroke(
                path,
                with: .color(baseColor.opacity(isSelected || isHovered ? 0.95 : 0.5)),
                style: StrokeStyle(
                    lineWidth: isSelected ? 2 : 0.8,
                    dash: sector.item.isLowerBound ? [4, 3] : []
                )
            )

            if sector.span >= 16, outerRadius - innerRadius > 26 {
                let point = SunburstLayout.point(
                    forAngle: sector.midAngle,
                    radiusFraction: (sector.innerRadius + sector.outerRadius) / 2,
                    in: size
                )
                context.draw(
                    Text(abbreviated(sector.item.name, maxCharacters: 9))
                        .font(.caption2.weight(.medium))
                        .foregroundColor(isAncestor ? .secondary : .primary),
                    at: point
                )
            }
        }

        let total = sectors.filter { $0.level == outermostLevel }.reduce(Int64(0)) { $0 + $1.item.bytes }
        let isLowerBound = sectors.contains { $0.level == outermostLevel && $0.item.isLowerBound }
        context.draw(
            Text((isLowerBound ? "≥ " : "") + total.devSweepFileSize)
                .font(.system(.headline, design: .rounded))
                .foregroundColor(isLowerBound ? .orange : .primary),
            at: CGPoint(x: center.x, y: center.y - 7)
        )
        context.draw(
            Text(levels.count > 1 ? "最外层占用" : "本层占用")
                .font(.caption2)
                .foregroundColor(.secondary),
            at: CGPoint(x: center.x, y: center.y + 11)
        )
    }

    private func handleTap(
        at location: CGPoint,
        in size: CGSize,
        sectors: [SunburstSector],
        drillDown: Bool
    ) {
        guard let sector = SunburstLayout.sector(at: location, in: size, sectors: sectors) else {
            if !drillDown { onSelect(nil) }
            return
        }
        if sector.level == outermostLevel {
            if drillDown {
                onDrillDown(sector.item)
            } else {
                onSelect(sector.item.id)
            }
            return
        }
        // 内圈单击即把该目录作为新的外层重新扫描，选中项随之下移一层。
        if sector.item.isDirectory {
            onDrillDown(sector.item)
        } else if !drillDown {
            onSelect(nil)
        }
    }

    private func abbreviated(_ name: String, maxCharacters: Int) -> String {
        guard name.count > maxCharacters else { return name }
        return String(name.prefix(max(1, maxCharacters - 1))) + "…"
    }
}

/// 右侧详情：单项、合并分组、以及无法统计条目的诊断。
private struct DistributionDetailPanel: View {
    let selectedNodeID: String?
    let items: [TreemapItem]
    let snapshot: DistributionSnapshot
    let nodes: [DiscoveryNode]
    let grouping: TreemapGrouping
    let onDrillDown: (DiscoveryNode) -> Void
    let onIgnore: (DiscoveryNode) -> Void
    let cleanupLink: (DiscoveryNode) -> DiscoveryCleanupLink
    let onAddToCleanup: (DiscoveryNode) -> Void
    let onSelect: (String) -> Void

    @State private var otherLimit = DistributionDetailPanel.defaultMemberPageSize
    @State private var otherQuery = ""

    static let defaultMemberPageSize = 50
    private static let maxMemberPages = 40

    var body: some View {
        let otherItem = items.first(where: \.isOther)
        return ScrollView(.vertical, showsIndicators: true) {
            Group {
                if let node = snapshot.node(for: selectedNodeID) {
                    nodeDetail(node)
                } else if let otherItem,
                          selectedNodeID == TreemapItem.otherID
                            || snapshot.otherContains(nodeID: selectedNodeID) {
                    otherDetail(otherItem)
                } else {
                    emptyDetail
                }
            }
            .padding(14)
            .onChange(of: selectedNodeID) { _ in
                otherLimit = Self.defaultMemberPageSize
                otherQuery = ""
            }
        }
        .background(.quaternary.opacity(0.14))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private var emptyDetail: some View {
        VStack(alignment: .leading, spacing: 10) {
            summaryHeader
            Divider()
            LabeledContent("本层条目", value: "\(snapshot.matchedCount) 项")
                .font(.caption)
            LabeledContent(
                "分配大小",
                value: (grouping.isLowerBound ? "≥ " : "") + grouping.totalBytes.devSweepFileSize
            )
            .font(.caption)
            if grouping.emptyCount > 0 {
                LabeledContent("无占用（0 B）", value: "\(grouping.emptyCount) 项")
                    .font(.caption)
            }
            if grouping.unmeasuredCount > 0 {
                unmeasuredSection
            }
            Text("未知、系统管理、开发环境和模型条目始终只读。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var summaryHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "cursorarrow.click.2")
                .font(.system(size: 24))
                .foregroundStyle(.secondary)
            Text("图表与列表共享同一份扫描结果")
                .font(.callout.weight(.semibold))
            Text("单击色块或列表行查看分类、识别依据和清理状态；双击目录进入下一级。搜索会同时过滤图表、类型统计和列表。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 无法统计的条目单独给出数量和逐条诊断，不与「0 B」混为一谈。
    private var unmeasuredSection: some View {
        let samples = DistributionMembers.unmeasured(in: nodes, query: otherQuery, limit: 20)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Label("无法统计 \(grouping.unmeasuredCount) 项", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                Spacer()
                TextField("筛选", text: $otherQuery)
                    .textFieldStyle(.plain)
                    .font(.caption2)
                    .frame(width: 70)
            }
            Text("这些条目没有可靠的占用数据，因此不进入图表，也不参与面积换算。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(samples.prefix(5)) { node in
                VStack(alignment: .leading, spacing: 1) {
                    Text(node.name)
                        .font(.caption2.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(node.measurement.warning ?? node.measurement.failureReason ?? "无法统计")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if grouping.unmeasuredCount > samples.count {
                Text("另有 \(grouping.unmeasuredCount - samples.count) 项未列出")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func nodeDetail(_ node: DiscoveryNode) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: node.isDirectory ? node.classification.symbolName : "doc")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(node.classification.color)
                    .frame(width: 32, height: 32)
                    .background(node.classification.color.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text(node.name)
                        .font(.callout.weight(.semibold))
                        .lineLimit(2)
                        .truncationMode(.middle)
                    HStack(spacing: 5) {
                        tag(node.classification.title, color: node.classification.color)
                        tag(node.confidence.title, color: .secondary)
                        if node.isHidden { tag("隐藏", color: .secondary) }
                    }
                }
            }

            HStack(alignment: .firstTextBaseline) {
                Text(node.sizeText)
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(node.measurement.isComplete ? Color.primary : Color.orange)
                Spacer()
                Label(node.fileType.title, systemImage: node.fileType.symbolName)
                    .font(.caption2)
                    .foregroundStyle(node.fileType.color)
            }

            Text(node.path.devSweepDisplayPath)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(node.path.path)

            if let warning = node.measurement.warning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("识别依据")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(node.evidence, id: \.self) { evidence in
                    HStack(alignment: .top, spacing: 5) {
                        Text("•")
                        Text(evidence)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }

            if let modifiedAt = node.modifiedAt {
                Text("最近修改 \(modifiedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Divider()

            if let candidate = node.cleanupCandidate {
                cleanupSection(node, candidate: candidate)
            } else {
                readOnlySection(node)
            }

            HStack(spacing: 8) {
                if node.canNavigate {
                    Button {
                        onDrillDown(node)
                    } label: {
                        Label("进入子目录", systemImage: "chevron.right")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                Spacer()
                Menu {
                    Button("在 Finder 中显示") {
                        NSWorkspace.shared.activateFileViewerSelecting([node.path])
                    }
                    Button("复制路径") {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(node.path.path, forType: .string)
                    }
                    Divider()
                    Button("忽略此项") { onIgnore(node) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
    }

    private func cleanupSection(
        _ node: DiscoveryNode,
        candidate: DiscoveryCleanupCandidate
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("清理候选")
                    .font(.caption.weight(.semibold))
                tag(candidate.risk.title, color: candidate.risk.color)
                Spacer()
                Text(candidate.category)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(candidate.note)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            switch cleanupLink(node) {
            case .absent:
                Button {
                    onAddToCleanup(node)
                } label: {
                    Label("加入本次清理", systemImage: "plus.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            case .present:
                Button {
                    onAddToCleanup(node)
                } label: {
                    Label("在清理列表中选中", systemImage: "checkmark.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            case .selected:
                Label("已在本次清理中", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.green)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Text("加入后不会立即删除；需要在清理列表确认，执行前还会重新验证路径、白名单和文件身份。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func readOnlySection(_ node: DiscoveryNode) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lock.shield")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text("只读条目")
                    .font(.caption.weight(.semibold))
                Text(readOnlyReason(for: node))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func readOnlyReason(for node: DiscoveryNode) -> String {
        switch node.classification {
        case .unknown:
            return "没有匹配的缓存规则、模型或环境特征，DevSweep 不会把它当作可删除项。"
        case .systemManaged:
            return "由系统或官方工具管理，请在对应工具中处理。"
        case .developmentEnvironment:
            return "开发环境可能仍在使用，请通过 nvm、rustup、pyenv、conda 等工具管理。"
        case .aiModel:
            return "模型权重可能被多个工具或配置共享，请使用对应工具的模型管理命令。"
        case .knownCache:
            return "位于已知缓存目录内，但不是已登记的具体缓存根；为避免误删保存只读。"
        case .generatedArtifact:
            return "这条规则要求手动处理，DevSweep 不提供批量删除。"
        }
    }

    /// 「其他」分组的成员按分页取回：默认只列出占用最大的 50 项，
    /// 不在内存里保留整尾成员。
    private func otherDetail(_ item: TreemapItem) -> some View {
        let members = DistributionMembers.top(
            in: nodes,
            excluding: grouping.drawnIDs,
            query: otherQuery,
            limit: otherLimit
        )
        let canLoadMore = members.count >= otherLimit
            && otherLimit < item.memberCount
            && otherLimit < Self.defaultMemberPageSize * Self.maxMemberPages

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "square.stack.3d.up")
                    .foregroundStyle(.secondary)
                Text(item.name)
                    .font(.callout.weight(.semibold))
                Spacer()
                if item.isLowerBound {
                    Label("含下限", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            Text((item.isLowerBound ? "合计 ≥ " : "合计 ") + item.bytes.devSweepFileSize + " · \(item.memberCount) 项")
                .font(.caption)
                .foregroundStyle(item.isLowerBound ? Color.orange : Color.secondary)
                .monospacedDigit()
            Text("这些条目面积过小，在图中合并显示；总量按真实大小计算，不会与父目录重复累计。列表默认只显示占用最大的前 \(Self.defaultMemberPageSize) 项。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                TextField("在分组内筛选", text: $otherQuery)
                    .textFieldStyle(.plain)
                    .font(.caption)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.quaternary.opacity(0.4))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            Divider()

            LazyVStack(spacing: 4) {
                ForEach(members) { member in
                    Button {
                        onSelect(member.id)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: member.isDirectory ? member.classification.symbolName : "doc")
                                .font(.caption)
                                .foregroundStyle(member.classification.color)
                                .frame(width: 16)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(member.name)
                                    .font(.caption)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text(member.sizeText)
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(member.measurement.isComplete ? Color.secondary : Color.orange)
                            }
                            Spacer(minLength: 0)
                            if member.canNavigate {
                                Image(systemName: "chevron.right")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if canLoadMore {
                    Button("显示更多（已列出 \(members.count) / \(item.memberCount)）") {
                        otherLimit += Self.defaultMemberPageSize
                    }
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
                } else if members.isEmpty {
                    Text("分组内没有匹配「\(otherQuery)」的条目")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func tag(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
    }
}
