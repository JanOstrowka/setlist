import XCTest
@testable import SetlistMac

@MainActor
final class CompletedSetSummaryTests: XCTestCase {
    func testTrackNamesStripDirectoriesAndExtensions() {
        let names = CompletedSetSummaryView.trackNames(from: [
            "/tmp/out/01 - Deep End.m4a",
            "/tmp/out/02 - La Danza.m4a",
        ])

        XCTAssertEqual(names, ["01 - Deep End", "02 - La Danza"])
    }

    func testMetaLineJoinsArtistCountAndFinishDate() {
        let line = CompletedSetSummaryView.metaLine(
            artist: "John Summit",
            trackCount: 12,
            completedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        XCTAssertTrue(
            line.hasPrefix("John Summit · 12 tracks · Finished "),
            "Unexpected meta line: \(line)"
        )
    }

    func testMetaLineOmitsMissingArtistAndUsesSingularTrack() {
        let line = CompletedSetSummaryView.metaLine(
            artist: "",
            trackCount: 1,
            completedAt: nil
        )

        XCTAssertEqual(line, "1 track")
    }

    func testWatchURLPrefersCanonicalVideoIDOverSourceExtras() {
        let url = CompletedSetSummaryView.watchURL(
            videoID: "S1L8cNyfXT4",
            sourceURL: "https://www.youtube.com/watch?v=S1L8cNyfXT4&t=843s"
        )

        XCTAssertEqual(
            url?.absoluteString,
            "https://www.youtube.com/watch?v=S1L8cNyfXT4"
        )
    }

    func testWatchURLFallsBackToSourceURLWithoutVideoID() {
        let url = CompletedSetSummaryView.watchURL(
            videoID: nil,
            sourceURL: "https://youtu.be/abcdefghijk"
        )

        XCTAssertEqual(url?.absoluteString, "https://youtu.be/abcdefghijk")
    }
}
