import SwiftUI

/// Power, heat, tram and the printer's firmware, the GUI's Printer tab.
struct PrinterView: View {
    @Environment(PrinterStore.self) private var store
    @AppStorage("preheat.bed") private var bed = 80
    @AppStorage("preheat.nozzle") private var nozzle = 150
    @State private var confirmOff = false
    @State private var confirmCool = false
    @State private var tramSheet = false
    @State private var working: String?

    var body: some View {
        NavigationStack {
            Form {
                powerSection
                heatSection
                tramSection
                Section("Printer") {
                    if let st = store.full {
                        let sim = st.simulated == true ? " (simulated printer)" : ""
                        Text(st.printer.connected ? "\(st.printer.firmware ?? "Connected")\(sim)" : "Not connected\(sim)")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("–").foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Printer")
            .refreshable { store.refreshSoon() }
            .sheet(isPresented: $tramSheet) { TramSheet() }
        }
    }

    private var powerSection: some View {
        Section {
            let plug = store.full?.plug
            LabeledContent(plug?.name ?? "Plug") {
                if let plug {
                    if plug.error != nil {
                        ToneChip(text: "unknown", tone: .bad)
                    } else {
                        ToneChip(text: plug.on ? "on" : "off", tone: plug.on ? .good : .plain)
                    }
                } else {
                    Text("–")
                }
            }
            if let e = plug?.error {
                Text("Can't read the plug: \(e)").font(.footnote).foregroundStyle(Theme.bad)
            } else if store.full != nil && plug == nil {
                Text("No plug is set up on the server.").font(.footnote).foregroundStyle(.secondary)
            }
            HStack {
                Button("Turn on") { run("on") { await store.power(on: true) } }
                    .buttonStyle(.glassProminent)
                    .disabled(plug?.on == true || working != nil)
                Button("Turn off") { confirmOff = true }
                    .buttonStyle(.glass)
                    .disabled(plug.map { !$0.on && $0.error == nil } ?? false || working != nil)
            }
            .alert("Turn the printer off?", isPresented: $confirmOff) {
                Button("Turn off", role: .destructive) { run("off") { await store.power(on: false) } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The Pi refuses while it's hot or printing.")
            }
        } header: {
            Text("Power")
        }
    }

    private var heatSection: some View {
        Section {
            Stepper(value: $bed, in: 0...110, step: 5) {
                LabeledContent("Bed", value: "\(bed) °C")
            }
            Stepper(value: $nozzle, in: 0...260, step: 5) {
                LabeledContent("Nozzle", value: "\(nozzle) °C")
            }
            HStack {
                Button("Preheat") { run("preheat") { await store.preheat(bed: bed, nozzle: nozzle) } }
                    .buttonStyle(.glassProminent)
                    .disabled(store.busyReason != nil || working != nil)
                Button("Cool down") {
                    if store.printBusy { confirmCool = true } else { run("cool") { await store.cool() } }
                }
                .buttonStyle(.glass)
                .disabled(working != nil)
            }
            .confirmationDialog("Cool down and cancel the print?", isPresented: $confirmCool, titleVisibility: .visible) {
                Button("Cool and cancel", role: .destructive) { run("cool") { await store.cool() } }
                Button("Keep printing", role: .cancel) {}
            } message: {
                Text("During a print, cooling down cancels it.")
            }
        } header: {
            Text("Heat")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if let off = store.full?.heatersOffAt {
                    Text("The heaters turn off at \(Words.clockTime(off)) unless you preheat again.")
                }
                if let busy = store.busyReason { Text(busy) }
            }
        }
    }

    private var tramSection: some View {
        Section("Tram") {
            TramSummary(job: store.full?.tram)
            Button("Check tram…") { tramSheet = true }
                .disabled(store.busyReason != nil)
        }
    }

    private func run(_ key: String, _ action: @escaping () async -> Void) {
        working = key
        Task {
            await action()
            working = nil
        }
    }
}

/// The last tram check, from `showTram` in `gui.js`.
struct TramSummary: View {
    let job: TramJob?

    static let pinHint = "In the 3D view each reading stands as a pin, 20 mm for every 0.05 mm above or below the average, the faint plane. The head's moves are worked out, not measured."

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let job {
                if job.state == "running" {
                    let round = job.rounds?.last
                    let pending = Dictionary((round?.readings ?? []).compactMap { r in
                        Words.corners.firstIndex(of: r.corner).map { ($0, r.z) }
                    }, uniquingKeysWith: { _, b in b })
                    let roundText = job.repeat > 1 ? ", round \(job.rounds?.count ?? 1) of \(job.repeat)" : ""
                    Text("Running\(roundText): \(job.step ?? "starting").").font(.subheadline)
                    BedMapView(pending: pending)
                    Text(Self.pinHint).font(.footnote).foregroundStyle(.secondary)
                } else if job.state == "failed" {
                    Text("The last check failed: \(job.error ?? "unknown")").foregroundStyle(Theme.bad)
                } else if let result = job.result {
                    BedMapView(relative: result.relativeMM, target: result.pass ? nil : result.corner)
                    TramVerdictView(result: result)
                    if job.repeat > 1, let spread = job.spreadMM {
                        Text("Repeatability over \(job.repeat) rounds: " + zip(Words.corners, spread)
                            .map { "\($0) \(String(format: "%.3f", $1)) mm" }.joined(separator: ", ") + ".")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Text((job.finishedAt.map { "Checked \(Words.shortTime($0)). " } ?? "")
                         + (job.parked ? "The head is parked." : "The head was not parked."))
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } else {
                Text("No check since the server started.").foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Check tram, from the GUI's dialog. The bed-clear switch starts off every time.
struct TramSheet: View {
    @Environment(PrinterStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var bedClear = false
    @State private var inset: Int?
    @State private var rounds = 1
    @State private var error: String?
    @State private var working = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Probes the four corners. The head crosses the bed low down, at whatever temperature the printer is at now.")
                        .foregroundStyle(.secondary)
                }
                Section {
                    LabeledContent("Inset") {
                        TextField("default", value: $inset, format: .number)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                        Text("mm").foregroundStyle(.secondary)
                    }
                    Stepper("Rounds: \(rounds)", value: $rounds, in: 1...10)
                } footer: {
                    Text("The inset is how far in from the bed's edges it probes, 1 to 100 mm. Leave it empty for the server's default.")
                }
                Section {
                    Toggle("I've checked the bed is clear", isOn: $bedClear).tint(Theme.accent)
                }
                if let error {
                    Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.bad) }
                }
            }
            .navigationTitle("Check tram")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Check tram") { go() }
                        .buttonStyle(.glassProminent)
                        .disabled(!bedClear || working)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func go() {
        if let inset, !(1...100).contains(inset) {
            error = "The inset must be from 1 to 100 mm."
            return
        }
        working = true
        error = nil
        Task {
            defer { working = false }
            do {
                try await store.tram(TramRequest(bedClear: bedClear, inset: inset, repeat: rounds))
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
