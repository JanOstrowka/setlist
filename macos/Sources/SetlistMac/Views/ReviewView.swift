import SwiftUI

struct ReviewView: View {
    let workflow: WorkflowController
    let draft: SetDraft

    @State private var player = YouTubePlayerController()

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
                }
                .frame(maxWidth: SetlistTheme.contentWidth, alignment: .leading)
                .padding(SetlistTheme.detailPadding)
            }
            .safeAreaInset(edge: .bottom) {
                // Pinned above the fold: the primary action is always
                // visible while the review content scrolls behind it.
                footer
                    .frame(maxWidth: SetlistTheme.contentWidth)
                    .padding(.horizontal, SetlistTheme.detailPadding)
                    .padding(.bottom, 18)
            }
        }
        .task(id: draft.historyID) {
            // Sets without chapters arrive with an empty tracklist; find
            // one automatically instead of waiting for a button press.
            guard draft.tracklist.tracks.isEmpty,
                  draft.tracklist.source == .none,
                  !workflow.isFetchingTracklist else {
                return
            }
            await fetchTracklist()
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
            Group {
                if let reason = player.unavailableReason {
                    BlockedVideoFallback(
                        videoID: draft.videoID,
                        reason: reason
                    )
                } else {
                    YouTubePlayerView(videoID: draft.videoID, controller: player)
                        .accessibilityLabel("YouTube preview player")
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(SetlistTheme.hairline, lineWidth: 1)
            )

            MetadataEditor(draft: draftBinding)
        }
    }

    private var rightColumn: some View {
        TracklistEditor(
            draft: draftBinding,
            isFetching: workflow.isFetchingTracklist,
            seek: { player.seek(to: $0) },
            pasteTracklist: { text in
                Task {
                    await workflow.parseTracklist(text)
                }
            },
            retryFind: {
                Task {
                    await fetchTracklist()
                }
            }
        )
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
                    Label("Download", systemImage: "arrow.down.circle.fill")
                        .font(.body.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 2)
                }
                .buttonStyle(.borderedProminent)
                .tint(SetlistTheme.cherry)
                .keyboardShortcut(.defaultAction)
                .disabled(!draft.canStartProcessing)
                .accessibilityLabel("Download the set")
            }
            .padding(14)
            .glassEffect(
                .regular,
                in: .rect(cornerRadius: 18)
            )
        }
    }

    private func fetchTracklist() async {
        let query = [draft.metadata.artist, draft.metadata.title]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        await workflow.autoTracklist(
            query: query.isEmpty ? draft.detectedLine : query
        )
    }
}

/// Shown in place of the embed player when the rights holder blocks
/// embedded playback: the video thumbnail with the block reason and a
/// jump to YouTube, where the video still plays.
private struct BlockedVideoFallback: View {
    let videoID: String
    let reason: String

    var body: some View {
        ZStack {
            AsyncImage(
                url: YouTubePlayerController.thumbnailURL(videoID: videoID)
            ) { image in
                image
                    .resizable()
                    .scaledToFill()
            } placeholder: {
                SetlistTheme.warmBlack
            }

            LinearGradient(
                colors: [.black.opacity(0.25), .black.opacity(0.82)],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(spacing: 10) {
                Spacer()

                Image(systemName: "play.slash.fill")
                    .font(.title2)
                    .foregroundStyle(SetlistTheme.mutedPaper)

                Text("Preview blocked by the rights holder")
                    .font(.headline)
                    .foregroundStyle(SetlistTheme.paper)

                Text(reason)
                    .font(.caption)
                    .foregroundStyle(SetlistTheme.mutedPaper)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .padding(.horizontal, 24)

                Button {
                    NSWorkspace.shared.open(
                        YouTubePlayerController.watchURL(videoID: videoID)
                    )
                } label: {
                    Label("Watch on YouTube", systemImage: "arrow.up.forward")
                        .font(.callout.weight(.medium))
                }
                .buttonStyle(.bordered)
                .tint(SetlistTheme.paper)
                .padding(.top, 4)

                Spacer()
            }
            .padding(16)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Video preview unavailable: \(reason). Watch on YouTube instead."
        )
    }
}
