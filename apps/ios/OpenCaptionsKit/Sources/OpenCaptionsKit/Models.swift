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
    /// The word's look: an index into the style's `variants`; nil is the style's own. An index past
    /// the end draws as the style's own and is kept, so a preset with more looks gives it back.
    public var variant: Int?

    public init(text: String, start: Double, end: Double, confidence: Double = 1, variant: Int? = nil) {
        self.text = text
        self.start = start
        self.end = end
        self.confidence = confidence
        self.variant = variant
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decode(String.self, forKey: .text)
        start = try c.decode(Double.self, forKey: .start)
        end = try c.decode(Double.self, forKey: .end)
        confidence = try c.decodeIfPresent(Double.self, forKey: .confidence) ?? 1
        variant = try c.decodeIfPresent(Int.self, forKey: .variant)
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
    /// Nothing moves: the line is shown as it is.
    case none
    case wordBounce = "word_bounce"
    case lyricFocus = "lyric_focus"
    case highlightSlide = "highlight_slide"
    case lineBar = "line_bar"
    case stickers
    case wordPress = "word_press"
    case letterRise = "letter_rise"
    case wordSlam = "word_slam"
    case drift = "drift"
    /// Each word comes out of a short blur as it is said; nothing moves.
    case blurIn = "blur_in"
}

public enum CaptionAlign: String, Codable, CaseIterable, Sendable {
    /// Rows are centred on each other, and the block on `positionX`.
    case center
    /// Rows start at the block's left edge, and `positionX` is where that edge sits.
    case left
    /// Rows end at the block's right edge, and `positionX` is where that edge sits.
    case right
    /// A poster: short rows, each scaled up to the widest one's width and stacked tight.
    case justify

    /// A left- or right-aligned block is held by its edge.
    var holdsAnEdge: Bool { self == .left || self == .right }

    /// How far in from its side a block held by its edge is put (a share of the frame).
    public static let edgeMargin = 0.06

    /// What the engine puts at `positionX` across the frame: the block's middle, or its edge.
    public var anchor: BlockAnchor {
        switch self {
        case .left: .start
        case .right: .end
        case .center, .justify: .middle
        }
    }
}

/// Which part of a caption block sits at its position: the middle, or the edge it is held by.
public enum BlockAnchor: Sendable {
    case middle, start, end

    /// The part of the block that is at the position: 0 its start, 0.5 its middle, 1 its end.
    public var fraction: Double {
        switch self {
        case .start: 0
        case .middle: 0.5
        case .end: 1
        }
    }
}

public enum TextCase: String, Codable, CaseIterable, Sendable {
    case none
    case upper
}

public enum Background: String, Codable, CaseIterable, Sendable {
    case none
    case solid
    case pill
    /// A rectangle with sharp corners.
    case square
}

/// How one word differs from the style's look: what is nil is the style's own.
public struct WordVariant: Codable, Equatable, Sendable {
    public var font: String?
    /// A multiple of the style's font size.
    public var scale: Double?
    public var italic: Bool?
    public var textCase: TextCase?
    public var textColor: String?
    public var letterSpacing: Double?
    public var stretch: Double?
    /// A square box of this colour behind the word: a name's label.
    public var boxColor: String?

    public init(
        font: String? = nil, scale: Double? = nil, italic: Bool? = nil, textCase: TextCase? = nil,
        textColor: String? = nil, letterSpacing: Double? = nil, stretch: Double? = nil, boxColor: String? = nil
    ) {
        self.font = font
        self.scale = scale
        self.italic = italic
        self.textCase = textCase
        self.textColor = textColor
        self.letterSpacing = letterSpacing
        self.stretch = stretch
        self.boxColor = boxColor
    }

    enum CodingKeys: String, CodingKey {
        case font, scale, italic
        case textCase = "text_case"
        case textColor = "text_color"
        case letterSpacing = "letter_spacing"
        case stretch
        case boxColor = "box_color"
    }
}

/// Caption styling. Colours are `#RRGGBB` (`#RRGGBBAA` for the shadow). There is no
/// default value here on purpose: the defaults are the first preset in `presets.json`.
public struct StyleConfig: Codable, Equatable, Sendable {
    public var font: String
    public var fontSize: Int
    public var textColor: String
    /// What the animation paints in; the first is the primary. A look that marks each word takes them in
    /// turn, a single shape (the sliding box, the bar) is the primary, and a sweep runs through all of them.
    public var highlightColors: [String]
    public var background: Background
    public var backgroundColor: String
    public var backgroundOpacity: Double
    /// Normalised place of the caption block across the frame, 0...1: its centre, or for `left` and `right`
    /// alignment its edge.
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
    /// A vertical gradient over each word's letters, top to baseline; empty is `textColor`.
    public var fillColors: [String]
    /// How much a solid shadow (an extrusion) darkens from the front to the back, 0...1.
    public var extrudeShade: Double
    /// The colour the back of an extrusion fades to from `shadowColor`; clear for none.
    public var extrudeBack: String
    /// How the rows sit in the block, and what `positionX` holds.
    public var align: CaptionAlign
    /// Extra space after each letter, as a share of the font size (negative to tighten).
    public var letterSpacing: Double
    /// How much wider (or narrower, below 1) the letters are drawn than the face has them.
    public var stretch: Double
    /// Looks a word can be given instead of the style's own (`Word.variant` is an index into this); a
    /// preset defines them and the editor only picks.
    public var variants: [WordVariant]

    public init(
        font: String, fontSize: Int, textColor: String, highlightColors: [String],
        background: Background, backgroundColor: String, backgroundOpacity: Double,
        positionX: Double, positionY: Double, animation: CaptionAnimation, wordsPerLine: Int,
        wordSpacing: Double, strokeWidth: Double, strokeColor: String, shadowBlur: Double,
        shadowColor: String, shadowOffsetX: Double = 0, shadowOffsetY: Double = 0, glowBlur: Double = 0,
        glowColor: String = "#FFFFFF", textCase: TextCase = .none, italic: Bool = false,
        fillColors: [String] = [], extrudeShade: Double = 0, extrudeBack: String = "#00000000",
        align: CaptionAlign = .center, letterSpacing: Double = 0, stretch: Double = 1,
        variants: [WordVariant] = []
    ) {
        self.font = font
        self.fontSize = fontSize
        self.textColor = textColor
        self.highlightColors = highlightColors
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
        self.fillColors = fillColors
        self.extrudeShade = extrudeShade
        self.extrudeBack = extrudeBack
        self.align = align
        self.letterSpacing = letterSpacing
        self.stretch = stretch
        self.variants = variants
    }

    /// The fields a style gained later may be missing from a project saved before: they take their defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            font: try c.decode(String.self, forKey: .font), fontSize: try c.decode(Int.self, forKey: .fontSize),
            textColor: try c.decode(String.self, forKey: .textColor),
            highlightColors: try Self.decodeHighlightColors(decoder, c),
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
            italic: try c.decodeIfPresent(Bool.self, forKey: .italic) ?? false,
            fillColors: try c.decodeIfPresent([String].self, forKey: .fillColors) ?? [],
            extrudeShade: try c.decodeIfPresent(Double.self, forKey: .extrudeShade) ?? 0,
            extrudeBack: try c.decodeIfPresent(String.self, forKey: .extrudeBack) ?? "#00000000",
            align: try Self.decodeAlign(decoder, c),
            letterSpacing: try c.decodeIfPresent(Double.self, forKey: .letterSpacing) ?? 0,
            stretch: try c.decodeIfPresent(Double.self, forKey: .stretch) ?? 1,
            variants: try c.decodeIfPresent([WordVariant].self, forKey: .variants) ?? [])
    }

    /// A project saved before `align` has a `layout`, whose `stack` is now `justify`.
    private static func decodeAlign(_ decoder: Decoder, _ c: KeyedDecodingContainer<CodingKeys>) throws -> CaptionAlign {
        if let align = try c.decodeIfPresent(CaptionAlign.self, forKey: .align) { return align }
        let earlier = try decoder.container(keyedBy: Earlier.self)
        return try earlier.decodeIfPresent(String.self, forKey: .layout) == "stack" ? .justify : .center
    }

    /// Where `positionX` goes when the alignment changes (as the web's `positionOnAlign`): a block held by its
    /// edge moves to that edge, and back to the middle when it stops being; between centred ones it stays.
    public func positionX(afterAligning to: CaptionAlign) -> Double {
        guard align != to, align.holdsAnEdge || to.holdsAnEdge else { return positionX }
        switch to {
        case .left: return CaptionAlign.edgeMargin
        case .right: return 1 - CaptionAlign.edgeMargin
        case .center, .justify: return 0.5
        }
    }

    /// A project saved before the colours became a list holds the one colour (and, in a build or two, an
    /// end colour for a sweep): they become the first and second of the list.
    private enum Earlier: String, CodingKey {
        case highlightColor = "highlight_color"
        case highlightColorEnd = "highlight_color_end"
        case layout
    }

    private static func decodeHighlightColors(_ decoder: Decoder, _ c: KeyedDecodingContainer<CodingKeys>) throws -> [String] {
        if let colors = try c.decodeIfPresent([String].self, forKey: .highlightColors), !colors.isEmpty { return colors }
        let earlier = try decoder.container(keyedBy: Earlier.self)
        let first = try earlier.decode(String.self, forKey: .highlightColor)
        let end = try earlier.decodeIfPresent(String.self, forKey: .highlightColorEnd)
        return [first] + [end].compactMap { $0 }
    }

    enum CodingKeys: String, CodingKey {
        case font
        case fontSize = "font_size"
        case textColor = "text_color"
        case highlightColors = "highlight_colors"
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
        case fillColors = "fill_colors"
        case extrudeShade = "extrude_shade"
        case extrudeBack = "extrude_back"
        case align
        case letterSpacing = "letter_spacing"
        case stretch
        case variants
    }
}
