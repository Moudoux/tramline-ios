import SwiftUI

/// Hue, probing settings and the mesh, About, and this phone's connection.
struct MoreView: View {
    @Environment(PrinterStore.self) private var store
    @Environment(AppModel.self) private var app
    @State private var lights: [HueLight]?
    @State private var output: String?
    @State private var working: String?
    @State private var confirmForget = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button("Pair with the bridge") {
                        run("pair") { await store.act(done: { _ in "Paired with the Hue Bridge." }) { try await store.client.huePair() } }
                    }
                    Button("List plugs") {
                        run("plugs") { lights = await store.act { try await store.client.huePlugs() } }
                    }
                    if let lights {
                        if lights.isEmpty { Text("Nothing on the bridge.").foregroundStyle(.secondary) }
                        ForEach(lights) { l in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(l.name)
                                    Text("\(l.archetype) · \(l.id)").font(.caption.monospaced()).foregroundStyle(.secondary)
                                }
                                Spacer()
                                ToneChip(text: l.on ? "on" : "off", tone: l.on ? .good : .plain)
                            }
                        }
                    }
                } header: {
                    Text("Hue plug")
                } footer: {
                    Text("To pair, press the button on the Hue Bridge, then Pair within 30 seconds. The key stays on the Pi.")
                }

                Section {
                    Button("Probing settings") {
                        run("info") {
                            if let lines = await store.act({ try await store.client.tramInfo() }) {
                                output = lines.joined(separator: "\n")
                            }
                        }
                    }
                    Button("Read the mesh") {
                        run("mesh") {
                            if let info = await store.act({ try await store.client.mesh() }) {
                                output = info.mesh.map(Words.meshText)
                                    ?? "\((info.lines ?? []).joined(separator: "\n"))\n\nCouldn't read a mesh in that: \(info.parseError ?? "")"
                                store.showHeights(info.mesh)
                            }
                        }
                    }
                    if let job = store.full?.print, let read = job.meshRead {
                        if let mesh = read.mesh {
                            Button("Show the mesh after \(job.name)") {
                                output = Words.meshText(mesh)
                                store.showHeights(mesh)
                            }
                            Text("Read at \(Words.clockTime(read.readAt)): range \(String(format: "%.3f", Words.meshRange(mesh))) mm.")
                                .font(.footnote).foregroundStyle(.secondary)
                        } else {
                            Text("The mesh after \(job.name) couldn't be read: \(read.error ?? "")")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    if store.heights != nil {
                        Button("Hide the mesh in the 3D view") { store.showHeights(nil) }
                    }
                    if let output {
                        ScrollView(.horizontal) {
                            Text(output).font(.caption.monospaced()).textSelection(.enabled)
                                .padding(.vertical, 4)
                        }
                    }
                } header: {
                    Text("Probing")
                } footer: {
                    Text("Asks the firmware about probing and the mesh. Nothing moves. The 3D view shows the mesh as a surface, 20 mm high for every 0.05 mm, blue below the average and orange above.")
                }

                Section("About") {
                    LabeledContent("App", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–")
                    LabeledContent("Server", value: store.full.map { "\($0.version)\($0.simulated == true ? ", simulated printer" : "")" } ?? "–")
                    LabeledContent("Address", value: store.client.activeHost)
                }

                Section {
                    NavigationLink("This iPhone's fingerprint") { PhoneFingerprintView() }
                    LabeledContent("Addresses", value: store.client.login.hosts.joined(separator: ", "))
                    LabeledContent("Server fingerprint") {
                        Text(store.client.login.fingerprint.prefix(16) + "…").font(.caption.monospaced())
                    }
                    Button("Forget this server", role: .destructive) { confirmForget = true }
                } header: {
                    Text("Connection")
                } footer: {
                    Text("To change the addresses, forget the server and set it up again. This phone's key stays, so the Pi doesn't need to allow it again.")
                }
            }
            .navigationTitle("More")
            .disabled(working != nil)
            .confirmationDialog("Forget this server?", isPresented: $confirmForget, titleVisibility: .visible) {
                Button("Forget", role: .destructive) { app.signOut() }
            } message: {
                Text("Nothing changes on the Pi. You'll need its address and fingerprint to set it up again.")
            }
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
