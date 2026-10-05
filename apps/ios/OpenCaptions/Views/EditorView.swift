import OpenCaptionsKit
import SwiftUI

struct EditorView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
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
                topBar(showsStyleButton: !wide)
                if wide {
                    HStack(spacing: 0) {
                        preview.frame(maxWidth: .infinity, maxHeight: .infinity)
                        style.frame(width: 340).background(Theme.background)
                    }
                    timelinePanel.frame(height: min(280, geo.size.height * 0.4))
                } else {
                    preview.frame(maxHeight: .infinity)
                    timelinePanel.frame(height: 190)
                }
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .overlay(alignment: .top) { progress }
        .sheet(isPresented: $showTranscribe) {
            TranscribeSheet(model: model).presentationBackground(Theme.background).presentationCornerRadius(24)
        }
        .sheet(isPresented: $showStyle) {
            VStack(spacing: 0) {
                HStack {
                    Text("Style").font(.system(size: 20, weight: .heavy))
                    Spacer()
                    Button("Done") { showStyle = false }.buttonStyle(PillButtonStyle(prominent: true))
                }
                .padding(.horizontal, 18)
                .padding(.top, 20)
                .padding(.bottom, 4)
                style
            }
            .presentationBackground(Theme.background)
            .presentationCornerRadius(24)
            // The video stays live behind it at the low detent, to see a change as it is made.
            .presentationDetents([Self.styleDetent, .large])
            .presentationBackgroundInteraction(.enabled(upThrough: Self.styleDetent))
        }
        .sheet(isPresented: $showExport) {
            if let exporter {
                ExportSheet(controller: exporter).presentationBackground(Theme.surface).presentationCornerRadius(24)
            }
        }
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
                if ProcessInfo.processInfo.environment["OC_SHOW_TRANSCRIBE"] != nil { showTranscribe = true }
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

    /// The timeline sits on a rounded dark panel that runs down under the home indicator.
    private var timelinePanel: some View {
        CaptionTimeline(model: model, playback: playback)
            .background {
                UnevenRoundedRectangle(topLeadingRadius: 22, topTrailingRadius: 22)
                    .fill(Theme.surface)
                    .overlay(alignment: .top) {
                        UnevenRoundedRectangle(topLeadingRadius: 22, topTrailingRadius: 22)
                            .stroke(Theme.stroke, lineWidth: 1)
                    }
                    .ignoresSafeArea(edges: .bottom)
            }
    }

    private func topBar(showsStyleButton: Bool) -> some View {
        HStack(spacing: 10) {
            Button { dismiss() } label: { Image(systemName: "chevron.left") }
                .buttonStyle(CircleButtonStyle())
                .accessibilityLabel("Back")
            VStack(alignment: .leading, spacing: 1) {
                Text(model.project.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                SaveLabel(state: model.saveState)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if showsStyleButton {
                Button { showStyle = true } label: { Image(systemName: "paintbrush.pointed.fill") }
                    .buttonStyle(CircleButtonStyle())
                    .disabled(model.transcript == nil)
                    .accessibilityLabel("Style")
            }
            Menu {
                Button(model.transcript == nil ? "Transcribe" : "Re-transcribe", systemImage: "waveform") {
                    showTranscribe = true
                }
                .disabled(model.isTranscribing || exporter?.isRunning == true)
            } label: {
                Image(systemName: "ellipsis")
            }
            .buttonStyle(CircleButtonStyle())
            .accessibilityLabel("More")
            Button("Save") { Task { await saveVideo() } }
                .buttonStyle(PillButtonStyle(prominent: true))
                .disabled(model.transcript == nil || model.isTranscribing || exporter?.isRunning == true)
                .opacity(model.transcript == nil || model.isTranscribing ? 0.4 : 1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
    private var style: some View { StylePanel(model: model, presets: app.presets) }

    @ViewBuilder
    private var progress: some View {
        if case .running(let fraction, let message) = model.transcription {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    // A short clip is a single step, so there is no fraction to show until it
                    // ends: a spinner, with the words as they are decoded, beats a stuck 0%.
                    if fraction > 0 {
                        Text("\(Int(fraction * 100))%").font(.system(size: 20, weight: .heavy).monospacedDigit())
                            .foregroundStyle(Theme.accent)
                    } else {
                        ProgressView().tint(Theme.accent)
                    }
                    Text(message).font(.system(size: 14, weight: .semibold)).lineLimit(2)
                    Spacer(minLength: 0)
                }
                if fraction > 0 { ProgressView(value: fraction).tint(Theme.accent) }
                HStack {
                    Text("Keep OpenCaptions open until this finishes.")
                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Button("Cancel") { model.cancelTranscription() }
                        .font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.danger)
                }
            }
            .padding(14)
            .background(Theme.raised.opacity(0.97), in: .rect(cornerRadius: Theme.radius))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.stroke, lineWidth: 1))
            .shadow(color: .black.opacity(0.4), radius: 16, y: 6)
            .padding(.horizontal, 14)
            .padding(.top, 62)
        }
    }
}

private struct SaveLabel: View {
    let state: SaveState

    var body: some View {
        switch state {
        case .idle: EmptyView()
        case .saving: Text("Saving…").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
        case .saved: Label("Saved", systemImage: "checkmark").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
        case .failed(let reason): Text("Save failed: \(reason)").font(.system(size: 11)).foregroundStyle(Theme.danger)
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
