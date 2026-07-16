import Darwin
import Foundation

enum SecureLocalFileIO {
    static func boundedRead(
        from url: URL,
        maximumBytes: Int,
        requireCurrentOwner: Bool = false,
        expectedParentIdentity: FilesystemIdentity? = nil
    ) throws -> Data {
        let parent = url.deletingLastPathComponent()
        let name = url.lastPathComponent
        guard maximumBytes >= 0,
              maximumBytes < Int.max,
              url.isFileURL,
              !name.isEmpty,
              !name.contains("/") else {
            throw posixError(EINVAL)
        }
        let parentDescriptor = parent.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard parentDescriptor >= 0 else { throw posixError(errno) }
        defer { Darwin.close(parentDescriptor) }

        var parentMetadata = stat()
        guard Darwin.fstat(parentDescriptor, &parentMetadata) == 0,
              parentMetadata.st_mode & S_IFMT == S_IFDIR else {
            throw posixError(ENOTDIR)
        }
        if let expectedParentIdentity {
            let actual = FilesystemIdentity(
                device: UInt64(bitPattern: Int64(parentMetadata.st_dev)),
                inode: UInt64(parentMetadata.st_ino)
            )
            guard actual == expectedParentIdentity else { throw posixError(ESTALE) }
        }

        let descriptor = name.withCString {
            Darwin.openat(
                parentDescriptor,
                $0,
                O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else { throw posixError(errno) }
        defer { Darwin.close(descriptor) }

        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              !requireCurrentOwner || metadata.st_uid == Darwin.geteuid() else {
            throw posixError(EINVAL)
        }
        guard metadata.st_size >= 0,
              metadata.st_size <= maximumBytes else {
            throw posixError(EFBIG)
        }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: min(64 * 1_024, maximumBytes + 1))
        while data.count <= maximumBytes {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            if count == 0 { return data }
            if count < 0 {
                if errno == EINTR { continue }
                throw posixError(errno)
            }
            data.append(contentsOf: buffer.prefix(Int(count)))
        }
        throw posixError(EFBIG)
    }

    static func atomicWrite(
        _ data: Data,
        to url: URL,
        permissions: mode_t = 0o600,
        expectedParentIdentity: FilesystemIdentity? = nil
    ) throws {
        let directory = url.deletingLastPathComponent()
        let destinationName = url.lastPathComponent
        guard url.isFileURL,
              !destinationName.isEmpty,
              !destinationName.contains("/") else {
            throw posixError(EINVAL)
        }
        if expectedParentIdentity == nil {
            try ensurePrivateDirectory(directory)
        }
        let directoryDescriptor = directory.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard directoryDescriptor >= 0 else { throw posixError(errno) }
        defer { Darwin.close(directoryDescriptor) }

        var directoryMetadata = stat()
        guard Darwin.fstat(directoryDescriptor, &directoryMetadata) == 0,
              directoryMetadata.st_mode & S_IFMT == S_IFDIR,
              directoryMetadata.st_uid == Darwin.geteuid() else {
            throw posixError(EACCES)
        }
        if let expectedParentIdentity {
            let actual = FilesystemIdentity(
                device: UInt64(bitPattern: Int64(directoryMetadata.st_dev)),
                inode: UInt64(directoryMetadata.st_ino)
            )
            guard actual == expectedParentIdentity else { throw posixError(ESTALE) }
        }
        guard Darwin.fchmod(directoryDescriptor, 0o700) == 0 else {
            throw posixError(errno)
        }

        var existing = stat()
        let existingStatus = destinationName.withCString {
            Darwin.fstatat(directoryDescriptor, $0, &existing, AT_SYMLINK_NOFOLLOW)
        }
        if existingStatus == 0 {
            guard existing.st_mode & S_IFMT == S_IFREG,
                  existing.st_uid == Darwin.geteuid() else {
                throw posixError(EINVAL)
            }
        } else if errno != ENOENT {
            throw posixError(errno)
        }

        let temporaryName = ".pch-write-\(UUID().uuidString)"
        let descriptor = temporaryName.withCString {
            Darwin.openat(
                directoryDescriptor,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                permissions
            )
        }
        guard descriptor >= 0 else { throw posixError(errno) }
        var published = false
        defer {
            if !published {
                var opened = stat()
                var current = stat()
                if Darwin.fstat(descriptor, &opened) == 0 {
                    let status = temporaryName.withCString {
                        Darwin.fstatat(
                            directoryDescriptor,
                            $0,
                            &current,
                            AT_SYMLINK_NOFOLLOW
                        )
                    }
                    if status == 0,
                       opened.st_dev == current.st_dev,
                       opened.st_ino == current.st_ino {
                        _ = temporaryName.withCString {
                            Darwin.unlinkat(directoryDescriptor, $0, 0)
                        }
                    }
                }
            }
            Darwin.close(descriptor)
        }

        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    bytes.baseAddress?.advanced(by: offset),
                    bytes.count - offset
                )
                if count < 0 {
                    if errno == EINTR { continue }
                    throw posixError(errno)
                }
                offset += count
            }
        }
        guard Darwin.fchmod(descriptor, permissions) == 0,
              Darwin.fsync(descriptor) == 0 else {
            throw posixError(errno)
        }
        var stagedMetadata = stat()
        var namedMetadata = stat()
        let namedStatus = temporaryName.withCString {
            Darwin.fstatat(
                directoryDescriptor,
                $0,
                &namedMetadata,
                AT_SYMLINK_NOFOLLOW
            )
        }
        guard Darwin.fstat(descriptor, &stagedMetadata) == 0,
              namedStatus == 0,
              stagedMetadata.st_dev == namedMetadata.st_dev,
              stagedMetadata.st_ino == namedMetadata.st_ino else {
            throw posixError(ESTALE)
        }
        let renameStatus = temporaryName.withCString { source in
            destinationName.withCString { destination in
                Darwin.renameat(directoryDescriptor, source, directoryDescriptor, destination)
            }
        }
        guard renameStatus == 0 else { throw posixError(errno) }
        published = true
        _ = Darwin.fsync(directoryDescriptor)
    }

    static func ensurePrivateDirectory(_ url: URL) throws {
        guard !pathContainsSymbolicLink(url) else { throw posixError(ELOOP) }
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw posixError(errno) }
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_uid == Darwin.geteuid(),
              Darwin.fchmod(descriptor, 0o700) == 0 else {
            throw posixError(EACCES)
        }
    }

    private static func pathContainsSymbolicLink(_ url: URL) -> Bool {
        let standardized = url.standardizedFileURL
        guard standardized.path.hasPrefix("/") else { return true }
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for component in standardized.pathComponents.dropFirst() {
            current.appendPathComponent(component)
            if current.path == "/var" || current.path == "/tmp" { continue }
            var metadata = stat()
            let status = current.withUnsafeFileSystemRepresentation { path in
                guard let path else { return Int32(-1) }
                return Darwin.lstat(path, &metadata)
            }
            if status == 0, metadata.st_mode & S_IFMT == S_IFLNK { return true }
        }
        return false
    }

    private static func posixError(_ code: Int32) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }
}
