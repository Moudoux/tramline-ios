import SwiftUI

@main
struct TramlineApp: App {
    @State private var app = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .task { await app.start() }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        switch app.phase {
        case .starting:
            ProgressView()
        case let .failed(text):
            ContentUnavailableView("Couldn't set up this phone's key", systemImage: "key.slash", description: Text(text))
        case .setup:
            SetupView()
        case let .ready(store):
            MainView()
                .environment(store)
                .id(ObjectIdentifier(store))
        }
    }
}

struct MainView: View {
    @Environment(PrinterStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab = MainView.firstTab

    enum TabID: String, Hashable { case now, files, printer, schedule, more }

    /// `-debugTab files` opens on another tab, for screenshots.
    private static var firstTab: TabID {
        #if DEBUG
        UserDefaults.standard.string(forKey: "debugTab").flatMap(TabID.init(rawValue:)) ?? .now
        #else
        .now
        #endif
    }

    var body: some View {
        @Bindable var store = store
        TabView(selection: $tab) {
            Tab("Now", systemImage: "cube.transparent", value: .now) { NowView() }
            Tab("Files", systemImage: "doc.on.doc", value: .files) { FilesView() }
            Tab("Printer", systemImage: "printer", value: .printer) { PrinterView() }
            Tab("Schedule", systemImage: "calendar.badge.clock", value: .schedule) { ScheduleView() }
                .badge(store.comingSchedules)
            Tab("More", systemImage: "ellipsis", value: .more) { MoreView() }
        }
        .tabViewBottomAccessory {
            StatusAccessory { tab = .now }
        }
        .overlay(alignment: .top) { ToastStack() }
        .alert(item: $store.estopOutcome) { out in
            Alert(title: Text(out.title),
                  message: Text(([out.text] + out.list).filter { !$0.isEmpty }.joined(separator: "\n\n")),
                  dismissButton: out.ok ? .default(Text("OK")) : .destructive(Text("OK")))
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            // The phone can't poll in the background, and shouldn't keep asking the Hue Bridge.
            if phase == .active { store.start() } else { store.stop() }
        }
        .onOpenURL { url in
            if url.isFileURL { tab = .files }
        }
    }
}

/// Above the tab bar on every tab: what the printer is doing, and the emergency stop.
struct StatusAccessory: View {
    @Environment(PrinterStore.self) private var store
    let showNow: () -> Void

    var body: some View {
        let card = store.now
        HStack(spacing: 10) {
            Button(action: showNow) {
                HStack(spacing: 8) {
                    Circle().fill(Theme.color(card.tone)).frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(card.badge).font(.subheadline.weight(.semibold)).lineLimit(1)
                        if !card.file.isEmpty {
                            Text(card.file).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 4)
                    if let p = card.progress {
                        Text(String(format: "%.0f%%", p * 100))
                            .font(.subheadline.monospacedDigit().weight(.semibold))
                            .contentTransition(.numericText())
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows the printer's status.")

            EstopButton(fire: { Task { await store.estop() } }, size: 36)
        }
        .padding(.leading, 16)
        .padding(.trailing, 4)
    }
}

struct ToastStack: View {
    @Environment(PrinterStore.self) private var store

    var body: some View {
        VStack(spacing: 8) {
            ForEach(store.toasts.suffix(3)) { t in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: t.tone == .bad ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(Theme.color(t.tone == .bad ? .bad : .good))
                    Text(t.text).font(.subheadline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .glassEffect(in: .rect(cornerRadius: 20))
                .onTapGesture { store.toasts.removeAll { $0.id == t.id } }
                .transition(.move(edge: .top).combined(with: .opacity))
                .accessibilityAddTraits(.isStaticText)
            }
        }
        .padding(.horizontal)
        .animation(.spring(duration: 0.35), value: store.toasts)
        .sensoryFeedback(trigger: store.toasts.last?.id) { _, _ in
            guard let t = store.toasts.last else { return nil }
            return t.tone == .bad ? .error : .success
        }
    }
}
