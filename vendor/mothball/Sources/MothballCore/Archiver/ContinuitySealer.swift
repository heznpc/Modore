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
            // Stable stem, the provider's own extension. A fixed
            // `transcript.jsonl` lets a reader find the top-level record
            // without knowing which tool wrote it, but claiming `.jsonl`
            // for Gemini's `.json` or an editor's `workspace.json`
            // describes a format the bytes do not have.
            try Self.copy(binding.source, to: dir.appending(path: Self.transcriptName(for: binding)))
            if !binding.subtranscripts.isEmpty {
                // Destination root is the session directory, not
                // `.../subagents`: the relative path computed below
                // already carries the `subagents/` segment, and rooting
                // at `subagents` would nest it twice.
                // The provider's subagent tree is nested, not flat:
                // `subagents/workflows/<wf-id>/agent-*.jsonl`, with a
                // `journal.jsonl` per workflow. Copying by
                // `lastPathComponent` collapses those onto each other and
                // the second copy fails outright -- found by sealing a
                // real 163-session store, which a flat fixture cannot
                // reproduce. The layout is reproduced instead.
                let origin = Self.subtranscriptOrigin(for: binding)
                for sub in binding.subtranscripts {
                    let destination = dir.appending(
                        path: Self.relativePath(of: sub, under: origin)
                    )
                    let parent = destination.deletingLastPathComponent()
                    do {
                        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
                    } catch {
                        throw SealError.stagingUnusable(parent, underlying: error)
                    }
                    try Self.copy(sub, to: destination)
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

    /// Directory the subagent tree hangs off, which for every provider
    /// seen so far is the transcript's path minus its extension:
    /// `<store>/<session-id>.jsonl` alongside `<store>/<session-id>/...`.
    /// Derived rather than passed in because the binder reports absolute
    /// paths and this keeps the two from having to agree on a second
    /// field.
    static func subtranscriptOrigin(for binding: SessionBinding) -> URL {
        binding.source.deletingPathExtension()
    }

    /// Path of `url` relative to `origin`.
    ///
    /// A subtranscript outside `origin` -- which should not happen, but
    /// would silently collide if it did -- keeps its filename prefixed by
    /// a digest of its full path. Uniqueness matters more here than
    /// readability: a collision is a lost transcript, and losing one
    /// quietly is the failure this type exists to prevent.
    static func relativePath(of url: URL, under origin: URL) -> String {
        let base = origin.standardizedFileURL.path
        let full = url.standardizedFileURL.path
        if full.hasPrefix(base + "/") {
            return String(full.dropFirst(base.count + 1))
        }
        var hasher = SHA256()
        hasher.update(data: Data(full.utf8))
        let tag = hasher.finalize().prefix(4).map { String(format: "%02x", $0) }.joined()
        return "\(tag)-\(url.lastPathComponent)"
    }

    /// `transcript` plus whatever extension the source carried.
    static func transcriptName(for binding: SessionBinding) -> String {
        let ext = binding.source.pathExtension
        return ext.isEmpty ? "transcript" : "transcript.\(ext)"
    }

    private static func copy(_ source: URL, to destination: URL) throws {
        do {
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            throw SealError.sourceUnreadable(source, underlying: error)
        }
    }

    // MARK: - Hashing

    public struct TreeDigest {
        public let digest: String
        public let sizeBytes: Int64
        public let fileCount: Int
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
    public static func treeDigest(of root: URL) throws -> TreeDigest {
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
            // `try?` here would turn a mid-file read failure into a
            // digest of the bytes that happened to arrive first -- a hash
            // that verifies successfully against nothing, recorded in a
            // manifest whose entire job is to prove the archive holds what
            // it says. A truncated read has to fail the seal.
            while true {
                let chunk: Data?
                do {
                    chunk = try handle.read(upToCount: 1 << 20)
                } catch {
                    throw SealError.hashFailed(file.url, underlying: error)
                }
                guard let chunk, !chunk.isEmpty else { break }
                hasher.update(data: chunk)
                total += Int64(chunk.count)
            }
        }
        let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return TreeDigest(digest: hex, sizeBytes: total, fileCount: files.count)
    }
}
