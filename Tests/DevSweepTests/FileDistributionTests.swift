import CoreGraphics
import Foundation
import XCTest
@testable import DevSweep

final class FileDistributionTests: XCTestCase {
    func testGroupingMergesTailWithoutLosingBytes() {
        let nodes = (0..<10).map { index in
            node(path: "/tmp/item-\(index)", bytes: Int64((10 - index) * 1_000))
        }
        let grouped = TreemapGrouping.grouped(nodes: nodes, maxVisible: 5)

        XCTAssertEqual(grouped.items.count, 5)
        XCTAssertEqual(grouped.items.filter(\.isOther).count, 1)
        XCTAssertEqual(grouped.items.reduce(Int64(0)) { $0 + $1.bytes },
                       nodes.reduce(Int64(0)) { $0 + $1.measurement.allocatedBytes })
        XCTAssertEqual(grouped.items.first(where: \.isOther)?.memberCount, 6)
        XCTAssertEqual(grouped.unmeasuredCount, 0)
        XCTAssertEqual(grouped.emptyCount, 0)
        XCTAssertEqual(grouped.drawnIDs.count, 4)
        XCTAssertFalse(grouped.isLowerBound)
    }

    /// 0 B 是可靠的测量结果，不能和「无法统计」混在一起。
    func testGroupingSeparatesEmptyEntriesFromUnmeasurableOnes() {
        let nodes = [
            node(path: "/tmp/known", bytes: 2_000),
            node(path: "/tmp/empty", bytes: 0),
            node(path: "/tmp/locked", bytes: 0, state: .failed),
            node(path: "/tmp/timeout", bytes: 0, state: .timedOut)
        ]
        let grouped = TreemapGrouping.grouped(nodes: nodes, maxVisible: 10)

        XCTAssertEqual(grouped.items.count, 1)
        XCTAssertEqual(grouped.emptyCount, 1)
        XCTAssertEqual(grouped.unmeasuredCount, 2)
        XCTAssertEqual(grouped.incompleteCount, 2)
        XCTAssertTrue(grouped.isLowerBound, "0 B 的超时或失败项同样让总量变成下限")
        XCTAssertFalse(grouped.totalIsUnknown, "仍有一项精确测量的 2 KB")
    }

    /// 0 B 的超时项不绘制，但必须让合计和警示一起降级为下限。
    func testZeroByteTimeoutMakesTotalALowerBound() {
        let nodes = [
            node(path: "/tmp/exact-a", bytes: 6_000),
            node(path: "/tmp/exact-b", bytes: 4_000),
            node(path: "/tmp/timeout", bytes: 0, state: .timedOut)
        ]
        let grouped = TreemapGrouping.grouped(nodes: nodes, maxVisible: 10)

        XCTAssertEqual(grouped.totalBytes, 10_000)
        XCTAssertEqual(grouped.unmeasuredCount, 1)
        XCTAssertEqual(grouped.incompleteCount, 1)
        XCTAssertEqual(grouped.lowerBoundCount, 0, "没有可绘制的下限图块")
        XCTAssertTrue(grouped.isLowerBound, "合计不能继续声称精确")
        XCTAssertFalse(grouped.totalIsUnknown)
    }

    /// 全部条目都无法测量时，0 B 不是有效合计。
    func testAllUnmeasuredEntriesReportUnknownTotal() {
        let nodes = [
            node(path: "/tmp/failed", bytes: 0, state: .failed),
            node(path: "/tmp/timeout", bytes: 0, state: .timedOut),
            node(path: "/tmp/partial", bytes: 0, state: .partial)
        ]
        let grouped = TreemapGrouping.grouped(nodes: nodes, maxVisible: 10)

        XCTAssertTrue(grouped.items.isEmpty)
        XCTAssertEqual(grouped.unmeasuredCount, 3)
        XCTAssertEqual(grouped.incompleteCount, 3)
        XCTAssertTrue(grouped.isLowerBound)
        XCTAssertTrue(grouped.totalIsUnknown)
        XCTAssertEqual(grouped.totalBytes, 0)
    }

    /// 只有完整测量到的 0 B 是精确值，不能误报成未知。
    func testAllEmptyButCompleteEntriesKeepKnownZeroTotal() {
        let nodes = [
            node(path: "/tmp/empty-a", bytes: 0),
            node(path: "/tmp/empty-b", bytes: 0)
        ]
        let grouped = TreemapGrouping.grouped(nodes: nodes, maxVisible: 10)

        XCTAssertTrue(grouped.items.isEmpty)
        XCTAssertFalse(grouped.isLowerBound)
        XCTAssertFalse(grouped.totalIsUnknown)
        XCTAssertEqual(grouped.emptyCount, 2)
    }

    func testGroupingMarksLowerBoundTilesAndTotals() {
        let nodes = [
            node(path: "/tmp/partial", bytes: 4_000, state: .partial),
            node(path: "/tmp/exact", bytes: 1_000)
        ]
        let grouped = TreemapGrouping.grouped(nodes: nodes, maxVisible: 10)

        XCTAssertTrue(grouped.isLowerBound)
        XCTAssertEqual(grouped.lowerBoundCount, 1)
        XCTAssertEqual(grouped.totalBytes, 5_000)
        XCTAssertEqual(grouped.items.first(where: { $0.id == "/tmp/partial" })?.isLowerBound, true)
        XCTAssertEqual(grouped.items.first(where: { $0.id == "/tmp/exact" })?.isLowerBound, false)
    }

    func testGroupingMergesLowerBoundTailIntoOtherFlag() throws {
        let nodes = (0..<20).map { index in
            node(
                path: "/tmp/item-\(index)",
                bytes: Int64(index + 1) * 100,
                state: index < 2 ? .partial : .complete
            )
        }
        let grouped = TreemapGrouping.grouped(nodes: nodes, maxVisible: 6)

        XCTAssertEqual(grouped.items.count, 6)
        let other = try XCTUnwrap(grouped.items.first(where: \.isOther))
        XCTAssertEqual(other.memberCount, 15)
        // 两个最小项测量不完整，被合进同一个「其他」图块：
        // 可见下限图块只有 1 个，底层不完整条目仍是 2 个。
        XCTAssertEqual(other.isLowerBound, true)
        XCTAssertEqual(grouped.lowerBoundCount, 1)
        XCTAssertEqual(grouped.incompleteCount, 2)
        XCTAssertTrue(grouped.isLowerBound)
        XCTAssertFalse(grouped.drawnIDs.contains("/tmp/item-0"))
        XCTAssertEqual(grouped.totalBytes, nodes.reduce(Int64(0)) { $0 + $1.measurement.allocatedBytes })
    }

    /// 绘制上限截断的是图块数量，不是数据：尾部只保留计数，不常驻成员 ID。
    func testGroupingStaysBoundedOnHugeLayer() {
        let count = 100_000
        let nodes = (0..<count).map {
            node(path: "/tmp/huge/\($0)", bytes: Int64($0 % 997) + 1)
        }
        let startedAt = Date()
        let grouped = TreemapGrouping.grouped(nodes: nodes)
        let elapsed = Date().timeIntervalSince(startedAt)

        XCTAssertEqual(grouped.items.count, 300)
        XCTAssertEqual(grouped.items.first(where: \.isOther)?.memberCount, count - 299)
        XCTAssertEqual(grouped.totalBytes, nodes.reduce(Int64(0)) { $0 + $1.measurement.allocatedBytes })
        XCTAssertLessThan(elapsed, 3, "十万级目录的分组不应退化成多次全量排序")
    }

    func testSnapshotFiltersLookupAndOtherMembership() {
        let kept = node(path: "/tmp/big", bytes: 9_000)
        let hidden = node(path: "/tmp/other-name", bytes: 7_000)
        // 匹配项超过绘制上限，尾部落到「其他」分组。
        let tailNodes = (0...300).map {
            node(path: "/tmp/tail-\($0)", bytes: Int64(301 - $0))
        }
        let snapshot = DistributionSnapshot(
            nodes: [kept] + tailNodes + [hidden],
            query: "tail"
        )

        XCTAssertEqual(snapshot.matchedCount, tailNodes.count)
        XCTAssertEqual(snapshot.node(for: "/tmp/tail-0")?.id, "/tmp/tail-0")
        XCTAssertNil(snapshot.node(for: kept.id), "搜索未命中的条目不在快照查找表里")
        XCTAssertTrue(snapshot.otherContains(nodeID: "/tmp/tail-300"))
        XCTAssertFalse(snapshot.otherContains(nodeID: "/tmp/tail-0"))
        XCTAssertFalse(snapshot.otherContains(nodeID: "/tmp/other-name"))
        XCTAssertFalse(snapshot.otherContains(nodeID: nil))
    }

    func testMembersAreFetchedBoundedAndOrdered() {
        let nodes = (0..<1_000).map {
            node(path: "/tmp/item-\($0)", bytes: Int64($0 + 1) * 10)
        }
        let drawn = Set(nodes.prefix(3).map(\.id))
        let top = DistributionMembers.top(in: nodes, excluding: drawn, query: "", limit: 25)

        XCTAssertEqual(top.count, 25)
        XCTAssertEqual(top.first?.id, nodes.last?.id)
        XCTAssertFalse(top.contains { drawn.contains($0.id) })
        let bytes = top.map { $0.measurement.allocatedBytes }
        XCTAssertEqual(bytes, bytes.sorted(by: >), "其他明细按占用降序返回")

        let filtered = DistributionMembers.top(in: nodes, excluding: drawn, query: "item-99", limit: 25)
        XCTAssertEqual(filtered.count, 11)
        XCTAssertEqual(filtered.first?.id, "/tmp/item-999")
    }

    func testUnmeasuredMembersKeepDiagnostics() {
        let nodes = [
            node(path: "/tmp/ok", bytes: 1_000),
            node(path: "/tmp/failed", bytes: 0, state: .failed),
            node(path: "/tmp/partial-zero", bytes: 0, state: .partial)
        ]
        let samples = DistributionMembers.unmeasured(in: nodes, query: "", limit: 10)

        XCTAssertEqual(samples.map(\.id), ["/tmp/failed", "/tmp/partial-zero"])
        XCTAssertNotNil(samples.first(where: { $0.id == "/tmp/failed" })?.measurement.warning)
    }

    func testTreemapAreasAreProportionalAndInsideBounds() {
        let items = [
            TreemapItem(id: "a", name: "a", bytes: 6_000),
            TreemapItem(id: "b", name: "b", bytes: 3_000),
            TreemapItem(id: "c", name: "c", bytes: 1_000)
        ]
        let size = CGSize(width: 400, height: 300)
        let rects = TreemapLayout.layout(items: items, in: size)

        XCTAssertEqual(rects.count, 3)
        let container = CGRect(origin: .zero, size: size)
        var totalArea: CGFloat = 0
        for rect in rects {
            XCTAssertTrue(container.insetBy(dx: -0.01, dy: -0.01).contains(rect.frame))
            XCTAssertGreaterThanOrEqual(rect.frame.width, 0)
            XCTAssertGreaterThanOrEqual(rect.frame.height, 0)
            totalArea += rect.frame.width * rect.frame.height
        }
        XCTAssertEqual(totalArea, size.width * size.height, accuracy: 0.5)

        let totalBytes = 10_000.0
        for rect in rects {
            let expected = rect.frame.width * rect.frame.height / (size.width * size.height)
            let actual = Double(rect.item.bytes) / totalBytes
            XCTAssertEqual(expected, actual, accuracy: 0.01)
        }
    }

    func testTreemapDoesNotOverlap() {
        let items = (1...12).map { index in
            TreemapItem(
                id: "item-\(index)",
                name: "item-\(index)",
                bytes: Int64(index * index * 137)
            )
        }
        let rects = TreemapLayout.layout(items: items, in: CGSize(width: 320, height: 240))
        XCTAssertEqual(rects.count, items.count)

        for first in rects.indices {
            for second in rects.indices where second > first {
                let overlap = rects[first].frame.intersection(rects[second].frame)
                let area = overlap.isNull ? 0 : overlap.width * overlap.height
                XCTAssertLessThan(area, 0.01, "\(rects[first].item.name) 与 \(rects[second].item.name) 重叠")
            }
        }
    }

    func testTreemapHandlesSingleAndEmptyInput() {
        let single = TreemapItem(id: "one", name: "one", bytes: 100)
        let rects = TreemapLayout.layout(items: [single], in: CGSize(width: 200, height: 100))
        XCTAssertEqual(rects.count, 1)
        XCTAssertEqual(rects[0].frame, CGRect(x: 0, y: 0, width: 200, height: 100))
        XCTAssertTrue(TreemapLayout.layout(items: [], in: CGSize(width: 200, height: 100)).isEmpty)
        XCTAssertTrue(TreemapLayout.layout(items: [single], in: .zero).isEmpty)
    }

    func testSunburstAnglesFollowBytesAndCoverFullCircle() {
        let items = [
            TreemapItem(id: "a", name: "a", bytes: 60),
            TreemapItem(id: "b", name: "b", bytes: 30),
            TreemapItem(id: "c", name: "c", bytes: 10)
        ]
        let sectors = SunburstLayout.layout(items: items)

        XCTAssertEqual(sectors.count, 3)
        XCTAssertEqual(sectors[0].level, 0)
        XCTAssertEqual(sectors[0].startAngle, 0, accuracy: 0.0001)
        XCTAssertEqual(sectors[2].endAngle, 360, accuracy: 0.0001)
        XCTAssertEqual(sectors[0].span, 216, accuracy: 0.0001)
        XCTAssertEqual(sectors[1].span, 108, accuracy: 0.0001)
        XCTAssertEqual(sectors[2].span, 36, accuracy: 0.0001)
        XCTAssertEqual(sectors.reduce(0) { $0 + $1.span }, 360, accuracy: 0.0001)
    }

    func testSunburstRingsSplitRadiusByLevel() {
        XCTAssertEqual(SunburstLayout.rings(for: 1), [SunburstLayout.defaultInnerRadius...SunburstLayout.defaultOuterRadius])
        let bands = SunburstLayout.rings(for: 3)
        XCTAssertEqual(bands.count, 3)
        XCTAssertEqual(bands[0].lowerBound, SunburstLayout.multiRingStartRadius, accuracy: 0.0001)
        XCTAssertEqual(bands[2].upperBound, SunburstLayout.defaultOuterRadius, accuracy: 0.0001)
        for index in 1..<bands.count {
            XCTAssertEqual(bands[index].lowerBound, bands[index - 1].upperBound, accuracy: 0.0001)
        }
    }

    /// 子层必须落在父层被展开图块的角度范围内，且不与父层重复累计。
    func testSunburstLaysChildLevelsInsideExpandedParentSector() {
        let outer = [
            TreemapItem(id: "/A", name: "A", bytes: 60, isDirectory: true),
            TreemapItem(id: "/B", name: "B", bytes: 40, isDirectory: true)
        ]
        let inner = [
            TreemapItem(id: "/A/one", name: "one", bytes: 25),
            TreemapItem(id: "/A/two", name: "two", bytes: 15)
        ]
        let sectors = SunburstLayout.layout(levels: [
            SunburstLevel(items: outer, enteredID: "/A"),
            SunburstLevel(items: inner, enteredID: nil)
        ])

        let parent = sectors.filter { $0.level == 0 }
        let children = sectors.filter { $0.level == 1 }
        XCTAssertEqual(parent.count, 2)
        XCTAssertEqual(children.count, 2)
        XCTAssertEqual(parent[0].span, 216, accuracy: 0.0001)
        for child in children {
            XCTAssertGreaterThanOrEqual(child.startAngle, parent[0].startAngle - 0.0001)
            XCTAssertLessThanOrEqual(child.endAngle, parent[0].endAngle + 0.0001)
            XCTAssertGreaterThan(child.innerRadius, parent[0].outerRadius - 0.0001)
        }
        XCTAssertEqual(children.reduce(0.0) { $0 + $1.span }, parent[0].span, accuracy: 0.0001)
        XCTAssertEqual(children[0].span, 216 * 25.0 / 40.0, accuracy: 0.0001)
    }

    func testSunburstHitTestingAcrossLevels() {
        let outer = [
            TreemapItem(id: "/A", name: "A", bytes: 60, isDirectory: true),
            TreemapItem(id: "/B", name: "B", bytes: 40, isDirectory: true)
        ]
        let inner = [
            TreemapItem(id: "/A/one", name: "one", bytes: 25),
            TreemapItem(id: "/A/two", name: "two", bytes: 15)
        ]
        let sectors = SunburstLayout.layout(levels: [
            SunburstLevel(items: outer, enteredID: "/A"),
            SunburstLevel(items: inner, enteredID: nil)
        ])
        let size = CGSize(width: 200, height: 200)
        let bands = SunburstLayout.rings(for: 2)
        let innerMid = (bands[0].lowerBound + bands[0].upperBound) / 2
        let outerMid = (bands[1].lowerBound + bands[1].upperBound) / 2

        XCTAssertEqual(
            SunburstLayout.sector(at: SunburstLayout.point(forAngle: 100, radiusFraction: outerMid, in: size), in: size, sectors: sectors)?.id,
            "1:/A/one"
        )
        XCTAssertEqual(
            SunburstLayout.sector(at: SunburstLayout.point(forAngle: 300, radiusFraction: outerMid, in: size), in: size, sectors: sectors),
            nil, "B 没有子层，外圈在它的角度范围内不应命中"
        )
        XCTAssertEqual(
            SunburstLayout.sector(at: SunburstLayout.point(forAngle: 300, radiusFraction: innerMid, in: size), in: size, sectors: sectors)?.id,
            "0:/B"
        )
        XCTAssertNil(
            SunburstLayout.sector(at: CGPoint(x: 100, y: 100), in: size, sectors: sectors),
            "圆心留空，不能命中任何扇区"
        )
    }

    func testSunburstStopsWhenExpandedItemIsMissing() {
        let sectors = SunburstLayout.layout(levels: [
            SunburstLevel(items: [TreemapItem(id: "/A", name: "A", bytes: 60)], enteredID: "/missing"),
            SunburstLevel(items: [TreemapItem(id: "/A/one", name: "one", bytes: 25)], enteredID: nil)
        ])
        XCTAssertEqual(sectors.count, 1)
        XCTAssertEqual(sectors.first?.level, 0)
    }

    func testFileTypeSummaryCoversAllDirectNodes() {
        let nodes = [
            node(path: "/tmp/photo.jpg", bytes: 1_000, logical: 2_000),
            node(path: "/tmp/main.swift", bytes: 500),
            node(path: "/tmp/node_modules", bytes: 3_000, isDirectory: true),
            node(path: "/tmp/random.bin", bytes: 200)
        ]
        let summary = FileTypeSummary.direct(nodes: nodes)
        let total = summary.reduce(Int64(0)) { $0 + $1.allocatedBytes }

        XCTAssertEqual(total, 4_700)
        XCTAssertEqual(summary.map(\.category), [.folder, .image, .source, .other])
        XCTAssertEqual(summary.first?.itemCount, 1)
        XCTAssertEqual(summary.first(where: { $0.category == .image })?.logicalBytes, 2_000)
        XCTAssertEqual(summary.first(where: { $0.category == .folder })?.itemCount, 1)
        XCTAssertTrue(summary.allSatisfy { !$0.isLowerBound })
    }

    func testFileTypeSummaryFlagsIncompleteMeasurements() {
        let nodes = [
            node(path: "/tmp/partial", bytes: 4_000, state: .partial),
            node(path: "/tmp/exact", bytes: 1_000, state: .complete)
        ]
        let summary = FileTypeSummary.direct(nodes: nodes)

        XCTAssertEqual(summary.count, 1)
        XCTAssertEqual(summary[0].lowerBoundCount, 1)
        XCTAssertTrue(summary[0].isLowerBound)
        XCTAssertEqual(summary[0].allocatedBytes, 5_000)
    }

    func testCapacitySummaryDistinguishesUnknownLowerBoundAndComplete() {
        XCTAssertEqual(
            CapacitySummary(knownBytes: 0, totalCount: 2, completeCount: 0,
                            partialCount: 1, unmeasuredCount: 1).state,
            .unknown
        )
        XCTAssertEqual(
            CapacitySummary(knownBytes: 4_000, totalCount: 2, completeCount: 1,
                            partialCount: 0, unmeasuredCount: 1).state,
            .lowerBound
        )
        XCTAssertEqual(
            CapacitySummary(knownBytes: 4_000, totalCount: 2, completeCount: 1,
                            partialCount: 1, unmeasuredCount: 0).state,
            .lowerBound
        )
        XCTAssertEqual(
            CapacitySummary(knownBytes: 0, totalCount: 2, completeCount: 2,
                            partialCount: 0, unmeasuredCount: 0).state,
            .complete
        )
        XCTAssertEqual(CapacitySummary.empty.state, .complete)
    }

    func testSearchMatchesNameAndPathAndKeepsSnapshotOrder() {
        let project = node(path: "/tmp/work/MyApp/node_modules", bytes: 2_000, isDirectory: true)
        let cache = node(path: "/tmp/.npm-cache", bytes: 1_000, isDirectory: true)
        let nodes = [project, cache]

        XCTAssertEqual(DiscoverySearch.filter(nodes, query: "myapp").map(\.id), [project.id])
        XCTAssertEqual(DiscoverySearch.filter(nodes, query: ".npm").map(\.id), [cache.id])
        XCTAssertEqual(DiscoverySearch.filter(nodes, query: "  ").map(\.id), nodes.map(\.id))
    }

    /// 同一份分组数据在两张图里必须命中同一个图块，选中与下钻才不会分叉。
    func testTreemapAndSunburstHitTheSameItem() throws {
        let items: [TreemapItem] = (1...6).map { index in
            let path = "/tmp/layer/" + String(index)
            let bytes = Int64(index * index * 1_500)
            let isDirectory = index % 2 == 0
            return TreemapItem(id: path, name: "entry-\(index)", bytes: bytes, isDirectory: isDirectory)
        }
        let size = CGSize(width: 360, height: 220)
        let rects = TreemapLayout.layout(items: items, in: size)
        let sectors = SunburstLayout.layout(items: items)
        XCTAssertEqual(rects.count, items.count)
        XCTAssertEqual(sectors.count, items.count)

        for item in items {
            let rect = try XCTUnwrap(rects.first { $0.id == item.id })
            let rectCenter = CGPoint(x: rect.frame.midX, y: rect.frame.midY)
            let treemapPick = rects.first { $0.frame.contains(rectCenter) }
            XCTAssertEqual(treemapPick?.id, item.id)

            let sector = try XCTUnwrap(sectors.first { $0.item.id == item.id })
            let radius = (sector.innerRadius + sector.outerRadius) / 2
            let point = SunburstLayout.point(forAngle: sector.midAngle, radiusFraction: radius, in: size)
            let sunburstPick = SunburstLayout.sector(at: point, in: size, sectors: sectors)
            XCTAssertEqual(sunburstPick?.item.id, item.id)
            XCTAssertEqual(sunburstPick?.item.name, item.name, "两张图共用同一份图块数据")
            XCTAssertEqual(item.url.standardizedFileURL.path, item.id, "下钻路径来自图块本身")
        }
    }

    /// 布局成本只跟绘制的图块数有关，不随本层条目数增长；悬停和选中不会触发它。
    func testLayoutCostIsBoundedByDrawCountNotLayerSize() throws {
        let count = 200_000
        let nodes = (0..<count).map {
            node(path: "/tmp/perf/\($0)", bytes: Int64($0 % 4_097) + 1)
        }
        let buildStartedAt = Date()
        let snapshot = DistributionSnapshot(nodes: nodes, query: "")
        let buildElapsed = Date().timeIntervalSince(buildStartedAt)

        XCTAssertEqual(snapshot.items.count, 300)
        XCTAssertEqual(snapshot.grouping.totalBytes, nodes.reduce(Int64(0)) { $0 + $1.measurement.allocatedBytes })
        XCTAssertLessThan(buildElapsed, 5, "一次快照构建覆盖分组、类型统计和查找表")

        let size = CGSize(width: 900, height: 520)
        let layoutStartedAt = Date()
        var drawnRects = 0
        for _ in 0..<20 {
            drawnRects += TreemapLayout.layout(items: snapshot.items, in: size).count
            _ = SunburstLayout.layout(items: snapshot.items)
        }
        let perFrame = Date().timeIntervalSince(layoutStartedAt) / 20
        XCTAssertEqual(drawnRects, 300 * 20)
        XCTAssertLessThan(perFrame, 0.05, "每帧布局只处理绘制上限内的图块")
    }

    /// 同一份数据重复构建快照的结果必须一致，缓存才可能安全。
    func testSnapshotIsDeterministicForTheSameInput() {
        let nodes = (0..<50).map {
            node(path: "/tmp/det/\($0)", bytes: Int64(50 - $0) * 1_000)
        }
        XCTAssertEqual(
            DistributionSnapshot(nodes: nodes, query: ""),
            DistributionSnapshot(nodes: nodes, query: "")
        )
    }

    private func node(
        path: String,
        bytes: Int64,
        isDirectory: Bool = false,
        logical: Int64? = nil,
        state: MeasurementState = .complete
    ) -> DiscoveryNode {
        DiscoveryNode(
            path: URL(fileURLWithPath: path),
            name: URL(fileURLWithPath: path).lastPathComponent,
            measurement: StorageMeasurement(allocatedBytes: bytes, state: state),
            classification: .unknown,
            confidence: .unknown,
            evidence: [],
            isDirectory: isDirectory,
            isHidden: false,
            modifiedAt: nil,
            logicalBytes: logical,
            cleanupCandidate: nil
        )
    }
}
