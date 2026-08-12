import XCTest
@testable import Modore

final class ScreeServiceTests: XCTestCase {
    // The destination becomes a real filesystem path component under the
    // app's own results directory, so this locks down the one piece of that
    // pipeline that's pure enough to unit test without a signed runtime.
    func testPreserveFilenameCombinesToolAndSourceStem() {
        let name = ScreeService.preserveFilename(
            tool: "Claude",
            source: "/Users/test/.claude/projects/p/abc123.jsonl"
        )
        XCTAssertEqual(name, "Claude-abc123.md")
    }

    func testPreserveFilenameIgnoresSourceDirectoryComponents() {
        let name = ScreeService.preserveFilename(
            tool: "Codex",
            source: "/Users/test/.codex/sessions/2026/08/rollout-1.jsonl"
        )
        XCTAssertEqual(name, "Codex-rollout-1.md")
    }

    // tool is one of scree's own fixed labels today, but this is a filename
    // builder -- it must not trust either input to already be filesystem-safe.
    func testPreserveFilenameSanitizesUnsafeCharacters() {
        let name = ScreeService.preserveFilename(
            tool: "VS Code",
            source: "/Users/test/weird name/session file.jsonl"
        )
        XCTAssertFalse(name.contains(" "))
        XCTAssertFalse(name.contains("/"))
        XCTAssertTrue(name.hasSuffix(".md"))
    }

    // Not reachable through scree.py's own output today (source is always a
    // real Path's string form), but JsonRead.string defaults a malformed or
    // missing "source" key to "" -- the filename builder must not produce a
    // bare "-session.md"-shaped name or an empty path component in that case.
    func testPreserveFilenameFallsBackWhenSourceIsEmpty() {
        let name = ScreeService.preserveFilename(tool: "Claude", source: "")
        XCTAssertEqual(name, "Claude-session.md")
    }
}
