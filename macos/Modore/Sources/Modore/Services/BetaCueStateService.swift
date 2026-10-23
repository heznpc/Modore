import Darwin
import Foundation

/// BetaCue owns credentials, collection, watches and notifications. This surface only reads its export.
struct BetaCueSnapshot: Decodable, Sendable {
    struct Runtime: Decodable, Sendable {
        let instanceID: String
        let pid: Int
        let state: String
        let heartbeatAt: Date
    }
    struct Build: Decodable, Sendable {
        let id: String
        let number: String
        let marketingVersion: String?
        let displayVersion: String
    }
    struct Status: Decodable, Sendable {
        let code: String
        let headline: String
        let description: String
    }
    struct App: Decodable, Sendable, Identifiable {
        let id: String
        let name: String
        let bundleID: String
        let latestBuild: Build?
        let status: Status
        let fetchedAt: Date
        let partial: Bool
    }
    struct Watch: Decodable, Sendable {
        struct Goal: Decodable, Sendable {
            let channel: String
            let groupID: String?
            let groupName: String?
        }
        let id: String
        let appID: String
        let appName: String
        let buildID: String?
        let goal: Goal
        let phase: String
        let headline: String
        let detail: String
        let startedAt: Date
        let observedAt: Date?
        let evidence: [String]
        private let openURL: String?
        var destination: URL? { openURL.flatMap { BetaCueStateService.safeURL($0, watch: true) } }
    }
    struct WorkRecord: Decodable, Sendable, Identifiable {
        let id: String
        let title: String
        let threadID: String?
        private let url: String?
        let projectPath: String?
        let appID: String?
        let watchID: String?
        let connectionID: String?
        let createdAt: Date
        var destination: URL? { url.flatMap { BetaCueStateService.safeURL($0) } }
    }
    let schemaVersion: Int
    let producer: String
    let generatedAt: Date
    let expiresAt: Date
    let connectionID: String?
    let runtime: Runtime
    let apps: [App]
    let watch: Watch?
    let workRecords: [WorkRecord]
    let issues: [String]

    func isCurrent(now: Date = Date()) -> Bool {
        runtime.state == "running" && generatedAt <= now.addingTimeInterval(60) && expiresAt > now
    }
}

enum BetaCueReadState: Sendable {
    case missing, invalid
    case available(BetaCueSnapshot)

    var snapshot: BetaCueSnapshot? {
        if case .available(let snapshot) = self { return snapshot }
        return nil
    }
}

enum BetaCueStateService {
    static let maximumBytes = 1_048_576
    static var boundaryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/BetaCue/Integration/snapshot.json")
    }

    static func read(from url: URL = boundaryURL) -> BetaCueReadState {
        do { return decode(try readPrivateFile(url)) }
        catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) { return .missing }
        catch { return .invalid }
    }

    static func decode(_ data: Data) -> BetaCueReadState {
        guard data.count <= maximumBytes else { return .invalid }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(raw) { return date }
            if let date = try? Date.ISO8601FormatStyle().parse(raw) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid date"))
        }
        guard let snapshot = try? decoder.decode(BetaCueSnapshot.self, from: data),
              snapshot.schemaVersion == 1, snapshot.producer == "BetaCue",
              snapshot.expiresAt > snapshot.generatedAt,
              snapshot.expiresAt.timeIntervalSince(snapshot.generatedAt) <= 3600,
              abs(snapshot.runtime.heartbeatAt.timeIntervalSince(snapshot.generatedAt)) <= 60,
              ["running", "stopped"].contains(snapshot.runtime.state), snapshot.runtime.pid > 0,
              valid(snapshot.runtime.instanceID, maximum: 200), validOptional(snapshot.connectionID, maximum: 200),
              snapshot.apps.count <= 200, Set(snapshot.apps.map(\.id)).count == snapshot.apps.count,
              snapshot.apps.allSatisfy(validApp),
              snapshot.workRecords.count <= 100,
              Set(snapshot.workRecords.map(\.id)).count == snapshot.workRecords.count,
              snapshot.workRecords.allSatisfy({ valid($0.id, maximum: 200) && valid($0.title)
                  && validOptional($0.threadID, maximum: 200) && validOptional($0.projectPath, maximum: 4096)
                  && validOptional($0.appID, maximum: 200) && validOptional($0.watchID, maximum: 200)
                  && validOptional($0.connectionID, maximum: 200) }),
              snapshot.issues.count <= 50, snapshot.issues.allSatisfy({ valid($0, maximum: 200) }),
              snapshot.watch.map(validWatch) ?? true else { return .invalid }
        return .available(snapshot)
    }

    private static func valid(_ value: String, maximum: Int = 500) -> Bool {
        !value.isEmpty && value.count <= maximum
            && !value.unicodeScalars.contains { $0.value < 32 && $0.value != 9 && $0.value != 10 }
    }
    private static func validOptional(_ value: String?, maximum: Int) -> Bool {
        value.map { valid($0, maximum: maximum) } ?? true
    }
    private static func validApp(_ app: BetaCueSnapshot.App) -> Bool {
        valid(app.id, maximum: 200) && valid(app.name) && valid(app.bundleID)
            && valid(app.status.code, maximum: 200) && valid(app.status.headline)
            && valid(app.status.description, maximum: 4000)
            && (app.latestBuild.map { valid($0.id, maximum: 200) && valid($0.number, maximum: 200)
                && validOptional($0.marketingVersion, maximum: 200) && valid($0.displayVersion) } ?? true)
    }
    private static func validWatch(_ watch: BetaCueSnapshot.Watch) -> Bool {
        valid(watch.id, maximum: 200) && valid(watch.appID, maximum: 200) && valid(watch.appName)
            && validOptional(watch.buildID, maximum: 200) && valid(watch.headline)
            && (watch.detail.isEmpty || valid(watch.detail, maximum: 4000))
            && ["any", "internal", "external"].contains(watch.goal.channel)
            && validOptional(watch.goal.groupID, maximum: 200) && validOptional(watch.goal.groupName, maximum: 500)
            && ["waitingForUpload", "processing", "waitingForApple", "needsAction", "ready", "unavailable"].contains(watch.phase)
            && watch.evidence.count <= 30 && watch.evidence.allSatisfy { valid($0, maximum: 2000) }
    }

    static func safeURL(_ raw: String, watch: Bool = false) -> URL? {
        guard raw.count <= 2048,
              let parts = URLComponents(string: raw), parts.user == nil, parts.password == nil,
              parts.port == nil, parts.fragment == nil, let url = parts.url else { return nil }
        if watch {
            guard parts.scheme == "betacue", parts.path.isEmpty else { return nil }
            if parts.host == "watch", parts.query == nil { return url }
            if parts.host == "app", let items = parts.queryItems, items.count == 1,
               items[0].name == "id", let id = items[0].value,
               id.range(of: #"^[A-Za-z0-9_-]{1,200}$"#, options: .regularExpression) != nil { return url }
            return nil
        }
        guard parts.query == nil, parts.percentEncodedPath == parts.path else { return nil }
        let uuidPattern = #"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}"#
        if parts.scheme == "codex", parts.host == "threads",
           parts.path.range(of: "^/" + uuidPattern + "$", options: .regularExpression) != nil { return url }
        let prefixes = ["chatgpt.com": "/c/", "claude.ai": "/chat/"]
        if parts.scheme == "https", let host = parts.host, let prefix = prefixes[host],
           parts.path.range(of: "^" + prefix + uuidPattern + "$", options: .regularExpression) != nil { return url }
        return nil
    }

    private static func readPrivateFile(_ url: URL) throws -> Data {
        guard url.isFileURL else { throw posixError(EINVAL) }
        let parent = url.deletingLastPathComponent().path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard parent >= 0 else { throw posixError(errno) }
        defer { Darwin.close(parent) }
        var parentInfo = stat()
        guard Darwin.fstat(parent, &parentInfo) == 0, parentInfo.st_uid == Darwin.geteuid(),
              parentInfo.st_mode & 0o077 == 0 else { throw posixError(EACCES) }
        let fd = url.lastPathComponent.withCString {
            Darwin.openat(parent, $0, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        }
        guard fd >= 0 else { throw posixError(errno) }
        defer { Darwin.close(fd) }
        var info = stat()
        guard Darwin.fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == Darwin.geteuid(), info.st_mode & 0o077 == 0,
              info.st_size >= 0, info.st_size <= maximumBytes else { throw posixError(EACCES) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while data.count <= maximumBytes {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, min($0.count, maximumBytes + 1 - data.count)) }
            if count == 0 { return data }
            if count < 0 {
                if errno == EINTR { continue }
                throw posixError(errno)
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        throw posixError(EFBIG)
    }
    private static func posixError(_ code: Int32) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }
}
