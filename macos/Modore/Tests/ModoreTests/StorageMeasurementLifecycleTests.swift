import Foundation
import XCTest
@testable import Modore

private actor StorageMeasurementGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var entered = false

    func wait() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func hasEntered() -> Bool { entered }
    func release() { continuation?.resume(); continuation = nil }
}

@MainActor
final class StorageMeasurementLifecycleTests: XCTestCase {
    private func readyModel() async -> ScanModel {
        let model = ScanModel(automaticallyScansStaleResults: false)
        for task in model.cancelTrackedApplicationTasks() { await task.value }
        return model
    }

    func testLeavingStorageCancelsAndKeepsSharedBusyUntilDrainCompletes() async throws {
        let model = await readyModel()
        let gate = StorageMeasurementGate()
        var published = false
        XCTAssertTrue(model.startStorageMeasurement {
            await gate.wait()
            if !Task.isCancelled { published = true }
        })
        let task = try XCTUnwrap(model.trackedApplicationTasks.values.first { $0.scope == .storageScreen }?.task)
        for _ in 0..<100 {
            if await gate.hasEntered() { break }
            await Task.yield()
        }
        let entered = await gate.hasEntered()
        XCTAssertTrue(entered)
        XCTAssertTrue(model.isBusy)
        XCTAssertFalse(model.startStorageMeasurement {})

        model.cancelStorageScreenTasks()
        XCTAssertTrue(task.isCancelled)
        XCTAssertTrue(model.storageMeasurementInFlight, "Keep the slot until subprocess cleanup has completed")
        model.runScan()
        XCTAssertFalse(model.isRunning)
        XCTAssertFalse(model.startStorageMeasurement {})
        XCTAssertFalse(model.pendingDrainTasks.isEmpty)

        await gate.release()
        await task.value
        XCTAssertFalse(published, "A cancelled read must not replace the page's data")
        XCTAssertFalse(model.storageMeasurementInFlight)
        XCTAssertFalse(model.isBusy)
    }

    func testCompletedMeasurementReleasesSlotAndTerminationPreventsNewReads() async throws {
        let model = await readyModel()
        var completed = false
        XCTAssertTrue(model.startStorageMeasurement { completed = true })
        let task = try XCTUnwrap(model.trackedApplicationTasks.values.first { $0.scope == .storageScreen }?.task)
        await task.value
        XCTAssertTrue(completed)
        XCTAssertFalse(model.storageMeasurementInFlight)
        XCTAssertFalse(model.isBusy)

        model.applicationTerminationStarted = true
        XCTAssertFalse(model.startStorageMeasurement { XCTFail("Must not start after termination") })
        XCTAssertFalse(model.storageMeasurementInFlight)
    }
}
