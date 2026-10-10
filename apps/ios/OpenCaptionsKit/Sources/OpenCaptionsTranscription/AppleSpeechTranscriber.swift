#if canImport(Speech) && compiler(>=6.2)
    import AVFoundation
    import Foundation
    import OpenCaptionsKit
    import Speech

    /// On-device transcription with the speech model built into iOS 26 (`SpeechTranscriber`). Apple downloads
    /// and keeps it, per language, so there is nothing for the app to fetch, size or delete; it is here to be
    /// measured against Whisper and Parakeet, above all on how many words come back with a time of their own.
    ///
    /// It cannot detect a language, so a transcription with none chosen asks for one.
    @available(iOS 26.0, macOS 26.0, *)
    public struct AppleSpeechTranscriber: Transcriber {
        public init() {}

        public func transcribe(
            source: URL, language: String?, model: String,
            progress: @escaping @Sendable (Double, String) -> Void
        ) async throws -> Transcript {
            let requested = language.flatMap { $0 == "auto" ? nil : $0 }
            let code = requested ?? Locale.current.language.languageCode?.identifier ?? "en"
            guard requested != nil else { throw TranscriptionError.unsureLanguage(guess: code) }
            guard let locale = await Self.locale(for: code) else { throw TranscriptionError.unsupportedLanguage(code) }

            progress(0, KitStrings.localized("Reading the audio…"))
            let samples = try await AudioExtractor.samples(from: source)
            guard !samples.isEmpty else { throw TranscriptionError.noAudio }
            let seconds = Double(samples.count) / AudioExtractor.sampleRate
            let file = try Self.write(samples)
            defer { try? FileManager.default.removeItem(at: file) }

            let transcriber = SpeechTranscriber(
                locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
            // The language's model is Apple's to download, once, the first time it is wanted.
            if let installation = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                progress(0, KitStrings.localized("Downloading the language from Apple…"))
                try await installation.downloadAndInstall()
            }

            progress(0, KitStrings.localized("Transcribing…"))
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            let collecting = Task { () throws -> [Word] in
                var words: [Word] = []
                for try await result in transcriber.results {
                    words += Self.words(in: result.text, span: result.range, duration: seconds)
                    if let end = words.last?.end { progress(min(1, end / seconds), KitStrings.localized("Transcribing…")) }
                }
                return words
            }
            let input = try AVAudioFile(forReading: file)
            if let last = try await analyzer.analyzeSequence(from: input) {
                try await analyzer.finalizeAndFinish(through: last)
            } else {
                await analyzer.cancelAndFinishNow()
            }
            let words = try await collecting.value
            progress(1, KitStrings.localized("Done"))

            let segments = Self.segments(from: words)
            guard !segments.isEmpty else { throw TranscriptionError.noSpeech }
            return Transcript(language: code, languageDetection: .manual, duration: seconds, segments: segments)
        }

        /// The supported locale for a language code (the first, if Apple lists several regions).
        private static func locale(for code: String) async -> Locale? {
            await SpeechTranscriber.supportedLocales.first { $0.language.languageCode?.identifier == code }
        }

        /// The words of a result. Each run carries its own time range when Apple gave one; a run without
        /// one (or holding several words) has its words spread over the time it does have, the result's.
        private static func words(in text: AttributedString, span: CMTimeRange, duration: Double) -> [Word] {
            var words: [Word] = []
            for run in text.runs {
                let piece = String(text[run.range].characters)
                let tokens = piece.split(whereSeparator: \.isWhitespace).map(String.init)
                guard !tokens.isEmpty else { continue }
                let range = run.audioTimeRange ?? span
                let start = max(0, range.start.seconds)
                let end = min(duration, max(start, range.end.seconds))
                let weight = Double(tokens.reduce(0) { $0 + max(1, $1.count) })
                var used = 0.0
                for token in tokens {
                    let from = start + (end - start) * used / weight
                    used += Double(max(1, token.count))
                    words.append(Word(text: token, start: from, end: start + (end - start) * used / weight))
                }
            }
            return words
        }

        private static let sentenceEnds: Set<Character> = [".", "?", "!", "…", "。", "？", "！"]

        private static func segments(from words: [Word]) -> [TranscriptSegment] {
            var segments: [TranscriptSegment] = []
            var current: [Word] = []
            func close() {
                guard let first = current.first, let last = current.last else { return }
                segments.append(
                    TranscriptSegment(
                        id: UUID().uuidString, words: current, start: first.start, end: last.end,
                        text: current.map(\.text).joined(separator: " ")))
                current = []
            }
            for word in words {
                current.append(word)
                if let end = word.text.last, sentenceEnds.contains(end) { close() }
            }
            close()
            return segments
        }

        /// The samples as a 16 kHz mono WAV in a temporary file, which is what the analyzer reads.
        private static func write(_ samples: [Float]) throws -> URL {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioExtractor.sampleRate, channels: 1, interleaved: false)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
            buffer.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
            return url
        }
    }
#endif
