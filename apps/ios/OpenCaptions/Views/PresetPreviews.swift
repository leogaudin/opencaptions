import CoreImage
import OpenCaptionsKit
import SwiftUI

/// What each preset looks like, drawn by the engine (the code that draws the preview and the
/// export, so a tile cannot disagree with the result) in the preset's own font, size and colours.
@MainActor @Observable
final class PresetPreviews {
    private(set) var images: [String: CGImage] = [:]
    @ObservationIgnored private var loading = false

    /// Draws the tiles that are missing. Fonts a preset needs are fetched first (once).
    func load(_ presets: [Preset], fonts: FontCache, engine: CaptionEngine = .shared) async {
        guard !loading, presets.contains(where: { images[$0.id] == nil }) else { return }
        loading = true
        defer { loading = false }
        let missing = presets.filter { images[$0.id] == nil }
        let drawn = await Self.draw(missing.map { ($0.id, $0.config) }, fonts: fonts, engine: engine)
        images.merge(drawn) { _, new in new }
    }

    /// Tiles for any looks, by id: the engine draws a sample caption in each, at one size so that
    /// they compare the looks and not how big each happened to be.
    static func draw(
        _ looks: [(id: String, config: StyleConfig)], fonts: FontCache, engine: CaptionEngine = .shared
    ) async -> [String: CGImage] {
        // Downloaded side by side (and kept), then registered one after another.
        let families = Set(looks.map(\.config.font))
        await withTaskGroup(of: Void.self) { group in
            for family in families { group.addTask { _ = await fonts.data(for: family) } }
        }
        for family in families { await engine.ensureFont(family, cache: fonts) }
        // Sizes are tuned against a tall video frame, so the sample is one (a phone video in
        // miniature) and the tile shows the band around the middle, where the caption is.
        let (width, height) = (540, 960)
        let crop = CGRect(x: 90, y: (height - 200) / 2, width: 360, height: 200)  // a closer look: 1.5x
        let frames = await engine.samples(
            of: looks.map { look in
                var config = look.config
                config.fontSize = 64
                return config
            }, words: ["Make", "it", "pop"], width: width, height: height)
        let context = CIContext()
        var images: [String: CGImage] = [:]
        for (look, frame) in zip(looks, frames) {
            guard let full = frame?.cgImage(using: context), let tile = full.cropping(to: crop) else { continue }
            images[look.id] = tile
        }
        return images
    }
}
