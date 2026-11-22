import Foundation

/// How a badge or chip is coloured, as the GUI's CSS classes are.
enum Tone: Sendable, Equatable {
    case plain, active, good, bad
}

/// The GUI's words and formats, ported from `shared/status.js` and `gui/gui.js`, so the
/// phone and the desktop read the same.
enum Words {
    static let corners = ["front-left", "front-right", "back-right", "back-left"]

    /// `STATE_TEXT`: a print state's badge, its tone and its message.
    static func printState(_ state: String) -> (badge: String, tone: Tone, message: String) {
        switch state {
        case "heating": ("heating", .active, "Heating for the tram check before printing.")
        case "soaking": ("soaking", .active, "At temperature, letting the bed settle before the tram check.")
        case "checking": ("checking tram", .active, "Probing the corners of the bed.")
        case "adjusting": ("needs you", .bad, "")
        case "starting": ("starting", .active, "Tram check passed, starting the file.")
        case "running": ("printing", .active, "")
        case "cancelling": ("cancelling", .bad, "The print is being cancelled.")
        case "finished": ("finished", .good, "")
        case "cancelled": ("cancelled", .plain, "")
        case "scheduled": ("tram passed, scheduled", .good, "")
        case "failed": ("failed", .bad, "")
        case "unknown": ("ended, outcome unknown", .plain, "")
        default: (state, .active, "")
        }
    }

    static let activeStates: Set = ["heating", "soaking", "checking", "adjusting", "starting", "running", "cancelling"]
    static let preparingStates: Set = ["heating", "soaking", "checking", "adjusting", "starting", "scheduled"]
    static let schedulePending: Set = ["checking", "waiting", "starting"]
    static let scheduleBad: Set = ["failed", "cancelled", "missed", "unknown"]

    static func isPrinting(_ state: String?) -> Bool { state == "running" || state == "cancelling" }
    static func isActive(_ state: String?) -> Bool { state.map(activeStates.contains) ?? false }

    /// `SCHEDULE_TEXT`.
    static func scheduleState(_ state: String) -> String {
        switch state {
        case "checking": "checking tram now"
        case "waiting": "waiting"
        case "starting": "starting"
        case "printing": "printing"
        default: state
        }
    }

    static func scheduleTone(_ state: String) -> Tone {
        if scheduleBad.contains(state) { return .bad }
        if state == "finished" { return .good }
        if schedulePending.contains(state) || state == "printing" { return .active }
        return .plain
    }

    /// `clock`: 1 h 5 min, 4 min 10 s, 12 s.
    static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "–" }
        let s = Int(seconds.rounded())
        let h = s / 3600, m = (s % 3600) / 60
        if h > 0 { return "\(h) h \(m) min" }
        if m > 0 { return "\(m) min \(s % 60) s" }
        return "\(s) s"
    }

    /// `temp`: 61.5 / 80 °C, or 21.0 °C with no target.
    static func temp(_ now: Double?, _ target: Double?) -> String {
        guard let now else { return "–" }
        if let target, target > 0 {
            return String(format: "%.1f / %.0f °C", now, target)
        }
        return String(format: "%.1f °C", now)
    }

    /// `bytes`: 1.5 MB, 12 KB, 300 bytes.
    static func bytes(_ n: Int64) -> String {
        if n >= 1 << 20 { return String(format: "%.1f MB", Double(n) / Double(1 << 20)) }
        if n >= 1 << 10 { return "\(Int((Double(n) / 1024).rounded())) KB" }
        return "\(n) bytes"
    }

    /// `sentence`: the Pi's messages are written to follow other words, so this starts one
    /// with a capital and ends it with a full stop.
    static func sentence(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = t.first else { return t }
        let ended = t.last.map { ".!?".contains($0) } ?? false
        return first.uppercased() + t.dropFirst() + (ended ? "" : ".")
    }

    /// `scheduleWhen`: weekday, date, time and timezone, so it can't be misread.
    static func scheduleWhen(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute().timeZone(.specificName(.short)))
    }

    static func shortTime(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
    }

    static func clockTime(_ date: Date) -> String {
        date.formatted(.dateTime.hour().minute())
    }

    static func turn(_ action: String?) -> String { action == "lower" ? "counter-clockwise" : "clockwise" }

    /// The advice for a failed check: which knob, and which way.
    static func advice(_ result: TramResult) -> (head: String, rest: String)? {
        guard let action = result.action, let corner = result.corner, let first = action.first else { return nil }
        return ("\(first.uppercased())\(action.dropFirst()) \(corner):", "turn its knob \(turn(action)), seen from above.")
    }

    static func checkText(_ label: String, _ c: TramResult) -> String {
        "\(label): \(c.pass ? "passed" : "failed"), range \(String(format: "%.3f", c.rangeMM)) mm"
    }

    /// `safeName`: a name the Pi will take, keeping the extension.
    static func safeName(_ name: String) -> String {
        var stem = name
        var ext = ".gcode"
        if let m = name.firstMatch(of: /(?i)\.(gcode|gco)$/) {
            stem = String(name[..<m.range.lowerBound])
            ext = String(name[m.range]).lowercased()
        }
        stem = stem.replacing(/[^A-Za-z0-9._-]+/, with: "_")
        stem = stem.replacing(/^[^A-Za-z0-9]+/, with: "")
        stem = stem.replacing(/[._-]+$/, with: "")
        stem = String(stem.prefix(64 - ext.count))
        return (stem.isEmpty ? "print" : stem) + ext
    }

    static func isGcode(_ name: String) -> Bool { name.firstMatch(of: /(?i)\.(gcode|gco)$/) != nil }

    /// `meshText`: the mesh as the bed is seen from the front, as `tramline mesh` prints it.
    static func meshText(_ m: MeshReport) -> String {
        var head = ["Mesh: \(m.valid ? "valid" : "not valid, as some points have no height")"]
        if let slot = m.slot { head.append("storage slot \(slot)") }
        if let active = m.active { head.append("leveling \(active ? "on" : "off")") }
        var rows = [head.joined(separator: ", "), "Heights in mm, back of the bed at the top, left on the left:"]
        var all: [Double] = []
        for row in m.z.reversed() {
            rows.append(row.map { z -> String in
                guard let z else { return "       ." }
                all.append(z)
                let s = (z >= 0 ? "+" : "") + String(format: "%.3f", z)
                return String(repeating: " ", count: max(8 - s.count, 0)) + s
            }.joined())
        }
        if let lo = all.min(), let hi = all.max() {
            rows.append("Range \(String(format: "%.3f", hi - lo)) mm")
        }
        return rows.joined(separator: "\n")
    }

    static func meshRange(_ m: MeshReport) -> Double {
        let known = m.z.flatMap { $0 }.compactMap { $0 }
        guard let lo = known.min(), let hi = known.max() else { return 0 }
        return hi - lo
    }
}
