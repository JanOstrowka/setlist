import Foundation
import Observation

@MainActor
@Observable
final class WorkflowController {
    private(set) var state: WorkflowState = .idle

    @ObservationIgnored private let api: any SetlistAPIProtocol
    @ObservationIgnored private let history: any HistoryStoreProtocol
    @ObservationIgnored private var resolveTask: Task<Void, Never>?
    @ObservationIgnored private var tracklistTask: Task<Void, Never>?
    @ObservationIgnored private var progressTask: Task<Void, Never>?
    @ObservationIgnored private var resolveToken: UUID?
    @ObservationIgnored private var tracklistToken: UUID?
    @ObservationIgnored private var progressToken: UUID?
    @ObservationIgnored private var draftRevision = 0

    init(api: any SetlistAPIProtocol, history: any HistoryStoreProtocol) {
        self.api = api
        self.history = history

        do {
            try history.markActiveJobsInterrupted()
        } catch {
            state = .failed(
                FailedJob(
                    recordID: nil,
                    backendJobID: nil,
                    message: "Could not restore history: \(Self.describe(error))",
                    failedAt: Date()
                )
            )
        }
    }

    func resolve(_ sourceURL: String) async {
        do {
            try cancelActiveWorkForNewResolve()
        } catch {
            state = .failed(
                FailedJob(
                    recordID: activeRecordID,
                    backendJobID: activeBackendJobID,
                    message: "Could not update history: \(Self.describe(error))",
                    failedAt: Date()
                )
            )
            return
        }

        let record = HistoryRecord(
            sourceURL: sourceURL,
            status: .resolving,
            stage: .resolving
        )

        do {
            try history.insert(record)
            try history.save()
        } catch {
            state = .failed(
                FailedJob(
                    recordID: record.id,
                    backendJobID: nil,
                    message: "Could not persist resolve: \(Self.describe(error))",
                    failedAt: Date()
                )
            )
            return
        }

        state = .resolving(
            ResolvePhase(recordID: record.id, sourceURL: sourceURL)
        )
        let token = UUID()
        resolveToken = token
        let api = api

        let task = Task { [weak self] in
            do {
                let response = try await api.resolve(url: sourceURL)
                try Task.checkCancellation()
                guard let self, self.resolveToken == token else {
                    return
                }
                try self.finishResolve(
                    response,
                    sourceURL: sourceURL,
                    recordID: record.id
                )
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.resolveToken == token else {
                    return
                }
                self.fail(
                    recordID: record.id,
                    backendJobID: nil,
                    error: error
                )
            }
        }

        resolveTask = task
        await task.value
        if resolveToken == token {
            resolveTask = nil
            resolveToken = nil
        }
    }

    func replaceDraft(_ draft: SetDraft) {
        guard case .reviewing(let current) = state,
              current.historyID == draft.historyID else {
            return
        }

        tracklistToken = nil
        tracklistTask?.cancel()
        tracklistTask = nil
        draftRevision += 1
        state = .reviewing(draft)

        do {
            try persist(draft: draft)
        } catch {
            fail(
                recordID: draft.historyID,
                backendJobID: nil,
                error: error
            )
        }
    }

    func autoTracklist(query: String) async {
        guard case .reviewing(let draft) = state else {
            return
        }
        await runTracklistLookup(
            draft: draft,
            operation: { [api] in
                try await api.autoTracklist(
                    query: query,
                    url: draft.sourceURL,
                    duration: draft.duration
                )
            }
        )
    }

    func parseTracklist(_ text: String) async {
        guard case .reviewing(let draft) = state else {
            return
        }
        await runTracklistLookup(
            draft: draft,
            operation: { [api] in
                try await api.parseTracklist(
                    text: text,
                    duration: draft.duration
                )
            }
        )
    }

    func process() async {
        guard case .reviewing(let draft) = state else {
            return
        }

        tracklistToken = nil
        tracklistTask?.cancel()
        tracklistTask = nil
        draftRevision += 1

        let frozenDraft = draft
        let token = UUID()
        progressToken = token

        do {
            try persistProcessingStart(frozenDraft)
        } catch {
            fail(
                recordID: frozenDraft.historyID,
                backendJobID: nil,
                error: error
            )
            return
        }

        state = .processing(
            ProcessingState(
                recordID: frozenDraft.historyID,
                backendJobID: nil,
                stage: .submitting,
                percent: 0,
                message: "Submitting",
                frozenDraft: frozenDraft
            )
        )

        let api = api
        let task = Task { [weak self] in
            do {
                let jobID: String
                if frozenDraft.split && !frozenDraft.tracklist.tracks.isEmpty {
                    jobID = try await api.submitSplit(
                        APISplitDownloadRequest(
                            videoID: frozenDraft.videoID,
                            url: frozenDraft.sourceURL,
                            metadata: frozenDraft.metadata,
                            tracks: frozenDraft.tracklist.tracks,
                            format: frozenDraft.format,
                            cover: frozenDraft.cover
                        )
                    )
                } else {
                    jobID = try await api.submit(
                        APIDownloadRequest(
                            videoID: frozenDraft.videoID,
                            url: frozenDraft.sourceURL,
                            metadata: frozenDraft.metadata,
                            format: frozenDraft.format,
                            cover: frozenDraft.cover
                        )
                    )
                }

                try Task.checkCancellation()
                guard let self, self.progressToken == token else {
                    return
                }
                try self.persistSubmittedJob(
                    jobID,
                    frozenDraft: frozenDraft
                )

                do {
                    for try await event in api.progress(jobID: jobID) {
                        try Task.checkCancellation()
                        guard self.progressToken == token else {
                            return
                        }
                        try self.apply(
                            event,
                            jobID: jobID,
                            frozenDraft: frozenDraft
                        )
                    }
                    try Task.checkCancellation()
                    guard self.progressToken == token else {
                        return
                    }
                    await self.reconcile(
                        jobID: jobID,
                        frozenDraft: frozenDraft,
                        token: token,
                        streamError: nil
                    )
                } catch is CancellationError {
                    return
                } catch {
                    guard self.progressToken == token else {
                        return
                    }
                    await self.reconcile(
                        jobID: jobID,
                        frozenDraft: frozenDraft,
                        token: token,
                        streamError: error
                    )
                }
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.progressToken == token else {
                    return
                }
                self.fail(
                    recordID: frozenDraft.historyID,
                    backendJobID: nil,
                    error: error
                )
            }
        }

        progressTask = task
        await task.value
        if progressToken == token {
            progressTask = nil
            progressToken = nil
        }
    }

    private func runTracklistLookup(
        draft: SetDraft,
        operation: @escaping @Sendable () async throws -> APITracklist
    ) async {
        tracklistTask?.cancel()
        let token = UUID()
        let revision = draftRevision
        tracklistToken = token

        let task = Task { [weak self] in
            do {
                let tracklist = try await operation()
                try Task.checkCancellation()
                guard let self,
                      self.tracklistToken == token,
                      self.draftRevision == revision,
                      case .reviewing(var current) = self.state,
                      current.historyID == draft.historyID else {
                    return
                }

                current.tracklist = tracklist
                self.draftRevision += 1
                self.state = .reviewing(current)
                try self.persist(draft: current)
            } catch is CancellationError {
                return
            } catch {
                guard let self,
                      self.tracklistToken == token,
                      case .reviewing(let current) = self.state,
                      current.historyID == draft.historyID else {
                    return
                }
                self.persistNonterminalError(
                    recordID: draft.historyID,
                    error: error
                )
            }
        }

        tracklistTask = task
        await task.value
        if tracklistToken == token {
            tracklistTask = nil
            tracklistToken = nil
        }
    }

    private func finishResolve(
        _ response: APIResolveResponse,
        sourceURL: String,
        recordID: UUID
    ) throws {
        let draft = SetDraft(
            historyID: recordID,
            sourceURL: sourceURL,
            response: response
        )
        try persist(draft: draft)
        draftRevision += 1
        state = .reviewing(draft)
    }

    private func persist(draft: SetDraft) throws {
        guard let record = record(id: draft.historyID) else {
            throw WorkflowPersistenceError.missingRecord(draft.historyID)
        }
        record.videoID = draft.videoID
        record.title = draft.metadata.title
        record.artist = draft.metadata.artist
        record.status = .reviewing
        record.stage = .reviewing
        record.errorSummary = nil
        record.metadataJSON = try APIJSON.encoder.encode(draft.metadata)
        record.tracklistJSON = try APIJSON.encoder.encode(draft.tracklist)
        record.updatedAt = Date()
        try history.save()
    }

    private func persistProcessingStart(_ draft: SetDraft) throws {
        guard let record = record(id: draft.historyID) else {
            throw WorkflowPersistenceError.missingRecord(draft.historyID)
        }
        record.videoID = draft.videoID
        record.title = draft.metadata.title
        record.artist = draft.metadata.artist
        record.status = .processing
        record.stage = .submitting
        record.errorSummary = nil
        record.metadataJSON = try APIJSON.encoder.encode(draft.metadata)
        record.tracklistJSON = try APIJSON.encoder.encode(draft.tracklist)
        record.updatedAt = Date()
        try history.save()
    }

    private func persistSubmittedJob(
        _ jobID: String,
        frozenDraft: SetDraft
    ) throws {
        guard let record = record(id: frozenDraft.historyID) else {
            throw WorkflowPersistenceError.missingRecord(frozenDraft.historyID)
        }
        record.backendJobID = jobID
        record.status = .processing
        record.stage = .queued
        record.updatedAt = Date()
        try history.save()
        state = .processing(
            ProcessingState(
                recordID: frozenDraft.historyID,
                backendJobID: jobID,
                stage: .queued,
                percent: 0,
                message: "Queued",
                frozenDraft: frozenDraft
            )
        )
    }

    private func apply(
        _ event: APIProgressEvent,
        jobID: String,
        frozenDraft: SetDraft
    ) throws {
        let stage = HistoryStage(event.stage)
        guard let record = record(id: frozenDraft.historyID) else {
            throw WorkflowPersistenceError.missingRecord(frozenDraft.historyID)
        }
        record.status = .processing
        record.stage = stage
        record.updatedAt = Date()
        if let filePath = event.filePath,
           !record.outputPaths.contains(filePath) {
            record.outputPaths.append(filePath)
        }
        try history.save()
        state = .processing(
            ProcessingState(
                recordID: frozenDraft.historyID,
                backendJobID: jobID,
                stage: stage,
                percent: event.overallPercent ?? event.stagePercent,
                message: event.message,
                frozenDraft: frozenDraft
            )
        )
    }

    private func reconcile(
        jobID: String,
        frozenDraft: SetDraft,
        token: UUID,
        streamError: (any Error)?
    ) async {
        do {
            let snapshot = try await api.job(jobID: jobID)
            try Task.checkCancellation()
            guard progressToken == token else {
                return
            }
            try apply(
                snapshot: snapshot,
                frozenDraft: frozenDraft,
                streamError: streamError
            )
        } catch is CancellationError {
            return
        } catch {
            guard progressToken == token else {
                return
            }
            fail(
                recordID: frozenDraft.historyID,
                backendJobID: jobID,
                error: streamError ?? error
            )
        }
    }

    private func apply(
        snapshot: APIJobSnapshot,
        frozenDraft: SetDraft,
        streamError: (any Error)?
    ) throws {
        let stage = HistoryStage(snapshot.latest.stage)
        guard let record = record(id: frozenDraft.historyID) else {
            throw WorkflowPersistenceError.missingRecord(frozenDraft.historyID)
        }

        record.backendJobID = snapshot.jobID
        record.stage = stage
        for outputPath in snapshot.outputPaths
        where !record.outputPaths.contains(outputPath) {
            record.outputPaths.append(outputPath)
        }
        record.updatedAt = Date()

        switch snapshot.status {
        case .completed:
            let completedAt = Date()
            record.status = .completed
            record.stage = .done
            record.errorSummary = nil
            record.completedAt = completedAt
            try history.save()
            state = .completed(
                CompletedJob(
                    recordID: frozenDraft.historyID,
                    backendJobID: snapshot.jobID,
                    outputPaths: record.outputPaths,
                    completedAt: completedAt
                )
            )
        case .failed:
            try persistTerminalFailure(
                record: record,
                status: .failed,
                message: snapshot.error.isEmpty ? snapshot.latest.message : snapshot.error
            )
        case .cancelled:
            try persistTerminalFailure(
                record: record,
                status: .cancelled,
                message: snapshot.error.isEmpty ? "Cancelled" : snapshot.error
            )
        case .interrupted:
            try persistTerminalFailure(
                record: record,
                status: .interrupted,
                message: snapshot.error.isEmpty ? "Interrupted" : snapshot.error
            )
        case .queued, .processing, .cancelling:
            let error = streamError.map(Self.describe)
                ?? "Progress stream ended before the job completed."
            try persistTerminalFailure(
                record: record,
                status: .failed,
                message: error
            )
        }
    }

    private func persistTerminalFailure(
        record: HistoryRecord,
        status: HistoryStatus,
        message: String
    ) throws {
        let failedAt = Date()
        record.status = status
        record.errorSummary = message
        record.completedAt = failedAt
        record.updatedAt = failedAt
        try history.save()
        state = .failed(
            FailedJob(
                recordID: record.id,
                backendJobID: record.backendJobID,
                message: message,
                failedAt: failedAt
            )
        )
    }

    private func persistNonterminalError(
        recordID: UUID,
        error: any Error
    ) {
        guard let record = record(id: recordID) else {
            return
        }
        record.errorSummary = Self.describe(error)
        record.updatedAt = Date()
        do {
            try history.save()
        } catch {
            fail(recordID: recordID, backendJobID: nil, error: error)
        }
    }

    private func fail(
        recordID: UUID?,
        backendJobID: String?,
        error: any Error
    ) {
        let failedAt = Date()
        let message = Self.describe(error)
        if let recordID, let record = record(id: recordID) {
            record.status = .failed
            record.stage = .error
            record.errorSummary = message
            record.completedAt = failedAt
            record.updatedAt = failedAt
            try? history.save()
        }
        state = .failed(
            FailedJob(
                recordID: recordID,
                backendJobID: backendJobID,
                message: message,
                failedAt: failedAt
            )
        )
    }

    private func cancelActiveWorkForNewResolve() throws {
        let interruptedID = activeRecordID

        resolveToken = nil
        tracklistToken = nil
        progressToken = nil
        resolveTask?.cancel()
        tracklistTask?.cancel()
        progressTask?.cancel()
        resolveTask = nil
        tracklistTask = nil
        progressTask = nil

        guard let interruptedID,
              let record = record(id: interruptedID),
              record.status == .resolving || record.status == .processing else {
            return
        }
        let interruptedAt = Date()
        record.status = .interrupted
        record.errorSummary = "Interrupted by a newer workflow."
        record.completedAt = interruptedAt
        record.updatedAt = interruptedAt
        try history.save()
    }

    private var activeRecordID: UUID? {
        switch state {
        case .resolving(let phase):
            phase.recordID
        case .reviewing(let draft):
            draft.historyID
        case .processing(let processing):
            processing.recordID
        case .completed(let completed):
            completed.recordID
        case .failed(let failed):
            failed.recordID
        case .idle:
            nil
        }
    }

    private var activeBackendJobID: String? {
        switch state {
        case .processing(let processing):
            processing.backendJobID
        case .completed(let completed):
            completed.backendJobID
        case .failed(let failed):
            failed.backendJobID
        case .idle, .resolving, .reviewing:
            nil
        }
    }

    private func record(id: UUID) -> HistoryRecord? {
        history.records.first { $0.id == id }
    }

    private static func describe(_ error: any Error) -> String {
        String(describing: error)
    }
}

private enum WorkflowPersistenceError: Error {
    case missingRecord(UUID)
}
