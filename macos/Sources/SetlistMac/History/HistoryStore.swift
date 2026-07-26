import Foundation
import Observation
import SwiftData

@MainActor
protocol HistoryStoreProtocol: AnyObject {
    var records: [HistoryRecord] { get }

    func insert(_ record: HistoryRecord) throws
    func promote(_ record: HistoryRecord)
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
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        records = try modelContext.fetch(descriptor)
        try collapseDuplicateSets()
    }

    /// Removes duplicate Recent entries left over for the same video,
    /// keeping the most recent one. Completed sets that point at real
    /// files are never removed.
    private func collapseDuplicateSets() throws {
        var seenKeys = Set<String>()
        var duplicates: [UUID] = []

        for record in records {
            let key = dedupeKey(for: record)
            if seenKeys.contains(key) {
                let holdsFiles = record.status == .completed
                    || !record.outputPaths.isEmpty
                if !holdsFiles {
                    duplicates.append(record.id)
                    modelContext.delete(record)
                }
            } else {
                seenKeys.insert(key)
            }
        }

        guard !duplicates.isEmpty else {
            return
        }
        let removed = Set(duplicates)
        records.removeAll { removed.contains($0.id) }
        try modelContext.save()
    }

    private func dedupeKey(for record: HistoryRecord) -> String {
        if let videoID = record.videoID, !videoID.isEmpty {
            return videoID
        }
        return YouTubeURLValidator.videoID(from: record.sourceURL)
            ?? record.sourceURL
    }

    func insert(_ record: HistoryRecord) throws {
        modelContext.insert(record)
        records.insert(record, at: 0)
    }

    /// Moves a record to the top of Recent, used when an existing set is
    /// resolved again instead of duplicating it.
    func promote(_ record: HistoryRecord) {
        guard let index = records.firstIndex(where: { $0.id == record.id }),
              index != 0 else {
            return
        }
        records.remove(at: index)
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
