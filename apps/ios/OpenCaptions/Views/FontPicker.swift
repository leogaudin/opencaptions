import CoreText
import OpenCaptionsKit
import SwiftUI

/// Makes a family drawable in the interface (not in a caption, which the engine draws): the
/// small subset that can draw only the family's name is fetched, once, and registered for this
/// process, so a row can show its name in its own face.
@MainActor @Observable
final class FontSamples {
    static let shared = FontSamples()
    /// Family to the name the face registered under (a file of one weight of Poppins is
    /// "Poppins-ExtraBold", not "Poppins").
    private(set) var faces: [String: String] = [:]
    @ObservationIgnored private var started: Set<String> = []

    func load(_ family: String, cache: FontCache) async {
        guard started.insert(family).inserted else { return }
        guard let url = await cache.sample(for: family) else {
            started.remove(family)  // offline now; try again when the row is next shown
            return
        }
        // Already registered (a second launch of the same file) is fine, and so is a failure:
        // the row then shows its name in the system face.
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor]
        if let name = descriptors?.first.flatMap({ CTFontDescriptorCopyAttribute($0, kCTFontNameAttribute) as? String }) {
            faces[family] = name
        }
    }
}

/// A family's name in that family.
struct FontName: View {
    @Environment(AppModel.self) private var app
    let family: String
    var size: CGFloat = 18

    var body: some View {
        Text(family)
            .font(FontSamples.shared.faces[family].map { .custom($0, size: size) } ?? .system(size: size, weight: .semibold))
            .lineLimit(1)
            .task(id: family) { await FontSamples.shared.load(family, cache: app.fontCache) }
    }
}

/// Choosing the caption font: the ones in use, each shown in its own face, then "More fonts" for
/// the whole Google Fonts catalog, searchable (as the desktop's picker is).
struct FontPickerSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let current: String
    let suggested: [String]
    let onSelect: (String) -> Void

    @State private var browsing = false
    @State private var query = ""
    @State private var catalog: [FontFamilyInfo] = []
    @State private var loadedCatalog = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if browsing { catalogList } else { shortList }
        }
        .background(Theme.background.ignoresSafeArea())
        .tint(Theme.accent)
    }

    private var header: some View {
        HStack {
            if browsing {
                Button { browsing = false; query = "" } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(CircleButtonStyle())
                    .accessibilityLabel("Back")
            }
            Text(browsing ? "More fonts" : "Font").font(.system(size: 22, weight: .heavy))
            Spacer()
            Button("Done") { dismiss() }.buttonStyle(PillButtonStyle(prominent: true))
        }
        .padding(.horizontal, 18).padding(.top, 20).padding(.bottom, 12)
    }

    private var shortList: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(suggested, id: \.self) { row($0) }
                Button { browsing = true } label: {
                    HStack {
                        Label("More fonts", systemImage: "textformat")
                            .font(.system(size: 16, weight: .semibold))
                        Spacer()
                        Text("Google Fonts").font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                        Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.textSecondary)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 16)
                    .foregroundStyle(Theme.textPrimary)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            .background(Theme.surface, in: .rect(cornerRadius: Theme.radius))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.stroke, lineWidth: 1))
            .padding(.horizontal, 16).padding(.bottom, 24)
        }
    }

    private var matches: [FontFamilyInfo] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? catalog : catalog.filter { $0.family.lowercased().contains(q) }
    }

    private var catalogList: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.textSecondary)
                TextField("Search fonts", text: $query)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            .background(Theme.raised, in: .rect(cornerRadius: 12))
            .padding(.horizontal, 16)
            if catalog.isEmpty {
                Spacer()
                if loadedCatalog {
                    VStack(spacing: 10) {
                        Text("The font list could not be loaded.").font(.system(size: 15, weight: .semibold))
                        Text("Check your connection and try again.").font(.footnote).foregroundStyle(Theme.textSecondary)
                        Button("Try again") { Task { await loadCatalog() } }.buttonStyle(PillButtonStyle(prominent: true))
                    }
                } else {
                    ProgressView()
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(matches) { row($0.family) }
                        if matches.isEmpty {
                            Text("No font matches “\(query)”.").font(.footnote).foregroundStyle(Theme.textSecondary).padding(24)
                        }
                    }
                    .background(Theme.surface, in: .rect(cornerRadius: Theme.radius))
                    .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.stroke, lineWidth: 1))
                    .padding(.horizontal, 16).padding(.bottom, 24)
                }
                .scrollDismissesKeyboard(.immediately)
            }
        }
        .task { if catalog.isEmpty { await loadCatalog() } }
    }

    private func loadCatalog() async {
        loadedCatalog = false
        catalog = await app.fontCatalog.families()
        loadedCatalog = true
    }

    private func row(_ family: String) -> some View {
        Button {
            onSelect(family)
            dismiss()
        } label: {
            HStack(spacing: 10) {
                FontName(family: family, size: 19)
                Spacer(minLength: 8)
                if family == current {
                    Image(systemName: "checkmark").font(.system(size: 14, weight: .heavy)).foregroundStyle(Theme.textPrimary)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 13)
            .foregroundStyle(Theme.textPrimary)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(family == current ? .isSelected : [])
    }
}
