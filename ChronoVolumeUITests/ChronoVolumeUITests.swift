//
//  ChronoVolumeUITests.swift
//  ChronoVolumeUITests
import XCTest

final class ChronoVolumeUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testExample() throws {
        // UI tests must launch the application that they test.
        let app = XCUIApplication()
        app.launch()

        // Use XCTAssert and related functions to verify your tests produce the correct results.
    }

    @MainActor
    func testAlphaCheaterImporterIsTopLevelAndMediaActionsAreContextual() throws {
        let app = XCUIApplication()
        app.launch()

        if !app.windows.firstMatch.waitForExistence(timeout: 2) {
            app.menuBars.menuBarItems["File"].click()
            app.menuItems["New Window"].click()
        }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))

        let importVideo = app.buttons["导入视频/模型"]
        let importAlphaCheater = app.buttons["导入AlphaCheater"]
        XCTAssertTrue(importVideo.waitForExistence(timeout: 5))
        XCTAssertTrue(importAlphaCheater.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(importAlphaCheater.frame.midY, importVideo.frame.midY)
        XCTAssertFalse(app.buttons["打开 A_color"].exists)
        XCTAssertFalse(app.buttons["添加 A_color"].exists)
        XCTAssertFalse(app.buttons["添加 B_alpha"].exists)
        XCTAssertFalse(app.buttons["移除 A_color"].exists)
        XCTAssertFalse(app.buttons["移除 B_alpha"].exists)
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
