import CoreGraphics

struct TreemapRect: Identifiable {
    let item: TreemapItem
    let frame: CGRect

    var id: String { item.id }
}

/// Squarified Treemap：面积严格按字节数分配，只把不可见的小项合并后统一布局。
enum TreemapLayout {
    static func layout(items: [TreemapItem], in size: CGSize) -> [TreemapRect] {
        guard size.width > 0, size.height > 0 else { return [] }
        let positives = items.filter { $0.bytes > 0 }
        let total = positives.reduce(Int64(0)) { $0 + $1.bytes }
        guard total > 0 else { return [] }

        let sorted = positives.sorted { lhs, rhs in
            if lhs.bytes != rhs.bytes { return lhs.bytes > rhs.bytes }
            return lhs.id < rhs.id
        }
        let totalArea = Double(size.width) * Double(size.height)
        var remaining = sorted.map { item in
            Weighted(item: item, area: Double(item.bytes) / Double(total) * totalArea)
        }
        var free = CGRect(origin: .zero, size: size)
        var result: [TreemapRect] = []

        while !remaining.isEmpty {
            guard free.width > 0.0001, free.height > 0.0001 else { break }
            let shortSide = min(free.width, free.height)
            var row: [Weighted] = []
            var worst = Double.infinity
            var index = 0
            while index < remaining.count {
                let candidate = row + [remaining[index]]
                let ratio = worstRatio(candidate, shortSide: Double(shortSide))
                if !row.isEmpty, ratio > worst { break }
                row = candidate
                worst = ratio
                index += 1
            }
            guard !row.isEmpty else { break }
            remaining.removeFirst(row.count)
            layout(row: row, in: &free, into: &result)
        }

        return result
    }

    private struct Weighted {
        let item: TreemapItem
        let area: Double
    }

    private static func worstRatio(_ row: [Weighted], shortSide: Double) -> Double {
        let sum = row.reduce(0.0) { $0 + $1.area }
        guard sum > 0, shortSide > 0 else { return .infinity }
        let maxArea = row.map(\.area).max() ?? 0
        let minArea = row.map(\.area).min() ?? 0
        guard maxArea > 0, minArea > 0 else { return .infinity }
        let sideSquared = shortSide * shortSide
        return max(
            sideSquared * maxArea / (sum * sum),
            sum * sum / (sideSquared * minArea)
        )
    }

    private static func layout(
        row: [Weighted],
        in free: inout CGRect,
        into result: inout [TreemapRect]
    ) {
        let rowArea = row.reduce(0.0) { $0 + $1.area }
        guard rowArea > 0 else { return }

        if free.width >= free.height {
            // 左侧一列，列宽由行面积和可用高度决定。
            var columnWidth = rowArea / Double(free.height)
            columnWidth = min(columnWidth, Double(free.width))
            guard columnWidth > 0 else { return }
            var y = free.minY
            for (index, weighted) in row.enumerated() {
                let isLast = index == row.count - 1
                var height = isLast
                    ? free.maxY - y
                    : weighted.area / columnWidth
                height = max(0, min(height, free.maxY - y))
                let rect = CGRect(x: free.minX, y: y, width: columnWidth, height: height)
                result.append(TreemapRect(item: weighted.item, frame: rect))
                y += height
            }
            let newWidth = max(0, free.width - columnWidth)
            free = CGRect(x: free.minX + columnWidth, y: free.minY, width: newWidth, height: free.height)
        } else {
            // 顶部一行，行高由行面积和可用宽度决定。
            var rowHeight = rowArea / Double(free.width)
            rowHeight = min(rowHeight, Double(free.height))
            guard rowHeight > 0 else { return }
            var x = free.minX
            for (index, weighted) in row.enumerated() {
                let isLast = index == row.count - 1
                var width = isLast
                    ? free.maxX - x
                    : weighted.area / rowHeight
                width = max(0, min(width, free.maxX - x))
                let rect = CGRect(x: x, y: free.minY, width: width, height: rowHeight)
                result.append(TreemapRect(item: weighted.item, frame: rect))
                x += width
            }
            let newHeight = max(0, free.height - rowHeight)
            free = CGRect(x: free.minX, y: free.minY + rowHeight, width: free.width, height: newHeight)
        }
    }
}
