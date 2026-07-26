import SwiftUI
import WebKit

/// Drives the embedded YouTube player in `YouTubePlayerView`.
///
/// YouTube requires a valid HTTPS `Referer` header on embed requests and
/// rejects players without one ("Video player configuration error",
/// error 153). WKWebView sends no referer for local HTML or direct
/// top-level loads, so the referer is attached to the request explicitly.
/// Seeking drives the embed page's own `<video>` element.
@MainActor
@Observable
final class YouTubePlayerController {
    static let refererURL = "https://setlist.local/"

    @ObservationIgnored fileprivate weak var webView: WKWebView?
    private(set) var loadedVideoID: String?

    /// Set when the rights holder blocks embedded playback for the loaded
    /// video ("Video unavailable"); the UI swaps in a thumbnail fallback.
    private(set) var unavailableReason: String?

    func load(videoID: String) {
        loadedVideoID = videoID
        unavailableReason = nil
        webView?.load(Self.embedRequest(videoID: videoID))
    }

    func markUnavailable(reason: String) {
        let cleaned = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        unavailableReason = cleaned.isEmpty
            ? "This video cannot be played inside other apps."
            : cleaned
    }

    static func embedRequest(videoID: String) -> URLRequest {
        var request = URLRequest(url: embedURL(videoID: videoID))
        request.setValue(refererURL, forHTTPHeaderField: "Referer")
        request.setValue(refererURL, forHTTPHeaderField: "Origin")
        return request
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
        components.host = "www.youtube.com"
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

    static func thumbnailURL(videoID: String) -> URL {
        URL(string: "https://i.ytimg.com/vi/\(videoID)/hqdefault.jpg")!
    }

    static func watchURL(videoID: String) -> URL {
        URL(string: "https://www.youtube.com/watch?v=\(videoID)")!
    }

    /// Injected into the embed page: when YouTube shows its in-player
    /// error panel (`.ytp-error`, e.g. a rights holder blocking embeds),
    /// the reason is reported to the app so a native fallback can take
    /// over.
    static let errorProbeScript = """
    (function () {
        function reasonText() {
            var parts = [];
            var nodes = document.querySelectorAll(
                '.ytp-error-content-wrap-reason, '
                + '.ytp-error-content-wrap-subreason'
            );
            for (var i = 0; i < nodes.length; i++) {
                var text = (nodes[i].textContent || '').trim();
                if (text) { parts.push(text); }
            }
            return parts.join(' — ');
        }
        function report() {
            if (!document.querySelector('.ytp-error')) { return false; }
            try {
                window.webkit.messageHandlers.setlistPlayer.postMessage({
                    status: 'blocked',
                    reason: reasonText()
                });
            } catch (err) {}
            return true;
        }
        if (report()) { return; }
        var observer = new MutationObserver(function () {
            if (report()) { observer.disconnect(); }
        });
        observer.observe(document.documentElement, {
            childList: true,
            subtree: true
        });
    })();
    """
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
        Coordinator(controller: controller)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: YouTubePlayerController.errorProbeScript,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            )
        )
        configuration.userContentController.add(
            context.coordinator,
            name: "setlistPlayer"
        )

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

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController
            .removeScriptMessageHandler(forName: "setlistPlayer")
        webView.stopLoading()
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        private weak var controller: YouTubePlayerController?

        init(controller: YouTubePlayerController) {
            self.controller = controller
        }

        nonisolated func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            // WKScriptMessage is delivered on the main thread.
            MainActor.assumeIsolated {
                guard let body = message.body as? [String: Any],
                      body["status"] as? String == "blocked" else {
                    return
                }
                controller?.markUnavailable(
                    reason: body["reason"] as? String ?? ""
                )
            }
        }
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
