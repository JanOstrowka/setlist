import SwiftUI
import WebKit

/// Drives the embedded YouTube player in `YouTubePlayerView`.
///
/// The player loads `youtube-nocookie.com/embed` directly (with a Safari
/// user agent) rather than hosting the IFrame API in local HTML: WKWebView
/// sends no referer for `loadHTMLString` content, which YouTube rejects
/// with "This video is unavailable" (error 152/153). Seeking drives the
/// page's own `<video>` element.
@MainActor
@Observable
final class YouTubePlayerController {
    @ObservationIgnored fileprivate weak var webView: WKWebView?
    private(set) var loadedVideoID: String?

    func load(videoID: String) {
        loadedVideoID = videoID
        webView?.load(URLRequest(url: Self.embedURL(videoID: videoID)))
    }

    func seek(to seconds: Double) {
        guard seconds.isFinite, seconds >= 0 else {
            return
        }
        webView?.evaluateJavaScript(
            Self.seekScript(seconds: seconds),
            completionHandler: nil
        )
    }

    static func embedURL(videoID: String) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.youtube-nocookie.com"
        components.path = "/embed/\(videoID)"
        components.queryItems = [
            URLQueryItem(name: "playsinline", value: "1"),
            URLQueryItem(name: "rel", value: "0"),
            URLQueryItem(name: "modestbranding", value: "1"),
        ]
        return components.url!
    }

    static func seekScript(seconds: Double) -> String {
        """
        (function () {
            var video = document.querySelector('video');
            if (!video) { return; }
            video.currentTime = \(seconds);
            var playing = video.play();
            if (playing && playing.catch) { playing.catch(function () {}); }
        })();
        """
    }
}

/// A WKWebView scoped to the YouTube embed player only. It never loads the
/// Setlist web application and cancels navigation away from player origins.
struct YouTubePlayerView: NSViewRepresentable {
    static let safariUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) "
        + "Version/17.4 Safari/605.1.15"

    let videoID: String
    let controller: YouTubePlayerController

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.mediaTypesRequiringUserActionForPlayback = []

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.customUserAgent = Self.safariUserAgent
        webView.setValue(false, forKey: "drawsBackground")
        controller.webView = webView
        controller.load(videoID: videoID)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        controller.webView = webView
        if controller.loadedVideoID != videoID {
            controller.load(videoID: videoID)
        }
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        private static let allowedHostSuffixes = [
            "youtube.com",
            "youtube-nocookie.com",
            "ytimg.com",
            "googlevideo.com",
            "google.com",
            "gstatic.com",
            "doubleclick.net",
        ]

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url,
                  let host = url.host() else {
                decisionHandler(.cancel)
                return
            }
            let allowed = Self.allowedHostSuffixes.contains { suffix in
                host == suffix || host.hasSuffix("." + suffix)
            }
            // "Watch on YouTube" and similar links should not hijack the
            // player pane; anything that is a full watch page opens in the
            // browser instead.
            if allowed, url.path.hasPrefix("/watch") {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(allowed ? .allow : .cancel)
        }
    }
}
