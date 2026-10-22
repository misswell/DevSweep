import CoreGraphics
import Foundation
import XCTest
@testable import DevSweep

final class FileDistributionTests: XCTestCase {
    func testGroupingMergesTailWithoutLosingBytes() {
        let nodes = (0..<10).map { index in
            node(path: "/tmp/item-\(index)", bytes: Int64((10 - index) * 1_000))
        }
        let grouped = TreemapItem.grouped(nodes: nodes, maxVisible: 5)

        XCTAssertEqual(grouped.items.count, 5)
        XCTAssertEqual(grouped.items.filter(\.isOther).count, 1)
        XCTAssertEqual(grouped.items.reduce(Int64(0)) { $0 + $1.bytes },
                       nodes.reduce(Int64(0)) { $0 + $1.measurement.allocatedBytes })
        XCTAssertEqual(grouped.items.first(where: \.isOther)?.memberIDs.count, 6)
        XCTAssertEqual(grouped.unmeasuredCount, 0)
    }

    func testGroupingCountsUnmeasuredNodesSeparately() {
        let nodes = [
            node(path: "/tmp/known", bytes: 2_000),
            node(path: "/tmp/unknown", bytes: 0, state: .failed)
        ]
        let grouped = TreemapItem.grouped(nodes: nodes, maxVisible: 10)

        XCTAssertEqual(grouped.items.count, 1)
        XCTAssertEqual(grouped.unmeasuredCount, 1)
    }

    func testTreemapAreasAreProportionalAndInsideBounds() {
        let items = [
            TreemapItem(id: "a", name: "a", bytes: 6_000, memberIDs: ["a"], isOther: false),
            TreemapItem(id: "b", name: "b", bytes: 3_000, memberIDs: ["b"], isOther: false),
            TreemapItem(id: "c", name: "c", bytes: 1_000, memberIDs: ["c"], isOther: false)
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
                bytes: Int64(index * index * 137),
                memberIDs: ["item-\(index)"],
                isOther: false
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
        let single = TreemapItem(id: "one", name: "one", bytes: 100, memberIDs: ["one"], isOther: false)
        let rects = TreemapLayout.layout(items: [single], in: CGSize(width: 200, height: 100))
        XCTAssertEqual(rects.count, 1)
        XCTAssertEqual(rects[0].frame, CGRect(x: 0, y: 0, width: 200, height: 100))
        XCTAssertTrue(TreemapLayout.layout(items: [], in: CGSize(width: 200, height: 100)).isEmpty)
        XCTAssertTrue(TreemapLayout.layout(items: [single], in: .zero).isEmpty)
    }

    func testSunburstAnglesFollowBytesAndCoverFullCircle() {
        let items = [
            TreemapItem(id: "a", name: "a", bytes: 60, memberIDs: ["a"], isOther: false),
            TreemapItem(id: "b", name: "b", bytes: 30, memberIDs: ["b"], isOther: false),
            TreemapItem(id: "c", name: "c", bytes: 10, memberIDs: ["c"], isOther: false)
        ]
        let sectors = SunburstLayout.layout(items: items)

        XCTAssertEqual(sectors.count, 3)
        XCTAssertEqual(sectors[0].startAngle, 0, accuracy: 0.0001)
        XCTAssertEqual(sectors[2].endAngle, 360, accuracy: 0.0001)
        XCTAssertEqual(sectors[0].span, 216, accuracy: 0.0001)
        XCTAssertEqual(sectors[1].span, 108, accuracy: 0.0001)
        XCTAssertEqual(sectors[2].span, 36, accuracy: 0.0001)
        XCTAssertEqual(sectors.reduce(0) { $0 + $1.span }, 360, accuracy: 0.0001)
    }

    func testSunburstHitTestingUsesAngleAndRadius() {
        let items = [
            TreemapItem(id: "a", name: "a", bytes: 50, memberIDs: ["a"], isOther: false),
            TreemapItem(id: "b", name: "b", bytes: 50, memberIDs: ["b"], isOther: false)
        ]
        let size = CGSize(width: 200, height: 200)
        let sectors = SunburstLayout.layout(items: items)

        let top = SunburstLayout.point(forAngle: 10, radiusFraction: 0.4, in: size)
        XCTAssertEqual(SunburstLayout.sector(at: top, in: size, sectors: sectors)?.id, "a")

        let bottom = SunburstLayout.point(forAngle: 190, radiusFraction: 0.4, in: size)
        XCTAssertEqual(SunburstLayout.sector(at: bottom, in: size, sectors: sectors)?.id, "b")

        let center = CGPoint(x: 100, y: 100)
        XCTAssertNil(SunburstLayout.sector(at: center, in: size, sectors: sectors))
        let outside = CGPoint(x: 200, y: 200)
        XCTAssertNil(SunburstLayout.sector(at: outside, in: size, sectors: sectors))
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
    }

    func testSearchMatchesNameAndPathAndKeepsSnapshotOrder() {
        let project = node(path: "/tmp/work/MyApp/node_modules", bytes: 2_000, isDirectory: true)
        let cache = node(path: "/tmp/.npm-cache", bytes: 1_000, isDirectory: true)
        let nodes = [project, cache]

        XCTAssertEqual(DiscoverySearch.filter(nodes, query: "myapp").map(\.id), [project.id])
        XCTAssertEqual(DiscoverySearch.filter(nodes, query: ".npm").map(\.id), [cache.id])
        XCTAssertEqual(DiscoverySearch.filter(nodes, query: "  ").map(\.id), nodes.map(\.id))
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
