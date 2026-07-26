import Foundation
import XCTest
@testable import SetlistMac

final class TracklistEditingTests: XCTestCase {
    func testMoveTrackPreservesOrderAndValues() {
        var draft = SetDraft.editingFixture(
            tracks: [.named("A"), .named("B"), .named("C")]
        )

        draft.moveTrack(from: 2, to: 0)

        XCTAssertEqual(draft.tracklist.tracks.map(\.title), ["C", "A", "B"])
    }

    func testMoveTrackForwardAccountsForRemoval() {
        var draft = SetDraft.editingFixture(
            tracks: [.named("A"), .named("B"), .named("C")]
        )

        draft.moveTrack(from: 0, to: 3)

        XCTAssertEqual(draft.tracklist.tracks.map(\.title), ["B", "C", "A"])
    }

    func testMoveTrackMarksTracklistManual() {
        var draft = SetDraft.editingFixture(
            tracks: [.named("A"), .named("B")]
        )

        draft.moveTrack(from: 1, to: 0)

        XCTAssertEqual(draft.tracklist.source, .manual)
    }

    func testAddTrackInsertsAfterIndex() {
        var draft = SetDraft.editingFixture(
            tracks: [.named("A"), .named("B")]
        )

        draft.addTrack(after: 0)

        XCTAssertEqual(draft.tracklist.tracks.count, 3)
        XCTAssertEqual(draft.tracklist.tracks[1].title, "")
    }

    func testRemoveTrackDeletesRow() {
        var draft = SetDraft.editingFixture(
            tracks: [.named("A"), .named("B")]
        )

        draft.removeTrack(at: 0)

        XCTAssertEqual(draft.tracklist.tracks.map(\.title), ["B"])
    }

    func testTrackTimeFormatting() {
        XCTAssertEqual(TrackTime.format(nil), "")
        XCTAssertEqual(TrackTime.format(0), "0:00")
        XCTAssertEqual(TrackTime.format(204), "3:24")
        XCTAssertEqual(TrackTime.format(3_753), "1:02:33")
    }

    func testTrackTimeParsing() {
        XCTAssertEqual(TrackTime.parse("0:00"), 0)
        XCTAssertEqual(TrackTime.parse("3:24"), 204)
        XCTAssertEqual(TrackTime.parse("1:02:33"), 3_753)
        XCTAssertEqual(TrackTime.parse("42"), 42)
        XCTAssertNil(TrackTime.parse(""))
        XCTAssertNil(TrackTime.parse("abc"))
        XCTAssertNil(TrackTime.parse("1:99"))
        XCTAssertNil(TrackTime.parse("-1:00"))
    }
}

final class ReviewValidationTests: XCTestCase {
    func testSplitValidationIdentifiesMissingCue() {
        let draft = SetDraft.editingFixture(
            split: true,
            tracks: [
                APITrack(start: 0, title: "A"),
                APITrack(start: nil, title: "B"),
            ]
        )

        XCTAssertEqual(
            draft.validationIssues,
            [.missingStart(trackIndex: 1)]
        )
        XCTAssertFalse(draft.canStartProcessing)
    }

    func testSplitValidationRejectsEmptyTracklist() {
        let draft = SetDraft.editingFixture(split: true, tracks: [])

        XCTAssertEqual(draft.validationIssues, [.emptyTracklist])
    }

    func testSplitValidationFlagsStartBeyondDuration() {
        let draft = SetDraft.editingFixture(
            split: true,
            tracks: [APITrack(start: 4_000, title: "A")]
        )

        XCTAssertEqual(
            draft.validationIssues,
            [.startBeyondDuration(trackIndex: 0)]
        )
    }

    func testSplitValidationFlagsNonAscendingStarts() {
        let draft = SetDraft.editingFixture(
            split: true,
            tracks: [
                APITrack(start: 120, title: "A"),
                APITrack(start: 60, title: "B"),
            ]
        )

        XCTAssertEqual(
            draft.validationIssues,
            [.nonAscendingStart(trackIndex: 1)]
        )
    }

    func testDisabledSplitSkipsTrackValidation() {
        let draft = SetDraft.editingFixture(split: false, tracks: [])

        XCTAssertTrue(draft.validationIssues.isEmpty)
        XCTAssertTrue(draft.canStartProcessing)
    }
}

extension SetDraft {
    static func editingFixture(
        split: Bool = true,
        tracks: [APITrack]
    ) -> SetDraft {
        SetDraft(
            historyID: UUID(),
            sourceURL: "https://youtu.be/abcdefghijk",
            response: APIResolveResponse(
                videoID: "abcdefghijk",
                duration: 3_600,
                metadata: APIMetadataFields(
                    title: "Fixture Set",
                    artist: "Fixture DJ"
                ),
                cover: "keep",
                formats: "m4a",
                detectedLine: "Fixture",
                hasChapters: false,
                tracklist: APITracklist(source: .manual, tracks: tracks)
            ),
            split: split
        )
    }
}

extension APITrack {
    static func named(_ title: String) -> APITrack {
        APITrack(start: 0, title: title)
    }
}
