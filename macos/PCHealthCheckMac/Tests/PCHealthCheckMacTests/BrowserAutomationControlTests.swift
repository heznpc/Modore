import XCTest
@testable import PCHealthCheckMac

final class BrowserAutomationControlTests: XCTestCase {
    func testNormalChromeDefaultProfileIsNeverStoppable() {
        let command = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

        let classification = BrowserAutomationControl.classify(
            executablePath: command,
            command: command
        )

        XCTAssertEqual(classification.channel, "system")
        XCTAssertEqual(classification.profile, "default")
        XCTAssertFalse(classification.canStop)
    }

    func testSystemChromeNeedsDisposableAutomationProfile() {
        let executable = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
        let unprotectedDebugChrome = BrowserAutomationControl.classify(
            executablePath: executable,
            command: executable + " --remote-debugging-port=9222"
        )
        let playwrightChrome = BrowserAutomationControl.classify(
            executablePath: executable,
            command: executable + " "
                + "--user-data-dir=/tmp/playwright_chromiumdev_profile-1 --remote-debugging-pipe"
        )
        let persistentCustomChrome = BrowserAutomationControl.classify(
            executablePath: executable,
            command: executable + " "
                + "--user-data-dir=/Users/test/BrowserProfile --remote-debugging-pipe"
        )

        XCTAssertFalse(unprotectedDebugChrome.canStop)
        XCTAssertEqual(unprotectedDebugChrome.profile, "default")
        XCTAssertTrue(playwrightChrome.canStop)
        XCTAssertEqual(playwrightChrome.profile, "temporary")
        XCTAssertEqual(persistentCustomChrome.profile, "custom")
        XCTAssertFalse(persistentCustomChrome.canStop)
    }

    func testIsolatedTestingBrowserIsStoppableButHelperIsNot() {
        let rootExecutable = "/Users/test/Library/Caches/ms-playwright/chromium/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing"
        let root = BrowserAutomationControl.classify(
            executablePath: rootExecutable,
            command: rootExecutable + " --headless"
        )
        let helperExecutable = "/Users/test/Google Chrome for Testing.app/Contents/Frameworks/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper"
        let helper = BrowserAutomationControl.classify(
            executablePath: helperExecutable,
            command: helperExecutable + " --type=renderer --headless"
        )

        XCTAssertEqual(root.channel, "isolated")
        XCTAssertTrue(root.canStop)
        XCTAssertFalse(helper.canStop)
    }

    func testSpoofedChromeCommandWithDifferentExecutableIsNeverStoppable() {
        let command = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome "
            + "--user-data-dir=/tmp/playwright_chromiumdev_profile-spoof --headless"

        let classification = BrowserAutomationControl.classify(
            executablePath: "/bin/sleep",
            command: command
        )

        XCTAssertEqual(classification.channel, "unknown")
        XCTAssertFalse(classification.canStop)
    }

    func testProcessTableAndTreeMemoryKeepOnlyStructuredEvidence() throws {
        let text = """
          100 1 01:02:03 1000 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome --user-data-dir=/tmp/playwright_chromiumdev_profile-a
          101 100 01:02:02 2000 /Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper --type=renderer
          102 101 01:02:01 3000 /Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper --type=gpu
          200 1 00:10 9000 /Applications/Other.app/Contents/MacOS/Other
        """

        let processes = BrowserAutomationControl.parseProcessTable(text)
        let tree = BrowserAutomationControl.processTree(rootPID: 100, processes: processes)

        XCTAssertEqual(processes.count, 4)
        XCTAssertEqual(Set(tree.map(\.pid)), [100, 101, 102])
        XCTAssertEqual(tree.reduce(0) { $0 + $1.memoryKB }, 6_000)
        XCTAssertFalse(tree.contains(where: { $0.pid == 200 }))
    }

    func testMalformedProcessRowsAreDiscarded() {
        let text = """
          nope 1 00:01 200 command
          123 -1 00:01 200 command
          124 1 00:01 -2 command
          125 1 00:01 200 valid command
        """

        XCTAssertEqual(BrowserAutomationControl.parseProcessTable(text).map(\.pid), [125])
    }

    func testControllerClueIsRecomputedFromCurrentAncestors() {
        let processes = [
            process(pid: 100, parentPID: 90, command: "automation browser"),
            process(
                pid: 90,
                parentPID: 80,
                command: "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT"
            ),
            process(pid: 80, parentPID: 1, command: "launchd"),
        ]

        XCTAssertEqual(
            BrowserAutomationControl.controllerLabel(parentPID: 90, processes: processes),
            "ChatGPT"
        )
    }

    private func process(
        pid: Int,
        parentPID: Int,
        command: String
    ) -> BrowserAutomationProcess {
        BrowserAutomationProcess(
            pid: pid,
            parentPid: parentPID,
            elapsed: "00:01",
            memoryKB: 100,
            command: command
        )
    }
}
