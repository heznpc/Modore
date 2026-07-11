import Foundation
import XCTest
@testable import PCHealthCheckMac

final class CleanupSafetyTests: XCTestCase {
    func testReadyCleanupRequiresApprovalToken() throws {
        let missingToken = try XCTUnwrap(CleanupPreview(protocolText: """
        version\t1
        operation\tpreview
        status\tready
        recipeId\tnpm_cache
        label\tnpm cache
        estimatedKB\t4
        target\t/Users/test/.npm
        """))
        XCTAssertFalse(missingToken.canExecute)

        let approved = try XCTUnwrap(CleanupPreview(protocolText: """
        version\t1
        operation\tpreview
        status\tready
        recipeId\tnpm_cache
        label\tnpm cache
        estimatedKB\t4
        approvalToken\t0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
        target\t/Users/test/.npm
        """))
        XCTAssertTrue(approved.canExecute)
    }

    func testStandaloneRuntimeIgnoresEnvironmentAndWorkingDirectoryOverrides() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pch-runtime-boundary-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = root.appendingPathComponent("resources")
        let bundled = resources.appendingPathComponent("runtime")
        let attacker = root.appendingPathComponent("attacker")
        let support = root.appendingPathComponent("support")
        try writeRuntime(at: bundled, marker: "signed")
        try writeRuntime(at: attacker, marker: "attacker")

        let resolved = RuntimeWorkspace.resolve(
            environment: [
                "PCH_DEVELOPMENT_MODE": "1",
                "PCH_PROJECT_DIR": attacker.path,
                "PCH_RUNTIME_ROOT": attacker.path,
            ],
            resourceURL: resources,
            currentDirectory: attacker,
            applicationSupportRoot: support
        )

        let expected = support.appendingPathComponent("PC Health Check/runtime")
        XCTAssertEqual(resolved.standardizedFileURL, expected.standardizedFileURL)
        XCTAssertEqual(
            try String(contentsOf: resolved.appendingPathComponent("runtime-manifest.txt")),
            "signed"
        )
        let config = RuntimeWorkspace.userConfigURL(applicationSupportRoot: support)
        XCTAssertEqual(try String(contentsOf: config), "{\"local\":true}\n")
        let permissions = try FileManager.default.attributesOfItem(atPath: config.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue ?? 0, 0o600)
    }

    func testStandaloneExecutionUsesSignedBundleAfterStagedRuntimeChanges() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pch-runtime-execution-source-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = root.appendingPathComponent("resources")
        let bundled = resources.appendingPathComponent("runtime")
        let attacker = root.appendingPathComponent("attacker")
        let support = root.appendingPathComponent("support")
        try writeRuntime(at: bundled, marker: "signed")
        try writeRuntime(at: attacker, marker: "attacker")

        let installed = RuntimeWorkspace.resolve(
            environment: [
                "PCH_DEVELOPMENT_MODE": "1",
                "PCH_PROJECT_DIR": attacker.path,
            ],
            resourceURL: resources,
            currentDirectory: attacker,
            applicationSupportRoot: support
        )
        let execution = try XCTUnwrap(RuntimeWorkspace.prepareExecution(
            projectRoot: installed,
            environment: [
                "PCH_DEVELOPMENT_MODE": "1",
                "PCH_PROJECT_DIR": attacker.path,
            ],
            resourceURL: resources,
            currentDirectory: attacker,
            applicationSupportRoot: support
        ))

        XCTAssertTrue(execution.usesBundledRuntime)
        XCTAssertEqual(execution.runtimeRoot.standardizedFileURL, bundled.standardizedFileURL)
        XCTAssertEqual(execution.outputRoot.standardizedFileURL, installed.standardizedFileURL)
        XCTAssertEqual(
            execution.configurationURL.standardizedFileURL,
            RuntimeWorkspace.userConfigURL(applicationSupportRoot: support).standardizedFileURL
        )
        XCTAssertTrue(execution.scannerScriptURL.path.hasPrefix(bundled.path + "/"))
        XCTAssertTrue(execution.cleanupScriptURL.path.hasPrefix(bundled.path + "/"))
        XCTAssertTrue(execution.scheduleScriptURL.path.hasPrefix(bundled.path + "/"))
        XCTAssertTrue(execution.storageWatchScriptURL.path.hasPrefix(bundled.path + "/"))
        XCTAssertFalse(execution.scannerScriptURL.path.hasPrefix(installed.path + "/"))

        try "#!/bin/bash\n# replaced after validation\nexit 99\n".write(
            to: installed.appendingPathComponent("scripts/scanner.sh"),
            atomically: true,
            encoding: .utf8
        )
        try "#!/bin/bash\n# replaced cleanup\nexit 99\n".write(
            to: installed.appendingPathComponent("scripts/cleanup.sh"),
            atomically: true,
            encoding: .utf8
        )

        XCTAssertTrue(try String(contentsOf: execution.scannerScriptURL).contains("signed"))
        XCTAssertTrue(try String(contentsOf: execution.cleanupScriptURL).contains("cleanup-signed"))
        XCTAssertFalse(try String(contentsOf: execution.scannerScriptURL).contains("replaced"))
    }

    func testInvalidProductionBundleCannotFallThroughToMarkerOrEnvironmentRuntime() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pch-invalid-production-bundle-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fakeApp = root.appendingPathComponent("Tampered.app")
        let resources = fakeApp.appendingPathComponent("Contents/Resources")
        let bundled = resources.appendingPathComponent("runtime")
        let attacker = root.appendingPathComponent("attacker")
        let support = root.appendingPathComponent("support")
        try writeRuntime(at: bundled, marker: "tampered-bundle")
        try writeRuntime(at: attacker, marker: "attacker")
        try attacker.path.write(
            to: resources.appendingPathComponent("project-root.txt"),
            atomically: true,
            encoding: .utf8
        )

        let expectedInstalled = support.appendingPathComponent("PC Health Check/runtime")
        let environment = [
            "PCH_DEVELOPMENT_MODE": "1",
            "PCH_PROJECT_DIR": attacker.path,
        ]
        let resolved = RuntimeWorkspace.resolve(
            environment: environment,
            resourceURL: resources,
            currentDirectory: attacker,
            mainApplicationResourceURL: resources,
            mainApplicationBundleURL: fakeApp,
            applicationSupportRoot: support
        )
        XCTAssertEqual(resolved.standardizedFileURL, expectedInstalled.standardizedFileURL)
        XCTAssertNotEqual(resolved.standardizedFileURL, attacker.standardizedFileURL)
        XCTAssertFalse(RuntimeWorkspace.hasScanner(at: resolved))

        XCTAssertNil(RuntimeWorkspace.prepareExecution(
            projectRoot: expectedInstalled,
            environment: environment,
            resourceURL: resources,
            currentDirectory: attacker,
            mainApplicationResourceURL: resources,
            mainApplicationBundleURL: fakeApp,
            applicationSupportRoot: support
        ))
    }

    func testStorageWatchRejectsRelocatedOrMutableRuntimePath() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pch-storage-watch-runtime-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let expectedWatcher = root.appendingPathComponent("Signed.app/Contents/Resources/runtime/scripts/storage_watch.sh")
        let staleWatcher = root.appendingPathComponent("Old.app/Contents/Resources/runtime/scripts/storage_watch.sh")
        let plistURL = root.appendingPathComponent("Library/LaunchAgents/me.heznpc.pchealthcheck.storage-watch.plist")
        try FileManager.default.createDirectory(
            at: expectedWatcher.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: plistURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "#!/bin/bash\nexit 0\n".write(to: expectedWatcher, atomically: true, encoding: .utf8)

        func writePlist(watcher: URL) throws {
            let payload: [String: Any] = [
                "Label": "me.heznpc.pchealthcheck.storage-watch",
                "ProgramArguments": ["/bin/bash", watcher.path],
            ]
            let data = try PropertyListSerialization.data(
                fromPropertyList: payload,
                format: .xml,
                options: 0
            )
            try data.write(to: plistURL, options: .atomic)
        }

        // A leftover plist is unsafe even when launchctl currently reports the
        // job as unloaded: the next login can load it again.
        let protocolValues = ["enabled": "false", "plist": plistURL.path]
        try writePlist(watcher: staleWatcher)
        XCTAssertEqual(ScanModel.storageWatchRuntimeState(
            protocolValues: protocolValues,
            expectedWatcherURL: expectedWatcher
        ), .stale)

        // Installing replaces the stale definition with the current signed
        // bundle watcher path.
        try writePlist(watcher: expectedWatcher)
        XCTAssertEqual(ScanModel.storageWatchRuntimeState(
            protocolValues: protocolValues,
            expectedWatcherURL: expectedWatcher
        ), .current)

        let mutableWatcher = root.appendingPathComponent("Application Support/PC Health Check/runtime/scripts/storage_watch.sh")
        try writePlist(watcher: mutableWatcher)
        XCTAssertEqual(ScanModel.storageWatchRuntimeState(
            protocolValues: protocolValues,
            expectedWatcherURL: expectedWatcher
        ), .stale)

        let outsidePlist = root.appendingPathComponent("outside.plist")
        try FileManager.default.moveItem(at: plistURL, to: outsidePlist)
        try FileManager.default.createSymbolicLink(at: plistURL, withDestinationURL: outsidePlist)
        XCTAssertEqual(ScanModel.storageWatchRuntimeState(
            protocolValues: protocolValues,
            expectedWatcherURL: expectedWatcher
        ), .stale)

        // Uninstall must remove the entry rather than merely unload it.
        try FileManager.default.removeItem(at: plistURL)
        XCTAssertEqual(ScanModel.storageWatchRuntimeState(
            protocolValues: protocolValues,
            expectedWatcherURL: expectedWatcher
        ), .absent)
    }

    @MainActor
    func testTerminationSafetyGateWaitsForDestructiveTransactionCompletion() {
        let gate = AppTerminationSafetyGate()
        var terminationReplies = 0

        gate.beginDestructiveTransaction()
        gate.beginDestructiveTransaction()
        XCTAssertEqual(gate.state, .destructiveCleanupInProgress)
        XCTAssertTrue(gate.deferTerminationUntilSafe { terminationReplies += 1 })

        gate.finishDestructiveTransaction()
        XCTAssertEqual(gate.state, .destructiveCleanupInProgress)
        XCTAssertEqual(terminationReplies, 0)

        gate.finishDestructiveTransaction()
        XCTAssertEqual(gate.state, .safe)
        XCTAssertEqual(terminationReplies, 1)
        XCTAssertFalse(gate.deferTerminationUntilSafe { terminationReplies += 1 })
        XCTAssertEqual(terminationReplies, 1)
    }

    func testEnvironmentSourceOverrideRequiresExplicitDevelopmentMode() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pch-runtime-development-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let resources = root.appendingPathComponent("resources")
        let support = root.appendingPathComponent("support")
        try writeRuntime(at: source, marker: "source")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)

        let rejected = RuntimeWorkspace.resolve(
            environment: ["PCH_PROJECT_DIR": source.path],
            resourceURL: resources,
            currentDirectory: source,
            applicationSupportRoot: support
        )
        XCTAssertEqual(
            rejected.standardizedFileURL,
            support.appendingPathComponent("PC Health Check/runtime").standardizedFileURL
        )

        let accepted = RuntimeWorkspace.resolve(
            environment: ["PCH_DEVELOPMENT_MODE": "1", "PCH_PROJECT_DIR": source.path],
            resourceURL: resources,
            currentDirectory: root,
            applicationSupportRoot: support
        )
        XCTAssertEqual(accepted.standardizedFileURL, source.standardizedFileURL)
    }

    func testExecutionRevalidationRemovesUnexpectedRuntimeFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pch-runtime-revalidate-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = root.appendingPathComponent("resources")
        let bundled = resources.appendingPathComponent("runtime")
        let support = root.appendingPathComponent("support")
        try writeRuntime(at: bundled, marker: "signed")
        let installed = RuntimeWorkspace.resolve(
            environment: [:],
            resourceURL: resources,
            currentDirectory: root,
            applicationSupportRoot: support
        )
        let unexpected = installed.appendingPathComponent("sitecustomize.py")
        try "raise SystemExit\n".write(to: unexpected, atomically: true, encoding: .utf8)

        XCTAssertTrue(RuntimeWorkspace.prepareForExecution(
            projectRoot: installed,
            environment: [:],
            resourceURL: resources,
            applicationSupportRoot: support
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: unexpected.path))
    }

    func testRuntimeRootAndSupportSymlinksAreRejected() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pch-runtime-symlinks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let actualRuntime = root.appendingPathComponent("actual-runtime")
        let runtimeLink = root.appendingPathComponent("runtime-link")
        try writeRuntime(at: actualRuntime, marker: "signed")
        try FileManager.default.createSymbolicLink(at: runtimeLink, withDestinationURL: actualRuntime)
        XCTAssertFalse(RuntimeWorkspace.hasScanner(at: runtimeLink))

        let resources = root.appendingPathComponent("resources")
        let bundled = resources.appendingPathComponent("runtime")
        try writeRuntime(at: bundled, marker: "signed")
        let outsideSupport = root.appendingPathComponent("outside-support")
        let supportLink = root.appendingPathComponent("support-link")
        try FileManager.default.createDirectory(at: outsideSupport, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: supportLink, withDestinationURL: outsideSupport)
        let expectedRuntime = supportLink.appendingPathComponent("PC Health Check/runtime")

        XCTAssertFalse(RuntimeWorkspace.prepareForExecution(
            projectRoot: expectedRuntime,
            environment: [:],
            resourceURL: resources,
            applicationSupportRoot: supportLink
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: outsideSupport.appendingPathComponent("PC Health Check/runtime").path
        ))
    }

    func testConfigSymlinksAreNeverCopiedOrOverwritten() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pch-config-symlink-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = root.appendingPathComponent("resources")
        let bundled = resources.appendingPathComponent("runtime")
        let support = root.appendingPathComponent("support")
        try writeRuntime(at: bundled, marker: "signed")
        let installed = RuntimeWorkspace.resolve(
            environment: [:],
            resourceURL: resources,
            currentDirectory: root,
            applicationSupportRoot: support
        )

        let outside = root.appendingPathComponent("outside-secret")
        try "keep".write(to: outside, atomically: true, encoding: .utf8)
        let config = RuntimeWorkspace.userConfigURL(applicationSupportRoot: support)
        try FileManager.default.removeItem(at: config)
        try FileManager.default.createSymbolicLink(at: config, withDestinationURL: outside)

        XCTAssertFalse(RuntimeWorkspace.prepareForExecution(
            projectRoot: installed,
            environment: [:],
            resourceURL: resources,
            applicationSupportRoot: support
        ))
        XCTAssertEqual(try String(contentsOf: outside), "keep")
    }

    private func writeRuntime(at root: URL, marker: String) throws {
        let scanner = root.appendingPathComponent("scripts/scanner.sh")
        let cleanup = root.appendingPathComponent("scripts/cleanup.sh")
        let report = root.appendingPathComponent("scripts/report.jxa.js")
        let schedule = root.appendingPathComponent("scripts/schedule.sh")
        let storageWatch = root.appendingPathComponent("scripts/storage_watch.sh")
        let example = root.appendingPathComponent("data/config.example.json")
        try FileManager.default.createDirectory(
            at: scanner.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: example.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "#!/bin/bash\n# \(marker)\nexit 0\n".write(to: scanner, atomically: true, encoding: .utf8)
        try "#!/bin/bash\n# cleanup-\(marker)\nexit 0\n".write(
            to: cleanup,
            atomically: true,
            encoding: .utf8
        )
        try "// report-\(marker)\n".write(to: report, atomically: true, encoding: .utf8)
        try "#!/bin/bash\n# schedule-\(marker)\nexit 0\n".write(
            to: schedule,
            atomically: true,
            encoding: .utf8
        )
        try "#!/bin/bash\n# watch-\(marker)\nexit 0\n".write(
            to: storageWatch,
            atomically: true,
            encoding: .utf8
        )
        try "{\"local\":true}\n".write(to: example, atomically: true, encoding: .utf8)
        try marker.write(
            to: root.appendingPathComponent("runtime-manifest.txt"),
            atomically: true,
            encoding: .utf8
        )
    }
}
