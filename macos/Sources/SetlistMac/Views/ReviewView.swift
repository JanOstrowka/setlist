import SwiftUI

struct ReviewView: View {
    let workflow: WorkflowController
    let draft: SetDraft

    @State private var player = YouTubePlayerController()
    @State private var isFetchingTracklist = false

    private var draftBinding: Binding<SetDraft> {
        Binding(
            get: {
                if case .reviewing(let current) = workflow.state,
                   current.historyID == draft.historyID {
                    return current
                }
                return draft
            },
            set: { workflow.replaceDraft($0) }
        )
    }

    var body: some View {
        ZStack {
            SetlistDetailBackground()

            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    header

                    HStack(alignment: .top, spacing: 26) {
                        leftColumn
                            .frame(maxWidth: 400)
                        rightColumn
                            .frame(maxWidth: .infinity)
                    }

                    footer
                }
                .frame(maxWidth: SetlistTheme.contentWidth, alignment: .leading)
                .padding(SetlistTheme.detailPadding)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("REVIEW THE SET")
                .font(.caption.weight(.semibold))
                .tracking(2.2)
                .foregroundStyle(SetlistTheme.cherry)
            Text(
                draft.metadata.title.isEmpty
                    ? "Untitled set"
                    : draft.metadata.title
            )
            .font(.system(size: 34, weight: .medium))
            .foregroundStyle(SetlistTheme.paper)
            HStack(spacing: 8) {
                if !draft.metadata.artist.isEmpty {
                    Text(draft.metadata.artist)
                }
                Text(TrackTime.format(Double(draft.duration)))
                    .monospacedDigit()
            }
            .font(.title3)
            .foregroundStyle(SetlistTheme.mutedPaper)
        }
    }

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 16) {
            YouTubePlayerView(videoID: draft.videoID, controller: player)
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(SetlistTheme.hairline, lineWidth: 1)
                )
                .accessibilityLabel("YouTube preview player")

            MetadataEditor(draft: draftBinding)
        }
    }

    private var rightColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Button {
                    fetchTracklist()
                } label: {
                    if isFetchingTracklist {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Finding tracklist…")
                        }
                    } else {
                        Label(
                            "Find Tracklist",
                            systemImage: "sparkle.magnifyingglass"
                        )
                    }
                }
                .disabled(isFetchingTracklist)
                Spacer()
            }

            TracklistEditor(
                draft: draftBinding,
                seek: { player.seek(to: $0) },
                pasteTracklist: { text in
                    Task {
                        isFetchingTracklist = true
                        defer { isFetchingTracklist = false }
                        await workflow.parseTracklist(text)
                    }
                }
            )
        }
    }

    private var footer: some View {
        GlassEffectContainer(spacing: 16) {
            HStack(spacing: 14) {
                Button("Discard", role: .cancel) {
                    workflow.startOver()
                }

                Spacer()

                if let issue = draft.validationIssues.first {
                    Text(issue.message)
                        .font(.callout)
                        .foregroundStyle(.orange)
                }

                Button {
                    Task {
                        await workflow.process()
                    }
                } label: {
                    Label("Produce the Set", systemImage: "waveform")
                        .font(.body.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                }
                .buttonStyle(.borderedProminent)
                .tint(SetlistTheme.cherry)
                .keyboardShortcut(.defaultAction)
                .disabled(!draft.canStartProcessing)
            }
            .padding(14)
            .glassEffect(
                .regular,
                in: .rect(cornerRadius: 18)
            )
        }
    }

    private func fetchTracklist() {
        let query = [draft.metadata.artist, draft.metadata.title]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        Task {
            isFetchingTracklist = true
            defer { isFetchingTracklist = false }
            await workflow.autoTracklist(
                query: query.isEmpty ? draft.detectedLine : query
            )
        }
    }
}
