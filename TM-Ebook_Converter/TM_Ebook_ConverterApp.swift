//
//  TM_Ebook_ConverterApp.swift
//  TM-Ebook_Converter
//
//  Created by techmore on 5/15/26.
//

import SwiftUI

@main
struct TM_Ebook_ConverterApp: App {
    @StateObject private var appModel = AppViewModel()

    var body: some Scene {
        WindowGroup {
            AppRootView()
                .environmentObject(appModel)
                .frame(minWidth: 1180, minHeight: 760)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Open Folder...") {
                    appModel.importFolder()
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])

                Button("Open Audio Files...") {
                    appModel.importAudioFiles()
                }
                .keyboardShortcut("o", modifiers: .command)

                Button("Chapter Single Audio File...") {
                    appModel.importSingleFileForChaptering()
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])

                Divider()

                Button("Save Project...") {
                    appModel.saveProject()
                }
                .keyboardShortcut("s", modifiers: .command)

                Button("Save Project Status") {
                    appModel.saveProjectStatus()
                }
                .keyboardShortcut("s", modifiers: [.command, .option])

                Button("Restore Saved Status...") {
                    appModel.loadProjectStatus()
                }
                .keyboardShortcut("r", modifiers: [.command, .option])

                Button("Load Project...") {
                    appModel.loadProject()
                }
                .keyboardShortcut("o", modifiers: [.command, .option])
            }
        }

        Settings {
            SettingsView()
                .environmentObject(appModel)
                .frame(width: 560)
                .padding()
        }

        MenuBarExtra("M4B Forge", systemImage: "waveform.badge.plus") {
            Button("Convert Current Project") {
                Task { await appModel.convertSelectedProject() }
            }
            .disabled(appModel.selectedProject == nil)

            Button("Open M4B Forge") {
                NSApp.activate(ignoringOtherApps: true)
            }

            Divider()

            Button("Quit") {
                NSApp.terminate(nil)
            }
        }
    }
}
