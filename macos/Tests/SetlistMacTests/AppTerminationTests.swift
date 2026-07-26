import Foundation
import XCTest
@testable import SetlistMac

final class AppTerminationTests: XCTestCase {
    func testQuitRequiresConfirmationDuringProcessing() {
        let policy = TerminationPolicy(
            state: .processing(
                ProcessingState(
                    recordID: UUID(),
                    backendJobID: "job",
                    stage: .download,
                    percent: 12,
                    message: "Downloading",
                    frozenDraft: .editingFixture(tracks: [])
                )
            )
        )

        XCTAssertEqual(policy.action, .confirmCancellation)
    }

    func testQuitRequiresConfirmationDuringResolving() {
        let policy = TerminationPolicy(
            state: .resolving(
                ResolvePhase(
                    recordID: UUID(),
                    sourceURL: "https://youtu.be/abcdefghijk"
                )
            )
        )

        XCTAssertEqual(policy.action, .confirmCancellation)
    }

    func testQuitIsImmediateWhenIdle() {
        XCTAssertEqual(
            TerminationPolicy(state: .idle).action,
            .terminateNow
        )
    }

    func testQuitIsImmediateWhenReviewing() {
        let policy = TerminationPolicy(
            state: .reviewing(.editingFixture(tracks: []))
        )

        XCTAssertEqual(policy.action, .terminateNow)
    }

    func testQuitIsImmediateAfterCompletion() {
        let policy = TerminationPolicy(
            state: .completed(
                CompletedJob(
                    recordID: UUID(),
                    backendJobID: "job",
                    outputPaths: ["/Music/set.m4a"],
                    completedAt: Date()
                )
            )
        )

        XCTAssertEqual(policy.action, .terminateNow)
    }

    func testQuitIsImmediateAfterFailure() {
        let policy = TerminationPolicy(
            state: .failed(
                FailedJob(
                    recordID: UUID(),
                    backendJobID: nil,
                    message: "boom",
                    failedAt: Date()
                )
            )
        )

        XCTAssertEqual(policy.action, .terminateNow)
    }
}
