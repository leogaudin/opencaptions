import AVFoundation
import OpenCaptionsKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// A video picked from Photos, copied to a temporary file the app owns.
struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let copy = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return PickedMovie(url: copy)
        }
    }
}

struct ProjectsView: View {
    @Environment(AppModel.self) private var app
    @State private var picked: PhotosPickerItem?
    @State private var importing: String?  // what the spinner says, while there is one
    @State private var pending: PendingImport?
    @State private var path: [UUID] = []
    @State private var deleting: Project?
    @State private var renaming: Project?

    private let columns = [GridItem(.adaptive(minimum: 158, maximum: 240), spacing: 14)]

    var body: some View {
        NavigationStack(path: $path) { library }
            .modifier(
                ProjectDialogs(
                    deleting: $deleting, pending: $pending, renaming: $renaming, onDelete: { app.delete($0) },
                    choose: { item in Task { await confirm(item) } }))
        #if DEBUG
            // Screenshots on a simulator: open the first project straight away.
            .task(id: app.projects.first?.id) {
                if ProcessInfo.processInfo.environment["OC_OPEN_FIRST"] != nil, path.isEmpty,
                    let first = app.projects.first
                {
                    path.append(first.id)
                }
            }
        #endif
        #if DEBUG
            // Screenshots on a simulator: OC_SHOW_IMPORT=<video> shows the import confirmation for it.
            .task {
                guard let path = ProcessInfo.processInfo.environment["OC_SHOW_IMPORT"] else { return }
                let copy = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).mp4")
                try? FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: copy)
                if let info = try? await VideoProbe.probe(copy) {
                    pending = PendingImport(url: copy, title: "Video 6 Oct 2026", info: info, poster: await PendingImport.poster(of: copy))
                }
            }
        #endif
        .onChange(of: picked) { _, item in
            guard let item else { return }
            Task { await load(item) }
        }
        .onChange(of: path) { _, path in
            if path.isEmpty { app.reload() }
        }
    }

    /// The header and the grid of projects (or the empty state).
    private var library: some View {
        VStack(spacing: 0) {
            header
            if app.projects.isEmpty { emptyState } else { grid }
        }
        .background(Theme.background.ignoresSafeArea())
        .fadesIntoTabBar()
        .toolbar(.hidden, for: .navigationBar)
        .overlay { if importing != nil { importingCard } }
        .navigationDestination(for: UUID.self) { id in
            if let project = app.projects.first(where: { $0.id == id }) {
                EditorView(model: app.editor(for: project))
            }
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 18) {
                ForEach(app.projects) { project in
                    NavigationLink(value: project.id) { ProjectCard(project: project) }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Rename", systemImage: "pencil") { renaming = project }
                            // The app's tint is black, which would make the destructive item black too.
                            Button(role: .destructive) { deleting = project } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            .tint(Theme.danger)
                        }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
        }
        // Under the tab bar, which the content dissolves into (`fadesIntoTabBar`): the scroll view
        // keeps its own inset, so the last row can still be scrolled clear of the bar.
        .contentMargins(.bottom, tabBarClearance, for: .scrollContent)
        .ignoresSafeArea(.container, edges: .bottom)
    }

    // MARK: Pieces

    private var header: some View {
        HStack(spacing: 10) {
            Wordmark()
            Spacer()
            if !app.projects.isEmpty {
                picker { Image(systemName: "plus") }.buttonStyle(CircleButtonStyle(prominent: true))
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }

    /// `.current` hands over the video as it is stored; the default may transcode it first,
    /// which is slow for a long clip.
    private func picker<Label: View>(@ViewBuilder label: () -> Label) -> some View {
        PhotosPicker(selection: $picked, matching: .videos, preferredItemEncoding: .current, label: label)
    }

    private var emptyState: some View {
        VStack(spacing: 28) {
            Spacer()
            // A caption as the app draws one: the spoken word in yellow.
            VStack(spacing: 14) {
                Text("Add captions that move")
                    .font(.system(size: 30, weight: .heavy)).multilineTextAlignment(.center)
                    .foregroundStyle(Theme.textPrimary)
                (Text("Transcribe, restyle and ").foregroundStyle(.white) + Text("save").foregroundStyle(Theme.accent)
                    + Text(" a video, all on this phone.").foregroundStyle(.white))
                    .font(.system(size: 17, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 18).padding(.vertical, 12)
                    .background(.black.opacity(0.75), in: .rect(cornerRadius: 22))
                    .overlay(RoundedRectangle(cornerRadius: 22).stroke(Theme.stroke, lineWidth: 1))
            }
            Text("Nothing is uploaded: the transcription runs on your device.")
                .font(.system(size: 14)).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
            picker {
                Label("Import a video", systemImage: "plus")
            }
            .buttonStyle(PrimaryButtonStyle())
            .padding(.horizontal, 40)
            Spacer()
            Spacer()
        }
        .padding(.horizontal, 24)
    }

    private var importingCard: some View {
        VStack(spacing: 12) {
            ProgressView().tint(Theme.accent)
            Text(importing ?? "").font(.system(size: 15, weight: .semibold))
        }
        .padding(.horizontal, 28).padding(.vertical, 22)
        .background(Theme.raised, in: .rect(cornerRadius: Theme.radius))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.stroke, lineWidth: 1))
    }

    /// A picked video is copied somewhere the app owns and looked at, then the user is shown it and
    /// decides: nothing is imported until they say so.
    private func load(_ item: PhotosPickerItem) async {
        importing = "Preparing your video…"
        defer {
            importing = nil
            picked = nil
        }
        guard let movie = try? await item.loadTransferable(type: PickedMovie.self) else {
            app.errorMessage = "That video could not be read."
            return
        }
        guard let info = try? await VideoProbe.probe(movie.url) else {
            try? FileManager.default.removeItem(at: movie.url)
            app.errorMessage = "That file does not look like a video."
            return
        }
        pending = PendingImport(
            url: movie.url, title: "Video " + Date().formatted(date: .abbreviated, time: .shortened),
            info: info, poster: await PendingImport.poster(of: movie.url))
    }

    private func confirm(_ item: PendingImport) async {
        pending = nil
        importing = "Importing…"
        defer { importing = nil }
        let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let project = await app.importVideo(
            from: item.url, title: title.isEmpty ? "Untitled" : title, move: true)
        {
            path.append(project.id)
        }
    }
}

// MARK: Project card

struct ProjectCard: View {
    @Environment(AppModel.self) private var app
    let project: Project
    /// What the project takes on disk, once counted (it is off the main thread, and again when the
    /// project changes).
    @State private var bytes: Int64?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Thumbnail(url: app.store.sourceURL(for: project.id))
                .aspectRatio(9.0 / 16.0, contentMode: .fit)
                .overlay(alignment: .topTrailing) {
                    if let seconds = project.videoDuration, seconds > 0 {
                        Text(Self.length(seconds))
                            .font(.system(size: 12, weight: .bold).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(.black.opacity(0.6), in: .capsule)
                            .padding(8)
                    }
                }
                .clipShape(.rect(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.stroke, lineWidth: 1))
            VStack(alignment: .leading, spacing: 2) {
                Text((app.openEditor(for: project.id)?.project ?? project).title)
                    .font(.system(size: 15, weight: .semibold)).lineLimit(1)
                status.font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            }
        }
        .contentShape(.rect)
        .task(id: project.updatedAt) {
            let (store, id) = (app.store, project.id)
            bytes = await Task.detached { store.size(of: id) }.value
        }
    }

    private static func length(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// What is happening to the project: a transcription in progress, else its size.
    @ViewBuilder private var status: some View {
        if let model = app.openEditor(for: project.id), case .running(let fraction, _) = model.transcription {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini).tint(Theme.accent)
                Text(fraction > 0 ? "Transcribing… \(Int(fraction * 100))%" : "Transcribing…")
                    .foregroundStyle(Theme.textSecondary)
            }
        } else if let transcript = (app.openEditor(for: project.id)?.project ?? project).transcript {
            Text(
                [bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) },
                    project.createdAt.formatted(date: .abbreviated, time: .omitted)]
                    .compactMap { $0 }.joined(separator: " · "))
        } else {
            Text("Not transcribed")
        }
    }
}

/// A frame from near the start of the clip.
private struct Thumbnail: View {
    let url: URL?
    @State private var image: CGImage?

    var body: some View {
        // The shape is the colour's (whatever the proposed size is); the picture only fills it and
        // is cropped to it, so a landscape video cannot widen the card.
        Theme.surface
            .overlay {
                if let image { Image(decorative: image, scale: 1).resizable().scaledToFill() }
            }
            .clipped()
        .task(id: url) {
            guard let url else { return }
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 480, height: 480)
            image = try? await generator.image(at: CMTime(seconds: 0.2, preferredTimescale: 600)).image
        }
    }
}

/// The questions this screen asks: rename a project, delete one, import the video just picked, and report
/// an error. One alert serves the delete question and the error: several `.alert`s on one view compete,
/// and only one of them is reliably shown.
private struct ProjectDialogs: ViewModifier {
    @Environment(AppModel.self) private var app
    @Binding var deleting: Project?
    @Binding var pending: PendingImport?
    @Binding var renaming: Project?
    let onDelete: (Project) -> Void
    let choose: (PendingImport) -> Void

    private enum Prompt {
        case delete(Project)
        case error(String)
    }

    private var prompt: Prompt? {
        if let deleting { return .delete(deleting) }
        if let message = app.errorMessage { return .error(message) }
        return nil
    }

    func body(content: Content) -> some View {
        content
            .alert(
                alertTitle, isPresented: Binding(get: { prompt != nil }, set: { if !$0 { deleting = nil; app.errorMessage = nil } }),
                presenting: prompt
            ) { prompt in
                switch prompt {
                case .delete(let project):
                    Button("Cancel", role: .cancel) {}
                    Button("Delete “\(project.title)”", role: .destructive) { onDelete(project) }
                case .error:
                    Button("OK") {}
                }
            } message: { prompt in
                switch prompt {
                case .delete: Text("The video and its captions are removed from this device.")
                case .error(let message): Text(message)
                }
            }
            .sheet(item: $renaming) { project in
                RenameSheet(project: project) { title in
                    app.rename(project, to: title)
                    renaming = nil
                } cancel: {
                    renaming = nil
                }
                .presentationBackground(Theme.background)
                .presentationCornerRadius(24)
            }
            .sheet(item: $pending) { item in
                ImportConfirmSheet(
                    item: item, choose: choose,
                    cancel: {
                        try? FileManager.default.removeItem(at: item.url)
                        pending = nil
                    })
                .presentationBackground(Theme.background)
                .presentationCornerRadius(24)
            }
    }

    private var alertTitle: String {
        if case .delete = prompt { return "Delete this project?" }
        return "Something went wrong"
    }
}

/// Renaming a project: its name in a field, selected, with the keyboard up.
struct RenameSheet: View {
    let project: Project
    let save: (String) -> Void
    let cancel: () -> Void
    @State private var title: String
    @State private var selection: TextSelection?
    @FocusState private var focused: Bool

    init(project: Project, save: @escaping (String) -> Void, cancel: @escaping () -> Void) {
        self.project = project
        self.save = save
        self.cancel = cancel
        _title = State(initialValue: project.title)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename").font(.system(size: 22, weight: .heavy))
            TextField("Name", text: $title, selection: $selection)
                .focused($focused)
                .submitLabel(.done)
                .onSubmit { save(title) }
                .font(.system(size: 18, weight: .semibold))
                .padding(.horizontal, 14).padding(.vertical, 12)
                .background(Theme.raised, in: .rect(cornerRadius: 12))
            HStack(spacing: 10) {
                Button("Cancel", action: cancel).buttonStyle(SecondaryButtonStyle())
                Button("Save") { save(title) }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal, 18).padding(.top, 24).padding(.bottom, 8)
        .presentationDetents([.height(210)])
        .presentationDragIndicator(.visible)
        .tint(Theme.accent)
        .onAppear {
            focused = true
            Task {
                try? await Task.sleep(for: .milliseconds(80))
                selection = TextSelection(range: title.startIndex..<title.endIndex)
            }
        }
    }
}
