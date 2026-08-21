import XCTest
@testable import DevSweep

final class DockerCleanupTests: XCTestCase {
    func testParsesDockerReclaimableSizes() {
        XCTAssertEqual(DockerReclaimableSize.bytes(from: "5.04GB (99%)"), 5_040_000_000)
        XCTAssertEqual(DockerReclaimableSize.bytes(from: "44MB (100%)"), 44_000_000)
        XCTAssertEqual(DockerReclaimableSize.bytes(from: "8.192kB"), 8_192)
        XCTAssertEqual(DockerReclaimableSize.bytes(from: "0B"), 0)
        XCTAssertNil(DockerReclaimableSize.bytes(from: "unknown"))
        XCTAssertNil(DockerReclaimableSize.bytes(from: "999999999999999999999TB"))
    }

    func testMapsDockerReportTypesAndUsesExplicitPruneCommands() {
        XCTAssertEqual(DockerCleanupTarget(dockerType: "Images"), .images)
        XCTAssertEqual(DockerCleanupTarget(dockerType: "Local Volumes"), .volumes)
        XCTAssertNil(DockerCleanupTarget(dockerType: "Networks"))
        XCTAssertEqual(DockerCleanupTarget.images.arguments, ["image", "prune", "--all", "--force"])
        XCTAssertEqual(DockerCleanupTarget.volumes.arguments, ["volume", "prune", "--all", "--force"])
        XCTAssertEqual(DockerCleanupTarget.buildCache.arguments, ["builder", "prune", "--all", "--force"])
    }

    func testDockerItemsAreNotSelectedByDefault() {
        let item = CacheItem(
            category: "Docker",
            name: "未使用镜像 · Docker",
            path: URL(fileURLWithPath: "/tmp/devsweep-docker-images"),
            size: 1,
            risk: .review,
            kind: .dockerPrune,
            identifier: DockerCleanupTarget.images.rawValue
        )

        XCTAssertFalse(item.isSelected)
    }
}
