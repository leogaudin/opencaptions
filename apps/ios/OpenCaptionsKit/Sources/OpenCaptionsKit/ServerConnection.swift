import Foundation

/// Another OpenCaptions backend this app can transcribe on: where it is, the key to use it, and a
/// name to show. The Docker stack's frontend, a GPU box at home, a friend's instance.
public struct ServerConnection: Equatable, Sendable {
    /// The instance's origin, e.g. `https://captions.example.org` or `http://192.168.1.20:5173`.
    public var url: URL
    public var key: String
    public var name: String?

    public init(url: URL, key: String, name: String? = nil) {
        self.url = url
        self.key = key
        self.name = name
    }

    /// What to call it on screen.
    public var displayName: String { name ?? url.host ?? url.absoluteString }

    /// An address as someone types it. Without a scheme, `http` for a machine on the local network
    /// (an IP address, `localhost`, a `.local` name) and `https` for anything else. Only the origin
    /// is kept, so a pasted page address works. Nil when it cannot be an address.
    public static func normalizedURL(_ text: String) -> URL? {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") {
            let host = text.split(separator: "/").first.map(String.init) ?? text
            let name = host.split(separator: ":").first.map(String.init) ?? host
            let local =
                name == "localhost" || name.hasSuffix(".local")
                || name.split(separator: ".").count == 4 && name.split(separator: ".").allSatisfy { Int($0) != nil }
            text = (local ? "http://" : "https://") + text
        }
        guard var parts = URLComponents(string: text), let scheme = parts.scheme?.lowercased(),
            scheme == "http" || scheme == "https", let host = parts.host, !host.isEmpty
        else { return nil }
        parts.scheme = scheme
        parts.path = ""
        parts.query = nil
        parts.fragment = nil
        parts.user = nil
        parts.password = nil
        return parts.url
    }

    /// The pairing link the web app makes for a new key: `opencaptions://connect?url=…&key=…[&name=…]`.
    public static func parse(link: URL) -> ServerConnection? {
        guard link.scheme == "opencaptions", link.host == "connect",
            let items = URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems
        else { return nil }
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard let address = value("url").flatMap(normalizedURL), let key = value("key"), !key.isEmpty else { return nil }
        return ServerConnection(url: address, key: key, name: value("name"))
    }
}

/// Somewhere to keep a secret. The Keychain in the app, memory in tests.
public protocol SecretStore: Sendable {
    func read(_ account: String) -> String?
    func write(_ value: String, for account: String)
    func delete(_ account: String)
}

public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    public init() {}

    public func read(_ account: String) -> String? { lock.withLock { values[account] } }
    public func write(_ value: String, for account: String) { lock.withLock { values[account] = value } }
    public func delete(_ account: String) { lock.withLock { _ = values.removeValue(forKey: account) } }
}

/// Which backend transcribes, remembered: the address and name in preferences, the key in the secret
/// store, and whether the server is in use or the phone is. Connecting does not switch to it by
/// itself being stored; `useServer` does.
public struct ServerSettings: Sendable {
    private let defaults: UserDefaultsBox
    private let secrets: any SecretStore
    private static let urlKey = "transcription.server.url"
    private static let nameKey = "transcription.server.name"
    private static let useKey = "transcription.server.use"
    private static let keyAccount = "transcription.server.key"

    public init(defaults: UserDefaults = .standard, secrets: any SecretStore) {
        self.defaults = UserDefaultsBox(defaults)
        self.secrets = secrets
    }

    public var connection: ServerConnection? {
        guard let text = defaults.value.string(forKey: Self.urlKey), let url = URL(string: text),
            let key = secrets.read(Self.keyAccount)
        else { return nil }
        return ServerConnection(url: url, key: key, name: defaults.value.string(forKey: Self.nameKey))
    }

    /// Whether transcription goes to the server (only ever true with one connected).
    public var useServer: Bool {
        get { connection != nil && defaults.value.bool(forKey: Self.useKey) }
        nonmutating set { defaults.value.set(newValue, forKey: Self.useKey) }
    }

    public func save(_ connection: ServerConnection, use: Bool = true) {
        defaults.value.set(connection.url.absoluteString, forKey: Self.urlKey)
        defaults.value.set(connection.name, forKey: Self.nameKey)
        secrets.write(connection.key, for: Self.keyAccount)
        defaults.value.set(use, forKey: Self.useKey)
    }

    public func disconnect() {
        for key in [Self.urlKey, Self.nameKey, Self.useKey] { defaults.value.removeObject(forKey: key) }
        secrets.delete(Self.keyAccount)
    }
}

/// `UserDefaults` is thread-safe but not marked `Sendable`.
private struct UserDefaultsBox: @unchecked Sendable {
    let value: UserDefaults
    init(_ value: UserDefaults) { self.value = value }
}
