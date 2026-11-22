import Foundation

/// A file's SHA-256 and what it means, for the badge beside its name. Ported from
/// `jobSum` in `shared/status.js`, and `piSum` and `cardSum` in `gui.js`.
struct SumInfo: Equatable, Sendable {
    enum Kind: Sendable { case plain, bad, unknown }

    /// Nil when it isn't known.
    var sha256: String?
    var title: String
    var notes: [String] = []
    var kind = Kind.plain

    /// The first 12 digits, as `sha256sum` output starts.
    static func short(_ sha: String) -> String { String(sha.prefix(12)) }

    /// A print's file, or nil for one started elsewhere.
    static func job(sha256: String?, mode: String, elsewhere: Bool?) -> SumInfo? {
        guard let sha = sha256, !sha.isEmpty else {
            if elsewhere == true { return nil }
            return SumInfo(title: "The file this prints", notes: [mode == "sd"
                ? "Its copy on the card was made before checksums were kept."
                : "Started before checksums were kept."], kind: .unknown)
        }
        return SumInfo(sha256: sha, title: "The file this prints", notes: [mode == "sd"
            ? "What the Pi sent to the card in its copy, whose size then checked out. The card can't be read back."
            : "Checked on the Pi's disk just before it started, against its upload."])
    }

    static func copying(_ sha: String?) -> SumInfo? {
        guard let sha, !sha.isEmpty else { return nil }
        return SumInfo(sha256: sha, title: "The file being copied",
                       notes: ["Its upload's sum, which what the Pi reads and sends must match."])
    }

    /// A file on the Pi, from the server's fresh read of its disk.
    static func pi(_ rec: FileRecord) -> SumInfo {
        let up = "Uploaded \(Words.shortTime(rec.uploadedAt))."
        let checked = rec.disk?.checkedAt.map(Words.clockTime) ?? "the last check"
        if let d = rec.disk, let now = d.sha256, !d.match {
            return SumInfo(sha256: now, title: "DAMAGED: the file on the Pi now reads as", notes: [
                "At \(checked), it didn't match its upload, which was \(short(rec.sha256)).",
                "Upload it again before printing it.",
            ], kind: .bad)
        }
        if let d = rec.disk, d.sha256 != nil {
            return SumInfo(sha256: rec.sha256, title: "SHA-256 of the file on the Pi",
                           notes: [up, "Read from the Pi's disk at \(checked), and it matches its upload."])
        }
        let how = rec.disk?.error.map { "As uploaded. Not read from the disk just now: \($0)." } ?? "As uploaded."
        return SumInfo(sha256: rec.sha256, title: "SHA-256 of the file on the Pi", notes: [up, how])
    }

    /// Whether a card file is an older copy of its upload than what's on the Pi now.
    static func isOlder(_ f: CardFile, records: [FileRecord]) -> Bool {
        guard let sha = f.sha256, let up = f.upload, let rec = records.first(where: { $0.name == up }) else { return false }
        return rec.sha256 != sha
    }

    /// A file on the card. The card can't be read back, so the sum is what the Pi sent.
    static func card(_ f: CardFile, records: [FileRecord]) -> SumInfo {
        let how = "What the Pi sent in its copy, whose size then checked out on the card. The card can't be read back over USB."
        guard let sha = f.sha256, !sha.isEmpty else {
            return SumInfo(title: "SHA-256 of the file on the card", notes: [f.upload != nil
                ? "Not known: \(f.note ?? "no copy was checked")."
                : "Not known: it wasn't copied from here, and the card can't be read back over USB."], kind: .unknown)
        }
        if isOlder(f, records: records), let up = f.upload, let rec = records.first(where: { $0.name == up }) {
            return SumInfo(sha256: sha, title: "SHA-256 of the file on the card", notes: [
                how, "It's an older version: \(up) on the Pi is \(short(rec.sha256)) now. Copy it again to print the new one from the card.",
            ], kind: .bad)
        }
        return SumInfo(sha256: sha, title: "SHA-256 of the file on the card", notes: [how])
    }

    static func schedule(sha256: String?, from: String) -> SumInfo? {
        guard let sha = sha256, !sha.isEmpty else { return nil }
        return SumInfo(sha256: sha, title: "The file it prints", notes: [from == "sd"
            ? "The copy on the card, as the Pi sent it, when this was scheduled."
            : "Its upload's, when this was scheduled. It's checked on the Pi's disk again before it starts."])
    }
}
