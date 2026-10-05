import OpenCaptionsKit
import SwiftUI

struct EditorView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: EditorModel
    @State private var playback = Playback()
    @State private var showTranscribe = false
    @State private var edit: WordEdit?
    @State private var panel = Panel.timeline
    @State private var exporter: ExportController?
    @State private var showExport = false

    private enum Panel: String, CaseIterable {
        case timeline = "Timeline"
        case style = "Style"
    }

    private struct WordEdit: Identifiable {
        let index: Int
        var text: String
        var id: Int { index }
    }

    init(project: Project, store: ProjectStore) {
        _model = State(initialValue: EditorModel(project: project, store: store))
    }

    var body: some View {
        GeometryReader { geo in
            // A tablet or a phone on its side: the timeline spans the whole width at the
            // bottom, as on the web. A phone upright stacks preview, then a tabbed panel.
            let wide = geo.size.width > 700 || geo.size.width > geo.size.height
            VStack(spacing: 0) {
                if wide {
                    HStack(spacing: 0) {
                        preview.frame(maxWidth: .infinity, maxHeight: .infinity)
                        Divider()
                        style.frame(width: 340)
                    }
                    Divider()
                    timeline.frame(height: min(260, geo.size.height * 0.4))
                } else {
                    preview.frame(height: geo.size.height * 0.46)
                    Divider()
                    Picker("Panel", selection: $panel) {
                        ForEach(Panel.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .padding(8)
                    if panel == .timeline { timeline } else { style }
                }
            }
        }
        .navigationTitle(model.project.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .status) { SaveLabel(state: model.saveState) }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Save video", systemImage: "square.and.arrow.down") { Task { await saveVideo() } }
                        .disabled(model.transcript == nil || model.isTranscribing || exporter?.isRunning == true)
                    Button(model.transcript == nil ? "Transcribe" : "Re-transcribe", systemImage: "waveform") {
                        showTranscribe = true
                    }
                    .disabled(model.isTranscribing || exporter?.isRunning == true)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .overlay(alignment: .top) { progress }
        .sheet(isPresented: $showTranscribe) { TranscribeSheet(model: model) }
        .sheet(isPresented: $showExport) { if let exporter { ExportSheet(controller: exporter) } }
        .alert(
            "Edit word", isPresented: Binding(get: { edit != nil }, set: { if !$0 { edit = nil } }),
            presenting: edit
        ) { target in
            TextField("Word", text: Binding(
                get: { edit?.text ?? target.text },
                set: { edit?.text = CaptionGestures.sanitizedWord($0) }))
            Button("Save") { model.setWord(index: target.index, text: edit?.text ?? target.text) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("One word at a time. Clear it to delete the word.")
        }
        .task {
            if let source = app.store.sourceURL(for: model.project.id) { playback.load(source) }
            #if DEBUG
                if let at = ProcessInfo.processInfo.environment["OC_SEEK"].flatMap(Double.init) {
                    try? await Task.sleep(for: .milliseconds(600))
                    playback.seek(to: at)
                }
            #endif
            if model.transcript == nil { showTranscribe = true }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { Task { await model.flush() } }
        }
        // A long job needs the app in the foreground: there is no background processing.
        .onChange(of: model.isTranscribing) { _, busy in
            UIApplication.shared.isIdleTimerDisabled = busy
        }
        .onChange(of: exporter?.isRunning) { _, busy in
            UIApplication.shared.isIdleTimerDisabled = busy == true
        }
        .onDisappear {
            playback.pause()
            UIApplication.shared.isIdleTimerDisabled = false
            Task { await model.flush() }
        }
    }

    /// Saves what is on screen: pending edits land first, and the preview lets go of the
    /// engine while the export uses it.
    private func saveVideo() async {
        guard let source = app.store.sourceURL(for: model.project.id) else { return }
        await model.flush()
        playback.pause()
        // Exports are named by content hash in the project's own folder, outside backups.
        guard let directory = try? app.store.rendersDirectory(for: model.project.id) else { return }
        let controller = ExportController(run: { [fonts = app.fontCache] project, source, progress in
            try await CaptionExporter(fonts: fonts).export(
                project: project, source: source, in: directory, progress: progress)
        })
        exporter = controller
        controller.start(project: model.project, source: source)
        showExport = true
    }

    private var ratio: Double {
        Double(model.project.videoWidth ?? 9) / Double(max(1, model.project.videoHeight ?? 16))
    }

    private var preview: some View {
        ZStack {
            Color.black
            PreviewView(
                playback: playback, project: model.project, fonts: app.fontCache,
                suspended: exporter?.isRunning == true,
                onTogglePlay: { playback.toggle() },
                onMove: { model.setPosition(x: $0, y: $1) },
                onEditWord: { index in
                    playback.pause()
                    let text = model.transcript?.words[safe: index]?.text ?? ""
                    edit = WordEdit(index: index, text: text)
                }
            )
            .aspectRatio(ratio, contentMode: .fit)
        }
    }

    private var timeline: some View { TimelineView(model: model, playback: playback) }
    private var style: some View { StylePanel(model: model, presets: app.presets) }

    @ViewBuilder
    private var progress: some View {
        if case .running(let fraction, let message) = model.transcription {
            VStack(spacing: 6) {
                ProgressView(value: fraction) { Text(message).font(.footnote) }
                HStack {
                    Text("Keep OpenCaptions open until this finishes.").font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel", role: .destructive) { model.cancelTranscription() }.font(.caption)
                }
            }
            .padding(12)
            .background(.regularMaterial, in: .rect(cornerRadius: 12))
            .padding()
        } else if case .failed(let reason) = model.transcription {
            Text(reason).font(.footnote).foregroundStyle(.red).padding(12)
                .background(.regularMaterial, in: .rect(cornerRadius: 12)).padding()
        }
    }
}

private struct SaveLabel: View {
    let state: SaveState

    var body: some View {
        switch state {
        case .idle: EmptyView()
        case .saving: Text("Saving…").font(.caption).foregroundStyle(.secondary)
        case .saved: Label("Saved", systemImage: "checkmark").font(.caption).foregroundStyle(.green)
        case .failed(let reason): Text("Save failed: \(reason)").font(.caption).foregroundStyle(.red)
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
