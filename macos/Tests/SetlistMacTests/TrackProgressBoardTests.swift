import Foundation
import XCTest
@testable import SetlistMac

final class TrackProgressBoardTests: XCTestCase {
    func testTracksStartPending() {
        let board = TrackProgressBoard(trackCount: 3)

        XCTAssertEqual(
            board.statuses,
            [.pending, .pending, .pending]
        )
        XCTAssertEqual(board.readyCount, 0)
        XCTAssertNil(board.activeIndex)
    }

    func testCuttingUpdateActivatesTrack() {
        var board = TrackProgressBoard(trackCount: 3)

        board.apply(.update(stage: .split, trackIndex: 0, trackState: .cutting))

        XCTAssertEqual(board.statuses, [.cutting, .pending, .pending])
        XCTAssertEqual(board.activeIndex, 0)
    }

    func testLaterTrackActivityMarksEarlierTracksReady() {
        var board = TrackProgressBoard(trackCount: 3)

        board.apply(.update(stage: .split, trackIndex: 2, trackState: .cutting))

        XCTAssertEqual(board.statuses, [.ready, .ready, .cutting])
        XCTAssertEqual(board.readyCount, 2)
    }

    func testStatusNeverRegresses() {
        var board = TrackProgressBoard(trackCount: 2)

        board.apply(.update(stage: .tag, trackIndex: 0, trackState: .ready))
        board.apply(.update(stage: .split, trackIndex: 0, trackState: .cutting))

        XCTAssertEqual(board.statuses[0], .ready)
    }

    func testDoneStageMarksAllReady() {
        var board = TrackProgressBoard(trackCount: 3)

        board.apply(.update(stage: .done, trackIndex: nil, trackState: nil))

        XCTAssertEqual(board.statuses, [.ready, .ready, .ready])
        XCTAssertEqual(board.readyCount, 3)
    }

    func testOutOfRangeTrackIndexIsIgnored() {
        var board = TrackProgressBoard(trackCount: 1)

        board.apply(.update(stage: .split, trackIndex: 5, trackState: .cutting))

        XCTAssertEqual(board.statuses, [.pending])
    }

    func testTaggingFollowsCutting() {
        var board = TrackProgressBoard(trackCount: 2)

        board.apply(.update(stage: .split, trackIndex: 0, trackState: .cutting))
        board.apply(.update(stage: .tag, trackIndex: 0, trackState: .tagging))
        board.apply(.update(stage: .tag, trackIndex: 0, trackState: .ready))
        board.apply(.update(stage: .split, trackIndex: 1, trackState: .cutting))

        XCTAssertEqual(board.statuses, [.ready, .cutting])
    }
}

private extension ProcessingState {
    static func update(
        stage: HistoryStage,
        trackIndex: Int?,
        trackState: APITrackProgressState?
    ) -> ProcessingState {
        ProcessingState(
            recordID: UUID(),
            backendJobID: "job",
            stage: stage,
            percent: 0,
            message: "",
            frozenDraft: .editingFixture(tracks: []),
            trackIndex: trackIndex,
            trackCount: nil,
            trackTitle: nil,
            trackState: trackState
        )
    }
}
