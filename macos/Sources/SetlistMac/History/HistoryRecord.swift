import Foundation
import SwiftData

enum HistoryStatus: String, Codable, Equatable, Sendable {
    case resolving
    case reviewing
    case processing
    case completed
    case failed
    case cancelled
    case interrupted
}

enum HistoryStage: String, Codable, Equatable, Sendable {
    case resolving
    case reviewing
    case submitting
    case queued
    case download
    case encode
    case split
    case tag
    case done
    case error
    case cancelled
    case unknown

    init(_ stage: APIProgressStage) {
        switch stage {
        case .queued:
            self = .queued
        case .download:
            self = .download
        case .encode:
            self = .encode
        case .split:
            self = .split
        case .tag:
            self = .tag
        case .done:
            self = .done
        case .error:
            self = .error
        case .cancelled:
            self = .cancelled
        }
    }
}

@Model
final class HistoryRecord {
    @Attribute(.unique) var id: UUID
    var backendJobID: String?
    var sourceURL: String
    var videoID: String?
    var title: String
    var artist: String
    var artworkData: Data?
    var statusRawValue: String
    var stageRawValue: String?
    var errorSummary: String?
    var metadataJSON: Data?
    var tracklistJSON: Data?
    var outputPaths: [String]
    var createdAt: Date
    var updatedAt: Date
    var completedAt: Date?
    var importedAt: Date?

    var status: HistoryStatus {
        get {
            HistoryStatus(rawValue: statusRawValue) ?? .interrupted
        }
        set {
            statusRawValue = newValue.rawValue
        }
    }

    var stage: HistoryStage? {
        get {
            guard let stageRawValue else {
                return nil
            }
            return HistoryStage(rawValue: stageRawValue) ?? .unknown
        }
        set {
            stageRawValue = newValue?.rawValue
        }
    }

    init(
        id: UUID = UUID(),
        backendJobID: String? = nil,
        sourceURL: String,
        videoID: String? = nil,
        title: String = "",
        artist: String = "",
        artworkData: Data? = nil,
        status: HistoryStatus,
        stage: HistoryStage? = nil,
        errorSummary: String? = nil,
        metadataJSON: Data? = nil,
        tracklistJSON: Data? = nil,
        outputPaths: [String] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        completedAt: Date? = nil,
        importedAt: Date? = nil
    ) {
        self.id = id
        self.backendJobID = backendJobID
        self.sourceURL = sourceURL
        self.videoID = videoID
        self.title = title
        self.artist = artist
        self.artworkData = artworkData
        statusRawValue = status.rawValue
        stageRawValue = stage?.rawValue
        self.errorSummary = errorSummary
        self.metadataJSON = metadataJSON
        self.tracklistJSON = tracklistJSON
        self.outputPaths = outputPaths
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
        self.importedAt = importedAt
    }
}

extension HistoryRecord {
    /// A record with output files is a finished set; a review on top of
    /// it is transient. When such a review is abandoned — a newer set, a
    /// quit — the set goes back to finished instead of "interrupted".
    /// Returns whether it did.
    func restoreCompletedIfFilesRemain() -> Bool {
        guard !outputPaths.isEmpty else {
            return false
        }
        status = .completed
        stage = .done
        errorSummary = nil
        completedAt = completedAt ?? updatedAt
        updatedAt = Date()
        return true
    }
}
