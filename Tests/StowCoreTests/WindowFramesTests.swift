import CoreGraphics
import Foundation
import XCTest

@testable import StowCore

final class WindowFramesTests: XCTestCase {
    private let fallback = CGRect(x: 20, y: 20, width: 350, height: 380)
    private let minimum = CGSize(width: 260, height: 180)
    private let left = CGRect(x: 0, y: 25, width: 1440, height: 875)
    private let right = CGRect(x: 1440, y: 0, width: 1920, height: 1080)

    private func restored(_ stored: WindowFrame?, screens: [CGRect]? = nil) -> CGRect {
        restoredWindowFrame(
            stored, fallback: fallback, minimum: minimum, screens: screens ?? [left, right], defaultScreen: left)
    }

    func testUnusableSavedFramesUseTheFallback() {
        let expected = restored(nil)
        XCTAssertEqual(expected, CGRect(x: 20, y: 25, width: 350, height: 380), "Kept inside the screen")
        XCTAssertEqual(restored(.init(x: .nan, y: .infinity, width: 500, height: 500)), expected)
        XCTAssertEqual(restored(.init(x: 10, y: 10, width: 0, height: 500)), expected)
        XCTAssertEqual(restored(.init(x: 10, y: 10, width: 500, height: -1)), expected)
    }

    func testOffscreenAndOversizedFramesClampToTheScreen() {
        let frame = restored(.init(x: 1e8, y: -1e8, width: 1e7, height: 1e7))
        XCTAssertTrue([frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite))
        XCTAssertTrue([left, right].contains { $0.contains(frame) })
        XCTAssertEqual(
            restored(.init(x: 3300, y: 100, width: 400, height: 300)), CGRect(x: 2960, y: 100, width: 400, height: 300))
        XCTAssertEqual(
            restored(.init(x: -50, y: 0, width: 400, height: 300)), CGRect(x: 0, y: 25, width: 400, height: 300))
    }

    func testTheScreenWithTheMostOverlapWinsAndMinimumSizeApplies() {
        XCTAssertEqual(
            restored(.init(x: 1400, y: 100, width: 500, height: 300)), CGRect(x: 1440, y: 100, width: 500, height: 300))
        XCTAssertEqual(
            restored(.init(x: 100, y: 100, width: 50, height: 50)), CGRect(x: 100, y: 100, width: 260, height: 180))
    }

    func testNoScreensUsesTheDefaultScreen() {
        XCTAssertEqual(
            restored(.init(x: 5000, y: 100, width: 400, height: 300), screens: []),
            CGRect(x: 1040, y: 100, width: 400, height: 300))
    }
}
