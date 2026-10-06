import Foundation
import OpenCaptionsEngine

public struct EngineError: Error, Equatable, Sendable, LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
}

/// A rectangle in frame pixels, the engine's own coordinates.
public struct FrameRect: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public func contains(x px: Double, y py: Double) -> Bool {
        px >= x && px <= x + width && py >= y && py <= y + height
    }
}

/// The caption showing at the last rendered time, for the editor to manipulate.
public struct ActiveCaption: Equatable, Sendable {
    /// The block rectangle, for dragging the whole caption.
    public var bounds: FrameRect
    /// Index among all lines: word N here is transcript word `index * wordsPerLine + N`.
    public var index: Int
    /// Each word's rectangle in line order, for picking the word under a tap.
    public var words: [FrameRect]
}

/// One caption as the viewer sees it: words `from`..<`from + count` in reading order.
public struct CaptionLine: Codable, Equatable, Sendable {
    public var from: Int
    public var count: Int
    public var start: Double
    public var end: Double
    public var text: String
}

/// A caption position after magnetism toward the video's centre lines.
public struct SnappedPosition: Equatable, Sendable {
    public var x: Double
    public var y: Double
    /// Whether x was pulled to the vertical centre line, and y to the horizontal one.
    public var onX: Bool
    public var onY: Bool
}

public enum CaptionEdge: Int32, Sendable {
    case start = 0
    case end = 1
}

/// The caption engine: the same Rust library the server and the browser draw with.
///
/// The only code that calls `oc_*`. The engine keeps one scene for the whole
/// process and allows its calls from any thread if they are serialized, which an
/// actor guarantees: every method here is synchronous inside the actor, so a result
/// or a frame is copied out before the next call can run. Hence one shared instance:
/// two would not give two engines, only two callers of one.
public actor CaptionEngine {
    public static let shared = CaptionEngine()

    private var bundledFamilies: [String]?
    /// The scene last set, so a sample can be drawn and the real scene put back.
    private var scene: SceneInput?

    // MARK: Buffers

    /// Copies `bytes` into engine memory. The call it is passed to takes ownership,
    /// so Swift never frees it.
    private func put(_ bytes: [UInt8]) -> (UnsafeMutablePointer<UInt8>, Int) {
        let ptr = oc_alloc(bytes.count)!
        bytes.withUnsafeBufferPointer { src in
            if let base = src.baseAddress { ptr.update(from: base, count: bytes.count) }
        }
        return (ptr, bytes.count)
    }

    private func put(_ string: String) -> (UnsafeMutablePointer<UInt8>, Int) {
        put(Array(string.utf8))
    }

    private func put(_ data: Data) -> (UnsafeMutablePointer<UInt8>, Int) {
        put([UInt8](data))
    }

    private func put<T: Encodable>(json value: T) throws -> (UnsafeMutablePointer<UInt8>, Int) {
        put(try JSONEncoder().encode(value))
    }

    /// The bytes the last call left in the result buffer.
    private func result() -> Data {
        Data(bytes: oc_result_ptr(), count: oc_result_len())
    }

    private func failure() -> EngineError {
        EngineError(message: String(decoding: result(), as: UTF8.self))
    }

    /// The result buffer as little-endian `Float32`s (geometry calls leave quads there).
    private func floats(_ data: Data) -> [Double] {
        data.withUnsafeBytes { raw in
            (0..<raw.count / 4).map { Double(raw.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self)) }
        }
    }

    // MARK: Fonts

    /// Registers every font file in `directory`, in the order the server and the
    /// browser use (file names by byte order), so glyph fallback picks the same face.
    /// Done once; later calls return the families found the first time.
    @discardableResult
    public func registerBundledFonts(in directory: URL) throws -> [String] {
        if let bundledFamilies { return bundledFamilies }
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { ["ttf", "otf"].contains(($0 as NSString).pathExtension.lowercased()) }
            .sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
        var families: [String] = []
        for name in names {
            let data = try Data(contentsOf: directory.appendingPathComponent(name))
            let (ptr, len) = put(data)
            if oc_add_font(ptr, len) == 1 { families.append(String(decoding: result(), as: UTF8.self)) }
        }
        bundledFamilies = families
        return families
    }

    public func hasFont(_ family: String) -> Bool {
        let (ptr, len) = put(family)
        return oc_has_font(ptr, len) == 1
    }

    /// Registers a font a style asked for, under that family name. Returns whether it parsed.
    public func addRequestedFont(family: String, data: Data) -> Bool {
        let (np, nl) = put(family)
        let (dp, dl) = put(data)
        return oc_add_requested_font(np, nl, dp, dl) == 1
    }

    // MARK: Drawing

    private struct SceneInput: Encodable {
        var transcript: Transcript
        var style: StyleConfig
        var width: Int
        var height: Int
        var captionOffsetMs: Int

        enum CodingKeys: String, CodingKey {
            case transcript, style, width, height
            case captionOffsetMs = "caption_offset_ms"
        }
    }

    /// Lays out the captions for a transcript, style and frame size.
    public func setScene(
        transcript: Transcript, style: StyleConfig, width: Int, height: Int, captionOffsetMs: Int
    ) throws {
        let input = SceneInput(
            transcript: transcript, style: style, width: width, height: height,
            captionOffsetMs: captionOffsetMs
        )
        try apply(input)
    }

    private func apply(_ input: SceneInput) throws {
        let (ptr, len) = try put(json: input)
        guard oc_set_scene(ptr, len) == 1 else { throw failure() }
        scene = input
    }

    /// One frame per style of `words`, as they look while the middle word is spoken: what a style
    /// picker shows. The same drawing as the preview and the export, so a tile cannot disagree with
    /// the result. The scene in use is put back before returning, so a preview open at the same
    /// time carries on unaffected. Fonts must have been made available (`ensureFont`) already.
    public func samples(
        of styles: [StyleConfig], words: [String], width: Int, height: Int
    ) -> [CaptionFrame?] {
        let previous = scene
        defer { if let previous { try? apply(previous) } }
        let step = 0.4
        let spoken = words.enumerated().map { i, text in
            Word(text: text, start: Double(i) * step, end: Double(i + 1) * step)
        }
        let transcript = Transcript(
            language: "en", languageDetection: .manual, duration: Double(words.count) * step,
            segments: [
                TranscriptSegment(
                    id: "sample", words: spoken, start: 0, end: Double(words.count) * step,
                    text: words.joined(separator: " "))
            ])
        let middle = (Double(words.count) / 2).rounded(.down) * step + step / 2
        return styles.map { style in
            var style = style
            style.positionX = 0.5
            style.positionY = 0.5
            style.wordsPerLine = max(style.wordsPerLine, words.count)
            do {
                try apply(
                    SceneInput(
                        transcript: transcript, style: style, width: width, height: height, captionOffsetMs: 0))
            } catch { return nil }
            return render(at: middle)
        }
    }

    /// The overlay at `t` seconds, or nil when it is unchanged since the last call.
    public func render(at t: Double) -> CaptionFrame? {
        guard oc_render(Float(t)) == 1, let pixels = oc_frame_ptr() else { return nil }
        let (w, h) = (Int(oc_frame_width()), Int(oc_frame_height()))
        return CaptionFrame(width: w, height: h, rgba: Data(bytes: pixels, count: w * h * 4))
    }

    /// The caption showing at the last rendered time, or nil when none shows.
    public func activeCaption() -> ActiveCaption? {
        let index = oc_active_index()
        guard index >= 0, oc_active_bounds() == 1 else { return nil }
        let box = floats(result())
        _ = oc_active_word_rects()
        let flat = floats(result())
        guard box.count == 4 else { return nil }
        let words = stride(from: 0, to: flat.count - 3, by: 4).map {
            FrameRect(x: flat[$0], y: flat[$0 + 1], width: flat[$0 + 2], height: flat[$0 + 3])
        }
        return ActiveCaption(
            bounds: FrameRect(x: box[0], y: box[1], width: box[2], height: box[3]),
            index: Int(index), words: words
        )
    }

    /// Magnetism for dragging the caption block: each axis snaps to the video's centre
    /// when the block's centre is within `threshold` of it. `width` and `height` are the
    /// preview's size in the unit of `threshold` (points), so the pull feels the same at
    /// any size. The rule is the engine's, so the web editor snaps identically.
    public func snapPosition(
        x: Double, y: Double, width: Double, height: Double, threshold: Double
    ) -> SnappedPosition {
        _ = oc_snap_position(Float(x), Float(y), Float(width), Float(height), Float(threshold))
        let v = floats(result())
        guard v.count == 4 else { return SnappedPosition(x: x, y: y, onX: false, onY: false) }
        return SnappedPosition(x: v[0], y: v[1], onX: v[2] == 1, onY: v[3] == 1)
    }

    // MARK: Edits

    private func decoded<T: Decodable>(_ ok: UInt32, as type: T.Type) throws -> T {
        guard ok == 1 else { throw failure() }
        return try JSONDecoder().decode(T.self, from: result())
    }

    /// The captions, cut every `wordsPerLine` words as the export cuts them, with
    /// times as shown (the caption offset applied).
    public func lines(_ t: Transcript, wordsPerLine: Int, offsetMs: Int) throws -> [CaptionLine] {
        let (ptr, len) = try put(json: t)
        return try decoded(
            oc_caption_lines(ptr, len, UInt32(wordsPerLine), Int32(offsetMs)), as: [CaptionLine].self)
    }

    /// Moves one edge of a word to `time` as shown, stopping at its neighbours. The
    /// returned transcript has unshifted times.
    public func retimeWord(
        _ t: Transcript, index: Int, edge: CaptionEdge, time: Double, offsetMs: Int
    ) throws -> Transcript {
        let (ptr, len) = try put(json: t)
        return try decoded(
            oc_retime_word(ptr, len, UInt32(index), UInt32(edge.rawValue), Float(time), Int32(offsetMs)),
            as: Transcript.self)
    }

    /// Sets the text of one word, keeping its timing. Empty text removes the word;
    /// text of several words is refused.
    public func setWord(_ t: Transcript, index: Int, text: String) throws -> Transcript {
        let (ptr, len) = try put(json: t)
        let (tp, tl) = put(text)
        return try decoded(oc_set_word(ptr, len, UInt32(index), tp, tl), as: Transcript.self)
    }
}

extension CaptionEngine {
    /// Makes `family` drawable: nothing to do for a bundled face, otherwise the font is
    /// fetched (once) and registered, the rule the server applies to an export, so both
    /// draw with the same file. Offline and uncached, the engine draws the default face.
    public func ensureFont(_ family: String, cache: FontCache) async {
        guard !hasFont(family) else { return }
        guard let data = await cache.data(for: family) else { return }
        if !hasFont(family) { _ = addRequestedFont(family: family, data: data) }
    }
}
