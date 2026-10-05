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
    @State private var importing = false
    @State private var path: [UUID] = []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if app.projects.isEmpty {
                    ContentUnavailableView {
                        Label("No projects yet", systemImage: "captions.bubble")
                    } description: {
                        Text("Import a video to caption it. Everything stays on this device.")
                    } actions: {
                        picker
                    }
                } else {
                    List {
                        ForEach(app.projects) { project in
                            NavigationLink(value: project.id) { ProjectRow(project: project) }
                        }
                        .onDelete { offsets in
                            for index in offsets { app.delete(app.projects[index]) }
                        }
                    }
                }
            }
            .navigationTitle("OpenCaptions")
            .toolbar {
                if !app.projects.isEmpty { ToolbarItem(placement: .primaryAction) { picker } }
            }
            .overlay { if importing { ProgressView("Importing…").padding().background(.regularMaterial, in: .rect(cornerRadius: 12)) } }
            .navigationDestination(for: UUID.self) { id in
                if let project = app.projects.first(where: { $0.id == id }) {
                    EditorView(project: project, store: app.store)
                }
            }
            .alert("Something went wrong", isPresented: .constant(app.errorMessage != nil)) {
                Button("OK") { app.errorMessage = nil }
            } message: {
                Text(app.errorMessage ?? "")
            }
        }
        .onChange(of: picked) { _, item in
            guard let item else { return }
            Task { await load(item) }
        }
        .onChange(of: path) { _, path in
            if path.isEmpty { app.reload() }
        }
    }

    private var picker: some View {
        PhotosPicker(selection: $picked, matching: .videos) {
            Label("Import video", systemImage: "plus")
        }
        .buttonStyle(.borderedProminent)
    }

    private func load(_ item: PhotosPickerItem) async {
        importing = true
        defer {
            importing = false
            picked = nil
        }
        guard let movie = try? await item.loadTransferable(type: PickedMovie.self) else {
            app.errorMessage = "That video could not be read."
            return
        }
        defer { try? FileManager.default.removeItem(at: movie.url) }
        let title = "Video " + Date().formatted(date: .abbreviated, time: .shortened)
        if let project = await app.importVideo(from: movie.url, title: title) {
            path.append(project.id)
        }
    }
}

private struct ProjectRow: View {
    @Environment(AppModel.self) private var app
    let project: Project

    var body: some View {
        HStack(spacing: 12) {
            Thumbnail(url: app.store.sourceURL(for: project.id))
                .frame(width: 48, height: 72)
                .clipShape(.rect(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text(project.title).font(.headline)
                Text(project.createdAt.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption).foregroundStyle(.secondary)
                Text(project.transcript == nil ? "Not transcribed" : "\(project.transcript?.words.count ?? 0) words")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// A frame from near the start of the clip.
private struct Thumbnail: View {
    let url: URL?
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            Color.gray.opacity(0.2)
            if let image { Image(decorative: image, scale: 1).resizable().scaledToFill() }
        }
        .task(id: url) {
            guard let url else { return }
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 200, height: 200)
            image = try? await generator.image(at: CMTime(seconds: 0.2, preferredTimescale: 600)).image
        }
    }
}
