import CoreGraphics

struct SunburstSector: Identifiable {
    let item: TreemapItem
    /// 从 12 点方向顺时针起算的角度，范围 0...360。
    let startAngle: Double
    let endAngle: Double
    /// 相对于最短边的归一化半径。
    let innerRadius: Double
    let outerRadius: Double

    var id: String { item.id }
    var midAngle: Double { (startAngle + endAngle) / 2 }
    var span: Double { endAngle - startAngle }
}

/// 单层环形分布图。扇区角度严格按当前层占用比例分配；
/// 进入子目录后重新扫描并替换快照，因此内外层不会重复累计同一份空间。
enum SunburstLayout {
    static let defaultInnerRadius = 0.34
    static let defaultOuterRadius = 0.48

    static func layout(
        items: [TreemapItem],
        innerRadius: Double = defaultInnerRadius,
        outerRadius: Double = defaultOuterRadius
    ) -> [SunburstSector] {
        let positives = items.filter { $0.bytes > 0 }
        let total = positives.reduce(Int64(0)) { $0 + $1.bytes }
        guard total > 0 else { return [] }

        var cursor = 0.0
        var sectors: [SunburstSector] = []
        for (index, item) in positives.enumerated() {
            let span = index == positives.count - 1
                ? max(0, 360 - cursor)
                : Double(item.bytes) / Double(total) * 360
            let sector = SunburstSector(
                item: item,
                startAngle: cursor,
                endAngle: cursor + span,
                innerRadius: innerRadius,
                outerRadius: outerRadius
            )
            sectors.append(sector)
            cursor += span
        }
        return sectors
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
        guard let first = sectors.first,
              normalizedRadius >= first.innerRadius,
              normalizedRadius <= first.outerRadius
        else { return nil }

        // 画布坐标 y 向下；12 点方向是 -90°，顺时针角度用 atan2 + 90° 归一化。
        let degrees = atan2(Double(dy), Double(dx)) * 180 / .pi + 90
        let angle = degrees < 0 ? degrees + 360 : degrees.truncatingRemainder(dividingBy: 360)
        return sectors.first { sector in
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
