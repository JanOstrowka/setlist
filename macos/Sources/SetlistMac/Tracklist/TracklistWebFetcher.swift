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

    /// Finds the 1001tracklists page for a set: the site's own search
    /// first, a DuckDuckGo HTML search as a fallback. Only a result that
    /// plausibly matches the query is returned.
    @MainActor func searchTracklistURL(query: String) async throws -> URL?
}

/// One row of a tracklist search: where it points and what it is called.
struct TracklistCandidate: Equatable, Sendable {
    let url: URL
    let title: String
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

    /// Bound for each search request. The review scene shows a skeleton
    /// while this runs, so a hung request must not look like a hung app.
    private static let searchTimeout: TimeInterval = 12

    @MainActor
    func searchTracklistURL(query: String) async throws -> URL? {
        // The site's own index ranks the set we want first and is plain
        // server-rendered HTML — no Cloudflare wall on the search page.
        if let html = try? await Self.fetchHTML(Self.onSiteSearchRequest(query: query)),
           let match = Self.bestMatch(
               Self.candidates(inSearchResultHTML: html),
               query: query
           ) {
            return match
        }
        // DuckDuckGo's HTML endpoint rate-limits by IP and answers with an
        // HTTP 202 "anomaly" page; that is a miss, not an empty result.
        var request = URLRequest(url: Self.searchURL(query: query))
        request.timeoutInterval = Self.searchTimeout
        request.setValue(
            YouTubePlayerView.safariUserAgent,
            forHTTPHeaderField: "User-Agent"
        )
        guard let html = try? await Self.fetchHTML(request, acceptedStatus: 200...200),
              !Self.isDuckDuckGoChallenge(html: html) else {
            return nil
        }
        return Self.bestMatch(Self.candidates(inDuckDuckGoHTML: html), query: query)
    }

    private static func fetchHTML(
        _ request: URLRequest,
        acceptedStatus: ClosedRange<Int> = 200...299
    ) async throws -> String? {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              acceptedStatus.contains(http.statusCode) else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
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

    /// The same search for a real browser, offered when the in-app lookup
    /// comes up empty: the user finds the page and pastes its URL. The
    /// site's own search is POST-only, so it cannot be deep-linked.
    static func browserSearchURL(query: String) -> URL {
        var components = URLComponents(string: "https://duckduckgo.com/")!
        components.queryItems = [
            URLQueryItem(name: "q", value: "\(query) site:1001tracklists.com")
        ]
        return components.url!
    }

    /// The site's search form: a POST to `/search/result.php` scoped to
    /// tracklists (`search_selection=9`). The GET form of the same URL
    /// returns the generic landing page.
    static func onSiteSearchRequest(query: String) -> URLRequest {
        var request = URLRequest(
            url: URL(string: "https://www.1001tracklists.com/search/result.php")!
        )
        request.httpMethod = "POST"
        request.timeoutInterval = searchTimeout
        request.setValue(
            YouTubePlayerView.safariUserAgent,
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue(
            "application/x-www-form-urlencoded; charset=utf-8",
            forHTTPHeaderField: "Content-Type"
        )
        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "main_search", value: query),
            URLQueryItem(name: "search_selection", value: "9"),
        ]
        request.httpBody = Data((form.percentEncodedQuery ?? "").utf8)
        return request
    }

    /// Result rows of a 1001tracklists search page, in the site's ranking
    /// order. Each row's title link is `<div class="bTitle"><a href=…>Title</a>`.
    static func candidates(inSearchResultHTML html: String) -> [TracklistCandidate] {
        let pattern = /class="bTitle"[^>]*>\s*<a href="(\/tracklist\/[^"]+)"[^>]*>(.*?)<\/a>/
            .dotMatchesNewlines()
        var seen = Set<String>()
        var candidates: [TracklistCandidate] = []
        for match in html.matches(of: pattern) {
            let path = String(match.1)
            guard !seen.contains(path),
                  let url = URL(string: "https://www.1001tracklists.com" + path) else {
                continue
            }
            seen.insert(path)
            candidates.append(
                TracklistCandidate(url: url, title: decodeEntities(stripTags(String(match.2))))
            )
        }
        return candidates
    }

    /// `/tracklist/` links in a DuckDuckGo HTML result page, in result
    /// order. DJ index and source pages are skipped. The slug stands in for
    /// the title, which is what the scoring reads anyway.
    static func candidates(inDuckDuckGoHTML html: String) -> [TracklistCandidate] {
        let pattern = /href="(https:\/\/(?:www\.)?1001tracklists\.com\/tracklist\/[^"]+)"/
        var seen = Set<String>()
        var candidates: [TracklistCandidate] = []
        for match in html.matches(of: pattern) {
            let link = String(match.1)
            guard !seen.contains(link), let url = URL(string: link) else {
                continue
            }
            seen.insert(link)
            let slug = url.deletingPathExtension().lastPathComponent
            candidates.append(
                TracklistCandidate(url: url, title: slug.replacingOccurrences(of: "-", with: " "))
            )
        }
        return candidates
    }

    /// The candidate sharing the most words with the query, or nil when
    /// even the best one is a loose match. The site answers every query
    /// with *something*, so "first result" alone would attach a random set
    /// to any video that is not on 1001tracklists.
    static func bestMatch(_ candidates: [TracklistCandidate], query: String) -> URL? {
        let wanted = searchTokens(query)
        guard !wanted.isEmpty else {
            return nil
        }
        let required = max(min(2, wanted.count), Int((Double(wanted.count) * 0.6).rounded(.up)))

        var best: (score: Int, url: URL)?
        for candidate in candidates {
            let slug = candidate.url.deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: "-", with: " ")
            let have = Set(searchTokens(candidate.title + " " + slug))
            let score = wanted.filter(have.contains).count
            if score >= required, score > (best?.score ?? 0) {
                best = (score, candidate.url)
            }
        }
        return best?.url
    }

    /// Words worth matching on: lowercased, diacritics folded, punctuation
    /// split, with the filler that YouTube titles and the site both add
    /// ("live", "set", "full", "hd"…) removed. Order is kept, duplicates
    /// dropped.
    static func searchTokens(_ text: String) -> [String] {
        let folded = text.folding(
            options: [.diacriticInsensitive, .caseInsensitive],
            locale: .init(identifier: "en_US_POSIX")
        )
        var seen = Set<String>()
        var tokens: [String] = []
        for raw in folded.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            let token = String(raw)
            guard token.count >= 2,
                  !noiseWords.contains(token),
                  !seen.contains(token) else {
                continue
            }
            seen.insert(token)
            tokens.append(token)
        }
        return tokens
    }

    private static let noiseWords: Set<String> = [
        "live", "set", "dj", "mix", "at", "the", "an", "of", "in", "on", "from",
        "full", "hd", "4k", "official", "video", "audio", "tracklist", "and",
        "with", "vs", "pres", "presents", "stage", "recorded", "recording",
    ]

    /// DuckDuckGo's bot check: an HTTP 202 page that loads `anomaly.js`
    /// instead of results.
    static func isDuckDuckGoChallenge(html: String) -> Bool {
        html.contains("anomaly.js") || html.contains("anomaly-modal")
    }

    private static func stripTags(_ html: String) -> String {
        html.replacing(/<[^>]+>/, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeEntities(_ text: String) -> String {
        var result = text
        for (entity, replacement) in [
            ("&amp;", "&"), ("&#039;", "'"), ("&#39;", "'"), ("&apos;", "'"),
            ("&quot;", "\""), ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " "),
        ] {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        return result
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
