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

extension YuyinUITests {
    func testSearchSwitchAndClearDoNotCarryPreviousCategory() {
        let app = launch(["--search-test"])
        app.tabBars.buttons["搜索"].tap()
        let field = app.textFields["searchField"]; field.tap(); field.typeText("fixture")
        XCTAssertTrue(app.staticTexts["曲目0"].waitForExistence(timeout: 5))
        app.segmentedControls.buttons["专辑"].tap()
        XCTAssertTrue(app.staticTexts["专辑0"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["曲目0"].exists)
        app.buttons["清空搜索"].tap()
        XCTAssertFalse(app.buttons["searchMore"].exists); XCTAssertFalse(app.staticTexts["专辑0"].exists)
        XCTAssertTrue(app.staticTexts["最近找过"].exists)
    }
    func testSearchPaginationFailureRetriesWithoutDroppingResults() {
        let app = launch(["--search-test"])
        app.tabBars.buttons["搜索"].tap()
        let field = app.textFields["searchField"]; field.tap(); field.typeText("fixture")
        XCTAssertTrue(app.staticTexts["曲目0"].waitForExistence(timeout: 5))
        let more = app.buttons["searchMore"]
        XCTAssertTrue(more.waitForExistence(timeout: 5)); more.tap()
        for _ in 0..<14 where !app.buttons["重试"].isHittable { app.swipeDown() }
        XCTAssertTrue(app.buttons["重试"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["曲目0"].exists)
        app.buttons["重试"].tap()
        for _ in 0..<14 where !app.staticTexts["曲目31"].isHittable { app.swipeUp() }
        XCTAssertTrue(app.staticTexts["曲目31"].exists)
    }
}

extension YuyinUITests {
    func testArrangementFailurePreservesSavedResultAndCollapsesPrompt() {
        let app = launch(["--ai-result", "--saved-ai-result"])
        XCTAssertTrue(app.buttons["修改需求"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "arrangementPrompt").firstMatch.exists)
        XCTAssertTrue(app.buttons["已保存到网易云"].exists)
        let adjustment = app.buttons["更熟悉"]
        for _ in 0..<3 where !adjustment.isHittable { app.swipeUp() }
        adjustment.tap()
        XCTAssertTrue(app.staticTexts["留一点时间，慢慢走"].exists)
        XCTAssertTrue(app.buttons["已保存到网易云"].exists)
    }
    func testAuditionOffersImmediateExitAndRestoresOriginalTrack() {
        let app = launch(["--ai-result", "--audio-test"])
        let audition = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "试听 ")).firstMatch
        XCTAssertTrue(audition.waitForExistence(timeout: 5))
        for _ in 0..<10 {
            let frame = audition.frame
            if audition.isHittable && frame.minY > 110 && frame.maxY < app.frame.maxY - 110 { break }
            let delta = min(180, max(-180, app.frame.midY - frame.midY))
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: delta)))
        }
        XCTAssertGreaterThan(audition.frame.minY, 110)
        XCTAssertLessThan(audition.frame.maxY, app.frame.maxY - 110)
        audition.tap()
        let stop = app.buttons["endAudition"]; XCTAssertTrue(stop.waitForExistence(timeout: 5)); XCTAssertTrue(stop.isHittable)
        stop.tap(); app.buttons["完成"].tap()
        app.buttons["miniPlayer"].tap()
        XCTAssertTrue(app.staticTexts["测试音频 1"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["mainPlayPause"].value as? String, "已暂停")
    }
}

extension YuyinUITests {
    func testRecentListeningSearchRemovalAndQueuePreservation() {
        let app = launch(["--collection-test", "--audio-test", "--library"])
        app.buttons["recentListening"].tap()
        let search = app.textFields["historySearch"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "最近听过"; shot.lifetime = .keepAlways; add(shot)
        search.tap(); search.typeText("Guitar")
        XCTAssertTrue(app.buttons["旅行的意义(Guitar Ver.)的更多操作"].exists)
        app.buttons["清空搜索"].tap()
        search.typeText("Guitar")
        app.buttons["旅行的意义(Guitar Ver.)的更多操作"].tap()
        app.buttons["移除这条聆听记录"].tap()
        XCTAssertTrue(app.staticTexts["没有找到这首歌"].waitForExistence(timeout: 5))
        app.buttons["清空搜索"].tap()
        search.typeText("嫉妒")
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "播放 嫉妒")).firstMatch.tap()
        app.buttons["miniPlayer"].tap(); XCTAssertTrue(app.buttons["queueButton"].waitForExistence(timeout: 5)); app.buttons["queueButton"].tap()
        XCTAssertTrue(app.staticTexts["测试音频 2"].waitForExistence(timeout: 5))
    }

    func testArrangementArchiveKeepsRenamesAndSeparatesNewRequest() {
        let app = launch(["--collection-test", "--library"])
        app.buttons["arrangementLibrary"].tap()
        XCTAssertTrue(app.staticTexts["夜晚，慢慢走"].waitForExistence(timeout: 5))
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "我的编排"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["夜晚，慢慢走的编排操作"].tap(); app.buttons["保留这份"].tap()
        app.buttons["夜晚，慢慢走的编排操作"].tap(); XCTAssertTrue(app.buttons["取消保留"].waitForExistence(timeout: 5), app.debugDescription)
        app.buttons["修改名称"].tap()
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "夜晚，慢慢走".count) + "Evening")
        app.alerts.buttons["保存"].tap()
        XCTAssertTrue(app.staticTexts["Evening"].waitForExistence(timeout: 5), app.debugDescription)
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "openArrangement-", "Evening")).firstMatch.tap()
        XCTAssertTrue(app.buttons["keepArrangement"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["keepArrangement"].label, "已保留在本机")
        app.buttons["完成"].tap()
        app.buttons["newArrangement"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "arrangementPrompt").firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["keepArrangement"].exists)
        app.buttons["完成"].tap()
        app.buttons["Evening的编排操作"].tap(); app.buttons["照这个需求再选一组"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "arrangementPrompt").firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "arrangementPrompt").firstMatch.value as? String, "收藏里的歌，陪我散步三十分钟")
    }

    func testHomeControlFollowsActualPlaybackAndPause() {
        let app = launch(["--collection-test", "--audio-test"])
        let button = app.buttons["continuePlayback"]
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        button.tap(); waitForValue("正在播放", on: button)
        XCTAssertEqual(button.label, "暂停")
        button.tap(); waitForValue("已暂停", on: button)
        XCTAssertEqual(button.label, "继续播放")
    }
}

extension YuyinUITests {
    func testCollectionPagesDarkLargeTextAndLocalDeletion() {
        let light = launch(["--collection-test", "--library"])
        light.buttons["recentListening"].tap()
        XCTAssertTrue(light.textFields["historySearch"].waitForExistence(timeout: 5))
        let normal = XCTAttachment(screenshot: light.screenshot()); normal.name = "最近听过-产品"; normal.lifetime = .keepAlways; add(normal)
        light.terminate()
        let app = launch(["--collection-test", "--library", "--dark", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXL"])
        XCTAssertTrue(app.buttons["recentListening"].waitForExistence(timeout: 5)); XCTAssertTrue(app.buttons["recentListening"].isHittable)
        app.buttons["recentListening"].tap()
        XCTAssertTrue(app.textFields["historySearch"].waitForExistence(timeout: 5))
        let history = XCTAttachment(screenshot: app.screenshot()); history.name = "最近听过-深色大字体"; history.lifetime = .keepAlways; add(history)
        app.navigationBars.buttons["返回"].tap()
        app.buttons["arrangementLibrary"].tap()
        XCTAssertTrue(app.buttons["newArrangement"].waitForExistence(timeout: 5)); XCTAssertTrue(app.buttons["newArrangement"].isHittable)
        let archive = XCTAttachment(screenshot: app.screenshot()); archive.name = "我的编排-深色大字体"; archive.lifetime = .keepAlways; add(archive)
        let menu = app.buttons["安静的午后的编排操作"]
        for _ in 0..<4 where !menu.isHittable { app.swipeUp() }
        menu.tap(); app.buttons["删除本机编排"].tap()
        XCTAssertTrue(app.buttons["删除本机编排"].waitForExistence(timeout: 5)); app.buttons["删除本机编排"].tap()
        let removed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.buttons["安静的午后的编排操作"])
        XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: 5), .completed, app.debugDescription)
    }
}

extension YuyinUITests {
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<18 {
            let footer = app.buttons["findReplacements"]
            let navigationBottom = app.navigationBars.allElementsBoundByIndex.filter { $0.isHittable }.last?.frame.maxY ?? 90
            let top = max(app.frame.minY + 90, navigationBottom + 8)
            let bottom = footer.exists && element.identifier != "findReplacements" ? min(app.frame.maxY - 20, footer.frame.minY - 10) : app.frame.maxY - 20
            let frame = element.frame
            if element.isHittable && (element.identifier == "findReplacements" || (frame.midY > top && frame.midY < bottom)) { return }
            let middle = (top + bottom) / 2
            let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: app.frame.midX, dy: middle))
            let end = start.withOffset(CGVector(dx: 0, dy: frame.midY <= top ? 110 : -110))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTFail("未能将操作滚动到导航与底部操作条之间")
    }
    private func chooseFirstReplacement(in app: XCUIApplication) {
        let menu = app.buttons.matching(NSPredicate(format: "label ENDSWITH %@", "的更多操作")).firstMatch
        reveal(menu, in: app); menu.tap()
        app.buttons["只替换这首"].tap()
        reveal(app.buttons["findReplacements"], in: app)
    }
    func testAlongSongOpensWithoutChangingPlaybackAndGeneratesAnchoredResult() {
        let app = launch(["--editing-test", "--player"])
        XCTAssertTrue(app.buttons["播放器更多操作"].waitForExistence(timeout: 10))
        let originalTitle = app.staticTexts["playerTrackTitle"].label
        app.buttons["播放器更多操作"].tap(); app.buttons["沿着这首听"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["arrangementPrompt"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts[originalTitle].exists)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "沿着这首听"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["编排一段音乐"].tap()
        XCTAssertTrue(app.buttons["keepArrangement"].waitForExistence(timeout: 15))
        reveal(app.buttons["选择要替换的歌曲"], in: app)
        app.buttons["选择要替换的歌曲"].tap()
        let anchor = app.buttons["选择替换 " + originalTitle]
        reveal(anchor, in: app); XCTAssertFalse(anchor.isEnabled)
        app.buttons["完成"].tap()
        XCTAssertEqual(app.staticTexts["playerTrackTitle"].label, originalTitle)
    }
    func testRevisionPreviewDiscardAndAdoptionPreservePlayback() {
        let app = launch(["--ai-result", "--saved-ai-result", "--editing-test"])
        XCTAssertTrue(app.buttons["keepArrangement"].waitForExistence(timeout: 10))
        chooseFirstReplacement(in: app); app.buttons["findReplacements"].tap()
        XCTAssertTrue(app.buttons["adoptRevision"].waitForExistence(timeout: 15))
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "局部替换预览"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["放弃"].tap()
        XCTAssertTrue(app.buttons["已保存到网易云"].exists)
        reveal(app.buttons["findReplacements"], in: app); app.buttons["findReplacements"].tap()
        XCTAssertTrue(app.buttons["adoptRevision"].waitForExistence(timeout: 15)); app.buttons["adoptRevision"].tap()
        XCTAssertTrue(app.buttons["selectReplacementTracks"].waitForExistence(timeout: 5))
        reveal(app.buttons["保存为私人歌单"], in: app); XCTAssertTrue(app.buttons["保存为私人歌单"].isEnabled)
        app.buttons["完成"].tap(); XCTAssertTrue(app.buttons["miniPlayer"].waitForExistence(timeout: 5))
    }
    func testFeedbackIsExplicitAndCanBeRemovedWithoutGeneration() {
        let app = launch(["--ai-result", "--saved-ai-result", "--editing-test", "--dark", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXL"])
        XCTAssertTrue(app.buttons["keepArrangement"].waitForExistence(timeout: 10))
        let menu = app.buttons.matching(NSPredicate(format: "label ENDSWITH %@", "的更多操作")).firstMatch
        reveal(menu, in: app); menu.tap(); app.buttons["这首不太合适"].tap(); app.buttons["最近听得太多"].tap()
        let feedback = app.buttons["本次反馈（1）"]; reveal(feedback, in: app); feedback.tap()
        XCTAssertTrue(app.staticTexts["最近听得太多"].exists)
        let remove = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "移除反馈 ")).firstMatch
        reveal(remove, in: app)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "本次反馈-深色大字体"; shot.lifetime = .keepAlways; add(shot)
        remove.tap()
        XCTAssertTrue(feedback.waitForNonExistence(timeout: 5)); XCTAssertFalse(app.buttons["adoptRevision"].exists)
        XCTAssertTrue(app.buttons["已保存到网易云"].exists)
    }
    func testReplacementFailureAndCancellationKeepSavedResult() {
        for flag in ["--editing-failure", "--editing-slow"] {
            let app = launch(["--ai-result", "--saved-ai-result", "--editing-test", flag])
            XCTAssertTrue(app.buttons["keepArrangement"].waitForExistence(timeout: 10))
            chooseFirstReplacement(in: app); app.buttons["findReplacements"].tap()
            if flag == "--editing-slow" { let cancel = app.buttons["findReplacements"]; XCTAssertTrue(cancel.waitForExistence(timeout: 5)); cancel.tap() }
            else { XCTAssertTrue(app.staticTexts["请求频率或账户额度达到限制，请查看厂商控制台。"].waitForExistence(timeout: 15)) }
            XCTAssertFalse(app.buttons["adoptRevision"].exists); XCTAssertTrue(app.buttons["已保存到网易云"].exists)
            app.terminate()
        }
    }
}

extension YuyinUITests {
    func testAlongSongFromHistoryCanRequestLoginWithoutLosingResult() {
        let app = launch(["--editing-test", "--collection-test", "--library"])
        XCTAssertTrue(app.buttons["recentListening"].waitForExistence(timeout: 10)); app.buttons["recentListening"].tap()
        let menu = app.buttons.matching(NSPredicate(format: "label ENDSWITH %@", "的更多操作")).firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 5)); menu.tap(); app.buttons["沿着这首听"].tap()
        XCTAssertTrue(app.buttons["编排一段音乐"].waitForExistence(timeout: 5))
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "沿着这首听-入口"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["编排一段音乐"].tap(); XCTAssertTrue(app.buttons["keepArrangement"].waitForExistence(timeout: 15))
        let save = app.buttons["保存为私人歌单"]; reveal(save, in: app); save.tap()
        XCTAssertTrue(app.textFields["phoneField"].waitForExistence(timeout: 8))
    }
}
