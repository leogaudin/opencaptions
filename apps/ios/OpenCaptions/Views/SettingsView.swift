import OpenCaptionsKit
import OpenCaptionsTranscription
import SwiftUI

/// How the app looks, the speech models it keeps, what it stores, and what it is.
struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @AppStorage(Appearance.storageKey) private var appearance = Appearance.system
    @AppStorage("transcribeLanguage") private var language = "auto"

    @State private var refresh = 0
    @State private var downloading: [String: Double] = [:]
    @State private var deleting: WhisperModel?
    @State private var meteredFor: WhisperModel?
    @State private var clearingSaved = false
    @State private var failure: String?
    private let languages = TranscriptionLanguages.all

    var body: some View {
        VStack(spacing: 0) {
            Text("Settings").font(.system(size: 28, weight: .heavy))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 10)
            ScrollView(.vertical) {
                VStack(spacing: 24) {
                    appearanceSection
                    ServerSection()
                    transcriptionSection
                    modelsSection
                    storageSection
                    aboutSection
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 32)
                .containerRelativeFrame(.horizontal)
            }
            .clipped()
            .scrollIndicators(.hidden)
        }
        .background(Theme.background.ignoresSafeArea())
        .id(refresh)
        // Sizes (saved videos, models) are read when the tab is shown, so a save made since is counted.
        // Outside the id: inside it, each refresh would remake the view and appear again, for ever.
        .onAppear { refresh += 1 }
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
                Button("Delete saved videos", role: .destructive) {
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
        case .deleteModel: "Delete this model?"
        case .metered: "Download on a metered connection?"
        case .clearSaved: "Delete every saved video?"
        case .failure, nil: "Something went wrong"
        }
    }

    private func dismissPrompts() {
        deleting = nil
        meteredFor = nil
        clearingSaved = false
        failure = nil
    }

    // MARK: Sections

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Appearance")
            SegmentedPills(options: Appearance.allCases, selection: $appearance, label: \.label)
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
                Text(model.label).font(.system(size: 16, weight: .semibold))
                Text(downloaded ? "On this device · \(Self.size(app.transcriber.sizeOnDisk(model.id)))" : "\(model.megabytes) MB")
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
                Button("Download") { requestDownload(model) }
                    .buttonStyle(PillButtonStyle(prominent: true))
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var storageSection: some View {
        let usage = app.store.usage()
        let models = WhisperModels.all.reduce(Int64(0)) { $0 + app.transcriber.sizeOnDisk($1.id) }
        return VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Storage")
            VStack(spacing: 14) {
                storageRow("Projects", Self.size(usage.projects))
                storageRow("Speech models", Self.size(models))
                HStack {
                    Text("Saved videos").font(.system(size: 16, weight: .medium))
                    Spacer()
                    Text(Self.size(usage.renders)).font(.system(size: 15)).foregroundStyle(Theme.textSecondary)
                    Button("Clear") { clearingSaved = true }
                        .buttonStyle(PillButtonStyle())
                        .disabled(usage.renders == 0)
                        .opacity(usage.renders == 0 ? 0.4 : 1)
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
                    Task { @MainActor in downloading[model.id] = fraction }
                }
            } catch {
                failure = "\(model.label) could not be downloaded: \(error.localizedDescription)"
            }
            downloading[model.id] = nil
            refresh += 1
        }
    }

    private func delete(_ model: WhisperModel) {
        do {
            try app.transcriber.delete(model.id)
        } catch {
            failure = "\(model.label) could not be deleted: \(error.localizedDescription)"
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
