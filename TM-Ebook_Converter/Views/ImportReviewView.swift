import SwiftUI

struct ImportReviewView: View {
    @EnvironmentObject private var appModel: AppViewModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            actionBar
            Divider()
            ScrollView {
                VStack(spacing: 14) {
                    table
                        .frame(minHeight: 180, idealHeight: 220, maxHeight: 260)
                    templateEditor
                }
                .padding(.vertical, 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 18) {
            Image(systemName: "tray.and.arrow.down.fill")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 56)

            VStack(alignment: .leading, spacing: 8) {
                Text("Review Import")
                    .font(.largeTitle.weight(.semibold))
                Text("M4B Forge detected likely audiobook projects. Approve only what you want to load; files stay on disk and are processed one at a time.")
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 10) {
                Toggle("Auto-approve future drops", isOn: $appModel.autoApproveImports)
                    .toggleStyle(.switch)

                Button {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    if panel.runModal() == .OK {
                        SecurityScopedBookmarkStore.persistAccess(for: panel.urls)
                        appModel.defaults.outputFolderURL = panel.url
                    }
                } label: {
                    Label("Export Folder", systemImage: "folder")
                }

                Text(appModel.defaults.outputFolderURL?.path ?? "Exports to Music by default")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: 260, alignment: .trailing)
            }
        }
        .padding(24)
    }

    private var table: some View {
        Table(appModel.importCandidates) {
            TableColumn("") { candidate in
                Toggle("", isOn: Binding(
                    get: { candidate.isSelected },
                    set: { appModel.setImportCandidateSelection(candidate.id, isSelected: $0) }
                ))
                .labelsHidden()
                .disabled(candidate.audioFiles.isEmpty)
            }
            .width(36)

            TableColumn("Name") { candidate in
                VStack(alignment: .leading, spacing: 4) {
                    Text(candidate.title)
                        .font(.headline)
                    Text(candidate.rootURL.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            TableColumn("Type") { candidate in
                Label(candidate.kind.rawValue, systemImage: icon(for: candidate.kind))
            }
            .width(min: 120, ideal: 140)

            TableColumn("Files") { candidate in
                Text("\(candidate.fileCount)")
                    .monospacedDigit()
            }
            .width(70)

            TableColumn("Cover") { candidate in
                HStack(spacing: 8) {
                    if let cover = candidate.coverArtURL {
                        CoverThumb(url: cover)
                    } else {
                        Image(systemName: "photo")
                            .foregroundStyle(.secondary)
                            .frame(width: 34, height: 34)
                    }

                    Button {
                        appModel.chooseCoverArt(for: candidate.id)
                    } label: {
                        Image(systemName: candidate.coverArtURL == nil ? "plus" : "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.borderless)
                    .disabled(candidate.audioFiles.isEmpty)
                    .help(candidate.coverArtURL == nil ? "Choose cover art" : "Replace cover art")

                    if candidate.coverArtURL != nil {
                        Button {
                            appModel.setCoverArt(nil, for: candidate.id)
                        } label: {
                            Image(systemName: "xmark.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove cover art")
                    }
                }
            }
            .width(120)

            TableColumn("Size") { candidate in
                Text(candidate.sizeDescription)
                    .monospacedDigit()
            }
            .width(110)

            TableColumn("Status") { candidate in
                VStack(alignment: .leading, spacing: 4) {
                    Text(candidate.status.rawValue)
                        .foregroundStyle(candidate.status == .warning ? .orange : .secondary)
                    if !candidate.chapterDrafts.isEmpty {
                        Text("\(candidate.chapterDrafts.count) template chapter\(candidate.chapterDrafts.count == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(.tint)
                    }
                    ForEach(candidate.warnings, id: \.self) { warning in
                        Text(warning)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .width(min: 180, ideal: 260)
        }
        .padding(.horizontal)
    }

    private var templateEditor: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(appModel.importCandidates.filter(\.supportsChapterTemplate)) { candidate in
                    ImportChapterTemplateCard(candidate: candidate)
                        .environmentObject(appModel)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
        }
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.65))
    }

    private var actionBar: some View {
        HStack(spacing: 12) {
            let selected = appModel.importCandidates.filter { $0.isSelected && !$0.audioFiles.isEmpty }
            let selectedBytes = selected.map(\.totalBytes).reduce(0, +)
            Text("\(selected.count) selected • \(ByteCountFormatter.string(fromByteCount: selectedBytes, countStyle: .file))")
                .foregroundStyle(.secondary)

            Spacer()

            Button("Cancel") {
                appModel.clearImportReview()
            }

            Button {
                for candidate in appModel.importCandidates {
                    appModel.setImportCandidateSelection(candidate.id, isSelected: candidate.audioFiles.isEmpty ? false : true)
                }
            } label: {
                Label("Select All", systemImage: "checklist.checked")
            }

            Button {
                Task { await appModel.approveSelectedImportCandidates() }
            } label: {
                Label("Approve Selected", systemImage: "checkmark.circle.fill")
            }

            Button {
                Task {
                    if appModel.ensureDefaultOutputFolderSelected() {
                        await appModel.approveSelectedImportCandidates(addToQueue: true)
                        await appModel.runQueue()
                    }
                }
            } label: {
                Label("Approve + Queue", systemImage: "play.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(selected.isEmpty)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private func icon(for kind: ImportCandidate.Kind) -> String {
        switch kind {
        case .audiobookFolder:
            return "folder.fill"
        case .audioFiles:
            return "square.stack.3d.up.fill"
        case .singleAudioFile:
            return "waveform"
        case .unsupported:
            return "exclamationmark.triangle"
        }
    }
}

private struct CoverThumb: View {
    let url: URL

    var body: some View {
        if let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay {
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(.quaternary)
                }
        } else {
            Image(systemName: "photo.badge.exclamationmark")
                .foregroundStyle(.orange)
                .frame(width: 34, height: 34)
        }
    }
}

private struct ImportChapterTemplateCard: View {
    @EnvironmentObject private var appModel: AppViewModel
    let candidate: ImportCandidate
    @StateObject private var audition = AudiobookAuditionController()
    @State private var transitionLeadIn: TimeInterval = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Chapter Template", systemImage: "list.bullet.rectangle")
                    .font(.headline)
                Spacer()
                Menu {
                    ForEach(ChapterTemplateKind.allCases) { template in
                        Button(template.rawValue) {
                            appModel.applyChapterTemplate(template, to: candidate.id)
                        }
                    }
                    Divider()
                    Button("Import JSON/CSV Chapters...") {
                        appModel.importChapterFile(for: candidate.id)
                    }
                    Divider()
                    Button("Clear Template") {
                        appModel.clearChapterTemplate(for: candidate.id)
                    }
                } label: {
                    Label("Apply", systemImage: "wand.and.sparkles")
                }
            }

            Text(candidate.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)

            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    if candidate.chapterDrafts.isEmpty {
                        Text("Apply a starter template or add sections manually before approval.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(height: 44, alignment: .topLeading)
                    } else {
                        auditionControls
                        ImportScrubTimeline(candidate: candidate, audition: audition)

                        ScrollView {
                            LazyVStack(spacing: 6) {
                                ForEach(candidate.chapterDrafts) { draft in
                                    ChapterDraftRow(
                                        candidateID: candidate.id,
                                        draft: draft,
                                        play: {
                                            play(from: draft)
                                        },
                                        playTransition: {
                                            playTransition(after: draft)
                                        },
                                        setFromPlayhead: {
                                            let playhead = audition.currentTime
                                            appModel.updateChapterDraft(
                                                candidateID: candidate.id,
                                                draftID: draft.id,
                                                startTime: playhead
                                            )
                                            return playhead
                                        },
                                        hasNextDraft: hasNextDraft(after: draft)
                                    )
                                }
                            }
                            .padding(.trailing, 4)
                        }
                        .frame(minHeight: 160, maxHeight: 360)
                    }

                    HStack {
                        Button {
                            appModel.addChapterDraft(to: candidate.id)
                        } label: {
                            Label("Add Section", systemImage: "plus")
                        }
                        Button {
                            appModel.importChapterFile(for: candidate.id)
                        } label: {
                            Label("Import JSON/CSV", systemImage: "doc.badge.plus")
                        }
                        Spacer()
                        Text(candidate.chapterDrafts.isEmpty ? "No template" : "\(candidate.chapterDrafts.count) editable sections")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 480, alignment: .topLeading)

                ImportBookDetailsPanel(candidate: candidate)
                    .frame(width: 330, alignment: .topLeading)
            }
        }
        .padding(12)
        .frame(width: 880, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(.quaternary)
        }
        .onDisappear {
            audition.stop()
        }
    }

    private var auditionControls: some View {
        HStack(spacing: 8) {
            Label("Audition", systemImage: "headphones")
                .font(.caption.weight(.semibold))

            Text(audition.nowPlaying)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Text("MP3 \(DurationFormatter.positional(audition.currentTime))")
                .font(.system(.caption, design: .monospaced).weight(.semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 5))

            Spacer()

            Picker("Lead-in", selection: $transitionLeadIn) {
                Text("5").tag(TimeInterval(5))
                Text("10").tag(TimeInterval(10))
            }
            .pickerStyle(.segmented)
            .frame(width: 76)

            Picker("Speed", selection: $audition.playbackRate) {
                Text("1x").tag(Float(1.0))
                Text("1.25x").tag(Float(1.25))
                Text("1.5x").tag(Float(1.5))
                Text("1.75x").tag(Float(1.75))
                Text("2x").tag(Float(2.0))
            }
            .pickerStyle(.segmented)
            .frame(width: 174)

            Button {
                audition.mode == .paused ? audition.resume() : audition.pause()
            } label: {
                Image(systemName: audition.mode == .paused ? "play.fill" : "pause.fill")
            }
            .disabled(audition.mode == .stopped)
            .buttonStyle(.borderless)
            .help(audition.mode == .paused ? "Resume" : "Pause")

            Button {
                audition.stop()
            } label: {
                Image(systemName: "stop.fill")
            }
            .disabled(audition.mode == .stopped)
            .buttonStyle(.borderless)
            .help("Stop")
        }
        .padding(8)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 7))
    }

    private func play(from draft: ChapterDraft) {
        guard let url = candidate.audioFiles.first else { return }
        audition.playSingleFile(url: url, startTime: draft.startTime, label: "Playing \(draft.title)", totalDuration: candidateDurationEstimate)
    }

    private func playTransition(after draft: ChapterDraft) {
        guard let url = candidate.audioFiles.first,
              let next = nextDraft(after: draft)
        else { return }
        audition.playSingleFile(
            url: url,
            startTime: max(0, next.startTime - transitionLeadIn),
            label: "\(draft.title) to \(next.title)",
            totalDuration: candidateDurationEstimate
        )
    }

    private var candidateDurationEstimate: TimeInterval {
        candidate.chapterDrafts.map(\.startTime).max().map { $0 + 600 } ?? 0
    }

    private func hasNextDraft(after draft: ChapterDraft) -> Bool {
        nextDraft(after: draft) != nil
    }

    private func nextDraft(after draft: ChapterDraft) -> ChapterDraft? {
        let sorted = candidate.chapterDrafts.sorted { $0.startTime < $1.startTime }
        guard let index = sorted.firstIndex(where: { $0.id == draft.id }),
              sorted.indices.contains(index + 1)
        else { return nil }
        return sorted[index + 1]
    }
}

private struct ImportMetadataDraftView: View {
    @EnvironmentObject private var appModel: AppViewModel
    let candidate: ImportCandidate

    var body: some View {
        DisclosureGroup {
            VStack(spacing: 8) {
                TextField("Book blurb / description", text: binding(\.description), axis: .vertical)
                    .lineLimit(2...4)
                HStack {
                    TextField("Genre", text: binding(\.genre))
                    TextField("Language", text: binding(\.language))
                }
                HStack {
                    TextField("Publisher", text: binding(\.publisher))
                    TextField("ISBN", text: binding(\.isbn))
                }
                HStack {
                    TextField("Series", text: binding(\.series))
                    TextField("Series #", text: binding(\.seriesNumber))
                        .frame(width: 84)
                }
                TextField("Copyright", text: binding(\.copyright))
            }
            .textFieldStyle(.roundedBorder)
            .padding(.top, 6)
        } label: {
            Label("Book Details", systemImage: "text.book.closed")
                .font(.subheadline.weight(.semibold))
        }
    }

    private func binding(_ keyPath: WritableKeyPath<BookMetadataDraft, String>) -> Binding<String> {
        Binding(
            get: { candidate.metadataDraft[keyPath: keyPath] },
            set: { value in
                appModel.updateMetadataDraft(candidate.id) { draft in
                    draft[keyPath: keyPath] = value
                }
            }
        )
    }
}

private struct ImportScrubTimeline: View {
    let candidate: ImportCandidate
    @ObservedObject var audition: AudiobookAuditionController
    @State private var hoverTime: TimeInterval?
    @State private var waveformSamples: [Float] = []
    @State private var jumpTimeText = "00:00:00"

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Audio Timeline", systemImage: "waveform")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(DurationFormatter.positional(audition.currentTime)) / \(DurationFormatter.positional(timelineDuration))")
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                if let hoverTime {
                    Text(DurationFormatter.positional(hoverTime))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            GeometryReader { proxy in
                ZStack(alignment: .topLeading) {
                    ImportScrubTimelineCanvas(
                        duration: timelineDuration,
                        playheadTime: audition.currentTime,
                        hoverTime: hoverTime,
                        waveformSamples: waveformSamples,
                        drafts: candidate.chapterDrafts
                    )
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let scrubTime = time(for: value.location.x, width: proxy.size.width)
                            hoverTime = scrubTime
                            play(at: scrubTime, pauseAfterSeek: true)
                        }
                        .onEnded { value in
                            let scrubTime = time(for: value.location.x, width: proxy.size.width)
                            play(at: scrubTime, pauseAfterSeek: true)
                            hoverTime = nil
                        }
                )
            }
            .frame(height: 118)

            HStack {
                Text("00:00:00")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)

                Spacer()

                Text(DurationFormatter.positional(timelineDuration))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            HStack {
                TextField("HH:MM:SS", text: $jumpTimeText)
                    .monospacedDigit()
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 94)
                    .onSubmit { jumpToTypedTime(play: false) }

                Button {
                    jumpToTypedTime(play: false)
                } label: {
                    Label("Jump", systemImage: "scope")
                }

                Button {
                    jumpToTypedTime(play: true)
                } label: {
                    Label("Play Time", systemImage: "play.fill")
                }

                Button {
                    play(at: audition.currentTime, pauseAfterSeek: false)
                } label: {
                    Label("Play From Playhead", systemImage: "play.fill")
                }
                .disabled(candidate.audioFiles.first == nil)

                Text("Drag the waveform or type an exact time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()
            }
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .task(id: candidate.audioFiles.first) {
            guard let url = candidate.audioFiles.first else { return }
            let samples = try? await Task.detached(priority: .utility) {
                try WaveformAnalyzer.samples(for: url, targetSampleCount: 700)
            }.value
            waveformSamples = samples ?? []
        }
    }

    private var timelineDuration: TimeInterval {
        max(candidate.chapterDrafts.map(\.startTime).max().map { $0 + 600 } ?? 3_600, audition.totalDuration)
    }

    private func time(for x: CGFloat, width: CGFloat) -> TimeInterval {
        guard width > 0 else { return 0 }
        let fraction = max(0, min(1, x / width))
        return timelineDuration * TimeInterval(fraction)
    }

    private func play(at time: TimeInterval, pauseAfterSeek: Bool) {
        guard let url = candidate.audioFiles.first else { return }
        audition.playSingleFile(
            url: url,
            startTime: time,
            label: "Scrubbed to \(DurationFormatter.positional(time))",
            totalDuration: timelineDuration
        )
        if pauseAfterSeek {
            audition.pause()
        }
    }

    private func jumpToTypedTime(play shouldPlay: Bool) {
        let target = parseTime(jumpTimeText) ?? audition.currentTime
        play(at: max(0, min(target, timelineDuration)), pauseAfterSeek: !shouldPlay)
    }

    private func parseTime(_ text: String) -> TimeInterval? {
        let pieces = text.split(separator: ":").compactMap { Double($0) }
        guard pieces.count == 3 else { return nil }
        return pieces[0] * 3600 + pieces[1] * 60 + pieces[2]
    }
}

private struct ImportScrubTimelineCanvas: View {
    let duration: TimeInterval
    let playheadTime: TimeInterval
    let hoverTime: TimeInterval?
    let waveformSamples: [Float]
    let drafts: [ChapterDraft]

    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            let baseline = size.height * 0.52
            context.fill(Path(roundedRect: rect, cornerRadius: 8), with: .color(Color(nsColor: .controlBackgroundColor)))

            let samples = waveformSamples.isEmpty ? placeholderSamples(count: max(80, Int(size.width / 5))) : waveformSamples
            for index in samples.indices {
                let x = CGFloat(index) / CGFloat(samples.count) * size.width
                let height = 12 + max(0.04, CGFloat(samples[index])) * (size.height * 0.58)
                let barRect = CGRect(x: x, y: baseline - height / 2, width: max(1.5, size.width / CGFloat(samples.count) - 1), height: height)
                context.fill(Path(roundedRect: barRect, cornerRadius: 1.5), with: .color(.accentColor.opacity(waveformSamples.isEmpty ? 0.22 : 0.48)))
            }

            for draft in drafts {
                guard duration > 0 else { continue }
                let x = size.width * CGFloat(draft.startTime / duration)
                var marker = Path()
                marker.move(to: CGPoint(x: x, y: 0))
                marker.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(marker, with: .color(.blue.opacity(0.55)), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
            }

            if let hoverTime, duration > 0 {
                let x = size.width * CGFloat(hoverTime / duration)
                var hover = Path()
                hover.move(to: CGPoint(x: x, y: 0))
                hover.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(hover, with: .color(.primary.opacity(0.45)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }

            if duration > 0 {
                let x = size.width * CGFloat(max(0, min(playheadTime, duration)) / duration)
                var playhead = Path()
                playhead.move(to: CGPoint(x: x, y: 0))
                playhead.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(playhead, with: .color(.red), style: StrokeStyle(lineWidth: 2))
                context.fill(Path(ellipseIn: CGRect(x: x - 5, y: 8, width: 10, height: 10)), with: .color(.red))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(.quaternary)
        }
    }

    private func placeholderSamples(count: Int) -> [Float] {
        (0..<count).map { index in
            Float(0.18 + (Double((index * 37) % 91) / 91.0) * 0.72)
        }
    }
}

private struct ImportBookDetailsPanel: View {
    @EnvironmentObject private var appModel: AppViewModel
    let candidate: ImportCandidate

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Book Details", systemImage: "text.book.closed")
                .font(.headline)

            HStack(alignment: .top, spacing: 12) {
                CoverThumbLarge(url: candidate.coverArtURL)

                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        appModel.chooseCoverArt(for: candidate.id)
                    } label: {
                        Label(candidate.coverArtURL == nil ? "Add Cover" : "Replace Cover", systemImage: "photo.badge.plus")
                    }

                    if candidate.coverArtURL != nil {
                        Button {
                            appModel.setCoverArt(nil, for: candidate.id)
                        } label: {
                            Label("Remove", systemImage: "xmark.circle")
                        }
                    }
                }
                .buttonStyle(.bordered)
            }

            TextField("Book blurb / description", text: binding(\.description), axis: .vertical)
                .lineLimit(5...8)
                .textFieldStyle(.roundedBorder)

            HStack {
                TextField("Genre", text: binding(\.genre))
                TextField("Language", text: binding(\.language))
            }
            HStack {
                TextField("Publisher", text: binding(\.publisher))
                TextField("ISBN", text: binding(\.isbn))
            }
            HStack {
                TextField("Series", text: binding(\.series))
                TextField("Series #", text: binding(\.seriesNumber))
                    .frame(width: 84)
            }
            TextField("Copyright", text: binding(\.copyright))
        }
        .textFieldStyle(.roundedBorder)
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private func binding(_ keyPath: WritableKeyPath<BookMetadataDraft, String>) -> Binding<String> {
        Binding(
            get: { candidate.metadataDraft[keyPath: keyPath] },
            set: { value in
                appModel.updateMetadataDraft(candidate.id) { draft in
                    draft[keyPath: keyPath] = value
                }
            }
        )
    }
}

private struct CoverThumbLarge: View {
    let url: URL?

    var body: some View {
        Group {
            if let url, let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Rectangle()
                        .fill(Color(nsColor: .controlBackgroundColor))
                    Image(systemName: "book.closed")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 96, height: 128)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(.quaternary)
        }
    }
}

private struct ChapterDraftRow: View {
    @EnvironmentObject private var appModel: AppViewModel
    let candidateID: ImportCandidate.ID
    let draft: ChapterDraft
    let play: () -> Void
    let playTransition: () -> Void
    let setFromPlayhead: () -> TimeInterval
    let hasNextDraft: Bool
    @State private var title: String
    @State private var timeText: String

    init(
        candidateID: ImportCandidate.ID,
        draft: ChapterDraft,
        play: @escaping () -> Void,
        playTransition: @escaping () -> Void,
        setFromPlayhead: @escaping () -> TimeInterval,
        hasNextDraft: Bool
    ) {
        self.candidateID = candidateID
        self.draft = draft
        self.play = play
        self.playTransition = playTransition
        self.setFromPlayhead = setFromPlayhead
        self.hasNextDraft = hasNextDraft
        _title = State(initialValue: draft.title)
        _timeText = State(initialValue: DurationFormatter.positional(draft.startTime))
    }

    var body: some View {
        HStack(spacing: 8) {
            Button(action: play) {
                Label("Play", systemImage: "play.fill")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Play from this section")

            Button(action: playTransition) {
                Label("Test", systemImage: "arrow.right.to.line.compact")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!hasNextDraft)
            .help("Play into the next section")

            Button {
                let playhead = setFromPlayhead()
                timeText = DurationFormatter.positional(playhead)
            } label: {
                Label("Mark", systemImage: "waveform.and.magnifyingglass")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Set this section start from the current playhead time")

            TextField("Section", text: $title)
                .textFieldStyle(.roundedBorder)
                .onSubmit { commit() }

            TextField("HH:MM:SS", text: $timeText)
                .monospacedDigit()
                .textFieldStyle(.roundedBorder)
                .frame(width: 88)
                .onSubmit { commit() }

            Button {
                appModel.removeChapterDraft(candidateID: candidateID, draftID: draft.id)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Remove section")
        }
        .onChange(of: draft.title) { _, value in
            guard value != title else { return }
            title = value
        }
        .onChange(of: draft.startTime) { _, value in
            let formatted = DurationFormatter.positional(value)
            guard formatted != timeText else { return }
            timeText = formatted
        }
    }

    private func commit() {
        appModel.updateChapterDraft(
            candidateID: candidateID,
            draftID: draft.id,
            title: title,
            startTime: parseTime(timeText)
        )
    }

    private func parseTime(_ text: String) -> TimeInterval? {
        let pieces = text.split(separator: ":").compactMap { Double($0) }
        guard pieces.count == 3 else { return nil }
        return pieces[0] * 3600 + pieces[1] * 60 + pieces[2]
    }
}
