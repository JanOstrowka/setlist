import Foundation
import Observation

@MainActor
@Observable
final class WorkflowController {
    private(set) var state: WorkflowState = .idle

    @ObservationIgnored private let api: any SetlistAPIProtocol
    @ObservationIgnored private let history: any HistoryStoreProtocol
    @ObservationIgnored private let retryDelay: @Sendable (Duration) async -> Void
    @ObservationIgnored private let detachedCancellationAttemptLimit: Int
    @ObservationIgnored private let minimumResolveDisplay: Duration
    @ObservationIgnored private let pageFetcher: (any TracklistPageFetching)?
    @ObservationIgnored private var resolveTask: Task<Void, Never>?
    @ObservationIgnored private var tracklistTask: Task<Void, Never>?
    @ObservationIgnored private var progressTask: Task<Void, Never>?
    @ObservationIgnored private var resolveToken: UUID?
    @ObservationIgnored private var tracklistToken: UUID? {
        didSet {
            isFetchingTracklist = tracklistToken != nil
        }
    }
    @ObservationIgnored private var progressToken: UUID?

    /// True while a tracklist lookup (auto-find or paste) is in flight;
    /// the review scene shows skeleton rows during it.
    private(set) var isFetchingTracklist = false
    @ObservationIgnored private var draftRevision = 0

    init(
        api: any SetlistAPIProtocol,
        history: any HistoryStoreProtocol,
        retryDelay: @escaping @Sendable (Duration) async -> Void = { duration in
            try? await Task.sleep(for: duration)
        },
        detachedCancellationAttemptLimit: Int = 8,
        minimumResolveDisplay: Duration = .zero,
        pageFetcher: (any TracklistPageFetching)? = nil
    ) {
        self.api = api
        self.history = history
        self.retryDelay = retryDelay
        self.detachedCancellationAttemptLimit = max(
            1,
            detachedCancellationAttemptLimit
        )
        self.minimumResolveDisplay = minimumResolveDisplay
        self.pageFetcher = pageFetcher

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

    deinit {
        resolveTask?.cancel()
        tracklistTask?.cancel()
        progressTask?.cancel()
    }

    func resolve(_ sourceURL: String) async {
        guard case .processing = state else {
            await beginResolve(sourceURL)
            return
        }
    }

    private func beginResolve(_ sourceURL: String) async {
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

        let record: HistoryRecord
        let isNewRecord: Bool
        if let existing = existingRecord(matching: sourceURL) {
            // The same set was resolved before: refresh it in place and
            // move it to the top of Recent instead of duplicating it.
            existing.sourceURL = sourceURL
            existing.status = .resolving
            existing.stage = .resolving
            existing.errorSummary = nil
            existing.backendJobID = nil
            existing.completedAt = nil
            existing.updatedAt = Date()
            history.promote(existing)
            record = existing
            isNewRecord = false
        } else {
            record = HistoryRecord(
                sourceURL: sourceURL,
                status: .resolving,
                stage: .resolving
            )
            isNewRecord = true
        }

        do {
            if isNewRecord {
                try history.insert(record)
            }
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
        let retryDelay = retryDelay
        let minimumResolveDisplay = minimumResolveDisplay

        let task = Task { [weak self] in
            do {
                let clock = ContinuousClock()
                let start = clock.now
                let response = try await api.resolve(url: sourceURL)
                // Let the resolving scene finish its phase animation even
                // when the backend answers quickly.
                let remaining = minimumResolveDisplay - start.duration(to: clock.now)
                if remaining > .zero {
                    await retryDelay(remaining)
                }
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
        let pageFetcher = pageFetcher
        await runTracklistLookup(
            draft: draft,
            operation: { [api] in
                let result = try await api.autoTracklist(
                    query: query,
                    url: draft.sourceURL,
                    duration: draft.duration
                )
                if !result.tracks.isEmpty {
                    return result
                }
                // The backend search needs a Firecrawl key; without one it
                // comes back empty. Fall back to an in-app search and an
                // in-app render of the page — no key required.
                guard let pageFetcher,
                      let found = try? await pageFetcher.searchTracklistURL(
                        query: query
                      ) else {
                    return result
                }
                do {
                    let extracted = try await pageFetcher.fetchTracklistText(
                        from: found
                    )
                    var tracklist = try await api.parseTracklist(
                        text: extracted,
                        duration: draft.duration
                    )
                    tracklist.note =
                        "Found on 1001tracklists: \(found.absoluteString)"
                    return tracklist
                } catch {
                    return result
                }
            }
        )
    }

    func parseTracklist(_ text: String) async {
        guard case .reviewing(let draft) = state else {
            return
        }
        // A pasted 1001tracklists URL is rendered inside the app; the
        // extracted rows go through the same backend text parser as a
        // pasted tracklist.
        if let url = TracklistWebFetcher.pastedTracklistURL(from: text),
           let pageFetcher {
            await runTracklistLookup(
                draft: draft,
                operation: { [api] in
                    let extracted = try await pageFetcher.fetchTracklistText(
                        from: url
                    )
                    var tracklist = try await api.parseTracklist(
                        text: extracted,
                        duration: draft.duration
                    )
                    tracklist.note =
                        "Fetched \(tracklist.tracks.count) tracks "
                        + "from 1001tracklists."
                    return tracklist
                }
            )
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

    func shutdown() {
        resolveToken = nil
        tracklistToken = nil
        progressToken = nil
        resolveTask?.cancel()
        tracklistTask?.cancel()
        progressTask?.cancel()
        resolveTask = nil
        tracklistTask = nil
        progressTask = nil
    }

    func startOver() {
        guard case .processing = state else {
            do {
                try cancelActiveWorkForNewResolve()
                state = .idle
            } catch {
                state = .failed(
                    FailedJob(
                        recordID: activeRecordID,
                        backendJobID: activeBackendJobID,
                        message: "Could not start a new set: \(Self.describe(error))",
                        failedAt: Date()
                    )
                )
            }
            return
        }
    }

    func process() async {
        guard let task = startProcessing() else {
            return
        }
        await Self.waitForTask(task)
    }

    /// User-initiated cancellation of the active production job. The
    /// progress worker observes the cancellation, requests a backend
    /// cancel, and reconciles the terminal state.
    func cancelProcessing() {
        guard case .processing = state else {
            return
        }
        progressTask?.cancel()
    }

    /// Cancels active work ahead of app termination and waits a bounded
    /// time for the backend cancel to be delivered and persisted. Anything
    /// still in flight after the timeout is recovered on the next launch
    /// via `markActiveJobsInterrupted`.
    func prepareForTermination(timeout: Duration = .seconds(3)) async {
        if case .processing = state {
            let task = progressTask
            progressTask?.cancel()
            if let task {
                await Self.wait(for: task, upTo: timeout)
            }
            return
        }
        try? cancelActiveWorkForNewResolve()
    }

    private nonisolated static func wait(
        for task: Task<Void, Never>,
        upTo timeout: Duration
    ) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await task.value
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
            }
            await group.next()
            group.cancelAll()
        }
    }

    @discardableResult
    func startProcessing() -> Task<Void, Never>? {
        guard case .reviewing(let draft) = state else {
            return nil
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
            return nil
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
        let retryDelay = retryDelay
        let detachedCancellationAttemptLimit = detachedCancellationAttemptLimit
        let task = Task { [weak self] in
            defer {
                self?.clearProgressTask(token: token)
            }
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

                guard try self?.persistSubmittedJobIfCurrent(
                    jobID,
                    frozenDraft: frozenDraft,
                    token: token
                ) == true else {
                    if Task.isCancelled {
                        _ = await Self.cancelAndPoll(
                            api: api,
                            jobID: jobID,
                            retryDelay: retryDelay,
                            teardownAttemptLimit: detachedCancellationAttemptLimit,
                            ownerIsActive: { false },
                            onNonterminal: { _ in }
                        )
                    }
                    return
                }

                if Task.isCancelled {
                    let cancellation = await Self.cancelAndPoll(
                        api: api,
                        jobID: jobID,
                        retryDelay: retryDelay,
                        teardownAttemptLimit: detachedCancellationAttemptLimit,
                        ownerIsActive: { [weak self] in
                            self?.ownsProgress(token: token) == true
                        },
                        onNonterminal: { [weak self] snapshot in
                            self?.applyNonterminal(
                                snapshot,
                                frozenDraft: frozenDraft,
                                token: token
                            )
                        }
                    )
                    try self?.applyCancellation(
                        cancellation,
                        jobID: jobID,
                        frozenDraft: frozenDraft,
                        token: token
                    )
                    return
                }

                let outcome = await Self.consumeProgress(
                    api: api,
                    jobID: jobID,
                    onProgress: { [weak self] event in
                        guard let self, self.progressToken == token else {
                            throw CancellationError()
                        }
                        try self.apply(
                            event,
                            jobID: jobID,
                            frozenDraft: frozenDraft
                        )
                    }
                )

                switch outcome {
                case .terminal(let event):
                    switch event.stage {
                    case .error:
                        try self?.applyTerminal(
                            event,
                            status: .failed,
                            jobID: jobID,
                            frozenDraft: frozenDraft
                        )
                    case .cancelled:
                        try self?.applyTerminal(
                            event,
                            status: .cancelled,
                            jobID: jobID,
                            frozenDraft: frozenDraft
                        )
                    case .done:
                        try self?.applyDone(
                            event,
                            jobID: jobID,
                            frozenDraft: frozenDraft
                        )
                        let reconciliation = await Self.reconcileDone(
                            api: api,
                            jobID: jobID,
                            retryDelay: retryDelay
                        )
                        switch reconciliation {
                        case .completed(let snapshot):
                            try self?.applyTerminal(
                                snapshot,
                                frozenDraft: frozenDraft,
                                token: token
                            )
                        case .fallback(let message):
                            try self?.persistCompletionNote(
                                recordID: frozenDraft.historyID,
                                message: message
                            )
                        case .cancelled:
                            let cancellation = await Self.cancelAndPoll(
                                api: api,
                                jobID: jobID,
                                retryDelay: retryDelay,
                                teardownAttemptLimit: detachedCancellationAttemptLimit,
                                ownerIsActive: { [weak self] in
                                    self?.ownsProgress(token: token) == true
                                },
                                onNonterminal: { [weak self] snapshot in
                                    self?.applyNonterminal(
                                        snapshot,
                                        frozenDraft: frozenDraft,
                                        token: token
                                    )
                                }
                            )
                            try self?.applyCancellation(
                                cancellation,
                                jobID: jobID,
                                frozenDraft: frozenDraft,
                                token: token
                            )
                        }
                    case .queued, .download, .encode, .split, .tag:
                        break
                    }
                case .disconnected:
                    let reconciliation = try await Self.pollUntilTerminal(
                        api: api,
                        jobID: jobID,
                        retryDelay: retryDelay,
                        onNonterminal: { [weak self] snapshot in
                            self?.applyNonterminal(
                                snapshot,
                                frozenDraft: frozenDraft,
                                token: token
                            )
                        }
                    )
                    switch reconciliation {
                    case .terminal(let snapshot):
                        try self?.applyTerminal(
                            snapshot,
                            frozenDraft: frozenDraft,
                            token: token
                        )
                    case .jobLost:
                        try self?.applyJobLost(
                            jobID: jobID,
                            frozenDraft: frozenDraft,
                            token: token
                        )
                    case .cancelled:
                        let cancellation = await Self.cancelAndPoll(
                            api: api,
                            jobID: jobID,
                            retryDelay: retryDelay,
                            teardownAttemptLimit: detachedCancellationAttemptLimit,
                            ownerIsActive: { [weak self] in
                                self?.ownsProgress(token: token) == true
                            },
                            onNonterminal: { [weak self] snapshot in
                                self?.applyNonterminal(
                                    snapshot,
                                    frozenDraft: frozenDraft,
                                    token: token
                                )
                            }
                        )
                        try self?.applyCancellation(
                            cancellation,
                            jobID: jobID,
                            frozenDraft: frozenDraft,
                            token: token
                        )
                    }
                case .cancelledByTask:
                    let cancellation = await Self.cancelAndPoll(
                        api: api,
                        jobID: jobID,
                        retryDelay: retryDelay,
                        teardownAttemptLimit: detachedCancellationAttemptLimit,
                        ownerIsActive: { [weak self] in
                            self?.ownsProgress(token: token) == true
                        },
                        onNonterminal: { [weak self] snapshot in
                            self?.applyNonterminal(
                                snapshot,
                                frozenDraft: frozenDraft,
                                token: token
                            )
                        }
                    )
                    try self?.applyCancellation(
                        cancellation,
                        jobID: jobID,
                        frozenDraft: frozenDraft,
                        token: token
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
        return task
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

    private func persistSubmittedJobIfCurrent(
        _ jobID: String,
        frozenDraft: SetDraft,
        token: UUID
    ) throws -> Bool {
        guard progressToken == token else {
            return false
        }
        try persistSubmittedJob(jobID, frozenDraft: frozenDraft)
        return true
    }

    private nonisolated static func consumeProgress(
        api: any SetlistAPIProtocol,
        jobID: String,
        onProgress: @MainActor @escaping @Sendable (APIProgressEvent) async throws -> Void
    ) async -> ProgressStreamOutcome {
        do {
            for try await event in api.progress(jobID: jobID) {
                try Task.checkCancellation()
                switch event.stage {
                case .done, .error, .cancelled:
                    return .terminal(event)
                case .queued, .download, .encode, .split, .tag:
                    try await onProgress(event)
                }
            }
            if Task.isCancelled {
                return .cancelledByTask
            }
            return .disconnected(nil)
        } catch is CancellationError {
            return .cancelledByTask
        } catch {
            return .disconnected(String(describing: error))
        }
    }

    private nonisolated static func waitForTask(
        _ task: Task<Void, Never>
    ) async {
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private nonisolated static func pollUntilTerminal(
        api: any SetlistAPIProtocol,
        jobID: String,
        retryDelay: @escaping @Sendable (Duration) async -> Void,
        onNonterminal: @MainActor @escaping @Sendable (APIJobSnapshot) async -> Void
    ) async throws -> BackendPollingOutcome {
        var backoff = PollingBackoff()

        while true {
            let snapshot: APIJobSnapshot
            do {
                snapshot = try await api.job(jobID: jobID)
            } catch {
                if Task.isCancelled {
                    return .cancelled
                }
                if isJobNotFound(error) {
                    return .jobLost
                }
                await retryDelay(backoff.next())
                continue
            }

            if Task.isCancelled {
                return .cancelled
            }
            if snapshot.status.isTerminal {
                return .terminal(snapshot)
            }

            await onNonterminal(snapshot)
            await retryDelay(backoff.next())
            if Task.isCancelled {
                return .cancelled
            }
        }
    }

    private nonisolated static func cancelAndPoll(
        api: any SetlistAPIProtocol,
        jobID: String,
        retryDelay: @escaping @Sendable (Duration) async -> Void,
        teardownAttemptLimit: Int,
        ownerIsActive: @MainActor @escaping @Sendable () -> Bool,
        onNonterminal: @MainActor @escaping @Sendable (APIJobSnapshot) async -> Void
    ) async -> CancellationPollingOutcome {
        let worker = Task.detached { () -> CancellationPollingOutcome in
            var cancellationRequested = false
            var backoff = PollingBackoff()
            var remainingTeardownAttempts: Int?

            while true {
                if !(await ownerIsActive()), remainingTeardownAttempts == nil {
                    remainingTeardownAttempts = teardownAttemptLimit
                }
                if remainingTeardownAttempts == 0 {
                    return .exhausted
                }
                if let remaining = remainingTeardownAttempts {
                    remainingTeardownAttempts = remaining - 1
                }
                do {
                    let snapshot: APIJobSnapshot
                    if cancellationRequested {
                        snapshot = try await api.job(jobID: jobID)
                    } else {
                        snapshot = try await api.cancel(jobID: jobID)
                        cancellationRequested = true
                    }

                    if snapshot.status.isTerminal {
                        return .terminal(snapshot)
                    }
                    await onNonterminal(snapshot)
                } catch {
                    if isJobNotFound(error) {
                        return .jobLost
                    }
                }

                if remainingTeardownAttempts == 0 {
                    return .exhausted
                }
                await retryDelay(backoff.next())
            }
        }
        return await worker.value
    }

    private nonisolated static func reconcileDone(
        api: any SetlistAPIProtocol,
        jobID: String,
        retryDelay: @escaping @Sendable (Duration) async -> Void
    ) async -> DoneReconciliationOutcome {
        var backoff = PollingBackoff()

        for attempt in 0..<4 {
            do {
                let snapshot = try await api.job(jobID: jobID)
                if Task.isCancelled {
                    return .cancelled
                }
                if snapshot.status == .completed {
                    return .completed(snapshot)
                }
                if snapshot.status.isTerminal {
                    return .fallback(
                        snapshot.error.isEmpty
                            ? "Backend status differed after completion."
                            : snapshot.error
                    )
                }
                if attempt < 3 {
                    await retryDelay(backoff.next())
                }
            } catch {
                if Task.isCancelled {
                    return .cancelled
                }
                if isJobNotFound(error) {
                    return .fallback(
                        "Full output reconciliation was unavailable because "
                            + "the completed backend job was not found."
                    )
                }
                if attempt < 3 {
                    await retryDelay(backoff.next())
                    continue
                }
                return .fallback(String(describing: error))
            }
        }
        return .fallback("Final output paths are still being reconciled.")
    }

    private nonisolated static func isJobNotFound(_ error: any Error) -> Bool {
        guard let apiError = error as? SetlistAPIError else {
            return false
        }
        guard case .httpStatus(let status, _) = apiError else {
            return false
        }
        return status == 404
    }

    private func applyNonterminal(
        _ snapshot: APIJobSnapshot,
        frozenDraft: SetDraft,
        token: UUID
    ) {
        guard progressToken == token,
              !snapshot.status.isTerminal,
              let record = record(id: frozenDraft.historyID) else {
            return
        }

        do {
            record.backendJobID = snapshot.jobID
            record.status = .processing
            record.stage = HistoryStage(snapshot.latest.stage)
            record.errorSummary = nil
            merge(snapshot.outputPaths, into: record)
            record.updatedAt = Date()
            try history.save()
            state = .processing(
                ProcessingState(
                    recordID: frozenDraft.historyID,
                    backendJobID: snapshot.jobID,
                    stage: HistoryStage(snapshot.latest.stage),
                    percent: snapshot.latest.overallPercent
                        ?? snapshot.latest.stagePercent,
                    message: snapshot.latest.message,
                    frozenDraft: frozenDraft,
                    trackIndex: snapshot.latest.trackIndex,
                    trackCount: snapshot.latest.trackCount,
                    trackTitle: snapshot.latest.trackTitle,
                    trackState: snapshot.latest.trackState
                )
            )
        } catch {
            fail(
                recordID: frozenDraft.historyID,
                backendJobID: snapshot.jobID,
                error: error
            )
        }
    }

    private func applyTerminal(
        _ snapshot: APIJobSnapshot,
        frozenDraft: SetDraft,
        token: UUID
    ) throws {
        guard progressToken == token, snapshot.status.isTerminal else {
            return
        }
        guard let record = record(id: frozenDraft.historyID) else {
            throw WorkflowPersistenceError.missingRecord(frozenDraft.historyID)
        }

        record.backendJobID = snapshot.jobID
        record.stage = HistoryStage(snapshot.latest.stage)
        merge(snapshot.outputPaths, into: record)
        record.updatedAt = Date()

        switch snapshot.status {
        case .completed:
            try persistCompleted(
                record: record,
                jobID: snapshot.jobID,
                outputPaths: record.outputPaths
            )
        case .failed:
            try persistTerminalFailure(
                record: record,
                status: .failed,
                message: snapshot.error.isEmpty
                    ? snapshot.latest.message
                    : snapshot.error
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
            return
        }
    }

    private func applyCancellation(
        _ outcome: CancellationPollingOutcome,
        jobID: String,
        frozenDraft: SetDraft,
        token: UUID
    ) throws {
        switch outcome {
        case .terminal(let snapshot):
            try applyTerminal(
                snapshot,
                frozenDraft: frozenDraft,
                token: token
            )
        case .jobLost:
            try applyJobLost(
                jobID: jobID,
                frozenDraft: frozenDraft,
                token: token
            )
        case .exhausted:
            break
        }
    }

    private func applyJobLost(
        jobID: String,
        frozenDraft: SetDraft,
        token: UUID
    ) throws {
        guard progressToken == token,
              let record = record(id: frozenDraft.historyID) else {
            return
        }
        record.backendJobID = jobID
        record.stage = .unknown
        try persistTerminalFailure(
            record: record,
            status: .interrupted,
            message: "Backend job \(jobID) was not found. "
                + "The backend may have restarted; retry the download."
        )
    }

    private func ownsProgress(token: UUID) -> Bool {
        progressToken == token
    }

    private func persistCompletionNote(
        recordID: UUID,
        message: String
    ) throws {
        guard let record = record(id: recordID) else {
            throw WorkflowPersistenceError.missingRecord(recordID)
        }
        try persistCompletionNote(record: record, message: message)
    }

    private func clearProgressTask(token: UUID) {
        guard progressToken == token else {
            return
        }
        progressTask = nil
        progressToken = nil
    }

    private func applyTerminal(
        _ event: APIProgressEvent,
        status: HistoryStatus,
        jobID: String,
        frozenDraft: SetDraft
    ) throws {
        guard let record = record(id: frozenDraft.historyID) else {
            throw WorkflowPersistenceError.missingRecord(frozenDraft.historyID)
        }
        record.backendJobID = jobID
        record.stage = HistoryStage(event.stage)
        if let filePath = event.filePath,
           !record.outputPaths.contains(filePath) {
            record.outputPaths.append(filePath)
        }
        let fallback = status == .cancelled ? "Cancelled" : "Processing failed"
        try persistTerminalFailure(
            record: record,
            status: status,
            message: event.message.isEmpty ? fallback : event.message
        )
    }

    private func applyDone(
        _ event: APIProgressEvent,
        jobID: String,
        frozenDraft: SetDraft
    ) throws {
        guard let record = record(id: frozenDraft.historyID) else {
            throw WorkflowPersistenceError.missingRecord(frozenDraft.historyID)
        }
        if let filePath = event.filePath,
           !record.outputPaths.contains(filePath) {
            record.outputPaths.append(filePath)
        }
        try persistCompleted(
            record: record,
            jobID: jobID,
            outputPaths: record.outputPaths
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
                frozenDraft: frozenDraft,
                trackIndex: event.trackIndex,
                trackCount: event.trackCount,
                trackTitle: event.trackTitle,
                trackState: event.trackState,
                downloadedBytes: event.downloadedBytes,
                totalBytes: event.totalBytes,
                speedBytesPerSecond: event.speedBytesPerSecond,
                etaSeconds: event.etaSeconds
            )
        )
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

    private func persistCompleted(
        record: HistoryRecord,
        jobID: String,
        outputPaths: [String]
    ) throws {
        let completedAt = record.completedAt ?? Date()
        record.backendJobID = jobID
        record.status = .completed
        record.stage = .done
        record.errorSummary = nil
        record.outputPaths = outputPaths
        record.completedAt = completedAt
        record.updatedAt = Date()
        try history.save()
        state = .completed(
            CompletedJob(
                recordID: record.id,
                backendJobID: jobID,
                outputPaths: outputPaths,
                completedAt: completedAt
            )
        )
    }

    private func persistCompletionNote(
        record: HistoryRecord,
        message: String
    ) throws {
        record.status = .completed
        record.stage = .done
        record.errorSummary = message
        record.updatedAt = Date()
        try history.save()
        if case .completed(let completed) = state {
            state = .completed(
                CompletedJob(
                    recordID: completed.recordID,
                    backendJobID: completed.backendJobID,
                    outputPaths: record.outputPaths,
                    completedAt: completed.completedAt
                )
            )
        }
    }

    private func merge(
        _ outputPaths: [String],
        into record: HistoryRecord
    ) {
        for outputPath in outputPaths
        where !record.outputPaths.contains(outputPath) {
            record.outputPaths.append(outputPath)
        }
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
              record.status == .resolving || record.status == .reviewing else {
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

    /// Finds a prior record for the same YouTube video regardless of URL
    /// extras (timestamps, playlist parameters), so re-resolving a link
    /// refreshes the existing Recent entry. Records that are mid-production
    /// are never reused.
    private func existingRecord(matching sourceURL: String) -> HistoryRecord? {
        let incomingVideoID = YouTubeURLValidator.videoID(from: sourceURL)
        return history.records.first { candidate in
            guard candidate.status != .processing else {
                return false
            }
            if let incomingVideoID {
                if let candidateVideoID = candidate.videoID,
                   !candidateVideoID.isEmpty {
                    return candidateVideoID == incomingVideoID
                }
                return YouTubeURLValidator.videoID(from: candidate.sourceURL)
                    == incomingVideoID
            }
            return candidate.sourceURL == sourceURL
        }
    }

    private static func describe(_ error: any Error) -> String {
        String(describing: error)
    }
}

private enum WorkflowPersistenceError: Error {
    case missingRecord(UUID)
}

private enum ProgressStreamOutcome: Sendable {
    case terminal(APIProgressEvent)
    case disconnected(String?)
    case cancelledByTask
}

private enum BackendPollingOutcome: Sendable {
    case terminal(APIJobSnapshot)
    case jobLost
    case cancelled
}

private enum DoneReconciliationOutcome: Sendable {
    case completed(APIJobSnapshot)
    case fallback(String)
    case cancelled
}

private enum CancellationPollingOutcome: Sendable {
    case terminal(APIJobSnapshot)
    case jobLost
    case exhausted
}

private struct PollingBackoff: Sendable {
    private var milliseconds = 250

    mutating func next() -> Duration {
        let delay = Duration.milliseconds(milliseconds)
        milliseconds = min(milliseconds * 2, 2_000)
        return delay
    }
}

private extension APIJobStatus {
    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled, .interrupted:
            true
        case .queued, .processing, .cancelling:
            false
        }
    }
}
