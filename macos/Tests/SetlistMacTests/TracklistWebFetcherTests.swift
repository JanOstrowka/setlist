import Foundation
import XCTest
@testable import SetlistMac

final class TracklistWebFetcherTests: XCTestCase {
    func testPastedTracklistURLAccepts1001TracklistsLinks() {
        XCTAssertEqual(
            TracklistWebFetcher.pastedTracklistURL(
                from: "  https://www.1001tracklists.com/tracklist/2hm37f8t/"
                    + "john-summit-savaya-bali-indonesia-2023-10-10.html  "
            )?.host(),
            "www.1001tracklists.com"
        )
        XCTAssertEqual(
            TracklistWebFetcher.pastedTracklistURL(
                from: "https://1001.tl/2hm37f8t"
            )?.host(),
            "1001.tl"
        )
    }

    func testPastedTracklistURLRejectsOtherInput() {
        XCTAssertNil(
            TracklistWebFetcher.pastedTracklistURL(
                from: "https://example.com/tracklist/abc"
            )
        )
        XCTAssertNil(
            TracklistWebFetcher.pastedTracklistURL(
                from: "http://www.1001tracklists.com/tracklist/abc"
            )
        )
        XCTAssertNil(
            TracklistWebFetcher.pastedTracklistURL(
                from: "0:00 Artist - Title\n3:43 Other - Track"
            )
        )
        XCTAssertNil(TracklistWebFetcher.pastedTracklistURL(from: ""))
    }

    func testSearchURLTargetsDuckDuckGoWithSiteFilter() {
        let url = TracklistWebFetcher.searchURL(
            query: "John Summit Live from Savaya Bali"
        )

        XCTAssertEqual(url.host(), "html.duckduckgo.com")
        let query = try? XCTUnwrap(url.query(percentEncoded: false))
        XCTAssertTrue(query?.contains("site:1001tracklists.com") == true)
        XCTAssertTrue(query?.contains("John Summit") == true)
    }

    func testFirstTracklistURLSkipsNonTracklistPages() {
        let html = """
        <a href="https://www.1001tracklists.com/source/mylp5v/savaya-bali/index.html">source</a>
        <a href="https://www.1001tracklists.com/tracklist/2hm37f8t/john-summit-savaya-bali-indonesia-2023-10-10.html">result</a>
        <a href="https://www.1001tracklists.com/tracklist/other/second.html">second</a>
        """

        XCTAssertEqual(
            TracklistWebFetcher.firstTracklistURL(inHTML: html)?.absoluteString,
            "https://www.1001tracklists.com/tracklist/2hm37f8t/"
                + "john-summit-savaya-bali-indonesia-2023-10-10.html"
        )
        XCTAssertNil(TracklistWebFetcher.firstTracklistURL(inHTML: "<p>none</p>"))
    }

    func testExtractionScriptAnchorsOnGoogleSearchLinksAndCues() {
        let script = TracklistWebFetcher.extractionScript

        XCTAssertTrue(script.contains("google.com/search"))
        XCTAssertTrue(script.contains("[?&]q=([^&]+)"))
        // The opening track has no cue on 1001tracklists; it starts at 0:00.
        XCTAssertTrue(script.contains("cue = '0:00'"))
    }
}
