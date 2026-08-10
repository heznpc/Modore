import XCTest
@testable import MothballCore

final class RepoScannerTests: XCTestCase {
    private var scratch: URL!

    override func setUp() async throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "MothballScanner-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let scratch {
            try? FileManager.default.removeItem(at: scratch)
        }
    }

    func test_scanReportSurfacesInspectionFailures() async throws {
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: "/usr/bin/git"),
            "git required at /usr/bin"
        )
        let brokenRepo = scratch.appending(path: "broken", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: brokenRepo, withIntermediateDirectories: true)
        try Data("not a real gitdir\n".utf8).write(to: brokenRepo.appending(path: ".git"))

        let report = await RepoScanner().scanReport(roots: [scratch])

        XCTAssertTrue(report.repos.isEmpty)
        let failure = try XCTUnwrap(report.failures.first)
        XCTAssertEqual(failure.path.standardizedFileURL, brokenRepo.standardizedFileURL)
        XCTAssertFalse(failure.reason.isEmpty)
    }
}
