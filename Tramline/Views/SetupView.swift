import SwiftUI
import VisionKit

/// Signing in, as a new computer does: the Pi allows this phone's fingerprint, and the
/// phone saves the Pi's addresses and pins its fingerprint. No trust-on-first-use: the
/// fingerprint has to come from the Pi, by paste or QR code.
struct SetupView: View {
    @Environment(AppModel.self) private var app
    @State private var hosts: [String] = ["raspberrypi"]
    @State private var fingerprint = ""
    @State private var scanning = false
    @State private var working = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Tramline signs in to your print server with a key made on this iPhone, which never leaves it. The Pi has to allow it once.")
                        .foregroundStyle(.secondary)
                }

                Section {
                    NavigationLink {
                        PhoneFingerprintView()
                    } label: {
                        Label("Allow this iPhone on the Pi", systemImage: "1.circle.fill")
                    }
                } footer: {
                    Text("Shows the command to run on the Pi, with this phone's fingerprint.")
                }

                Section {
                    ForEach($hosts.indices, id: \.self) { i in
                        TextField(i == 0 ? "raspberrypi" : "another address", text: $hosts[i])
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .font(.body.monospaced())
                    }
                    .onDelete { hosts.remove(atOffsets: $0) }
                    Button("Add another address", systemImage: "plus") { hosts.append("") }
                } header: {
                    Label("The Pi's address", systemImage: "2.circle.fill")
                } footer: {
                    Text("Tried in order, port 8726 unless you give one. With Tailscale on, raspberrypi reaches the Pi at home and away, through MagicDNS. Add its Tailscale IP or full ts.net name as well, to fall back on.")
                }

                Section {
                    TextField("64 hex characters", text: $fingerprint, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.callout.monospaced())
                    HStack {
                        Button("Paste", systemImage: "doc.on.clipboard") {
                            if let s = UIPasteboard.general.string { apply(scanned: s) }
                        }
                        .buttonStyle(.bordered)
                        if DataScannerViewController.isSupported {
                            Button("Scan QR code", systemImage: "qrcode.viewfinder") { scanning = true }
                                .buttonStyle(.bordered)
                        }
                    }
                } header: {
                    Label("The Pi's fingerprint", systemImage: "3.circle.fill")
                } footer: {
                    Text("From `sudo -u tramline tramline fingerprint` on the Pi, or the `fingerprint` in `~/.config/tramline/client.json` on your Mac. Copy it on the Mac and paste it here with Universal Clipboard.")
                }

                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.bad)
                    }
                }

                Section {
                    Button {
                        connect()
                    } label: {
                        HStack {
                            Spacer()
                            if working { ProgressView().padding(.trailing, 6) }
                            Text("Connect").font(.headline)
                            Spacer()
                        }
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(working || cleanHosts.isEmpty || Fingerprint.normalized(fingerprint) == nil)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
            }
            .navigationTitle("Set up Tramline")
            .sheet(isPresented: $scanning) {
                QRScanner { text in
                    scanning = false
                    apply(scanned: text)
                }
                .ignoresSafeArea()
            }
        }
    }

    private var cleanHosts: [String] { hosts.compactMap(Login.normalizeHost) }

    private func apply(scanned text: String) {
        guard let parsed = Login.parseScanned(text) else {
            error = "That isn't a fingerprint: it should be 64 hex characters."
            return
        }
        error = nil
        if !parsed.hosts.isEmpty { hosts = parsed.hosts }
        if let fp = parsed.fingerprint { fingerprint = fp }
    }

    private func connect() {
        guard let fp = Fingerprint.normalized(fingerprint) else { return }
        working = true
        error = nil
        Task {
            defer { working = false }
            do {
                try await app.signIn(Login(hosts: cleanHosts, fingerprint: fp))
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// This phone's fingerprint and the command that allows it on the Pi.
struct PhoneFingerprintView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Form {
            if let fp = app.identity?.fingerprint {
                let command = "sudo -u tramline tramline allow \(fp) --name iphone"
                Section {
                    Text(grouped(fp))
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                    ShareLink(item: fp) { Label("Share fingerprint", systemImage: "square.and.arrow.up") }
                } header: {
                    Text("This iPhone")
                } footer: {
                    Text("The SHA-256 of this phone's certificate. It isn't secret: it's what the Pi checks this phone by.")
                }
                Section {
                    Text(command)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                    Button("Copy command", systemImage: "doc.on.doc") { UIPasteboard.general.string = command }
                    ShareLink(item: command) { Label("Send to your Mac", systemImage: "square.and.arrow.up") }
                } header: {
                    Text("Run on the Pi")
                } footer: {
                    Text("For example over SSH from your Mac. Allowing needs no restart. If the Pi later refuses this phone, run it again.")
                }
            }
        }
        .navigationTitle("Allow this iPhone")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func grouped(_ fp: String) -> String {
        stride(from: 0, to: fp.count, by: 8).map { i in
            let a = fp.index(fp.startIndex, offsetBy: i)
            return String(fp[a..<fp.index(a, offsetBy: 8)])
        }.joined(separator: " ")
    }
}

/// VisionKit's live scanner, for a QR code with the login or the fingerprint.
struct QRScanner: UIViewControllerRepresentable {
    let found: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
                                           qualityLevel: .balanced, isHighlightingEnabled: true)
        vc.delegate = context.coordinator
        try? vc.startScanning()
        return vc
    }

    func updateUIViewController(_ vc: DataScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(found: found) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let found: (String) -> Void
        private var done = false
        init(found: @escaping (String) -> Void) { self.found = found }

        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !done else { return }
            for case let .barcode(code) in items {
                if let text = code.payloadStringValue {
                    done = true
                    scanner.stopScanning()
                    found(text)
                    return
                }
            }
        }
    }
}
