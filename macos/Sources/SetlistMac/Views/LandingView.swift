import AppKit
import Foundation
import SwiftUI

enum YouTubeURLValidator {
    static func isValid(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased() else {
            return false
        }

        if host == "youtu.be" {
            guard let videoID = components.path
                .split(separator: "/", omittingEmptySubsequences: true)
                .first else {
                return false
            }
            return isValidVideoID(String(videoID))
        }

        guard host == "youtube.com"
                || host == "www.youtube.com"
                || host == "m.youtube.com" else {
            return false
        }

        if components.path == "/watch" {
            guard let videoID = components.queryItems?
                .first(where: { $0.name == "v" })?
                .value else {
                return false
            }
            return isValidVideoID(videoID)
        }

        let segments = components.path.split(separator: "/")
        return segments.count >= 2
            && ["shorts", "live", "embed"].contains(String(segments[0]))
            && isValidVideoID(String(segments[1]))
    }

    private static func isValidVideoID(_ value: String) -> Bool {
        value.count == 11
            && value.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0)
                    || $0 == "_"
                    || $0 == "-"
            }
    }
}

enum LandingSubmission: Equatable {
    case resolve(String)
    case showError(String)

    static func intent(for value: String) -> LandingSubmission {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard YouTubeURLValidator.isValid(trimmed) else {
            return .showError("Paste a valid YouTube video URL.")
        }
        return .resolve(trimmed)
    }
}

struct ResolvePresentation: Equatable {
    struct Phase: Equatable, Identifiable {
        let title: String

        var id: String { title }
    }

    let phases = [
        Phase(title: "Reading YouTube details"),
        Phase(title: "Preparing artwork and tags"),
        Phase(title: "Finding a tracklist"),
        Phase(title: "Ready to review"),
    ]
    let shimmerEnabled: Bool

    init(reduceMotion: Bool) {
        shimmerEnabled = !reduceMotion
    }
}

struct LandingView: View {
    let resolve: (String) -> Void

    @State private var sourceURL = ""
    @State private var errorMessage: String?
    @FocusState private var fieldIsFocused: Bool

    private var isValid: Bool {
        YouTubeURLValidator.isValid(sourceURL)
    }

    var body: some View {
        ZStack {
            SetlistDetailBackground()

            HStack(alignment: .center, spacing: 64) {
                RecordSleeveMark()
                    .frame(width: 252, height: 252)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 0) {
                    Text("NEW SET")
                        .font(.caption.weight(.semibold))
                        .tracking(2.2)
                        .foregroundStyle(SetlistTheme.cherry)

                    Text("Bring the set.\nWe’ll shape the record.")
                        .font(.system(size: 43, weight: .medium))
                        .tracking(-1.4)
                        .foregroundStyle(SetlistTheme.paper)
                        .padding(.top, 14)

                    Text(
                        "Paste a YouTube set to resolve its artwork, "
                            + "metadata, and tracklist."
                    )
                    .font(.title3)
                    .foregroundStyle(SetlistTheme.mutedPaper)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 18)
                    .padding(.bottom, 30)

                    GlassEffectContainer(spacing: 16) {
                        pasteSurface
                    }
                }
                .frame(maxWidth: 520, alignment: .leading)
            }
            .frame(maxWidth: SetlistTheme.contentWidth)
            .padding(SetlistTheme.detailPadding)
        }
        .onAppear {
            fieldIsFocused = true
        }
    }

    private var pasteSurface: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                TextField("https://youtube.com/watch?v=…", text: $sourceURL)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .foregroundStyle(SetlistTheme.paper)
                    .focused($fieldIsFocused)
                    .onChange(of: sourceURL) {
                        errorMessage = nil
                    }
                    .onSubmit {
                        guard isValid else {
                            return
                        }
                        submit()
                    }
                    .accessibilityLabel("YouTube URL")

                Button("Paste", systemImage: "doc.on.clipboard") {
                    pasteFromClipboard()
                }
                .labelStyle(.titleAndIcon)
                .buttonStyle(.plain)
                .foregroundStyle(SetlistTheme.paper.opacity(0.78))
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 15)
            .background(.black.opacity(0.20), in: .rect(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(SetlistTheme.hairline)
            }

            HStack(alignment: .center) {
                Group {
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.circle")
                            .foregroundStyle(
                                Color(red: 0.98, green: 0.52, blue: 0.48)
                            )
                    } else {
                        Text("youtube.com · youtu.be")
                            .foregroundStyle(SetlistTheme.mutedPaper.opacity(0.72))
                    }
                }
                .font(.caption)

                Spacer()

                Button("Resolve") {
                    submit()
                }
                .buttonStyle(.borderedProminent)
                .tint(SetlistTheme.cherry)
                .disabled(!isValid)
                .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding(18)
        .glassEffect(.regular, in: .rect(cornerRadius: 26))
    }

    private func pasteFromClipboard() {
        guard let clipboard = NSPasteboard.general.string(forType: .string) else {
            errorMessage = "The clipboard doesn’t contain text."
            return
        }
        sourceURL = clipboard.trimmingCharacters(in: .whitespacesAndNewlines)
        fieldIsFocused = true
        if !sourceURL.isEmpty, !isValid {
            errorMessage = "The clipboard isn’t a YouTube video URL."
        }
    }

    private func submit() {
        switch LandingSubmission.intent(for: sourceURL) {
        case .resolve(let url):
            errorMessage = nil
            sourceURL = url
            resolve(url)
        case .showError(let message):
            errorMessage = message
        }
    }
}

private struct RecordSleeveMark: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(SetlistTheme.cherry)
                .rotationEffect(.degrees(-3))
                .offset(x: -8, y: 7)

            Rectangle()
                .fill(SetlistTheme.warmBlack)
                .overlay(alignment: .topLeading) {
                    Text("SETLIST / 001")
                        .font(.caption2.weight(.semibold))
                        .tracking(1.8)
                        .foregroundStyle(SetlistTheme.paper.opacity(0.75))
                        .padding(18)
                }

            ZStack {
                Circle()
                    .fill(Color(red: 0.035, green: 0.03, blue: 0.03))
                ForEach([0.72, 0.55, 0.38], id: \.self) { scale in
                    Circle()
                        .stroke(.white.opacity(0.08), lineWidth: 1)
                        .scaleEffect(scale)
                }
                Circle()
                    .fill(SetlistTheme.cherry)
                    .frame(width: 46, height: 46)
                Circle()
                    .fill(SetlistTheme.paper)
                    .frame(width: 8, height: 8)
            }
            .frame(width: 174, height: 174)
            .offset(x: 26, y: 24)
            .shadow(color: .black.opacity(0.32), radius: 18, y: 10)
        }
    }
}
