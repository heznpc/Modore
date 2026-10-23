import Foundation
import XCTest
@testable import Modore

final class NativeUnifiedDiffTests: XCTestCase {
    private func apply(_ before: String, _ after: String) throws -> String {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("skill.txt")
        try Data(before.utf8).write(to: path)
        let diff = NativeUnifiedDiff.render(before, after, from: "skill.txt", to: "skill.txt")
        let result = try NativeCommand.run("/usr/bin/patch", ["-f", "-s", "-p0"], directory: root, input: Data(diff.utf8))
        XCTAssertEqual(result.status, 0, result.errorText + result.text)
        XCTAssertEqual(try Data(contentsOf: path), Data(after.utf8))
        return diff
    }
    func testSmallEditShowsContextWithoutReplacingTheWholeDocument() throws {
        let lines = (1...30).map { "line \($0)\n" }.joined(), changed = lines.replacingOccurrences(of: "line 15\n", with: "new instruction\n")
        let diff = try apply(lines, changed)
        XCTAssertTrue(diff.contains("-line 15\n+new instruction\n"))
        XCTAssertFalse(diff.contains("line 1\n")); XCTAssertTrue(diff.contains(" line 12\n"))
    }
    func testSeparatedChangesProduceIndependentHunks() throws {
        let before = (1...40).map { "\($0)\n" }.joined()
        let after = before.replacingOccurrences(of: "5\n", with: "five\n").replacingOccurrences(of: "32\n", with: "thirty two\n")
        let diff = try apply(before, after)
        XCTAssertGreaterThan(diff.components(separatedBy: "@@ -").count, 2)
    }
    func testInsertRemoveEmptyFilesAndMissingFinalNewlines() throws {
        for (before, after) in [("", "new\n"), ("old\n", ""), ("same", "same\n"), ("one\ntwo\n", "one\nthree"), ("a\nb\n", "a\nadded\nb\n")] {
            _ = try apply(before, after)
        }
        XCTAssertEqual(NativeUnifiedDiff.render("same", "same", from: "a", to: "b"), "")
    }
    func testLargeUnchangedEdgesAndUnicodeBytes() throws {
        let before = String(repeating: "unchanged\n", count: 10_000) + "끝\n", after = String(repeating: "unchanged\n", count: 10_000) + "변경\n"
        XCTAssertLessThan(try apply(before, after).count, 200)
        let diff = try apply("\u{e9}\n", "e\u{301}\n")
        XCTAssertTrue(diff.contains("@@"))
    }
}
