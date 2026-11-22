import SwiftUI

/// The four corners as seen from above, back at the top, from `bedMap` in `gui.js`.
struct BedMapView: View {
    /// Heights relative to the average, in the order of `Words.corners`.
    var relative: [Double]?
    /// The corner to adjust, outlined.
    var target: String?
    /// Readings so far while a check runs, by corner index.
    var pending: [Int: Double]?

    private static let order = [3, 2, 0, 1]

    var body: some View {
        Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow { cell(Self.order[0]); cell(Self.order[1]) }
            GridRow { cell(Self.order[2]); cell(Self.order[3]) }
        }
    }

    private func cell(_ i: Int) -> some View {
        let name = Words.corners[i]
        let isTarget = target == name
        let value: String
        var muted = false
        if let pending {
            value = pending[i].map { String(format: "%.3f mm", $0) } ?? "–"
            muted = true
        } else if let relative, relative.indices.contains(i) {
            let v = relative[i]
            value = (v >= 0 ? "+" : "") + String(format: "%.3f mm", v)
        } else {
            value = "–"
            muted = true
        }
        return VStack(alignment: .leading, spacing: 2) {
            Text(name).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.body.monospacedDigit().weight(.semibold))
                .foregroundStyle(muted ? .secondary : .primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.fill.tertiary, in: .rect(cornerRadius: 12))
        .overlay {
            if isTarget { RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.bad, lineWidth: 2) }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The verdict and advice for a check, from `verdict` and `advice` in `gui.js`.
struct TramVerdictView: View {
    let result: TramResult

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ToneChip(text: result.pass ? "in tram" : "out of tram", tone: result.pass ? .good : .bad)
                Text("range \(String(format: "%.3f", result.rangeMM)) mm, limit \(String(format: "%.2f", Limits.tramTolerance)) mm")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !result.pass, let advice = Words.advice(result) {
                Text("**\(advice.head)** \(advice.rest)")
                    .font(.subheadline)
            }
        }
    }
}
