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
    /// Remembered between runs: someone who picks Spanish once is probably transcribing Spanish.
    @AppStorage("transcribeLanguage") private var language = "auto"
    @State private var downloading: Double?
    @State private var askAboutData = false
    @State private var failure: String?
    private let languages = TranscriptionLanguages.all

    private var chosen: WhisperModel { WhisperModels.model(modelID) ?? WhisperModels.all[0] }
    private var downloaded: Bool { app.transcriber.isDownloaded(modelID) }
    private var busy: Bool { downloading != nil || model.isTranscribing }

    var body: some View {
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
                    languageSection
                    modelSection
                    if let downloading {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Downloading the model").font(.system(size: 15, weight: .bold))
                            ProgressView(value: downloading).tint(Theme.accent)
                            Text("\(Int(downloading * 100))% of \(chosen.megabytes) MB")
                                .font(.system(size: 13).monospacedDigit()).foregroundStyle(Theme.textSecondary)
                        }
                        .card()
                    }
                    if let failure {
                        Text(failure).font(.system(size: 14)).foregroundStyle(Theme.danger).card()
                    }
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
            footer
        }
        .background(Theme.background)
        .tint(Theme.accent)
        .presentationDetents([.large])
        .interactiveDismissDisabled(downloading != nil)
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

    private var languageSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Spoken language")
            HStack {
                Text("Language").font(.system(size: 16, weight: .medium))
                Spacer()
                Picker("Spoken language", selection: $language) {
                    Text("Auto-detect").tag("auto")
                    ForEach(languages) { Text($0.label).tag($0.code) }
                }
                .labelsHidden().pickerStyle(.menu).tint(Theme.textPrimary)
            }
            .card()
            Text("Auto-detect works best on clear speech. If it guesses wrong, choose the language.")
                .font(.system(size: 12)).foregroundStyle(Theme.textSecondary).padding(.horizontal, 4)
        }
    }

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Model")
            VStack(spacing: 0) {
                ForEach(Array(WhisperModels.all.enumerated()), id: \.element.id) { index, option in
                    if index > 0 { Rectangle().fill(Theme.stroke).frame(height: 1).padding(.leading, 16) }
                    modelRow(option)
                }
            }
            .background(Theme.surface, in: .rect(cornerRadius: Theme.radius))
            .clipShape(.rect(cornerRadius: Theme.radius))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.stroke, lineWidth: 1))
            Text(downloaded
                ? "Downloaded. Transcription runs on this device."
                : "Downloaded once (\(chosen.megabytes) MB), then runs on this device. Larger models are slower and more accurate, and the biggest need a recent iPhone.")
                .font(.system(size: 12)).foregroundStyle(Theme.textSecondary).padding(.horizontal, 4)
        }
    }

    /// The chosen model is the highlighted row (a yellow edge and a soft wash), not a ticked box:
    /// there is exactly one, and it should not read as a list of options to tick.
    private func modelRow(_ option: WhisperModel) -> some View {
        let selected = option.id == modelID
        return Button { modelID = option.id } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label).font(.system(size: 16, weight: .semibold))
                    if let hint = Self.hint(option.id) {
                        Text(hint).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    }
                }
                Spacer(minLength: 8)
                if app.transcriber.isDownloaded(option.id) {
                    Image(systemName: "arrow.down.circle.fill").foregroundStyle(Theme.textSecondary)
                        .accessibilityLabel("Downloaded")
                }
                Text("\(option.megabytes) MB").font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Theme.accent.opacity(0.14) : .clear)
            .overlay(alignment: .leading) {
                Rectangle().fill(Theme.accent).frame(width: selected ? 4 : 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private static func hint(_ id: String) -> String? {
        switch id {
        case "tiny": "Fastest, least accurate"
        case "base": "Fast, good for most videos"
        case "small": "A balance of speed and accuracy"
        case "large-v3-turbo": "Most accurate for its speed"
        default: nil
        }
    }

    private var footer: some View {
        VStack(spacing: 8) {
            Button(downloaded ? "Transcribe" : "Download and transcribe") {
                Task { await begin(allowMetered: false) }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(busy)
            Text("Keep OpenCaptions open while it works.")
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
