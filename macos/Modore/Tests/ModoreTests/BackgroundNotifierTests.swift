import XCTest
@testable import Modore

final class BackgroundNotifierTests: XCTestCase {
    func testPendingRequestRequiresMessageAcknowledgementPathAndNonce() throws {
        let nonce = UUID().uuidString
        let arguments = [
            "/path/to/Modore",
            "--post-storage-notice", "남은 저장공간이 20GB 아래입니다.",
            "--storage-notice-ack", "/tmp/.storage-watch-ack.example",
            "--storage-notice-nonce", nonce,
        ]

        let request = try XCTUnwrap(BackgroundNotifier.pendingRequest(in: arguments))
        XCTAssertEqual(request.message, "남은 저장공간이 20GB 아래입니다.")
        XCTAssertEqual(request.acknowledgementURL.path, "/tmp/.storage-watch-ack.example")
        XCTAssertEqual(request.nonce, nonce)
    }

    func testPendingRequestRejectsNormalTruncatedAndDuplicateLaunches() {
        let nonce = UUID().uuidString
        XCTAssertNil(BackgroundNotifier.pendingRequest(in: ["/path/to/Modore"]))
        XCTAssertNil(BackgroundNotifier.pendingRequest(in: [
            "/path/to/Modore", "--post-storage-notice", "message",
        ]))
        XCTAssertNil(BackgroundNotifier.pendingRequest(in: [
            "/path/to/Modore",
            "--post-storage-notice", "first",
            "--post-storage-notice", "second",
            "--storage-notice-ack", "/tmp/.storage-watch-ack.example",
            "--storage-notice-nonce", nonce,
        ]))
        XCTAssertNil(BackgroundNotifier.pendingRequest(in: [
            "/path/to/Modore",
            "--post-storage-notice", "message",
            "--storage-notice-ack", "/tmp/.storage-watch-ack.example",
            "--storage-notice-nonce", "not-a-nonce",
        ]))
    }

    func testAcknowledgementIsAtomicOwnerOnlyAndRequiresNoNotificationError() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("modore-notification-ack-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let acknowledgementURL = directory.appendingPathComponent(
            ".storage-watch-ack.accepted"
        )
        let request = BackgroundNotificationRequest(
            message: "message",
            acknowledgementURL: acknowledgementURL,
            nonce: UUID().uuidString
        )

        XCTAssertFalse(BackgroundNotifier.acknowledgeAcceptedRequest(
            request,
            error: NSError(domain: "test", code: 1),
            stateDirectory: directory
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: acknowledgementURL.path))

        XCTAssertTrue(BackgroundNotifier.acknowledgeAcceptedRequest(
            request,
            error: nil,
            stateDirectory: directory
        ))
        XCTAssertEqual(try String(contentsOf: acknowledgementURL), request.nonce)
        let attributes = try FileManager.default.attributesOfItem(atPath: acknowledgementURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testAcknowledgementCannotEscapeThePrivateStateDirectory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("modore-notification-ack-root-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let outside = directory.deletingLastPathComponent()
            .appendingPathComponent(".storage-watch-ack.outside-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outside) }
        let request = BackgroundNotificationRequest(
            message: "message",
            acknowledgementURL: outside,
            nonce: UUID().uuidString
        )

        XCTAssertFalse(BackgroundNotifier.acknowledgeAcceptedRequest(
            request,
            error: nil,
            stateDirectory: directory
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.path))
    }
}
