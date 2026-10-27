import XCTest
@testable import NotchMate

@MainActor
final class FaceAnimationTests: XCTestCase {
    func testLoopingAnimationDoesNotProduceNegativeIndexForEarlierTimelineDate() {
        let index = FaceAnimations.animationFrameIndex(elapsed: -0.1, fps: 12, range: 0..<48, loops: true)

        XCTAssertEqual(index, 0)
    }

    func testAnimationIndexRejectsInvalidTimelineInput() {
        XCTAssertNil(FaceAnimations.animationFrameIndex(elapsed: .nan, fps: 12, range: 0..<48, loops: true))
        XCTAssertNil(FaceAnimations.animationFrameIndex(elapsed: 1, fps: 0, range: 0..<48, loops: true))
        XCTAssertNil(FaceAnimations.animationFrameIndex(elapsed: 1, fps: 12, range: 0..<0, loops: true))
    }

    func testFrameIndexIsBoundedBeforeRendering() {
        XCTAssertNil(FaceAnimations.boundedFrameIndex(0, frameCount: 0))
        XCTAssertEqual(FaceAnimations.boundedFrameIndex(-1, frameCount: 48), 0)
        XCTAssertEqual(FaceAnimations.boundedFrameIndex(47, frameCount: 48), 47)
        XCTAssertEqual(FaceAnimations.boundedFrameIndex(48, frameCount: 48), 47)
    }
}
