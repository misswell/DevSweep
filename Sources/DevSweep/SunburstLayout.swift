import CoreGraphics

/// 环形图的一层。`items` 是该目录直接子项的分组结果，
/// `enteredID` 是本层中被展开进入下一层的那个图块。
struct SunburstLevel: Hashable {
    let items: [TreemapItem]
    let enteredID: String?

    var totalBytes: Int64 { items.reduce(0) { $0 + $1.bytes } }
}

struct SunburstSector: Identifiable, Hashable {
    let item: TreemapItem
    /// 从内到外的层序号，0 是最靠近圆心的一层。
    let level: Int
    /// 从 12 点方向顺时针起算的角度，范围 0...360。
    let startAngle: Double
    let endAngle: Double
    /// 相对于最短边的归一化半径。
    let innerRadius: Double
    let outerRadius: Double

    var id: String { "\(level):\(item.id)" }
    var midAngle: Double { (startAngle + endAngle) / 2 }
    var span: Double { endAngle - startAngle }
}

/// 多层环形分布图。每层占用一段独立的半径区间，子层的扇区严格落在父层
/// 被展开图块的角度范围内；各层角度按本层已测量占用比例分配，
/// 父目录和子目录不会重复累计同一份空间。
enum SunburstLayout {
    static let defaultInnerRadius = 0.34
    static let defaultOuterRadius = 0.48
    /// 多层时最内圈的起始半径；层数越多，每圈越窄。
    static let multiRingStartRadius = 0.18

    /// 按层数分配归一化半径区间，从内到外。单层时沿用原来的粗环。
    static func rings(for levelCount: Int) -> [ClosedRange<Double>] {
        guard levelCount > 1 else { return [defaultInnerRadius...defaultOuterRadius] }
        let start = min(multiRingStartRadius, defaultInnerRadius)
        let span = defaultOuterRadius - start
        let thickness = span / Double(levelCount)
        return (0..<levelCount).map { index in
            (start + Double(index) * thickness)...(start + Double(index + 1) * thickness)
        }
    }

    static func layout(levels: [SunburstLevel]) -> [SunburstSector] {
        let visible = levels.filter { !$0.items.isEmpty }
        guard !visible.isEmpty else { return [] }
        let bands = rings(for: visible.count)
        var sectors: [SunburstSector] = []
        // 每一层只在父层被展开图块的角度范围内布局。
        var parentRange = 0.0...360.0

        for (index, level) in visible.enumerated() {
            let positives = level.items.filter { $0.bytes > 0 }
            guard !positives.isEmpty else { break }
            let total = positives.reduce(Int64(0)) { $0 + $1.bytes }
            guard total > 0, parentRange.lowerBound < parentRange.upperBound else { break }
            let rangeWidth = parentRange.upperBound - parentRange.lowerBound
            let band = bands[index]
            var cursor = parentRange.lowerBound

            for (position, item) in positives.enumerated() {
                let span = position == positives.count - 1
                    ? max(0, parentRange.upperBound - cursor)
                    : Double(item.bytes) / Double(total) * rangeWidth
                sectors.append(SunburstSector(
                    item: item,
                    level: index,
                    startAngle: cursor,
                    endAngle: cursor + span,
                    innerRadius: band.lowerBound,
                    outerRadius: band.upperBound
                ))
                cursor += span
            }

            guard let enteredID = level.enteredID,
                  let expanded = sectors.first(where: { $0.level == index && $0.item.id == enteredID })
            else { break }
            parentRange = expanded.startAngle...expanded.endAngle
        }
        return sectors
    }

    /// 单层图的便捷入口：整圈就是当前层。
    static func layout(items: [TreemapItem]) -> [SunburstSector] {
        layout(levels: [SunburstLevel(items: items, enteredID: nil)])
    }

    static func sector(
        at point: CGPoint,
        in size: CGSize,
        sectors: [SunburstSector]
    ) -> SunburstSector? {
        guard !sectors.isEmpty, size.width > 0, size.height > 0 else { return nil }
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let dx = point.x - center.x
        let dy = point.y - center.y
        let distance = sqrt(dx * dx + dy * dy)
        let normalizedRadius = Double(distance / (min(size.width, size.height) / 2))
        // 先按半径确定落在哪一层，再在该层内按角度命中扇区。
        let inRing = sectors.filter {
            normalizedRadius >= $0.innerRadius && normalizedRadius <= $0.outerRadius
        }
        guard !inRing.isEmpty else { return nil }

        // 画布坐标 y 向下；12 点方向是 -90°，顺时针角度用 atan2 + 90° 归一化。
        let degrees = atan2(Double(dy), Double(dx)) * 180 / .pi + 90
        let angle = degrees < 0 ? degrees + 360 : degrees.truncatingRemainder(dividingBy: 360)
        return inRing.first { sector in
            if sector.endAngle >= 360 {
                return angle >= sector.startAngle || angle <= sector.endAngle - 360
            }
            return angle >= sector.startAngle && angle < sector.endAngle
        }
    }

    static func point(
        forAngle angle: Double,
        radiusFraction: Double,
        in size: CGSize
    ) -> CGPoint {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radians = (angle - 90) * .pi / 180
        let radius = min(size.width, size.height) / 2 * radiusFraction
        return CGPoint(
            x: center.x + cos(radians) * radius,
            y: center.y + sin(radians) * radius
        )
    }
}
