import Foundation

struct ResolvePhase: Equatable, Sendable {
    let recordID: UUID
    let sourceURL: String
}

struct SetDraft: Equatable, Sendable {
    let historyID: UUID
    var sourceURL: String
    var videoID: String
    var duration: Int
    var metadata: APIMetadataFields
    var cover: String
    var formats: String
    var detectedLine: String
    var hasChapters: Bool
    var tracklist: APITracklist
    var format: APIAudioFormat
    var split: Bool

    init(
        historyID: UUID,
        sourceURL: String,
        response: APIResolveResponse,
        format: APIAudioFormat = .alac,
        split: Bool? = nil
    ) {
        self.historyID = historyID
        self.sourceURL = sourceURL
        videoID = response.videoID
        duration = response.duration
        metadata = response.metadata
        cover = response.cover
        formats = response.formats
        detectedLine = response.detectedLine
        hasChapters = response.hasChapters
        tracklist = response.tracklist ?? APITracklist()
        self.format = format
        self.split = split ?? !(response.tracklist?.tracks.isEmpty ?? true)
    }
}

struct ProcessingState: Equatable, Sendable {
    let recordID: UUID
    let backendJobID: String?
    let stage: HistoryStage
    let percent: Double
    let message: String
    let frozenDraft: SetDraft
}

struct CompletedJob: Equatable, Sendable {
    let recordID: UUID
    let backendJobID: String
    let outputPaths: [String]
    let completedAt: Date
}

struct FailedJob: Equatable, Sendable {
    let recordID: UUID?
    let backendJobID: String?
    let message: String
    let failedAt: Date
}

enum WorkflowState: Equatable, Sendable {
    case idle
    case resolving(ResolvePhase)
    case reviewing(SetDraft)
    case processing(ProcessingState)
    case completed(CompletedJob)
    case failed(FailedJob)
}
