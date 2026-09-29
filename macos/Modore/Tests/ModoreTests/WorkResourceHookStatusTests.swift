import Foundation
import XCTest
@testable import Modore

final class WorkResourceHookStatusTests: XCTestCase {
    func testLifecycleAndGuardEvidenceDecodeIndependently() throws {
        let input = #"{"provider":"codex","configured":true,"disabled":false,"recentlyObserved":true,"guard":{"configured":true,"recentlyObserved":false,"outcome":"deny","lastObservedAt":100}}"#
        let value = try JSONDecoder().decode(WorkResourceHookStatus.self, from: Data(input.utf8))
        XCTAssertTrue(value.recentlyObserved)
        XCTAssertEqual(value.guardStatus?.recentlyObserved, false)
        XCTAssertEqual(value.guardStatus?.outcome, "deny")
        let old = #"{"provider":"codex","configured":true,"disabled":false,"recentlyObserved":false}"#
        XCTAssertNil(try JSONDecoder().decode(WorkResourceHookStatus.self, from: Data(old.utf8)).guardStatus)
    }
}
