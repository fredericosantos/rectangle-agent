/// FillRestTests.swift

import XCTest
@testable import Rectangle

/// The rect `fillRest` gives the last selected window. Pure geometry, so no screens, no
/// accessibility, no app.
final class FillRestGeometryTests: XCTestCase {

    private let visibleFrame = CGRect(x: 0, y: 0, width: 1600, height: 1000)
    private let minSize = CGSize(width: 400, height: 250)
    private let rightHalf = CGRect(x: 800, y: 0, width: 800, height: 1000)

    private func fill(_ anchor: CGRect, gap: CGFloat = 0) -> CGRect? {
        MultiWindowManager.fillRect(anchor: anchor, visibleFrame: visibleFrame,
                                    gapSize: gap, minSize: minSize)
    }

    /// Beside a right half, the fill must land exactly where a real left-half action would put it.
    /// This is the test that pins the gap convention to the rest of the app.
    func testFillingBesideARightHalfMatchesTheLeftHalf() {
        let leftHalf = GapCalculation.applyGaps(CGRect(x: 0, y: 0, width: 800, height: 1000),
                                                sharedEdges: .right, gapSize: 10)
        XCTAssertEqual(fill(rightHalf, gap: 10), leftHalf)
        XCTAssertEqual(fill(rightHalf), CGRect(x: 0, y: 0, width: 800, height: 1000))
    }

    /// A third leaves two thirds, and the fill takes all of it.
    func testFillingBesideAThirdTakesTheOtherTwoThirds() {
        let firstThird = CGRect(x: 0, y: 0, width: 533, height: 1000)
        XCTAssertEqual(fill(firstThird), CGRect(x: 533, y: 0, width: 1067, height: 1000))
    }

    /// A band, not the exact complement: one window cannot be an L, so a corner anchor gives up
    /// the opposite quarter and the fill takes the larger leg.
    func testCornerAnchorFillsTheLargerLeg() {
        let corner = CGRect(x: 0, y: 0, width: 800, height: 500)
        XCTAssertEqual(fill(corner), CGRect(x: 800, y: 0, width: 800, height: 1000))
    }

    /// A window floating clear of every edge still has usable space beside it.
    func testFloatingAnchorFillsTheLargerSideBand() {
        let floating = CGRect(x: 600, y: 300, width: 400, height: 400)
        XCTAssertEqual(fill(floating), CGRect(x: 0, y: 0, width: 600, height: 1000))
    }

    /// A maximized window leaves nothing, so nothing moves.
    func testMaximizedAnchorRefuses() {
        XCTAssertNil(fill(visibleFrame))
    }

    /// Refusal is about size, not shape: when every leftover band is under the minimum, nothing
    /// moves rather than a window being squeezed into a sliver.
    func testAnchorLeavingOnlySliversRefuses() {
        XCTAssertNil(fill(CGRect(x: 200, y: 200, width: 1200, height: 600)))
    }

    /// A band too narrow to use is skipped in favour of one that is usable, so a hand-dragged
    /// anchor works the same way as one an action placed.
    func testUnusableBandsAreSkipped() {
        XCTAssertEqual(fill(CGRect(x: 137, y: 0, width: 663, height: 1000)),
                       CGRect(x: 800, y: 0, width: 800, height: 1000))
    }

    /// Same input, same output. This is what makes a second press a no-op.
    func testTheResultIsDeterministic() {
        XCTAssertEqual(fill(rightHalf, gap: 8), fill(rightHalf, gap: 8))
    }

    /// The minimum size is a fraction of the visible frame, as the rest of the app defines it.
    func testMinimumWindowSizeFollowsTheAppConvention() {
        let saved = (Defaults.minimumWindowWidth.value, Defaults.minimumWindowHeight.value)
        defer {
            Defaults.minimumWindowWidth.value = saved.0
            Defaults.minimumWindowHeight.value = saved.1
        }

        Defaults.minimumWindowWidth.value = 0
        Defaults.minimumWindowHeight.value = 0
        XCTAssertEqual(MultiWindowManager.minimumWindowSize(in: visibleFrame),
                       CGSize(width: 400, height: 250), "out of range falls back to a quarter")

        Defaults.minimumWindowWidth.value = 0.5
        Defaults.minimumWindowHeight.value = 0.5
        XCTAssertEqual(MultiWindowManager.minimumWindowSize(in: visibleFrame),
                       CGSize(width: 800, height: 500))
    }
}

final class FillRestActionRegistrationTests: XCTestCase {

    func testFillRestIsRegisteredForShortcuts() {
        XCTAssertEqual(WindowAction.fillRest.name, "fillRest")
        XCTAssertTrue(WindowAction.active.contains(.fillRest))
        XCTAssertTrue(WindowAction.fillRest.excludedFromMenu)
        XCTAssertNil(WindowAction.fillRest.category)
        XCTAssertNil(WindowAction.fillRest.classification)
        XCTAssertEqual(WindowAction.fillRest.settingsDisplayName, "Fill Rest")
    }
}
