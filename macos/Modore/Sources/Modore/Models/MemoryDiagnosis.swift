import Darwin
import Foundation

struct MemoryProcessNode: Codable, Equatable, Sendable {
    let pid: Int32
    let parentPID: Int32?
    let started: UInt64
    let name: String
    let executable: String?
    let bytes: UInt64
    let usesResidentFallback: Bool
    let cpu: Double?
    var role: String? = nil
}

struct MemoryProcessFamily: Codable, Equatable, Identifiable, Sendable {
    var id: Int32 { root.pid }
    let root: MemoryProcessNode
    let members: [MemoryProcessNode]
    let workspace: String?
    var bytes: UInt64 { members.reduce(0) { $0 &+ $1.bytes } }
    var cpu: Double { members.compactMap(\.cpu).reduce(0, +) }
    var fallbackCount: Int { members.filter(\.usesResidentFallback).count }
    /// Start-time clusters are evidence of multiple live tool launches, not proof
    /// that a session has ended or that any particular process is safe to kill.
    var toolAccumulation: MemoryToolAccumulation? {
        let roles: Set<String> = ["Node REPL", "Computer Use REPL", "Computer Use server", "MCP server", "BetaCue MCP", "XcodeBuildMCP"]
        let tools = members.filter { $0.role.map(roles.contains) ?? false }.sorted { $0.started < $1.started }
        guard tools.count >= 12, Set(tools.compactMap(\.role)).count >= 2 else { return nil }
        let gapTicks = UInt64(5_000_000_000 / NativeCPUReader.nanosecondsPerTick)
        var clusters = 1
        for (previous, next) in zip(tools, tools.dropFirst()) where next.started - previous.started >= gapTicks {
            clusters += 1
        }
        guard clusters >= 2 else { return nil }
        return .init(launchGroups: clusters, processCount: tools.count, bytes: tools.reduce(0) { $0 &+ $1.bytes })
    }
    var components: [MemoryFamilyComponent] {
        Dictionary(grouping: members, by: { $0.role ?? $0.name }).map { name, nodes in
            MemoryFamilyComponent(name: name, count: nodes.count, bytes: nodes.reduce(0) { $0 &+ $1.bytes })
        }.sorted { $0.bytes == $1.bytes ? $0.name < $1.name : $0.bytes > $1.bytes }
    }
    var title: String {
        if root.name == "launchd_sim" { return L10n.text("실행 중인 시뮬레이터") }
        if let executable = root.executable, let range = executable.range(of: ".app/") {
            return URL(fileURLWithPath: String(executable[..<range.lowerBound])).lastPathComponent
        }
        if ["bun", "node", "python", "python3"].contains(root.name), let workspace {
            return root.name + " · " + URL(fileURLWithPath: workspace).lastPathComponent
        }
        return root.name
    }
}

struct MemoryToolAccumulation: Equatable, Sendable {
    let launchGroups: Int
    let processCount: Int
    let bytes: UInt64
}

struct MemoryFamilyComponent: Identifiable, Equatable {
    var id: String { name }
    let name: String
    let count: Int
    let bytes: UInt64
}

/// User-requested, bounded process inventory. No shell, transcript reads or polling.
struct MemoryDiagnosis: Codable, Sendable {
    let snapshot: HealthSnapshot
    let physicalMemory: UInt64
    let uptimeSeconds: TimeInterval
    let families: [MemoryProcessFamily]
    let readableProcesses: Int
    let enumeratedProcesses: Int?

    static func group(_ nodes: [MemoryProcessNode], workspaces: [Int32: String] = [:]) -> [MemoryProcessFamily] {
        let byPID = Dictionary(nodes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        func root(for node: MemoryProcessNode) -> MemoryProcessNode {
            var current = node, visited: Set<Int32> = [node.pid]
            while let parent = current.parentPID, parent > 1, let next = byPID[parent] {
                // Malformed/incomplete ancestry must not merge unrelated processes.
                guard visited.insert(parent).inserted, next.started <= current.started else { return node }
                current = next
            }
            return current
        }
        let grouped = Dictionary(grouping: Array(byPID.values), by: { root(for: $0).pid })
        return grouped.compactMap { pid, members in
            guard let root = byPID[pid] else { return nil }
            return MemoryProcessFamily(root: root, members: members.sorted { $0.bytes > $1.bytes }, workspace: workspaces[pid])
        }.sorted { $0.bytes == $1.bytes ? $0.id < $1.id : $0.bytes > $1.bytes }
    }

    static func capture() -> Self {
        let before = CPUSample.capture()
        Thread.sleep(forTimeInterval: 0.25)
        let after = CPUSample.capture()
        let usage = after.usage(since: before)
        let cpu = Dictionary(usage.map { ($0.pid, $0.percent) }, uniquingKeysWith: { first, _ in first })
        let nodes: [MemoryProcessNode] = after.counters.compactMap { counter in
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout.size(ofValue: info))
            let hasParent = proc_pidinfo(counter.pid, PROC_PIDTBSDINFO, 0, &info, size) == size
            var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            let path = proc_pidpath(counter.pid, &buffer, UInt32(buffer.count)) > 0 ? String(cString: buffer) : nil
            // The process may have exited or its PID may have been reused during collection.
            guard NativeCPUReader.read(counter.pid)?.started == counter.started else { return nil }
            return .init(pid: counter.pid, parentPID: hasParent ? Int32(info.pbi_ppid) : nil,
                started: counter.started, name: counter.name, executable: path,
                bytes: counter.physicalFootprintBytes ?? counter.residentBytes,
                usesResidentFallback: counter.physicalFootprintBytes == nil, cpu: cpu[counter.pid],
                role: MemoryProcessRole.read(pid: counter.pid, name: counter.name))
        }
        let roots = group(nodes)
        let paths = Dictionary(uniqueKeysWithValues: roots.compactMap { family in
            HealthSnapshot.workspace(pid: family.id).map { (family.id, $0) }
        })
        return .init(snapshot: .capture(sample: after, usage: usage, cpuElevated: false),
            physicalMemory: ProcessInfo.processInfo.physicalMemory,
            uptimeSeconds: ProcessInfo.processInfo.systemUptime,
            families: group(nodes, workspaces: paths), readableProcesses: nodes.count,
            enumeratedProcesses: after.enumeratedProcessCount)
    }

    static func dictionary(_ value: Self) throws -> [String: Any] {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        return try JSONSerialization.jsonObject(with: encoder.encode(value)) as! [String: Any]
    }
}

/// Read a bounded argv only for known runtimes, persist a fixed role label only.
/// Never include command arguments, environment values, or credentials in the report.
enum MemoryProcessRole {
    static func classify(_ arguments: [String]) -> String? {
        if arguments.contains(where: { $0.contains("node_repl") || $0.contains("node-repl") }) { return "Node REPL" }
        if arguments.contains(where: { $0.contains("cua-repl") || $0.contains("cua_repl") }) { return "Computer Use REPL" }
        if arguments.contains(where: { $0.contains("xcodebuildmcp") }) { return "XcodeBuildMCP" }
        if arguments.contains(where: { $0.contains("betacue") && $0.hasSuffix(".py") }) { return "BetaCue MCP" }
        if arguments.contains(where: { $0.contains("cua") && $0.hasSuffix("server.mjs") }) { return "Computer Use server" }
        if arguments.contains(where: { $0.hasSuffix("/mcp/server.bundle.mjs") }) { return "MCP server" }
        if arguments.contains(where: { $0.contains("quotapie-compaction") }) { return "QuotaPie compaction relay" }
        return nil
    }

    static func read(pid: Int32, name: String) -> String? {
        guard ["node", "node_repl", "bun", "python", "python3", "python3.11"].contains(name) else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4, size <= 1_048_576 else { return nil }
        var data = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &data, &size, nil, 0) == 0, size <= data.count else { return nil }
        var argc: Int32 = 0
        withUnsafeMutableBytes(of: &argc) { $0.copyBytes(from: data.prefix(4)) }
        guard argc > 0, argc <= 4096 else { return nil }
        var offset = 4
        // Executable path followed by padding, then exactly argc argv strings.
        while offset < size && data[offset] != 0 { offset += 1 }
        while offset < size && data[offset] == 0 { offset += 1 }
        var arguments: [String] = []
        for _ in 0..<argc {
            guard offset < size else { return nil }
            let start = offset
            while offset < size && data[offset] != 0 { offset += 1 }
            guard offset < size else { return nil }
            arguments.append(String(decoding: data[start..<offset], as: UTF8.self))
            offset += 1
        }
        return classify(arguments)
    }
}
