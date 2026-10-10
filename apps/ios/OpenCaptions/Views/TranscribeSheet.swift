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

    @State private var modelID = SpeechModels.defaultID
    /// Remembered between runs: someone who picks Spanish once is probably transcribing Spanish.
    @AppStorage("transcribeLanguage") private var language = "auto"
    @State private var downloading: Double?
    @State private var askAboutData = false
    @State private var failure: String?
    @State private var showPro = false
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
    /// Whether the chosen model can work out the language itself (the server's always can).
    private var detects: Bool { onServer || chosen.detectsLanguage }
    /// After an unsure guess, auto-detect would only guess again: a language has to be chosen.
    private var afterUnsureGuess: Bool {
        if case .needsLanguage = model.transcription { return true }
        return false
    }
    private var offersAuto: Bool { detects && !afterUnsureGuess }
    private var mustChoose: Bool { language == "auto" && !offersAuto }
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
        .sheet(isPresented: $showPro) { ProSheet() }
        .sheet(isPresented: $connecting, onDismiss: { if app.serverConnection != nil { sourceChoice = true } }) {
            ConnectServerSheet().presentationBackground(Theme.background).presentationCornerRadius(24)
        }
        .task(id: onServer) { await loadServerModels() }
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
            if afterUnsureGuess { showLanguages = true }
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
                        if case .needsLanguage(let guess) = model.transcription {
                            VStack(alignment: .leading, spacing: 4) {
                                Label("Not sure which language this is", systemImage: "questionmark.circle.fill")
                                    .font(.system(size: 14, weight: .semibold))
                                Text("The best guess was \(Locale.current.localizedString(forLanguageCode: guess) ?? guess), but it is far from certain. Choose the language to go on.")
                                    .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                            }
                            .fixedSize(horizontal: false, vertical: true)
                            .card()
                        }
                        if let failure {
                            Text(failure).font(.system(size: 14)).foregroundStyle(Theme.danger).card()
                        }
                        languageSearch
                        languageList
                        if !detects {
                            Text("This model cannot tell the language by itself, so one has to be chosen.")
                                .font(.system(size: 12)).foregroundStyle(Theme.textSecondary).padding(.horizontal, 4)
                        }
                    }
                    .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 24)
                    .containerRelativeFrame(.horizontal)
                }
                .scrollBounceBehavior(.basedOnSize)
                .scrollIndicators(.hidden)
                .task { proxy.scrollTo(language, anchor: .center) }
            }
            footer(Button(downloaded ? (onServer ? "Transcribe on \(app.serverConnection?.displayName ?? "the server")" : "Transcribe") : "Download and transcribe") {
                Task { await begin(allowMetered: false) }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(busy || mustChoose || !offered.contains { $0.code == language } && language != "auto"))
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
                    ProgressView().controlSize(.small)
                    Text("Finishing up…").font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                }
            } else {
                ProgressView(value: fraction).tint(Theme.accent)
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
            if offersAuto, search.isEmpty {
                languageRow(code: "auto", flag: "\u{2728}", label: String(localized: "Auto-detect"))
            }
            ForEach(rows) { option in
                if offersAuto && search.isEmpty || option.id != rows.first?.id {
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

    /// The choice must be one the model offers: a language it does not know falls back to detecting, and a
    /// model that cannot detect gets the device's language (or the first one it has).
    private func keepLanguageValid() {
        let known = offered.contains { $0.code == language }
        if language == "auto" ? offersAuto : known { return }
        if offersAuto { language = "auto"; return }
        let device = Locale.current.language.languageCode?.identifier ?? "en"
        language = (offered.first { $0.code == device } ?? offered.first)?.code ?? "auto"
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
                    ProgressView().controlSize(.small)
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
        let locked = app.entitlements.locks(model: option.id)
        return Button {
            if locked { showPro = true } else { modelID = option.id }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(option.label).font(.system(size: 16, weight: .semibold))
                        if locked { ProBadge() }
                    }
                    if let hint = Self.hint(option.id) {
                        Text(hint).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    }
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

    private static func hint(_ id: String) -> LocalizedStringKey? {
        switch id {
        case "small": "For older iPhones"
        case SpeechModels.defaultID: "The one to use: nearly as accurate as Large v3, and much faster"
        case "parakeet-tdt-0.6b-v3": "Faster, 25 European languages"
        case SpeechModels.appleSpeechID: "Apple's own, for the languages iOS offers"
        default: nil
        }
    }

    private func footer(_ button: some View) -> some View {
        VStack(spacing: 8) {
            button
            Text(onServer ? "Keep OpenCaptions open until the audio has been sent." : "Keep OpenCaptions open while it works.")
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
                language: language == "auto" ? nil : language)
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
            with: app.transcriber, model: modelID, language: language == "auto" ? nil : language)
        dismiss()
    }
}
