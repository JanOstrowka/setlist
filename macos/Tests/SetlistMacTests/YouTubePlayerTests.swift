import Foundation
import XCTest
@testable import SetlistMac

@MainActor
final class YouTubePlayerTests: XCTestCase {
    func testEmbedURLUsesPrivacyEnhancedHostAndInlinePlayback() {
        let url = YouTubePlayerController.embedURL(videoID: "S1L8cNyfXT4")

        XCTAssertEqual(url.host(), "www.youtube-nocookie.com")
        XCTAssertEqual(url.path, "/embed/S1L8cNyfXT4")
        XCTAssertTrue(url.query()?.contains("playsinline=1") == true)
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
