import SwiftUI
import UniformTypeIdentifiers

struct FilesView: View {
    @Environment(PrinterStore.self) private var store
    @State private var picking = false
    @State private var plan: UploadPlan?
    @State private var run: RunRequest?
    @State private var confirmCopy: FileRecord?
    @State private var confirmDelete: FileRecord?

    static let gcodeTypes: [UTType] = {
        let types = ["gcode", "gco"].compactMap { UTType(filenameExtension: $0, conformingTo: .data) }
        return types.isEmpty ? [.data] : types + [.plainText]
    }()

    var body: some View {
        NavigationStack {
            List {
                if let up = store.upload {
                    Section { UploadRow(state: up) }
                }
                Section {
                    if let error = store.filesError, store.files == nil {
                        Text("Can't list the files: \(error)").foregroundStyle(.secondary)
                    } else if store.files == nil {
                        HStack { ProgressView(); Text("Loading…").foregroundStyle(.secondary) }
                    } else if piFiles.isEmpty {
                        ContentUnavailableView {
                            Label("No files on the Pi yet", systemImage: "doc.badge.plus")
                        } description: {
                            Text("Upload a sliced .gcode from Files, or share one to Tramline.")
                        } actions: {
                            Button("Upload") { picking = true }.buttonStyle(.glassProminent)
                        }
                    }
                    ForEach(piFiles) { rec in
                        FileRow(rec: rec, chip: cardState(rec))
                            .contentShape(.rect)
                            .contextMenu { menu(rec) }
                            .swipeActions(edge: .trailing) {
                                Button("Delete", systemImage: "trash", role: .destructive) { confirmDelete = rec }
                                    .disabled(busy)
                            }
                            .swipeActions(edge: .leading) {
                                Button("Print", systemImage: "printer") { run = RunRequest(mode: .print, name: rec.name) }
                                    .tint(Theme.accent)
                                    .disabled(busy)
                            }
                            .overlay(alignment: .trailing) {
                                Menu { menu(rec) } label: {
                                    Image(systemName: "ellipsis.circle").imageScale(.large)
                                        .padding(.leading, 12)
                                        .contentShape(.rect)
                                }
                                .accessibilityLabel("Actions for \(rec.name)")
                            }
                    }
                } header: {
                    Text("On the Pi")
                } footer: {
                    if let busy = store.busyReason { Text(busy) }
                }

                Section("On the SD card") {
                    if let files = store.files {
                        if let card = files.card {
                            if card.isEmpty {
                                Text("Nothing on the card.").foregroundStyle(.secondary)
                            }
                            let records = files.files ?? []
                            let ours = Set(records.map { $0.sdName.uppercased() })
                            ForEach(card) { f in
                                HStack {
                                    VStack(alignment: .leading) {
                                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                                            Text(f.name).font(.body.monospaced())
                                            SumBadge(info: SumInfo.card(f, records: records))
                                        }
                                        Text(f.upload.map { "\(Words.bytes(f.size)) · copied from \($0)" } ?? Words.bytes(f.size))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    let mine = f.upload != nil || ours.contains(f.name.uppercased())
                                    if SumInfo.isOlder(f, records: records) {
                                        ToneChip(text: "older version", tone: .bad)
                                    } else {
                                        ToneChip(text: mine ? "from here" : "not from here", tone: mine ? .good : .plain)
                                    }
                                }
                            }
                        } else {
                            Text("Can't read the card now: \(files.cardNote ?? "the printer is busy or off").")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Files")
            .refreshable { await store.loadFiles() }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Upload", systemImage: "plus") { picking = true }
                        .disabled(store.upload?.finished == false)
                }
            }
            .fileImporter(isPresented: $picking, allowedContentTypes: Self.gcodeTypes) { result in
                if case let .success(url) = result { begin(url) }
            }
            .onOpenURL { url in
                if url.isFileURL { begin(url) }
            }
            .alert(plan?.renamed == true ? "Upload under a new name?" : "Replace \(plan?.name ?? "")?",
                   isPresented: Binding(get: { plan != nil }, set: { if !$0 { plan = nil } }), presenting: plan) { p in
                Button("Upload") { Task { await store.upload(p) } }
                Button("Cancel", role: .cancel) {}
            } message: { p in
                if p.renamed {
                    Text("The Pi only takes names of letters, digits, dots, dashes and underscores, up to 64. It would be saved as \(p.name).")
                } else {
                    Text("A file by this name is already on the Pi. If it's the same file nothing is sent. If it's different, the Pi's copy is replaced.")
                }
            }
            .alert("Copy \(confirmCopy?.name ?? "") to the card?",
                   isPresented: Binding(get: { confirmCopy != nil }, set: { if !$0 { confirmCopy = nil } }), presenting: confirmCopy) { rec in
                Button("Copy") { Task { await store.copy(rec) } }
                Button("Cancel", role: .cancel) {}
            } message: { rec in
                let seconds = max((Double(rec.info.sdSize) / Limits.copyBytesPerSecond).rounded(), 1)
                Text("It takes about \(Words.clock(seconds)), with the printer on, and nothing else can run meanwhile. Printing from the card doesn't depend on the Pi once it starts.")
            }
            .confirmationDialog("Delete \(confirmDelete?.name ?? "")?",
                                isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
                                titleVisibility: .visible, presenting: confirmDelete) { rec in
                Button("Delete", role: .destructive) { Task { await store.delete(rec) } }
            } message: { rec in
                Text(rec.onCard ? "It's deleted from the Pi, and its copy on the card too." : "It's deleted from the Pi.")
            }
            .sheet(item: $run) { req in RunSheet(request: req) }
        }
    }

    private var busy: Bool { store.busyReason != nil }

    private var piFiles: [FileRecord] {
        (store.files?.files ?? []).sorted { $0.uploadedAt > $1.uploadedAt }
    }

    @ViewBuilder
    private func menu(_ rec: FileRecord) -> some View {
        Button("Print…", systemImage: "printer") { run = RunRequest(mode: .print, name: rec.name) }
            .disabled(busy)
        Button("Schedule…", systemImage: "calendar.badge.clock") { run = RunRequest(mode: .schedule, name: rec.name) }
            .disabled(busy)
        if rec.sdState != "verified" {
            Button(rec.sdState == "failed" ? "Copy again" : "Copy to card", systemImage: "sdcard") { confirmCopy = rec }
                .disabled(busy)
        }
        Divider()
        Button("Delete", systemImage: "trash", role: .destructive) { confirmDelete = rec }
            .disabled(busy)
    }

    /// `cardState`, but with `verified` for a finished copy, as the server sends.
    private func cardState(_ rec: FileRecord) -> (String, Tone) {
        if let copy = store.page?.copy, copy.name == rec.name {
            let pct = copy.totalBytes > 0 ? Int(100 * copy.bytes / copy.totalBytes) : 0
            return ("copying \(pct)%", .active)
        }
        switch rec.sdState {
        case "verified": return ("on card", .good)
        case "running": return ("copying", .active)
        case "failed": return ("copy failed", .bad)
        default: return rec.onCard && rec.cardSHA256 != nil ? ("older copy on card", .plain) : ("Pi only", .plain)
        }
    }

    private func begin(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let p = store.prepareUpload(url) else { return }
        if p.renamed || p.replaces {
            plan = p
        } else {
            Task { await store.upload(p) }
        }
    }
}

private struct FileRow: View {
    let rec: FileRecord
    let chip: (String, Tone)

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(rec.name).font(.body.weight(.medium)).lineLimit(2)
                SumBadge(info: SumInfo.pi(rec))
                Spacer(minLength: 8)
                ToneChip(text: chip.0, tone: chip.1)
                    .padding(.trailing, 32)
            }
            Text([Words.bytes(rec.size), "\(rec.info.lines.formatted()) lines", "uploaded \(Words.shortTime(rec.uploadedAt))"]
                .joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
            if rec.damaged {
                Text("Damaged on the Pi: it no longer matches its upload. Upload it again.")
                    .font(.caption).foregroundStyle(Theme.bad)
            }
            if rec.sdState == "failed", let e = rec.sdError {
                Text(e).font(.caption).foregroundStyle(Theme.bad)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct UploadRow: View {
    @Environment(PrinterStore.self) private var store
    let state: UploadState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(state.name).font(.body.weight(.medium)).lineLimit(1)
                Spacer()
                Text(state.phase).font(.caption).foregroundStyle(state.failed ? Theme.bad : .secondary)
            }
            ProgressView(value: state.fraction)
                .tint(state.failed ? Theme.bad : state.finished ? Theme.good : Theme.accent)
        }
        .swipeActions { if state.finished { Button("Dismiss") { store.dismissUpload() } } }
    }
}

struct RunRequest: Identifiable {
    enum Mode { case print, schedule }
    let id = UUID()
    let mode: Mode
    var name: String?
}

/// Print or schedule a file, from `openRun` and `updateRun`. The bed-clear switch starts
/// off every time, and neither source is picked for you when both are possible.
struct RunSheet: View {
    @Environment(PrinterStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let request: RunRequest

    @State private var name = ""
    @State private var from: String?
    @State private var at = Date()
    @State private var bedClear = false
    @State private var error: String?
    @State private var working = false

    private var isPrint: Bool { request.mode == .print }
    private var files: [FileRecord] { (store.files?.files ?? []).sorted { $0.uploadedAt > $1.uploadedAt } }
    private var rec: FileRecord? { files.first { $0.name == name } }
    private var onCard: Bool { rec?.sdState == "verified" }

    var body: some View {
        NavigationStack {
            Form {
                if files.isEmpty {
                    Text("Upload a file first.").foregroundStyle(.secondary)
                } else {
                    Section {
                        Picker("File", selection: $name) {
                            ForEach(files) { Text($0.name).tag($0.name) }
                        }
                    } footer: {
                        if let rec {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text("SHA-256 \(SumInfo.short(rec.sha256))").font(.footnote.monospaced())
                                SumBadge(info: SumInfo.pi(rec))
                            }
                        }
                    }
                }

                Section {
                    Picker("Print from", selection: $from) {
                        Text("The Pi").tag(String?.some("pi"))
                        Text("The SD card").tag(String?.some("sd"))
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .onChange(of: name) { fixFrom() }
                    .onChange(of: from) { if from == "sd" && !onCard { from = "pi" } }
                } header: {
                    Text("Print from")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("The Pi sends it line by line. Don't restart the server until it's done. The printer's own Pause doesn't work while streaming.")
                        Text(onCard ? "The card prints its copy, \(rec?.sdName ?? "")." : "To print from the card, copy it there first, from the file list.")
                    }
                }

                if !isPrint {
                    Section {
                        DatePicker("When", selection: $at, in: earliest...latest)
                    } footer: {
                        Text(Words.scheduleWhen(at))
                    }
                }

                Section {
                    Text(isPrint
                         ? "Turns the printer on if needed, heats to bed 80 °C and nozzle 150 °C, checks tram, then prints. It turns off once the print is over and cool."
                         : "Heats and checks tram now, so the head will move. On a pass the printer turns off until the time, then powers on, checks tram again and prints only if it still passes. It ends turned off.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Toggle(isPrint ? "I've checked the bed is clear" : "I've checked the bed is clear, and nothing will go on it before the print",
                           isOn: $bedClear)
                        .tint(Theme.accent)
                }

                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.bad)
                    }
                }
            }
            .navigationTitle(isPrint ? "Print" : "Schedule a print")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isPrint ? "Start print" : "Schedule") { go() }
                        .buttonStyle(.glassProminent)
                        .disabled(!(bedClear && from != nil && rec != nil) || working || store.busyReason != nil)
                }
            }
            .onAppear {
                name = request.name ?? files.first?.name ?? ""
                fixFrom()
                // At least an hour ahead, rounded up to 5 minutes, as the GUI offers.
                let t = Date().addingTimeInterval(max(Limits.scheduleMinLead + 5 * 60, 3600))
                let step = 5 * 60.0
                at = Date(timeIntervalSinceReferenceDate: (t.timeIntervalSinceReferenceDate / step).rounded(.up) * step)
            }
            .interactiveDismissDisabled(working)
        }
        .presentationDetents([.large])
    }

    private var earliest: Date { Date().addingTimeInterval(Limits.scheduleMinLead) }
    private var latest: Date { Date().addingTimeInterval(Limits.scheduleMaxLead) }

    /// With the card possible it's the user's choice; without it, it's the Pi.
    private func fixFrom() {
        from = onCard ? nil : "pi"
    }

    private func go() {
        guard let from, let rec else { return }
        working = true
        error = nil
        Task {
            defer { working = false }
            do {
                let req = PrintRequest(name: rec.name, from: from, bedClear: bedClear, at: isPrint ? nil : at)
                if isPrint { try await store.startPrint(req) } else { try await store.schedule(req) }
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
