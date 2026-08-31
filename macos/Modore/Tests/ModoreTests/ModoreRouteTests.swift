import Foundation
import XCTest
@testable import Modore

final class ModoreRouteTests: XCTestCase {
    func testParsesCanonicalStorageRecoveryURL() throws {
        let url = try XCTUnwrap(URL(string: "modore://storage/recovery"))

        XCTAssertEqual(ModoreRoute(url: url), .storageRecovery)
    }

    func testSchemeAndHostAreCaseInsensitive() throws {
        let url = try XCTUnwrap(URL(string: "MODORE://STORAGE/recovery"))

        XCTAssertEqual(ModoreRoute(url: url), .storageRecovery)
    }

    func testRejectsUnsupportedOrNonCanonicalURLs() throws {
        let unsupported = [
            "https://storage/recovery",
            "modore://work/recovery",
            "modore://storage",
            "modore://storage/cleanup",
            "modore://storage/recovery/extra",
            "modore://storage/recovery?execute=true",
            "modore://storage/recovery#approval",
            "modore://user@storage/recovery",
            "modore://storage:443/recovery",
            "modore://storage/%72ecovery",
        ]

        for value in unsupported {
            let url = try XCTUnwrap(URL(string: value), value)
            XCTAssertNil(ModoreRoute(url: url), value)
        }
    }

    func testStorageScanStartsOnlyWithoutDataAndIdle() {
        let route = ModoreRoute.storageRecovery

        XCTAssertTrue(route.shouldStartStorageScan(
            hasStorageData: false,
            isBusy: false
        ))
        XCTAssertFalse(route.shouldStartStorageScan(
            hasStorageData: true,
            isBusy: false
        ))
        XCTAssertFalse(route.shouldStartStorageScan(
            hasStorageData: false,
            isBusy: true
        ))
    }
}
