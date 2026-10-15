import XCTest
@testable import Modore

final class MacRecheckGuideTests: XCTestCase {
    func testOnlyAnExactNoIssueResultShowsTheADP000Explanation() {
        for code in ["ADP000", " adp000\n", "\tAdP000 "] {
            XCTAssertTrue(MacRecheckGuide.ManualResult(code: code).reportsNoIssue, code)
        }
        for code in ["", " ", "PPT001", "ADP000, PPT001", "ADP000\nPPT001", "ADP0000", "ADP000?"] {
            XCTAssertFalse(MacRecheckGuide.ManualResult(code: code).reportsNoIssue, code)
        }
    }

    func testEditsPreserveManualTextAndUpdateTheRecordTime() {
        let firstEdit = Date(timeIntervalSince1970: 1_700_000_000)
        let secondEdit = firstEdit.addingTimeInterval(60)
        var result = MacRecheckGuide.ManualResult()
        result.update(code: " adp000 ", notes: "검사 뒤에도\n가끔 느려짐", at: firstEdit)
        XCTAssertEqual(result.code, " adp000 ")
        XCTAssertEqual(result.notes, "검사 뒤에도\n가끔 느려짐")
        XCTAssertEqual(result.lastModified, firstEdit)

        result.update(code: result.code, notes: "키보드도 다시 확인", at: secondEdit)
        XCTAssertEqual(result.code, " adp000 ")
        XCTAssertEqual(result.lastModified, secondEdit)

        // Recreating a screen from its saved fields is not a new edit.
        var restored = MacRecheckGuide.ManualResult(
            code: result.code, notes: result.notes, updatedAt: result.updatedAt
        )
        restored.update(code: result.code, notes: result.notes, at: secondEdit.addingTimeInterval(60))
        XCTAssertEqual(restored, result)
    }

    func testNotesOnlyRecordSurvivesAndClearingContentRemovesItsTimestamp() {
        let editTime = Date(timeIntervalSince1970: 1_700_000_000)
        var result = MacRecheckGuide.ManualResult()
        result.update(code: "", notes: "진단 결과를 기록하지 못함", at: editTime)
        XCTAssertTrue(result.hasContent)
        XCTAssertFalse(result.reportsNoIssue)
        XCTAssertEqual(result.lastModified, editTime)

        result.update(code: " \n", notes: "\t", at: editTime.addingTimeInterval(60))
        XCTAssertFalse(result.hasContent)
        XCTAssertEqual(result.updatedAt, 0)
        XCTAssertNil(result.lastModified)
    }

    func testMissingOrInvalidSavedTimeDoesNotProduceAMisleadingDate() {
        for time in [0.0, -1, .infinity, -.infinity, .nan] {
            let result = MacRecheckGuide.ManualResult(code: "ADP000", updatedAt: time)
            XCTAssertTrue(result.hasContent)
            XCTAssertNil(result.lastModified)
        }
        XCTAssertNil(MacRecheckGuide.ManualResult(updatedAt: 1_700_000_000).lastModified)
    }

    func testCopiedGuideIncludesTheSelectedProcessorsStepsAndReturnLinks() {
        for processor in MacRecheckGuide.Processor.allCases {
            let copied = MacRecheckGuide.copiedInstructions(for: processor)
            XCTAssertTrue(copied.contains(processor.rawValue))
            XCTAssertTrue(copied.contains(MacRecheckGuide.preparation))
            for (index, instruction) in processor.instructions.enumerated() {
                XCTAssertTrue(copied.contains("\(index + 1). \(instruction)"))
            }
            XCTAssertTrue(copied.contains(MacRecheckGuide.diagnosticsHelp.absoluteString))
            XCTAssertTrue(copied.contains(MacRecheckGuide.resultHelp.absoluteString))
            XCTAssertTrue(copied.contains(L10n.text("재시동 후 Modore > Mac 재점검에서 결과를 기록하세요.")))
        }
        XCTAssertNotEqual(
            MacRecheckGuide.copiedInstructions(for: .appleSilicon),
            MacRecheckGuide.copiedInstructions(for: .intel)
        )
    }
}
