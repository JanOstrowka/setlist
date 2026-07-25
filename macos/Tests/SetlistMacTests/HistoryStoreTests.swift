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
