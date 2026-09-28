import XCTest
@testable import LagQA

final class ProtocolTests: XCTestCase {
    func testPhaseBoundariesAndAutomaticEnd() {
        let phases = Phase.standard
        XCTAssertEqual(phases.reduce(0) { $0 + $1.seconds }, 80)
        XCTAssertEqual(Phase.position(at: 7.9, phases: phases)?.index, 0)
        XCTAssertEqual(Phase.position(at: 8, phases: phases)?.index, 1)
        XCTAssertEqual(Phase.position(at: 40, phases: phases)?.index, 4)
        XCTAssertNil(Phase.position(at: 80, phases: phases))
    }
    func testCPUUsesElapsedCountersAndRejectsPIDReuse() {
        let old = CPUCounter(birth: 1, totalNanoseconds: 2_000_000_000, timestamp: 10)
        let now = CPUCounter(birth: 1, totalNanoseconds: 5_000_000_000, timestamp: 12)
        XCTAssertEqual(CPUCounter.percent(previous: old, current: now), 150)
        XCTAssertNil(CPUCounter.percent(previous: old, current: .init(birth: 2, totalNanoseconds: 5_000_000_000, timestamp: 12)))
        XCTAssertNil(CPUCounter.percent(previous: old, current: .init(birth: 1, totalNanoseconds: 1, timestamp: 12)))
        XCTAssertNil(CPUCounter.percent(previous: old, current: old))
    }
}
