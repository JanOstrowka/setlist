import SwiftUI
import WebKit

/// Drives the scoped YouTube IFrame player embedded in `YouTubePlayerView`.
@MainActor
@Observable
final class YouTubePlayerController {
    @ObservationIgnored fileprivate weak var webView: WKWebView?
    private(set) var loadedVideoID: String?

    func load(videoID: String) {
        loadedVideoID = videoID
        webView?.evaluateJavaScript(
            "loadVideo(\(Self.javaScriptString(videoID)));",
            completionHandler: nil
        )
    }

    func seek(to seconds: Double) {
        guard seconds.isFinite, seconds >= 0 else {
            return
        }
        webView?.evaluateJavaScript(
            "seekTo(\(seconds));",
            completionHandler: nil
        )
    }

    static func javaScriptString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}

/// A WKWebView scoped to the YouTube IFrame player only. It never loads the
/// Setlist web application and cancels navigation away from player origins.
struct YouTubePlayerView: NSViewRepresentable {
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
        webView.setValue(false, forKey: "drawsBackground")
        webView.loadHTMLString(
            Self.playerHTML(videoID: videoID),
            baseURL: URL(string: "https://www.youtube.com")
        )
        controller.webView = webView
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        controller.webView = webView
        if controller.loadedVideoID != nil,
           controller.loadedVideoID != videoID {
            controller.load(videoID: videoID)
        }
    }

    static func playerHTML(videoID: String) -> String {
        let escapedID = YouTubePlayerController.javaScriptString(videoID)
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        html, body { margin: 0; height: 100%; background: transparent; overflow: hidden; }
        #player { width: 100%; height: 100%; }
        </style>
        </head>
        <body>
        <div id="player"></div>
        <script src="https://www.youtube.com/iframe_api"></script>
        <script>
        var player = null;
        var pendingVideoID = \(escapedID);
        function onYouTubeIframeAPIReady() {
            player = new YT.Player('player', {
                videoId: pendingVideoID,
                playerVars: { playsinline: 1, rel: 0, modestbranding: 1 }
            });
        }
        function loadVideo(videoID) {
            pendingVideoID = videoID;
            if (player && player.cueVideoById) { player.cueVideoById(videoID); }
        }
        function seekTo(seconds) {
            if (!player || !player.seekTo) { return; }
            player.seekTo(seconds, true);
            if (player.playVideo) { player.playVideo(); }
        }
        </script>
        </body>
        </html>
        """
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
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let host = navigationAction.request.url?.host() else {
                // Local player HTML has no host.
                decisionHandler(.allow)
                return
            }
            let allowed = Self.allowedHostSuffixes.contains { suffix in
                host == suffix || host.hasSuffix("." + suffix)
            }
            decisionHandler(allowed ? .allow : .cancel)
        }
    }
}
