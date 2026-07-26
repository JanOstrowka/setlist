import Foundation
import XCTest
@testable import SetlistMac

@MainActor
final class YouTubePlayerTests: XCTestCase {
    func testEmbedURLUsesYouTubeHostAndInlinePlayback() {
        let url = YouTubePlayerController.embedURL(videoID: "S1L8cNyfXT4")

        XCTAssertEqual(url.host(), "www.youtube.com")
        XCTAssertEqual(url.path, "/embed/S1L8cNyfXT4")
        XCTAssertTrue(url.query()?.contains("playsinline=1") == true)
    }

    func testEmbedRequestCarriesHTTPSRefererForYouTube() {
        let request = YouTubePlayerController.embedRequest(videoID: "S1L8cNyfXT4")

        let referer = request.value(forHTTPHeaderField: "Referer")
        XCTAssertEqual(referer, YouTubePlayerController.refererURL)
        XCTAssertTrue(referer?.hasPrefix("https://") == true)
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Origin"),
            YouTubePlayerController.refererURL
        )
    }

    func testSeekScriptTargetsPageVideoElement() {
        let script = YouTubePlayerController.seekScript(seconds: 204.5)

        XCTAssertTrue(script.contains("document.querySelector('video')"))
        XCTAssertTrue(script.contains("video.currentTime = 204.5"))
        XCTAssertTrue(script.contains("video.play()"))
    }

    func testPlayerIdentifiesAsSafari() {
        XCTAssertTrue(YouTubePlayerView.safariUserAgent.contains("Safari"))
        XCTAssertTrue(YouTubePlayerView.safariUserAgent.contains("Macintosh"))
    }
}
