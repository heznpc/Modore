import XCTest
@testable import Modore

final class ObservationServiceTests: XCTestCase {
    // MARK: parseProcessRows

    func testParsesProcessRowsFromIdleCpuProtocol() {
        let output = """
        version\t1
        operation\tidle-cpu
        windowSeconds\t60
        minPercent\t1
        process\t42.5\t501\tnode\t500\tzsh\ttrue
        process\t10.0\t900\tElectron\t900\tElectron\tfalse
        observed\t2
        reported\t2
        """

        let rows = ObservationService.parseProcessRows(output)

        XCTAssertEqual(rows.map(\.name), ["node", "Electron"])
        XCTAssertEqual(rows[0].percent, 42.5, accuracy: 0.001)
        XCTAssertEqual(rows[0].pid, 501)
        XCTAssertEqual(rows[0].ownerPid, 500)
        XCTAssertEqual(rows[0].ownerName, "zsh")
        XCTAssertTrue(rows[0].startedFromShell)
        // A process that owns itself, not started from a shell.
        XCTAssertFalse(rows[1].startedFromShell)
        XCTAssertFalse(rows[1].isDetachedFromAnApp)
    }

    // Same reasoning as BackgroundCpuRow: work not attributable to the
    // application it appears to belong to, so quitting that app wouldn't
    // stop it.
    func testFlagsWorkDetachedFromAnyOwningApp() {
        let output = "process\t99.0\t501\tnode\t500\tzsh\ttrue"

        let rows = ObservationService.parseProcessRows(output)

        XCTAssertEqual(rows.count, 1)
        XCTAssertTrue(rows[0].isDetachedFromAnApp)
    }

    func testIgnoresNonProcessLinesAndMalformedRows() {
        let output = """
        version\t1
        windowSeconds\t60
        process\tnot-a-number\t501\tnode\t500\tzsh\ttrue
        process\t10.0\t501\tnode\t500
        observed\t0
        """

        XCTAssertTrue(ObservationService.parseProcessRows(output).isEmpty)
    }

    // MARK: parseConnectionRows

    func testParsesNewConnectionAndListenRows() {
        let output = """
        version\t1
        operation\tnetwork-watch
        windowSeconds\t60
        established\tCodex\t2000\t2.2.2.2:8080
        listen\tnewsvc\t3000\t*:9999
        newEstablished\t1
        newListen\t1
        """

        let rows = ObservationService.parseConnectionRows(output)

        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].kind, "established")
        XCTAssertEqual(rows[0].process, "Codex")
        XCTAssertEqual(rows[0].pid, 2000)
        XCTAssertEqual(rows[0].address, "2.2.2.2:8080")
        XCTAssertFalse(rows[0].isListening)
        XCTAssertTrue(rows[1].isListening)
    }

    func testIgnoresMetadataLinesWhenParsingConnections() {
        let output = "version\t1\nwindowSeconds\t60\nnewEstablished\t0\nnewListen\t0"

        XCTAssertTrue(ObservationService.parseConnectionRows(output).isEmpty)
    }
}
