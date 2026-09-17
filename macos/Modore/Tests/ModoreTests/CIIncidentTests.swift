import XCTest
@testable import Modore

final class CIIncidentTests: XCTestCase {
    func testRunLinksRejectNonGitHubAndUnexpectedRoutes() {
        XCTAssertNotNil(CIIncident.githubRunURL("https://github.com/heznpc/Modore/actions/runs/123"))
        for bad in ["https://github.com.evil/owner/repo/actions/runs/1", "file:///tmp/log", "https://github.com/a/../actions/runs/1", "https://github.com/a/b/actions/runs/1?token=secret", "https://user" + "@github.com/a/b/actions/runs/1"] {
            XCTAssertNil(CIIncident.githubRunURL(bad))
        }
    }
    func testCINotificationOpensWorkWithoutStartingStorageScan() {
        let url = URL(string: "modore://work/ci")!
        XCTAssertEqual(ModoreRoute(url: url), .ci)
        XCTAssertFalse(ModoreRoute.ci.shouldStartStorageScan(hasStorageData: false, isBusy: false))
        XCTAssertNil(ModoreRoute(url: URL(string: "modore://work/ci?execute=1")!))
    }
}
