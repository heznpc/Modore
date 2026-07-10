import Foundation

enum RuntimeWorkspace {
    static let applicationSupportName = "PC Health Check"

    static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        resourceURL: URL? = Bundle.main.resourceURL,
        currentDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        applicationSupportRoot: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
    ) -> URL {
        if let path = environment["PCH_PROJECT_DIR"] {
            let candidate = URL(fileURLWithPath: path)
            if hasScanner(at: candidate) { return candidate }
        }

        if let resourceURL {
            let marker = resourceURL.appendingPathComponent("project-root.txt")
            if let text = try? String(contentsOf: marker, encoding: .utf8) {
                let candidate = URL(
                    fileURLWithPath: text.trimmingCharacters(in: .whitespacesAndNewlines)
                )
                if hasScanner(at: candidate) { return candidate }
            }
        }

        var current = currentDirectory
        for _ in 0..<8 {
            if hasScanner(at: current) { return current }
            current.deleteLastPathComponent()
        }

        if let bundledRuntime = resourceURL?.appendingPathComponent("runtime"),
           hasScanner(at: bundledRuntime) {
            let destination: URL
            if let override = environment["PCH_RUNTIME_ROOT"], !override.isEmpty {
                destination = URL(fileURLWithPath: override)
            } else {
                destination = applicationSupportRoot
                    .appendingPathComponent(applicationSupportName)
                    .appendingPathComponent("runtime")
            }
            if (try? installBundledRuntime(from: bundledRuntime, to: destination)) != nil,
               hasScanner(at: destination) {
                return destination
            }
        }

        return currentDirectory
    }

    static func installBundledRuntime(from source: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        guard hasScanner(at: source) else {
            throw RuntimeWorkspaceError.scannerMissing(source)
        }

        let sourceManifest = manifestValue(at: source)
        if hasScanner(at: destination),
           sourceManifest == manifestValue(at: destination),
           immutableRuntimeFilesMatch(source: source, destination: destination) {
            return
        }

        let parent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: parent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let staging = parent.appendingPathComponent("runtime-staging-\(UUID().uuidString)")
        let backup = parent.appendingPathComponent("runtime-backup-\(UUID().uuidString)")
        try fileManager.copyItem(at: source, to: staging)

        let existingConfig = destination.appendingPathComponent("data/config.json")
        let stagedConfig = staging.appendingPathComponent("data/config.json")
        if let data = try? Data(contentsOf: existingConfig) {
            try data.write(to: stagedConfig, options: .atomic)
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
        let scanner = url.appendingPathComponent("scripts/scanner.sh")
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: scanner.path),
              let type = attributes[.type] as? FileAttributeType else {
            return false
        }
        return type == .typeRegular
    }

    private static func immutableRuntimeFilesMatch(source: URL, destination: URL) -> Bool {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: source,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }

        for case let sourceFile as URL in enumerator {
            let relativePath = String(sourceFile.path.dropFirst(source.path.count + 1))
            if relativePath == "data/config.json" || relativePath == "runtime-manifest.txt" {
                continue
            }
            guard (try? sourceFile.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                continue
            }

            let destinationFile = destination.appendingPathComponent(relativePath)
            guard let attributes = try? fileManager.attributesOfItem(atPath: destinationFile.path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  let sourceData = try? Data(contentsOf: sourceFile),
                  let destinationData = try? Data(contentsOf: destinationFile),
                  sourceData == destinationData else {
                return false
            }
        }
        return true
    }

    private static func manifestValue(at runtime: URL) -> String? {
        let url = runtime.appendingPathComponent("runtime-manifest.txt")
        return try? String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum RuntimeWorkspaceError: LocalizedError {
    case scannerMissing(URL)

    var errorDescription: String? {
        switch self {
        case .scannerMissing(let url):
            return "Bundled scanner is missing or not executable: \(url.path)"
        }
    }
}
