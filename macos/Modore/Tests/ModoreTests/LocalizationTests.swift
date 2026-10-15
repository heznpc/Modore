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

    func testSkillRestoreConflictAndSafetyErrorsLocalize() {
        let conflict = "복구 충돌: 원래 위치에 파일 또는 링크가 있습니다. 덮어쓰지 않았습니다."
        XCTAssertEqual(
            L10n.message(conflict, preferences: ["en"]),
            "Recovery conflict: A file or link exists at the original location. Nothing was overwritten."
        )
        XCTAssertEqual(
            L10n.message(conflict, preferences: ["ja"]),
            "復元の競合: 元の場所にファイルまたはリンクがあります。上書きはしていません。"
        )
        let changed = "백업 중 원본이 바뀌었습니다. 비활성화하지 않았습니다."
        XCTAssertEqual(
            L10n.message(changed, preferences: ["en"]),
            "The original changed during backup. It was not disabled."
        )
        XCTAssertEqual(
            L10n.message(changed, preferences: ["ja"]),
            "バックアップ中に元の項目が変更されました。無効化は行っていません。"
        )
        let linked = "내부 심볼릭 링크가 있는 스킬은 아직 안전한 복구를 지원하지 않습니다. 원본을 변경하지 않았습니다."
        XCTAssertEqual(
            L10n.message(linked, preferences: ["en"]),
            "Safe recovery is not yet supported for skills containing internal symbolic links. The original was not changed."
        )
        XCTAssertEqual(
            L10n.message(linked, preferences: ["ja"]),
            "内部にシンボリックリンクがあるスキルは、まだ安全な復元に対応していません。元の項目は変更していません。"
        )
    }

    func testSkillPathDiagnosticsPreserveCapturedPathsAndPluginNames() {
        let path = "/Volumes/자료/백업 완료 · 비활성화/100% original %@/SKILL.md"
        let message = "읽는 중 파일이 바뀌었습니다: \(path)"
        XCTAssertEqual(L10n.message(message, preferences: ["en"]), "The file changed while being read: \(path)")
        XCTAssertEqual(L10n.message(message, preferences: ["ja"]), "読み取り中にファイルが変更されました: \(path)")
        XCTAssertEqual(L10n.message(message, preferences: ["ko"]), message)

        let plugin = "프로젝트·대화 찾기@시장"
        let warning = "Claude 플러그인 \(plugin): 설치 기록 형식이 올바르지 않습니다."
        XCTAssertEqual(L10n.message(warning, preferences: ["en"]), "Claude plugin \(plugin): The installation record format is invalid.")
        XCTAssertEqual(L10n.message(warning, preferences: ["ja"]), "Claude プラグイン \(plugin): インストール記録の形式が正しくありません。")
    }

    func testSkillBackupContextLocalizesEachGeneratedLineAndPreservesIdentifiers() {
        let identifier = "A92F90C8-9F33-411E-9618-BF4BFC2A8D1F"
        let path = "/Volumes/자료/원본/스킬 %@"
        let message = "백업 \(identifier)\n백업 기록 읽기 실패\n\(path)\n읽는 중 파일이 바뀌었습니다: \(path)"
        XCTAssertEqual(
            L10n.message(message, preferences: ["en"]),
            "Backup \(identifier)\nFailed to read the backup record\n\(path)\nThe file changed while being read: \(path)"
        )
        XCTAssertEqual(
            L10n.message(message, preferences: ["ja"]),
            "バックアップ \(identifier)\nバックアップ記録の読み取りに失敗しました\n\(path)\n読み取り中にファイルが変更されました: \(path)"
        )
    }
}
