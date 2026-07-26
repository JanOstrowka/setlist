import Foundation
import XCTest
@testable import SetlistMac

final class AccessibilityStateTests: XCTestCase {
    func testEveryHistoryStageHasNonemptyDisplayTitle() {
        let stages: [HistoryStage] = [
            .resolving, .reviewing, .submitting, .queued, .download,
            .encode, .split, .tag, .done, .error, .cancelled, .unknown,
        ]

        for stage in stages {
            XCTAssertFalse(
                stage.displayTitle.isEmpty,
                "Stage \(stage) needs a spoken title"
            )
        }
    }

    func testEveryValidationIssueHasNonemptyMessage() {
        let issues: [DraftValidationIssue] = [
            .emptyTracklist,
            .missingStart(trackIndex: 0),
            .startBeyondDuration(trackIndex: 1),
            .nonAscendingStart(trackIndex: 2),
        ]

        for issue in issues {
            XCTAssertFalse(
                issue.message.isEmpty,
                "Issue \(issue) needs a user-facing message"
            )
        }
    }

    func testValidationMessagesUseOneBasedTrackNumbers() {
        XCTAssertTrue(
            DraftValidationIssue.missingStart(trackIndex: 0)
                .message.contains("Track 1")
        )
        XCTAssertTrue(
            DraftValidationIssue.nonAscendingStart(trackIndex: 4)
                .message.contains("Track 5")
        )
    }

    func testMusicImportErrorsSpeakForThemselves() {
        let errors: [MusicImportError] = [
            .noFiles,
            .missingFiles(["/tmp/a.m4a"]),
            .scriptFailed("permission denied"),
        ]

        for error in errors {
            let description = error.errorDescription ?? ""
            XCTAssertFalse(
                description.isEmpty,
                "Error \(error) needs a user-facing description"
            )
        }
    }

    func testReduceMotionDisablesResolveShimmer() {
        XCTAssertFalse(
            ResolvePresentation(reduceMotion: true).shimmerEnabled
        )
        XCTAssertTrue(
            ResolvePresentation(reduceMotion: false).shimmerEnabled
        )
    }
}
