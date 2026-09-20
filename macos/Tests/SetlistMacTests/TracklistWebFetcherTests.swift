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

    // MARK: - On-site search

    /// Trimmed from a real `/search/result.php` response.
    private let searchResultHTML = """
    <div class="bItm action oItm" onclick="window.open('/tracklist/dr6kbf9/john-summit-bud-light-stage-lollapalooza-united-states-chicago-2026-07-30.html', '_self');" data-id="dr6kbf9" id="dr6kbf9"><img data-src="https://i1.sndcdn.com/a.jpg" src="/images/static/empty.png" class="artM extImg" alt="John Summit @ Lollapalooza United States Chicago 2026-07-30 Artwork"><div class="bCont"><div class="bTitle" onclick="cancelBubble();"><a href="/tracklist/dr6kbf9/john-summit-bud-light-stage-lollapalooza-united-states-chicago-2026-07-30.html" class="">John Summit @ Bud Light Stage, Lollapalooza United States Chicago</a></div></div><div class="mediaRow iRow"><div title="tracklist date">2026-07-30</div><div class="tlUser"><a href="/user/1tech/index.html">1tech</a></div></div></div>
    <div class="bItm action oItm" onclick="window.open('/tracklist/1nszdm81/john-summit-new-dance-order-stage-rock-in-rio-brazil-2026-09-13.html', '_self');" data-id="1nszdm81" id="1nszdm81"><div class="bCont"><div class="bTitle"><a href="/tracklist/1nszdm81/john-summit-new-dance-order-stage-rock-in-rio-brazil-2026-09-13.html" class="">John Summit @ New Dance Order Stage, Rock In Rio, Brazil</a></div></div></div>
    <div class="bItm action oItm" onclick="window.open('/tracklist/2mj95l7k/westend-perrys-lollapalooza-united-states-chicago-2026-08-02.html', '_self');" data-id="2mj95l7k"><div class="bCont"><div class="bTitle"><a href="/tracklist/2mj95l7k/westend-perrys-lollapalooza-united-states-chicago-2026-08-02.html">Westend @ Perry&#039;s, Lollapalooza United States Chicago</a></div></div></div>
    """

    func testOnSiteSearchRequestPostsTracklistQuery() throws {
        let request = TracklistWebFetcher.onSiteSearchRequest(
            query: "John Summit Lollapalooza 2026"
        )

        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://www.1001tracklists.com/search/result.php"
        )
        let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        XCTAssertTrue(body.contains("main_search=John%20Summit%20Lollapalooza%202026"))
        XCTAssertTrue(body.contains("search_selection=9"))
        XCTAssertEqual(request.timeoutInterval, 12)
    }

    func testCandidatesInSearchResultKeepPageOrderTitlesAndAbsoluteURLs() {
        let candidates = TracklistWebFetcher.candidates(
            inSearchResultHTML: searchResultHTML
        )

        XCTAssertEqual(candidates.count, 3)
        XCTAssertEqual(
            candidates[0].url.absoluteString,
            "https://www.1001tracklists.com/tracklist/dr6kbf9/"
                + "john-summit-bud-light-stage-lollapalooza-united-states-chicago-2026-07-30.html"
        )
        XCTAssertEqual(
            candidates[0].title,
            "John Summit @ Bud Light Stage, Lollapalooza United States Chicago"
        )
        XCTAssertEqual(candidates[1].title, "John Summit @ New Dance Order Stage, Rock In Rio, Brazil")
        // Entities are decoded so scoring sees real words.
        XCTAssertEqual(candidates[2].title, "Westend @ Perry's, Lollapalooza United States Chicago")
        XCTAssertEqual(TracklistWebFetcher.candidates(inSearchResultHTML: "<p>nothing</p>"), [])
    }

    func testCandidatesInDuckDuckGoHTMLUseSlugAsTitle() {
        let html = """
        <a href="https://www.1001tracklists.com/source/mylp5v/savaya-bali/index.html">source</a>
        <a class="result__a" href="https://www.1001tracklists.com/tracklist/2hm37f8t/john-summit-savaya-bali-indonesia-2023-10-10.html">result</a>
        <a class="result__url" href="https://www.1001tracklists.com/tracklist/2hm37f8t/john-summit-savaya-bali-indonesia-2023-10-10.html">dupe</a>
        <a href="https://1001tracklists.com/tracklist/other/second-set.html">second</a>
        """

        let candidates = TracklistWebFetcher.candidates(inDuckDuckGoHTML: html)

        XCTAssertEqual(candidates.map(\.title), [
            "john summit savaya bali indonesia 2023 10 10",
            "second set",
        ])
    }

    func testBestMatchPrefersTheResultSharingMostQueryWords() {
        let candidates = TracklistWebFetcher.candidates(
            inSearchResultHTML: searchResultHTML
        )

        // The raw app query: artist + YouTube title, with noise words.
        let match = TracklistWebFetcher.bestMatch(
            candidates,
            query: "John Summit JOHN SUMMIT LIVE @ LOLLAPALOOZA CHICAGO 2026"
        )

        XCTAssertEqual(match?.lastPathComponent.hasPrefix("john-summit-bud-light-stage"), true)
    }

    func testBestMatchIgnoresPageOrderWhenALaterResultFitsBetter() {
        let candidates = TracklistWebFetcher.candidates(
            inSearchResultHTML: searchResultHTML
        )

        let match = TracklistWebFetcher.bestMatch(
            candidates,
            query: "Westend Perry's Lollapalooza Chicago 2026"
        )

        XCTAssertEqual(match?.lastPathComponent.hasPrefix("westend-perrys"), true)
    }

    func testBestMatchRejectsFuzzyResultsForSetsThatAreNotOnTheSite() {
        // The site always answers something; a set that is not there comes
        // back as loose word matches that must not be used.
        let candidates = TracklistWebFetcher.candidates(
            inSearchResultHTML: searchResultHTML
        )

        XCTAssertNil(
            TracklistWebFetcher.bestMatch(
                candidates,
                query: "Peggy Gou Coachella Weekend 2 2026"
            )
        )
        XCTAssertNil(TracklistWebFetcher.bestMatch([], query: "anything"))
    }

    func testSearchTokensDropNoiseWordsAndDuplicates() {
        XCTAssertEqual(
            TracklistWebFetcher.searchTokens(
                "John Summit JOHN SUMMIT LIVE @ LOLLAPALOOZA CHICAGO 2026 (Full Set) [HD]"
            ),
            ["john", "summit", "lollapalooza", "chicago", "2026"]
        )
        // "stage" is festival filler; the apostrophe splits off a one-letter
        // fragment that is dropped.
        XCTAssertEqual(
            TracklistWebFetcher.searchTokens("Perry's Stage — Ñu Sky"),
            ["perry", "nu", "sky"]
        )
    }

    func testBrowserSearchURLOpensARegularDuckDuckGoSearch() {
        let url = TracklistWebFetcher.browserSearchURL(query: "John Summit Lollapalooza")

        XCTAssertEqual(url.host(), "duckduckgo.com")
        XCTAssertEqual(
            url.query(percentEncoded: false),
            "q=John Summit Lollapalooza site:1001tracklists.com"
        )
    }

    func testDuckDuckGoChallengePageIsRecognized() {
        XCTAssertTrue(
            TracklistWebFetcher.isDuckDuckGoChallenge(
                html: "<script src=\"/anomaly.js?sv=html&cc=botnet\"></script>"
                    + "<div class=\"anomaly-modal__mask\">"
            )
        )
        XCTAssertFalse(
            TracklistWebFetcher.isDuckDuckGoChallenge(
                html: "<a class=\"result__a\" href=\"https://www.1001tracklists.com/tracklist/x/y.html\">"
            )
        )
    }

    func testExtractionScriptAnchorsOnGoogleSearchLinksAndCues() {
        let script = TracklistWebFetcher.extractionScript

        XCTAssertTrue(script.contains("google.com/search"))
        XCTAssertTrue(script.contains("[?&]q=([^&]+)"))
        // The opening track has no cue on 1001tracklists; it starts at 0:00.
        XCTAssertTrue(script.contains("cue = '0:00'"))
    }
}
