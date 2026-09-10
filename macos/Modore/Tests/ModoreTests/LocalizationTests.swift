import XCTest
@testable import Modore

final class LocalizationTests: XCTestCase {
    func testShippedLanguagesHaveMatchingKeysAndTranslateDashboard() throws {
        var expected:Set<String>?
        for locale in ["ko","en","ja"] {
            let path=try XCTUnwrap(L10n.bundle.path(forResource:locale,ofType:"lproj"))
            let bundle=try XCTUnwrap(Bundle(path:path))
            let data=try Data(contentsOf:URL(fileURLWithPath:path).appendingPathComponent("Localizable.strings"))
            let table=try XCTUnwrap(PropertyListSerialization.propertyList(from:data,format:nil) as? [String:String])
            if let expected { XCTAssertEqual(Set(table.keys),expected) } else { expected=Set(table.keys) }
            XCTAssertFalse(table.values.contains(""))
            XCTAssertEqual(bundle.localizedString(forKey:"메모리",value:nil,table:nil),locale == "en" ? "Memory" : (locale == "ja" ? "メモリ" : "메모리"))
            XCTAssertEqual(table["%@을 다시 시작할까요?"]?.components(separatedBy:"%@").count,2)
        }
    }
}
