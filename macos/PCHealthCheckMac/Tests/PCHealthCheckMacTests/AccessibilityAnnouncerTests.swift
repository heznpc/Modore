import XCTest
@testable import PCHealthCheckMac

@MainActor
final class AccessibilityAnnouncerTests: XCTestCase {
    // Each test installs its own handler (no other test triggers announce), so
    // no shared teardown is needed — and XCTestCase.tearDown is nonisolated,
    // which cannot touch the @MainActor handler under strict concurrency.

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
