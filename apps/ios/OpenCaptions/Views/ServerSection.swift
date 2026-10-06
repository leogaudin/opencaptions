import OpenCaptionsKit
import SwiftUI

/// Where transcription happens: on this phone, or on another OpenCaptions server (a GPU box at home,
/// the Docker stack on a desktop). Connecting checks the server first, so what is kept works.
struct ServerSection: View {
    @Environment(AppModel.self) private var app
    @State private var connecting = false
    @State private var testing = false
    @State private var testResult: Result<ServerCapabilities, Error>?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Where to transcribe")
            SegmentedPills(
                options: [false, true], selection: Binding(get: { app.useServer }, set: choose),
                label: { $0 ? "My server" : "On this phone" })
            if let connection = app.serverConnection {
                connected(connection)
            } else {
                Text("Transcribe on another OpenCaptions server instead of on this phone: faster on a computer with a graphics card. Nothing changes until you connect one.")
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary).padding(.horizontal, 4)
                Button("Connect a server") { connecting = true }.buttonStyle(PillButtonStyle(prominent: true))
            }
        }
        #if DEBUG
            // Screenshots on a simulator: OC_SHOW_CONNECT opens the connect sheet.
            .task { if ProcessInfo.processInfo.environment["OC_SHOW_CONNECT"] != nil { connecting = true } }
        #endif
        .sheet(isPresented: $connecting) {
            ConnectServerSheet().presentationBackground(Theme.background).presentationCornerRadius(24)
        }
    }

    private func choose(_ useServer: Bool) {
        if useServer, app.serverConnection == nil {
            connecting = true
        } else {
            app.setUseServer(useServer)
        }
    }

    private func connected(_ connection: ServerConnection) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(connection.displayName).font(.system(size: 16, weight: .semibold))
                Text(connection.url.absoluteString).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            }
            HStack(spacing: 10) {
                Button(testing ? "Testing…" : "Test") { Task { await test(connection) } }
                    .buttonStyle(PillButtonStyle()).disabled(testing)
                Button("Disconnect", role: .destructive) {
                    testResult = nil
                    app.disconnectServer()
                }
                .buttonStyle(PillButtonStyle())
            }
            switch testResult {
            case .success(let caps):
                Label("Connected to \(caps.instanceName).", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .medium))
            case .failure(let error):
                Text(error.localizedDescription).font(.system(size: 13)).foregroundStyle(Theme.danger)
            case nil:
                EmptyView()
            }
            Text("With “My server” the audio of a video is sent to \(connection.url.host ?? "it") to be transcribed, and deleted there afterwards.")
                .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
        }
        .card()
    }

    private func test(_ connection: ServerConnection) async {
        testing = true
        defer { testing = false }
        do {
            testResult = .success(try await ServerTranscriber(connection: connection).capabilities())
        } catch {
            testResult = .failure(error)
        }
    }
}

/// Adds a server: paste the link the web app made, or type its address and a key. Nothing is saved until
/// the server has answered.
struct ConnectServerSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var key = ""
    @State private var name: String?
    @State private var checking = false
    @State private var problem: String?
    @FocusState private var focus: Field?
    private enum Field { case address, key }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Connect a server").font(.system(size: 22, weight: .heavy))
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(CircleButtonStyle()).accessibilityLabel("Close")
            }
            Text("In the server's web app, open Account and create a key: it comes with a link. Paste the link here, or enter the address and the key.")
                .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
            Button { paste() } label: { Label("Paste link", systemImage: "doc.on.clipboard") }
                .buttonStyle(PillButtonStyle())
            VStack(spacing: 10) {
                field("Address, e.g. 192.168.1.20:5173", text: $address, focus: .address)
                SecureField("Key (oc_…)", text: $key)
                    .focused($focus, equals: .key)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .font(.system(size: 16, weight: .medium))
                    .padding(.horizontal, 14).padding(.vertical, 12)
                    .background(Theme.raised, in: .rect(cornerRadius: 12))
            }
            if let problem { Text(problem).font(.system(size: 13)).foregroundStyle(Theme.danger) }
            Spacer(minLength: 0)
            Button(checking ? "Checking…" : "Connect") { Task { await connect() } }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(checking || address.isEmpty || key.isEmpty)
                .opacity(address.isEmpty || key.isEmpty ? 0.4 : 1)
        }
        .padding(.horizontal, 18).padding(.top, 24).padding(.bottom, 12)
        .presentationDetents([.large])
        .tint(Theme.accent)
    }

    private func field(_ placeholder: String, text: Binding<String>, focus target: Field) -> some View {
        TextField(placeholder, text: text)
            .focused($focus, equals: target)
            .keyboardType(.URL)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .font(.system(size: 16, weight: .medium))
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(Theme.raised, in: .rect(cornerRadius: 12))
    }

    private func paste() {
        problem = nil
        guard let text = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
            let link = URL(string: text), let connection = ServerConnection.parse(link: link)
        else {
            problem = "The clipboard does not hold an OpenCaptions link."
            return
        }
        address = connection.url.absoluteString
        key = connection.key
        name = connection.name
    }

    private func connect() async {
        problem = nil
        guard let url = ServerConnection.normalizedURL(address) else {
            problem = "That does not look like an address."
            return
        }
        let connection = ServerConnection(url: url, key: key.trimmingCharacters(in: .whitespacesAndNewlines), name: name)
        checking = true
        defer { checking = false }
        do {
            let caps = try await ServerTranscriber(connection: connection).capabilities()
            var named = connection
            named.name = name ?? caps.instanceName
            app.connect(named)
            dismiss()
        } catch {
            problem = error.localizedDescription
        }
    }
}

/// Asks before a pairing link, opened from a message or another app, is allowed to take the audio.
struct PairingConfirmation: ViewModifier {
    @Environment(AppModel.self) private var app

    func body(content: Content) -> some View {
        @Bindable var app = app
        content.confirmationDialog(
            "Transcribe on \(app.pendingConnection?.displayName ?? "this server")?",
            isPresented: Binding(get: { app.pendingConnection != nil }, set: { if !$0 { app.pendingConnection = nil } }),
            titleVisibility: .visible, presenting: app.pendingConnection
        ) { connection in
            Button("Use \(connection.displayName)") {
                app.connect(connection)
                app.pendingConnection = nil
            }
            Button("Cancel", role: .cancel) { app.pendingConnection = nil }
        } message: { connection in
            Text("The audio of your videos will be sent to \(connection.url.host ?? "it") to be transcribed there. Only continue if you trust it.")
        }
    }
}
