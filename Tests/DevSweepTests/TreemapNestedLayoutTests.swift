import CoreGraphics
import Foundation
import XCTest
@testable import DevSweep

final class TreemapNestedLayoutTests: XCTestCase {
    func testNestedSegmentsStayInsideParentsAndDoNotOverlap() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = DiscoveryTreeScanEngine.scan(root: root)
        let result = NestedTreemapLayout.segments(
            in: snapshot,
            rootIndex: snapshot.rootIndex,
            size: CGSize(width: 900, height: 520)
        )

        XCTAssertFalse(result.segments.isEmpty)
        let rootSegments = result.segments.filter { $0.depth == 0 }
        XCTAssertGreaterThan(rootSegments.count, 1)
        for segment in rootSegments {
            XCTAssertGreaterThanOrEqual(segment.rect.width, 0)
            XCTAssertGreaterThanOrEqual(segment.rect.height, 0)
            XCTAssertTrue(CGRect(x: 0, y: 0, width: 1, height: 1)
                .insetBy(dx: -0.001, dy: -0.001)
                .contains(segment.rect))
        }

        // 同层兄弟不能重叠。
        let byParent = Dictionary(grouping: result.segments) { $0.containerNodeID }
        for (_, siblings) in byParent {
            for first in siblings.indices {
                for second in siblings.indices where second > first {
                    let overlap = siblings[first].rect.intersection(siblings[second].rect)
                    let area = overlap.isNull ? 0 : overlap.width * overlap.height
                    XCTAssertLessThan(area, 0.0005, "同层图块重叠：\(siblings[first].title) / \(siblings[second].title)")
                }
            }
        }

        // 子图块必须完全落在父图块内部。
        let byNode = Dictionary(uniqueKeysWithValues: result.segments.compactMap { segment in
            segment.nodeID.map { ($0, segment) }
        })
        for segment in result.segments where segment.depth > 0 {
            guard let parent = byNode[segment.containerNodeID] else { continue }
            XCTAssertTrue(parent.rect.insetBy(dx: -0.0001, dy: -0.0001).contains(segment.rect),
                          "\(segment.title) 超出父目录 \(parent.title)")
            XCTAssertGreaterThan(segment.depth, parent.depth)
        }
    }

    func testAreaIsProportionalToBytesWithinEachParent() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = DiscoveryTreeScanEngine.scan(root: root)
        let result = NestedTreemapLayout.segments(
            in: snapshot,
            rootIndex: snapshot.rootIndex,
            size: CGSize(width: 800, height: 600)
        )

        let byParent = Dictionary(grouping: result.segments) { $0.containerNodeID }
        for (_, siblings) in byParent where siblings.count > 1 {
            let totalBytes = siblings.reduce(Int64(0)) { $0 + $1.bytes }
            guard totalBytes > 0 else { continue }
            let parentArea = siblings.reduce(CGFloat(0)) { $0 + $1.rect.width * $1.rect.height }
            guard parentArea > 0 else { continue }
            for segment in siblings {
                let actual = segment.rect.width * segment.rect.height / parentArea
                let expected = CGFloat(Double(segment.bytes) / Double(totalBytes))
                XCTAssertEqual(actual, expected, accuracy: 0.02, "\(segment.title) 面积比例不符")
            }
        }
    }

    func testDepthLimitAndAggregationBoundSegmentCount() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = DiscoveryTreeScanEngine.scan(root: root)

        var parameters = NestedTreemapParameters()
        parameters.depthLimit = 1
        let shallow = NestedTreemapLayout.segments(
            in: snapshot,
            rootIndex: snapshot.rootIndex,
            size: CGSize(width: 600, height: 400),
            parameters: parameters
        )
        XCTAssertEqual(shallow.segments.map(\.depth).max(), 0)

        // 极小的最小面积会把大量子项合并，但总量必须守恒。
        parameters.depthLimit = 6
        parameters.minimumTileArea = 100_000
        let merged = NestedTreemapLayout.segments(
            in: snapshot,
            rootIndex: snapshot.rootIndex,
            size: CGSize(width: 600, height: 400),
            parameters: parameters
        )
        let rootTotal = snapshot.records[snapshot.rootIndex].allocatedBytes
        let drawnTotal = merged.segments.filter { $0.depth == 0 }.reduce(Int64(0)) { $0 + $1.bytes }
        XCTAssertEqual(drawnTotal, rootTotal)
        XCTAssertTrue(merged.segments.contains { $0.isAggregate })
    }

    func testDeterministicLayoutForSameInput() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = DiscoveryTreeScanEngine.scan(root: root)
        let size = CGSize(width: 700, height: 450)
        let first = NestedTreemapLayout.segments(in: snapshot, rootIndex: snapshot.rootIndex, size: size)
        let second = NestedTreemapLayout.segments(in: snapshot, rootIndex: snapshot.rootIndex, size: size)
        XCTAssertEqual(first.segments, second.segments)
    }

    func testHitTestPrefersDeepestTileAndRejectsGaps() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = DiscoveryTreeScanEngine.scan(root: root)
        let size = CGSize(width: 900, height: 520)
        let result = NestedTreemapLayout.segments(in: snapshot, rootIndex: snapshot.rootIndex, size: size)
        let index = TreemapHitTestIndex(segments: result.segments)

        for segment in result.segments where !segment.isAggregate {
            let rect = TreemapGeometry.displayRect(for: segment, in: size)
            guard rect.width > 6, rect.height > 6 else { continue }
            let point = CGPoint(x: rect.midX, y: rect.maxY - 1)
            guard let hit = index.segment(at: point, in: size) else { continue }
            // 命中点若落在更深的图块里，必须返回更深的那个。
            XCTAssertGreaterThanOrEqual(hit.depth, segment.depth)
        }

        XCTAssertNil(index.segment(at: CGPoint(x: -10, y: -10), in: size))
        XCTAssertNil(index.segment(at: CGPoint(x: 10, y: 10), in: .zero))
    }

    func testLargeSyntheticTreeLaysOutWithinBudget() {
        // 直接构造合成快照：1 个根 + 40 个目录 + 每个 500 个文件。
        let directoryCount = 40
        let filesPerDirectory = 500
        let total = 1 + directoryCount + directoryCount * filesPerDirectory
        var records: [DiscoveryTreeRecord] = []
        records.reserveCapacity(total)
        records.append(DiscoveryTreeRecord(
            name: "root", parentIndex: -1, allocatedBytes: 0, logicalBytes: 0,
            fileCount: 0, directoryCount: 0, skippedCount: 0,
            isDirectory: true, isHidden: false, isCrossVolume: false,
            isSharedAllocationDeduplicated: false, modifiedAt: nil
        ))
        var parentIndices: [Int32] = [-1]
        var rootBytes: Int64 = 0
        for directory in 0..<directoryCount {
            let directoryIndex = records.count
            records.append(DiscoveryTreeRecord(
                name: "dir-\(directory)", parentIndex: 0, allocatedBytes: 0, logicalBytes: 0,
                fileCount: 0, directoryCount: 0, skippedCount: 0,
                isDirectory: true, isHidden: false, isCrossVolume: false,
                isSharedAllocationDeduplicated: false, modifiedAt: nil
            ))
            parentIndices.append(0)
            var directoryBytes: Int64 = 0
            for file in 0..<filesPerDirectory {
                let bytes = Int64(((directory * 31 + file * 17) % 4_096) + 1) * 512
                directoryBytes += bytes
                records.append(DiscoveryTreeRecord(
                    name: "file-\(file).bin", parentIndex: Int32(directoryIndex),
                    allocatedBytes: bytes, logicalBytes: bytes, fileCount: 1,
                    directoryCount: 0, skippedCount: 0, isDirectory: false,
                    isHidden: false, isCrossVolume: false,
                    isSharedAllocationDeduplicated: false, modifiedAt: nil
                ))
                parentIndices.append(Int32(directoryIndex))
            }
            records[directoryIndex].allocatedBytes = directoryBytes
            records[directoryIndex].fileCount = Int32(filesPerDirectory)
            rootBytes += directoryBytes
        }
        records[0].allocatedBytes = rootBytes
        records[0].fileCount = Int32(directoryCount * filesPerDirectory)

        var childCounts = [Int32](repeating: 0, count: records.count)
        for index in 1..<records.count { childCounts[Int(parentIndices[index])] += 1 }
        var cursor: Int32 = 0
        for index in records.indices {
            records[index].firstChildIndex = cursor
            records[index].childCount = childCounts[index]
            cursor += childCounts[index]
        }
        var placement = records.map(\.firstChildIndex)
        var children = [Int32](repeating: 0, count: Int(cursor))
        for index in 1..<records.count {
            let parent = Int(parentIndices[index])
            children[Int(placement[parent])] = Int32(index)
            placement[parent] += 1
        }
        let snapshot = DiscoveryTreeSnapshot(
            rootIndex: 0, records: records, childIndices: children,
            rootURL: URL(fileURLWithPath: "/synthetic"), scannedAt: Date(),
            duration: 0, wasCancelled: false, limitReached: false,
            checkedCount: total, symlinkCount: 0, crossVolumeCount: 0,
            unreadableCount: 0, sharedDeduplicatedCount: 0, issues: []
        )

        _ = NestedTreemapLayout.segments(
            in: snapshot,
            rootIndex: 0,
            size: CGSize(width: 1_200, height: 760)
        )
        let startedAt = Date()
        let result = NestedTreemapLayout.segments(
            in: snapshot,
            rootIndex: 0,
            size: CGSize(width: 1_200, height: 760)
        )
        let elapsed = Date().timeIntervalSince(startedAt)
        print("DevSweep nested layout: \(result.segments.count) segments in \(String(format: "%.1f", elapsed * 1000)) ms")

        var dense = NestedTreemapParameters()
        dense.minimumTileArea = 2
        let denseResult = NestedTreemapLayout.segments(
            in: snapshot,
            rootIndex: 0,
            size: CGSize(width: 1_200, height: 760),
            parameters: dense
        )
        // 取三次中最好的一次，避免机器正在跑其他构建任务时把断言变成测机器负载。
        var best = TimeInterval.greatestFiniteMagnitude
        for _ in 0..<3 {
            let denseStartedAt = Date()
            _ = NestedTreemapLayout.segments(
                in: snapshot,
                rootIndex: 0,
                size: CGSize(width: 1_200, height: 760),
                parameters: dense
            )
            best = min(best, Date().timeIntervalSince(denseStartedAt))
        }
        print("DevSweep dense layout: \(denseResult.segments.count) segments in \(String(format: "%.1f", best * 1000)) ms")
        XCTAssertLessThanOrEqual(denseResult.segments.count, dense.maximumSegmentCount)
#if DEBUG
        // Debug 构建没有优化；Release 下同样的数据约 75 ms。
        XCTAssertLessThan(best, 1.2, "接近图块上限的布局必须可控")
#else
        XCTAssertLessThan(best, 0.15, "接近图块上限的布局必须可控")
#endif

        XCTAssertLessThanOrEqual(result.segments.count, NestedTreemapParameters().maximumSegmentCount)
        XCTAssertLessThan(elapsed, 1.0, "两万级图块的布局必须在 1 秒内完成")

        let indexStartedAt = Date()
        let index = TreemapHitTestIndex(segments: result.segments)
        for _ in 0..<2_000 {
            _ = index.segment(at: CGPoint(x: 500, y: 300), in: CGSize(width: 1_200, height: 760))
        }
        let indexElapsed = Date().timeIntervalSince(indexStartedAt)
        print("DevSweep hit test: 2000 probes in \(String(format: "%.1f", indexElapsed * 1000)) ms")
        XCTAssertLessThan(indexElapsed / 2_000, 0.002)
    }

    private func makeTree() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevSweepNested-\(UUID().uuidString)")
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        for (directoryName, megabytes) in [("alpha", 6), ("beta", 3), ("gamma", 1)] {
            let directory = root.appendingPathComponent(directoryName)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(repeating: 0x5A, count: megabytes * 1_048_576)
                .write(to: directory.appendingPathComponent("payload.bin"))
            try fileManager.createDirectory(
                at: directory.appendingPathComponent("nested"),
                withIntermediateDirectories: true
            )
            try Data(repeating: 0x5A, count: 262_144)
                .write(to: directory.appendingPathComponent("nested/deep.bin"))
        }
        try Data(repeating: 0x5A, count: 524_288).write(to: root.appendingPathComponent("loose.bin"))
        return root
    }
}
