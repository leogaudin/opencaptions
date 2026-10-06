import CoreImage
import OpenCaptionsKit
import SwiftUI

/// What each preset looks like, drawn by the engine (the code that draws the preview and the
/// export, so a tile cannot disagree with the result) in the preset's own font, size and colours.
@MainActor @Observable
final class PresetPreviews {
    private(set) var images: [String: CGImage] = [:]
    @ObservationIgnored private var loading = false
    @ObservationIgnored private let context = CIContext()

    /// Draws the tiles that are missing. Fonts a preset needs are fetched first (once).
    func load(_ presets: [Preset], fonts: FontCache, engine: CaptionEngine = .shared) async {
        guard !loading, presets.contains(where: { images[$0.id] == nil }) else { return }
        loading = true
        defer { loading = false }
        let missing = presets.filter { images[$0.id] == nil }
        // Downloaded side by side (and kept), then registered one after another.
        let families = Set(missing.map(\.config.font))
        await withTaskGroup(of: Void.self) { group in
            for family in families { group.addTask { _ = await fonts.data(for: family) } }
        }
        for family in families { await engine.ensureFont(family, cache: fonts) }
        // Sizes are tuned against a tall video frame, so the sample is one (a phone video in
        // miniature) and the tile shows the band around the middle, where the caption is.
        let (width, height) = (540, 960)
        let crop = CGRect(x: 90, y: (height - 200) / 2, width: 360, height: 200)  // a closer look: 1.5x
        let frames = await engine.samples(
            of: missing.map { preset in
                // The same size for every tile: applying a preset keeps the user's size, so the
                // tiles compare looks, not how big each preset happened to be.
                var look = preset.config
                look.fontSize = 64
                return look
            }, words: ["Make", "it", "pop"], width: width, height: height)
        for (preset, frame) in zip(missing, frames) {
            guard let full = frame?.cgImage(using: context),
                let tile = full.cropping(to: crop)
            else { continue }
            images[preset.id] = tile
        }
    }
}
