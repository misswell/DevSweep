import CoreGraphics
import Foundation
import XCTest
@testable import DevSweep

@MainActor
final class TreemapChartModelTests: XCTestCase {
    func testLayoutAppliesAndExposesLookupAndHitTesting() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let model = TreemapChartModel()
        model.requestLayout(
            snapshot: fixture.snapshot,
            rootIndex: 0,
            size: CGSize(width: 800, height: 500),
            parameters: NestedTreemapParameters(),
            classifier: DiscoveryClassifier(knownCacheLocations: [])
        )
        try await waitForLayout(model)

        XCTAssertFalse(model.renderedSegments.isEmpty)
        XCTAssertFalse(model.renderData.paints.isEmpty)
        XCTAssertEqual(model.renderedSegments.count, model.renderData.paints.count)

        let segment = try XCTUnwrap(model.renderedSegments.first { $0.depth == 0 })
        let size = CGSize(width: 800, height: 500)
        let rect = TreemapGeometry.displayRect(for: segment, in: size)
        XCTAssertEqual(model.layout.segment(nodeID: segment.nodeID)?.id, segment.id)
        let hit = model.layout.segment(at: CGPoint(x: rect.midX, y: rect.maxY - 2), in: size)
        XCTAssertNotNil(hit)
    }

    func testHoverDoesNotInvalidateLayout() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let model = TreemapChartModel()
        model.requestLayout(
            snapshot: fixture.snapshot,
            rootIndex: 0,
            size: CGSize(width: 700, height: 420),
            parameters: NestedTreemapParameters(),
            classifier: DiscoveryClassifier(knownCacheLocations: [])
        )
        try await waitForLayout(model)
        let version = model.layoutVersion
        let first = try XCTUnwrap(model.renderedSegments.first)

        model.setHovered(first)
        XCTAssertEqual(model.hoveredSegmentID, first.id)
        XCTAssertEqual(model.layoutVersion, version, "悬停不能触发布局重算")
        model.setHovered(nil)
        XCTAssertNil(model.hoveredSegmentID)
        XCTAssertEqual(model.layoutVersion, version)
    }

    /// 尺寸变化会发起新请求，旧请求即使算完也不能覆盖新结果。
    func testSupersededLayoutRequestIsDiscarded() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let model = TreemapChartModel()
        model.requestLayout(
            snapshot: fixture.snapshot,
            rootIndex: 0,
            size: CGSize(width: 400, height: 300),
            parameters: NestedTreemapParameters(),
            classifier: DiscoveryClassifier(knownCacheLocations: [])
        )
        model.requestLayout(
            snapshot: fixture.snapshot,
            rootIndex: 0,
            size: CGSize(width: 900, height: 520),
            parameters: NestedTreemapParameters(),
            classifier: DiscoveryClassifier(knownCacheLocations: [])
        )
        try await waitForLayout(model)

        // 布局按 900×520 计算：根图块应铺满整张画布。
        let size = CGSize(width: 900, height: 520)
        let rootSegments = model.renderedSegments.filter { $0.depth == 0 }
        let covered = rootSegments.reduce(CGFloat(0)) { $0 + $1.rect.width * $1.rect.height }
        XCTAssertEqual(covered, 1, accuracy: 0.02)
        _ = size
    }

    func testResetClearsLayoutAndHover() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let model = TreemapChartModel()
        model.requestLayout(
            snapshot: fixture.snapshot,
            rootIndex: 0,
            size: CGSize(width: 600, height: 400),
            parameters: NestedTreemapParameters(),
            classifier: DiscoveryClassifier(knownCacheLocations: [])
        )
        try await waitForLayout(model)
        model.setHovered(model.renderedSegments.first)
        model.reset()

        XCTAssertTrue(model.renderedSegments.isEmpty)
        XCTAssertNil(model.hoveredSegmentID)
        XCTAssertNil(model.hoveredSegment)
    }

    func testDepthLimitChangesLayout() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let model = TreemapChartModel()
        var parameters = NestedTreemapParameters()
        parameters.depthLimit = 1
        model.requestLayout(
            snapshot: fixture.snapshot,
            rootIndex: 0,
            size: CGSize(width: 600, height: 400),
            parameters: parameters,
            classifier: DiscoveryClassifier(knownCacheLocations: [])
        )
        try await waitForLayout(model)
        XCTAssertEqual(model.renderedSegments.map(\.depth).max(), 0)
    }

    private func waitForLayout(_ model: TreemapChartModel, timeout: TimeInterval = 30) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while model.isLayoutRunning && Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertFalse(model.isLayoutRunning, "布局应在超时前完成")
    }

    private func makeFixture() throws -> (root: URL, snapshot: DiscoveryTreeSnapshot) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevSweepChartModel-\(UUID().uuidString)")
        let fileManager = FileManager.default
        for (name, megabytes) in [("alpha", 8), ("beta", 5), ("gamma", 2)] {
            let directory = root.appendingPathComponent(name)
            try fileManager.createDirectory(
                at: directory.appendingPathComponent("nested"),
                withIntermediateDirectories: true
            )
            try Data(repeating: 0x5A, count: megabytes * 1_048_576)
                .write(to: directory.appendingPathComponent("payload.bin"))
            try Data(repeating: 0x5A, count: 131_072)
                .write(to: directory.appendingPathComponent("nested/deep.bin"))
        }
        return (root, DiscoveryTreeScanEngine.scan(root: root))
    }
}
