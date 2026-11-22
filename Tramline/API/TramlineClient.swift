import Foundation
import Synchronization

/// Talks to the Pi, as `internal/client/client.go` does for the CLI: mutual TLS with the
/// phone's certificate, trusting only the server whose fingerprint was saved at sign-in.
/// The read-only status and the 3D view's moves come over plain HTTP on the same port.
final class TramlineClient: Sendable {
    let login: Login
    private let identity: DeviceIdentity
    private let pinning: PinningDelegate
    private let session: URLSession
    private let plain: URLSession
    /// The index into `login.hosts` that answered last, which is tried first.
    private let current = Mutex(0)

    // Timeouts as in client.go. Cool and cancel wait for the move the printer is making,
    // which can take up to 3 minutes.
    static let requestTimeout: TimeInterval = 30
    static let coolTimeout: TimeInterval = 4 * 60
    static let printTimeout: TimeInterval = 2 * 60
    static let estopTimeout: TimeInterval = 30
    static let uploadTimeout: TimeInterval = 30 * 60

    init(login: Login, identity: DeviceIdentity) {
        self.login = login
        self.identity = identity
        pinning = PinningDelegate(fingerprint: login.fingerprint, identity: identity)

        let config = URLSessionConfiguration.ephemeral
        config.tlsMinimumSupportedProtocolVersion = .TLSv13
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.waitsForConnectivity = false
        session = URLSession(configuration: config, delegate: pinning, delegateQueue: nil)

        let plainConfig = URLSessionConfiguration.ephemeral
        plainConfig.requestCachePolicy = .reloadIgnoringLocalCacheData
        plainConfig.urlCache = nil
        plainConfig.timeoutIntervalForRequest = 8
        plain = URLSession(configuration: plainConfig, delegate: NoRedirects(), delegateQueue: nil)
    }

    deinit {
        session.invalidateAndCancel()
        plain.invalidateAndCancel()
    }

    /// The host:port answering now.
    var activeHost: String {
        let i = current.withLock { $0 }
        return login.hosts.indices.contains(i) ? login.hosts[i] : login.hosts.first ?? ""
    }

    /// The read-only page's base, http://host:port/, which the 3D view loads from.
    var webBase: URL { URL(string: "http://\(activeHost)/")! }

    // MARK: - The API

    /// The full status, and its JSON as sent, for the 3D view.
    func status() async throws -> (StatusResponse, Data) {
        let raw: RawJSON = try await send("GET", "/v1/status")
        return (try JSON.decoder.decode(StatusResponse.self, from: raw.data), raw.data)
    }
    func webStatus() async throws -> (WebStatus, Data) {
        let data = try await fetchPlain("/api/status")
        return (try JSON.decoder.decode(WebStatus.self, from: data), data)
    }

    // MARK: - Status streams

    /// `GET /v1/events`: the full status without the plug, pushed within 200 ms of a
    /// change and at least once a second. Each element is one status's JSON.
    func statusEvents() -> AsyncThrowingStream<Data, Error> {
        events { host in
            var req = URLRequest(url: URL(string: "https://\(host)/v1/events")!)
            req.timeoutInterval = Self.streamStale
            return try await self.wrap(host: host) { try await self.session.bytes(for: req) }
        }
    }

    /// `GET /api/events` on the read-only page: its status, pushed the same way.
    func webStatusEvents() -> AsyncThrowingStream<Data, Error> {
        events { host in
            var req = URLRequest(url: URL(string: "http://\(host)/api/events")!)
            req.timeoutInterval = Self.streamStale
            return try await self.plain.bytes(for: req)
        }
    }

    /// A stream with nothing for this long has stalled, so it's dropped and opened again.
    /// The Pi sends at least once a second.
    static let streamStale: TimeInterval = 15

    /// Opens a server-sent event stream, trying the addresses in turn as requests do, and
    /// yields the data of each `status` event. Go's JSON has no newlines, so each event is
    /// one `data:` line. It ends with `APIError.notFound` from a Pi with no streams.
    private func events(_ open: @escaping @Sendable (String) async throws -> (URLSession.AsyncBytes, URLResponse))
        -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, resp) = try await self.withFallback { try await open($0) }
                    guard let http = resp as? HTTPURLResponse else { throw APIError.server("No answer.") }
                    if http.statusCode == 404 { throw APIError.notFound }
                    guard http.statusCode == 200,
                          http.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("text/event-stream") == true
                    else { throw APIError.server("The Pi answered \(http.statusCode).") }
                    var parser = StatusEvents()
                    for try await line in bytes.lines {
                        if let data = parser.feed(line) { continuation.yield(data) }
                    }
                    continuation.finish(throwing: APIError.unreachable("The Pi closed the status stream."))
                } catch let error as URLError {
                    continuation.finish(throwing: error.code == .timedOut
                        ? APIError.unreachable("The Pi stopped sending its status.")
                        : APIError.unreachable(error.localizedDescription))
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func power(on: Bool) async throws { try await sendIgnoring("POST", "/v1/power", body: ["on": on]) }
    func preheat(bed: Int, nozzle: Int) async throws -> PreheatResponse {
        try await send("POST", "/v1/preheat", body: ["bed": bed, "nozzle": nozzle])
    }
    func cool() async throws -> CoolResponse { try await send("POST", "/v1/cool", timeout: Self.coolTimeout) }
    func tram(_ req: TramRequest) async throws { try await sendIgnoring("POST", "/v1/tram", body: req) }
    func tramInfo() async throws -> [String] { try await send("GET", "/v1/tram/info") }
    func mesh() async throws -> MeshInfo { try await send("GET", "/v1/mesh") }

    func files() async throws -> FilesResponse { try await send("GET", "/v1/files") }
    func file(_ name: String) async throws -> FileRecord? {
        do { return try await send("GET", "/v1/files/" + escape(name)) } catch APIError.notFound { return nil }
    }
    func copy(_ name: String) async throws -> CopyResponse {
        try await send("POST", "/v1/files/\(escape(name))/copy", body: [String: Int]())
    }
    func cancelCopy() async throws { try await sendIgnoring("POST", "/v1/copy/cancel") }
    func delete(_ name: String) async throws { try await sendIgnoring("DELETE", "/v1/files/" + escape(name)) }

    func print(_ req: PrintRequest) async throws -> PrintJob {
        try await send("POST", "/v1/print", body: req, timeout: Self.printTimeout)
    }
    func continuePrint() async throws { try await sendIgnoring("POST", "/v1/print/continue", body: [String: Int](), timeout: Self.printTimeout) }
    func cancel() async throws { try await sendIgnoring("POST", "/v1/cancel", timeout: Self.coolTimeout) }
    func estop() async throws -> EstopResponse { try await send("POST", "/v1/estop", timeout: Self.estopTimeout) }

    func schedule(_ req: PrintRequest) async throws -> ScheduledPrint {
        try await send("POST", "/v1/schedule", body: req, timeout: Self.printTimeout)
    }
    func schedules() async throws -> [ScheduledPrint] {
        let list: [ScheduledPrint]? = try await send("GET", "/v1/schedule")
        return list ?? []
    }
    func cancelSchedule(_ id: Int) async throws {
        try await sendIgnoring("POST", "/v1/schedule/\(id)/cancel", timeout: Self.coolTimeout)
    }

    func huePair() async throws { try await sendIgnoring("POST", "/v1/hue/pair") }
    func huePlugs() async throws -> [HueLight] {
        let list: [HueLight]? = try await send("GET", "/v1/hue/plugs")
        return list ?? []
    }

    /// Sends a file to keep on the Pi, reporting the fraction sent.
    func upload(name: String, file: URL, size: Int64, sha256: String,
                progress: @escaping @Sendable (Double) -> Void) async throws -> FileRecord {
        let host = activeHost
        var req = URLRequest(url: URL(string: "https://\(host)/v1/files/\(escape(name))")!)
        req.httpMethod = "PUT"
        req.timeoutInterval = Self.uploadTimeout
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.setValue(sha256, forHTTPHeaderField: "X-Tramline-SHA256")
        let watcher = UploadProgress(report: progress)
        let (data, resp) = try await wrap(host: host) {
            try await session.upload(for: req, fromFile: file, delegate: watcher)
        }
        return try decode(data, resp)
    }

    // MARK: - Sending

    private func escape(_ name: String) -> String {
        name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? name
    }

    private func sendIgnoring(_ method: String, _ path: String, body: (any Encodable)? = nil,
                              timeout: TimeInterval = requestTimeout) async throws {
        let _: Ignored = try await send(method, path, body: body, timeout: timeout)
    }

    private func send<T: Decodable>(_ method: String, _ path: String, body: (any Encodable)? = nil,
                                    timeout: TimeInterval = requestTimeout) async throws -> T {
        let bodyData = try body.map { try JSON.encoder.encode($0) }
        let (data, resp) = try await withFallback { host in
            var req = URLRequest(url: URL(string: "https://\(host)\(path)")!)
            req.httpMethod = method
            req.timeoutInterval = timeout
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = bodyData
            return try await self.wrap(host: host) { try await self.session.data(for: req) }
        }
        return try decode(data, resp)
    }

    private func fetchPlain(_ path: String) async throws -> Data {
        let (data, resp) = try await withFallback { host in
            try await self.plain.data(from: URL(string: "http://\(host)\(path)")!)
        }
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw APIError.server("The Pi answered \((resp as? HTTPURLResponse)?.statusCode ?? 0).")
        }
        return data
    }

    /// Tries the address that answered last, then the others, but only moving on when a
    /// request can't have reached the Pi, so an action is never sent twice.
    private func withFallback<R>(_ run: (String) async throws -> R) async throws -> R {
        let start = current.withLock { $0 }
        let count = max(login.hosts.count, 1)
        var lastError: Error = APIError.server("No address to try.")
        for step in 0..<count {
            let i = (start + step) % count
            guard login.hosts.indices.contains(i) else { break }
            do {
                let out = try await run(login.hosts[i])
                if step > 0 { current.withLock { $0 = i } }
                return out
            } catch let error as URLError where Self.neverReached(error) {
                lastError = APIError.unreachable(error.localizedDescription)
            } catch let APIError.unreachable(text) {
                lastError = APIError.unreachable(text)
            }
        }
        throw lastError
    }

    private static func neverReached(_ e: URLError) -> Bool {
        [.cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .notConnectedToInternet].contains(e.code)
    }

    /// Turns a TLS failure into something a person can act on, as `client.Explain` does.
    private func wrap<R>(host: String, _ run: () async throws -> R) async throws -> R {
        do {
            return try await run()
        } catch let error as URLError {
            if pinning.rejectedServer(host) {
                throw APIError.wrongServer
            }
            switch error.code {
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .notConnectedToInternet:
                throw error
            case .clientCertificateRejected, .clientCertificateRequired, .secureConnectionFailed:
                throw APIError.notAllowed
            case .timedOut:
                throw APIError.unreachable("The Pi didn't answer in time.")
            default:
                throw APIError.unreachable(error.localizedDescription)
            }
        }
    }

    private func decode<T: Decodable>(_ data: Data, _ resp: URLResponse) throws -> T {
        guard let http = resp as? HTTPURLResponse else { throw APIError.server("No answer.") }
        let message = (try? JSON.decoder.decode(ServerError.self, from: data))?.error
        if http.statusCode == 404 { throw message.map(APIError.server) ?? APIError.notFound }
        guard http.statusCode == 200 else {
            throw APIError.server(message ?? "The Pi answered \(http.statusCode).")
        }
        if T.self == Ignored.self { return Ignored() as! T }
        if T.self == RawJSON.self { return RawJSON(data: data) as! T }
        do {
            return try JSON.decoder.decode(T.self, from: data)
        } catch {
            throw APIError.server("Couldn't read the Pi's answer: \(error)")
        }
    }
}

/// Picks the `status` events out of a server-sent event stream, a line at a time.
/// `AsyncBytes.lines` skips blank lines, so an event ends at its data line, which is one
/// line as Go's JSON has no newlines. Comments, `retry:` and other events are ignored.
struct StatusEvents {
    private var event = ""

    mutating func feed(_ line: String) -> Data? {
        if line.hasPrefix("event:") {
            event = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
        } else if line.hasPrefix("data:") {
            defer { event = "" }
            guard event == "status" else { return nil }
            var data = line.dropFirst(5)
            if data.first == " " { data = data.dropFirst() }
            return Data(data.utf8)
        }
        return nil
    }
}

private struct Ignored: Decodable {}
private struct RawJSON: Decodable {
    var data: Data
    init(data: Data) { self.data = data }
    init(from decoder: Decoder) throws { throw DecodingError.typeMismatch(Data.self, .init(codingPath: [], debugDescription: "raw")) }
}
private struct ServerError: Decodable { var error: String }

enum APIError: LocalizedError, Equatable {
    case notFound
    case notAllowed
    case wrongServer
    case unreachable(String)
    case server(String)

    var errorDescription: String? {
        switch self {
        case .notFound: "Not found."
        case .notAllowed: "The Pi refused this phone. It has to be allowed on the Pi first, with the command in Settings."
        case .wrongServer: "The server's certificate doesn't match the saved fingerprint, so nothing was sent."
        case let .unreachable(text): "Can't reach the Pi: \(text)"
        case let .server(text): text
        }
    }
}

/// Answers both TLS challenges: the server must present the certificate whose fingerprint
/// was saved, as `secure.ClientTLS` checks, and the phone presents its own. No redirects,
/// as the CLI refuses them too.
final class PinningDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    private let fingerprint: String
    private let identity: DeviceIdentity
    private let rejected = Mutex<Set<String>>([])

    init(fingerprint: String, identity: DeviceIdentity) {
        self.fingerprint = fingerprint
        self.identity = identity
    }

    /// Whether the last connection to this host was dropped for presenting another certificate.
    func rejectedServer(_ hostPort: String) -> Bool {
        rejected.withLock { $0.contains(hostPort) }
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        answer(challenge)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        answer(challenge)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        nil
    }

    private func answer(_ challenge: URLAuthenticationChallenge) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = challenge.protectionSpace
        let hostPort = space.host.contains(":") ? "[\(space.host)]:\(space.port)" : "\(space.host):\(space.port)"
        switch space.authenticationMethod {
        case NSURLAuthenticationMethodServerTrust:
            // The certificate is self-signed, so it's never evaluated against the system's
            // roots: the fingerprint saved at sign-in is the whole check.
            guard let trust = space.serverTrust,
                  let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
                  let leaf = chain.first
            else {
                return (.cancelAuthenticationChallenge, nil)
            }
            let presented = Fingerprint.of(SecCertificateCopyData(leaf) as Data)
            guard Fingerprint.equal(presented, fingerprint) else {
                _ = rejected.withLock { $0.insert(hostPort) }
                return (.cancelAuthenticationChallenge, nil)
            }
            _ = rejected.withLock { $0.remove(hostPort) }
            return (.useCredential, URLCredential(trust: trust))
        case NSURLAuthenticationMethodClientCertificate:
            return (.useCredential, URLCredential(identity: identity.identity, certificates: nil, persistence: .forSession))
        default:
            return (.performDefaultHandling, nil)
        }
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}

private final class UploadProgress: NSObject, URLSessionTaskDelegate, Sendable {
    let report: @Sendable (Double) -> Void
    init(report: @escaping @Sendable (Double) -> Void) { self.report = report }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        report(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
    }
}
