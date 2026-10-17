import Foundation
import XCTest
@testable import ModoreDomain

final class StorageBytesTests: XCTestCase {
    func testCapacityLabelsStateTheBinaryDivisorAcrossSurfaces() {
        let locale = Locale(identifier: "en_US")
        XCTAssertEqual(StorageBytes.text(0, locale: locale), "0 B")
        XCTAssertEqual(StorageBytes.text(1_024, locale: locale), "1.0 KiB")
        XCTAssertEqual(StorageBytes.text(1_048_576, locale: locale), "1.0 MiB")
        XCTAssertEqual(StorageBytes.text(20 * 1_073_741_824, locale: locale), "20.0 GiB")
        XCTAssertEqual(StorageBytes.text(-1, locale: locale), "-1 B")
        XCTAssertEqual(StorageBytes.text(-1_073_741_824, locale: locale), "-1.0 GiB")
        XCTAssertEqual(StorageBytes.text(.min, locale: locale), "-8.0 EiB")
    }
}
