import AppKit
import Darwin
import Foundation

/// Keeps one Modore UI process alive across installed and source-built app
/// paths. A bundle path is not an application identity: every local build has
/// the same bundle identifier, and `open -n` can otherwise leave an old copy
/// running for days while newer copies start their own scans and watchers.
enum AppInstanceCoordinator {
    struct Candidate: Equatable {
        let processIdentifier: pid_t
        let bundleIdentifier: String?
        let launchedAt: TimeInterval?
        let isRegularApplication: Bool
    }

    enum LockState: Equatable {
        case acquired
        case busy
        case unavailable
    }

    enum Decision: Equatable {
        case continueRunning
        case activateExistingAndExit(pid_t?)
        case cannotCoordinate
    }

    final class Lease {
        private var descriptor: Int32

        fileprivate init(descriptor: Int32) {
            self.descriptor = descriptor
        }

        deinit {
            guard descriptor >= 0 else { return }
            flock(descriptor, LOCK_UN)
            close(descriptor)
            descriptor = -1
        }
    }

    enum LeaseResult {
        case acquired(Lease)
        case busy
        case unavailable

        var state: LockState {
            switch self {
            case .acquired: return .acquired
            case .busy: return .busy
            case .unavailable: return .unavailable
            }
        }
    }

    enum Outcome {
        case continueRunning(Lease?, obsoletePeers: [NSRunningApplication])
        case activateExistingAndExit(NSRunningApplication?)
        case cannotCoordinate
    }

    /// Pure policy, kept separate from AppKit discovery and the file lock so
    /// the startup rule can be pinned without terminating a test process.
    static func decide(
        bundleIdentifier: String?,
        currentPID: pid_t,
        candidates: [Candidate],
        lockState: LockState
    ) -> Decision {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else {
            // `swift run` and test executables are not app bundles. They do
            // not share the production application identity and must not be
            // turned into a hidden global singleton.
            return .continueRunning
        }

        let peer = candidates
            .filter {
                $0.processIdentifier != currentPID
                    && $0.bundleIdentifier == bundleIdentifier
                    && $0.isRegularApplication
            }
            .sorted {
                let lhs = $0.launchedAt ?? .greatestFiniteMagnitude
                let rhs = $1.launchedAt ?? .greatestFiniteMagnitude
                return lhs == rhs
                    ? $0.processIdentifier < $1.processIdentifier
                    : lhs < rhs
            }
            .first

        switch lockState {
        case .acquired:
            // The lock is the election result. If two launches both appear in
            // Launch Services before either evaluates policy, letting peer age
            // outrank this result makes the winner and loser both exit.
            return .continueRunning
        case .busy:
            // The winner may not yet be visible to Launch Services. Exiting
            // without an activation target still preserves the singleton.
            return .activateExistingAndExit(peer?.processIdentifier)
        case .unavailable:
            // An already-running regular UI is still a safe destination. With
            // no peer, silently continuing would turn an unsafe lock path into
            // permission for duplicate scans.
            if let peer {
                return .activateExistingAndExit(peer.processIdentifier)
            }
            return .cannotCoordinate
        }
    }

    @MainActor
    static func acquire(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        currentPID: pid_t = getpid(),
        supportDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Modore", isDirectory: true)
    ) -> Outcome {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else {
            // The production app always has an identifier. This path exists
            // only for raw Swift executables and is intentionally ungated.
            return .continueRunning(nil, obsoletePeers: [])
        }

        let applications = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier
        )
        let candidates = applications.map {
            Candidate(
                processIdentifier: $0.processIdentifier,
                bundleIdentifier: $0.bundleIdentifier,
                launchedAt: $0.launchDate?.timeIntervalSince1970,
                isRegularApplication: $0.activationPolicy == .regular
            )
        }
        let leaseResult = acquireLease(at: supportDirectory)
        let decision = decide(
            bundleIdentifier: bundleIdentifier,
            currentPID: currentPID,
            candidates: candidates,
            lockState: leaseResult.state
        )

        switch decision {
        case .continueRunning:
            guard case .acquired(let lease) = leaseResult else {
                return .cannotCoordinate
            }
            let obsoletePeers = applications.filter {
                $0.processIdentifier != currentPID && $0.activationPolicy == .regular
            }
            return .continueRunning(lease, obsoletePeers: obsoletePeers)
        case .activateExistingAndExit(let processIdentifier):
            let peer = processIdentifier.flatMap { pid in
                applications.first { $0.processIdentifier == pid }
            }
            return .activateExistingAndExit(peer)
        case .cannotCoordinate:
            return .cannotCoordinate
        }
    }

    /// Owner-only advisory lock. The directory and file are opened without
    /// following their final path components, then verified from descriptors;
    /// no process may redirect the coordinator through a symlink.
    static func acquireLease(at supportDirectory: URL) -> LeaseResult {
        do {
            // Reuse the app's existing whole-path symlink check and its 0700
            // owner directory contract instead of protecting only the final
            // component here.
            try SecureLocalFileIO.ensurePrivateDirectory(supportDirectory)
        } catch {
            return .unavailable
        }

        let directoryFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        let directoryDescriptor: Int32 = supportDirectory.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.open(path, directoryFlags)
        }
        guard directoryDescriptor >= 0 else { return .unavailable }
        defer { close(directoryDescriptor) }

        var directoryInfo = stat()
        guard fstat(directoryDescriptor, &directoryInfo) == 0,
              (directoryInfo.st_mode & S_IFMT) == S_IFDIR,
              directoryInfo.st_uid == geteuid(),
              directoryInfo.st_mode & 0o077 == 0 else {
            return .unavailable
        }

        let fileFlags = O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC
        let descriptor = "app-instance.lock".withCString { name in
            Darwin.openat(directoryDescriptor, name, fileFlags, 0o600)
        }
        guard descriptor >= 0 else { return .unavailable }

        var fileInfo = stat()
        guard fstat(descriptor, &fileInfo) == 0,
              (fileInfo.st_mode & S_IFMT) == S_IFREG,
              fileInfo.st_uid == geteuid(),
              fileInfo.st_nlink == 1,
              fchmod(descriptor, 0o600) == 0 else {
            close(descriptor)
            return .unavailable
        }

        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
            return .acquired(Lease(descriptor: descriptor))
        }
        let lockError = errno
        close(descriptor)
        return lockError == EWOULDBLOCK || lockError == EAGAIN ? .busy : .unavailable
    }
}
