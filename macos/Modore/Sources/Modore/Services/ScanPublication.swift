import Darwin
import Foundation

struct StagedScanOutput: Equatable, Sendable {
    let directoryURL: URL
    let directoryIdentity: FilesystemIdentity

    var scanResultURL: URL {
        directoryURL.appendingPathComponent("scan_result.json")
    }

    var rawFactsURL: URL {
        directoryURL.appendingPathComponent("raw_facts.json")
    }
}

/// Keeps an unverified scanner run outside the canonical result namespace.
/// Both JSON files become visible together by swapping one directory entry;
/// a rejected or interrupted run therefore cannot replace either trusted file.
enum ScanPublication {
    static let currentDirectoryName = ".modore-scan-current"
    private static let stagingPrefix = ".modore-scan-run-"
    private static let cleanupMutationMarkerName = ".cleanup-mutation-pending"

    static func prepare(
        in outputRoot: URL,
        expectedParentIdentity: FilesystemIdentity
    ) throws -> StagedScanOutput {
        let parentDescriptor = try openDirectory(
            outputRoot,
            expectedIdentity: expectedParentIdentity
        )
        defer { Darwin.close(parentDescriptor) }

        let name = stagingPrefix + UUID().uuidString
        let createStatus = name.withCString {
            Darwin.mkdirat(parentDescriptor, $0, 0o700)
        }
        guard createStatus == 0 else { throw publicationError(errno) }

        let directoryURL = outputRoot.appendingPathComponent(name, isDirectory: true)
        do {
            let descriptor = name.withCString {
                Darwin.openat(
                    parentDescriptor,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
            }
            guard descriptor >= 0 else { throw publicationError(errno) }
            defer { Darwin.close(descriptor) }

            var metadata = stat()
            guard Darwin.fstat(descriptor, &metadata) == 0,
                  metadata.st_mode & S_IFMT == S_IFDIR,
                  metadata.st_uid == Darwin.geteuid(),
                  Darwin.fchmod(descriptor, 0o700) == 0 else {
                throw publicationError(EACCES)
            }
            let identity = FilesystemIdentity(
                device: UInt64(bitPattern: Int64(metadata.st_dev)),
                inode: UInt64(metadata.st_ino)
            )
            return StagedScanOutput(
                directoryURL: directoryURL,
                directoryIdentity: identity
            )
        } catch {
            _ = name.withCString { Darwin.unlinkat(parentDescriptor, $0, AT_REMOVEDIR) }
            throw error
        }
    }

    static func publish(
        _ staged: StagedScanOutput,
        in outputRoot: URL,
        expectedParentIdentity: FilesystemIdentity,
        synchronizeParent: (Int32) -> Bool = { Darwin.fsync($0) == 0 }
    ) -> Bool {
        guard staged.directoryURL.deletingLastPathComponent().standardizedFileURL
                == outputRoot.standardizedFileURL,
              FilesystemIdentity.directory(at: staged.directoryURL)
                == staged.directoryIdentity,
              outputsAreConsistent(staged),
              let parentDescriptor = try? openDirectory(
                outputRoot,
                expectedIdentity: expectedParentIdentity
              ) else {
            return false
        }
        defer { Darwin.close(parentDescriptor) }

        let stagedName = staged.directoryURL.lastPathComponent
        var currentMetadata = stat()
        let currentStatus = currentDirectoryName.withCString {
            Darwin.fstatat(parentDescriptor, $0, &currentMetadata, AT_SYMLINK_NOFOLLOW)
        }

        let status: Int32
        var supersededIdentity: FilesystemIdentity?
        if currentStatus == 0 {
            guard currentMetadata.st_mode & S_IFMT == S_IFDIR,
                  currentMetadata.st_uid == Darwin.geteuid() else {
                return false
            }
            supersededIdentity = FilesystemIdentity(
                device: UInt64(bitPattern: Int64(currentMetadata.st_dev)),
                inode: UInt64(currentMetadata.st_ino)
            )
            status = stagedName.withCString { source in
                currentDirectoryName.withCString { destination in
                    Darwin.renameatx_np(
                        parentDescriptor,
                        source,
                        parentDescriptor,
                        destination,
                        UInt32(RENAME_SWAP)
                    )
                }
            }
        } else {
            guard errno == ENOENT else { return false }
            status = stagedName.withCString { source in
                currentDirectoryName.withCString { destination in
                    Darwin.renameat(
                        parentDescriptor,
                        source,
                        parentDescriptor,
                        destination
                    )
                }
            }
        }
        guard status == 0 else { return false }
        // Do not remove the previous generation until the namespace swap is
        // proven durable. If fsync fails, the new generation is visible now
        // but a crash may roll the swap back; retaining the previous directory
        // preserves its cleanup-mutation marker in that rollback case.
        guard synchronizeParent(parentDescriptor) else { return false }

        if let supersededIdentity {
            removeOwnedDirectory(
                at: staged.directoryURL,
                expectedIdentity: supersededIdentity
            )
        }
        return canonicalDirectory(in: outputRoot)?.identity
            == staged.directoryIdentity
    }

    static func discard(_ staged: StagedScanOutput) {
        removeOwnedDirectory(
            at: staged.directoryURL,
            expectedIdentity: staged.directoryIdentity
        )
    }

    /// A cleanup can mutate storage after the last canonical scan and the app
    /// may terminate before its follow-up scan starts. Keep that fact inside
    /// the canonical generation so a successful directory swap clears it
    /// atomically, while a restart still knows the previous result is stale.
    static func markCleanupMutationPending(in outputRoot: URL) -> Bool {
        guard let current = canonicalDirectory(in: outputRoot) else {
            // With no prior canonical result, startup already treats the scan as
            // missing and schedules one without a marker.
            return true
        }
        do {
            try SecureLocalFileIO.atomicWrite(
                Data("pending\n".utf8),
                to: current.url.appendingPathComponent(cleanupMutationMarkerName),
                permissions: 0o600,
                expectedParentIdentity: current.identity
            )
            return true
        } catch {
            return false
        }
    }

    static func cleanupMutationIsPending(in outputRoot: URL) -> Bool {
        guard let current = canonicalDirectory(in: outputRoot) else { return false }
        let marker = current.url.appendingPathComponent(cleanupMutationMarkerName)
        var metadata = stat()
        let status = marker.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.lstat(path, &metadata)
        }
        if status != 0 { return errno != ENOENT }
        guard metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == Darwin.geteuid() else {
            return true
        }
        guard (try? SecureLocalFileIO.boundedRead(
            from: marker,
            maximumBytes: 64,
            requireCurrentOwner: true,
            expectedParentIdentity: current.identity
        )) != nil else {
            return true
        }
        // The marker's existence is the durable fact. Unknown contents fail
        // closed instead of reviving a potentially stale scan.
        return true
    }

    static func outputsAreConsistent(_ staged: StagedScanOutput) -> Bool {
        func scannedAt(_ url: URL) -> String? {
            guard let data = try? ScanResultLoader.boundedData(
                contentsOf: url,
                maximumBytes: ScanResultLoader.maximumScanResultBytes,
                expectedParentIdentity: staged.directoryIdentity
            ),
                  let root = try? JSONSerialization.jsonObject(with: data)
                    as? [String: Any],
                  root["schemaVersion"] != nil,
                  let value = root["scannedAt"] as? String,
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return value
        }
        guard let scanTimestamp = scannedAt(staged.scanResultURL),
              let rawTimestamp = scannedAt(staged.rawFactsURL) else {
            return false
        }
        return scanTimestamp == rawTimestamp
    }

    static func canonicalDirectory(
        in outputRoot: URL
    ) -> (url: URL, identity: FilesystemIdentity)? {
        let url = outputRoot.appendingPathComponent(
            currentDirectoryName,
            isDirectory: true
        )
        guard let identity = FilesystemIdentity.directory(at: url) else { return nil }
        return (url, identity)
    }

    private static func openDirectory(
        _ url: URL,
        expectedIdentity: FilesystemIdentity
    ) throws -> Int32 {
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw publicationError(errno) }

        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_uid == Darwin.geteuid() else {
            Darwin.close(descriptor)
            throw publicationError(EACCES)
        }
        let identity = FilesystemIdentity(
            device: UInt64(bitPattern: Int64(metadata.st_dev)),
            inode: UInt64(metadata.st_ino)
        )
        guard identity == expectedIdentity else {
            Darwin.close(descriptor)
            throw publicationError(ESTALE)
        }
        return descriptor
    }

    private static func removeOwnedDirectory(
        at url: URL,
        expectedIdentity: FilesystemIdentity
    ) {
        guard FilesystemIdentity.directory(at: url) == expectedIdentity else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private static func publicationError(_ code: Int32) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(code))]
        )
    }
}
