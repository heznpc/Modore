import XCTest
@testable import Modore

final class BackgroundNotifierTests: XCTestCase {
    func testPendingMessageExtractsTheArgumentImmediatelyFollowingTheFlag() {
        let arguments = ["/path/to/Modore", "--post-storage-notice", "남은 저장공간이 20GB 아래입니다."]

        XCTAssertEqual(
            BackgroundNotifier.pendingMessage(in: arguments),
            "남은 저장공간이 20GB 아래입니다."
        )
    }

    func testPendingMessageIsNilForANormalLaunchWithNoFlag() {
        XCTAssertNil(BackgroundNotifier.pendingMessage(in: ["/path/to/Modore"]))
        XCTAssertNil(BackgroundNotifier.pendingMessage(in: []))
    }

    func testPendingMessageIsNilWhenTheFlagIsTheLastArgument() {
        // A malformed or truncated launch must not be treated as a background
        // notify request with an empty/garbage message.
        XCTAssertNil(
            BackgroundNotifier.pendingMessage(in: ["/path/to/Modore", "--post-storage-notice"])
        )
    }

    func testPendingMessageIgnoresUnrelatedArguments() {
        XCTAssertNil(
            BackgroundNotifier.pendingMessage(in: ["/path/to/Modore", "--some-other-flag", "value"])
        )
    }

    func testPendingMessageTakesTheFirstOccurrenceOnly() {
        let arguments = ["/path/to/Modore", "--post-storage-notice", "first", "--post-storage-notice", "second"]
        XCTAssertEqual(BackgroundNotifier.pendingMessage(in: arguments), "first")
    }
}
