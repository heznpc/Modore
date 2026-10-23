import XCTest
@testable import Modore

final class MemoryDiagnosisTests: XCTestCase {
    private func node(_ pid: Int32, _ parent: Int32?, _ bytes: UInt64, started: UInt64 = 1, role: String? = nil) -> MemoryProcessNode {
        .init(pid: pid, parentPID: parent, started: started, name: "process-\(pid)", executable: nil,
              bytes: bytes, usesResidentFallback: false, cpu: 1, role: role)
    }
    func testRepeatedToolLaunchesAreVisibleWithoutTreatingOneLargeLaunchAsLeak() {
        let gap = UInt64(10_000_000_000 / NativeCPUReader.nanosecondsPerTick)
        let tools = (0..<12).map { index in
            node(Int32(11 + index), 10, 100, started: index < 6 ? 1 : gap + 1,
                 role: index.isMultiple(of: 2) ? "Node REPL" : "MCP server")
        }
        let family = MemoryDiagnosis.group([node(10, 1, 50)] + tools)[0]
        XCTAssertEqual(family.toolAccumulation, .init(launchGroups: 2, processCount: 12, bytes: 1200))
        let oneLaunch = tools.map { node($0.pid, 10, 100, role: $0.role) }
        XCTAssertNil(MemoryDiagnosis.group([node(10, 1, 50)] + oneLaunch)[0].toolAccumulation)
        let ordinary = tools.map { node($0.pid, 10, 100, started: $0.started) }
        XCTAssertNil(MemoryDiagnosis.group([node(10, 1, 50)] + ordinary)[0].toolAccumulation)
    }
    func testAppIncludesLargeChildrenAndGrandchildrenExactlyOnce() {
        let families = MemoryDiagnosis.group([node(10, 1, 100), node(11, 10, 2000), node(12, 11, 3000), node(20, 1, 400)])
        XCTAssertEqual(families.map(\.id), [10, 20])
        XCTAssertEqual(families[0].bytes, 5100)
        XCTAssertEqual(families[0].members.count, 3)
        XCTAssertEqual(families[0].cpu, 3)
        XCTAssertEqual(families[0].components.reduce(0) { $0 + $1.bytes }, 5100)
        XCTAssertEqual(families[0].components.reduce(0) { $0 + $1.count }, 3)
        XCTAssertEqual(families.flatMap(\.members).count, 4)
    }
    func testMissingParentDoesNotAttachToLaunchdOrAnotherApp() {
        let families = MemoryDiagnosis.group([node(11, 10, 2000), node(20, 1, 400), node(30, nil, 600)])
        XCTAssertEqual(Set(families.map(\.id)), [11, 20, 30])
    }
    func testNewerParentPIDIsNotTheOriginalParent() {
        let families = MemoryDiagnosis.group([node(10, 1, 100, started: 50), node(11, 10, 2000, started: 10)])
        XCTAssertEqual(families.count, 2)
    }
    func testMalformedAncestryTerminatesWithoutLosingOrDuplicatingMembers() {
        let families = MemoryDiagnosis.group([node(10, 11, 100), node(11, 10, 200)])
        XCTAssertEqual(families.count, 2)
        XCTAssertEqual(families.reduce(0) { $0 + $1.bytes }, 300)
    }
    func testHelpersUseOuterAppNameAndWorkspaceIsShownForBackgroundRuntime() {
        var nodes = [MemoryProcessNode(pid: 10, parentPID: 1, started: 1, name: "Renderer", executable: "/Applications/Example.app/Contents/Helpers/Renderer.app/Contents/MacOS/Renderer", bytes: 1, usesResidentFallback: false, cpu: nil)]
        XCTAssertEqual(MemoryDiagnosis.group(nodes).first?.title, "Example")
        nodes = [.init(pid: 10, parentPID: 1, started: 1, name: "bun", executable: "/bin/bun", bytes: 1, usesResidentFallback: true, cpu: nil)]
        XCTAssertEqual(MemoryDiagnosis.group(nodes, workspaces: [10: "/workspace/service"]).first?.title, "bun · service")
        XCTAssertEqual(MemoryDiagnosis.group(nodes).first?.fallbackCount, 1)
    }
    func testToolRolesUseOnlyFixedLabelsAndKeepArgumentsPrivate() {
        XCTAssertEqual(MemoryProcessRole.classify(["node", "/app/cua/server.mjs", "--token", "secret"]), "Computer Use server")
        XCTAssertEqual(MemoryProcessRole.classify(["node", "/plugin/cua-repl/server.mjs"]), "Computer Use REPL")
        XCTAssertEqual(MemoryProcessRole.classify(["node", "/mcp/server.bundle.mjs"]), "MCP server")
        XCTAssertEqual(MemoryProcessRole.classify(["node", "/tools/node_repl/index.js"]), "Node REPL")
        XCTAssertNil(MemoryProcessRole.classify(["node", "/private/customer-project/index.js", "secret"]))
    }
    func testMemoryCLIIsReadOnlyAndRejectsMutationFlags() throws {
        XCTAssertEqual(try NativeCLI.parse(["Modore", "--native-cli", "resources", "memory"]).0, "memory-diagnosis")
        XCTAssertThrowsError(try NativeCLI.parse(["Modore", "--native-cli", "resources", "memory", "--override"]))
    }
}
