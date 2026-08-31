import Foundation
import XCTest
@testable import DevSweep

final class WindowPlacementTests: XCTestCase {
    private let visibleFrame = CGRect(x: 0, y: 0, width: 1_440, height: 900)

    func testRightSideExpandsTowardTheLeft() {
        let miniFrame = CGRect(x: 1_050, y: 100, width: 360, height: 640)
        let normalFrame = CGRect(x: 200, y: 120, width: 1_040, height: 700)

        let expanded = MiniModeWindowPlacement.expandedFrame(
            from: miniFrame,
            normalFrame: normalFrame,
            visibleFrame: visibleFrame
        )

        XCTAssertEqual(expanded.width, normalFrame.width)
        XCTAssertEqual(expanded.height, normalFrame.height)
        XCTAssertEqual(expanded.maxX, miniFrame.maxX)
        XCTAssertEqual(expanded.minY, miniFrame.maxY - normalFrame.height)
        XCTAssertTrue(visibleFrame.contains(expanded))
    }

    func testLeftSideExpandsTowardTheRight() {
        let miniFrame = CGRect(x: 30, y: 100, width: 360, height: 640)
        let normalFrame = CGRect(x: 600, y: 120, width: 1_040, height: 700)

        let expanded = MiniModeWindowPlacement.expandedFrame(
            from: miniFrame,
            normalFrame: normalFrame,
            visibleFrame: visibleFrame
        )

        XCTAssertEqual(expanded.width, normalFrame.width)
        XCTAssertEqual(expanded.height, normalFrame.height)
        XCTAssertEqual(expanded.minX, miniFrame.minX)
        XCTAssertEqual(expanded.minY, miniFrame.maxY - normalFrame.height)
        XCTAssertTrue(visibleFrame.contains(expanded))
    }

    func testExpansionClampsToVisibleFrameWhenNormalWindowIsTooLarge() {
        let miniFrame = CGRect(x: 1_200, y: 80, width: 360, height: 640)
        let oversizedNormalFrame = CGRect(x: 0, y: 0, width: 1_800, height: 1_200)

        let expanded = MiniModeWindowPlacement.expandedFrame(
            from: miniFrame,
            normalFrame: oversizedNormalFrame,
            visibleFrame: visibleFrame
        )

        XCTAssertEqual(expanded, visibleFrame)
    }
}
