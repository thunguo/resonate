import XCTest

final class YuyinUITests: XCTestCase {
    private func launch(_ arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication(); app.launchArguments = ["--preview"] + arguments; app.launch(); return app
    }
    func testSignedInHomeDoesNotAskToConnectAgain() {
        let app = launch(["--home-signed-in"])
        XCTAssertTrue(app.staticTexts["libraryStartTitle"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["playLibrary"].isHittable)
        XCTAssertFalse(app.buttons["connectMusic"].exists)
        XCTAssertFalse(app.buttons["miniPlayer"].exists)
    }
    func testGuestHomeOffersLogin() {
        let app = launch(["--home-guest"])
        XCTAssertTrue(app.buttons["connectMusic"].waitForExistence(timeout: 10))
        app.buttons["connectMusic"].tap()
        XCTAssertTrue(app.textFields["phoneField"].waitForExistence(timeout: 5))
    }
    func testSignedInEmptyAndSyncStatesRemainDistinct() {
        for (flag, identifier) in [("--home-empty", "findFirstTrack"), ("--home-sync-failed", "retryHomeSync")] {
            let app = launch(["--home-signed-in", flag])
            XCTAssertTrue(app.buttons[identifier].waitForExistence(timeout: 10))
            XCTAssertFalse(app.buttons["connectMusic"].exists)
            if flag == "--home-empty" {
                app.buttons[identifier].tap()
                XCTAssertTrue(app.textFields["searchField"].waitForExistence(timeout: 5))
            }
            app.terminate()
        }
        let app = launch(["--home-signed-in", "--home-syncing"])
        XCTAssertTrue(app.staticTexts["libraryStartTitle"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["正在同步你的收藏…"].exists)
        XCTAssertFalse(app.buttons["connectMusic"].exists)
        XCTAssertFalse(app.buttons["findFirstTrack"].exists)
    }
    func testNavigationAndPlayer() throws {
        let app = launch()
        XCTAssertTrue(app.staticTexts["listenTitle"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["miniPlayer"].exists)
        let playerFrame = app.buttons["miniPlayer"].frame
        XCTAssertLessThanOrEqual(playerFrame.maxY, app.tabBars.buttons["听听"].frame.minY + 4, "播放条不能覆盖底部导航")
        app.buttons["miniPlayer"].tap()
        XCTAssertTrue(app.buttons["queueButton"].waitForExistence(timeout: 5))
        app.buttons["queueButton"].tap()
        XCTAssertTrue(app.navigationBars["播放队列"].waitForExistence(timeout: 5))
        app.buttons["完成"].tap()
        app.buttons["closePlayer"].tap()
        app.tabBars.buttons["音乐库"].tap()
        XCTAssertTrue(app.buttons["settingsButton"].waitForExistence(timeout: 5))
        app.tabBars.buttons["搜索"].tap()
        XCTAssertTrue(app.textFields["searchField"].waitForExistence(timeout: 5))
    }
    func testLargeTextKeepsPlayerControlsReachable() throws {
        let app = launch(["--player", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXL"])
        XCTAssertTrue(app.buttons["mainPlayPause"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["mainPlayPause"].isHittable)
        XCTAssertTrue(app.buttons["queueButton"].isHittable)
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "播放器-大字体"; attachment.lifetime = .keepAlways; add(attachment)
    }
    func testBYOKIsOptionalAndCustomConfigurationExists() throws {
        let app = launch(["--settings"])
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "模型服务")).firstMatch.tap()
        XCTAssertTrue(app.buttons["addProvider"].waitForExistence(timeout: 5))
        app.buttons["addProvider"].tap()
        XCTAssertTrue(app.secureTextFields["apiKeyField"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["启用"].isEnabled)
        XCTAssertTrue(app.textFields["modelIDField"].exists)
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "模型连接"; attachment.lifetime = .keepAlways; add(attachment)
    }
    func testCaptureLightDarkAndPlayer() throws {
        for (name, flags) in [("听听-浅色", []), ("听听-深色", ["--dark"]), ("播放器", ["--player"]), ("音乐库", ["--library"])] {
            let app = launch(flags)
            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
            if flags.contains("--player") {
                XCTAssertTrue(app.buttons["mainPlayPause"].waitForExistence(timeout: 5))
                XCTAssertLessThanOrEqual(app.buttons["播放器更多操作"].frame.maxX, app.frame.maxX - 16)
                XCTAssertTrue(app.buttons["lyricsButton"].isHittable)
                XCTAssertTrue(app.buttons["queueButton"].isHittable)
            }
            else { XCTAssertTrue(app.tabBars.buttons["听听"].waitForExistence(timeout: 5)) }
            let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
            app.terminate()
        }
    }
}

extension YuyinUITests {
    private func waitForValue(_ value: String, on element: XCUIElement, timeout: TimeInterval = 10) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed)
    }
    func testAudioEndAndResumeUsesActualPlayer() {
        let app = launch(["--player", "--audio-test"])
        let button = app.buttons["mainPlayPause"]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        button.tap(); waitForValue("播放中", on: button)
        XCTAssertTrue(app.staticTexts["测试音频 2"].waitForExistence(timeout: 8))
        waitForValue("已暂停", on: button, timeout: 8)
        button.tap(); waitForValue("播放中", on: button)
        app.terminate()
    }
    func testAudioPausedBeforeReadyStaysPaused() {
        let app = launch(["--player", "--audio-test", "--audio-paused"])
        let button = app.buttons["mainPlayPause"]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        waitForValue("已暂停", on: button)
        button.tap(); waitForValue("播放中", on: button)
        button.tap(); waitForValue("已暂停", on: button)
        app.terminate()
    }
    func testLongTitleAndSavedArrangementRemainUsable() {
        let app = launch(["--player", "--long-title", "--dark", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXL"])
        XCTAssertTrue(app.buttons["mainPlayPause"].waitForExistence(timeout: 10))
        for _ in 0..<4 where !app.buttons["queueButton"].isHittable { app.swipeUp() }
        XCTAssertTrue(app.buttons["queueButton"].isHittable)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "长歌名-大字体-深色"; shot.lifetime = .keepAlways; add(shot)
        app.terminate()
        let result = launch(["--ai-result"])
        XCTAssertTrue(result.staticTexts["留一点时间，慢慢走"].waitForExistence(timeout: 10))
        let screenshot = XCTAttachment(screenshot: result.screenshot()); screenshot.name = "编排结果-界面示例"; screenshot.lifetime = .keepAlways; add(screenshot)
    }
}

extension YuyinUITests {
    func testPrimaryControlsAccessibilityAudit() throws {
        let home = launch(["--home-signed-in"])
        XCTAssertTrue(home.buttons["playLibrary"].waitForExistence(timeout: 10))
        try home.performAccessibilityAudit(for: [.hitRegion, .sufficientElementDescription])
        // The contrast scanner includes obscured content; keep it opt-in for manual review.
        if ProcessInfo.processInfo.environment["YUYIN_CONTRAST_AUDIT"] == "1" {
            try home.performAccessibilityAudit(for: .contrast)
            home.swipeUp()
            try home.performAccessibilityAudit(for: .contrast)
        }
        let homeShot = XCTAttachment(screenshot: home.screenshot()); homeShot.name = "已登录-从收藏开始听"; homeShot.lifetime = .keepAlways; add(homeShot)
        home.terminate()
        let player = launch(["--player"])
        XCTAssertTrue(player.buttons["queueButton"].waitForExistence(timeout: 10))
        try player.performAccessibilityAudit(for: [.hitRegion, .sufficientElementDescription])
        if ProcessInfo.processInfo.environment["YUYIN_CONTRAST_AUDIT"] == "1" {
            try player.performAccessibilityAudit(for: .contrast)
        }
    }
}


extension YuyinUITests {
    func testLyricsAndQueueRememberReadingPosition() {
        let app = launch(["--player", "--reading-test"])
        XCTAssertTrue(app.buttons["lyricsButton"].waitForExistence(timeout: 10))
        app.buttons["lyricsButton"].tap()
        XCTAssertTrue(app.buttons["lyricLine-0"].waitForExistence(timeout: 5))
        app.swipeUp(); app.swipeUp()
        let visibleLine = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "lyricLine-")).allElementsBoundByIndex.first { $0.isHittable && $0.frame.midY > app.frame.midY - 60 && $0.frame.midY < app.frame.midY + 100 }
        XCTAssertNotNil(visibleLine)
        let identifier = visibleLine?.identifier ?? ""
        XCTAssertTrue(app.buttons["回到当前"].exists)
        app.buttons["完成"].tap(); app.buttons["lyricsButton"].tap()
        XCTAssertTrue(app.buttons[identifier].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons[identifier].isHittable)
        XCTAssertTrue(app.buttons["回到当前"].exists)
        app.buttons["完成"].tap(); app.buttons["queueButton"].tap()
        XCTAssertTrue(app.navigationBars["播放队列"].waitForExistence(timeout: 5))
        app.swipeUp(); app.swipeUp()
        let title = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "队列歌曲 ")).allElementsBoundByIndex.first { $0.isHittable && $0.frame.midY < app.frame.midY }?.label
        XCTAssertNotNil(title)
        app.buttons["完成"].tap(); app.buttons["queueButton"].tap()
        if let title { XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 5)); XCTAssertTrue(app.staticTexts[title].isHittable) }
    }
}
