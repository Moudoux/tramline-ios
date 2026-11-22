import CryptoKit
import Foundation
import Observation

/// Everything the screens show, and the actions they take, ported from `gui.js`. The Pi's
/// rules decide what's allowed and its messages are shown as they come; the busy rules
/// here only save a tap.
@MainActor @Observable
final class PrinterStore {
    let client: TramlineClient

    // The streamed or polled state.
    private(set) var page: WebStatus?
    private(set) var full: StatusResponse?
    private(set) var files: FilesResponse?
    private(set) var schedules: [ScheduledPrint]?
    private(set) var reachable = true
    private(set) var pageError: String?
    private(set) var fullError: String?
    private(set) var filesError: String?
    private(set) var schedulesError: String?
    private(set) var loadingFiles = false

    // The raw JSON of the last polls, handed to the 3D view as they came.
    private(set) var pageJSON = "null"
    private(set) var fullJSON = "null"

    // What the 3D view reports back.
    var viewDetails = ViewDetails()

    // The mesh drawn over the bed, from More or after a print.
    private(set) var heights: MeshReport?
    private(set) var lastMeshShownForJob = 0

    private(set) var upload: UploadState?
    var toasts: [Toast] = []
    var estopOutcome: EstopOutcome?
    var scheduleTabShown = false

    @ObservationIgnored private var pageTask: Task<Void, Never>?
    @ObservationIgnored private var fullStreamTask: Task<Void, Never>?
    @ObservationIgnored private var fullTask: Task<Void, Never>?
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    @ObservationIgnored private var lastBusy: String?
    @ObservationIgnored private var lastCopyState: String?
    @ObservationIgnored private var tramSeen = (id: 0, endedAt: Date?.none)
    /// Set once a Pi turns out to have no status streams, as one before 0.1.1 doesn't.
    @ObservationIgnored private(set) var pagePolling = false
    @ObservationIgnored private(set) var fullPolling = false
    /// When the page's stream last sent something, while it's open.
    @ObservationIgnored private var pageStreamSince: Date?

    // From gui.js and followStatus in status.js.
    static let pageInterval: Duration = .seconds(1)
    static let fullInterval: Duration = .seconds(5)
    static let fullBusyInterval: Duration = .seconds(2)
    static let streamQuiet: TimeInterval = 5
    static let streamRetry: Duration = .seconds(2)
    static let tramViewAfter: TimeInterval = 2 * 60
    static let meshAfterSeconds = 6.0
    static let meshStaleSeconds = 30.0
    static let meshStartBytes: Int64 = 4096
    static let meshFresh: TimeInterval = 10 * 60

    init(client: TramlineClient) {
        self.client = client
    }

    // MARK: - Following the status

    /// Follows the Pi's status streams while the app is in the foreground, as the GUI does
    /// since 2026-11-21. The streamed full status has no plug, as reading it asks the Hue
    /// Bridge, so `GET /v1/status` is still asked for every 5 seconds for that. A Pi with
    /// no streams is polled as before.
    func start() {
        guard pageTask == nil else { return }
        pageTask = Task { [weak self] in await self?.followPage() }
        fullStreamTask = Task { [weak self] in await self?.followFull() }
        scheduleFull(after: .zero)
        watchTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.watchPageStream()
            }
        }
        Task { await loadFiles() }
    }

    func stop() {
        for task in [pageTask, fullStreamTask, fullTask, watchTask] { task?.cancel() }
        pageTask = nil
        fullStreamTask = nil
        fullTask = nil
        watchTask = nil
        pageStreamSince = nil
    }

    /// `/api/events`, or `/api/status` once a second from a Pi without it.
    private func followPage() async {
        while !Task.isCancelled, !pagePolling {
            do {
                pageStreamSince = Date()
                for try await data in client.webStatusEvents() {
                    pageStreamSince = Date()
                    gotPage(data)
                }
            } catch APIError.notFound {
                pagePolling = true
            } catch {
                if !Task.isCancelled { pageLost(error) }
            }
            pageStreamSince = nil
            if !pagePolling { try? await Task.sleep(for: Self.streamRetry) }
        }
        while !Task.isCancelled {
            await pollPage()
            try? await Task.sleep(for: Self.pageInterval)
        }
    }

    /// `/v1/events`. Without it, `pollFull` is all there is, and goes faster while busy.
    private func followFull() async {
        while !Task.isCancelled {
            do {
                for try await data in client.statusEvents() {
                    gotFull(data, streamed: true)
                }
            } catch APIError.notFound {
                fullPolling = true
                return
            } catch {
                // The plug's poll shows why, if the Pi is out of reach.
            }
            try? await Task.sleep(for: Self.streamRetry)
        }
    }

    /// A stream quiet for 5 seconds has stalled, though it's only reopened after 15.
    private func watchPageStream() {
        guard let since = pageStreamSince, reachable,
              Date().timeIntervalSince(since) > Self.streamQuiet else { return }
        reachable = false
        pageError = "The Pi has stopped sending its status."
    }

    private func scheduleFull(after delay: Duration) {
        fullTask?.cancel()
        fullTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            while !Task.isCancelled {
                guard let self else { return }
                await self.pollFull()
                try? await Task.sleep(for: self.fullPolling && self.fullBusy ? Self.fullBusyInterval : Self.fullInterval)
            }
        }
    }

    /// Catches up after an action. The streams bring most of it, but not the plug.
    func refreshSoon() {
        scheduleFull(after: .milliseconds(300))
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            await loadFiles()
        }
    }

    private func pollPage() async {
        do {
            let (_, data) = try await client.webStatus()
            gotPage(data)
        } catch {
            pageLost(error)
        }
    }

    private func gotPage(_ data: Data) {
        guard let st = try? JSON.decoder.decode(WebStatus.self, from: data) else { return }
        page = st
        pageJSON = String(decoding: data, as: UTF8.self)
        pageError = nil
        reachable = true
        if heights != nil, Words.isActive(st.print?.state) { heights = nil }
        afterPoll()
    }

    private func pageLost(_ error: Error) {
        reachable = false
        pageError = error.localizedDescription
    }

    /// The full status with the plug, for the plug, and for everything from a Pi without
    /// streams.
    private func pollFull() async {
        do {
            let (_, data) = try await client.status()
            gotFull(data, streamed: false)
            fullError = nil
            if scheduleTabShown { await loadSchedules() }
        } catch {
            fullError = error.localizedDescription
        }
    }

    private func gotFull(_ data: Data, streamed: Bool) {
        guard var st = try? JSON.decoder.decode(StatusResponse.self, from: data) else { return }
        // A streamed status has no plug, so the last one read stays.
        if streamed { st.plug = full?.plug }
        full = st
        fullJSON = String(decoding: data, as: UTF8.self)
        noteTram()
        noticeCopyEnded(st.copy)
        showLastMesh(st.print)
        afterPoll()
    }

    /// When what's busy changes, the card's listing may have too.
    private func afterPoll() {
        let busy = busyReason ?? ""
        if busy != lastBusy {
            if lastBusy != nil, files != nil { Task { await loadFiles() } }
            lastBusy = busy
        }
    }

    private var fullBusy: Bool {
        tramming || copying || meshSoon || Words.preparingStates.contains(page?.print?.state ?? "")
    }

    private func noticeCopyEnded(_ copy: CopyJob?) {
        let state = copy.map { "\($0.id):\($0.state)" }
        guard state != lastCopyState else { return }
        if lastCopyState != nil, let copy, copy.state != "running" {
            if copy.state == "failed" {
                toast("Copy of \(copy.name) failed: \(copy.error ?? "unknown")", .bad)
            } else {
                toast("\(copy.name) is on the card as \(copy.sdName).", .good)
            }
        }
        lastCopyState = state
        if files != nil { Task { await loadFiles() } }
    }

    func loadFiles() async {
        guard !loadingFiles else { return }
        loadingFiles = true
        defer { loadingFiles = false }
        do {
            files = try await client.files()
            filesError = nil
        } catch {
            filesError = error.localizedDescription
        }
    }

    func loadSchedules() async {
        do {
            schedules = try await client.schedules()
            schedulesError = nil
        } catch {
            schedulesError = error.localizedDescription
        }
    }

    // MARK: - What's going on

    var tramming: Bool { full?.tram?.state == "running" }
    var copying: Bool { page?.copy != nil || full?.copy?.state == "running" }
    var printBusy: Bool { Words.isActive(page?.print?.state) }

    /// Why a new job can't start, or nil if it can (`busyReason`).
    var busyReason: String? {
        if printBusy { return "A print is under way." }
        if tramming { return "A tram check is running." }
        if copying { return "A copy to the card is running." }
        return nil
    }

    var comingSchedules: Int { full?.scheduled?.count ?? page?.scheduled?.filter { $0.ended != true }.count ?? 0 }

    /// The status card, from `showNow`.
    var now: NowCard {
        var card = NowCard()
        guard let st = page else {
            card.badge = reachable ? "connecting" : "can't reach the Pi"
            card.tone = reachable ? .plain : .bad
            card.message = reachable ? "" : (pageError ?? "")
            return card
        }
        let job = st.print
        let offText = full?.plug?.on == true ? "The plug is on, and the printer is connecting." : "The printer is off."
        var focus: WebPrint?
        if let job, Words.isActive(job.state) {
            focus = job
            (card.badge, card.tone, card.message) = Words.printState(job.state)
            if job.state == "adjusting" {
                card.message = (job.parked == true ? "The head is parked. The bed may be hot." : "The head may be low. The bed may be hot.")
                    + " Adjust the knob, then check again."
            }
            if job.state == "checking", tramming, let step = full?.tram?.step { card.message = "Tram check: \(step)." }
            if let mesh = meshShown, mesh.id == job.id, let m = mesh.mesh {
                card.message = "Probing the mesh, point \(m.point) of \(m.of). The head's place is an estimate, as the printer doesn't report it."
            }
        } else if st.tramming == true || tramming {
            (card.badge, card.tone) = ("checking tram", .active)
            card.message = full?.tram?.step.map { "Tram check: \($0)." } ?? "Probing the corners of the bed."
        } else if let copy = st.copy {
            (card.badge, card.tone) = ("copying to card", .active)
            let pct = copy.totalBytes > 0 ? Int(100 * copy.bytes / copy.totalBytes) : 0
            card.message = "Copying \(copy.name) to the card: \(pct)%."
        } else if let job {
            focus = job
            (card.badge, card.tone, card.message) = Words.printState(job.state)
            if job.state == "cancelled" || job.state == "unknown" { card.tone = .plain }
            if !st.connected { card.message = offText }
        } else if !st.connected {
            (card.badge, card.tone) = ("printer off", .plain)
            card.message = "The printer is off, or not connected."
        } else {
            (card.badge, card.tone) = ("idle", .plain)
        }
        if !reachable {
            (card.badge, card.tone) = ("can't reach the Pi", .bad)
        }

        card.file = focus?.name ?? st.copy?.name ?? ""
        if let f = focus {
            card.fileSum = SumInfo.job(sha256: f.sha256, mode: f.mode, elsewhere: f.elsewhere)
        } else if let copy = st.copy {
            card.fileSum = SumInfo.copying(copy.sha256)
        }
        card.nozzle = Words.temp(st.temps?.nozzle, st.temps?.nozzleTarget)
        card.bed = Words.temp(st.temps?.bed, st.temps?.bedTarget)

        var notes = [card.message]
        if let f = focus {
            if let note = f.note { notes.append(Words.sentence(note)) }
            if f.stopping == true { notes.append("Being cancelled.") }
            if f.linkLost == true { notes.append("The link to the printer is lost, so this is out of date.") }
            if f.elsewhere == true { notes.append("Started from the printer, not from here.") }
            if viewDetails.modelMissing { notes.append("Its file isn't on the Pi, so there's no 3D view.") }
            if f.mode == "stream", Words.isPrinting(f.state) {
                notes.append("The printer's own Pause doesn't work while streaming from the Pi.")
            }
        }
        card.message = notes.filter { !$0.isEmpty }.joined(separator: " ")

        var problems: [String] = []
        if let f = focus, let e = f.error, !["finished", "cancelled"].contains(f.state) { problems.append(e) }
        if let h = full?.heatProblem { problems.append(h) }
        if !reachable, let e = pageError { problems.append(e) } else if let e = fullError { problems.append(e) }
        card.problem = problems.map(Words.sentence).joined(separator: " ")

        if let job, focus?.id == job.id, job.size > 0, job.pos > 0 || Words.isPrinting(job.state),
           !Words.preparingStates.contains(job.state) {
            card.progress = min(Double(job.pos) / Double(job.size), 1)
            card.elapsed = Words.clock(job.runSeconds)
        }
        if let job, job.state == "adjusting", let check = job.check, !check.pass {
            card.check = check
        }

        if let job, Words.isActive(job.state) {
            if job.state == "adjusting" { card.actions = .adjusting }
            else if job.state != "cancelling", job.stopping != true { card.actions = .print }
        } else if st.copy != nil {
            card.actions = .copy
        }
        return card
    }

    // MARK: - The 3D view's rules

    /// Whether to draw the tram check: while it runs, for two minutes after, and while a
    /// print waits for the bed to be adjusted, but not once a print is under way.
    var showTramInView: Bool {
        guard let job = full?.tram else { return false }
        let state = page?.print?.state ?? ""
        if ["starting", "running", "cancelling"].contains(state) { return false }
        if job.state == "running" { return true }
        if job.id == tramSeen.id, let ended = tramSeen.endedAt, Date().timeIntervalSince(ended) < Self.tramViewAfter { return true }
        return state == "adjusting"
    }

    /// Call after each poll, as `showTramView` notes when a check it watched ends.
    func noteTram() {
        guard let job = full?.tram else { return }
        if job.state == "running" {
            tramSeen = (job.id, nil)
        } else if job.id == tramSeen.id, tramSeen.endedAt == nil {
            tramSeen.endedAt = Date()
        }
    }

    /// The print whose mesh probing to draw, from `meshShown`.
    var meshShown: PrintJob? {
        guard let job = full?.print, let m = job.mesh, job.state == "running",
              let p = page?.print, p.id == job.id, p.state == "running" else { return nil }
        let age = m.pointSeconds ?? 0
        if age > Self.meshStaleSeconds || (m.point >= m.of && age > Self.meshAfterSeconds) { return nil }
        return job
    }

    private var meshSoon: Bool {
        if meshShown != nil { return true }
        guard let p = page?.print else { return false }
        return p.state == "running" && p.pos < Self.meshStartBytes
    }

    /// The mesh read after the last print is shown once by itself, if it's recent.
    private func showLastMesh(_ job: PrintJob?) {
        guard let job, let mesh = job.meshRead?.mesh, let read = job.meshRead else { return }
        let fresh = Date().timeIntervalSince(read.readAt) < Self.meshFresh
        if lastMeshShownForJob != job.id, fresh, !Words.isActive(job.state) {
            lastMeshShownForJob = job.id
            heights = mesh
        }
    }

    func showHeights(_ mesh: MeshReport?) { heights = mesh }

    // MARK: - Actions

    /// Runs an action, shows how it went, and catches up. Nil if it failed.
    @discardableResult
    func act<T>(done: ((T) -> String?)? = nil, _ run: () async throws -> T) async -> T? {
        do {
            let out = try await run()
            if let text = done?(out) { toast(text, .good) }
            refreshSoon()
            return out
        } catch {
            toast(error.localizedDescription, .bad)
            return nil
        }
    }

    func power(on: Bool) async {
        await act(done: { _ in on ? "The plug is on. The printer connects in about 10 seconds." : "The plug is off." }) {
            try await client.power(on: on)
        }
    }

    func preheat(bed: Int, nozzle: Int) async {
        await act(done: { (out: PreheatResponse) in
            "Heating to bed \(out.bed) °C and nozzle \(out.nozzle) °C. They turn off at \(Words.clockTime(out.heatersOffAt))."
        }) { try await client.preheat(bed: bed, nozzle: nozzle) }
    }

    func cool() async {
        await act(done: { (out: CoolResponse) in
            out.cancelling == true ? "Cancelling the print, which turns the heaters off." : "Heaters off."
        }) { try await client.cool() }
    }

    func continuePrint() async {
        await act(done: { _ in "Checking tram again. The head will move." }) { try await client.continuePrint() }
    }

    func cancelPrint() async {
        await act(done: { _ in "Cancelling. The status confirms it." }) { try await client.cancel() }
    }

    func cancelCopy() async {
        await act(done: { _ in "Stopping the copy." }) { try await client.cancelCopy() }
    }

    func copy(_ rec: FileRecord) async {
        await act(done: { (out: CopyResponse) in
            out.job != nil ? "Copying \(rec.name) to the card." : "\(rec.name) is already on the card."
        }) { try await client.copy(rec.name) }
    }

    func delete(_ rec: FileRecord) async {
        await act(done: { _ in "Deleted \(rec.name)." }) { try await client.delete(rec.name) }
    }

    /// Starts a tram check. Throws so the sheet can show the Pi's reason beside its button.
    func tram(_ req: TramRequest) async throws {
        try await client.tram(req)
        toast("Checking tram. The head will move.", .good)
        refreshSoon()
    }

    func startPrint(_ req: PrintRequest) async throws {
        let job = try await client.print(req)
        toast(job.mode == "stream"
              ? "Heating for the tram check. \(job.name) streams from the Pi once that passes."
              : "Heating for the tram check. \(job.name) starts from the card once that passes.", .good, seconds: 8)
        refreshSoon()
    }

    func schedule(_ req: PrintRequest) async throws {
        let p = try await client.schedule(req)
        toast("Scheduled \(p.name) for \(Words.scheduleWhen(p.at)). Checking tram now, the head will move.", .good, seconds: 8)
        refreshSoon()
        await loadSchedules()
    }

    func cancelSchedule(_ p: ScheduledPrint) async {
        if await act(done: { _ in "Cancelled." }, { try await client.cancelSchedule(p.id) }) != nil {
            await loadSchedules()
        }
    }

    func estop() async {
        do {
            let out = try await client.estop()
            var list = [
                out.m112 ? "Stop code M112 sent to the printer." : "No M112 sent, as the printer wasn't connected or was copying.",
                out.plugOff ? "The plug is off, and read back as off." : "The plug is NOT confirmed off.",
            ]
            list += (out.problems ?? []).map(Words.sentence)
            estopOutcome = EstopOutcome(
                title: out.plugOff ? "Stopped, and the power is off" : "The plug isn't confirmed off",
                text: out.plugOff ? "" : "Use the printer's own switch now.",
                list: list, ok: out.plugOff)
        } catch {
            estopOutcome = EstopOutcome(
                title: "The emergency stop didn't get through",
                text: "Use the printer's own switch now. \(error.localizedDescription)",
                list: [], ok: false)
        }
        refreshSoon()
    }

    // MARK: - Uploading

    /// Checks a picked file before sending, as `upload()` in the GUI does. Returns the
    /// questions to ask first, if any.
    func prepareUpload(_ url: URL) -> UploadPlan? {
        let original = url.lastPathComponent
        guard Words.isGcode(original) else {
            toast("\(original) isn't G-code: the Pi takes .gcode or .gco files.", .bad)
            return nil
        }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        if size > Limits.maxUpload {
            toast("\(original) is \(Words.bytes(size)), more than the \(Words.bytes(Limits.maxUpload)) the Pi takes.", .bad)
            return nil
        }
        let renamed = !Limits.isFileName(original)
        let name = renamed ? Words.safeName(original) : original
        let exists = files?.files?.contains { $0.name == name } ?? false
        return UploadPlan(url: url, name: name, renamed: renamed, replaces: exists)
    }

    func upload(_ plan: UploadPlan) async {
        guard upload?.finished != false else {
            toast("An upload is already running.", .bad)
            return
        }
        upload = UploadState(name: plan.name, phase: "reading", fraction: 0)
        do {
            // The picked file is copied first: it may be in iCloud, and access to it ends.
            let local = try copyPicked(plan.url)
            defer { try? FileManager.default.removeItem(at: local.deletingLastPathComponent()) }
            let size = Int64(try local.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
            let sha = try await Task.detached { try Self.sha256(of: local) }.value
            if let existing = try await client.file(plan.name), existing.sha256 == sha {
                upload = UploadState(name: plan.name, phase: "already on the Pi", fraction: 1, finished: true)
                toast("\(plan.name) is already on the Pi, so it wasn't sent again.", .good)
            } else {
                upload?.phase = "sending to the Pi"
                let rec = try await client.upload(name: plan.name, file: local, size: size, sha256: sha) { [weak self] f in
                    Task { @MainActor in
                        guard let self, self.upload?.finished == false else { return }
                        self.upload?.fraction = f
                        self.upload?.phase = "sending to the Pi, \(Int(f * 100))%"
                    }
                }
                upload = UploadState(name: plan.name, phase: "on the Pi", fraction: 1, finished: true)
                toast("\(plan.name) is on the Pi: \(rec.info.lines.formatted()) commands.", .good)
            }
            await loadFiles()
            let name = plan.name
            Task {
                try? await Task.sleep(for: .seconds(6))
                if self.upload?.name == name, self.upload?.failed == false { self.upload = nil }
            }
        } catch {
            upload = UploadState(name: plan.name, phase: "failed", fraction: 1, finished: true, failed: true)
            toast("Upload of \(plan.name) failed: \(error.localizedDescription)", .bad)
        }
    }

    func dismissUpload() { if upload?.finished == true { upload = nil } }

    private func copyPicked(_ url: URL) throws -> URL {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appending(path: "upload.gcode")
        var error: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: url, options: .forUploading, error: &error) { readable in
            do { try FileManager.default.copyItem(at: readable, to: dest) } catch { copyError = error }
        }
        if let e = error ?? copyError { throw e }
        return dest
    }

    nonisolated private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Toasts

    func toast(_ text: String, _ tone: Tone, seconds: Double? = nil) {
        let t = Toast(text: Words.sentence(text), tone: tone)
        toasts.append(t)
        let wait = seconds ?? (tone == .bad ? 12 : 5)
        Task {
            try? await Task.sleep(for: .seconds(wait))
            self.toasts.removeAll { $0.id == t.id }
        }
    }
}

struct NowCard {
    enum Actions { case none, adjusting, print, copy }

    var badge = ""
    var tone = Tone.plain
    var file = ""
    var fileSum: SumInfo?
    var message = ""
    var problem = ""
    var nozzle = "–"
    var bed = "–"
    var progress: Double?
    var elapsed = "–"
    var check: TramResult?
    var actions = Actions.none
}

struct ViewDetails: Equatable {
    var ok = true
    var loaded = false
    var layer = "–"
    var left = "–"
    var modelMissing = false
}

struct Toast: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let tone: Tone
}

struct EstopOutcome: Identifiable {
    let id = UUID()
    let title: String
    let text: String
    let list: [String]
    let ok: Bool
}

struct UploadPlan: Identifiable {
    let id = UUID()
    let url: URL
    let name: String
    let renamed: Bool
    let replaces: Bool
}

struct UploadState: Equatable {
    var name: String
    var phase: String
    var fraction: Double
    var finished = false
    var failed = false
}
