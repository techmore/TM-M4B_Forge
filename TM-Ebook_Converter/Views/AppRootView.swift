import SwiftUI
import UniformTypeIdentifiers

struct AppRootView: View {
    @EnvironmentObject private var appModel: AppViewModel

    var body: some View {
        NavigationSplitView {
            LibrarySidebar()
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 340)
        } detail: {
            if !appModel.importCandidates.isEmpty {
                ImportReviewView()
            } else if appModel.selectedProject != nil {
                ProjectDetailView()
            } else {
                DropLandingView()
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            Task { await handleDrop(providers) }
            return true
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) async {
        var urls: [URL] = []
        for provider in providers {
            if let url = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? URL {
                urls.append(url)
            } else if let data = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) {
                urls.append(url)
            }
        }
        await MainActor.run {
            SecurityScopedBookmarkStore.persistAccess(for: urls)
            appModel.prepareImportReview(urls)
        }
    }
}
