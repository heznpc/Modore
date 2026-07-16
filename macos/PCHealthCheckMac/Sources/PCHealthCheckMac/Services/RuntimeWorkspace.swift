import Darwin
import CryptoKit
import Foundation
import Security

struct FilesystemIdentity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64

    static func directory(at url: URL) -> FilesystemIdentity? {
        var value = stat()
        let status = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.lstat(path, &value)
        }
        guard status == 0, value.st_mode & S_IFMT == S_IFDIR else { return nil }
        return FilesystemIdentity(
            device: UInt64(bitPattern: Int64(value.st_dev)),
            inode: UInt64(value.st_ino)
        )
    }
}

struct RuntimeExecutionContext: Equatable, Sendable {
    /// Immutable scripts and rules used for this invocation. In a standalone
    /// app this is the code-signed bundle resource, never the mutable staged
    /// copy under Application Support.
    let runtimeRoot: URL
    /// Mutable scan results and reports remain outside the signed app bundle.
    let outputRoot: URL
    /// User-owned configuration is intentionally separate from immutable code.
    let configurationURL: URL
    let usesBundledRuntime: Bool
    let runtimeRootIdentity: FilesystemIdentity
    let outputRootIdentity: FilesystemIdentity
    /// Revalidated immediately before spawning any bundled script. Development
    /// executions intentionally leave this nil.
    let signedBundleURL: URL?
    /// Byte-for-byte runtime resources captured between code-signature checks.
    /// Bundled interpreter inputs are later passed through anonymous file
    /// descriptors so pathname replacement cannot change what is executed.
    let sealedRuntimeFiles: [String: Data]?

    var scannerScriptURL: URL {
        runtimeRoot.appendingPathComponent("scripts/scanner.sh")
    }

    var cleanupScriptURL: URL {
        runtimeRoot.appendingPathComponent("scripts/cleanup.sh")
    }

    var reportScriptURL: URL {
        runtimeRoot.appendingPathComponent("scripts/report.jxa.js")
    }

    var scheduleScriptURL: URL {
        runtimeRoot.appendingPathComponent("scripts/schedule.sh")
    }

    var storageWatchScriptURL: URL {
        runtimeRoot.appendingPathComponent("scripts/storage_watch.sh")
    }

    var scanResultURL: URL {
        outputRoot.appendingPathComponent("scan_result.json")
    }

    var rawFactsURL: URL {
        outputRoot.appendingPathComponent("raw_facts.json")
    }

    func pinnedInvocation(
        relativePath: String,
        name: String
    ) -> (argument: String, files: [String: Data])? {
        if let sealedRuntimeFiles {
            guard let contents = sealedRuntimeFiles[relativePath] else { return nil }
            return ("@pch-pinned:\(name)", [name: contents])
        }
        guard !usesBundledRuntime else { return nil }
        return (relativePath, [:])
    }

    func sealedSHA256(relativePath: String) -> String? {
        guard let contents = sealedRuntimeFiles?[relativePath] else { return nil }
        return SHA256.hash(data: contents).map { String(format: "%02x", $0) }.joined()
    }
}

enum RuntimeWorkspace {
    static let applicationSupportName = "PC Health Check"
    private static let developmentModeKey = "PCH_DEVELOPMENT_MODE"

    static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        resourceURL: URL? = Bundle.main.resourceURL,
        currentDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        mainApplicationResourceURL: URL? = Bundle.main.resourceURL,
        mainApplicationBundleURL: URL = Bundle.main.bundleURL,
        applicationSupportRoot: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
    ) -> URL {
        let supportDirectory = applicationSupportRoot.appendingPathComponent(applicationSupportName)
        let installedRuntime = supportDirectory.appendingPathComponent("runtime")
        let resultsDirectory = supportDirectory.appendingPathComponent("results")

        if let resourceURL,
           isMainApplicationResourceURL(
            resourceURL,
            mainResourceURL: mainApplicationResourceURL,
            mainBundleURL: mainApplicationBundleURL
           ),
           !bundledRuntimeSignatureIsValid(bundleURL: mainApplicationBundleURL) {
            // A modified production bundle must never fall through to an
            // environment-selected development path.
            return resultsDirectory
        }

        // A standalone app always uses its signed bundled runtime as the source
        // of truth. Environment variables and the process working directory are
        // intentionally ignored on this path.
        if let resourceURL {
            let bundledRuntime = resourceURL.appendingPathComponent("runtime")
            if pathEntryExists(bundledRuntime) {
                guard hasScanner(at: bundledRuntime) else { return resultsDirectory }
                do {
                    try installBundledRuntime(from: bundledRuntime, to: installedRuntime)
                    try installUserConfigIfNeeded(
                        from: bundledRuntime,
                        applicationSupportRoot: applicationSupportRoot
                    )
                    try prepareResultsDirectory(resultsDirectory)
                    guard hasScanner(at: installedRuntime),
                          immutableRuntimeFilesMatch(source: bundledRuntime, destination: installedRuntime) else {
                        return resultsDirectory
                    }
                    return resultsDirectory
                } catch {
                    return resultsDirectory
                }
            }
        }

        // Command-line development must be explicitly opted in. A release app
        // with a bundled runtime never reaches this branch.
        if environment[developmentModeKey] == "1",
           let path = environment["PCH_PROJECT_DIR"] {
            let candidate = URL(fileURLWithPath: path).standardizedFileURL
            if hasScanner(at: candidate) { return candidate }
        }

        return resultsDirectory
    }

    static func prepareExecution(
        projectRoot: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        resourceURL: URL? = Bundle.main.resourceURL,
        currentDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        mainApplicationResourceURL: URL? = Bundle.main.resourceURL,
        mainApplicationBundleURL: URL = Bundle.main.bundleURL,
        applicationSupportRoot: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
    ) -> RuntimeExecutionContext? {
        // Kept as an injectable test boundary. Standalone resolution never
        // treats the process working directory as executable input.
        _ = currentDirectory
        let normalizedProjectRoot = projectRoot.standardizedFileURL
        if let resourceURL,
           isMainApplicationResourceURL(
            resourceURL,
            mainResourceURL: mainApplicationResourceURL,
            mainBundleURL: mainApplicationBundleURL
           ),
           !bundledRuntimeSignatureIsValid(bundleURL: mainApplicationBundleURL) {
            return nil
        }
        if let resourceURL {
            let bundledRuntime = resourceURL.appendingPathComponent("runtime")
            if pathEntryExists(bundledRuntime) {
                guard hasScanner(at: bundledRuntime) else { return nil }
                let installedRuntime = applicationSupportRoot
                    .appendingPathComponent(applicationSupportName)
                    .appendingPathComponent("runtime")
                let resultsDirectory = applicationSupportRoot
                    .appendingPathComponent(applicationSupportName)
                    .appendingPathComponent("results")
                guard normalizedProjectRoot == resultsDirectory.standardizedFileURL else { return nil }
                let isSignedMainBundle = isMainApplicationResourceURL(
                    resourceURL,
                    mainResourceURL: mainApplicationResourceURL,
                    mainBundleURL: mainApplicationBundleURL
                )
                do {
                    try installBundledRuntime(from: bundledRuntime, to: installedRuntime)
                    try installUserConfigIfNeeded(
                        from: bundledRuntime,
                        applicationSupportRoot: applicationSupportRoot
                    )
                    try prepareResultsDirectory(resultsDirectory)
                    let configurationURL = userConfigURL(applicationSupportRoot: applicationSupportRoot)
                    guard let sealedRuntimeFiles = runtimeFilePayload(at: bundledRuntime),
                          hasScanner(at: installedRuntime),
                          immutableRuntimeFilesMatch(source: bundledRuntime, destination: installedRuntime),
                          workspacePathsAreSafe(
                            installedRuntime: installedRuntime,
                            configurationURL: configurationURL,
                            resultsDirectory: resultsDirectory
                          ),
                          let runtimeRootIdentity = FilesystemIdentity.directory(at: bundledRuntime),
                          let outputRootIdentity = FilesystemIdentity.directory(at: resultsDirectory) else {
                        return nil
                    }
                    if isSignedMainBundle,
                       !runtimePayloadMatchesCodeSignature(
                        sealedRuntimeFiles,
                        bundleURL: mainApplicationBundleURL
                       ) {
                        return nil
                    }
                    // The installed tree is retained only as a mutable output
                    // location and migration target. Executable code is opened
                    // directly from the signed bundle, so replacing the staged
                    // Application Support tree after this check cannot replace the
                    // scanner or cleanup program that will run.
                    return RuntimeExecutionContext(
                        runtimeRoot: bundledRuntime,
                        outputRoot: resultsDirectory,
                        configurationURL: configurationURL,
                        usesBundledRuntime: true,
                        runtimeRootIdentity: runtimeRootIdentity,
                        outputRootIdentity: outputRootIdentity,
                        signedBundleURL: isSignedMainBundle ? mainApplicationBundleURL : nil,
                        sealedRuntimeFiles: sealedRuntimeFiles
                    )
                } catch {
                    return nil
                }
            }
        }

        if environment[developmentModeKey] == "1",
           let path = environment["PCH_PROJECT_DIR"] {
            let developmentRoot = URL(fileURLWithPath: path).standardizedFileURL
            guard normalizedProjectRoot == developmentRoot,
                  hasScanner(at: developmentRoot),
                  let runtimeRootIdentity = FilesystemIdentity.directory(at: developmentRoot),
                  let configurationURL = effectiveConfigurationURL(
                    runtimeRoot: developmentRoot,
                    applicationSupportRoot: applicationSupportRoot
                  ) else {
                return nil
            }
            return RuntimeExecutionContext(
                runtimeRoot: developmentRoot,
                outputRoot: developmentRoot,
                configurationURL: configurationURL,
                usesBundledRuntime: false,
                runtimeRootIdentity: runtimeRootIdentity,
                outputRootIdentity: runtimeRootIdentity,
                signedBundleURL: nil,
                sealedRuntimeFiles: nil
            )
        }
        return nil
    }

    static func prepareForExecution(
        projectRoot: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        resourceURL: URL? = Bundle.main.resourceURL,
        currentDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        applicationSupportRoot: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
    ) -> Bool {
        prepareExecution(
            projectRoot: projectRoot,
            environment: environment,
            resourceURL: resourceURL,
            currentDirectory: currentDirectory,
            applicationSupportRoot: applicationSupportRoot
        ) != nil
    }

    static func codeAtURLMatchesRunningProcess(_ bundleURL: URL) -> Bool {
        validatedStaticCodeMatchingRunningProcess(bundleURL) != nil
    }

    private static func validatedStaticCodeMatchingRunningProcess(
        _ bundleURL: URL
    ) -> SecStaticCode? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(
            bundleURL as CFURL,
            SecCSFlags(),
            &staticCode
        ) == errSecSuccess,
        let staticCode else {
            return nil
        }
        let flags = SecCSFlags(rawValue:
            kSecCSCheckAllArchitectures
                | kSecCSCheckNestedCode
                | kSecCSStrictValidate
                | kSecCSRestrictSymlinks
                | kSecCSRestrictSidebandData
        )
        // Default validity includes the sealed resource envelope. Strict and
        // symlink/sideband restrictions reject bundle structures that could
        // redirect the runtime after validation.
        guard SecStaticCodeCheckValidity(staticCode, flags, nil) == errSecSuccess,
              let candidateHash = uniqueCodeHash(staticCode),
              candidateHash.count == 20 else {
            return nil
        }

        let hashText = candidateHash.map { String(format: "%02x", $0) }.joined()
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(
            "cdhash H\"\(hashText)\"" as CFString,
            SecCSFlags(),
            &requirement
        ) == errSecSuccess,
        let requirement else {
            return nil
        }

        var runningCode: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &runningCode) == errSecSuccess,
              let runningCode else {
            return nil
        }
        // Dynamic validity is kernel-backed and remains tied to the executable
        // that is actually mapped even if the bundle path is replaced. Applying
        // the candidate cdhash as a requirement binds the sealed resources above
        // to this exact running build, not merely any valid ad-hoc signature.
        guard SecCodeCheckValidity(
            runningCode,
            SecCSFlags(),
            requirement
        ) == errSecSuccess else {
            return nil
        }
        return staticCode
    }

    private static func bundledRuntimeSignatureIsValid(bundleURL: URL) -> Bool {
        codeAtURLMatchesRunningProcess(bundleURL)
    }

    private static func uniqueCodeHash(_ code: SecStaticCode) -> Data? {
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            code,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        ) == errSecSuccess,
        let information else {
            return nil
        }
        return (information as NSDictionary)[kSecCodeInfoUnique as String] as? Data
    }

    private static func runtimePayloadMatchesCodeSignature(
        _ payload: [String: Data],
        bundleURL: URL
    ) -> Bool {
        // Keep strict signature validation, running-cdhash binding, and every
        // resource-envelope comparison on one SecStaticCode object. Combining
        // results from separate path-backed objects would allow a bundle path
        // replacement between the checks to authenticate unrelated bytes.
        guard let staticCode = validatedStaticCodeMatchingRunningProcess(bundleURL) else {
            return false
        }
        for (relativePath, contents) in payload {
            let sealedPath = "Resources/runtime/\(relativePath)" as CFString
            guard SecCodeValidateFileResource(
                staticCode,
                sealedPath,
                contents as CFData,
                SecCSFlags()
            ) == errSecSuccess else {
                return false
            }
        }
        return true
    }

    private static func isMainApplicationResourceURL(
        _ resourceURL: URL,
        mainResourceURL: URL?,
        mainBundleURL: URL
    ) -> Bool {
        guard mainBundleURL.pathExtension == "app",
              let mainResourceURL else {
            return false
        }
        return resourceURL.standardizedFileURL == mainResourceURL.standardizedFileURL
    }

    static func userConfigURL(
        applicationSupportRoot: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
    ) -> URL {
        applicationSupportRoot
            .appendingPathComponent(applicationSupportName)
            .appendingPathComponent("config.json")
    }

    static func installUserConfigIfNeeded(from runtime: URL, applicationSupportRoot: URL) throws {
        let fileManager = FileManager.default
        let source = runtime.appendingPathComponent("data/config.example.json")
        let destination = userConfigURL(applicationSupportRoot: applicationSupportRoot)
        guard isRegularFileWithoutSymlink(at: source) else {
            return
        }
        let parent = destination.deletingLastPathComponent()
        guard !pathContainsSymbolicLink(parent) else {
            throw RuntimeWorkspaceError.unsafePath(parent)
        }
        if pathEntryExists(parent) {
            guard isDirectoryWithoutSymlink(at: parent) else {
                throw RuntimeWorkspaceError.unsafePath(parent)
            }
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
            guard isSecureOwnedDirectory(at: parent) else {
                throw RuntimeWorkspaceError.unsafePath(parent)
            }
        }
        if pathEntryExists(destination) {
            guard isSecureOwnedRegularFile(at: destination, privateToOwner: false) else {
                throw RuntimeWorkspaceError.unsafePath(destination)
            }
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: destination.path
            )
            guard isSecureOwnedRegularFile(at: destination, privateToOwner: true) else {
                throw RuntimeWorkspaceError.unsafePath(destination)
            }
            return
        }
        try fileManager.createDirectory(
            at: parent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard !pathContainsSymbolicLink(parent) else {
            throw RuntimeWorkspaceError.unsafePath(parent)
        }
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
        guard isSecureOwnedDirectory(at: parent) else {
            throw RuntimeWorkspaceError.unsafePath(parent)
        }
        let sourceData = try boundedData(contentsOf: source, maximumBytes: 1_048_576)
        _ = try createFileExclusively(
            at: destination,
            contents: sourceData,
            permissions: 0o600
        )
    }

    private static func effectiveConfigurationURL(
        runtimeRoot: URL,
        applicationSupportRoot: URL
    ) -> URL? {
        let external = userConfigURL(applicationSupportRoot: applicationSupportRoot)
        if pathEntryExists(external) {
            return isRegularFileWithoutSymlink(at: external)
                && !pathContainsSymbolicLink(external.deletingLastPathComponent()) ? external : nil
        }
        let local = runtimeRoot.appendingPathComponent("data/config.json")
        if pathEntryExists(local) {
            return isRegularFileWithoutSymlink(at: local) ? local : nil
        }
        let example = runtimeRoot.appendingPathComponent("data/config.example.json")
        return isRegularFileWithoutSymlink(at: example) ? example : nil
    }

    static func installBundledRuntime(from source: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        guard hasScanner(at: source),
              runtimeTree(at: source, allowsMutableOutputs: false) != nil else {
            throw RuntimeWorkspaceError.scannerMissing(source)
        }

        let parent = destination.deletingLastPathComponent()
        guard !pathContainsSymbolicLink(parent) else {
            throw RuntimeWorkspaceError.unsafePath(parent)
        }
        try fileManager.createDirectory(
            at: parent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard isDirectoryWithoutSymlink(at: parent) else {
            throw RuntimeWorkspaceError.unsafePath(parent)
        }
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
        guard isSecureOwnedDirectory(at: parent) else {
            throw RuntimeWorkspaceError.unsafePath(parent)
        }
        let resultsDirectory = parent.appendingPathComponent("results")
        try prepareResultsDirectory(resultsDirectory)
        _ = try migrateLegacyOutputs(
            from: destination,
            to: resultsDirectory
        )
        let sourceManifest = manifestValue(at: source)
        if hasScanner(at: destination),
           isSecureOwnedDirectory(at: destination),
           sourceManifest == manifestValue(at: destination),
           immutableRuntimeFilesMatch(source: source, destination: destination) {
            return
        }

        if pathEntryExists(destination), !isDirectoryWithoutSymlink(at: destination) {
            throw RuntimeWorkspaceError.unsafePath(destination)
        }
        guard !pathContainsSymbolicLink(parent) else {
            throw RuntimeWorkspaceError.unsafePath(parent)
        }

        let staging = parent.appendingPathComponent("runtime-staging-\(UUID().uuidString)")
        let backup = parent.appendingPathComponent("runtime-backup-\(UUID().uuidString)")
        try fileManager.copyItem(at: source, to: staging)

        let legacyConfig = destination.appendingPathComponent("data/config.json")
        let externalConfig = parent.appendingPathComponent("config.json")
        if isRegularFileWithoutSymlink(at: legacyConfig),
           !pathEntryExists(externalConfig) {
            let legacyData = try boundedData(contentsOf: legacyConfig, maximumBytes: 1_048_576)
            _ = try createFileExclusively(
                at: externalConfig,
                contents: legacyData,
                permissions: 0o600
            )
        }

        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.moveItem(at: destination, to: backup)
            do {
                try fileManager.moveItem(at: staging, to: destination)
            } catch {
                if !fileManager.fileExists(atPath: destination.path) {
                    try? fileManager.moveItem(at: backup, to: destination)
                }
                try? fileManager.removeItem(at: staging)
                throw error
            }
        } else {
            try fileManager.moveItem(at: staging, to: destination)
        }

        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: destination.path)
    }

    private static func workspacePathsAreSafe(
        installedRuntime: URL,
        configurationURL: URL,
        resultsDirectory: URL
    ) -> Bool {
        let workspace = installedRuntime.deletingLastPathComponent()
        return !pathContainsSymbolicLink(workspace)
            && !pathContainsSymbolicLink(configurationURL.deletingLastPathComponent())
            && isSecureOwnedDirectory(at: workspace)
            && isSecureOwnedDirectory(at: installedRuntime)
            && isSecureOwnedDirectory(at: resultsDirectory)
            && isSecureOwnedRegularFile(at: configurationURL, privateToOwner: true)
    }

    private static func prepareResultsDirectory(_ resultsDirectory: URL) throws {
        let parent = resultsDirectory.deletingLastPathComponent()
        guard !pathContainsSymbolicLink(parent) else {
            throw RuntimeWorkspaceError.unsafePath(parent)
        }
        try FileManager.default.createDirectory(
            at: resultsDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard !pathContainsSymbolicLink(resultsDirectory),
              isDirectoryWithoutSymlink(at: resultsDirectory) else {
            throw RuntimeWorkspaceError.unsafePath(resultsDirectory)
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: resultsDirectory.path
        )
        guard isSecureOwnedDirectory(at: parent),
              isSecureOwnedDirectory(at: resultsDirectory) else {
            throw RuntimeWorkspaceError.unsafePath(resultsDirectory)
        }
    }

    private static func migrateLegacyOutputs(from runtime: URL, to results: URL) throws -> Bool {
        guard isDirectoryWithoutSymlink(at: runtime) else { return true }
        var allPreserved = true
        for relativePath in mutableRuntimeOutputs {
            let source = runtime.appendingPathComponent(relativePath)
            guard pathEntryExists(source) else { continue }
            guard isRegularFileWithoutSymlink(at: source),
                  let data = try? boundedData(
                    contentsOf: source,
                    maximumBytes: 64 * 1_024 * 1_024
                  ) else {
                allPreserved = false
                continue
            }
            let destination = results.appendingPathComponent(relativePath)
            if pathEntryExists(destination) {
                guard isRegularFileWithoutSymlink(at: destination),
                      let existing = try? boundedData(
                        contentsOf: destination,
                        maximumBytes: 64 * 1_024 * 1_024
                      ),
                      existing == data else {
                    allPreserved = false
                    continue
                }
            } else {
                _ = try createFileExclusively(
                    at: destination,
                    contents: data,
                    permissions: 0o600
                )
            }
        }
        return allPreserved
    }

    static func hasScanner(at url: URL) -> Bool {
        guard !isSymbolicLink(at: url) else { return false }
        guard let rootAttributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              rootAttributes[.type] as? FileAttributeType == .typeDirectory else {
            return false
        }
        let scripts = url.appendingPathComponent("scripts")
        guard !isSymbolicLink(at: scripts) else { return false }
        guard let scriptsAttributes = try? FileManager.default.attributesOfItem(atPath: scripts.path),
              scriptsAttributes[.type] as? FileAttributeType == .typeDirectory else {
            return false
        }
        let scanner = url.appendingPathComponent("scripts/scanner.sh")
        guard !isSymbolicLink(at: scanner) else { return false }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: scanner.path),
              let type = attributes[.type] as? FileAttributeType else {
            return false
        }
        return type == .typeRegular
    }

    private static func pathEntryExists(_ url: URL) -> Bool {
        var value = stat()
        return url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            return Darwin.lstat(path, &value) == 0
        }
    }

    private static func isSymbolicLink(at url: URL) -> Bool {
        var value = stat()
        return url.withUnsafeFileSystemRepresentation { path in
            guard let path, Darwin.lstat(path, &value) == 0 else { return false }
            return value.st_mode & S_IFMT == S_IFLNK
        }
    }

    private static func isRegularFileWithoutSymlink(at url: URL) -> Bool {
        var value = stat()
        return url.withUnsafeFileSystemRepresentation { path in
            guard let path, Darwin.lstat(path, &value) == 0 else { return false }
            return value.st_mode & S_IFMT == S_IFREG
        }
    }

    private static func isSecureOwnedRegularFile(
        at url: URL,
        privateToOwner: Bool
    ) -> Bool {
        var value = stat()
        let status = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.lstat(path, &value)
        }
        let forbidden = privateToOwner
            ? mode_t(S_IRWXG | S_IRWXO)
            : mode_t(S_IWGRP | S_IWOTH)
        return status == 0
            && value.st_mode & S_IFMT == S_IFREG
            && value.st_uid == Darwin.geteuid()
            && value.st_mode & forbidden == 0
    }

    private static func isDirectoryWithoutSymlink(at url: URL) -> Bool {
        var value = stat()
        return url.withUnsafeFileSystemRepresentation { path in
            guard let path, Darwin.lstat(path, &value) == 0 else { return false }
            return value.st_mode & S_IFMT == S_IFDIR
        }
    }

    private static func isSecureOwnedDirectory(at url: URL) -> Bool {
        var value = stat()
        let status = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.lstat(path, &value)
        }
        return status == 0
            && value.st_mode & S_IFMT == S_IFDIR
            && value.st_uid == Darwin.geteuid()
            && value.st_mode & mode_t(S_IWGRP | S_IWOTH) == 0
    }

    private static func pathContainsSymbolicLink(_ url: URL) -> Bool {
        let standardized = url.standardizedFileURL
        guard standardized.path.hasPrefix("/") else { return true }
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for component in standardized.pathComponents.dropFirst() {
            current.appendPathComponent(component)
            if current.path == "/var" || current.path == "/tmp" {
                continue
            }
            if isSymbolicLink(at: current) { return true }
        }
        return false
    }

    private struct RuntimeTreeEntry: Equatable {
        let isDirectory: Bool
        let contents: Data?
    }

    private static let mutableRuntimeOutputs: Set<String> = [
        "scan_result.json",
        "raw_facts.json",
        "검사결과.html",
        "검사결과_공유용.html",
    ]
    private static let maximumRuntimeEntries = 512
    private static let maximumRuntimeFileBytes = 16 * 1_024 * 1_024
    private static let maximumRuntimeTotalBytes = 128 * 1_024 * 1_024

    private static func immutableRuntimeFilesMatch(source: URL, destination: URL) -> Bool {
        guard let sourceTree = runtimeTree(at: source, allowsMutableOutputs: false),
              let destinationTree = runtimeTree(at: destination, allowsMutableOutputs: true) else {
            return false
        }
        return sourceTree == destinationTree
    }

    private static func runtimeFilePayload(at root: URL) -> [String: Data]? {
        guard let tree = runtimeTree(at: root, allowsMutableOutputs: false) else { return nil }
        var payload: [String: Data] = [:]
        for (path, entry) in tree where !entry.isDirectory {
            guard let contents = entry.contents else { return nil }
            payload[path] = contents
        }
        return payload
    }

    private static func runtimeTree(
        at root: URL,
        allowsMutableOutputs: Bool
    ) -> [String: RuntimeTreeEntry]? {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
        ]
        guard hasScanner(at: root),
              let canonicalRootPath = canonicalFilesystemPath(root),
              !canonicalRootPath.isEmpty else {
            return nil
        }
        let canonicalRoot = URL(fileURLWithPath: canonicalRootPath, isDirectory: true)
        guard
              let enumerator = FileManager.default.enumerator(
                at: canonicalRoot,
                includingPropertiesForKeys: Array(keys),
                options: []
              ) else {
            return nil
        }

        var result: [String: RuntimeTreeEntry] = [:]
        var totalBytes = 0
        for case let url as URL in enumerator {
            guard result.count < maximumRuntimeEntries else { return nil }
            let prefix = canonicalRootPath.hasSuffix("/")
                ? canonicalRootPath : canonicalRootPath + "/"
            guard url.path.hasPrefix(prefix) else { return nil }
            let relativePath = String(url.path.dropFirst(prefix.count))
            guard !relativePath.isEmpty, !relativePath.hasPrefix("/"),
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isSymbolicLink != true else {
                return nil
            }
            if allowsMutableOutputs && mutableRuntimeOutputs.contains(relativePath) {
                guard values.isRegularFile == true else { return nil }
                continue
            }
            if values.isDirectory == true {
                result[relativePath] = RuntimeTreeEntry(isDirectory: true, contents: nil)
            } else if values.isRegularFile == true,
                      let fileSize = values.fileSize,
                      fileSize >= 0,
                      fileSize <= maximumRuntimeFileBytes,
                      totalBytes <= maximumRuntimeTotalBytes - fileSize,
                      let data = try? boundedData(
                        contentsOf: url,
                        maximumBytes: maximumRuntimeFileBytes
                      ) {
                totalBytes += data.count
                result[relativePath] = RuntimeTreeEntry(isDirectory: false, contents: data)
            } else {
                return nil
            }
        }
        return result
    }

    private static func canonicalFilesystemPath(_ url: URL) -> String? {
        url.path.withCString { path in
            guard let resolved = Darwin.realpath(path, nil) else { return nil }
            defer { Darwin.free(resolved) }
            return String(cString: resolved)
        }
    }

    private static func manifestValue(at runtime: URL) -> String? {
        let url = runtime.appendingPathComponent("runtime-manifest.txt")
        guard let data = try? boundedData(contentsOf: url, maximumBytes: 4_096),
              let value = String(data: data, encoding: .utf8) else { return nil }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func boundedData(contentsOf url: URL, maximumBytes: Int) throws -> Data {
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw posixError(errno) }
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_size >= 0,
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

    /// Creates a user configuration without a copy/chmod pathname race. The
    /// opened parent directory and O_EXCL/O_NOFOLLOW bind the write to a new
    /// regular file; an existing safe file is never overwritten.
    @discardableResult
    private static func createFileExclusively(
        at destination: URL,
        contents: Data,
        permissions: mode_t
    ) throws -> Bool {
        let parent = destination.deletingLastPathComponent()
        let name = destination.lastPathComponent
        guard !name.isEmpty, !name.contains("/") else { throw posixError(EINVAL) }
        let parentDescriptor = parent.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard parentDescriptor >= 0 else { throw posixError(errno) }
        defer { Darwin.close(parentDescriptor) }

        let descriptor = name.withCString {
            Darwin.openat(
                parentDescriptor,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                permissions
            )
        }
        if descriptor < 0, errno == EEXIST {
            var existing = stat()
            let status = name.withCString {
                Darwin.fstatat(parentDescriptor, $0, &existing, AT_SYMLINK_NOFOLLOW)
            }
            guard status == 0,
                  existing.st_mode & S_IFMT == S_IFREG,
                  existing.st_uid == Darwin.geteuid(),
                  existing.st_mode & mode_t(S_IRWXG | S_IRWXO) == 0 else {
                throw RuntimeWorkspaceError.unsafePath(destination)
            }
            return false
        }
        guard descriptor >= 0 else { throw posixError(errno) }
        var completed = false
        defer {
            if !completed {
                var opened = stat()
                var current = stat()
                if Darwin.fstat(descriptor, &opened) == 0 {
                    let status = name.withCString {
                        Darwin.fstatat(parentDescriptor, $0, &current, AT_SYMLINK_NOFOLLOW)
                    }
                    if status == 0,
                       opened.st_dev == current.st_dev,
                       opened.st_ino == current.st_ino {
                        _ = name.withCString {
                            Darwin.unlinkat(parentDescriptor, $0, 0)
                        }
                    }
                }
            }
            Darwin.close(descriptor)
        }
        try contents.withUnsafeBytes { bytes in
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
        completed = true
        return true
    }
}

private func posixError(_ code: Int32) -> NSError {
    NSError(domain: NSPOSIXErrorDomain, code: Int(code))
}

enum RuntimeWorkspaceError: LocalizedError {
    case scannerMissing(URL)
    case unsafePath(URL)

    var errorDescription: String? {
        switch self {
        case .scannerMissing(let url):
            return "Bundled scanner is missing or not executable: \(url.path)"
        case .unsafePath(let url):
            return "Runtime path contains a symbolic link or unsafe file type: \(url.path)"
        }
    }
}
