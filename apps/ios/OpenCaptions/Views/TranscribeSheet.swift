import OpenCaptionsKit
import OpenCaptionsTranscription
import SwiftUI

/// Two steps. First where to transcribe and with which model; then the language, from the ones that
/// model knows, and the download if the model is not here yet. Models are fetched on demand, never
/// bundled, and a metered connection asks first.
struct TranscribeSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let model: EditorModel

    /// Remembered between runs, like the language: the model someone chose last is the one they will want.
    @AppStorage("transcribeModel") private var storedModelID = SpeechModels.defaultID
    private var modelID: String { SpeechModels.initial(stored: storedModelID) }
    /// The languages each model offers, for the flags on its row (Apple's depends on this iOS, so it is asked).
    @State private var languagesByModel: [String: [TranscriptionLanguage]] = [:]
    /// Remembered between runs: someone who picks Spanish once is probably transcribing Spanish.
    @AppStorage("transcribeLanguage") private var language = ""
    @State private var downloading: Double?
    @State private var askAboutData = false
    @State private var failure: String?
    @State private var connecting = false
    /// The languages the chosen model can be asked for (all of them until it has said), and the second step.
    @State private var offered = TranscriptionLanguages.all
    @State private var showLanguages = false
    @State private var search = ""

    private var chosen: SpeechModel { SpeechModels.model(modelID) ?? SpeechModels.all[0] }
    /// Where this transcription goes: what Settings says until the user changes it here, which applies
    /// to this one only.
    @State private var sourceChoice: Bool?
    /// With a server in use, nothing is downloaded: it has its own models and runs them.
    private var onServer: Bool { (sourceChoice ?? app.useServer) && app.serverConnection != nil }
    private var downloaded: Bool { onServer || app.transcriber.isDownloaded(modelID) }
    private var busy: Bool { downloading != nil || model.isTranscribing }
    @State private var serverModels: ServerCapabilities?
    @State private var serverModelID: String?
    @State private var serverProblem: String?

    var body: some View {
        NavigationStack {
            firstStep
                .navigationDestination(isPresented: $showLanguages) { secondStep }
                .toolbar(.hidden, for: .navigationBar)
        }
        .background(Theme.background)
        .tint(Theme.accent)
        .presentationDetents([.large])
        .interactiveDismissDisabled(downloading != nil)
        .onDisappear { model.dismissTranscriptionFailure() }
        .sheet(isPresented: $connecting, onDismiss: { if app.serverConnection != nil { sourceChoice = true } }) {
            ConnectServerSheet().presentationBackground(Theme.background).presentationCornerRadius(24)
        }
        .task(id: onServer) { await loadServerModels() }
        .task {
            for option in SpeechModels.all { languagesByModel[option.id] = await TranscriptionLanguages.offered(by: option) }
        }
        // The languages are the model's: the list follows it, and so does the choice, which must be one of them.
        .task(id: "\(modelID) \(onServer)") {
            let languages = onServer ? TranscriptionLanguages.all : await TranscriptionLanguages.offered(by: chosen)
            offered = languages
            keepLanguageValid()
        }
        // The longest wait is loading the model: start it as soon as it is the one chosen, while the
        // language is picked.
        .task(id: "\(modelID) \(downloaded) \(onServer)") {
            if !onServer, downloaded { app.transcriber.preload(modelID) }
        }
        .onAppear {
            #if DEBUG
                if ProcessInfo.processInfo.environment["OC_LANGUAGE_STEP"] != nil { showLanguages = true }
            #endif
        }
        .alert("Download \(chosen.megabytes) MB on a metered connection?", isPresented: $askAboutData) {
            Button("Cancel", role: .cancel) {}
            Button("Download") { Task { await begin(allowMetered: true) } }
        } message: {
            Text("You are on cellular or a hotspot. A Wi‑Fi connection would avoid using your data.")
        }
    }

    // MARK: First step: where, and which model

    private var firstStep: some View {
        VStack(spacing: 0) {
            header
            ScrollView(.vertical) {
                VStack(spacing: 22) {
                    if model.transcript != nil {
                        Label {
                            Text("This replaces the current captions, including your edits.")
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.accent)
                        }
                            .font(.system(size: 14, weight: .semibold))
                            .fixedSize(horizontal: false, vertical: true)
                            .card()
                    }
                    if model.isTranscribing {
                        Label("A transcription is already running.", systemImage: "hourglass")
                            .font(.system(size: 14, weight: .semibold)).card()
                    }
                    if app.serverConnection != nil { sourceSection }
                    if onServer { serverSection } else { modelSection }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
                // Exactly the scroll view's width, so nothing inside can make it drift sideways.
                .containerRelativeFrame(.horizontal)
            }
            .clipped()
            // Vertical only: nothing here is wider than the screen, so nothing may drift sideways.
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.hidden)
            footer(Button("Next") { showLanguages = true }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(model.isTranscribing || (onServer && serverModels == nil && serverProblem == nil)))
        }
        .background(Theme.background)
    }

    // MARK: Second step: the language

    private var secondStep: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { showLanguages = false } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(CircleButtonStyle())
                    .accessibilityLabel("Back")
                    .disabled(busy)
                Text("Spoken language").font(.system(size: 24, weight: .heavy))
                Spacer()
            }
            .padding(.horizontal, 18).padding(.top, 22).padding(.bottom, 10)
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(spacing: 16) {
                        if let downloading { downloadCard(downloading) }
                        if let failure {
                            Text(failure).font(.system(size: 14)).foregroundStyle(Theme.danger).card()
                        }
                        languageSearch
                        languageList
                    }
                    .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 24)
                    .containerRelativeFrame(.horizontal)
                    .id("top")
                }
                .scrollBounceBehavior(.basedOnSize)
                .scrollIndicators(.hidden)
                .task { proxy.scrollTo(language, anchor: .center) }
                // The list opens on the chosen language, far down it: the download, and a failure,
                // are at the top, and what everything waits for must be what is in view.
                .onChange(of: downloading != nil) { _, started in
                    if started { withAnimation { proxy.scrollTo("top", anchor: .top) } }
                }
                .onChange(of: failure) { _, shown in
                    if shown != nil { withAnimation { proxy.scrollTo("top", anchor: .top) } }
                }
            }
            footer(Button(downloaded ? (onServer ? "Transcribe on \(app.serverConnection?.displayName ?? "the server")" : "Transcribe") : "Download and transcribe") {
                Task { await begin(allowMetered: false) }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(busy || !offered.contains { $0.code == language }))
        }
        .background(Theme.background)
        .navigationBarBackButtonHidden()
        .toolbar(.hidden, for: .navigationBar)
        .interactiveDismissDisabled(busy)
    }

    /// The download is the first thing on the screen while it runs: it is what everything waits for. At the
    /// end the bytes are all here and the files are being put in place, which has no fraction to show.
    private func downloadCard(_ fraction: Double) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Downloading the model").font(.system(size: 15, weight: .bold))
            if fraction >= 0.99 {
                HStack(spacing: 10) {
                    Spinner().controlSize(.small)
                    Text("Finishing up…").font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                }
            } else {
                ProgressBar(value: fraction)
                Text("\(Int(fraction * 100))% of \(chosen.megabytes) MB")
                    .font(.system(size: 13).monospacedDigit()).foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var languageSearch: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.textSecondary)
            TextField("Search languages", text: $search)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            if !search.isEmpty {
                Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .foregroundStyle(Theme.textSecondary).accessibilityLabel("Clear")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(Theme.surface, in: .rect(cornerRadius: Theme.radius))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.stroke, lineWidth: 1))
    }

    private var shownLanguages: [TranscriptionLanguage] {
        search.isEmpty ? offered : offered.filter { $0.label.range(of: search, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    private var languageList: some View {
        let rows = shownLanguages
        return LazyVStack(spacing: 0) {
            ForEach(rows) { option in
                if option.id != rows.first?.id {
                    Rectangle().fill(Theme.stroke).frame(height: 1).padding(.leading, 16)
                }
                languageRow(code: option.code, flag: option.flag, label: option.label)
            }
        }
        .background(Theme.surface, in: .rect(cornerRadius: Theme.radius))
        .clipShape(.rect(cornerRadius: Theme.radius))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.stroke, lineWidth: 1))
    }

    private func languageRow(code: String, flag: String, label: String) -> some View {
        let selected = code == language
        return Button { language = code } label: {
            HStack(spacing: 14) {
                Text(flag).font(.system(size: 26))
                Text(label).font(.system(size: 16, weight: .semibold))
                Spacer(minLength: 8)
                if selected { Image(systemName: "checkmark").foregroundStyle(Theme.accent).fontWeight(.bold) }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Theme.accent.opacity(0.14) : .clear)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .id(code)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// The choice must be one the model offers: otherwise the device's language, or the first it has.
    private func keepLanguageValid() {
        language = TranscriptionLanguages.initial(stored: language, among: offered)
    }

    // MARK: Pieces

    private var header: some View {
        HStack {
            Text("Transcribe").font(.system(size: 24, weight: .heavy))
            Spacer()
            Button { dismiss() } label: { Image(systemName: "xmark") }
                .buttonStyle(CircleButtonStyle())
                .accessibilityLabel("Close")
        }
        .padding(.horizontal, 18)
        .padding(.top, 22)
        .padding(.bottom, 10)
    }

    /// Phone or server for this transcription only (Settings holds the standing choice).
    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Transcribe on")
            SourcePicker(useServer: Binding(get: { onServer }, set: { choice in
                // With no server connected, choosing one means connecting it, here and now.
                if choice, app.serverConnection == nil { connecting = true } else { sourceChoice = choice }
            }))
            if sourceChoice != nil, sourceChoice != app.useServer {
                Text("Just this time. Settings keeps your usual choice.")
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary).padding(.horizontal, 4)
            }
        }
    }

    /// The server's models (as it lists them) and where the audio goes.
    private var serverSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Model")
            if let serverModels, !serverModels.leanModels.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(serverModels.leanModels.enumerated()), id: \.element.id) { index, option in
                        if index > 0 { Rectangle().fill(Theme.stroke).frame(height: 1).padding(.leading, 16) }
                        serverModelRow(option, selected: option.id == (serverModelID ?? serverModels.defaultModel))
                    }
                }
                .background(Theme.surface, in: .rect(cornerRadius: Theme.radius))
                .clipShape(.rect(cornerRadius: Theme.radius))
                .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.stroke, lineWidth: 1))
            } else if let serverProblem {
                Text(serverProblem).font(.system(size: 14)).foregroundStyle(Theme.danger).card()
            } else if serverModels == nil {
                HStack(spacing: 10) {
                    Spinner().controlSize(.small)
                    Text("Asking \(app.serverConnection?.displayName ?? "the server")…")
                        .font(.system(size: 14)).foregroundStyle(Theme.textSecondary)
                }
                .card()
            } else {
                Text("The server chooses the model.").font(.system(size: 14)).foregroundStyle(Theme.textSecondary).card()
            }
            Text("Only the audio is sent, to \(app.serverConnection?.url.host ?? "the server"), which deletes it when it is done.")
                .font(.system(size: 12)).foregroundStyle(Theme.textSecondary).padding(.horizontal, 4)
            Button("Change server") { connecting = true }.buttonStyle(PillButtonStyle())
        }
    }

    private func serverModelRow(_ option: ServerCapabilities.Model, selected: Bool) -> some View {
        Button { serverModelID = option.id } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(option.label).font(.system(size: 16, weight: .semibold))
                if let note = option.note, !note.isEmpty {
                    Text(note).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Theme.accent.opacity(0.14) : .clear)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func loadServerModels() async {
        guard onServer, let connection = app.serverConnection else { return }
        serverModels = nil
        serverProblem = nil
        do {
            let caps = try await ServerTranscriber(connection: connection).capabilities()
            serverModels = caps
            serverModelID = nil
        } catch {
            serverProblem = error.localizedDescription
        }
    }

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Model")
            VStack(spacing: 0) {
                ForEach(Array(SpeechModels.all.enumerated()), id: \.element.id) { index, option in
                    if index > 0 { Rectangle().fill(Theme.stroke).frame(height: 1).padding(.leading, 16) }
                    modelRow(option)
                }
            }
            .background(Theme.surface, in: .rect(cornerRadius: Theme.radius))
            .clipShape(.rect(cornerRadius: Theme.radius))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.stroke, lineWidth: 1))
            Text(chosen.isBuiltIn
                ? "Built into iOS. Apple downloads each language the first time it is used, and a language has to be chosen."
                : downloaded
                ? "Downloaded. Transcription runs on this device."
                : "Downloaded once (\(chosen.megabytes) MB), then runs on this device. Larger models are slower and more accurate, and the biggest need a recent iPhone.")
                .font(.system(size: 12)).foregroundStyle(Theme.textSecondary).padding(.horizontal, 4)
        }
    }

    /// The chosen model is the highlighted row (a soft wash), not a ticked box:
    /// there is exactly one, and it should not read as a list of options to tick.
    private func modelRow(_ option: SpeechModel) -> some View {
        let selected = option.id == modelID
        return Button { storedModelID = option.id } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(option.label).font(.system(size: 16, weight: .semibold))
                    if let hint = Self.hint(option.id) {
                        Text(hint).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    }
                    if let languages = languagesByModel[option.id] { languageFlags(languages) }
                }
                Spacer(minLength: 8)
                if !option.isBuiltIn, app.transcriber.isDownloaded(option.id) {
                    Image(systemName: "arrow.down.circle.fill").foregroundStyle(Theme.textSecondary)
                        .accessibilityLabel("Downloaded")
                }
                Group {
                    if option.isBuiltIn { Text("Built in") } else { Text("\(option.megabytes) MB") }
                }
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Theme.accent.opacity(0.14) : .clear)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// A few flags and how many more languages there are, so a model's reach shows at a glance.
    private func languageFlags(_ languages: [TranscriptionLanguage]) -> some View {
        let glance = TranscriptionLanguages.glance(of: languages)
        return HStack(spacing: 4) {
            Text(glance.flags.joined()).font(.system(size: 12))
            if glance.more > 0 { Text("+\(glance.more)").font(.system(size: 11, weight: .semibold).monospacedDigit()) }
        }
        .foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(Theme.stroke.opacity(0.6), in: .capsule)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(languages.count) languages")
    }

    private static func hint(_ id: String) -> LocalizedStringKey? {
        switch id {
        case "small": "OpenAI's smaller, less precise model"
        case "large-v3-turbo": "OpenAI's default, bigger model"
        case SpeechModels.parakeetUltraID: "NVIDIA's default, bigger model"
        case SpeechModels.parakeetReduxID: "NVIDIA's smaller, less precise model"
        case SpeechModels.appleSpeechID: "Apple's own, built into iOS"
        default: nil
        }
    }

    private func footer(_ button: some View) -> some View {
        VStack(spacing: 8) {
            button
            Text(BackgroundJob.isSupported
                ? "You can leave OpenCaptions. The progress shows on your lock screen."
                : onServer ? "Keep OpenCaptions open until the audio has been sent." : "Keep OpenCaptions open while it works.")
                .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(Theme.background.shadow(.drop(color: .black.opacity(0.5), radius: 12, y: -4)))
    }

    // MARK: Work

    private func begin(allowMetered: Bool) async {
        failure = nil
        if onServer {
            guard let server = app.serverTranscriber else { return }
            model.startTranscription(
                with: server, model: serverModelID ?? serverModels?.defaultModel ?? "",
                language: language)
            dismiss()
            return
        }
        if !downloaded {
            if !allowMetered, await NetworkCost.isExpensive() {
                askAboutData = true
                return
            }
            UIApplication.shared.isIdleTimerDisabled = true
            defer { UIApplication.shared.isIdleTimerDisabled = false }
            downloading = 0
            let started = Date()
            Diagnostics.log("model download start \(modelID)")
            do {
                try await app.transcriber.download(modelID) { fraction in
                    Task { @MainActor in downloading = fraction }
                }
                Diagnostics.log("model download done \(modelID) in \(Int(Date().timeIntervalSince(started)))s")
            } catch {
                Diagnostics.log("model download failed \(modelID): \(error)")
                downloading = nil
                failure = String(localized: "The model could not be downloaded: \(error.localizedDescription)")
                return
            }
            downloading = nil
        }
        model.startTranscription(
            with: app.transcriber, model: modelID, language: language)
        dismiss()
    }
}
