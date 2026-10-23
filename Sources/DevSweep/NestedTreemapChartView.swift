import AppKit
import SwiftUI

/// 多层嵌套树图。基础色块、标签、悬停和选中各自是一层 Canvas：
/// 指针移动只重绘轻量覆盖层，不会重新布局，也不会重新格式化标签。
struct NestedTreemapChartView: View {
    let snapshot: DiscoveryTreeSnapshot
    let rootIndex: Int
    let classifier: DiscoveryClassifier
    let selectedNodeID: String?
    let searchQuery: String
    let depthLimit: Int
    let isScanning: Bool
    let onSelect: (String?) -> Void
    let onOpen: (String) -> Void
    let onInspectAggregate: (NestedTreemapSegment, Set<String>) -> Void

    @StateObject private var model = TreemapChartModel()
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var parameters: NestedTreemapParameters {
        var parameters = NestedTreemapParameters()
        parameters.depthLimit = depthLimit
        return parameters
    }

    private var selectedSegment: NestedTreemapSegment? {
        model.layout.segment(nodeID: selectedNodeID)
    }

    private var hoveredSegment: NestedTreemapSegment? {
        model.hoveredSegment
    }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                NestedTreemapBaseCanvas(
                    renderData: model.renderData,
                    version: model.layoutVersion,
                    colorScheme: colorScheme,
                    size: size
                )
                NestedTreemapLabelCanvas(
                    renderData: model.renderData,
                    version: model.layoutVersion,
                    colorScheme: colorScheme,
                    size: size
                )
                NestedTreemapHighlightCanvas(
                    hovered: hoveredSegment,
                    selected: selectedSegment,
                    colorScheme: colorScheme,
                    size: size
                )
                NestedTreemapSearchCanvas(
                    renderData: model.renderData,
                    version: model.layoutVersion,
                    query: searchQuery,
                    size: size
                )
                .allowsHitTesting(false)

                if model.isLayoutRunning && model.renderData.segments.isEmpty {
                    ProgressView()
                        .controlSize(.small)
                }
                if let failure = model.layoutFailure {
                    Text(failure)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(10)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    let next = model.layout.segment(at: location, in: size)
                    model.setHovered(next)
                case .ended:
                    model.clearHover()
                }
            }
            .gesture(
                SpatialTapGesture(count: 2).onEnded { value in
                    handleTap(at: value.location, in: size, open: true)
                }
            )
            .simultaneousGesture(
                SpatialTapGesture(count: 1).onEnded { value in
                    handleTap(at: value.location, in: size, open: false)
                }
            )
            .overlay(alignment: .topLeading) { hoverCard(size: size) }
            .focusable()
            .onMoveCommand { direction in
                moveSelection(direction, in: size)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("多层矩形树图，按占用显示目录与文件")
            .accessibilityValue(accessibilityValue)
            .onAppear {
                model.requestLayout(
                    snapshot: snapshot,
                    rootIndex: rootIndex,
                    size: size,
                    parameters: parameters,
                    classifier: classifier
                )
            }
            .onChange(of: size) { newSize in
                model.requestLayout(
                    snapshot: snapshot,
                    rootIndex: rootIndex,
                    size: newSize,
                    parameters: parameters,
                    classifier: classifier
                )
            }
            .onChange(of: snapshot.version) { _ in
                model.reset()
                model.requestLayout(
                    snapshot: snapshot,
                    rootIndex: rootIndex,
                    size: size,
                    parameters: parameters,
                    classifier: classifier,
                    force: true
                )
            }
            .onChange(of: rootIndex) { _ in
                model.requestLayout(
                    snapshot: snapshot,
                    rootIndex: rootIndex,
                    size: size,
                    parameters: parameters,
                    classifier: classifier,
                    force: true
                )
            }
            .onChange(of: depthLimit) { _ in
                model.requestLayout(
                    snapshot: snapshot,
                    rootIndex: rootIndex,
                    size: size,
                    parameters: parameters,
                    classifier: classifier,
                    force: true
                )
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: model.layoutVersion)
        }
        .onDisappear { model.cancel() }
    }

    private var accessibilityValue: String {
        let count = model.renderData.segments.count
        if let selectedSegment {
            return "已选中 \(selectedSegment.title)，共 \(count) 个图块"
        }
        return "共 \(count) 个图块"
    }

    /// 方向键在当前布局里按几何位置切换选中项：只考虑已绘制图块，
    /// 优先选同一深度、方向一致且距离最近的图块。
    private func moveSelection(_ direction: MoveCommandDirection, in size: CGSize) {
        let candidates = model.layout.segments.filter { $0.nodeID != nil }
        guard !candidates.isEmpty else { return }

        let current = selectedSegment.map { TreemapGeometry.displayRect(for: $0, in: size) }
            ?? CGRect(x: size.width / 2, y: size.height / 2, width: 0, height: 0)
        let origin = CGPoint(x: current.midX, y: current.midY)

        func score(_ segment: NestedTreemapSegment) -> CGFloat? {
            let rect = TreemapGeometry.displayRect(for: segment, in: size)
            let dx = rect.midX - origin.x
            let dy = rect.midY - origin.y
            switch direction {
            case .left: guard dx < -1 else { return nil }
            case .right: guard dx > 1 else { return nil }
            case .up: guard dy < -1 else { return nil }
            case .down: guard dy > 1 else { return nil }
            @unknown default: return nil
            }
            let primary = direction == .left || direction == .right ? abs(dx) : abs(dy)
            let secondary = direction == .left || direction == .right ? abs(dy) : abs(dx)
            let depthPenalty = selectedSegment.map { CGFloat(abs($0.depth - segment.depth)) * 400 } ?? 0
            return primary + secondary * 2 + depthPenalty
        }

        let next = candidates
            .compactMap { segment in score(segment).map { (segment, $0) } }
            .min { $0.1 < $1.1 }?.0
        if let next { onSelect(next.nodeID) }
    }

    private func handleTap(at location: CGPoint, in size: CGSize, open: Bool) {
        guard let segment = model.layout.segment(at: location, in: size) else {
            if !open { onSelect(nil) }
            return
        }
        if segment.isAggregate {
            onInspectAggregate(segment, model.layout.drawnNodeIDs)
            return
        }
        guard let nodeID = segment.nodeID else { return }
        onSelect(nodeID)
        if open {
            if segment.isDirectory {
                onOpen(nodeID)
            } else {
                NSWorkspace.shared.open(URL(fileURLWithPath: nodeID))
            }
        }
    }

    @ViewBuilder
    private func hoverCard(size: CGSize) -> some View {
        if let hoveredSegment {
            let rect = TreemapGeometry.displayRect(for: hoveredSegment, in: size)
            HStack(spacing: 6) {
                Text(hoveredSegment.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text((hoveredSegment.isLowerBound ? "≥ " : "") + hoveredSegment.bytes.devSweepFileSize)
                    .monospacedDigit()
                    .foregroundStyle(hoveredSegment.isLowerBound ? Color.orange : Color.secondary)
                if hoveredSegment.isAggregate {
                    Text("\(hoveredSegment.memberCount) 项")
                        .foregroundStyle(.secondary)
                } else {
                    Text(hoveredSegment.classification.title)
                        .foregroundStyle(hoveredSegment.classification.color)
                }
            }
            .font(.caption2)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .offset(
                x: min(max(rect.minX, 4), max(size.width - 260, 4)),
                y: max(rect.minY - 26, 4)
            )
            .allowsHitTesting(false)
        }
    }
}

struct NestedTreemapBaseCanvas: View, Equatable {
    let renderData: NestedTreemapRenderData
    let version: Int
    let colorScheme: ColorScheme
    let size: CGSize

    static func == (lhs: NestedTreemapBaseCanvas, rhs: NestedTreemapBaseCanvas) -> Bool {
        lhs.version == rhs.version && lhs.colorScheme == rhs.colorScheme && lhs.size == rhs.size
    }

    var body: some View {
        Canvas { context, canvasSize in
            let bounds = CGRect(origin: .zero, size: canvasSize)
            context.clip(to: Path(bounds))
            for (index, segment) in renderData.segments.enumerated() {
                let rect = TreemapGeometry.displayRect(for: segment, in: canvasSize)
                guard rect.width > 0.4, rect.height > 0.4, rect.intersects(bounds) else { continue }
                let paint = renderData.paints[index]
                let path = tilePath(rect)
                context.fill(path, with: .color(colorScheme == .dark ? paint.darkFill : paint.lightFill))
                context.stroke(
                    path,
                    with: .color(Color.primary.opacity(segment.depth == 0 ? 0.16 : 0.1)),
                    style: StrokeStyle(
                        lineWidth: segment.showsHeader ? 1 : 0.6,
                        dash: segment.isLowerBound ? [4, 3] : []
                    )
                )
            }
        }
        .allowsHitTesting(false)
    }
}

struct NestedTreemapLabelCanvas: View, Equatable {
    let renderData: NestedTreemapRenderData
    let version: Int
    let colorScheme: ColorScheme
    let size: CGSize

    static func == (lhs: NestedTreemapLabelCanvas, rhs: NestedTreemapLabelCanvas) -> Bool {
        lhs.version == rhs.version && lhs.colorScheme == rhs.colorScheme && lhs.size == rhs.size
    }

    var body: some View {
        Canvas { context, canvasSize in
            let bounds = CGRect(origin: .zero, size: canvasSize)
            context.clip(to: Path(bounds))
            for (index, segment) in renderData.segments.enumerated() {
                let rect = TreemapGeometry.displayRect(for: segment, in: canvasSize)
                guard rect.intersects(bounds), rect.width >= 42, rect.height >= 20 else { continue }
                let paint = renderData.paints[index]
                let padding: CGFloat = 5
                let availableWidth = rect.width - padding * 2
                guard availableWidth > 16 else { continue }

                let title = truncated(
                    segment.title,
                    characterCount: paint.titleCharacterCount,
                    for: availableWidth,
                    averageCharacterWidth: 6.2
                )
                var labelContext = context
                let clipRect = CGRect(
                    x: rect.minX + padding,
                    y: rect.minY + 3,
                    width: availableWidth,
                    height: segment.showsHeader ? 15 : max(rect.height - 6, 0)
                )
                labelContext.clip(to: Path(clipRect))
                labelContext.draw(
                    Text(title)
                        .font(.system(size: 11, weight: segment.showsHeader ? .semibold : .medium))
                        .foregroundColor(segment.showsHeader ? .primary : .primary.opacity(0.92)),
                    at: CGPoint(x: clipRect.minX, y: clipRect.minY),
                    anchor: .topLeading
                )

                guard !segment.showsHeader, rect.width >= 72, rect.height >= 42 else { continue }
                labelContext.draw(
                    Text((segment.isLowerBound ? "≥ " : "") + paint.sizeLabel)
                        .font(.system(size: 10))
                        .foregroundColor(segment.isLowerBound ? .orange : .secondary),
                    at: CGPoint(x: clipRect.minX, y: clipRect.minY + 16),
                    anchor: .topLeading
                )
            }
        }
        .allowsHitTesting(false)
    }
}

struct NestedTreemapHighlightCanvas: View {
    let hovered: NestedTreemapSegment?
    let selected: NestedTreemapSegment?
    let colorScheme: ColorScheme
    let size: CGSize

    var body: some View {
        Canvas { context, canvasSize in
            let bounds = CGRect(origin: .zero, size: canvasSize)
            context.clip(to: Path(bounds))
            if let hovered, hovered.id != selected?.id {
                let rect = TreemapGeometry.displayRect(for: hovered, in: canvasSize)
                guard rect.intersects(bounds) else { return }
                context.fill(tilePath(rect), with: .color(Color.primary.opacity(0.1)))
                context.stroke(tilePath(rect), with: .color(Color.primary.opacity(0.5)), lineWidth: 1)
            }
            if let selected {
                let rect = TreemapGeometry.displayRect(for: selected, in: canvasSize)
                guard rect.intersects(bounds) else { return }
                context.fill(tilePath(rect), with: .color(Color.accentColor.opacity(0.2)))
                context.stroke(tilePath(rect), with: .color(Color.accentColor), lineWidth: 2)
            }
        }
        .allowsHitTesting(false)
    }
}

/// 搜索高亮：匹配的图块加亮，不匹配的压暗，但保持面积比例不变，
/// 避免把过滤结果误解成真实磁盘占用。
struct NestedTreemapSearchCanvas: View, Equatable {
    let renderData: NestedTreemapRenderData
    let version: Int
    let query: String
    let size: CGSize

    static func == (lhs: NestedTreemapSearchCanvas, rhs: NestedTreemapSearchCanvas) -> Bool {
        lhs.version == rhs.version && lhs.query == rhs.query && lhs.size == rhs.size
    }

    var body: some View {
        Canvas { context, canvasSize in
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let bounds = CGRect(origin: .zero, size: canvasSize)
            context.clip(to: Path(bounds))
            for segment in renderData.segments {
                let rect = TreemapGeometry.displayRect(for: segment, in: canvasSize)
                guard rect.width > 0.4, rect.height > 0.4, rect.intersects(bounds) else { continue }
                if segment.title.localizedCaseInsensitiveContains(trimmed)
                    || (segment.nodeID?.localizedCaseInsensitiveContains(trimmed) ?? false) {
                    context.stroke(tilePath(rect), with: .color(.orange), lineWidth: 2)
                } else {
                    context.fill(tilePath(rect), with: .color(Color(nsColor: .windowBackgroundColor).opacity(0.24)))
                }
            }
        }
    }
}

func tilePath(_ rect: CGRect) -> Path {
    let radius = min(CGFloat(4), min(rect.width, rect.height) * 0.1)
    return Path(roundedRect: rect, cornerRadius: max(radius, 0))
}

func truncated(
    _ text: String,
    characterCount: Int,
    for width: CGFloat,
    averageCharacterWidth: CGFloat
) -> String {
    let maximum = max(Int(width / averageCharacterWidth), 1)
    guard characterCount > maximum, maximum > 1 else { return text }
    return String(text.prefix(maximum - 1)) + "…"
}

/// 被点击的聚合图块。聚合项没有真实路径，只能按父目录和「未单独绘制」的成员回查。
struct NestedAggregateSelection: Equatable {
    let segment: NestedTreemapSegment
    let drawnNodeIDs: Set<String>
}

/// 聚合图块详情：列出该父目录下没有单独绘制、但确实计入聚合面积的成员。
/// 只分页取回有限数量，不把整尾成员常驻在视图状态里。
struct NestedAggregateDetailPanel: View {
    let selection: NestedAggregateSelection
    let snapshot: DiscoveryTreeSnapshot?
    let onOpenContainer: (String) -> Void

    @State private var query = ""
    @State private var limit = 50

    private var members: [DiscoveryNode] {
        guard let snapshot,
              let containerIndex = snapshot.index(ofPath: selection.segment.containerNodeID) else { return [] }
        let classifier = DiscoveryClassifier()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var result: [DiscoveryNode] = []
        for child in snapshot.children(of: containerIndex) {
            let index = Int(child)
            guard let record = snapshot.record(at: index) else { continue }
            let path = snapshot.path(of: index)
            if selection.drawnNodeIDs.contains(path) { continue }
            if !trimmed.isEmpty, !path.localizedCaseInsensitiveContains(trimmed) { continue }
            guard let node = snapshot.discoveryNode(at: index, classifier: classifier) else { continue }
            _ = record
            result.append(node)
        }
        result.sort { lhs, rhs in
            if lhs.measurement.allocatedBytes != rhs.measurement.allocatedBytes {
                return lhs.measurement.allocatedBytes > rhs.measurement.allocatedBytes
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        return result
    }

    var body: some View {
        let items = members
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "square.stack.3d.up")
                        .foregroundStyle(.secondary)
                    Text(selection.segment.title)
                        .font(.callout.weight(.semibold))
                    Spacer()
                    if selection.segment.isLowerBound {
                        Label("含下限", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                Text((selection.segment.isLowerBound ? "合计 ≥ " : "合计 ") +
                     selection.segment.bytes.devSweepFileSize +
                     " · \(selection.segment.memberCount) 项")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(selection.segment.isLowerBound ? Color.orange : Color.secondary)
                Text("这些条目面积太小，合并成一个图块显示。总量按真实大小计算，不会与父目录重复累计。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    TextField("在分组内筛选", text: $query)
                        .textFieldStyle(.plain)
                        .font(.caption)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.quaternary.opacity(0.4))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                Divider()

                if items.isEmpty {
                    Text("这个分组里没有匹配的条目。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    LazyVStack(spacing: 4) {
                        ForEach(items.prefix(limit)) { node in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(node.name)
                                    .font(.caption)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text(node.sizeText)
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(node.measurement.isComplete ? Color.secondary : Color.orange)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if items.count > limit {
                            Button("显示更多（已列出 \(limit) / \(items.count)）") {
                                limit += 50
                            }
                            .controlSize(.small)
                        }
                    }
                }

                Divider()
                Button {
                    onOpenContainer(selection.segment.containerNodeID)
                } label: {
                    Label("进入所在目录", systemImage: "arrow.down.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(14)
        }
        .background(.quaternary.opacity(0.14))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
