import Foundation
import Security

/// What the app remembers about the Pi, as `client.json` does for the CLI. Nothing in it
/// is secret, but it's kept in the keychain so it stays off backups along with the key.
struct Login: Codable, Sendable, Equatable {
    /// Addresses as host:port, tried in order. `raspberrypi` works on the home network and,
    /// with Tailscale's MagicDNS on, away from it too; a second address is a fallback.
    var hosts: [String]
    /// The server certificate's SHA-256, from `tramline fingerprint` on the Pi.
    var fingerprint: String

    private static let account = "login"
    private static let service = "com.alar.tramline"

    static func load() -> Login? {
        var out: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
        ] as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(Login.self, from: data)
    }

    func save() throws {
        let data = try JSONEncoder().encode(self)
        Login.forget()
        let status = SecItemAdd([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Login.service,
            kSecAttrAccount: Login.account,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData: data,
        ] as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw DeviceIdentity.IdentityError.keychain("save the login", status)
        }
    }

    static func forget() {
        SecItemDelete([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ] as CFDictionary)
    }

    /// Turns what was typed into host:port: `raspberrypi`, `raspberrypi:8726`,
    /// `https://100.64.0.1:8726/` and `[fd7a::1]` all work. Nil if it can't be an address.
    static func normalizeHost(_ text: String) -> String? {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://", "http://"] where t.lowercased().hasPrefix(prefix) {
            t = String(t.dropFirst(prefix.count))
        }
        if let slash = t.firstIndex(of: "/") { t = String(t[..<slash]) }
        guard !t.isEmpty, !t.contains(" ") else { return nil }
        guard let url = URL(string: "https://\(t)"), let host = url.host(), !host.isEmpty else { return nil }
        let port = url.port ?? Limits.defaultPort
        let shownHost = host.contains(":") ? "[\(host)]" : host
        return "\(shownHost):\(port)"
    }

    /// Reads `tramline://login?host=raspberrypi:8726&host=...&fp=<fingerprint>`, or the
    /// same with `url=https://...`, as a QR code would give, or a bare fingerprint.
    static func parseScanned(_ text: String) -> (hosts: [String], fingerprint: String?)? {
        if let fp = Fingerprint.normalized(text) { return ([], fp) }
        guard let comps = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              comps.scheme == "tramline"
        else { return nil }
        let items = comps.queryItems ?? []
        let hosts = items.filter { ["host", "url"].contains($0.name) }.compactMap { $0.value.flatMap(normalizeHost) }
        let fp = items.first { ["fp", "fingerprint"].contains($0.name) }?.value.flatMap(Fingerprint.normalized)
        guard !hosts.isEmpty || fp != nil else { return nil }
        return (hosts, fp)
    }
}
