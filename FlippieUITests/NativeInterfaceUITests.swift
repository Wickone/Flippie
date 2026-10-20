import XCTest
import UIKit

final class NativeInterfaceUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor private func launch(sample: Bool = true, largeType: Bool = false, compact: Bool = false) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-AppleInterfaceStyle", "Dark"]
        if sample { app.launchArguments.append("-loadSampleOnLaunch") }
        if compact { app.launchArguments.append("-uiCompactViewport") }
        app.launchArguments += ["-UIPreferredContentSizeCategoryName",
                                largeType ? "UICTContentSizeCategoryAccessibilityXXXL" : "UICTContentSizeCategoryL"]
        app.launch()
        return app
    }

    @MainActor func testTabsOpenNativeSheetsAndRetainPreviewAfterRepeatedDismissal() throws {
        let app = launch()
        let settings = app.buttons["playback-settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 15))
        let usesTopTabs = UIDevice.current.userInterfaceIdiom == .pad
        func tabButton(_ title: String) -> XCUIElement {
            usesTopTabs ? app.buttons[title].firstMatch : app.tabBars.buttons[title]
        }
        if !usesTopTabs { XCTAssertEqual(app.tabBars.count, 1) }
        for title in ["Preview", "Edit", "Export"] { XCTAssertTrue(tabButton(title).isHittable) }
        for _ in 0..<3 {
            for (tab, title, close) in [("Edit", "Edit Properties", "Cancel"), ("Export", "Export Animation", "Close")] {
                (usesTopTabs ? app.buttons[tab].firstMatch : app.tabBars.buttons[tab]).tap()
                XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5))
                app.buttons[close].tap()
                XCTAssertTrue(settings.waitForExistence(timeout: 5))
                XCTAssertTrue(settings.isHittable)
                if !usesTopTabs { XCTAssertEqual(app.tabBars.count, 1) }
                XCTAssertTrue(tabButton("Preview").isSelected)
            }
        }
        settings.tap()
        XCTAssertTrue(app.navigationBars["Playback Settings"].waitForExistence(timeout: 5))
        let bar = app.navigationBars["Playback Settings"]
        bar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        XCTAssertTrue(settings.isHittable)
        attach("native-preview-after-six-sheets")
    }

    @MainActor func testPortraitPreviewRetainsOriginalControlSizesAndSpacing() throws {
        let app = launch()
        let play = app.buttons["play-pause"]
        XCTAssertTrue(play.waitForExistence(timeout: 15))
        let previous = app.buttons["Previous frame"].frame
        let next = app.buttons["Next frame"].frame
        let scale = app.frame.width / 393
        attach("portrait-preview-before-geometry-assertions")
        // iOS 26 exposes the glyph bounds, not the surrounding glass, in AX.
        // Its actual glass-edge hit region is checked separately by a real tap.
        if #available(iOS 27.0, *) {
            XCTAssertEqual(play.frame.width, 90 * scale, accuracy: 1)
            XCTAssertEqual(previous.width, 64 * scale, accuracy: 1)
            XCTAssertEqual(next.width, 64 * scale, accuracy: 1)
            XCTAssertEqual(play.frame.minX - previous.maxX, 32 * scale, accuracy: 1)
            XCTAssertEqual(next.minX - play.frame.maxX, 32 * scale, accuracy: 1)
        }
        XCTAssertEqual(play.frame.midX, app.frame.width / 2, accuracy: 3)
        XCTAssertEqual(previous.midX, app.frame.width / 2 - 109 * scale, accuracy: 3)
        XCTAssertEqual(next.midX, app.frame.width / 2 + 109 * scale, accuracy: 3)
        let previewBottom = 132 * scale + min(362 * scale, app.frame.height * 0.46)
        XCTAssertEqual(play.frame.midY, previewBottom + 132 * scale, accuracy: 2)
        XCTAssertFalse(play.frame.intersects(app.tabBars.firstMatch.frame))
        XCTAssertEqual(app.tabBars.count, 1)
        attach("restored-portrait-preview-layout")
    }

    @MainActor func testPlayControlRespondsNearGlassEdge() throws {
        let app = launch()
        let play = app.buttons["play-pause"]
        XCTAssertTrue(play.waitForExistence(timeout: 15))
        let scale = app.frame.width / 393
        let y = 264 * scale + min(362 * scale, app.frame.height * 0.46)
        let oldLabel = play.label
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: app.frame.width / 2 + 38 * scale, dy: y)).tap()
        let toggled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in play.label != oldLabel }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [toggled], timeout: 3), .completed)
    }

    @MainActor func testPortraitLandingRetainsOriginalImportPositionAndSize() throws {
        let app = launch(sample: false)
        let importButton = app.buttons["import-animation"]
        XCTAssertTrue(importButton.waitForExistence(timeout: 10))
        let scale = app.frame.width / 393
        attach("portrait-landing-before-geometry-assertions")
        if #available(iOS 27.0, *) {
            XCTAssertEqual(importButton.frame.width, app.frame.width - 40, accuracy: 1)
            XCTAssertEqual(importButton.frame.height, 52 * scale, accuracy: 1)
        }
        XCTAssertEqual(importButton.frame.midX, app.frame.width / 2, accuracy: 1)
        // The former composition lifted the CTA by ten percent of the screen.
        XCTAssertEqual(importButton.frame.midY, app.frame.height * 0.9 - 34 * scale, accuracy: 2)
        XCTAssertTrue(importButton.isHittable)
        XCTAssertTrue(app.buttons["choose-bundled-animation"].isHittable)
        attach("restored-portrait-landing-layout")
    }

    @MainActor func testPhoneStaysPortraitAndPlaybackReachableAfterDeviceRotation() throws {
        let app = launch(largeType: true)
        let settings = app.buttons["playback-settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 15))
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let play = app.buttons["play-pause"]
        reveal(play, in: app)
        let reachable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: play)
        XCTAssertEqual(XCTWaiter.wait(for: [reachable], timeout: 5), .completed)
        XCTAssertTrue(app.buttons["Next frame"].isHittable)
        XCTAssertTrue(app.buttons["Previous frame"].isHittable)
        let oldLabel = play.label
        play.tap()
        XCTAssertTrue(play.waitForExistence(timeout: 3))
        XCTAssertNotEqual(play.label, oldLabel, "Tap must actually toggle Play/Pause")
        XCTAssertGreaterThan(app.frame.height, app.frame.width, "The iPhone app must stay portrait when the device turns")
        XCTAssertTrue(app.tabBars.buttons["Edit"].isHittable)
        attach("portrait-accessibility-after-device-rotation")
    }

    @MainActor func testNativeTabDragOpensCommandSheetAndSwipeDismissRestoresPreview() throws {
        let app = launch()
        let settings = app.buttons["playback-settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 15))
        let preview = app.tabBars.buttons["Preview"]
        let edit = app.tabBars.buttons["Edit"]
        preview.press(forDuration: 0.2, thenDragTo: edit)
        XCTAssertTrue(app.navigationBars["Edit Properties"].waitForExistence(timeout: 5))
        let sheet = app.navigationBars["Edit Properties"]
        sheet.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        XCTAssertTrue(preview.isSelected)
        XCTAssertTrue(settings.isHittable)
    }

    @MainActor func testLandingButtonsAndProfileHaveActions() throws {
        let app = launch(sample: false, largeType: true)
        let importButton = app.buttons["import-animation"]
        if !importButton.isHittable { app.swipeUp() }
        XCTAssertTrue(importButton.isHittable)
        importButton.tap()
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 5), "Import must present the native file picker")
        app.terminate()
        app.launch()
        app.buttons["Profile"].tap()
        XCTAssertTrue(app.alerts["Profile"].waitForExistence(timeout: 5))
        app.alerts.buttons["OK"].tap()
        let samples = app.buttons["choose-bundled-animation"]
        if !samples.isHittable { app.swipeUp() }
        samples.tap()
        XCTAssertTrue(app.navigationBars["Sample Animations"].waitForExistence(timeout: 5))
    }

    @MainActor private func attach(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor func testCompactAccessibilityLayoutAndSheetActionsRemainReachable() throws {
        let app = launch(largeType: true, compact: true)
        let settings = app.buttons["playback-settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 15))
        let progress = app.descendants(matching: .any)["Animation progress"].firstMatch
        XCTAssertTrue(progress.exists)
        XCTAssertGreaterThan(progress.frame.height, 35, "Accessibility Dynamic Type must actually be applied")
        XCTAssertLessThanOrEqual(progress.frame.width, 288)
        reveal(app.buttons["play-pause"], in: app)
        for name in ["play-pause", "Previous frame", "Next frame"] {
            XCTAssertTrue(app.buttons[name].isHittable)
        }
        let play = app.buttons["play-pause"].frame
        XCTAssertFalse(play.intersects(app.tabBars.firstMatch.frame), "Controls must not overlap the native bar")
        XCTAssertFalse(play.intersects(app.buttons["Previous frame"].frame))
        XCTAssertFalse(play.intersects(app.buttons["Next frame"].frame))
        attach("320x568-accessibility-controls")

        app.tabBars.buttons["Edit"].tap()
        XCTAssertTrue(app.navigationBars["Edit Properties"].waitForExistence(timeout: 5))
        reveal(app.staticTexts["Speed"], in: app)
        XCTAssertTrue(app.staticTexts["Speed"].isHittable)
        XCTAssertTrue(app.buttons["Cancel"].isHittable)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["play-pause"].isHittable)

        app.tabBars.buttons["Export"].tap()
        XCTAssertTrue(app.navigationBars["Export Animation"].waitForExistence(timeout: 5))
        let original = app.buttons["Original"]
        reveal(original, in: app)
        XCTAssertLessThan(original.frame.height, 100, "A size preset must not wrap into a tall column of letters at accessibility sizes")
        let export = app.buttons["Export GIF"]
        reveal(export, in: app)
        XCTAssertTrue(export.isHittable)
        XCTAssertTrue(app.buttons["Close"].isHittable)
        attach("accessibility-export-action")
        app.buttons["Close"].tap()
        XCTAssertTrue(app.buttons["play-pause"].isHittable)
    }

    @MainActor private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<10 {
            if element.isHittable { return }
            app.swipeUp()
        }
    }
}
