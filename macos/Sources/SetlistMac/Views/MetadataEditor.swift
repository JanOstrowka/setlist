import SwiftUI

struct MetadataEditor: View {
    @Binding var draft: SetDraft

    private var yearBinding: Binding<String> {
        Binding(
            get: { draft.metadata.year.map(String.init) ?? "" },
            set: { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespaces)
                draft.metadata.year = Int(trimmed)
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionLabel("SET METADATA")

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                fieldRow("Title", text: $draft.metadata.title)
                fieldRow("Artist", text: $draft.metadata.artist)
                fieldRow("Album", text: $draft.metadata.album)
                fieldRow("Album artist", text: $draft.metadata.albumArtist)
                GridRow {
                    fieldLabel("Year")
                    TextField("2026", text: yearBinding)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 92)
                }
                fieldRow("Genre", text: $draft.metadata.genre)
                fieldRow("Comment", text: $draft.metadata.comment)
            }

            sectionLabel("OUTPUT")

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
                GridRow {
                    fieldLabel("Format")
                    Picker("Format", selection: $draft.format) {
                        Text("Apple Lossless").tag(APIAudioFormat.alac)
                        Text("AAC 256").tag(APIAudioFormat.aac256)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 260, alignment: .leading)
                }
                GridRow {
                    fieldLabel("Tracks")
                    Toggle(
                        "Split into individual tracks",
                        isOn: $draft.split
                    )
                    .toggleStyle(.switch)
                    .tint(SetlistTheme.cherry)
                }
                GridRow {
                    fieldLabel("Compilation")
                    Toggle(
                        "Tag as a various-artists set",
                        isOn: $draft.metadata.compilation
                    )
                    .toggleStyle(.switch)
                    .tint(SetlistTheme.cherry)
                }
            }
        }
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .tracking(2.2)
            .foregroundStyle(SetlistTheme.cherry)
    }

    private func fieldRow(
        _ label: String,
        text: Binding<String>
    ) -> some View {
        GridRow {
            fieldLabel(label)
            TextField(label, text: text)
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
        }
    }

    private func fieldLabel(_ label: String) -> some View {
        Text(label)
            .font(.callout)
            .foregroundStyle(SetlistTheme.mutedPaper)
            .frame(width: 100, alignment: .leading)
            .gridColumnAlignment(.leading)
    }
}
