import Foundation

// These mirror the API's Pydantic schemas (apps/api/app/models/schemas.py): the
// same names, snake_case keys and optionality, so a project moves between the phone
// and a server unchanged. A backend test validates the fixture these tests decode.

public struct Word: Codable, Equatable, Sendable {
    public var text: String
    /// Seconds from the start of the audio.
    public var start: Double
    public var end: Double
    public var confidence: Double

    public init(text: String, start: Double, end: Double, confidence: Double = 1) {
        self.text = text
        self.start = start
        self.end = end
        self.confidence = confidence
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decode(String.self, forKey: .text)
        start = try c.decode(Double.self, forKey: .start)
        end = try c.decode(Double.self, forKey: .end)
        confidence = try c.decodeIfPresent(Double.self, forKey: .confidence) ?? 1
    }
}

public struct TranscriptSegment: Codable, Equatable, Sendable {
    public var id: String
    public var words: [Word]
    public var start: Double
    public var end: Double
    public var text: String

    public init(id: String, words: [Word], start: Double, end: Double, text: String) {
        self.id = id
        self.words = words
        self.start = start
        self.end = end
        self.text = text
    }
}

public enum LanguageDetection: String, Codable, Sendable {
    case auto
    case manual
}

public struct Transcript: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    /// ISO 639-1 language code.
    public var language: String
    public var languageDetection: LanguageDetection
    public var duration: Double
    public var segments: [TranscriptSegment]

    public init(
        schemaVersion: Int = 1,
        language: String,
        languageDetection: LanguageDetection,
        duration: Double,
        segments: [TranscriptSegment]
    ) {
        self.schemaVersion = schemaVersion
        self.language = language
        self.languageDetection = languageDetection
        self.duration = duration
        self.segments = segments
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case language
        case languageDetection = "language_detection"
        case duration
        case segments
    }

    /// Every word in reading order across segments: the sequence captions are cut from.
    public var words: [Word] { segments.flatMap(\.words) }
}

public enum CaptionAnimation: String, Codable, CaseIterable, Sendable {
    case wordHighlight = "word_highlight"
    case highlightBox = "highlight_box"
    case wordPop = "word_pop"
    case wordFade = "word_fade"
    /// Karaoke: the highlight colour fills each word as it is said.
    case wordSweep = "word_sweep"
    case wordUnderline = "word_underline"
    case typewriter
}

public enum TextCase: String, Codable, CaseIterable, Sendable {
    case none
    case upper
}

public enum Background: String, Codable, CaseIterable, Sendable {
    case none
    case solid
    case pill
}

/// Caption styling. Colours are `#RRGGBB` (`#RRGGBBAA` for the shadow). There is no
/// default value here on purpose: the defaults are the first preset in `presets.json`.
public struct StyleConfig: Codable, Equatable, Sendable {
    public var font: String
    public var fontSize: Int
    public var textColor: String
    public var highlightColor: String
    public var background: Background
    public var backgroundColor: String
    public var backgroundOpacity: Double
    /// Normalised centre of the caption block, 0...1 across the frame.
    public var positionX: Double
    public var positionY: Double
    public var animation: CaptionAnimation
    public var wordsPerLine: Int
    public var wordSpacing: Double
    public var strokeWidth: Double
    public var strokeColor: String
    public var shadowBlur: Double
    public var shadowColor: String
    /// Where the shadow falls (tuned like its blur); with no blur it is solid and drawn as an extrusion.
    public var shadowOffsetX: Double
    public var shadowOffsetY: Double
    /// A halo of `glowColor` around the letters; 0 for none.
    public var glowBlur: Double
    public var glowColor: String
    public var textCase: TextCase
    /// Letters leaned to the right (the engine shears the upright face).
    public var italic: Bool

    public init(
        font: String, fontSize: Int, textColor: String, highlightColor: String,
        background: Background, backgroundColor: String, backgroundOpacity: Double,
        positionX: Double, positionY: Double, animation: CaptionAnimation, wordsPerLine: Int,
        wordSpacing: Double, strokeWidth: Double, strokeColor: String, shadowBlur: Double,
        shadowColor: String, shadowOffsetX: Double = 0, shadowOffsetY: Double = 0, glowBlur: Double = 0,
        glowColor: String = "#FFFFFF", textCase: TextCase = .none, italic: Bool = false
    ) {
        self.font = font
        self.fontSize = fontSize
        self.textColor = textColor
        self.highlightColor = highlightColor
        self.background = background
        self.backgroundColor = backgroundColor
        self.backgroundOpacity = backgroundOpacity
        self.positionX = positionX
        self.positionY = positionY
        self.animation = animation
        self.wordsPerLine = wordsPerLine
        self.wordSpacing = wordSpacing
        self.strokeWidth = strokeWidth
        self.strokeColor = strokeColor
        self.shadowBlur = shadowBlur
        self.shadowColor = shadowColor
        self.shadowOffsetX = shadowOffsetX
        self.shadowOffsetY = shadowOffsetY
        self.glowBlur = glowBlur
        self.glowColor = glowColor
        self.textCase = textCase
        self.italic = italic
    }

    /// The fields a style gained later may be missing from a project saved before: they take their defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            font: try c.decode(String.self, forKey: .font), fontSize: try c.decode(Int.self, forKey: .fontSize),
            textColor: try c.decode(String.self, forKey: .textColor),
            highlightColor: try c.decode(String.self, forKey: .highlightColor),
            background: try c.decode(Background.self, forKey: .background),
            backgroundColor: try c.decode(String.self, forKey: .backgroundColor),
            backgroundOpacity: try c.decode(Double.self, forKey: .backgroundOpacity),
            positionX: try c.decode(Double.self, forKey: .positionX), positionY: try c.decode(Double.self, forKey: .positionY),
            animation: try c.decode(CaptionAnimation.self, forKey: .animation),
            wordsPerLine: try c.decode(Int.self, forKey: .wordsPerLine),
            wordSpacing: try c.decode(Double.self, forKey: .wordSpacing),
            strokeWidth: try c.decode(Double.self, forKey: .strokeWidth),
            strokeColor: try c.decode(String.self, forKey: .strokeColor),
            shadowBlur: try c.decode(Double.self, forKey: .shadowBlur),
            shadowColor: try c.decode(String.self, forKey: .shadowColor),
            shadowOffsetX: try c.decodeIfPresent(Double.self, forKey: .shadowOffsetX) ?? 0,
            shadowOffsetY: try c.decodeIfPresent(Double.self, forKey: .shadowOffsetY) ?? 0,
            glowBlur: try c.decodeIfPresent(Double.self, forKey: .glowBlur) ?? 0,
            glowColor: try c.decodeIfPresent(String.self, forKey: .glowColor) ?? "#FFFFFF",
            textCase: try c.decodeIfPresent(TextCase.self, forKey: .textCase) ?? .none,
            italic: try c.decodeIfPresent(Bool.self, forKey: .italic) ?? false)
    }

    enum CodingKeys: String, CodingKey {
        case font
        case fontSize = "font_size"
        case textColor = "text_color"
        case highlightColor = "highlight_color"
        case background
        case backgroundColor = "background_color"
        case backgroundOpacity = "background_opacity"
        case positionX = "position_x"
        case positionY = "position_y"
        case animation
        case wordsPerLine = "words_per_line"
        case wordSpacing = "word_spacing"
        case strokeWidth = "stroke_width"
        case strokeColor = "stroke_color"
        case shadowBlur = "shadow_blur"
        case shadowColor = "shadow_color"
        case shadowOffsetX = "shadow_offset_x"
        case shadowOffsetY = "shadow_offset_y"
        case glowBlur = "glow_blur"
        case glowColor = "glow_color"
        case textCase = "text_case"
        case italic
    }
}
