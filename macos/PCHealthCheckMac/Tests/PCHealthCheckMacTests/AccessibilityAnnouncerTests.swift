import XCTest
@testable import PCHealthCheckMac

final class AccessibilityAnnouncerTests: XCTestCase {
    override func tearDown() {
        // Leave a no-op handler so no later test accidentally posts to
        // NSAccessibility through the shared static.
        AccessibilityAnnouncer.handler = { _ in }
        super.tearDown()
    }

    func testAnnounceRoutesTrimmedMessageToHandler() {
        var captured: [String] = []
        AccessibilityAnnouncer.handler = { captured.append($0) }

        AccessibilityAnnouncer.announce("  검사 완료: 범위 내 정상  ")

        XCTAssertEqual(captured, ["검사 완료: 범위 내 정상"])
    }

    func testAnnounceIgnoresEmptyAndWhitespace() {
        var count = 0
        AccessibilityAnnouncer.handler = { _ in count += 1 }

        AccessibilityAnnouncer.announce("")
        AccessibilityAnnouncer.announce("   \n  ")

        XCTAssertEqual(count, 0)
    }
}
