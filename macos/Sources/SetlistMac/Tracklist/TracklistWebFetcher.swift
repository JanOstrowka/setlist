import Foundation
import WebKit

/// Fetches 1001tracklists pages inside the app.
///
/// The site never sends track data to plain HTTP clients (the rows are
/// rendered by JavaScript behind Cloudflare), which is why the backend
/// needs a Firecrawl API key for it. The app carries a real browser
/// engine, so an invisible WKWebView renders the page exactly like
/// Safari and the rows are extracted straight from the DOM — no key,
/// no third-party service.
protocol TracklistPageFetching: Sendable {
    /// Renders the page and returns the tracklist as
    /// `cue Artist - Title` lines suitable for the backend text parser.
    @MainActor func fetchTracklistText(from url: URL) async throws -> String

    /// Finds the 1001tracklists page for a set via a DuckDuckGo HTML
    /// search (static HTML, no API key required).
    @MainActor func searchTracklistURL(query: String) async throws -> URL?
}

enum TracklistFetchError: LocalizedError {
    case pageDidNotRender

    var errorDescription: String? {
        switch self {
        case .pageDidNotRender:
            "Could not read the tracklist from 1001tracklists — "
                + "the page did not finish loading. Try again, or paste "
                + "the tracklist text instead."
        }
    }
}

final class TracklistWebFetcher: NSObject, TracklistPageFetching, @unchecked Sendable {
    /// The track rows appear a couple of seconds after load; poll until
    /// they do, giving slow networks a generous but bounded window.
    private static let pollInterval: Duration = .seconds(0.7)
    private static let deadline: Duration = .seconds(30)

    @MainActor
    func fetchTracklistText(from url: URL) async throws -> String {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 1280, height: 2400),
            configuration: configuration
        )
        webView.customUserAgent = YouTubePlayerView.safariUserAgent
        webView.load(URLRequest(url: url))
        defer {
            webView.stopLoading()
        }

        let clock = ContinuousClock()
        let deadline = clock.now + Self.deadline
        while clock.now < deadline {
            try await Task.sleep(for: Self.pollInterval)
            if let text = await Self.evaluate(Self.extractionScript, in: webView),
               !text.isEmpty {
                return text
            }
        }
        throw TracklistFetchError.pageDidNotRender
    }

    @MainActor
    func searchTracklistURL(query: String) async throws -> URL? {
        var request = URLRequest(url: Self.searchURL(query: query))
        request.setValue(
            YouTubePlayerView.safariUserAgent,
            forHTTPHeaderField: "User-Agent"
        )
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            return nil
        }
        let html = String(decoding: data, as: UTF8.self)
        return Self.firstTracklistURL(inHTML: html)
    }

    @MainActor
    private static func evaluate(
        _ script: String,
        in webView: WKWebView
    ) async -> String? {
        await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(script) { result, _ in
                continuation.resume(returning: result as? String)
            }
        }
    }

    // MARK: - Pure helpers

    /// Recognizes a pasted 1001tracklists (or 1001.tl shortener) URL.
    static func pastedTracklistURL(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains(where: \.isNewline),
              let url = URL(string: trimmed),
              url.scheme?.lowercased() == "https",
              let host = url.host()?.lowercased() else {
            return nil
        }
        let matches = host == "1001.tl"
            || host == "1001tracklists.com"
            || host.hasSuffix(".1001tracklists.com")
        return matches ? url : nil
    }

    static func searchURL(query: String) -> URL {
        var components = URLComponents(
            string: "https://html.duckduckgo.com/html/"
        )!
        components.queryItems = [
            URLQueryItem(name: "q", value: "\(query) site:1001tracklists.com")
        ]
        return components.url!
    }

    /// The first actual `/tracklist/` page in a DuckDuckGo HTML result
    /// page; DJ index and source pages are skipped.
    static func firstTracklistURL(inHTML html: String) -> URL? {
        let pattern = /href="(https:\/\/(?:www\.)?1001tracklists\.com\/tracklist\/[^"]+)"/
        guard let match = html.firstMatch(of: pattern) else {
            return nil
        }
        return URL(string: String(match.1))
    }

    /// Extracts `cue Artist - Title` lines from a rendered 1001tracklists
    /// page. Each track row carries a Google search link whose `q=` is a
    /// clean `Artist - Title`; the row's cue time sits in the same row
    /// container. A row is the largest ancestor holding exactly one such
    /// link, so cue lookup can never bleed into neighboring tracks. The
    /// first track has no cue on 1001tracklists and starts the set at 0:00.
    static let extractionScript = """
    (function () {
        var anchors = Array.prototype.slice.call(
            document.querySelectorAll('a[href*="google.com/search"]')
        );
        function rowFor(anchor) {
            var node = anchor;
            while (node.parentElement) {
                var parent = node.parentElement;
                var count = parent.querySelectorAll(
                    'a[href*="google.com/search"]'
                ).length;
                if (count > 1) { return node; }
                node = parent;
            }
            return node;
        }
        var lines = [];
        for (var i = 0; i < anchors.length; i++) {
            var href = anchors[i].getAttribute('href') || '';
            var match = href.match(/[?&]q=([^&]+)/);
            if (!match) { continue; }
            var label = decodeURIComponent(match[1].replace(/\\+/g, ' '));
            if (label.indexOf(' - ') === -1) { continue; }
            var row = rowFor(anchors[i]);
            var cueMatch = (row.textContent || '').match(
                /(?:^|[\\s\\[(])(\\d{1,2}:\\d{2}(?::\\d{2})?)(?:[\\s\\])]|$)/
            );
            var cue = cueMatch ? cueMatch[1] : '';
            if (!cue && lines.length === 0) { cue = '0:00'; }
            lines.push((cue ? cue + ' ' : '') + label);
        }
        return lines.join('\\n');
    })();
    """
}
