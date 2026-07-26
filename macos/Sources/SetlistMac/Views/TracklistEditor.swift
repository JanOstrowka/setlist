import SwiftUI

struct TracklistEditor: View {
    @Binding var draft: SetDraft
    let seek: (Double) -> Void
    let pasteTracklist: (String) -> Void

    @State private var pasteText = ""
    @State private var showsPasteSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if draft.tracklist.tracks.isEmpty {
                emptyState
            } else {
                trackRows
            }

            if !draft.validationIssues.isEmpty {
                validationSummary
            }
        }
        .sheet(isPresented: $showsPasteSheet) {
            pasteSheet
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("TRACKLIST")
                    .font(.caption.weight(.semibold))
                    .tracking(2.2)
                    .foregroundStyle(SetlistTheme.cherry)
                Text(sourceDescription)
                    .font(.caption)
                    .foregroundStyle(SetlistTheme.mutedPaper.opacity(0.8))
            }

            Spacer()

            Button("Paste Tracklist…") {
                pasteText = ""
                showsPasteSheet = true
            }
            .controlSize(.small)

            Button("Add Track", systemImage: "plus") {
                withAnimation(.easeOut(duration: 0.18)) {
                    draft.addTrack()
                }
            }
            .controlSize(.small)
        }
    }

    private var sourceDescription: String {
        switch draft.tracklist.source {
        case .chapters:
            "From YouTube chapters"
        case .description:
            "From the video description"
        case .oneThousandOneTracklists:
            "From 1001tracklists"
        case .manual:
            "Edited manually"
        case .none:
            "No tracklist yet"
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No tracks yet")
                .font(.headline)
                .foregroundStyle(SetlistTheme.paper)
            Text(
                "Add cue points to split the set into individual tracks, "
                    + "or turn off splitting to keep one continuous file."
            )
            .font(.callout)
            .foregroundStyle(SetlistTheme.mutedPaper)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 18)
    }

    private var trackRows: some View {
        List {
            ForEach(draft.tracklist.tracks.indices, id: \.self) { index in
                TrackRow(
                    index: index,
                    track: trackBinding(index),
                    issue: issue(for: index),
                    seek: seek,
                    remove: {
                        withAnimation(.easeOut(duration: 0.18)) {
                            draft.removeTrack(at: index)
                        }
                    }
                )
                .listRowSeparatorTint(SetlistTheme.hairline)
                .listRowBackground(Color.clear)
            }
            .onMove { source, destination in
                guard let first = source.first else {
                    return
                }
                draft.moveTrack(from: first, to: destination)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .frame(minHeight: 220)
        .accessibilityLabel("Tracklist, \(draft.tracklist.tracks.count) tracks")
    }

    private var validationSummary: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(
                Array(draft.validationIssues.prefix(3).enumerated()),
                id: \.offset
            ) { _, issue in
                Label(issue.message, systemImage: "exclamationmark.circle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var pasteSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Paste a tracklist")
                .font(.headline)
            Text("One track per line, like “3:24 Artist – Title”.")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextEditor(text: $pasteText)
                .font(.body.monospaced())
                .frame(width: 460, height: 220)
            HStack {
                Spacer()
                Button("Cancel") {
                    showsPasteSheet = false
                }
                Button("Use Tracklist") {
                    showsPasteSheet = false
                    pasteTracklist(pasteText)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(
                    pasteText.trimmingCharacters(in: .whitespacesAndNewlines)
                        .isEmpty
                )
            }
        }
        .padding(22)
    }

    private func trackBinding(_ index: Int) -> Binding<APITrack> {
        Binding(
            get: {
                guard draft.tracklist.tracks.indices.contains(index) else {
                    return APITrack()
                }
                return draft.tracklist.tracks[index]
            },
            set: { newValue in
                guard draft.tracklist.tracks.indices.contains(index) else {
                    return
                }
                draft.tracklist.tracks[index] = newValue
                draft.tracklist.source = .manual
            }
        )
    }

    private func issue(for index: Int) -> DraftValidationIssue? {
        draft.validationIssues.first { issue in
            switch issue {
            case .missingStart(let trackIndex),
                 .startBeyondDuration(let trackIndex),
                 .nonAscendingStart(let trackIndex):
                trackIndex == index
            case .emptyTracklist:
                false
            }
        }
    }
}

private struct TrackRow: View {
    let index: Int
    @Binding var track: APITrack
    let issue: DraftValidationIssue?
    let seek: (Double) -> Void
    let remove: () -> Void

    @State private var timeText = ""
    @FocusState private var timeFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Text(String(format: "%02d", index + 1))
                .font(.caption.monospacedDigit())
                .foregroundStyle(SetlistTheme.mutedPaper.opacity(0.7))
                .frame(width: 24, alignment: .trailing)

            Button {
                if let start = track.start {
                    seek(start)
                }
            } label: {
                Image(systemName: "play.circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(
                track.start == nil
                    ? SetlistTheme.mutedPaper.opacity(0.4)
                    : SetlistTheme.cherry
            )
            .disabled(track.start == nil)
            .help("Play from this cue")
            .accessibilityLabel("Play track \(index + 1) from its cue")

            TextField("0:00", text: $timeText)
                .textFieldStyle(.roundedBorder)
                .font(.body.monospacedDigit())
                .frame(width: 76)
                .focused($timeFocused)
                .onChange(of: timeFocused) { _, focused in
                    if !focused {
                        commitTime()
                    }
                }
                .onSubmit(commitTime)
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(
                            issue == nil ? .clear : .orange,
                            lineWidth: 1
                        )
                )
                .accessibilityLabel("Track \(index + 1) start time")

            TextField("Title", text: $track.title)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Track \(index + 1) title")

            TextField("Artist", text: $track.artist)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 180)
                .accessibilityLabel("Track \(index + 1) artist")

            Button(role: .destructive, action: remove) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(SetlistTheme.mutedPaper.opacity(0.6))
            .help("Remove track")
            .accessibilityLabel("Remove track \(index + 1)")
        }
        .padding(.vertical, 2)
        .onAppear {
            timeText = TrackTime.format(track.start)
        }
        .onChange(of: track.start) { _, newValue in
            if !timeFocused {
                timeText = TrackTime.format(newValue)
            }
        }
    }

    private func commitTime() {
        track.start = TrackTime.parse(timeText)
        timeText = TrackTime.format(track.start)
    }
}
