import SwiftUI

struct LibrarySidebar: View {
    @EnvironmentObject private var appModel: AppViewModel

    var body: some View {
        List(selection: $appModel.selectedProjectID) {
            if !appModel.importCandidates.isEmpty {
                Section("Import Review") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(appModel.importCandidates.count) item\(appModel.importCandidates.count == 1 ? "" : "s") pending")
                            .font(.headline)
                        Text("Approve selected items to create projects")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Projects") {
                ForEach(appModel.projects) { project in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(project.displayTitle)
                            .font(.headline)
                            .lineLimit(1)
                        Text("\(project.chapters.count) chapters • \(DurationFormatter.clock(project.duration))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(project.id)
                }
            }

            Section("Resumable") {
                if appModel.savedProjectStatuses.isEmpty {
                    Text("No saved projects yet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(appModel.savedProjectStatuses) { saved in
                        Button {
                            appModel.loadSavedProjectStatus(saved)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "clock.arrow.circlepath")
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(saved.title)
                                        .font(.subheadline.weight(.semibold))
                                        .lineLimit(1)
                                    Text("\(saved.chapterCount) chapters • \(DurationFormatter.clock(saved.duration))")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(role: .destructive) {
                                appModel.deleteSavedProjectStatus(saved)
                            } label: {
                                Label("Remove Saved Status", systemImage: "trash")
                            }
                        }
                    }
                }

                Button {
                    appModel.refreshSavedProjectStatuses()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .font(.caption)
            }

            Section("Batch Queue") {
                if !appModel.jobs.isEmpty {
                    HStack {
                        Button {
                            appModel.startQueue()
                        } label: {
                            Label(appModel.isQueueRunning ? "Queue Running" : "Run Queue", systemImage: "play.fill")
                        }
                        .disabled(appModel.isQueueRunning)

                        Button {
                            appModel.cancelQueue()
                        } label: {
                            Label("Cancel", systemImage: "stop.fill")
                        }
                        .disabled(!appModel.isQueueRunning)
                    }
                }

                ForEach(appModel.jobs) { job in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(job.project.displayTitle).lineLimit(1)
                            Spacer()
                            Text(job.status.rawValue).foregroundStyle(.secondary)
                        }
                        ProgressView(value: job.progress)
                        if let remaining = job.estimatedRemaining, job.status == .running {
                            Text("About \(DurationFormatter.clock(remaining)) remaining")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                Button {
                    appModel.importFolder()
                } label: {
                    Label("Import Folder", systemImage: "folder.badge.plus")
                }
                Button {
                    appModel.importAudioFiles()
                } label: {
                    Label("Import Files", systemImage: "waveform.badge.plus")
                }
            }
            .buttonStyle(.bordered)
            .padding()
        }
    }
}
