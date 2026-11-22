import SwiftUI

/// Scheduled prints, coming soonest first, then the ones that have ended, latest first.
struct ScheduleView: View {
    @Environment(PrinterStore.self) private var store
    @State private var run: RunRequest?
    @State private var confirmCancel: ScheduledPrint?

    var body: some View {
        NavigationStack {
            List {
                if let error = store.schedulesError, store.schedules == nil {
                    Text("Can't list them: \(error)").foregroundStyle(.secondary)
                } else if let list = store.schedules {
                    if list.isEmpty {
                        ContentUnavailableView {
                            Label("No scheduled prints", systemImage: "calendar.badge.clock")
                        } description: {
                            Text("A scheduled print checks tram now, and again at its time, and only prints if both pass.")
                        } actions: {
                            Button("Schedule a print") { run = RunRequest(mode: .schedule) }
                                .buttonStyle(.glassProminent)
                                .disabled(store.busyReason != nil)
                        }
                    }
                    let coming = list.filter { Words.schedulePending.contains($0.state) || $0.state == "printing" }
                    let ended = list.filter { !(Words.schedulePending.contains($0.state) || $0.state == "printing") }.reversed()
                    if !coming.isEmpty {
                        Section("Coming") { ForEach(coming) { row($0) } }
                    }
                    if !ended.isEmpty {
                        Section("Ended") { ForEach(Array(ended)) { row($0) } }
                    }
                } else {
                    HStack { ProgressView(); Text("Loading…").foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("Schedule")
            .refreshable { await store.loadSchedules() }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Schedule a print", systemImage: "plus") {
                        Task {
                            if store.files == nil { await store.loadFiles() }
                            run = RunRequest(mode: .schedule)
                        }
                    }
                    .disabled(store.busyReason != nil)
                }
            }
            .onAppear {
                store.scheduleTabShown = true
                Task { await store.loadSchedules() }
            }
            .onDisappear { store.scheduleTabShown = false }
            .sheet(item: $run) { RunSheet(request: $0) }
            .confirmationDialog("Cancel this scheduled print?",
                                isPresented: Binding(get: { confirmCancel != nil }, set: { if !$0 { confirmCancel = nil } }),
                                titleVisibility: .visible, presenting: confirmCancel) { p in
                Button("Cancel it", role: .destructive) { Task { await store.cancelSchedule(p) } }
                Button("Keep it", role: .cancel) {}
            } message: { p in
                Text("\(p.name) at \(Words.scheduleWhen(p.at)).")
            }
        }
    }

    private func row(_ p: ScheduledPrint) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(Words.scheduleWhen(p.at)).font(.body.weight(.medium))
                Spacer()
                ToneChip(text: Words.scheduleState(p.state), tone: Words.scheduleTone(p.state))
            }
            Text("\(p.name), from the \(p.from == "sd" ? "card" : "Pi")").font(.subheadline).foregroundStyle(.secondary)
            if let c = p.check { Text(Words.checkText("Check when scheduling", c)).font(.caption).foregroundStyle(.secondary) }
            if let c = p.finalCheck { Text(Words.checkText("Check at its time", c)).font(.caption).foregroundStyle(.secondary) }
            if let reason = p.reason {
                let bad = Words.scheduleBad.contains(p.state) && reason != "cancelled on request"
                Text(reason).font(.caption).foregroundStyle(bad ? Theme.bad : .secondary)
            }
        }
        .padding(.vertical, 2)
        .swipeActions {
            if Words.schedulePending.contains(p.state) {
                Button("Cancel", role: .destructive) { confirmCancel = p }
            }
        }
        .contextMenu {
            if Words.schedulePending.contains(p.state) {
                Button("Cancel…", systemImage: "xmark.circle", role: .destructive) { confirmCancel = p }
            }
        }
    }
}
