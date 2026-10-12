import UIKit
import WebKit
import XCTest
@testable import FountisConnect

/// `Presenter.present` must never leave a show() waiting on a sheet UIKit refused to show, and the sheet must finish
/// exactly once whatever order things happen in (its `onFinish` resumes a CheckedContinuation: twice would crash the
/// host app). The suite is hostless, so there is no app and no window to present into. An orphan `UIViewController()`
/// that was never put in a window is a real UIKit refusal: `present` only logs a warning and nothing ever happens.
/// Never present on a window-hosted controller here: that stalls and leaves the test process hanging at exit.
/// Timeouts are fractions of a second; production uses `sheetAppearTimeout` (10 s).
@MainActor
final class SheetPresentationTests: XCTestCase {
    private var engineURL: URL!
    private var shown = 0
    private var finishes: [SheetController.Finish] = []

    override func setUpWithError() throws {
        engineURL = FileManager.default.temporaryDirectory.appendingPathComponent("sheet-presentation-\(UUID().uuidString).html")
        try "<!doctype html><title>engine</title>".write(to: engineURL, atomically: true, encoding: .utf8)
        shown = 0
        finishes = []
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: engineURL)
    }

    private func makeSheet() -> SheetController {
        SheetController(
            engineURL: engineURL,
            initPayload: [:],
            api: ApiClient(base: URL(string: "https://connect.invalid/v1")!, key: "pk_test_unit"),
            attemptToken: "attempt",
            onShown: { [weak self] in self?.shown += 1 },
            onFinish: { [weak self] fin in self?.finishes.append(fin) }
        )
    }

    /// Spins the main run loop until `condition` holds (or `seconds` pass).
    private func wait(_ seconds: TimeInterval = 2, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
    }

    private func pause(_ seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// What UIKit does when it really starts showing, and later takes the sheet away.
    private func appear(_ sheet: SheetController) {
        sheet.beginAppearanceTransition(true, animated: false)
        sheet.endAppearanceTransition()
    }

    private func disappear(_ sheet: SheetController) {
        sheet.beginAppearanceTransition(false, animated: false)
        sheet.endAppearanceTransition()
    }

    private func hasWebView(_ sheet: SheetController) -> Bool {
        sheet.isViewLoaded && sheet.view.subviews.contains { $0 is WKWebView }
    }

    // MARK: a refused presentation

    func testRefusedPresentationFinishesOnceAsUnavailable() async throws {
        let sheet = makeSheet()
        let orphan = UIViewController()
        Presenter.present(sheet, on: orphan, timeout: 0.2)
        XCTAssertTrue(finishes.isEmpty, "nothing finishes before the watchdog fires")
        try await wait { !finishes.isEmpty }
        try await pause(0.4) // room for a second, wrong, call
        XCTAssertEqual(finishes.count, 1)
        XCTAssertEqual(finishes.first?.unavailable, true)
        XCTAssertNil(finishes.first?.outcome)
        XCTAssertEqual(shown, 0, "a sheet that never appeared must not report shown")
        XCTAssertFalse(hasWebView(sheet), "UIKit loads the view of a presentation it refuses; that must not start the engine")
    }

    func testTheWatchdogKeepsARefusedSheetAlive() async throws {
        weak var weakSheet: SheetController?
        do {
            let sheet = makeSheet()
            weakSheet = sheet
            Presenter.present(sheet, on: UIViewController(), timeout: 0.2)
        }
        try await pause(0.05)
        XCTAssertNotNil(weakSheet, "the sheet must outlive the call: if it deallocates, its onFinish (and the continuation) is dropped")
        try await wait { !finishes.isEmpty }
        XCTAssertEqual(finishes.count, 1)
        XCTAssertEqual(finishes.first?.unavailable, true)
    }

    // MARK: an abandoned sheet UIKit shows after all

    func testAnAbandonedSheetShownLateDoesNothing() async throws {
        let sheet = makeSheet()
        Presenter.present(sheet, on: UIViewController(), timeout: 0.2)
        try await wait { !finishes.isEmpty }
        XCTAssertEqual(finishes.count, 1)

        appear(sheet)
        XCTAssertFalse(hasWebView(sheet), "an abandoned sheet builds no web view, so it loads no engine")
        disappear(sheet)
        sheet.abandonIfNotShown()
        try await pause(0.3)

        XCTAssertEqual(finishes.count, 1, "onFinish must never run a second time")
        XCTAssertEqual(shown, 0, "an abandoned sheet must not report shown when UIKit shows it late")
    }

    func testAbandoningTwiceFinishesOnce() {
        let sheet = makeSheet()
        sheet.abandonIfNotShown()
        sheet.abandonIfNotShown()
        XCTAssertEqual(finishes.count, 1)
        XCTAssertEqual(finishes.first?.unavailable, true)
    }

    // MARK: a sheet that does appear

    func testASheetThatStartsAppearingIsNotAbandoned() async throws {
        let sheet = makeSheet()
        Presenter.present(sheet, on: UIViewController(), timeout: 0.3)
        appear(sheet)
        XCTAssertEqual(shown, 1)
        XCTAssertTrue(hasWebView(sheet), "a live sheet hosts the engine")

        try await pause(0.7) // well past the watchdog
        XCTAssertTrue(finishes.isEmpty, "the watchdog must leave a sheet that is appearing alone")
        XCTAssertEqual(shown, 1)

        appear(sheet) // viewWillAppear can run again (a picker closing over the sheet); shown stays once
        XCTAssertEqual(shown, 1)

        disappear(sheet)
        XCTAssertEqual(finishes.count, 1)
        XCTAssertEqual(finishes.first?.unavailable, false)
    }

    func testAbandonAfterANormalFinishDoesNothing() {
        let sheet = makeSheet()
        appear(sheet)
        disappear(sheet)
        XCTAssertEqual(finishes.count, 1)
        XCTAssertEqual(finishes.first?.unavailable, false)

        sheet.abandonIfNotShown()
        disappear(sheet)
        XCTAssertEqual(finishes.count, 1, "an abandon after a finish must not finish again")
        XCTAssertEqual(shown, 1)
    }

    func testAbandonWhileAppearingDoesNothing() {
        let sheet = makeSheet()
        sheet.beginAppearanceTransition(true, animated: false) // viewWillAppear ran, the transition is not over
        sheet.abandonIfNotShown()
        XCTAssertTrue(finishes.isEmpty)
        XCTAssertEqual(shown, 1)
        sheet.endAppearanceTransition()
        disappear(sheet)
        XCTAssertEqual(finishes.count, 1)
    }
}
