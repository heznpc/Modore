import CryptoKit
import Foundation

/// Copies the session transcripts bound to a workspace into a staging
/// tree and hashes the copies.
///
/// Order matters and is the whole point: copy first, hash the copy,
/// compress the copy. Hashing the provider's live transcript and
/// compressing it afterwards would record a digest for bytes the archive
/// does not contain — the agent can append to its own transcript in
/// between, and for a session that is still open it reliably will.
public struct ContinuitySealer: Sendable {

    /// Single top-level directory inside the session archive. Named once
    /// here because both the sealer and the restorer have to agree.
    public static let rootDirectoryName = "sessions"

    public enum SealError: Error, Sendable {
        case stagingUnusable(URL, underlying: Error)
        case sourceUnreadable(URL, underlying: Error)
        case hashFailed(URL, underlying: Error)
    }

    public init() {}

    /// - Parameter stagingParent: directory the throwaway staging tree is
    ///   created under. The caller owns its lifetime and must remove the
    ///   returned `stagingRoot` once the archive is written.
    public func seal(
        bindings: [SessionBinding],
        stagingParent: URL
    ) throws -> ContinuityBundle {
        let fm = FileManager.default
        let stagingRoot = stagingParent.appending(
            path: ".mothball-continuity-\(UUID().uuidString)", directoryHint: .isDirectory
        )
        let sessionsRoot = stagingRoot.appending(path: Self.rootDirectoryName, directoryHint: .isDirectory)
        do {
            try fm.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
        } catch {
            throw SealError.stagingUnusable(stagingRoot, underlying: error)
        }

        var sealed: [SealedSession] = []
        for binding in bindings {
            // `provider/sessionID` rather than a flat name: two providers
            // can and do mint the same-looking id, and the subagent tree
            // needs a directory of its own anyway.
            let dir = sessionsRoot
                .appending(path: binding.provider.rawValue, directoryHint: .isDirectory)
                .appending(path: binding.sessionID, directoryHint: .isDirectory)
            // Directory creation and copying are reported apart on
            // purpose: a full disk under staging and an unreadable
            // transcript need different answers from the caller, and
            // funnelling both into `sourceUnreadable` would name the
            // wrong file in the one message the user sees.
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            } catch {
                throw SealError.stagingUnusable(dir, underlying: error)
            }
            try Self.copy(binding.source, to: dir.appending(path: "transcript.jsonl"))
            if !binding.subtranscripts.isEmpty {
                let subDir = dir.appending(path: "subagents", directoryHint: .isDirectory)
                do {
                    try fm.createDirectory(at: subDir, withIntermediateDirectories: true)
                } catch {
                    throw SealError.stagingUnusable(subDir, underlying: error)
                }
                for sub in binding.subtranscripts {
                    try Self.copy(sub, to: subDir.appending(path: sub.lastPathComponent))
                }
            }

            let relative = "\(Self.rootDirectoryName)/\(binding.provider.rawValue)/\(binding.sessionID)"
            let tree = try Self.treeDigest(of: dir)
            sealed.append(SealedSession(
                provider: binding.provider,
                sessionID: binding.sessionID,
                artifact: relative,
                sha256: tree.digest,
                sizeBytes: tree.sizeBytes,
                fileCount: tree.fileCount,
                evidence: binding.evidence,
                confidence: binding.confidence
            ))
        }

        return ContinuityBundle(stagingRoot: stagingRoot, sessions: sealed)
    }

    private static func copy(_ source: URL, to destination: URL) throws {
        do {
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            throw SealError.sourceUnreadable(source, underlying: error)
        }
    }

    // MARK: - Hashing

    struct TreeDigest {
        let digest: String
        let sizeBytes: Int64
        let fileCount: Int
    }

    /// Digest over a whole session directory, not just its top-level
    /// transcript. The provider's own cleanup deletes the parent
    /// transcript and leaves the subagent tree behind, so a digest that
    /// covered only the parent would verify the smaller half of what was
    /// actually preserved.
    ///
    /// Each file contributes its path and its bytes, in sorted path
    /// order, so the result is stable across filesystems that enumerate
    /// differently.
    static func treeDigest(of root: URL) throws -> TreeDigest {
        let fm = FileManager.default
        var files: [(relative: String, url: URL)] = []
        let base = root.standardizedFileURL.path
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else {
            throw SealError.hashFailed(root, underlying: CocoaError(.fileReadUnknown))
        }
        for case let url as URL in walker {
            let isFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false
            guard isFile else { continue }
            let path = url.standardizedFileURL.path
            let relative = path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : url.lastPathComponent
            files.append((relative, url))
        }
        files.sort { $0.relative < $1.relative }

        var hasher = SHA256()
        var total: Int64 = 0
        for file in files {
            hasher.update(data: Data(file.relative.utf8))
            hasher.update(data: Data([0]))
            let handle: FileHandle
            do {
                handle = try FileHandle(forReadingFrom: file.url)
            } catch {
                throw SealError.hashFailed(file.url, underlying: error)
            }
            defer { try? handle.close() }
            while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                hasher.update(data: chunk)
                total += Int64(chunk.count)
            }
        }
        let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return TreeDigest(digest: hex, sizeBytes: total, fileCount: files.count)
    }
}
