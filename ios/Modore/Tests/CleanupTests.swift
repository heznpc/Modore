import XCTest
import Photos
@testable import Modore

private actor CleanupPhotoStub: PhotoCleanupServicing {
    private var items: [CleanupMediaItem]
    private let fails: Bool
    private(set) var deletedSelections: [[CleanupMediaItem]] = []

    init(items: [CleanupMediaItem], fails: Bool = false) {
        self.items = items
        self.fails = fails
    }
    func load(filter: CleanupMediaFilter) async throws -> [CleanupMediaItem] { items }
    func delete(_ selection: [CleanupMediaItem]) async throws {
        deletedSelections.append(selection)
        if fails { throw CleanupError.accessDenied }
        items.removeAll { item in selection.contains { $0.id == item.id } }
    }
}

final class CleanupTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testPhotoSelectionRejectsMissingModifiedAndUndeletableAssets() {
        let original = CleanupMediaItem(id: "chosen", modifiedAt: Date(timeIntervalSince1970: 1))
        XCTAssertTrue(PhotoCleanupService.selectionIsCurrent([original], current: [original]))
        XCTAssertFalse(PhotoCleanupService.selectionIsCurrent([original], current: []))
        XCTAssertFalse(PhotoCleanupService.selectionIsCurrent([], current: []))
        XCTAssertFalse(PhotoCleanupService.selectionIsCurrent([original, original], current: [original, original]))
        XCTAssertFalse(PhotoCleanupService.selectionIsCurrent([original], current: [
            CleanupMediaItem(id: "chosen", modifiedAt: Date(timeIntervalSince1970: 2))
        ]))
        let locked = CleanupMediaItem(id: "locked", canDelete: false)
        XCTAssertFalse(PhotoCleanupService.selectionIsCurrent([locked], current: [locked]))
        XCTAssertFalse(PhotoCleanupService.selectionIsCurrent([original], current: [CleanupMediaItem(id: "different")]))
    }

    @MainActor
    func testReviewDoesNotDeleteAndOnlyConfirmedSelectionIsRemoved() async throws {
        let a = CleanupMediaItem(id: "selected")
        let b = CleanupMediaItem(id: "retained")
        let service = CleanupPhotoStub(items: [a, b])
        let model = PhotoCleanupModel(service: service, capacity: { DeviceStorageSnapshot(totalBytes: 100, availableBytes: 30) })
        let journal = CleanupHistory(url: try temporaryDirectory().appendingPathComponent("history.json"))
        await model.load(filter: .videos)
        XCTAssertNil(model.plan())
        model.toggle(a)
        let plan = try XCTUnwrap(model.plan())
        let before = await service.deletedSelections
        XCTAssertTrue(before.isEmpty)
        XCTAssertTrue(journal.receipts.isEmpty)

        await model.delete(plan, history: journal, filter: .videos)

        let deletions = await service.deletedSelections
        XCTAssertEqual(deletions, [[a]])
        XCTAssertEqual(model.items, [b])
        XCTAssertTrue(model.selection.isEmpty)
        XCTAssertEqual(journal.receipts.first?.deletedCount, 1)
        XCTAssertEqual(journal.receipts.first?.availableChange, 0)
        XCTAssertEqual(journal.receipts.first?.status, .completed)
    }

    @MainActor
    func testRevokedAccessProducesFailedReceiptWithoutClaimingDeletedItems() async throws {
        let item = CleanupMediaItem(id: "selected")
        let model = PhotoCleanupModel(service: CleanupPhotoStub(items: [item], fails: true))
        let journal = CleanupHistory(url: try temporaryDirectory().appendingPathComponent("history.json"))
        await model.load(filter: .videos)
        model.toggle(item)
        await model.delete(try XCTUnwrap(model.plan()), history: journal, filter: .videos)
        XCTAssertEqual(journal.receipts.first?.deletedCount, 0)
        XCTAssertEqual(journal.receipts.first?.status, .failed)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.items, [item])
    }

    @MainActor
    func testStaleConfirmationCannotDeleteAfterSelectionChanges() async throws {
        let item = CleanupMediaItem(id: "selected")
        let service = CleanupPhotoStub(items: [item])
        let model = PhotoCleanupModel(service: service)
        let journal = CleanupHistory(url: try temporaryDirectory().appendingPathComponent("history.json"))
        await model.load(filter: .videos)
        model.toggle(item)
        let plan = try XCTUnwrap(model.plan())
        model.toggle(item)
        await model.delete(plan, history: journal, filter: .videos)
        let deleted = await service.deletedSelections
        XCTAssertTrue(deleted.isEmpty)
        XCTAssertTrue(journal.receipts.isEmpty)
    }

    @MainActor
    func testUnwritableReceiptPreventsPhotoDeletion() async throws {
        let folder = try temporaryDirectory()
        let blocker = folder.appendingPathComponent("not-a-directory")
        try Data([1]).write(to: blocker)
        let item = CleanupMediaItem(id: "selected")
        let service = CleanupPhotoStub(items: [item])
        let model = PhotoCleanupModel(service: service)
        let journal = CleanupHistory(url: blocker.appendingPathComponent("history.json"))
        await model.load(filter: .videos)
        model.toggle(item)
        await model.delete(try XCTUnwrap(model.plan()), history: journal, filter: .videos)
        let deleted = await service.deletedSelections
        XCTAssertTrue(deleted.isEmpty)
        XCTAssertNotNil(model.errorMessage)
    }

    @MainActor
    func testReceiptsSurviveRestartAndPreserveNegativeOrUnknownCapacityChange() throws {
        let url = try temporaryDirectory().appendingPathComponent("history.json")
        let journal = CleanupHistory(url: url)
        let id = try journal.begin(kind: .media, count: 2, beforeBytes: 100)
        XCTAssertEqual(CleanupHistory(url: url).receipts.first?.status, .inProgress)
        journal.finish(id: id, deletedCount: 2, status: .completed, afterBytes: 90)
        let reloaded = CleanupHistory(url: url)
        XCTAssertEqual(reloaded.receipts.first?.availableChange, -10)
        XCTAssertEqual(reloaded.receipts.first?.status, .completed)
        _ = try journal.begin(kind: .files, count: 1, beforeBytes: nil)
        XCTAssertNil(journal.receipts.first?.availableChange)
        let json = try String(contentsOf: url)
        XCTAssertFalse(json.contains("selected"))
    }

    func testFileDeletionOnlyRemovesChosenFilesAndRejectsReplay() async throws {
        let folder = try temporaryDirectory()
        let chosen = folder.appendingPathComponent("chosen.txt")
        let retained = folder.appendingPathComponent("retained.txt")
        try Data([1, 2, 3]).write(to: chosen)
        try Data([4]).write(to: retained)
        let service = FileCleanupService()
        let preview = await service.preview([chosen, retained, chosen])
        XCTAssertEqual(preview.items.count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: chosen.path))
        let item = try XCTUnwrap(preview.items.first { $0.name == "chosen.txt" })
        let outcome = await service.delete(ids: [item.id])
        XCTAssertNil(outcome.errorMessage)
        XCTAssertEqual(outcome.deletedCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: chosen.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: retained.path))
        let replay = await service.delete(ids: [item.id])
        XCTAssertEqual(replay.deletedCount, 0)
        XCTAssertNotNil(replay.errorMessage)
        await service.release()
    }

    func testChangedFilePreventsDeletionOfTheWholePlan() async throws {
        let folder = try temporaryDirectory()
        let first = folder.appendingPathComponent("first.txt")
        let second = folder.appendingPathComponent("second.txt")
        try Data([1]).write(to: first)
        try Data([2]).write(to: second)
        let service = FileCleanupService()
        let preview = await service.preview([first, second])
        try Data([3, 4, 5]).write(to: second)
        let outcome = await service.delete(ids: preview.items.map(\.id))
        XCTAssertEqual(outcome.deletedCount, 0)
        XCTAssertNotNil(outcome.errorMessage)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
        await service.release()
    }

    func testDirectoriesAndSymlinksCannotBeDeletedAsFiles() async throws {
        let folder = try temporaryDirectory()
        let target = folder.appendingPathComponent("keep.txt")
        let link = folder.appendingPathComponent("link.txt")
        try Data([1]).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let service = FileCleanupService()
        let preview = await service.preview([folder, link])
        XCTAssertTrue(preview.items.isEmpty)
        XCTAssertEqual(preview.rejectedCount, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        await service.release()
    }

    func testReplacedFileCannotBeDeletedUsingOldPreview() async throws {
        let folder = try temporaryDirectory()
        let file = folder.appendingPathComponent("replace.txt")
        try Data([1]).write(to: file)
        let service = FileCleanupService()
        let preview = await service.preview([file])
        try Data([2]).write(to: file, options: .atomic)
        let outcome = await service.delete(ids: preview.items.map(\.id))
        XCTAssertEqual(outcome.deletedCount, 0)
        XCTAssertEqual(try Data(contentsOf: file), Data([2]))
        await service.release()
    }
}
