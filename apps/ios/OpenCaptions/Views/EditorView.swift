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
    @State private var showSaveOptions = false
    @State private var showStyle = false
    @State private var edit: WordEdit?
    @State private var exporter: ExportController?
    @State private var showExport = false

    /// What the style sheet rests at: low enough to leave the caption (low in the frame) in view.
    private static let styleDetent = PresentationDetent.fraction(0.3)
    private static let styleDetentTall = PresentationDetent.fraction(0.55)

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
        .toolbar(.hidden, for: .tabBar)
        .overlay(alignment: .top) { progress }
        .overlay { wordEditor }
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
            // The video stays live behind it at the low detent, to see a change as it is made, and
            // the sheet does not go higher than the middle of the screen: the video stays in view.
            .presentationDetents([Self.styleDetent, Self.styleDetentTall])
            .presentationBackgroundInteraction(.enabled(upThrough: Self.styleDetentTall))
        }
        .sheet(isPresented: $showSaveOptions) {
            SaveOptionsSheet(
                project: model.project,
                save: { options in
                    showSaveOptions = false
                    Task { await saveVideo(options) }
                },
                cancel: { showSaveOptions = false }
            )
            .presentationBackground(Theme.surface).presentationCornerRadius(24)
        }
        .sheet(isPresented: $showExport) {
            if let exporter {
                ExportSheet(controller: exporter).presentationBackground(Theme.surface).presentationCornerRadius(24)
            }
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
                if ProcessInfo.processInfo.environment["OC_SHOW_SAVE"] != nil { showSaveOptions = true }
                if ProcessInfo.processInfo.environment["OC_EDIT_WORD"] != nil {
                    edit = WordEdit(index: 1, text: model.transcript?.words[safe: 1]?.text ?? "")
                }
            #endif
            if model.transcript == nil && !model.isTranscribing { showTranscribe = true }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { Task { await model.flush() } }
            // The system takes the hardware encoder from an app that leaves the screen, which ends a
            // save abruptly. Stopping it ourselves leaves a clear message instead of a dead app.
            if phase == .background {
                exporter?.interrupt(String(localized: "The save stopped because OpenCaptions left the screen. Keep it open while it saves, then try again."))
            }
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
    private func saveVideo(_ chosen: ExportOptions) async {
        // Whatever the screen allowed, what is saved is within this tier.
        let options = app.entitlements.limit(chosen, for: model.project)
        guard let source = app.store.sourceURL(for: model.project.id) else { return }
        await model.flush()
        playback.pause()
        // Exports are named by content hash in the project's own folder, outside backups.
        guard let directory = try? app.store.rendersDirectory(for: model.project.id) else { return }
        let controller = ExportController(run: { [fonts = app.fontCache] project, source, progress in
            try await CaptionExporter(fonts: fonts).export(
                project: project, source: source, in: directory, options: options, progress: progress)
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
                suspended: exporter?.isRunning == true, watermark: app.entitlements.watermark,
                onTogglePlay: { playback.toggle() },
                onAdjust: { position, size in model.adjustCaption(position: position, fontSize: size) },
                onEditWord: { index in
                    playback.pause()
                    let text = model.transcript?.words[safe: index]?.text ?? ""
                    edit = WordEdit(index: index, text: text)
                }
            )
            .aspectRatio(ratio, contentMode: .fit)
        }
        #if DEBUG
            // What the UI tests read: the caption's size and place, as an invisible label.
            .overlay(alignment: .topLeading) {
                let style = model.project.styleConfig
                Text("size=\(style.fontSize) x=\(Int((style.positionX * 100).rounded())) y=\(Int((style.positionY * 100).rounded()))")
                    .font(.system(size: 4)).opacity(0.02).allowsHitTesting(false)
                    .accessibilityIdentifier("debug-style")
            }
        #endif
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
            Button("Save") { showSaveOptions = true }
                .buttonStyle(PillButtonStyle(prominent: true))
                .disabled(model.transcript == nil || model.isTranscribing || exporter?.isRunning == true)
                .opacity(model.transcript == nil || model.isTranscribing ? 0.4 : 1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
    private var style: some View { StylePanel(model: model, presets: app.presets) }

    /// Editing a word: a card with a field that takes no spaces (a word is one word), over the
    /// preview. Saving an empty field deletes the word.
    @ViewBuilder
    private var wordEditor: some View {
        if let target = edit {
            WordEditCard(
                text: Binding(get: { edit?.text ?? target.text }, set: { edit?.text = $0 }),
                save: {
                    model.setWord(index: target.index, text: edit?.text ?? target.text)
                    edit = nil
                },
                cancel: { edit = nil })
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private var progress: some View {
        if case .running(let fraction, let message) = model.transcription {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    // A short clip is a single step, so there is no fraction to show until it
                    // ends: a spinner, with the words as they are decoded, beats a stuck 0%.
                    if fraction > 0 {
                        Text("\(Int(fraction * 100))%").font(.system(size: 20, weight: .heavy).monospacedDigit())
                            .foregroundStyle(Theme.textPrimary)
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

private struct WordEditCard: View {
    @Binding var text: String
    let save: () -> Void
    let cancel: () -> Void
    @FocusState private var focused: Bool
    @State private var selection: TextSelection?

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.5).ignoresSafeArea().onTapGesture(perform: cancel)
            VStack(alignment: .leading, spacing: 14) {
                Text("Edit word").font(.system(size: 18, weight: .heavy))
                TextField("Word", text: $text, selection: $selection)
                    .focused($focused)
                    .submitLabel(.done)
                    .onSubmit(save)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(size: 22, weight: .bold))
                    .padding(.horizontal, 14).padding(.vertical, 12)
                    .background(Theme.raised, in: .rect(cornerRadius: 12))
                Text("Clear it to delete the word.")
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                HStack(spacing: 10) {
                    Button("Cancel", action: cancel).buttonStyle(SecondaryButtonStyle())
                    Button(text.isEmpty ? "Delete" : "Save", action: save).buttonStyle(PrimaryButtonStyle())
                }
            }
            .card()
            .padding(.horizontal, 18)
            .padding(.top, 76)
        }
        .onAppear {
            // The keyboard opens with the word selected, so typing replaces it.
            focused = true
            Task {
                try? await Task.sleep(for: .milliseconds(80))
                selection = TextSelection(range: text.startIndex..<text.endIndex)
            }
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
