import SwiftUI
import UIKit

/// The GUI's "i" beside a file's name: tap it for the file's SHA-256 and what it was
/// checked against, with a button to copy it. "!" is a damaged or older file, and "?" one
/// whose sum isn't known.
struct SumBadge: View {
    let info: SumInfo
    @State private var shown = false
    @State private var copied = false

    var body: some View {
        Button { shown = true } label: {
            Text(symbol)
                .font(.caption2.weight(.bold))
                .frame(width: 18, height: 18)
                .foregroundStyle(color)
                .background(color.opacity(0.15), in: .circle)
                .overlay(Circle().strokeBorder(color.opacity(0.4), lineWidth: 1))
                .contentShape(.circle.inset(by: -8))
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(info.sha256.map { "\(info.title): SHA-256 \($0)" } ?? "\(info.title): no SHA-256")
        .popover(isPresented: $shown) {
            VStack(alignment: .leading, spacing: 10) {
                Text(info.title).font(.headline)
                    .foregroundStyle(info.kind == .bad ? Theme.bad : .primary)
                if let sha = info.sha256 {
                    Text(sha)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(info.notes, id: \.self) { note in
                    Text(note).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let sha = info.sha256 {
                    Button(copied ? "Copied" : "Copy SHA-256", systemImage: copied ? "checkmark" : "doc.on.doc") {
                        UIPasteboard.general.string = sha
                        copied = true
                    }
                    .buttonStyle(.glass)
                }
            }
            .padding()
            .frame(idealWidth: 320, maxWidth: 360)
            .presentationCompactAdaptation(.popover)
            .onDisappear { copied = false }
        }
    }

    private var symbol: String {
        switch info.kind {
        case .bad: "!"
        case .unknown: "?"
        case .plain: "i"
        }
    }

    private var color: Color {
        switch info.kind {
        case .bad: Theme.bad
        case .unknown: .secondary
        case .plain: Theme.accent
        }
    }
}
