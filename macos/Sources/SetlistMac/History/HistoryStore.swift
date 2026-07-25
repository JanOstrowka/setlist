import Foundation
import Observation
import SwiftData

@MainActor
protocol HistoryStoreProtocol: AnyObject {
    var records: [HistoryRecord] { get }

    func insert(_ record: HistoryRecord) throws
    func save() throws
    func markActiveJobsInterrupted() throws
}

@MainActor
@Observable
final class HistoryStore: HistoryStoreProtocol {
    private let modelContext: ModelContext
    private(set) var records: [HistoryRecord]

    init(modelContext: ModelContext) throws {
        self.modelContext = modelContext
        let descriptor = FetchDescriptor<HistoryRecord>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        records = try modelContext.fetch(descriptor)
    }

    func insert(_ record: HistoryRecord) throws {
        modelContext.insert(record)
        records.insert(record, at: 0)
    }

    func save() throws {
        try modelContext.save()
    }

    func markActiveJobsInterrupted() throws {
        let interruptedAt = Date()
        var changed = false

        for record in records where record.status == .resolving || record.status == .processing {
            record.status = .interrupted
            record.errorSummary = "Interrupted when the app last stopped."
            record.updatedAt = interruptedAt
            record.completedAt = interruptedAt
            changed = true
        }

        if changed {
            try save()
        }
    }
}
