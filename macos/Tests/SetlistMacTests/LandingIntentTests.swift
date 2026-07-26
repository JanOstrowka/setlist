import SwiftData
import XCTest
@testable import SetlistMac

@MainActor
final class LandingIntentTests: XCTestCase {
    func testYouTubeURLValidationAcceptsSupportedVideoURLs() {
        XCTAssertTrue(
            YouTubeURLValidator.isValid("https://youtu.be/abcdefghijk")
        )
        XCTAssertTrue(
            YouTubeURLValidator.isValid(
                "https://www.youtube.com/watch?v=abcdefghijk"
            )
        )
        XCTAssertTrue(
            YouTubeURLValidator.isValid(
                "https://youtube.com/shorts/abcdefghijk"
            )
        )
    }

    func testYouTubeURLValidationRejectsUnsupportedOrIncompleteURLs() {
        XCTAssertFalse(
            YouTubeURLValidator.isValid("https://example.com/video")
        )
        XCTAssertFalse(YouTubeURLValidator.isValid("https://youtu.be/"))
        XCTAssertFalse(
            YouTubeURLValidator.isValid("https://youtu.be/too-short")
        )
        XCTAssertFalse(
            YouTubeURLValidator.isValid("https://youtube.com/watch")
        )
        XCTAssertFalse(YouTubeURLValidator.isValid("not a url"))
    }

    func testVideoIDExtractionIgnoresTimestampsAndPlaylistExtras() {
        XCTAssertEqual(
            YouTubeURLValidator.videoID(
                from: "https://www.youtube.com/watch?v=S1L8cNyfXT4&t=843s"
            ),
            "S1L8cNyfXT4"
        )
        XCTAssertEqual(
            YouTubeURLValidator.videoID(from: "https://youtu.be/S1L8cNyfXT4?t=12"),
            "S1L8cNyfXT4"
        )
        XCTAssertNil(YouTubeURLValidator.videoID(from: "https://example.com/video"))
    }

    func testLandingSubmissionTrimsValidURL() {
        let intent = LandingSubmission.intent(
            for: "  https://youtu.be/abcdefghijk  "
        )

        XCTAssertEqual(
            intent,
            .resolve("https://youtu.be/abcdefghijk")
        )
    }

    func testLandingSubmissionProvidesInlineErrorForInvalidURL() {
        XCTAssertEqual(
            LandingSubmission.intent(for: "https://example.com/video"),
            .showError("Paste a valid YouTube video URL.")
        )
    }

    func testResolvePresentationKeepsNamedPhasesWithoutMotion() {
        let presentation = ResolvePresentation(reduceMotion: true)

        XCTAssertEqual(
            presentation.phases.map(\.title),
            [
                "Reading YouTube details",
                "Preparing artwork and tags",
                "Finding a tracklist",
                "Ready to review",
            ]
        )
        XCTAssertFalse(presentation.shimmerEnabled)
    }

    func testResolvePresentationEnablesShimmerWhenMotionAllowed() {
        XCTAssertTrue(
            ResolvePresentation(reduceMotion: false).shimmerEnabled
        )
    }

    func testAppEnvironmentNewSetClearsHistorySelection() throws {
        let container = try ModelContainer(
            for: HistoryRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let history = try HistoryStore(
            modelContext: ModelContext(container)
        )
        let backend = BackendController(
            configuration: BackendConfiguration(
                projectRoot: URL(fileURLWithPath: "/tmp/setlist-tests")
            ),
            healthCheck: { _ in nil },
            launcher: { _ in Process() },
            retryAttempts: 0
        )
        let workflow = WorkflowController(
            api: NoopSetlistAPI(),
            history: history
        )
        let environment = SetlistAppEnvironment(
            backend: backend,
            modelContainer: container,
            history: history,
            workflow: workflow
        )
        environment.selectedRecordID = UUID()

        environment.startNewSet()

        XCTAssertNil(environment.selectedRecordID)
        XCTAssertEqual(workflow.state, .idle)
    }
}

private struct NoopSetlistAPI: SetlistAPIProtocol {
    func resolve(url: String) async throws -> APIResolveResponse {
        throw CancellationError()
    }

    func autoTracklist(
        query: String,
        url: String,
        duration: Int
    ) async throws -> APITracklist {
        throw CancellationError()
    }

    func parseTracklist(
        text: String,
        duration: Int
    ) async throws -> APITracklist {
        throw CancellationError()
    }

    func submit(_ request: APIDownloadRequest) async throws -> String {
        throw CancellationError()
    }

    func submitSplit(
        _ request: APISplitDownloadRequest
    ) async throws -> String {
        throw CancellationError()
    }

    func progress(
        jobID: String
    ) -> AsyncThrowingStream<APIProgressEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func job(jobID: String) async throws -> APIJobSnapshot {
        throw CancellationError()
    }

    func cancel(jobID: String) async throws -> APIJobSnapshot {
        throw CancellationError()
    }
}
