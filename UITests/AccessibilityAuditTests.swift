import Foundation
import XCTest

/// Runs Xcode's accessibility audit against the real Debug app with synthetic demo state.
///
/// This has to be UI automation: SwiftUI builds its accessibility tree only for a connected assistive client,
/// so a hosted test that inspects `NSHostingView` sees an empty group.
final class AccessibilityAuditTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testBoardPassesAccessibilityAudit() throws {
        try withSyntheticApp { app in
            let board = app.windows["Stow"]
            XCTAssertTrue(board.buttons["New note"].exists, "The board's controls are not visible to the audit")
            // Cover pull request details and an open note next to a folded one.
            board.buttons["Expand pull request"].firstMatch.click()
            board.buttons["A little room to think"].click()
            XCTAssertTrue(board.textViews["note.source"].waitForExistence(timeout: 5), "The board note did not open")
            try audit(board, in: app)
        }
    }

    @MainActor
    func testDetachedNotePassesAccessibilityAudit() throws {
        try withSyntheticApp { app in
            app.buttons["Detach note"].firstMatch.click()
            let note = app.windows["Stow note"]
            XCTAssertTrue(note.waitForExistence(timeout: 5), "The detached note did not open")
            XCTAssertTrue(note.textViews["note.source"].exists, "The note editor is not visible to the audit")
            try closeBoard(app)
            try audit(note, in: app)
        }
    }

    @MainActor
    func testSettingsPassesAccessibilityAudit() throws {
        try withSyntheticApp { app in
            app.buttons["Settings"].click()
            let settings = app.windows["Stow settings"]
            XCTAssertTrue(settings.waitForExistence(timeout: 5), "Settings did not open")
            XCTAssertTrue(settings.checkBoxes["Show pull requests"].exists, "Settings controls are not visible")
            try closeBoard(app)
            try audit(settings, in: app)
        }
    }

    /// Launches Stow against a new synthetic state folder that never touches the normal data folder.
    ///
    /// The sandboxed test runner can't write outside its container, and Stow must not write inside it, so Stow
    /// creates the folder itself. `scripts/accessibility.sh` passes a temporary root and removes it afterwards.
    @MainActor
    private func withSyntheticApp(_ body: (XCUIApplication) throws -> Void) throws {
        let root = ProcessInfo.processInfo.environment["STOW_UI_TEST_STATE_ROOT"] ?? "/private/tmp"
        let folder = URL(fileURLWithPath: root, isDirectory: true)
            .appendingPathComponent("StowUITests-\(UUID().uuidString)", isDirectory: true)
        let app = XCUIApplication()
        app.launchArguments = ["--stow-testing-state", folder.path, "--stow-demo"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.windows["Stow"].waitForExistence(timeout: 15), "The board did not open")
        try body(app)
    }

    /// The audit covers every open window. The board has its own test, so other tests close it first.
    @MainActor
    private func closeBoard(_ app: XCUIApplication) throws {
        let board = app.windows["Stow"]
        board.buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertTrue(board.waitForNonExistence(timeout: 5), "The board did not close")
    }

    /// Records each issue Stow owns, logging the element so a run says what to fix.
    @MainActor
    private func audit(_ window: XCUIElement, in app: XCUIApplication) throws {
        // A tooltip under a resting pointer is a transient AppKit window; park the pointer on the titlebar.
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.02)).hover()
        // Keep auditing after the first issue so one run lists them all.
        continueAfterFailure = true
        try app.performAccessibilityAudit { issue in
            if Self.isSystemChrome(issue, in: app) { return true }
            let element = issue.element?.debugDescription.split(separator: "\n").first ?? "no element"
            print("accessibility issue: \(issue.detailedDescription) \(element)")
            return false
        }
    }

    /// Elements AppKit and UI testing add outside Stow's views, which Stow can't label or restructure.
    @MainActor
    private static func isSystemChrome(_ issue: XCUIAccessibilityAuditIssue, in app: XCUIApplication) -> Bool {
        guard let element = issue.element else { return false }
        // The virtual Touch Bar that UI testing provides, even on Macs without one.
        if element.elementType == .touchBar { return true }
        // macOS 26 nests a group inside the titlebar zoom button that its parent doesn't list as a child.
        if issue.auditType == .parentChild {
            let zoomButtons = app.buttons.matching(identifier: "_XCUI:ZoomWindow").allElementsBoundByIndex
            return zoomButtons.contains { $0.frame.contains(element.frame) }
        }
        return false
    }
}
