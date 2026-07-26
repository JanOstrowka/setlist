import AppKit
import SwiftUI

struct RecentSidebar: View {
    let records: [HistoryRecord]
    @Binding var selection: UUID?
    let newSet: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button {
                selection = nil
                newSet()
            } label: {
                HStack {
                    Image(systemName: "plus")
                    Text("New Set")
                        .fontWeight(.semibold)
                    Spacer()
                    Text("⌘N")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .accessibilityHint("Starts a new YouTube set")

            Divider()

            List(selection: $selection) {
                Section("Recent") {
                    if records.isEmpty {
                        VStack(alignment: .leading, spacing: 7) {
                            Text("Your shelf is empty")
                                .font(.callout.weight(.medium))
                            Text(
                                "Resolved and finished sets will stay "
                                    + "here for quick access."
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, 18)
                        .listRowSeparator(.hidden)
                    } else {
                        ForEach(records) { record in
                            RecentRow(record: record)
                                .tag(record.id)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        }
        .navigationTitle("Setlist")
    }
}

private struct RecentRow: View {
    let record: HistoryRecord

    private var displayTitle: String {
        record.title.isEmpty ? "Untitled set" : record.title
    }

    private var secondaryLine: String {
        if !record.artist.isEmpty {
            return record.artist
        }
        return record.updatedAt.formatted(.relative(presentation: .named))
    }

    private var trackCount: Int? {
        guard let data = record.tracklistJSON,
              let tracklist = try? APIJSON.decoder.decode(
                  APITracklist.self,
                  from: data
              ),
              !tracklist.tracks.isEmpty else {
            return nil
        }
        return tracklist.tracks.count
    }

    var body: some View {
        HStack(spacing: 11) {
            artwork
                .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 3) {
                Text(displayTitle)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)

                HStack(spacing: 5) {
                    Text(secondaryLine)
                        .lineLimit(1)
                    if let trackCount {
                        Text("·")
                        Text("\(trackCount) tracks")
                    }
                    if record.importedAt != nil {
                        Image(systemName: "music.note")
                            .accessibilityLabel("Added to Music")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                Text(record.status.sidebarTitle)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(record.status.tint)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(
                        record.status.tint.opacity(0.12),
                        in: .capsule
                    )
            }
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var artwork: some View {
        if let data = record.artworkData,
           let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .clipShape(.rect(cornerRadius: 4))
        } else {
            ZStack {
                SetlistTheme.warmBlack
                Circle()
                    .stroke(.white.opacity(0.16), lineWidth: 1)
                    .padding(8)
                Circle()
                    .fill(SetlistTheme.cherry.opacity(0.8))
                    .frame(width: 6, height: 6)
            }
            .clipShape(.rect(cornerRadius: 4))
        }
    }
}

extension HistoryStatus {
    var sidebarTitle: String {
        switch self {
        case .resolving:
            "Resolving"
        case .reviewing:
            "Ready to review"
        case .processing:
            "Processing"
        case .completed:
            "Complete"
        case .failed:
            "Failed"
        case .cancelled:
            "Cancelled"
        case .interrupted:
            "Interrupted"
        }
    }

    var tint: Color {
        switch self {
        case .completed:
            .green
        case .failed:
            .red
        case .cancelled, .interrupted:
            .orange
        case .resolving, .reviewing, .processing:
            SetlistTheme.cherry
        }
    }
}
