import AVFoundation
import Combine
import SwiftUI

struct ProjectDetailView: View {
    @EnvironmentObject private var appModel: AppViewModel

    var body: some View {
        VStack(spacing: 0) {
            ProjectToolbar()
            Divider()
            HSplitView {
                ChapterListView()
                    .frame(minWidth: 420, idealWidth: 560)

                VStack(spacing: 0) {
                    MetadataView()
                    Divider()
                    CoverAndOutputView()
                    Divider()
                    LogView()
                }
                .frame(minWidth: 420)
            }
        }
    }
}

struct ProjectToolbar: View {
    @EnvironmentObject private var appModel: AppViewModel

    var body: some View {
        HStack(spacing: 12) {
            if let project = appModel.selectedProject {
                VStack(alignment: .leading) {
                    Text(project.displayTitle)
                        .font(.title2.weight(.semibold))
                    HStack(spacing: 10) {
                        Label(project.sourceMode == .singleFile ? "Single source" : "Chapter files", systemImage: project.sourceMode == .singleFile ? "waveform" : "square.stack.3d.up")
                        Text("\(project.chapters.count) chapters")
                        Text(DurationFormatter.positional(project.duration))
                    }
                    .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button {
                appModel.enqueueSelectedProject()
            } label: {
                Label("Queue", systemImage: "text.badge.plus")
            }

            Button {
                appModel.saveProjectStatus()
            } label: {
                Label("Save Status", systemImage: "tray.and.arrow.down")
            }

            Button {
                appModel.enqueueSelectedProject()
                appModel.startQueue()
            } label: {
                Label("Convert to M4B", systemImage: "hammer.fill")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}

struct ChapterListView: View {
    @EnvironmentObject private var appModel: AppViewModel
    @StateObject private var audition = AudiobookAuditionController()
    @State private var splitMinutes = 10
    @State private var boundaryText = "00:00:00"
    @State private var transitionLeadIn: TimeInterval = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Chapters")
                        .font(.headline)
                    Spacer()
                    if appModel.selectedProject?.sourceMode == .singleFile {
                        Button {
                            appModel.addChapterBoundary(at: parseTime(boundaryText) ?? 0)
                        } label: {
                            Label("Add Boundary", systemImage: "plus")
                        }
                    }
                }

                if let project = appModel.selectedProject {
                    AuditionTransportView(
                        project: project,
                        audition: audition,
                        transitionLeadIn: $transitionLeadIn
                    )
                }

                if appModel.selectedProject?.sourceMode == .singleFile {
                    SingleFileChapterTools(splitMinutes: $splitMinutes, boundaryText: $boundaryText)
                    if let project = appModel.selectedProject {
                        ChapterTimelineView(project: project, audition: audition)
                    }
                }
            }
            .padding()

            List {
                if let project = appModel.selectedProject {
                    ForEach(Array(project.chapters.enumerated()), id: \.element.id) { index, chapter in
                        ChapterRow(chapter: chapter) { title, start in
                            appModel.updateSelectedProject { project in
                                guard let index = project.chapters.firstIndex(where: { $0.id == chapter.id }) else { return }
                                project.chapters[index].title = title
                                project.chapters[index].manualStartTime = start
                            }
                        } preview: {
                            audition.playFromChapter(index: index, in: project)
                        } previewBoundary: {
                            audition.playTransition(afterChapterAt: index, in: project, leadIn: transitionLeadIn)
                        } setFromPlayhead: {
                            let playhead = audition.currentTime
                            appModel.updateSelectedProject { project in
                                guard let index = project.chapters.firstIndex(where: { $0.id == chapter.id }) else { return }
                                project.chapters[index].manualStartTime = playhead
                                project.chapters[index].startTime = playhead
                            }
                            return playhead
                        } hasNextChapter: {
                            index < project.chapters.index(before: project.chapters.endIndex)
                        }
                    }
                    .onMove(perform: appModel.moveChapters)
                    .onDelete(perform: appModel.removeChapters)
                }
            }
        }
        .onDisappear {
            audition.stop()
        }
    }

    private func parseTime(_ text: String) -> TimeInterval? {
        let pieces = text.split(separator: ":").compactMap { Double($0) }
        guard pieces.count == 3 else { return nil }
        return pieces[0] * 3600 + pieces[1] * 60 + pieces[2]
    }
}

@MainActor
final class AudiobookAuditionController: ObservableObject {
    enum Mode {
        case stopped
        case playing
        case paused
    }

    @Published private(set) var mode: Mode = .stopped
    @Published private(set) var nowPlaying = "Stopped"
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var totalDuration: TimeInterval = 0
    @Published var playbackRate: Float = 1.0 {
        didSet {
            if mode == .playing {
                player?.rate = playbackRate
            }
        }
    }

    private var player: AVQueuePlayer?
    private var timeObserver: Any?
    private var itemOffsets: [ObjectIdentifier: TimeInterval] = [:]

    func playFromChapter(index: Int, in project: AudiobookProject) {
        guard project.chapters.indices.contains(index) else { return }
        stop()
        totalDuration = project.timelineDuration

        if project.sourceMode == .singleFile {
            guard let sourceURL = project.singleSourceURL ?? project.chapters.first?.sourceURL else { return }
            let item = AVPlayerItem(url: sourceURL)
            let queue = AVQueuePlayer(items: [item])
            itemOffsets[ObjectIdentifier(item)] = 0
            player = queue
            seek(queue, to: project.chapters[index].effectiveStartTime)
        } else {
            let items = project.chapters[index...].map { chapter in
                let item = AVPlayerItem(url: chapter.sourceURL)
                itemOffsets[ObjectIdentifier(item)] = chapter.effectiveStartTime
                return item
            }
            player = AVQueuePlayer(items: items)
        }

        nowPlaying = "Playing \(project.chapters[index].title)"
        installTimeObserver()
        player?.rate = playbackRate
        mode = .playing
    }

    func playSingleFile(url: URL, startTime: TimeInterval, label: String, totalDuration: TimeInterval = 0) {
        stop()
        let item = AVPlayerItem(url: url)
        let queue = AVQueuePlayer(items: [item])
        itemOffsets[ObjectIdentifier(item)] = 0
        player = queue
        self.totalDuration = totalDuration
        seek(queue, to: max(0, startTime))
        nowPlaying = label
        installTimeObserver()
        player?.rate = playbackRate
        mode = .playing
    }

    func playTransition(afterChapterAt index: Int, in project: AudiobookProject, leadIn: TimeInterval) {
        guard project.chapters.indices.contains(index),
              project.chapters.indices.contains(index + 1)
        else { return }
        stop()
        totalDuration = project.timelineDuration

        let current = project.chapters[index]
        let next = project.chapters[index + 1]

        if project.sourceMode == .singleFile {
            guard let sourceURL = project.singleSourceURL ?? project.chapters.first?.sourceURL else { return }
            let item = AVPlayerItem(url: sourceURL)
            let queue = AVQueuePlayer(items: [item])
            itemOffsets[ObjectIdentifier(item)] = 0
            player = queue
            seek(queue, to: max(0, next.effectiveStartTime - leadIn))
        } else {
            let items = project.chapters[index...].map { chapter in
                let item = AVPlayerItem(url: chapter.sourceURL)
                itemOffsets[ObjectIdentifier(item)] = chapter.effectiveStartTime
                return item
            }
            let queue = AVQueuePlayer(items: items)
            player = queue
            seek(queue, to: max(0, current.duration - leadIn))
        }

        nowPlaying = "Transition: \(current.title) to \(next.title)"
        installTimeObserver()
        player?.rate = playbackRate
        mode = .playing
    }

    func pause() {
        player?.pause()
        mode = .paused
    }

    func resume() {
        player?.rate = playbackRate
        mode = .playing
    }

    func scrub(to time: TimeInterval, in project: AudiobookProject, autoplay: Bool = false) {
        let boundedTime = max(0, min(time, project.timelineDuration))

        if project.sourceMode == .singleFile {
            guard let sourceURL = project.singleSourceURL ?? project.chapters.first?.sourceURL else { return }
            if player == nil {
                playSingleFile(url: sourceURL, startTime: boundedTime, label: "Scrubbing", totalDuration: project.timelineDuration)
                if !autoplay { pause() }
                return
            }
            if let player {
                seek(player, to: boundedTime)
            }
        } else if let chapterIndex = project.chapters.lastIndex(where: { $0.effectiveStartTime <= boundedTime }) {
            let chapter = project.chapters[chapterIndex]
            let offset = max(0, boundedTime - chapter.effectiveStartTime)
            if player == nil || mode == .stopped {
                playFromChapter(index: chapterIndex, in: project)
            }
            if let player {
                seek(player, to: offset)
            }
        }

        currentTime = boundedTime
        nowPlaying = "Scrubbed to \(DurationFormatter.positional(boundedTime))"
        if autoplay {
            resume()
        } else {
            pause()
        }
    }

    func stop() {
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        player?.pause()
        player?.removeAllItems()
        player = nil
        itemOffsets.removeAll()
        currentTime = 0
        totalDuration = 0
        nowPlaying = "Stopped"
        mode = .stopped
    }

    private func seek(_ player: AVQueuePlayer, to seconds: TimeInterval) {
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func installTimeObserver() {
        guard let player else { return }
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
            queue: .main
        ) { [weak self, weak player] time in
            Task { @MainActor [weak self, weak player] in
                guard let self, let player else { return }
                let offset = player.currentItem.map { self.itemOffsets[ObjectIdentifier($0)] ?? 0 } ?? 0
                self.currentTime = offset + max(0, time.seconds.isFinite ? time.seconds : 0)
            }
        }
    }
}

private struct AuditionTransportView: View {
    let project: AudiobookProject
    @ObservedObject var audition: AudiobookAuditionController
    @Binding var transitionLeadIn: TimeInterval

    var body: some View {
        HStack(spacing: 10) {
            Label("Audition", systemImage: "headphones")
                .font(.headline)

            Text(audition.nowPlaying)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Text(timeLabel)
                .font(.system(.caption, design: .monospaced).weight(.semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))

            Spacer()

            Picker("Transition lead-in", selection: $transitionLeadIn) {
                Text("5 sec").tag(TimeInterval(5))
                Text("10 sec").tag(TimeInterval(10))
            }
            .pickerStyle(.segmented)
            .frame(width: 132)

            Picker("Speed", selection: $audition.playbackRate) {
                Text("1x").tag(Float(1.0))
                Text("1.25x").tag(Float(1.25))
                Text("1.5x").tag(Float(1.5))
                Text("1.75x").tag(Float(1.75))
                Text("2x").tag(Float(2.0))
            }
            .pickerStyle(.segmented)
            .frame(width: 212)

            Button {
                audition.mode == .paused ? audition.resume() : audition.pause()
            } label: {
                Image(systemName: audition.mode == .paused ? "play.fill" : "pause.fill")
            }
            .disabled(audition.mode == .stopped)
            .help(audition.mode == .paused ? "Resume" : "Pause")

            Button {
                audition.stop()
            } label: {
                Image(systemName: "stop.fill")
            }
            .disabled(audition.mode == .stopped)
            .help("Stop")
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private var timeLabel: String {
        let current = DurationFormatter.positional(audition.currentTime)
        guard audition.totalDuration > 0 else { return "MP3 \(current)" }
        return "MP3 \(current) / \(DurationFormatter.positional(audition.totalDuration))"
    }
}

private struct ChapterTimelineView: View {
    @EnvironmentObject private var appModel: AppViewModel
    let project: AudiobookProject
    @ObservedObject var audition: AudiobookAuditionController
    @State private var hoverTime: TimeInterval?
    @State private var waveformSamples: [Float] = []
    @State private var jumpTimeText = "00:00:00"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Label("Master Timeline", systemImage: "timeline.selection")
                        .font(.headline)
                    Text("Scrub to navigate long recordings, then place or drag chapter boundaries.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("Playhead \(DurationFormatter.positional(audition.currentTime)) / \(DurationFormatter.positional(project.timelineDuration))")
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                    .foregroundStyle(.primary)
                if let hoverTime {
                    Text(DurationFormatter.positional(hoverTime))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            GeometryReader { proxy in
                ZStack(alignment: .topLeading) {
                    TimelineCanvas(
                        project: project,
                        hoverTime: hoverTime,
                        playheadTime: audition.currentTime,
                        waveformSamples: waveformSamples
                    )

                    ForEach(Array(project.chapters.enumerated()), id: \.element.id) { index, chapter in
                        if project.timelineDuration > 0 {
                            TimelineHandle(
                                chapter: chapter,
                                isLocked: index == 0,
                                xPosition: xPosition(for: chapter.effectiveStartTime, width: proxy.size.width)
                            ) { x in
                                let time = time(for: x, width: proxy.size.width)
                                appModel.moveChapterBoundary(chapterID: chapter.id, to: time)
                            }
                        }
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let scrubTime = time(for: value.location.x, width: proxy.size.width)
                            hoverTime = scrubTime
                            audition.scrub(to: scrubTime, in: project)
                        }
                        .onEnded { value in
                            let scrubTime = time(for: value.location.x, width: proxy.size.width)
                            audition.scrub(to: scrubTime, in: project)
                            hoverTime = nil
                        }
                )
            }
            .frame(height: 236)

            HStack {
                Text("00:00:00")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(DurationFormatter.positional(project.timelineDuration))
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
                    appModel.addChapterBoundary(at: audition.currentTime)
                } label: {
                    Label("Add Boundary at Playhead", systemImage: "plus")
                }
                Button {
                    audition.resume()
                } label: {
                    Label("Play From Playhead", systemImage: "play.fill")
                }
                .disabled(audition.mode == .stopped)
                Spacer()
                Text("Drag inside the waveform to scrub. Drag pins to refine starts; the first pin stays locked.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .onChange(of: audition.currentTime) { _, value in
            jumpTimeText = DurationFormatter.positional(value)
        }
        .task(id: project.singleSourceURL ?? project.chapters.first?.sourceURL) {
            guard let url = project.singleSourceURL ?? project.chapters.first?.sourceURL else { return }
            let samples = try? await Task.detached(priority: .utility) {
                try WaveformAnalyzer.samples(for: url)
            }.value
            waveformSamples = samples ?? []
        }
    }

    private func xPosition(for time: TimeInterval, width: CGFloat) -> CGFloat {
        guard project.timelineDuration > 0 else { return 0 }
        return width * CGFloat(time / project.timelineDuration)
    }

    private func time(for x: CGFloat, width: CGFloat) -> TimeInterval {
        guard width > 0 else { return 0 }
        let fraction = max(0, min(1, x / width))
        return project.timelineDuration * TimeInterval(fraction)
    }

    private func jumpToTypedTime(play shouldPlay: Bool) {
        let target = parseTime(jumpTimeText) ?? audition.currentTime
        audition.scrub(to: max(0, min(target, project.timelineDuration)), in: project, autoplay: shouldPlay)
    }

    private func parseTime(_ text: String) -> TimeInterval? {
        let pieces = text.split(separator: ":").compactMap { Double($0) }
        guard pieces.count == 3 else { return nil }
        return pieces[0] * 3600 + pieces[1] * 60 + pieces[2]
    }
}

private struct TimelineCanvas: View {
    let project: AudiobookProject
    let hoverTime: TimeInterval?
    let playheadTime: TimeInterval
    let waveformSamples: [Float]

    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            let baseline = size.height * 0.52
            context.fill(Path(roundedRect: rect, cornerRadius: 8), with: .color(Color(nsColor: .controlBackgroundColor)))

            let visibleSamples = waveformSamples.isEmpty ? placeholderSamples(count: max(96, Int(size.width / 5))) : waveformSamples
            for index in visibleSamples.indices {
                let x = CGFloat(index) / CGFloat(visibleSamples.count) * size.width
                let normalized = max(0.04, CGFloat(visibleSamples[index]))
                let height = 18 + normalized * (size.height * 0.58)
                let barRect = CGRect(x: x, y: baseline - height / 2, width: max(1.5, size.width / CGFloat(visibleSamples.count) - 1), height: height)
                context.fill(Path(roundedRect: barRect, cornerRadius: 1.5), with: .color(.accentColor.opacity(waveformSamples.isEmpty ? 0.22 : 0.48)))
            }

            for chapter in project.chapters {
                guard project.timelineDuration > 0 else { continue }
                let startX = size.width * CGFloat(chapter.effectiveStartTime / project.timelineDuration)
                let endX = size.width * CGFloat(chapter.endTime / project.timelineDuration)
                let chapterRect = CGRect(x: startX, y: 0, width: max(1, endX - startX), height: size.height)
                context.fill(Path(chapterRect), with: .color(.accentColor.opacity(0.08)))
            }

            if let hoverTime, project.timelineDuration > 0 {
                let x = size.width * CGFloat(hoverTime / project.timelineDuration)
                var path = Path()
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(path, with: .color(.primary.opacity(0.55)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }

            if project.timelineDuration > 0 {
                let x = size.width * CGFloat(max(0, min(playheadTime, project.timelineDuration)) / project.timelineDuration)
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

private struct TimelineHandle: View {
    let chapter: Chapter
    let isLocked: Bool
    let xPosition: CGFloat
    let move: (CGFloat) -> Void

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: isLocked ? "lock.fill" : "line.3.horizontal.decrease.circle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(isLocked ? Color.secondary : Color.accentColor)
                .background(.background, in: Circle())
            Rectangle()
                .fill(isLocked ? Color.secondary : Color.accentColor)
                .frame(width: 2, height: 80)
            Text(DurationFormatter.positional(chapter.effectiveStartTime))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .fixedSize()
        }
        .position(x: xPosition, y: 58)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard !isLocked else { return }
                    move(xPosition + value.translation.width)
                }
        )
        .help(isLocked ? "First chapter starts at 00:00:00" : "Drag to move chapter boundary")
    }
}

private struct SingleFileChapterTools: View {
    @EnvironmentObject private var appModel: AppViewModel
    @Binding var splitMinutes: Int
    @Binding var boundaryText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Stepper(value: $splitMinutes, in: 1...120) {
                    Text("Split every \(splitMinutes) min")
                        .frame(width: 142, alignment: .leading)
                }
                Button {
                    appModel.splitSelectedProject(every: splitMinutes)
                } label: {
                    Label("Generate", systemImage: "wand.and.sparkles")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    appModel.importChapterFileForSelectedProject()
                } label: {
                    Label("Import JSON/CSV", systemImage: "doc.badge.plus")
                }

                Divider()

                TextField("HH:MM:SS", text: $boundaryText)
                    .monospacedDigit()
                    .frame(width: 92)
            }

            Text("For a single recording, chapter starts are boundaries inside the same source file. Rename them below, preview from each boundary, then convert without changing the original MP3.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

struct ChapterRow: View {
    let chapter: Chapter
    let update: (String, TimeInterval?) -> Void
    let preview: () -> Void
    let previewBoundary: () -> Void
    let setFromPlayhead: () -> TimeInterval
    let hasNextChapter: Bool
    @State private var title: String
    @State private var startText: String

    init(
        chapter: Chapter,
        update: @escaping (String, TimeInterval?) -> Void,
        preview: @escaping () -> Void,
        previewBoundary: @escaping () -> Void,
        setFromPlayhead: @escaping () -> TimeInterval,
        hasNextChapter: () -> Bool
    ) {
        self.chapter = chapter
        self.update = update
        self.preview = preview
        self.previewBoundary = previewBoundary
        self.setFromPlayhead = setFromPlayhead
        self.hasNextChapter = hasNextChapter()
        _title = State(initialValue: chapter.title)
        _startText = State(initialValue: DurationFormatter.positional(chapter.effectiveStartTime))
    }

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
            GridRow {
                Button(action: preview) {
                    Image(systemName: "play.fill")
                }
                .help("Preview chapter")

                Button(action: previewBoundary) {
                    Image(systemName: "arrow.right.to.line.compact")
                }
                .disabled(!hasNextChapter)
                .help("Preview the rollover into the next chapter")

                Button {
                    startText = DurationFormatter.positional(setFromPlayhead())
                } label: {
                    Image(systemName: "waveform.and.magnifyingglass")
                }
                .help("Set this chapter start from the current playhead time")

                TextField("Chapter title", text: $title)
                    .onSubmit { commit() }

                TextField("Start", text: $startText)
                    .frame(width: 86)
                    .monospacedDigit()
                    .onSubmit { commit() }

                Text(DurationFormatter.positional(chapter.duration))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            GridRow {
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                Text("\(chapter.fileName) • \(DurationFormatter.positional(chapter.effectiveStartTime)) to \(DurationFormatter.positional(chapter.endTime))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .gridCellColumns(5)
            }
        }
        .padding(.vertical, 6)
        .onChange(of: title) { _, _ in commit() }
    }

    private func commit() {
        update(title, parseTime(startText))
    }

    private func parseTime(_ text: String) -> TimeInterval? {
        let pieces = text.split(separator: ":").compactMap { Double($0) }
        guard pieces.count == 3 else { return nil }
        return pieces[0] * 3600 + pieces[1] * 60 + pieces[2]
    }
}

struct MetadataView: View {
    @EnvironmentObject private var appModel: AppViewModel

    var body: some View {
        Form {
            Section("Metadata") {
                editable("Title", \.title)
                editable("Author", \.author)
                editable("Narrator", \.narrator)
                editable("Album", \.album)
                editable("Genre", \.genre)
                Stepper(value: yearBinding, in: 1000...3000) {
                    Text("Year \(appModel.selectedProject?.year ?? 0)")
                }
                editable("Publisher", \.publisher)
                editable("ISBN", \.isbn)
                editable("Language", \.language)
                editable("Copyright", \.copyright)
                editable("Series", \.series)
                editable("Series #", \.seriesNumber)
                TextField("Description", text: descriptionBinding, axis: .vertical)
                    .lineLimit(3...6)
            }
        }
        .formStyle(.grouped)
    }

    private func editable(_ label: String, _ keyPath: WritableKeyPath<AudiobookProject, String>) -> some View {
        TextField(label, text: Binding(
            get: { appModel.selectedProject?[keyPath: keyPath] ?? "" },
            set: { value in appModel.updateSelectedProject { $0[keyPath: keyPath] = value } }
        ))
    }

    private var yearBinding: Binding<Int> {
        Binding(
            get: { appModel.selectedProject?.year ?? Calendar.current.component(.year, from: Date()) },
            set: { value in appModel.updateSelectedProject { $0.year = value } }
        )
    }

    private var descriptionBinding: Binding<String> {
        Binding(
            get: { appModel.selectedProject?.description ?? "" },
            set: { value in appModel.updateSelectedProject { $0.description = value } }
        )
    }
}

struct CoverAndOutputView: View {
    @EnvironmentObject private var appModel: AppViewModel

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            CoverPreview()

            Form {
                Section("Output") {
                    Picker("Bitrate", selection: bitrateBinding) {
                        ForEach([128, 160, 192, 256, 320], id: \.self) { value in
                            Text("\(value) kbps").tag(value)
                        }
                    }
                    Toggle("Stream-copy when possible", isOn: streamCopyBinding)
                    Toggle("Overwrite existing export", isOn: overwriteBinding)
                    Toggle("Create folder per audiobook", isOn: projectFolderBinding)
                    Toggle("Clean output file names", isOn: cleanNamesBinding)
                    Button("Choose Output Folder") { appModel.chooseOutputFolder() }
                    Text(appModel.selectedProject?.settings.outputFolderURL?.path ?? "Downloads folder")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .formStyle(.grouped)
        }
        .padding()
    }

    private var bitrateBinding: Binding<Int> {
        Binding(
            get: { appModel.selectedProject?.settings.bitrateKbps ?? 160 },
            set: { value in appModel.updateSelectedProject { $0.settings.bitrateKbps = value } }
        )
    }

    private var streamCopyBinding: Binding<Bool> {
        Binding(
            get: { appModel.selectedProject?.settings.allowStreamCopy ?? false },
            set: { value in appModel.updateSelectedProject { $0.settings.allowStreamCopy = value } }
        )
    }

    private var overwriteBinding: Binding<Bool> {
        Binding(
            get: { appModel.selectedProject?.settings.overwriteExisting ?? false },
            set: { value in appModel.updateSelectedProject { $0.settings.overwriteExisting = value } }
        )
    }

    private var projectFolderBinding: Binding<Bool> {
        Binding(
            get: { appModel.selectedProject?.settings.outputIntoProjectFolder ?? true },
            set: { value in appModel.updateSelectedProject { $0.settings.outputIntoProjectFolder = value } }
        )
    }

    private var cleanNamesBinding: Binding<Bool> {
        Binding(
            get: { appModel.selectedProject?.settings.cleanOutputNames ?? true },
            set: { value in appModel.updateSelectedProject { $0.settings.cleanOutputNames = value } }
        )
    }
}

struct CoverPreview: View {
    @EnvironmentObject private var appModel: AppViewModel

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.quaternary)
                if let url = appModel.selectedProject?.coverArtURL,
                   let image = NSImage(contentsOf: url) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    Image(systemName: "photo")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 164, height: 164)
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                Task {
                    if let provider = providers.first,
                       let data = try? await provider.loadItem(forTypeIdentifier: "public.file-url") as? Data,
                       let url = URL(dataRepresentation: data, relativeTo: nil) {
                        appModel.updateSelectedProject { $0.coverArtURL = url }
                    }
                }
                return true
            }

            Button("Choose Cover") { appModel.setCoverArt() }
        }
    }
}

struct LogView: View {
    @EnvironmentObject private var appModel: AppViewModel

    var body: some View {
        VStack(alignment: .leading) {
            Text("Logs").font(.headline)
            ScrollView {
                Text(appModel.logMessages.joined(separator: "\n"))
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding()
        .frame(height: 150)
    }
}
