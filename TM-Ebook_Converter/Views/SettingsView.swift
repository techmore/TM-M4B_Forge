import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appModel: AppViewModel

    var body: some View {
        Form {
            Section("Conversion Defaults") {
                Picker("AAC bitrate", selection: $appModel.defaults.bitrateKbps) {
                    ForEach([128, 160, 192, 256, 320], id: \.self) { value in
                        Text("\(value) kbps").tag(value)
                    }
                }
                Picker("Sample rate", selection: $appModel.defaults.sampleRate) {
                    Text("44.1 kHz").tag(44_100)
                    Text("48 kHz").tag(48_000)
                }
                Toggle("Stream-copy compatible sources", isOn: $appModel.defaults.allowStreamCopy)
                Toggle("Overwrite existing exports", isOn: $appModel.defaults.overwriteExisting)
                Toggle("Create folder per audiobook", isOn: $appModel.defaults.outputIntoProjectFolder)
                Toggle("Clean output file names", isOn: $appModel.defaults.cleanOutputNames)
                Button("Choose Default Output Folder") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    if panel.runModal() == .OK {
                        appModel.defaults.outputFolderURL = panel.url
                    }
                }
                Text(appModel.defaults.outputFolderURL?.path ?? "Music folder")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("FFmpeg") {
                Text("ffmpeg: \(FFmpegToolLocator.ffmpegURL()?.path ?? "not found")")
                Text("ffprobe: \(FFmpegToolLocator.ffprobeURL()?.path ?? "not found")")
            }
        }
    }
}
