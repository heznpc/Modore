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

extension LocalizationTests {
    func testLanguageNegotiationAndEnglishFallback() {
        for tag in ["fr-FR", "ar", "he-IL", "zh-Hant-TW", "", "../../ko", "zz-ZZ"] {
            XCTAssertEqual(L10n.language(for: [tag]), "en")
            XCTAssertEqual(L10n.text("메모리", preferences: [tag]), "Memory")
        }
        XCTAssertEqual(L10n.language(for: ["JA_jp"]), "ja")
        XCTAssertEqual(L10n.language(for: ["ko-KR"]), "ko")
        XCTAssertEqual(L10n.language(for: ["fr-FR", "ja-JP"]), "ja")
        XCTAssertEqual(L10n.text("/Volumes/자료/Project.swift", preferences: ["en"]), "/Volumes/자료/Project.swift")
    }

    func testEveryCatalogEntryResolvesInAllLocales() throws {
        let path = try XCTUnwrap(L10n.bundle.path(forResource: "en", ofType: "lproj"))
        let data = try Data(contentsOf: URL(fileURLWithPath: path).appendingPathComponent("Localizable.strings"))
        let table = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
        for (key, english) in table {
            XCTAssertEqual(L10n.text(key, preferences: ["ar-SA"]), english, key)
            for lang in ["ko", "ja", "en"] {
                XCTAssertFalse(L10n.text(key, preferences: [lang]).isEmpty, key)
            }
        }
    }
}

extension LocalizationTests {
    func testLegacyDiagnosticsLocalizeWithoutRewritingEmbeddedTargets() {
        XCTAssertEqual(L10n.message("잔류 후보 시스템 Chrome 자동화", preferences: ["en"]), "Possible leftover: System Chrome automation")
        XCTAssertEqual(L10n.message("경로: /Volumes/자료/원본", preferences: ["en"]), "Path: /Volumes/자료/원본")
        XCTAssertEqual(L10n.message("앱·사용자 자료", preferences: ["en"]), L10n.text("앱·사용자 자료", preferences: ["en"]))
        XCTAssertEqual(L10n.message("/Volumes/자료/원본", preferences: ["ja"]), "/Volumes/자료/원본")
        XCTAssertEqual(L10n.message("외부 도구가 반환한 미등록 내용", preferences: ["en"]), "외부 도구가 반환한 미등록 내용")
    }
}
