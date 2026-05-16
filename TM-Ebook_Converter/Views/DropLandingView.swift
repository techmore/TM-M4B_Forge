import SwiftUI

struct DropLandingView: View {
    @EnvironmentObject private var appModel: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 10) {
                Text("M4B Forge")
                    .font(.system(size: 46, weight: .semibold))
                Text("Turn raw narration files into a polished audiobook: ordered chapters, clean tags, cover art, and a single M4B.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 780, alignment: .leading)
            }

            HStack(spacing: 16) {
                WorkflowCard(
                    title: "Build From Chapter Files",
                    subtitle: "Use a folder of numbered MP3 or M4A files. M4B Forge sorts them, reads durations, and creates chapter markers from file boundaries.",
                    symbol: "square.stack.3d.up.fill",
                    tint: .teal
                ) {
                    appModel.importFolder()
                }

                WorkflowCard(
                    title: "Chapter One Long File",
                    subtitle: "Import a single recording, split by time or add exact boundaries, then export it as a proper chaptered M4B.",
                    symbol: "waveform.path.ecg.rectangle.fill",
                    tint: .orange
                ) {
                    appModel.importSingleFileForChaptering()
                }
            }

            HStack(spacing: 12) {
                Label("Offline processing", systemImage: "lock.shield")
                Label("AAC M4B output", systemImage: "music.note")
                Label("iTunes-style metadata", systemImage: "tag")
                Label("Cover embedding", systemImage: "photo")
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

private struct WorkflowCard: View {
    let title: String
    let subtitle: String
    let symbol: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 18) {
                Image(systemName: symbol)
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 56, height: 56)

                VStack(alignment: .leading, spacing: 8) {
                    Text(title)
                        .font(.title2.weight(.semibold))
                    Text(subtitle)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                HStack {
                    Text("Start")
                    Image(systemName: "arrow.right")
                }
                .font(.headline)
            }
            .padding(22)
            .frame(maxWidth: .infinity, minHeight: 280, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(.quaternary)
            }
        }
        .buttonStyle(.plain)
    }
}
