import Foundation
import Observation

/// Whether the phone is set up: its identity, the saved login, and the store for the Pi.
@MainActor @Observable
final class AppModel {
    enum Phase {
        case starting
        case failed(String)
        case setup
        case ready(PrinterStore)
    }

    private(set) var phase = Phase.starting
    private(set) var identity: DeviceIdentity?

    func start() async {
        do {
            let id = try await Task.detached { try DeviceIdentity.loadOrCreate() }.value
            identity = id
            #if DEBUG
            await debugSignIn(id)
            if case .ready = phase { return }
            #endif
            if let login = Login.load() {
                phase = .ready(PrinterStore(client: TramlineClient(login: login, identity: id)))
            } else {
                phase = .setup
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Tries the login as `tramline login` does, with GET /v1/status, and keeps it if it works.
    func signIn(_ login: Login) async throws {
        guard let identity else { throw APIError.server("This phone has no key yet.") }
        let client = TramlineClient(login: login, identity: identity)
        _ = try await client.status()
        try login.save()
        phase = .ready(PrinterStore(client: client))
    }

    func signOut() {
        if case let .ready(store) = phase { store.stop() }
        Login.forget()
        phase = .setup
    }

    #if DEBUG
    /// For trying the app against `tramline serve --sim` on the Mac without tapping:
    /// `-debugHost 127.0.0.1:18726 -debugFingerprint <server fingerprint>`. Only loopback
    /// addresses are taken, so a debug launch can't reach the real Pi. The login isn't saved.
    private func debugSignIn(_ id: DeviceIdentity) async {
        print("tramline-phone-fingerprint: \(id.fingerprint)")
        let defaults = UserDefaults.standard
        guard let host = defaults.string(forKey: "debugHost").flatMap(Login.normalizeHost),
              host.hasPrefix("127.0.0.1:") || host.hasPrefix("localhost:"),
              let fp = defaults.string(forKey: "debugFingerprint").flatMap(Fingerprint.normalized)
        else { return }
        let client = TramlineClient(login: Login(hosts: [host], fingerprint: fp), identity: id)
        do {
            _ = try await client.status()
            phase = .ready(PrinterStore(client: client))
        } catch {
            print("tramline-debug-sign-in: \(error.localizedDescription)")
        }
    }
    #endif

    var savedLogin: Login? {
        if case let .ready(store) = phase { return store.client.login }
        return Login.load()
    }
}
