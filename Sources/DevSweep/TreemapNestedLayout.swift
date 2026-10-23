import CoreGraphics
import Foundation

/// 多层树图的一个图块。矩形使用归一化坐标（0...1），渲染时再按当前画布尺寸缩放，
/// 因此窗口缩放不需要重新布局，只需要重新换算绘制矩形。
struct NestedTreemapSegment: Identifiable, Hashable, Sendable {
    let id: String
    /// 真实节点路径；聚合图块没有对应路径。
    let nodeID: String?
    let containerNodeID: String
    let title: String
    let rect: CGRect
    let depth: Int
    let bytes: Int64
    let isDirectory: Bool
    let isLowerBound: Bool
    let isAggregate: Bool
    let memberCount: Int
    let classification: DiscoveryClassification
    let showsHeader: Bool
    let colorBranch: Int
    let colorVariant: Int
}

/// 多层布局参数。默认值按 900×520 的图表区域校准：
/// 5 层深度足以看清「目录 → 子目录 → 文件」，同时把可见图块控制在两万个以内。
struct NestedTreemapParameters: Hashable, Sendable {
    var depthLimit: Int = 5
    var minimumTileArea: CGFloat = 110
    var maximumSegmentCount: Int = 20_000
    var minimumContainerWidth: CGFloat = 52
    var minimumContainerHeight: CGFloat = 46
    var containerInset: CGFloat = 2
    var containerHeaderHeight: CGFloat = 18

    static let containerInset: CGFloat = 2
    static let containerHeaderHeight: CGFloat = 18
}

struct NestedTreemapLayoutOutput {
    let segments: [NestedTreemapSegment]
    /// 单独绘制过的节点路径；选中项不在其中时说明它被并入了聚合图块。
    let drawnNodeIDs: Set<String>
}

enum NestedTreemapLayout {
    /// 布局只依赖快照、根节点、画布尺寸和参数；分类颜色在布局时一次算好，
    /// 悬停、选中和详情面板状态不参与计算。
    static func segments(
        in snapshot: DiscoveryTreeSnapshot,
        rootIndex: Int,
        size: CGSize,
        parameters: NestedTreemapParameters = NestedTreemapParameters(),
        classifier: DiscoveryClassifier = DiscoveryClassifier(),
        isCancelled: @escaping () -> Bool = { false }
    ) -> NestedTreemapLayoutOutput {
        let empty = NestedTreemapLayoutOutput(segments: [], drawnNodeIDs: [])
        guard size.width > 0, size.height > 0, parameters.depthLimit > 0 else { return empty }
        guard snapshot.records.indices.contains(rootIndex) else { return empty }

        var builder = SegmentBuilder(
            snapshot: snapshot,
            classifier: classifier,
            parameters: parameters,
            rootSize: size,
            isCancelled: isCancelled
        )
        let rootChildren = snapshot.children(of: rootIndex)
        guard !rootChildren.isEmpty else { return empty }

        let rootBounds = CGRect(origin: .zero, size: size)
        let rootPath = snapshot.path(of: rootIndex)
        let entries = builder.groupedEntries(
            childIndices: rootChildren,
            parentIndex: rootIndex,
            parentPath: rootPath,
            bounds: rootBounds,
            branch: 0,
            isRootLevel: true
        )
        builder.appendSegments(
            entries: entries,
            parentIndex: rootIndex,
            parentPath: rootPath,
            bounds: rootBounds,
            depth: 0,
            branch: 0
        )
        return NestedTreemapLayoutOutput(
            segments: builder.segments,
            drawnNodeIDs: builder.drawnNodeIDs
        )
    }
}

private struct SegmentBuilder {
    let snapshot: DiscoveryTreeSnapshot
    let classifier: DiscoveryClassifier
    let parameters: NestedTreemapParameters
    let rootSize: CGSize
    let isCancelled: () -> Bool

    var segments: [NestedTreemapSegment] = []
    /// 已单独绘制的节点路径，用于判断某个选中项是否落在聚合图块里。
    var drawnNodeIDs: Set<String> = []

    init(
        snapshot: DiscoveryTreeSnapshot,
        classifier: DiscoveryClassifier,
        parameters: NestedTreemapParameters,
        rootSize: CGSize,
        isCancelled: @escaping () -> Bool
    ) {
        self.snapshot = snapshot
        self.classifier = classifier
        self.parameters = parameters
        self.rootSize = rootSize
        self.isCancelled = isCancelled
        segments.reserveCapacity(min(parameters.maximumSegmentCount, 4_096))
        drawnNodeIDs.reserveCapacity(min(parameters.maximumSegmentCount, 4_096))
    }

    struct Entry {
        let index: Int
        let title: String
        let bytes: Int64
        let isDirectory: Bool
        let isLowerBound: Bool
        let isAggregate: Bool
        let memberCount: Int
        let classification: DiscoveryClassification
        let branch: Int
        let variant: Int
        /// 聚合图块没有真实节点路径。
        let path: String?
    }

    mutating func groupedEntries(
        childIndices: ArraySlice<Int32>,
        parentIndex: Int,
        parentPath: String,
        bounds: CGRect,
        branch: Int,
        isRootLevel: Bool
    ) -> [Entry] {
        var drawable: [Int] = []
        drawable.reserveCapacity(childIndices.count)
        var totalWeight = 0.0
        var skippedBytes: Int64 = 0
        var skippedCount = 0
        var skippedLowerBound = false

        for child in childIndices {
            let index = Int(child)
            guard let record = snapshot.record(at: index) else { continue }
            if record.allocatedBytes <= 0 {
                skippedCount += 1
                skippedBytes = Self.addClamped(skippedBytes, record.allocatedBytes)
                if record.isIncomplete { skippedLowerBound = true }
                continue
            }
            drawable.append(index)
            totalWeight += Double(record.allocatedBytes)
        }
        guard !drawable.isEmpty else { return [] }

        let availableArea = max(bounds.width * bounds.height, 1)
        var entries: [Entry] = []
        entries.reserveCapacity(min(drawable.count, 512))
        var aggregateBytes: Int64 = 0
        var aggregateMembers = 0
        var aggregateLowerBound = false

        // 面积不足最小图块的子项合并成一个聚合图块；合并只减少绘制对象，
        // 不丢真实占用：聚合图块的字节数就是成员字节数之和。
        for index in drawable {
            guard let record = snapshot.record(at: index) else { continue }
            let projectedArea = availableArea * CGFloat(Double(record.allocatedBytes) / totalWeight)
            if projectedArea < parameters.minimumTileArea {
                aggregateBytes = Self.addClamped(aggregateBytes, record.allocatedBytes)
                aggregateMembers += 1
                if record.isIncomplete { aggregateLowerBound = true }
                continue
            }
            let path = parentPath + "/" + record.name
            entries.append(Entry(
                index: index,
                title: record.name,
                bytes: record.allocatedBytes,
                isDirectory: record.isDirectory,
                isLowerBound: record.isIncomplete,
                isAggregate: false,
                memberCount: 1,
                classification: classifier.classifyShallow(
                    path: path,
                    name: record.name,
                    isDirectory: record.isDirectory
                ),
                branch: branch,
                variant: Self.stableVariant(path),
                path: path
            ))
        }

        if aggregateMembers > 0 {
            aggregateBytes = Self.addClamped(aggregateBytes, skippedBytes)
            aggregateMembers += skippedCount
            aggregateLowerBound = aggregateLowerBound || skippedLowerBound
            entries.append(Entry(
                index: -1,
                title: "其他 \(aggregateMembers) 项",
                bytes: aggregateBytes,
                isDirectory: false,
                isLowerBound: aggregateLowerBound,
                isAggregate: true,
                memberCount: aggregateMembers,
                classification: .unknown,
                branch: branch,
                variant: Self.stableVariant(parentPath + "#aggregate"),
                path: nil
            ))
        } else if skippedCount > 0 {
            // 全部子项都只有 0 B：没有可绘制的面积，父目录只保留计数。
            entries.append(Entry(
                index: -1,
                title: "\(skippedCount) 项无占用",
                bytes: 0,
                isDirectory: false,
                isLowerBound: skippedLowerBound,
                isAggregate: true,
                memberCount: skippedCount,
                classification: .unknown,
                branch: branch,
                variant: Self.stableVariant(parentPath + "#empty"),
                path: nil
            ))
        }

        // 用逐字节比较而不是 localizedStandardCompare：后者在数万条目的热路径上
        // 代价极高，而且同一份数据的确定性只需要稳定、可重复的次序。
        entries.sort { lhs, rhs in
            if lhs.bytes != rhs.bytes { return lhs.bytes > rhs.bytes }
            return lhs.title < rhs.title
        }
        if !isRootLevel {
            // 兄弟节点按位置均匀取色，同一父目录下的图块有可读的深浅差异。
            for position in entries.indices where !entries[position].isAggregate {
                entries[position] = Entry(
                    index: entries[position].index,
                    title: entries[position].title,
                    bytes: entries[position].bytes,
                    isDirectory: entries[position].isDirectory,
                    isLowerBound: entries[position].isLowerBound,
                    isAggregate: false,
                    memberCount: 1,
                    classification: entries[position].classification,
                    branch: branch,
                    variant: Self.siblingVariant(position, count: entries.count),
                    path: entries[position].path
                )
            }
        }
        return entries
    }

    mutating func appendSegments(
        entries: [Entry],
        parentIndex: Int,
        parentPath: String,
        bounds: CGRect,
        depth: Int,
        branch: Int
    ) {
        guard depth < parameters.depthLimit, !entries.isEmpty else { return }
        let tiles = squarified(entries, in: bounds)

        for (position, tile) in tiles.enumerated() {
            if isCancelled() { return }
            guard segments.count < parameters.maximumSegmentCount else { return }
            let entry = tile.entry
            let childBounds = childContentBounds(in: tile.rect)
            let hasChildren = childBounds != nil
                && entry.isDirectory
                && entry.index >= 0
                && depth + 1 < parameters.depthLimit
                && !snapshot.children(of: entry.index).isEmpty

            let segmentBranch: Int
            segmentBranch = depth == 0 ? position % Self.branchCount : branch

            let path = entry.path
            if let path { drawnNodeIDs.insert(path) }
            segments.append(NestedTreemapSegment(
                id: path ?? "aggregate:\(parentPath):\(entry.title)",
                nodeID: path,
                containerNodeID: parentPath,
                title: entry.title,
                rect: normalized(tile.rect),
                depth: depth,
                bytes: entry.bytes,
                isDirectory: entry.isDirectory,
                isLowerBound: entry.isLowerBound,
                isAggregate: entry.isAggregate,
                memberCount: entry.memberCount,
                classification: entry.classification,
                showsHeader: hasChildren,
                colorBranch: segmentBranch,
                colorVariant: entry.variant
            ))

            guard hasChildren, let childBounds else { continue }
            let children = snapshot.children(of: entry.index)
            let childEntries = groupedEntries(
                childIndices: children,
                parentIndex: entry.index,
                parentPath: path ?? parentPath,
                bounds: childBounds,
                branch: segmentBranch,
                isRootLevel: false
            )
            appendSegments(
                entries: childEntries,
                parentIndex: entry.index,
                parentPath: path ?? parentPath,
                bounds: childBounds,
                depth: depth + 1,
                branch: segmentBranch
            )
        }
    }

    /// Squarified Treemap：单趟消费条目，候选行只维护面积和与最值，
    /// 不再为每个候选复制数组或反复 `removeFirst`。
    func squarified(_ entries: [Entry], in bounds: CGRect) -> [(entry: Entry, rect: CGRect)] {
        guard !entries.isEmpty, bounds.width > 0, bounds.height > 0 else { return [] }
        var totalWeight = 0.0
        for entry in entries { totalWeight += Double(max(entry.bytes, 1)) }
        guard totalWeight > 0 else { return [] }

        let scale = Double(bounds.width * bounds.height) / totalWeight
        let scaledAreas = entries.map { Double(max($0.bytes, 1)) * scale }
        var remaining = bounds
        var result: [(entry: Entry, rect: CGRect)] = []
        result.reserveCapacity(entries.count)

        var rowStart = 0
        var rowArea = 0.0
        var rowMin = Double.greatestFiniteMagnitude
        var rowMax = 0.0

        func flushRow(upTo end: Int) {
            guard end > rowStart, rowArea > 0 else { return }
            remaining = layoutRow(
                entries: entries,
                range: rowStart..<end,
                areas: scaledAreas,
                rowArea: rowArea,
                in: remaining,
                into: &result
            )
            rowStart = end
            rowArea = 0
            rowMin = .greatestFiniteMagnitude
            rowMax = 0
        }

        for index in entries.indices {
            let area = scaledAreas[index]
            let shortSide = Double(min(remaining.width, remaining.height))
            let candidateSum = rowArea + area
            let candidateMin = min(rowMin, area)
            let candidateMax = max(rowMax, area)
            if rowStart == index || worstAspectRatio(
                sum: candidateSum,
                minimum: candidateMin,
                maximum: candidateMax,
                shortSide: shortSide
            ) <= worstAspectRatio(sum: rowArea, minimum: rowMin, maximum: rowMax, shortSide: shortSide) {
                rowArea = candidateSum
                rowMin = candidateMin
                rowMax = candidateMax
            } else {
                flushRow(upTo: index)
                rowArea = area
                rowMin = area
                rowMax = area
            }
        }
        flushRow(upTo: entries.count)
        return result
    }

    private func layoutRow(
        entries: [Entry],
        range: Range<Int>,
        areas: [Double],
        rowArea: Double,
        in bounds: CGRect,
        into result: inout [(entry: Entry, rect: CGRect)]
    ) -> CGRect {
        guard bounds.width > 0, bounds.height > 0 else { return bounds }
        let lastIndex = range.upperBound - 1

        if bounds.width >= bounds.height {
            let columnWidth = min(rowArea / Double(bounds.height), Double(bounds.width))
            guard columnWidth > 0 else { return bounds }
            var cursorY = bounds.minY
            for index in range {
                let height: CGFloat
                if index == lastIndex {
                    height = max(bounds.maxY - cursorY, 0)
                } else {
                    height = min(CGFloat(areas[index] / columnWidth), bounds.maxY - cursorY)
                }
                result.append((entries[index], CGRect(
                    x: bounds.minX,
                    y: cursorY,
                    width: CGFloat(columnWidth),
                    height: height
                )))
                cursorY += height
            }
            return CGRect(
                x: bounds.minX + CGFloat(columnWidth),
                y: bounds.minY,
                width: max(bounds.width - CGFloat(columnWidth), 0),
                height: bounds.height
            )
        }

        let rowHeight = min(rowArea / Double(bounds.width), Double(bounds.height))
        guard rowHeight > 0 else { return bounds }
        var cursorX = bounds.minX
        for index in range {
            let width: CGFloat
            if index == lastIndex {
                width = max(bounds.maxX - cursorX, 0)
            } else {
                width = min(CGFloat(areas[index] / rowHeight), bounds.maxX - cursorX)
            }
            result.append((entries[index], CGRect(
                x: cursorX,
                y: bounds.minY,
                width: width,
                height: CGFloat(rowHeight)
            )))
            cursorX += width
        }
        return CGRect(
            x: bounds.minX,
            y: bounds.minY + CGFloat(rowHeight),
            width: bounds.width,
            height: max(bounds.height - CGFloat(rowHeight), 0)
        )
    }

    private func worstAspectRatio(
        sum: Double,
        minimum: Double,
        maximum: Double,
        shortSide: Double
    ) -> Double {
        guard shortSide > 0, sum > 0, minimum > 0 else { return .infinity }
        let sumSquared = sum * sum
        let sideSquared = shortSide * shortSide
        return max(
            (sideSquared * maximum) / sumSquared,
            sumSquared / (sideSquared * minimum)
        )
    }

    private func childContentBounds(in rect: CGRect) -> CGRect? {
        guard rect.width >= parameters.minimumContainerWidth,
              rect.height >= parameters.minimumContainerHeight else { return nil }
        var content = rect.insetBy(dx: parameters.containerInset, dy: parameters.containerInset)
        content.origin.y += parameters.containerHeaderHeight
        content.size.height -= parameters.containerHeaderHeight
        guard content.width > 1, content.height > 1 else { return nil }
        return content
    }

    private func normalized(_ rect: CGRect) -> CGRect {
        CGRect(
            x: rect.minX / rootSize.width,
            y: rect.minY / rootSize.height,
            width: rect.width / rootSize.width,
            height: rect.height / rootSize.height
        )
    }

    private static let branchCount = 8

    /// 同一路径始终得到同一个变体值，布局结果可重复。
    static func stableVariant(_ text: String) -> Int {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return Int(hash % 5)
    }

    private static func siblingVariant(_ position: Int, count: Int) -> Int {
        guard count > 1 else { return 2 }
        return min(4, max(0, Int(Double(position) / Double(count - 1) * 4.999)))
    }

    static func addClamped(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int64.max : sum
    }
}

/// 归一化矩形到屏幕坐标的换算与内缩。绘制、悬停和命中测试共用同一套几何，
/// 保证窗口缩放后画到哪里就能点中哪里。
enum TreemapGeometry {
    static let displayInset: CGFloat = 0.75

    static func rect(for segment: NestedTreemapSegment, in size: CGSize) -> CGRect {
        CGRect(
            x: segment.rect.minX * size.width,
            y: segment.rect.minY * size.height,
            width: segment.rect.width * size.width,
            height: segment.rect.height * size.height
        )
    }

    static func displayRect(for segment: NestedTreemapSegment, in size: CGSize) -> CGRect {
        let rect = rect(for: segment, in: size)
        let inset = min(displayInset, min(rect.width, rect.height) * 0.12)
        return rect.insetBy(dx: inset, dy: inset)
    }

    /// 容器标题区域优先命中父目录，避免点到标题却选中内部文件。
    static func navigationRect(for segment: NestedTreemapSegment, in size: CGSize) -> CGRect {
        let rect = rect(for: segment, in: size)
        guard segment.showsHeader else { return displayRect(for: segment, in: size) }
        let headerHeight = min(
            NestedTreemapParameters.containerInset + NestedTreemapParameters.containerHeaderHeight,
            rect.height
        )
        let header = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: headerHeight)
        return header.insetBy(dx: displayInset, dy: displayInset)
    }
}

/// 固定网格的空间索引：只把图块放进它覆盖的桶里，悬停时只检查一个桶的候选，
/// 并按深度从深到浅命中。索引只在布局变化时重建，悬停和选中不会重建。
struct TreemapHitTestIndex: Sendable {
    static let columnCount = 32
    static let rowCount = 24

    private let segments: [NestedTreemapSegment]
    private let bucketIndices: [[Int32]]

    init(segments: [NestedTreemapSegment]) {
        self.segments = segments
        var buckets = [[Int32]](repeating: [], count: Self.columnCount * Self.rowCount)
        for (index, segment) in segments.enumerated() {
            let columns = Self.bucketRange(minimum: segment.rect.minX, maximum: segment.rect.maxX, count: Self.columnCount)
            let rows = Self.bucketRange(minimum: segment.rect.minY, maximum: segment.rect.maxY, count: Self.rowCount)
            for row in rows {
                for column in columns {
                    buckets[row * Self.columnCount + column].append(Int32(index))
                }
            }
        }
        for bucket in buckets.indices {
            buckets[bucket].sort { lhs, rhs in
                let left = segments[Int(lhs)]
                let right = segments[Int(rhs)]
                if left.depth == right.depth { return lhs > rhs }
                return left.depth > right.depth
            }
        }
        bucketIndices = buckets
    }

    func segment(at point: CGPoint, in size: CGSize) -> NestedTreemapSegment? {
        guard size.width > 0, size.height > 0 else { return nil }
        let unitX = point.x / size.width
        let unitY = point.y / size.height
        guard unitX >= 0, unitX <= 1, unitY >= 0, unitY <= 1 else { return nil }

        let column = min(Int(unitX * CGFloat(Self.columnCount)), Self.columnCount - 1)
        let row = min(Int(unitY * CGFloat(Self.rowCount)), Self.rowCount - 1)
        let candidates = bucketIndices[row * Self.columnCount + column]

        for index in candidates {
            let segment = segments[Int(index)]
            let display = TreemapGeometry.displayRect(for: segment, in: size)
            guard display.contains(point) else { continue }
            if segment.showsHeader,
               TreemapGeometry.navigationRect(for: segment, in: size).contains(point) {
                return segment
            }
            return segment
        }
        return nil
    }

    private static func bucketRange(minimum: CGFloat, maximum: CGFloat, count: Int) -> ClosedRange<Int> {
        let lower = min(max(Int(floor(minimum * CGFloat(count))), 0), count - 1)
        let adjustedMaximum = max(maximum - CGFloat.ulpOfOne, minimum)
        let upper = min(max(Int(floor(adjustedMaximum * CGFloat(count))), 0), count - 1)
        return lower...max(lower, upper)
    }
}
