import OpenCaptionsKit
import SwiftUI

struct EditorView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    /// Owned by the app, not this screen: leaving for the project list must not end a
    /// transcription or drop an unsaved edit.
    let model: EditorModel
    @State private var playback = Playback()
    @State private var showTranscribe = false
    @State private var showStyle = false
    @State private var edit: WordEdit?
    @State private var exporter: ExportController?
    @State private var showExport = false

    /// What the style sheet rests at: low enough to leave the caption (low in the frame) in view.
    private static let styleDetent = PresentationDetent.fraction(0.3)

    private struct WordEdit: Identifiable {
        let index: Int
        var text: String
        var id: Int { index }
    }

    var body: some View {
        GeometryReader { geo in
            // A tablet or a phone on its side keeps the style controls beside the video. A
            // phone upright gives the video the screen, with only the timeline under it;
            // the style controls come up over it as a sheet.
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
                    preview.frame(maxHeight: .infinity)
                    Divider()
                    timeline.frame(height: 178)
                }
            }
        }
        .navigationTitle(model.project.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .status) { SaveLabel(state: model.saveState) }
            ToolbarItem(placement: .primaryAction) {
                Button("Style", systemImage: "paintbrush") { showStyle = true }
                    .disabled(model.transcript == nil)
            }
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
        .sheet(isPresented: $showStyle) {
            NavigationStack {
                style
                    .navigationTitle("Style")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showStyle = false } } }
            }
            // The video stays live behind it at the low detent, to see a change as it is made.
            .presentationDetents([Self.styleDetent, .large])
            .presentationBackgroundInteraction(.enabled(upThrough: Self.styleDetent))
        }
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
        // A failure is shown until it is read, not for a moment in a banner.
        .alert(
            "Transcription failed",
            isPresented: Binding(
                get: { if case .failed = model.transcription { true } else { false } },
                set: { if !$0 { model.dismissTranscriptionFailure() } })
        ) {
            Button("OK") {}
        } message: {
            if case .failed(let reason) = model.transcription { Text(reason) }
        }
        .task {
            if let source = app.store.sourceURL(for: model.project.id) { playback.load(source) }
            #if DEBUG
                if let at = ProcessInfo.processInfo.environment["OC_SEEK"].flatMap(Double.init) {
                    try? await Task.sleep(for: .milliseconds(600))
                    playback.seek(to: at)
                }
            #endif
            #if DEBUG
                if ProcessInfo.processInfo.environment["OC_SHOW_STYLE"] != nil { showStyle = true }
            #endif
            if model.transcript == nil && !model.isTranscribing { showTranscribe = true }
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
            // A transcription carries on after the user leaves, and still needs the screen on.
            UIApplication.shared.isIdleTimerDisabled = model.isTranscribing
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

    private var timeline: some View { CaptionTimeline(model: model, playback: playback) }
    private var style: some View { StylePanel(model: model, presets: app.presets) }

    @ViewBuilder
    private var progress: some View {
        if case .running(let fraction, let message) = model.transcription {
            VStack(spacing: 6) {
                // A short clip is a single step, so there is no fraction to show until it ends:
                // a spinner, with the words as they are decoded, is more honest than a stuck 0%.
                if fraction > 0 {
                    ProgressView(value: fraction) { Text(message).font(.footnote).lineLimit(2) }
                } else {
                    ProgressView { Text(message).font(.footnote).lineLimit(2) }
                }
                HStack {
                    Text("Keep OpenCaptions open until this finishes.").font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel", role: .destructive) { model.cancelTranscription() }.font(.caption)
                }
            }
            .padding(12)
            .background(.regularMaterial, in: .rect(cornerRadius: 12))
            .padding()
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
