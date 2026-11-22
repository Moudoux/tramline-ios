import SwiftUI

/// The 3D view with the status card, the GUI's always-visible card given a tab of its own.
struct NowView: View {
    @Environment(PrinterStore.self) private var store
    @Environment(\.verticalSizeClass) private var vertical

    var body: some View {
        let layout = vertical == .compact
            ? AnyLayout(HStackLayout(spacing: 0))
            : AnyLayout(VStackLayout(spacing: 0))
        layout {
            ZStack(alignment: .topLeading) {
                Theme.viewBackground
                PrintView3D(store: store)
                if store.viewDetails.loaded && !store.viewDetails.ok {
                    Text("This phone can't show the 3D view, as WebGL 2 isn't available. The status still updates.")
                        .font(.footnote)
                        .padding(12)
                        .glassEffect(in: .rect(cornerRadius: 16))
                        .padding()
                }
            }
            .ignoresSafeArea(edges: vertical == .compact ? [.top, .bottom, .leading] : .top)
            .accessibilityLabel("3D view of the print. One finger turns, two fingers pinch and move, double-tap resets.")

            ScrollView {
                StatusCard()
                    .padding()
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxWidth: vertical == .compact ? 380 : .infinity)
            .frame(maxHeight: vertical == .compact ? .infinity : 420)
            .fixedSize(horizontal: false, vertical: vertical != .compact)
            .background(.background)
        }
    }
}

struct StatusCard: View {
    @Environment(PrinterStore.self) private var store
    @State private var confirmCancel = false
    @State private var working = false

    var body: some View {
        let card = store.now
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                ToneChip(text: card.badge, tone: card.tone, prominent: true)
                    .animation(.default, value: card.badge)
                Spacer()
                if let page = store.page, page.simulated == true {
                    Text("simulated").font(.caption).foregroundStyle(.secondary)
                }
            }
            if !card.file.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(card.file).font(.title3.weight(.semibold)).lineLimit(2).textSelection(.enabled)
                    if let sum = card.fileSum { SumBadge(info: sum) }
                }
            }

            if let progress = card.progress {
                VStack(alignment: .leading, spacing: 10) {
                    ProgressView(value: progress)
                        .tint(Theme.accent)
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                        GridRow {
                            Figure("Progress", String(format: progress < 0.1 ? "%.1f%%" : "%.0f%%", progress * 100))
                            Figure("Layer", store.viewDetails.layer)
                        }
                        GridRow {
                            Figure("Time left", store.viewDetails.left)
                            Figure("Running for", card.elapsed)
                        }
                    }
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    Figure("Nozzle", card.nozzle)
                    Figure("Bed", card.bed)
                }
                if let plug = store.full?.plug {
                    GridRow {
                        Figure("Plug", plug.error != nil ? "unknown" : plug.on ? "on" : "off")
                        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    }
                }
            }

            if !card.message.isEmpty {
                Text(card.message).font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !card.problem.isEmpty {
                Label(card.problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(Theme.bad)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let check = card.check {
                VStack(alignment: .leading, spacing: 10) {
                    BedMapView(relative: check.relativeMM, target: check.corner)
                    TramVerdictView(result: check)
                }
                .padding(12)
                .background(Theme.bad.opacity(0.08), in: .rect(cornerRadius: 16))
            }

            actions(card.actions)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .confirmationDialog("Cancel the print?", isPresented: $confirmCancel, titleVisibility: .visible) {
            Button("Cancel print", role: .destructive) { run { await store.cancelPrint() } }
            Button("Keep printing", role: .cancel) {}
        } message: {
            let name = store.page?.print?.name
            Text("\(name.map { "\($0): t" } ?? "T")he heaters turn off. From the card the head goes home, from the Pi it lifts 5 mm.")
        }
    }

    @ViewBuilder
    private func actions(_ kind: NowCard.Actions) -> some View {
        switch kind {
        case .none:
            EmptyView()
        case .adjusting:
            HStack {
                Button("Check again") { run { await store.continuePrint() } }
                    .buttonStyle(.glassProminent)
                Button("Cancel print", role: .destructive) { confirmCancel = true }
                    .buttonStyle(.glass)
            }
            .disabled(working)
        case .print:
            Button("Cancel print", role: .destructive) { confirmCancel = true }
                .buttonStyle(.glass)
                .tint(Theme.bad)
                .disabled(working)
        case .copy:
            Button("Stop copy", role: .destructive) { run { await store.cancelCopy() } }
                .buttonStyle(.glass)
                .tint(Theme.bad)
                .disabled(working)
        }
    }

    private func run(_ action: @escaping () async -> Void) {
        working = true
        Task {
            await action()
            working = false
        }
    }
}

struct Figure: View {
    let label: String
    let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.body.monospacedDigit().weight(.medium))
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
