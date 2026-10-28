import Combine
import CoreGraphics
import Foundation
import SwiftUI

/// 一次布局的不可变结果：图块、配色、命中索引和查找表一起构建，
/// 发布时只替换整份结果，不会在视图构建期间重建索引。
struct NestedTreemapLayoutResult: Sendable {
    let segments: [NestedTreemapSegment]
    let drawnNodeIDs: Set<String>
    let hitTestIndex: TreemapHitTestIndex
    private let indexByNodeID: [String: Int32]
    private let indexBySegmentID: [String: Int32]

    static let empty = NestedTreemapLayoutResult(segments: [], drawnNodeIDs: [])

    init(segments: [NestedTreemapSegment], drawnNodeIDs: Set<String>) {
        self.segments = segments
        self.drawnNodeIDs = drawnNodeIDs
        hitTestIndex = TreemapHitTestIndex(segments: segments)
        var byNode: [String: Int32] = [:]
        var bySegment: [String: Int32] = [:]
        byNode.reserveCapacity(segments.count)
        bySegment.reserveCapacity(segments.count)
        for (index, segment) in segments.enumerated() {
            bySegment[segment.id] = Int32(index)
            if let nodeID = segment.nodeID { byNode[nodeID] = Int32(index) }
        }
        indexByNodeID = byNode
        indexBySegmentID = bySegment
    }

    var isEmpty: Bool { segments.isEmpty }

    func segment(nodeID: String?) -> NestedTreemapSegment? {
        guard let nodeID, let index = indexByNodeID[nodeID] else { return nil }
        return segments[Int(index)]
    }

    func segment(id: String?) -> NestedTreemapSegment? {
        guard let id, let index = indexBySegmentID[id] else { return nil }
        return segments[Int(index)]
    }

    func segment(at point: CGPoint, in size: CGSize) -> NestedTreemapSegment? {
        hitTestIndex.segment(at: point, in: size)
    }
}

/// 布局请求键。任何一项变化都需要重新布局；悬停和选中不在其中。
struct TreemapLayoutRequestKey: Hashable {
    let snapshotVersion: String
    let rootIndex: Int
    let width: CGFloat
    let height: CGFloat
    let depthLimit: Int
    let minimumTileArea: CGFloat
}

/// 布局取消标志。布局跑在 `Task.detached` 里，不继承外层的取消状态，
/// 所以用一个线程安全的标志把取消直接传进布局的遍历循环，让它尽快停止。
/// 布局每画一个图块都会读一次，读操作只有一次加锁。
final class TreemapLayoutCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

/// 多层树图的布局协调器。布局在后台线程计算，只接受最新一次请求的结果；
/// 旧请求会被直接取消，布局遍历在下一个图块边界就停下，不会空跑完再丢弃。
@MainActor
final class TreemapChartModel: ObservableObject {
    @Published private(set) var layout = NestedTreemapLayoutResult.empty
    @Published private(set) var renderData = NestedTreemapRenderData.empty
    @Published private(set) var layoutVersion = 0
    @Published private(set) var isLayoutRunning = false
    @Published private(set) var layoutFailure: String?
    @Published private(set) var hoveredSegmentID: String?
    @Published private(set) var hoveredSegment: NestedTreemapSegment?

    private var currentRequestID = 0
    private var activeTask: Task<Void, Never>?
    private var activeCancellation: TreemapLayoutCancellation?
    private var lastKey: TreemapLayoutRequestKey?

    /// 正在跑的布局的取消标志，取消外层请求时会被置位；测试据此确认取消已传进布局。
    var activeLayoutCancellation: TreemapLayoutCancellation? { activeCancellation }

    var renderedSegments: [NestedTreemapSegment] { layout.segments }

    func setHovered(_ segment: NestedTreemapSegment?) {
        guard hoveredSegmentID != segment?.id else { return }
        hoveredSegmentID = segment?.id
        hoveredSegment = segment
    }

    func clearHover() {
        setHovered(nil)
    }

    /// 请求一次布局。尺寸变化时沿用旧布局继续显示，避免闪白；
    /// 只有新布局完成后才整体替换。
    func requestLayout(
        snapshot: DiscoveryTreeSnapshot,
        rootIndex: Int,
        size: CGSize,
        parameters: NestedTreemapParameters,
        classifier: DiscoveryClassifier,
        force: Bool = false
    ) {
        guard size.width >= 1, size.height >= 1 else { return }
        let key = TreemapLayoutRequestKey(
            snapshotVersion: snapshot.version,
            rootIndex: rootIndex,
            width: size.width.rounded(),
            height: size.height.rounded(),
            depthLimit: parameters.depthLimit,
            minimumTileArea: parameters.minimumTileArea
        )
        guard force || key != lastKey else { return }
        lastKey = key

        currentRequestID += 1
        let requestID = currentRequestID
        // 旧布局先停：置位共享标志（布局遍历会看到）并取消任务句柄。
        activeCancellation?.cancel()
        activeTask?.cancel()
        let cancellation = TreemapLayoutCancellation()
        activeCancellation = cancellation
        isLayoutRunning = true
        layoutFailure = nil

        activeTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard !cancellation.isCancelled else { return }
            let raw = NestedTreemapLayout.segments(
                in: snapshot,
                rootIndex: rootIndex,
                size: size,
                parameters: parameters,
                classifier: classifier,
                isCancelled: { cancellation.isCancelled }
            )
            guard !cancellation.isCancelled else { return }
            let layout = NestedTreemapLayoutResult(
                segments: raw.segments,
                drawnNodeIDs: raw.drawnNodeIDs
            )
            // 颜色与大小文本也在后台一次算好，绘制和悬停都不再格式化。
            let renderData = NestedTreemapRenderData(layout: layout)
            guard !cancellation.isCancelled else { return }
            // 结果只在仍然是最新请求时发布；取消或过期都不会覆盖当前布局。
            await MainActor.run {
                guard let self,
                      self.currentRequestID == requestID,
                      self.activeCancellation === cancellation,
                      !cancellation.isCancelled
                else { return }
                self.activeCancellation = nil
                self.activeTask = nil
                self.isLayoutRunning = false
                self.apply(layout, renderData: renderData)
            }
        }
    }

    func cancel() {
        currentRequestID += 1
        activeCancellation?.cancel()
        activeCancellation = nil
        activeTask?.cancel()
        activeTask = nil
        isLayoutRunning = false
    }

    /// 扫描快照被替换时清空旧布局，避免继续显示已经不存在的节点。
    func reset() {
        cancel()
        lastKey = nil
        layout = .empty
        renderData = .empty
        layoutVersion += 1
        hoveredSegmentID = nil
        hoveredSegment = nil
        layoutFailure = nil
    }

    private func apply(_ next: NestedTreemapLayoutResult, renderData nextRenderData: NestedTreemapRenderData) {
        layout = next
        renderData = nextRenderData
        layoutVersion += 1
        if let hoveredSegmentID, next.segment(id: hoveredSegmentID) == nil {
            setHovered(nil)
        }
    }
}

/// 树图配色：同一分支共用色相，深度降低亮度，兄弟按位置轻微变化。
/// 分类只作为辅助色标，安全等级始终由文字与图标表达。
enum NestedTreemapColorResolver {
    private static let branchHues: [Double] = [0.58, 0.08, 0.38, 0.76, 0.49, 0.94, 0.14, 0.66]
    private static let variantOffsets: [Double] = [-0.035, -0.018, 0, 0.018, 0.035]

    static func components(
        for segment: NestedTreemapSegment,
        isDark: Bool
    ) -> (hue: Double, saturation: Double, brightness: Double) {
        if segment.isAggregate {
            return (0, 0, isDark ? 0.36 : 0.84)
        }
        let baseHue = branchHues[abs(segment.colorBranch) % branchHues.count]
        let offset = variantOffsets[min(max(segment.colorVariant, 0), variantOffsets.count - 1)]
        let depth = min(segment.depth, 7)
        let hue = normalizedHue(baseHue + offset * 0.5 + Double(depth) * 0.004)
        if isDark {
            return (
                hue,
                min(max(0.34 - Double(depth) * 0.01, 0.26), 0.42),
                min(max(0.52 - Double(depth) * 0.022 + offset * 0.1, 0.36), 0.58)
            )
        }
        return (
            hue,
            min(max(0.3 - Double(depth) * 0.008, 0.2), 0.38),
            min(max(0.96 - Double(depth) * 0.018 + offset * 0.08, 0.8), 0.98)
        )
    }

    static func color(for segment: NestedTreemapSegment, isDark: Bool) -> Color {
        let c = components(for: segment, isDark: isDark)
        return Color(hue: c.hue, saturation: c.saturation, brightness: c.brightness)
    }

    private static func normalizedHue(_ hue: Double) -> Double {
        var value = hue.truncatingRemainder(dividingBy: 1)
        if value < 0 { value += 1 }
        return value
    }
}

/// 预先算好的绘制数据：颜色、格式化后的大小文本和标签长度。
/// 绘制时不再做任何格式化，悬停也不会触发它们重算。
struct NestedTreemapPaint: Sendable {
    let lightFill: Color
    let darkFill: Color
    let sizeLabel: String
    let titleCharacterCount: Int
}

struct NestedTreemapRenderData: Sendable {
    let segments: [NestedTreemapSegment]
    let paints: [NestedTreemapPaint]

    static let empty = NestedTreemapRenderData()

    private init() {
        segments = []
        paints = []
    }

    init(layout: NestedTreemapLayoutResult) {
        segments = layout.segments
        var labels: [Int64: String] = [:]
        paints = layout.segments.map { segment in
            let sizeLabel: String
            if let cached = labels[segment.bytes] {
                sizeLabel = cached
            } else {
                sizeLabel = segment.bytes.devSweepFileSize
                labels[segment.bytes] = sizeLabel
            }
            return NestedTreemapPaint(
                lightFill: NestedTreemapColorResolver.color(for: segment, isDark: false),
                darkFill: NestedTreemapColorResolver.color(for: segment, isDark: true),
                sizeLabel: sizeLabel,
                titleCharacterCount: segment.title.count
            )
        }
    }
}
