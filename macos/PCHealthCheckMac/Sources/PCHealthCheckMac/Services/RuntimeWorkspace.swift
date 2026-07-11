import Darwin
import Foundation
import Security

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

        if let resourceURL,
           isMainApplicationResourceURL(
            resourceURL,
            mainResourceURL: mainApplicationResourceURL,
            mainBundleURL: mainApplicationBundleURL
           ),
           !bundledRuntimeSignatureIsValid(bundleURL: mainApplicationBundleURL) {
            // A modified production bundle must never fall through to an
            // environment-selected development path.
            return installedRuntime
        }

        // A standalone app always uses its signed bundled runtime as the source
        // of truth. Environment variables and the process working directory are
        // intentionally ignored on this path.
        if let resourceURL {
            let bundledRuntime = resourceURL.appendingPathComponent("runtime")
            if pathEntryExists(bundledRuntime) {
                guard hasScanner(at: bundledRuntime) else { return installedRuntime }
                do {
                    try installBundledRuntime(from: bundledRuntime, to: installedRuntime)
                    try installUserConfigIfNeeded(
                        from: bundledRuntime,
                        applicationSupportRoot: applicationSupportRoot
                    )
                    guard hasScanner(at: installedRuntime),
                          immutableRuntimeFilesMatch(source: bundledRuntime, destination: installedRuntime) else {
                        return installedRuntime
                    }
                    return installedRuntime
                } catch {
                    return installedRuntime
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

        return installedRuntime
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
                guard normalizedProjectRoot == installedRuntime.standardizedFileURL else { return nil }
                do {
                    try installBundledRuntime(from: bundledRuntime, to: installedRuntime)
                    try installUserConfigIfNeeded(
                        from: bundledRuntime,
                        applicationSupportRoot: applicationSupportRoot
                    )
                    let configurationURL = userConfigURL(applicationSupportRoot: applicationSupportRoot)
                    guard runtimeTree(at: bundledRuntime, allowsMutableOutputs: false) != nil,
                          hasScanner(at: installedRuntime),
                          immutableRuntimeFilesMatch(source: bundledRuntime, destination: installedRuntime),
                          isRegularFileWithoutSymlink(at: configurationURL) else {
                        return nil
                    }
                    // The installed tree is retained only as a mutable output
                    // location and migration target. Executable code is opened
                    // directly from the signed bundle, so replacing the staged
                    // Application Support tree after this check cannot replace the
                    // scanner or cleanup program that will run.
                    return RuntimeExecutionContext(
                        runtimeRoot: bundledRuntime,
                        outputRoot: installedRuntime,
                        configurationURL: configurationURL,
                        usesBundledRuntime: true
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
                usesBundledRuntime: false
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

    private static func bundledRuntimeSignatureIsValid(bundleURL: URL) -> Bool {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(
            bundleURL as CFURL,
            SecCSFlags(),
            &staticCode
        ) == errSecSuccess,
        let staticCode else {
            return false
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
        return SecStaticCodeCheckValidity(staticCode, flags, nil) == errSecSuccess
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
        if pathEntryExists(destination) {
            guard isRegularFileWithoutSymlink(at: destination) else {
                throw RuntimeWorkspaceError.unsafePath(destination)
            }
            return
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
        try fileManager.copyItem(at: source, to: destination)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }

    private static func effectiveConfigurationURL(
        runtimeRoot: URL,
        applicationSupportRoot: URL
    ) -> URL? {
        let external = userConfigURL(applicationSupportRoot: applicationSupportRoot)
        if pathEntryExists(external) {
            return isRegularFileWithoutSymlink(at: external) ? external : nil
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

        let sourceManifest = manifestValue(at: source)
        if hasScanner(at: destination),
           sourceManifest == manifestValue(at: destination),
           immutableRuntimeFilesMatch(source: source, destination: destination) {
            return
        }

        let parent = destination.deletingLastPathComponent()
        guard !pathContainsSymbolicLink(parent) else {
            throw RuntimeWorkspaceError.unsafePath(parent)
        }
        if pathEntryExists(destination), !isDirectoryWithoutSymlink(at: destination) {
            throw RuntimeWorkspaceError.unsafePath(destination)
        }
        try fileManager.createDirectory(
            at: parent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let staging = parent.appendingPathComponent("runtime-staging-\(UUID().uuidString)")
        let backup = parent.appendingPathComponent("runtime-backup-\(UUID().uuidString)")
        try fileManager.copyItem(at: source, to: staging)

        let legacyConfig = destination.appendingPathComponent("data/config.json")
        let externalConfig = parent.appendingPathComponent("config.json")
        if isRegularFileWithoutSymlink(at: legacyConfig),
           !pathEntryExists(externalConfig) {
            try fileManager.copyItem(at: legacyConfig, to: externalConfig)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: externalConfig.path)
        }

        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.moveItem(at: destination, to: backup)
            do {
                try fileManager.moveItem(at: staging, to: destination)
                try fileManager.removeItem(at: backup)
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

    private static func isDirectoryWithoutSymlink(at url: URL) -> Bool {
        var value = stat()
        return url.withUnsafeFileSystemRepresentation { path in
            guard let path, Darwin.lstat(path, &value) == 0 else { return false }
            return value.st_mode & S_IFMT == S_IFDIR
        }
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

    private static func immutableRuntimeFilesMatch(source: URL, destination: URL) -> Bool {
        guard let sourceTree = runtimeTree(at: source, allowsMutableOutputs: false),
              let destinationTree = runtimeTree(at: destination, allowsMutableOutputs: true) else {
            return false
        }
        return sourceTree == destinationTree
    }

    private static func runtimeTree(
        at root: URL,
        allowsMutableOutputs: Bool
    ) -> [String: RuntimeTreeEntry]? {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
        guard hasScanner(at: root),
              let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: Array(keys),
                options: []
              ) else {
            return nil
        }

        var result: [String: RuntimeTreeEntry] = [:]
        for case let url as URL in enumerator {
            let relativePath = String(url.path.dropFirst(root.path.count + 1))
            guard !relativePath.isEmpty,
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
                      let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) {
                result[relativePath] = RuntimeTreeEntry(isDirectory: false, contents: data)
            } else {
                return nil
            }
        }
        return result
    }

    private static func manifestValue(at runtime: URL) -> String? {
        let url = runtime.appendingPathComponent("runtime-manifest.txt")
        return try? String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
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
