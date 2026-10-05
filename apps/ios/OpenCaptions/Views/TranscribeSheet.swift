import OpenCaptionsKit
import OpenCaptionsTranscription
import SwiftUI

/// Pick the language and the model, download it if it is not here yet, and transcribe.
/// Models are fetched on demand, never bundled, and a metered connection asks first.
struct TranscribeSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let model: EditorModel

    @State private var modelID = WhisperModels.defaultID
    @State private var language = "auto"
    @State private var downloading: Double?
    @State private var askAboutData = false
    @State private var failure: String?
    private let languages = TranscriptionLanguages.all

    private var chosen: WhisperModel { WhisperModels.model(modelID) ?? WhisperModels.all[0] }
    private var downloaded: Bool { app.transcriber.isDownloaded(modelID) }

    var body: some View {
        NavigationStack {
            Form {
                Section("Language") {
                    Picker("Spoken language", selection: $language) {
                        Text("Detect automatically").tag("auto")
                        ForEach(languages) { Text($0.label).tag($0.code) }
                    }
                }
                Section {
                    Picker("Model", selection: $modelID) {
                        ForEach(WhisperModels.all) { Text("\($0.label) · \($0.megabytes) MB").tag($0.id) }
                    }
                } header: {
                    Text("Model")
                } footer: {
                    Text(downloaded
                        ? "Downloaded. Transcription runs on this device."
                        : "Downloaded once (\(chosen.megabytes) MB), then runs on this device. Larger models are slower and more accurate.")
                }
                if model.transcript != nil {
                    Section {
                        Label("This replaces the current captions, including your edits.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
                if let downloading {
                    Section("Downloading the model") { ProgressView(value: downloading) }
                }
                if let failure {
                    Section { Text(failure).foregroundStyle(.red) }
                }
                Section {
                    Button("Transcribe") { Task { await begin(allowMetered: false) } }
                        .disabled(downloading != nil)
                } footer: {
                    Text("Keep OpenCaptions open while it works.")
                }
            }
            .navigationTitle("Transcribe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .confirmationDialog(
                "Download \(chosen.megabytes) MB on a metered connection?", isPresented: $askAboutData,
                titleVisibility: .visible
            ) {
                Button("Download") { Task { await begin(allowMetered: true) } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("You are on cellular or a hotspot. A Wi‑Fi connection would avoid using your data.")
            }
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(downloading != nil)
    }

    private func begin(allowMetered: Bool) async {
        failure = nil
        if !downloaded {
            if !allowMetered, await NetworkCost.isExpensive() {
                askAboutData = true
                return
            }
            UIApplication.shared.isIdleTimerDisabled = true
            defer { UIApplication.shared.isIdleTimerDisabled = false }
            downloading = 0
            do {
                try await app.transcriber.download(modelID) { fraction in
                    Task { @MainActor in downloading = fraction }
                }
            } catch {
                downloading = nil
                failure = "The model could not be downloaded: \(error.localizedDescription)"
                return
            }
            downloading = nil
        }
        model.startTranscription(
            with: app.transcriber, model: modelID, language: language == "auto" ? nil : language)
        dismiss()
    }
}
