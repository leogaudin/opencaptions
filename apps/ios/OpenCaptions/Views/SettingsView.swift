import OpenCaptionsKit
import OpenCaptionsTranscription
import SwiftUI

/// How the app looks, the speech models it keeps, what it stores, and what it is.
struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @AppStorage(Appearance.storageKey) private var appearance = Appearance.system
    @AppStorage("transcribeLanguage") private var language = "auto"

    @State private var refresh = 0
    @State private var showPro = false
    @State private var downloading: [String: Double] = [:]
    @State private var deleting: WhisperModel?
    @State private var meteredFor: WhisperModel?
    @State private var clearingSaved = false
    @State private var failure: String?
    @State private var sizes = Sizes()
    private let languages = TranscriptionLanguages.all

    /// What is on disk. Read when `refresh` changes, not each time the page is drawn: a model's
    /// download progress draws it many times a second, and each size is a walk through a folder.
    private struct Sizes: Equatable {
        var projects: Int64 = 0
        var renders: Int64 = 0
        var models: Int64 = 0
        var perModel: [String: Int64] = [:]
    }

    private func measure() -> Sizes {
        let usage = app.store.usage()
        let perModel = Dictionary(uniqueKeysWithValues: WhisperModels.all.map { ($0.id, app.transcriber.sizeOnDisk($0.id)) })
        return Sizes(projects: usage.projects, renders: usage.renders, models: perModel.values.reduce(0, +), perModel: perModel)
    }

    var body: some View {
        // Read here so that a change of `refresh` draws the sizes again, without remaking the page
        // (which would scroll it to the top).
        let _ = refresh
        VStack(spacing: 0) {
            Text("Settings").font(.system(size: 28, weight: .heavy))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 10)
            ScrollView(.vertical) {
                VStack(spacing: 24) {
                    #if APPSTORE
                        proSection
                    #endif
                    appearanceSection
                    ServerSection()
                    transcriptionSection
                    modelsSection
                    storageSection
                    #if DEBUG
                        tierSection
                    #endif
                    aboutSection
                }
                .padding(.horizontal, 16)
                .containerRelativeFrame(.horizontal)
            }
            .clipped()
            .scrollIndicators(.hidden)
            // Under the tab bar, which the content dissolves into (`fadesIntoTabBar`).
            .contentMargins(.bottom, tabBarClearance, for: .scrollContent)
            .ignoresSafeArea(.container, edges: .bottom)
        }
        .background(Theme.background.ignoresSafeArea())
        .fadesIntoTabBar()
        .sheet(isPresented: $showPro) { ProSheet() }
        // Sizes (saved videos, models) are read when the tab is shown, so a save made since is counted.
        .onAppear { refresh += 1 }
        .task(id: refresh) { sizes = measure() }
        .alert(
            alertTitle, isPresented: Binding(get: { prompt != nil }, set: { if !$0 { dismissPrompts() } }),
            presenting: prompt
        ) { prompt in
            switch prompt {
            case .deleteModel(let model):
                Button("Cancel", role: .cancel) {}
                Button("Delete \(model.label)", role: .destructive) { delete(model) }
            case .metered(let model):
                Button("Cancel", role: .cancel) {}
                Button("Download \(model.megabytes) MB") { startDownload(model) }
            case .clearSaved:
                Button("Cancel", role: .cancel) {}
                Button("Delete cached videos", role: .destructive) {
                    app.store.clearRenders()
                    refresh += 1
                }
            case .failure:
                Button("OK") {}
            }
        } message: { prompt in
            switch prompt {
            case .deleteModel(let model):
                Text("It frees \(Self.size(app.transcriber.sizeOnDisk(model.id))) and downloads again when you next choose it.")
            case .metered:
                Text("You are on cellular or a hotspot. A Wi‑Fi connection would avoid using your data.")
            case .clearSaved:
                Text("Your projects are kept. Saving a project again makes its video again.")
            case .failure(let message):
                Text(message)
            }
        }
    }

    // MARK: One alert for the screen
    // Several `.alert`s on one view compete and only one is reliably shown, so the questions this
    // screen asks share one, chosen by what is pending.

    private enum Prompt {
        case deleteModel(WhisperModel)
        case metered(WhisperModel)
        case clearSaved
        case failure(String)
    }

    private var prompt: Prompt? {
        if let deleting { return .deleteModel(deleting) }
        if let meteredFor { return .metered(meteredFor) }
        if clearingSaved { return .clearSaved }
        if let failure { return .failure(failure) }
        return nil
    }

    private var alertTitle: String {
        switch prompt {
        case .deleteModel: String(localized: "Delete this model?")
        case .metered: String(localized: "Download on a metered connection?")
        case .clearSaved: String(localized: "Delete every cached video?")
        case .failure, nil: String(localized: "Something went wrong")
        }
    }

    private func dismissPrompts() {
        deleting = nil
        meteredFor = nil
        clearingSaved = false
        failure = nil
    }

    // MARK: Sections

    #if APPSTORE
        /// Where to buy Pro, and to restore it, without having to hit something that is locked.
        private var proSection: some View {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("OpenCaptions Pro")
                Button {
                    if !app.entitlements.isPro { showPro = true }
                } label: {
                    HStack {
                        Text(app.entitlements.isPro ? "Pro is unlocked" : "Unlock Pro").font(.system(size: 16, weight: .medium))
                        Spacer()
                        Image(systemName: app.entitlements.isPro ? "checkmark.circle.fill" : "chevron.right")
                            .foregroundStyle(app.entitlements.isPro ? Theme.accent : Theme.textSecondary)
                    }
                    .card()
                }
                .buttonStyle(.plain)
            }
        }
    #endif

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Appearance")
            InlinePicker(title: "Theme", options: Appearance.allCases, selection: $appearance, label: \.label).card()
        }
    }

    private var transcriptionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Transcription")
            HStack {
                Text("Spoken language").font(.system(size: 16, weight: .medium))
                Spacer()
                Picker("Spoken language", selection: $language) {
                    Text("Auto-detect").tag("auto")
                    ForEach(languages) { Text($0.label).tag($0.code) }
                }
                .labelsHidden().pickerStyle(.menu).tint(Theme.textPrimary)
            }
            .card()
            Text("What the transcribe sheet starts with. Auto-detect works best on clear speech.")
                .font(.system(size: 12)).foregroundStyle(Theme.textSecondary).padding(.horizontal, 4)
        }
    }

    private var modelsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Speech models")
            VStack(spacing: 0) {
                ForEach(Array(WhisperModels.all.enumerated()), id: \.element.id) { index, model in
                    if index > 0 { Rectangle().fill(Theme.stroke).frame(height: 1).padding(.leading, 16) }
                    modelRow(model)
                }
            }
            .background(Theme.surface, in: .rect(cornerRadius: Theme.radius))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.stroke, lineWidth: 1))
            Text("Models are downloaded once and run on this device. Delete the ones you do not use to free space.")
                .font(.system(size: 12)).foregroundStyle(Theme.textSecondary).padding(.horizontal, 4)
        }
    }

    private func modelRow(_ model: WhisperModel) -> some View {
        let downloaded = app.transcriber.isDownloaded(model.id)
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(model.label).font(.system(size: 16, weight: .semibold))
                    if app.entitlements.locks(model: model.id) { ProBadge() }
                }
                Text(downloaded ? "On this device · \(Self.size(sizes.perModel[model.id] ?? 0))" : "\(model.megabytes) MB")
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 8)
            if let fraction = downloading[model.id] {
                HStack(spacing: 8) {
                    Text("\(Int(fraction * 100))%").font(.system(size: 13, weight: .bold).monospacedDigit())
                    ProgressView().controlSize(.small)
                }
                .foregroundStyle(Theme.textSecondary)
            } else if downloaded {
                Button { deleting = model } label: { Image(systemName: "trash") }
                    .buttonStyle(CircleButtonStyle())
                    .accessibilityLabel("Delete \(model.label)")
            } else {
                Button("Download") {
                    if app.entitlements.locks(model: model.id) { showPro = true } else { requestDownload(model) }
                }
                .buttonStyle(PillButtonStyle(prominent: true))
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var storageSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Storage")
            VStack(spacing: 14) {
                storageRow("Projects", Self.size(sizes.projects))
                storageRow("Speech models", Self.size(sizes.models))
                HStack {
                    Text("Cached videos").font(.system(size: 16, weight: .medium))
                    Spacer()
                    Text(Self.size(sizes.renders)).font(.system(size: 15)).foregroundStyle(Theme.textSecondary)
                    Button("Clear") { clearingSaved = true }
                        .buttonStyle(PillButtonStyle())
                        .disabled(sizes.renders == 0)
                        .opacity(sizes.renders == 0 ? 0.4 : 1)
                }
            }
            .card()
        }
    }

    private func storageRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).font(.system(size: 16, weight: .medium))
            Spacer()
            Text(value).font(.system(size: 15)).foregroundStyle(Theme.textSecondary)
        }
    }

    #if DEBUG
        /// Debug builds only: try the free and the Pro side of the app.
        private var tierSection: some View {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("Debug")
                InlinePicker(
                    title: "Tier", options: [false, true],
                    selection: Binding(get: { app.entitlements.isPro }, set: { app.setTier($0 ? .pro : .free) }),
                    label: { $0 ? "Pro" : "Free" }
                ).card()
            }
        }
    #endif

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("About")
            VStack(alignment: .leading, spacing: 14) {
                Wordmark()
                Text("Captions that move, made on your phone. Nothing is uploaded: the speech is transcribed on this device.")
                    .font(.system(size: 14)).foregroundStyle(Theme.textSecondary)
                storageRow("Version", Self.version)
                Link(destination: URL(string: "https://github.com/leogaudin/opencaptions")!) {
                    Label("Source code", systemImage: "chevron.left.forwardslash.chevron.right")
                        .font(.system(size: 15, weight: .semibold))
                }
                Text("Open source (AGPL-3.0). Uses Whisper models and WhisperKit (MIT) and the Inter font (SIL OFL).")
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                if FileManager.default.fileExists(atPath: Diagnostics.fileURL.path) {
                    ShareLink(item: Diagnostics.fileURL) {
                        Label("Share diagnostics", systemImage: "square.and.arrow.up")
                            .font(.system(size: 15, weight: .semibold))
                    }
                }
            }
            .card()
        }
    }

    // MARK: Actions

    private func requestDownload(_ model: WhisperModel) {
        Task {
            if await NetworkCost.isExpensive() { meteredFor = model } else { startDownload(model) }
        }
    }

    private func startDownload(_ model: WhisperModel) {
        downloading[model.id] = 0
        Task {
            UIApplication.shared.isIdleTimerDisabled = true
            defer { UIApplication.shared.isIdleTimerDisabled = false }
            do {
                try await app.transcriber.download(model.id) { fraction in
                    Task { @MainActor in
                        // A late report must not bring the row back after the download is over.
                        if downloading[model.id] != nil { downloading[model.id] = fraction }
                    }
                }
            } catch {
                failure = String(localized: "\(model.label) could not be downloaded: \(error.localizedDescription)")
            }
            downloading[model.id] = nil
            refresh += 1
            // The first load of a model on a phone is the slow one (Core ML prepares it for this chip, once):
            // done now, in the background, it is not waited for at the first transcription.
            if app.transcriber.isDownloaded(model.id) { app.transcriber.preload(model.id) }
        }
    }

    private func delete(_ model: WhisperModel) {
        do {
            try app.transcriber.delete(model.id)
        } catch {
            failure = String(localized: "\(model.label) could not be deleted: \(error.localizedDescription)")
        }
        refresh += 1
    }

    private static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}
