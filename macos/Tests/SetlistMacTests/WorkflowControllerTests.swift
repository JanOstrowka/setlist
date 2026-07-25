import Foundation
import SwiftData
import XCTest
@testable import SetlistMac

@MainActor
final class WorkflowControllerTests: XCTestCase {
    func testResolvePersistsResolvingBeforeCallingAPI() async throws {
        let gate = ValueGate<APIResolveResponse>()
        let api = StubAPI(resolve: { url in
            try await gate.wait(for: url)
        })
        let history = try makeHistory()
        let controller = WorkflowController(api: api, history: history)

        let task = Task {
            await controller.resolve("https://youtu.be/abcdefghijk")
        }
        try await waitUntil { await gate.hasWaiter(for: "https://youtu.be/abcdefghijk") }

        let record = try XCTUnwrap(history.records.first)
        XCTAssertEqual(record.sourceURL, "https://youtu.be/abcdefghijk")
        XCTAssertEqual(record.status, .resolving)
        guard case .resolving = controller.state else {
            return XCTFail("Expected resolving state")
        }

        await gate.resume(
            .success(.fixture(videoID: "abcdefghijk")),
            for: "https://youtu.be/abcdefghijk"
        )
        await task.value
    }

    func testResolveMovesToReviewingAndPersistsSnapshots() async throws {
        let api = StubAPI(resolve: { _ in .fixture(videoID: "abcdefghijk") })
        let history = try makeHistory()
        let controller = WorkflowController(api: api, history: history)

        await controller.resolve("https://youtu.be/abcdefghijk")

        guard case .reviewing(let draft) = controller.state else {
            return XCTFail("Expected reviewing")
        }
        XCTAssertEqual(draft.videoID, "abcdefghijk")
        XCTAssertEqual(draft.metadata.title, "Fixture Set")
        let record = try XCTUnwrap(history.records.first)
        XCTAssertEqual(record.status, .reviewing)
        XCTAssertEqual(record.videoID, "abcdefghijk")
        XCTAssertNotNil(record.metadataJSON)
        XCTAssertNotNil(record.tracklistJSON)
    }

    func testResolveFailureIsPersisted() async throws {
        let api = StubAPI(resolve: { _ in throw StubError.resolveFailed })
        let history = try makeHistory()
        let controller = WorkflowController(api: api, history: history)

        await controller.resolve("https://youtu.be/failure")

        guard case .failed(let failure) = controller.state else {
            return XCTFail("Expected failed")
        }
        XCTAssertTrue(failure.message.contains("resolveFailed"))
        let record = try XCTUnwrap(history.records.first)
        XCTAssertEqual(record.status, .failed)
        XCTAssertNotNil(record.completedAt)
        XCTAssertTrue(try XCTUnwrap(record.errorSummary).contains("resolveFailed"))
    }

    func testOnlyLatestResolveCanMutateState() async throws {
        let gate = ValueGate<APIResolveResponse>()
        let api = StubAPI(resolve: { url in try await gate.wait(for: url) })
        let history = try makeHistory()
        let controller = WorkflowController(api: api, history: history)

        let oldTask = Task { await controller.resolve("old") }
        try await waitUntil { await gate.hasWaiter(for: "old") }
        let newTask = Task { await controller.resolve("new") }
        try await waitUntil { await gate.hasWaiter(for: "new") }

        await gate.resume(.success(.fixture(videoID: "new-video")), for: "new")
        await newTask.value
        await gate.resume(.success(.fixture(videoID: "old-video")), for: "old")
        await oldTask.value

        guard case .reviewing(let draft) = controller.state else {
            return XCTFail("Expected reviewing")
        }
        XCTAssertEqual(draft.sourceURL, "new")
        XCTAssertEqual(draft.videoID, "new-video")
        XCTAssertEqual(history.records.count, 2)
        XCTAssertEqual(
            history.records.first(where: { $0.sourceURL == "old" })?.status,
            .interrupted
        )
    }

    func testOnlyLatestTracklistTaskCanMutateDraft() async throws {
        let tracklistGate = ValueGate<APITracklist>()
        let api = StubAPI(
            resolve: { _ in .fixture(videoID: "video") },
            autoTracklist: { query, _, _ in
                try await tracklistGate.wait(for: query)
            }
        )
        let history = try makeHistory()
        let controller = WorkflowController(api: api, history: history)
        await controller.resolve("source")

        let oldTask = Task { await controller.autoTracklist(query: "old") }
        try await waitUntil { await tracklistGate.hasWaiter(for: "old") }
        let newTask = Task { await controller.autoTracklist(query: "new") }
        try await waitUntil { await tracklistGate.hasWaiter(for: "new") }

        await tracklistGate.resume(.success(.named("New")), for: "new")
        await newTask.value
        await tracklistGate.resume(.success(.named("Old")), for: "old")
        await oldTask.value

        guard case .reviewing(let draft) = controller.state else {
            return XCTFail("Expected reviewing")
        }
        XCTAssertEqual(draft.tracklist.tracks.map(\.title), ["New"])
        let record = try XCTUnwrap(history.records.first)
        let persisted = try APIJSON.decoder.decode(
            APITracklist.self,
            from: try XCTUnwrap(record.tracklistJSON)
        )
        XCTAssertEqual(persisted.tracks.map(\.title), ["New"])
    }

    func testDraftEditsInvalidatePendingTracklistResponse() async throws {
        let tracklistGate = ValueGate<APITracklist>()
        let api = StubAPI(
            resolve: { _ in .fixture(videoID: "video") },
            autoTracklist: { query, _, _ in
                try await tracklistGate.wait(for: query)
            }
        )
        let history = try makeHistory()
        let controller = WorkflowController(api: api, history: history)
        await controller.resolve("source")

        let lookup = Task { await controller.autoTracklist(query: "lookup") }
        try await waitUntil { await tracklistGate.hasWaiter(for: "lookup") }
        guard case .reviewing(var edited) = controller.state else {
            return XCTFail("Expected reviewing")
        }
        edited.tracklist = .named("Manual")
        controller.replaceDraft(edited)

        await tracklistGate.resume(.success(.named("Automatic")), for: "lookup")
        await lookup.value

        guard case .reviewing(let draft) = controller.state else {
            return XCTFail("Expected reviewing")
        }
        XCTAssertEqual(draft.tracklist.tracks.map(\.title), ["Manual"])
    }

    func testProcessingFreezesReviewedRequestAndPersistsEachStage() async throws {
        let progressEvents: [APIProgressEvent] = [
            .init(stage: .download, pct: 20, message: "Downloading"),
            .init(stage: .encode, pct: 60, message: "Encoding"),
            .init(stage: .done, pct: 100, message: "Done"),
        ]
        let api = StubAPI(
            resolve: { _ in .fixture(videoID: "video") },
            submit: { _ in "job-1" },
            progress: { _ in .events(progressEvents) },
            job: { _ in .completed(jobID: "job-1", paths: ["/tmp/output.m4a"]) }
        )
        let baseHistory = try makeHistory()
        let history = RecordingHistoryStore(base: baseHistory)
        let controller = WorkflowController(api: api, history: history)
        await controller.resolve("source")
        guard case .reviewing(var draft) = controller.state else {
            return XCTFail("Expected reviewing")
        }
        draft.metadata.title = "Reviewed title"
        draft.format = .aac256
        draft.split = false
        controller.replaceDraft(draft)

        await controller.process()

        let requests = await api.singleRequestsSnapshot()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].metadata.title, "Reviewed title")
        XCTAssertEqual(requests[0].format, .aac256)
        XCTAssertTrue(history.savedStages.contains(.submitting))
        XCTAssertTrue(history.savedStages.contains(.queued))
        XCTAssertTrue(history.savedStages.contains(.download))
        XCTAssertTrue(history.savedStages.contains(.encode))
        XCTAssertTrue(history.savedStages.contains(.done))
        guard case .completed(let completed) = controller.state else {
            return XCTFail("Expected completed")
        }
        XCTAssertEqual(completed.outputPaths, ["/tmp/output.m4a"])
        let record = try XCTUnwrap(history.records.first)
        XCTAssertEqual(record.status, .completed)
        XCTAssertEqual(record.backendJobID, "job-1")
        XCTAssertEqual(record.outputPaths, ["/tmp/output.m4a"])
        XCTAssertNotNil(record.completedAt)
    }

    func testPendingTracklistCannotOverwriteDraftAfterProcessingStarts() async throws {
        let tracklistGate = ValueGate<APITracklist>()
        let api = StubAPI(
            resolve: { _ in .fixture(videoID: "video") },
            autoTracklist: { query, _, _ in try await tracklistGate.wait(for: query) },
            submit: { _ in "job-1" },
            progress: { _ in .events([.init(stage: .done, pct: 100)]) },
            job: { _ in .completed(jobID: "job-1", paths: ["/tmp/output.m4a"]) }
        )
        let history = try makeHistory()
        let controller = WorkflowController(api: api, history: history)
        await controller.resolve("source")

        let lookup = Task { await controller.autoTracklist(query: "lookup") }
        try await waitUntil { await tracklistGate.hasWaiter(for: "lookup") }
        await controller.process()
        await tracklistGate.resume(.success(.named("Too late")), for: "lookup")
        await lookup.value

        guard case .completed = controller.state else {
            return XCTFail("Expected completed")
        }
        let requests = await api.singleRequestsSnapshot()
        let request = try XCTUnwrap(requests.first)
        XCTAssertTrue(request.metadata.title == "Fixture Set")
    }

    func testResolveIsBlockedWhileProcessing() async throws {
        let streamProbe = StreamProbe()
        let api = StubAPI(
            resolve: { url in .fixture(videoID: url) },
            submit: { _ in "job-1" },
            progress: { _ in .open(probe: streamProbe) }
        )
        let history = try makeHistory()
        let controller = WorkflowController(api: api, history: history)
        await controller.resolve("original")
        let processing = Task { await controller.process() }
        try await waitUntil { await streamProbe.didStart }

        await controller.resolve("replacement")

        guard case .processing = controller.state else {
            controller.shutdown()
            await processing.value
            return XCTFail("Expected original processing state")
        }
        XCTAssertEqual(history.records.count, 1)
        XCTAssertEqual(history.records.first?.sourceURL, "original")
        controller.shutdown()
        await processing.value
    }

    func testStartingResolveFromReviewingInterruptsAbandonedRecord() async throws {
        let api = StubAPI(resolve: { url in .fixture(videoID: url) })
        let history = try makeHistory()
        let controller = WorkflowController(api: api, history: history)
        await controller.resolve("old")

        await controller.resolve("new")

        XCTAssertEqual(history.records.count, 2)
        XCTAssertEqual(
            history.records.first(where: { $0.sourceURL == "old" })?.status,
            .interrupted
        )
        guard case .reviewing(let draft) = controller.state else {
            return XCTFail("Expected new reviewing state")
        }
        XCTAssertEqual(draft.sourceURL, "new")
    }

    func testTerminalErrorEventFailsImmediatelyWithoutGET() async throws {
        let api = StubAPI(
            resolve: { _ in .fixture(videoID: "video") },
            submit: { _ in "job-1" },
            progress: { _ in
                .events([
                    .init(stage: .error, pct: 70, message: "Encoder exploded"),
                ])
            }
        )
        let history = try makeHistory()
        let controller = WorkflowController(api: api, history: history)
        await controller.resolve("source")

        await controller.process()

        guard case .failed(let failure) = controller.state else {
            return XCTFail("Expected failed state")
        }
        XCTAssertEqual(failure.message, "Encoder exploded")
        XCTAssertEqual(history.records.first?.status, .failed)
        XCTAssertEqual(history.records.first?.stage, .error)
        let jobRequests = await api.jobRequestsSnapshot()
        XCTAssertEqual(jobRequests, [])
    }

    func testTerminalCancelledEventPersistsCancelledWithoutGET() async throws {
        let api = StubAPI(
            resolve: { _ in .fixture(videoID: "video") },
            submit: { _ in "job-1" },
            progress: { _ in
                .events([
                    .init(stage: .cancelled, pct: 40, message: "User cancelled"),
                ])
            }
        )
        let history = try makeHistory()
        let controller = WorkflowController(api: api, history: history)
        await controller.resolve("source")

        await controller.process()

        guard case .failed(let failure) = controller.state else {
            return XCTFail("Expected terminal cancelled state")
        }
        XCTAssertEqual(failure.message, "User cancelled")
        XCTAssertEqual(history.records.first?.status, .cancelled)
        XCTAssertEqual(history.records.first?.stage, .cancelled)
        let jobRequests = await api.jobRequestsSnapshot()
        XCTAssertEqual(jobRequests, [])
    }

    func testTerminalDoneWithGETFailurePreservesFallbackCompletion() async throws {
        let api = StubAPI(
            resolve: { _ in .fixture(videoID: "video") },
            submit: { _ in "job-1" },
            progress: { _ in
                .events([
                    .init(
                        stage: .done,
                        pct: 100,
                        message: "Done",
                        filePath: "/tmp/fallback.m4a"
                    ),
                ])
            },
            job: { _ in throw StubError.disconnected }
        )
        let history = try makeHistory()
        let controller = WorkflowController(api: api, history: history)
        await controller.resolve("source")

        await controller.process()

        guard case .completed(let completed) = controller.state else {
            return XCTFail("Expected recoverable completion")
        }
        XCTAssertEqual(completed.outputPaths, ["/tmp/fallback.m4a"])
        XCTAssertEqual(history.records.first?.status, .completed)
        XCTAssertEqual(history.records.first?.stage, .done)
        XCTAssertEqual(history.records.first?.errorSummary, "disconnected")
    }

    func testTerminalDonePollsNonterminalSnapshotUntilCompleted() async throws {
        let snapshots = SnapshotQueue([
            .processing(jobID: "job-1"),
            .processing(jobID: "job-1"),
            .completed(jobID: "job-1", paths: ["/tmp/final.m4a"]),
        ])
        let api = StubAPI(
            resolve: { _ in .fixture(videoID: "video") },
            submit: { _ in "job-1" },
            progress: { _ in .events([.init(stage: .done, pct: 100)]) },
            job: { _ in try await snapshots.next() }
        )
        let history = try makeHistory()
        let controller = WorkflowController(api: api, history: history)
        await controller.resolve("source")

        await controller.process()

        guard case .completed(let completed) = controller.state else {
            return XCTFail("Expected completion after polling")
        }
        XCTAssertEqual(completed.outputPaths, ["/tmp/final.m4a"])
        let jobRequests = await api.jobRequestsSnapshot()
        XCTAssertEqual(jobRequests.count, 3)
        XCTAssertEqual(history.records.first?.status, .completed)
    }

    func testCallerCancellationAfterSubmitCancelsBackendAndPersistsJobID() async throws {
        let submitGate = ValueGate<String>()
        let api = StubAPI(
            resolve: { _ in .fixture(videoID: "video") },
            submit: { _ in try await submitGate.wait(for: "submit") },
            progress: { _ in .events([]) },
            job: { _ in .completed(jobID: "job-1", paths: []) },
            cancel: { _ in .cancelled(jobID: "job-1") }
        )
        let history = try makeHistory()
        let controller = WorkflowController(api: api, history: history)
        await controller.resolve("source")
        let processing = Task { await controller.process() }
        try await waitUntil { await submitGate.hasWaiter(for: "submit") }

        processing.cancel()
        await submitGate.resume(.success("job-1"), for: "submit")
        await processing.value

        let cancelRequests = await api.cancelRequestsSnapshot()
        XCTAssertEqual(cancelRequests, ["job-1"])
        XCTAssertEqual(history.records.first?.backendJobID, "job-1")
        XCTAssertEqual(history.records.first?.status, .cancelled)
        XCTAssertEqual(history.records.first?.stage, .cancelled)
    }

    func testShutdownTerminatesProgressAndAllowsControllerDeallocation() async throws {
        let streamProbe = StreamProbe()
        let api = StubAPI(
            resolve: { _ in .fixture(videoID: "video") },
            submit: { _ in "job-1" },
            progress: { _ in .open(probe: streamProbe) }
        )
        let history = try makeHistory()
        var controller: WorkflowController? = WorkflowController(
            api: api,
            history: history
        )
        await controller?.resolve("source")
        weak let weakController = controller
        let processing = Task { [weak controller] in
            await controller?.process()
        }
        try await waitUntil { await streamProbe.didStart }

        controller?.shutdown()
        controller = nil
        await processing.value
        try await waitUntil { await streamProbe.didTerminate }

        XCTAssertNil(weakController)
    }

    func testProgressDisconnectReconcilesCompletedJobBeforeFailing() async throws {
        let api = StubAPI(
            resolve: { _ in .fixture(videoID: "video") },
            submit: { _ in "job-1" },
            progress: { _ in .failure(StubError.disconnected) },
            job: { _ in .completed(jobID: "job-1", paths: ["/tmp/reconciled.m4a"]) }
        )
        let history = try makeHistory()
        let controller = WorkflowController(api: api, history: history)
        await controller.resolve("source")

        await controller.process()

        let jobRequests = await api.jobRequestsSnapshot()
        XCTAssertEqual(jobRequests, ["job-1"])
        guard case .completed(let completed) = controller.state else {
            return XCTFail("Expected reconciled completion")
        }
        XCTAssertEqual(completed.outputPaths, ["/tmp/reconciled.m4a"])
        XCTAssertEqual(history.records.first?.status, .completed)
    }

    func testCompletionPreservesPathsReceivedBeforeSnapshot() async throws {
        let api = StubAPI(
            resolve: { _ in .fixture(videoID: "video") },
            submit: { _ in "job-1" },
            progress: { _ in
                .events([
                    .init(
                        stage: .done,
                        pct: 100,
                        message: "Done",
                        filePath: "/tmp/streamed.m4a"
                    ),
                ])
            },
            job: { _ in .completed(jobID: "job-1", paths: []) }
        )
        let history = try makeHistory()
        let controller = WorkflowController(api: api, history: history)
        await controller.resolve("source")

        await controller.process()

        guard case .completed(let completed) = controller.state else {
            return XCTFail("Expected completion")
        }
        XCTAssertEqual(completed.outputPaths, ["/tmp/streamed.m4a"])
        XCTAssertEqual(history.records.first?.outputPaths, ["/tmp/streamed.m4a"])
    }

    func testProgressDisconnectFailsOnlyAfterNonterminalReconciliation() async throws {
        let api = StubAPI(
            resolve: { _ in .fixture(videoID: "video") },
            submit: { _ in "job-1" },
            progress: { _ in .failure(StubError.disconnected) },
            job: { _ in .processing(jobID: "job-1") }
        )
        let history = try makeHistory()
        let controller = WorkflowController(api: api, history: history)
        await controller.resolve("source")

        await controller.process()

        let jobRequests = await api.jobRequestsSnapshot()
        XCTAssertEqual(jobRequests, ["job-1"])
        guard case .failed(let failure) = controller.state else {
            return XCTFail("Expected failure")
        }
        XCTAssertTrue(failure.message.contains("disconnected"))
        XCTAssertEqual(history.records.first?.status, .failed)
    }

    func testControllerMarksPersistedActiveRecordsInterruptedOnStartup() throws {
        let history = try makeHistory()
        try history.insert(HistoryRecord(sourceURL: "one", status: .resolving))
        try history.insert(HistoryRecord(sourceURL: "two", status: .processing))
        try history.save()

        _ = WorkflowController(api: StubAPI(), history: history)

        XCTAssertEqual(history.records.map(\.status), [.interrupted, .interrupted])
    }

    private func makeHistory() throws -> HistoryStore {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: HistoryRecord.self,
            configurations: configuration
        )
        return try HistoryStore(modelContext: ModelContext(container))
    }

    private func waitUntil(
        _ condition: @escaping @Sendable () async -> Bool
    ) async throws {
        for _ in 0..<200 {
            if await condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for async state")
    }
}

private enum StubError: Error, Sendable {
    case resolveFailed
    case disconnected
    case unconfigured
}

private actor ValueGate<Value: Sendable> {
    private var waiters: [String: CheckedContinuation<Value, Error>] = [:]

    func wait(for key: String) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            waiters[key] = continuation
        }
    }

    func hasWaiter(for key: String) -> Bool {
        waiters[key] != nil
    }

    func resume(_ result: Result<Value, Error>, for key: String) {
        waiters.removeValue(forKey: key)?.resume(with: result)
    }
}

private actor StreamProbe {
    private(set) var didStart = false
    private(set) var didTerminate = false

    func started() {
        didStart = true
    }

    func terminated() {
        didTerminate = true
    }
}

private actor SnapshotQueue {
    private var snapshots: [APIJobSnapshot]

    init(_ snapshots: [APIJobSnapshot]) {
        self.snapshots = snapshots
    }

    func next() throws -> APIJobSnapshot {
        guard !snapshots.isEmpty else {
            throw StubError.unconfigured
        }
        return snapshots.removeFirst()
    }
}

private actor StubAPI: SetlistAPIProtocol {
    typealias Resolve = @Sendable (String) async throws -> APIResolveResponse
    typealias AutoTracklist = @Sendable (String, String, Int) async throws -> APITracklist
    typealias ParseTracklist = @Sendable (String, Int) async throws -> APITracklist
    typealias Submit = @Sendable (APIDownloadRequest) async throws -> String
    typealias SubmitSplit = @Sendable (APISplitDownloadRequest) async throws -> String
    typealias Progress = @Sendable (String) -> AsyncThrowingStream<APIProgressEvent, Error>
    typealias Job = @Sendable (String) async throws -> APIJobSnapshot
    typealias Cancel = @Sendable (String) async throws -> APIJobSnapshot

    private let resolveHandler: Resolve
    private let autoTracklistHandler: AutoTracklist
    private let parseTracklistHandler: ParseTracklist
    private let submitHandler: Submit
    private let submitSplitHandler: SubmitSplit
    nonisolated private let progressHandler: Progress
    private let jobHandler: Job
    private let cancelHandler: Cancel

    private(set) var singleRequests: [APIDownloadRequest] = []
    private(set) var splitRequests: [APISplitDownloadRequest] = []
    private(set) var jobRequests: [String] = []
    private(set) var cancelRequests: [String] = []

    init(
        resolve: @escaping Resolve = { _ in throw StubError.unconfigured },
        autoTracklist: @escaping AutoTracklist = { _, _, _ in throw StubError.unconfigured },
        parseTracklist: @escaping ParseTracklist = { _, _ in throw StubError.unconfigured },
        submit: @escaping Submit = { _ in throw StubError.unconfigured },
        submitSplit: @escaping SubmitSplit = { _ in throw StubError.unconfigured },
        progress: @escaping Progress = { _ in .events([]) },
        job: @escaping Job = { _ in throw StubError.unconfigured },
        cancel: @escaping Cancel = { _ in throw StubError.unconfigured }
    ) {
        resolveHandler = resolve
        autoTracklistHandler = autoTracklist
        parseTracklistHandler = parseTracklist
        submitHandler = submit
        submitSplitHandler = submitSplit
        progressHandler = progress
        jobHandler = job
        cancelHandler = cancel
    }

    func resolve(url: String) async throws -> APIResolveResponse {
        try await resolveHandler(url)
    }

    func autoTracklist(
        query: String,
        url: String,
        duration: Int
    ) async throws -> APITracklist {
        try await autoTracklistHandler(query, url, duration)
    }

    func parseTracklist(text: String, duration: Int) async throws -> APITracklist {
        try await parseTracklistHandler(text, duration)
    }

    func submit(_ request: APIDownloadRequest) async throws -> String {
        singleRequests.append(request)
        return try await submitHandler(request)
    }

    func submitSplit(_ request: APISplitDownloadRequest) async throws -> String {
        splitRequests.append(request)
        return try await submitSplitHandler(request)
    }

    nonisolated func progress(
        jobID: String
    ) -> AsyncThrowingStream<APIProgressEvent, Error> {
        progressHandler(jobID)
    }

    func job(jobID: String) async throws -> APIJobSnapshot {
        jobRequests.append(jobID)
        return try await jobHandler(jobID)
    }

    func cancel(jobID: String) async throws -> APIJobSnapshot {
        cancelRequests.append(jobID)
        return try await cancelHandler(jobID)
    }

    func singleRequestsSnapshot() -> [APIDownloadRequest] {
        singleRequests
    }

    func jobRequestsSnapshot() -> [String] {
        jobRequests
    }

    func cancelRequestsSnapshot() -> [String] {
        cancelRequests
    }
}

@MainActor
private final class RecordingHistoryStore: HistoryStoreProtocol {
    let base: HistoryStore
    private(set) var savedStages: [HistoryStage] = []

    var records: [HistoryRecord] {
        base.records
    }

    init(base: HistoryStore) {
        self.base = base
    }

    func insert(_ record: HistoryRecord) throws {
        try base.insert(record)
    }

    func save() throws {
        savedStages.append(contentsOf: records.compactMap(\.stage))
        try base.save()
    }

    func markActiveJobsInterrupted() throws {
        try base.markActiveJobsInterrupted()
    }
}

private extension APIResolveResponse {
    static func fixture(videoID: String) -> Self {
        .init(
            videoID: videoID,
            duration: 3_600,
            metadata: .init(title: "Fixture Set", artist: "Fixture DJ"),
            cover: "keep",
            formats: "m4a",
            detectedLine: "Fixture",
            hasChapters: false,
            tracklist: .init(source: .none)
        )
    }
}

private extension APITracklist {
    static func named(_ title: String) -> Self {
        .init(
            source: .manual,
            tracks: [.init(start: 0, title: title)]
        )
    }
}

private extension APIJobSnapshot {
    static func completed(jobID: String, paths: [String]) -> Self {
        .init(
            jobID: jobID,
            status: .completed,
            latest: .init(stage: .done, pct: 100, message: "Done"),
            outputPaths: paths
        )
    }

    static func processing(jobID: String) -> Self {
        .init(
            jobID: jobID,
            status: .processing,
            latest: .init(stage: .download, pct: 10, message: "Downloading")
        )
    }

    static func cancelled(jobID: String) -> Self {
        .init(
            jobID: jobID,
            status: .cancelled,
            latest: .init(
                stage: .cancelled,
                pct: 100,
                message: "Cancelled"
            )
        )
    }
}

private extension AsyncThrowingStream where Element == APIProgressEvent, Failure == Error {
    static func events(_ events: [APIProgressEvent]) -> Self {
        Self { continuation in
            events.forEach { continuation.yield($0) }
            continuation.finish()
        }
    }

    static func failure(_ error: any Error) -> Self {
        Self { continuation in
            continuation.finish(throwing: error)
        }
    }

    static func open(probe: StreamProbe) -> Self {
        Self { continuation in
            Task {
                await probe.started()
            }
            continuation.onTermination = { @Sendable _ in
                Task {
                    await probe.terminated()
                }
            }
        }
    }
}
