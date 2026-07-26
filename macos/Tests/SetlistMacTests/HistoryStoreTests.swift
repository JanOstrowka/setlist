import Foundation
import SwiftData
import XCTest
@testable import SetlistMac

@MainActor
final class HistoryStoreTests: XCTestCase {
    func testRecordPersistsWorkflowSnapshotsAndPaths() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let store = try HistoryStore(modelContext: context)
        let id = UUID()
        let createdAt = Date(timeIntervalSince1970: 100)
        let metadata = try APIJSON.encoder.encode(APIMetadataFields(title: "Live Set", artist: "DJ"))
        let tracklist = try APIJSON.encoder.encode(
            APITracklist(source: .manual, tracks: [.init(start: 0, title: "Intro")])
        )
        let record = HistoryRecord(
            id: id,
            backendJobID: "job-7",
            sourceURL: "https://youtu.be/abcdefghijk",
            videoID: "abcdefghijk",
            title: "Live Set",
            artist: "DJ",
            artworkData: Data([1, 2, 3]),
            status: .completed,
            stage: .done,
            metadataJSON: metadata,
            tracklistJSON: tracklist,
            outputPaths: ["/tmp/live-set.m4a"],
            createdAt: createdAt,
            updatedAt: createdAt,
            completedAt: createdAt,
            importedAt: createdAt
        )

        try store.insert(record)
        try store.save()

        let reloaded = try HistoryStore(modelContext: ModelContext(container))
        let persisted = try XCTUnwrap(reloaded.records.first)
        XCTAssertEqual(persisted.id, id)
        XCTAssertEqual(persisted.backendJobID, "job-7")
        XCTAssertEqual(persisted.metadataJSON, metadata)
        XCTAssertEqual(persisted.tracklistJSON, tracklist)
        XCTAssertEqual(persisted.outputPaths, ["/tmp/live-set.m4a"])
        XCTAssertEqual(persisted.status, .completed)
        XCTAssertEqual(persisted.stage, .done)
        XCTAssertEqual(persisted.createdAt, createdAt)
        XCTAssertEqual(persisted.completedAt, createdAt)
        XCTAssertEqual(persisted.importedAt, createdAt)
    }

    func testUnknownPersistedEnumValuesFallBackSafely() {
        let record = HistoryRecord(
            sourceURL: "https://youtu.be/abcdefghijk",
            status: .reviewing
        )

        record.statusRawValue = "future-status"
        record.stageRawValue = "future-stage"

        XCTAssertEqual(record.status, .interrupted)
        XCTAssertEqual(record.stage, .unknown)
    }

    func testMarkActiveJobsInterruptedOnlyChangesActiveRecords() throws {
        let store = try makeStore()
        let resolving = HistoryRecord(sourceURL: "one", status: .resolving)
        let processing = HistoryRecord(sourceURL: "two", status: .processing)
        let reviewing = HistoryRecord(sourceURL: "three", status: .reviewing)
        try store.insert(resolving)
        try store.insert(processing)
        try store.insert(reviewing)
        try store.save()

        try store.markActiveJobsInterrupted()

        XCTAssertEqual(resolving.status, .interrupted)
        XCTAssertEqual(processing.status, .interrupted)
        XCTAssertEqual(reviewing.status, .reviewing)
        XCTAssertNotNil(resolving.errorSummary)
        XCTAssertNotNil(processing.errorSummary)
    }

    func testPromoteMovesRecordToTopOfRecent() throws {
        let store = try makeStore()
        let older = HistoryRecord(sourceURL: "one", status: .reviewing)
        let newer = HistoryRecord(sourceURL: "two", status: .reviewing)
        try store.insert(older)
        try store.insert(newer)

        store.promote(older)

        XCTAssertEqual(store.records.map(\.sourceURL), ["one", "two"])
    }

    func testLaunchCollapsesLeftoverDuplicatesKeepingNewestAndCompleted() throws {
        let container = try makeContainer()
        let seed = try HistoryStore(modelContext: ModelContext(container))
        let url = "https://www.youtube.com/watch?v=S1L8cNyfXT4"
        let completed = HistoryRecord(
            sourceURL: url,
            videoID: "S1L8cNyfXT4",
            status: .completed,
            outputPaths: ["/tmp/set.m4a"],
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let interruptedOld = HistoryRecord(
            sourceURL: url + "&t=843s",
            status: .interrupted,
            updatedAt: Date(timeIntervalSince1970: 200)
        )
        let reviewingNewest = HistoryRecord(
            sourceURL: url,
            videoID: "S1L8cNyfXT4",
            status: .reviewing,
            updatedAt: Date(timeIntervalSince1970: 300)
        )
        let unrelated = HistoryRecord(
            sourceURL: "https://youtu.be/bbbbbbbbbbb",
            status: .reviewing,
            updatedAt: Date(timeIntervalSince1970: 250)
        )
        for record in [completed, interruptedOld, reviewingNewest, unrelated] {
            try seed.insert(record)
        }
        try seed.save()

        let store = try HistoryStore(modelContext: ModelContext(container))

        // Newest duplicate survives, the interrupted copy is dropped, and
        // the completed set keeps its files.
        XCTAssertEqual(
            store.records.map(\.id),
            [reviewingNewest.id, unrelated.id, completed.id]
        )
    }

    private func makeStore() throws -> HistoryStore {
        try HistoryStore(modelContext: ModelContext(makeContainer()))
    }

    private func makeContainer() throws -> ModelContainer {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: HistoryRecord.self,
            configurations: configuration
        )
    }
}
