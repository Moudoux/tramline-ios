import Foundation

// The JSON the Pi sends, from the Go structs in tramline/internal/server (status, print,
// tram, upload, schedule, web), marlin and tram. Fields Go omits when empty are optional.
// States stay strings, so a new one from a newer server doesn't break decoding.

struct Temps: Codable, Sendable, Equatable {
    var nozzle: Double
    var nozzleTarget: Double
    var bed: Double
    var bedTarget: Double

    enum CodingKeys: String, CodingKey {
        case nozzle, bed
        case nozzleTarget = "nozzle_target"
        case bedTarget = "bed_target"
    }
}

/// A tram check's verdict. Corners are front-left, front-right, back-right, back-left.
struct TramResult: Codable, Sendable, Equatable {
    var relativeMM: [Double]
    var rangeMM: Double
    var pass: Bool
    var corner: String?
    var action: String?

    enum CodingKeys: String, CodingKey {
        case pass, corner, action
        case relativeMM = "relative_mm"
        case rangeMM = "range_mm"
    }
}

// MARK: - The read-only page's status, GET /api/status

struct WebStatus: Codable, Sendable, Equatable {
    var version: String
    var simulated: Bool?
    var connected: Bool
    var temps: Temps?
    var print: WebPrint?
    var tramming: Bool?
    var copy: WebCopy?
    var scheduled: [WebSchedule]?
}

struct WebPrint: Codable, Sendable, Equatable {
    var id: Int
    var name: String
    /// The file it prints, see `PrintJob.sha256`.
    var sha256: String?
    var mode: String
    var state: String
    var pos: Int64
    var size: Int64
    var movedAgo: Double
    var runSeconds: Double
    var elsewhere: Bool?
    var linkLost: Bool?
    var parked: Bool?
    var stopping: Bool?
    var check: TramResult?
    var turn: String?
    var note: String?
    var error: String?

    enum CodingKeys: String, CodingKey {
        case id, name, sha256, mode, state, pos, size, elsewhere, parked, stopping, check, turn, note, error
        case movedAgo = "moved_ago"
        case runSeconds = "run_seconds"
        case linkLost = "link_lost"
    }
}

struct WebCopy: Codable, Sendable, Equatable {
    var name: String
    var sha256: String?
    var bytes: Int64
    var totalBytes: Int64

    enum CodingKeys: String, CodingKey {
        case name, sha256, bytes
        case totalBytes = "total_bytes"
    }
}

struct WebSchedule: Codable, Sendable, Equatable, Identifiable {
    var id: Int
    var name: String
    var sha256: String?
    var from: String
    var at: Date
    var state: String
    var ended: Bool?
    var reason: String?
}

// MARK: - The full status, GET /v1/status

struct StatusResponse: Codable, Sendable, Equatable {
    var version: String
    var simulated: Bool?
    var printer: PrinterStatus
    var plug: PlugStatus?
    var heatersOffAt: Date?
    var heatProblem: String?
    var tram: TramJob?
    var copy: CopyJob?
    var print: PrintJob?
    var scheduled: [ScheduledPrint]?

    enum CodingKeys: String, CodingKey {
        case version, simulated, printer, plug, tram, copy, print, scheduled
        case heatersOffAt = "heaters_off_at"
        case heatProblem = "heat_problem"
    }
}

struct PrinterStatus: Codable, Sendable, Equatable {
    var connected: Bool
    var firmware: String?
    var temps: Temps?
    var tempsAt: Date?

    enum CodingKeys: String, CodingKey {
        case connected, firmware, temps
        case tempsAt = "temps_at"
    }
}

struct PlugStatus: Codable, Sendable, Equatable {
    var name: String?
    var on: Bool
    var error: String?
}

struct PrintJob: Codable, Sendable, Equatable {
    var id: Int
    var name: String
    /// From the Pi, checked on its disk just before; from the card, the bytes sent in its
    /// copy. Nil for a print started elsewhere, or before checksums were kept.
    var sha256: String?
    var sdName: String?
    var mode: String
    var state: String
    var elsewhere: Bool?
    var scheduleID: Int?
    var preCheck: Bool?
    var pos: Int64
    var size: Int64
    var linkLost: Bool?
    var check: TramResult?
    var checks: Int?
    var parked: Bool?
    var mesh: MeshProgress?
    var meshRead: MeshRead?
    var stopping: Bool?
    var note: String?
    var error: String?
    var startedAt: Date?
    var finishedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, name, sha256, mode, state, elsewhere, pos, size, check, checks, parked, mesh, stopping, note, error
        case sdName = "sd_name"
        case scheduleID = "schedule_id"
        case preCheck = "pre_check"
        case linkLost = "link_lost"
        case meshRead = "mesh_read"
        case startedAt = "started_at"
        case finishedAt = "finished_at"
    }
}

struct MeshProgress: Codable, Sendable, Equatable {
    var point: Int
    var of: Int
    var pointSeconds: Double?

    enum CodingKeys: String, CodingKey {
        case point, of
        case pointSeconds = "point_seconds"
    }
}

struct MeshRead: Codable, Sendable, Equatable {
    var readAt: Date
    var mesh: MeshReport?
    var error: String?

    enum CodingKeys: String, CodingKey {
        case mesh, error
        case readAt = "read_at"
    }
}

/// A mesh from the firmware: `z[j][i]`, column i from the left and row j from the front.
struct MeshReport: Codable, Sendable, Equatable {
    var z: [[Double?]]
    var valid: Bool
    var slot: Int?
    var active: Bool?
}

struct TramReading: Codable, Sendable, Equatable {
    var corner: String
    var x: Double
    var y: Double
    var z: Double
}

struct TramRound: Codable, Sendable, Equatable {
    var readings: [TramReading]?
    var result: TramResult?
}

struct TramJob: Codable, Sendable, Equatable {
    var id: Int
    var state: String
    var step: String?
    var inset: Int
    var `repeat`: Int
    var rounds: [TramRound]?
    var result: TramResult?
    var spreadMM: [Double]?
    var parked: Bool
    var error: String?
    var finishedAt: Date?
    var phase: String?

    enum CodingKeys: String, CodingKey {
        case id, state, step, inset, `repeat`, rounds, result, parked, error, phase
        case spreadMM = "spread_mm"
        case finishedAt = "finished_at"
    }
}

struct CopyJob: Codable, Sendable, Equatable {
    var id: Int
    var name: String
    var sdName: String
    var state: String
    var bytes: Int64
    var totalBytes: Int64
    /// The upload's, which the bytes sent must match.
    var sha256: String?
    var error: String?

    enum CodingKeys: String, CodingKey {
        case id, name, state, bytes, error, sha256
        case sdName = "sd_name"
        case totalBytes = "total_bytes"
    }
}

struct ScheduledPrint: Codable, Sendable, Equatable, Identifiable {
    var id: Int
    var name: String
    /// The file's when it was scheduled: the upload's, or the card copy's.
    var sha256: String?
    var from: String
    var at: Date
    var state: String
    var jobID: Int?
    var check: TramResult?
    var finalCheck: TramResult?
    var reason: String?
    var endedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, name, sha256, from, at, state, check, reason
        case jobID = "job_id"
        case finalCheck = "final_check"
        case endedAt = "ended_at"
    }
}

// MARK: - Files

struct FileInfo: Codable, Sendable, Equatable {
    var lines: Int
    var sdSize: Int64

    enum CodingKeys: String, CodingKey {
        case lines
        case sdSize = "sd_size"
    }
}

struct FileRecord: Codable, Sendable, Equatable, Identifiable {
    var name: String
    var sha256: String
    var size: Int64
    var info: FileInfo
    var uploadedAt: Date
    var sdName: String
    var onCard: Bool
    /// Empty, `running`, `verified` or `failed`. A finished copy is `verified`.
    var sdState: String?
    var sdError: String?
    /// What the Pi sent in the last copy whose size checked out on the card. It stays
    /// after a new upload, as that copy is still on the card.
    var cardSHA256: String?
    var cardSize: Int64?
    /// A fresh read of the file on the Pi's disk, in listings only.
    var disk: DiskCheck?

    var id: String { name }

    /// The file on the Pi no longer matches its upload.
    var damaged: Bool { disk.map { $0.sha256 != nil && !$0.match } ?? false }

    enum CodingKeys: String, CodingKey {
        case name, sha256, size, info, disk
        case cardSHA256 = "card_sha256"
        case cardSize = "card_size"
        case uploadedAt = "uploaded_at"
        case sdName = "sd_name"
        case onCard = "on_card"
        case sdState = "sd_state"
        case sdError = "sd_error"
    }
}

struct DiskCheck: Codable, Sendable, Equatable {
    var sha256: String?
    /// The file reads as its upload did.
    var match: Bool
    var checkedAt: Date?
    /// Why there's no answer, such as that it isn't read during a print or a copy.
    var error: String?

    enum CodingKeys: String, CodingKey {
        case sha256, match, error
        case checkedAt = "checked_at"
    }
}

/// A file on the card. For one copied from here, `upload` names the file on the Pi, and
/// `sha256` is what its last checked copy sent, if the size on the card still matches,
/// or else `note` says why there's none.
struct CardFile: Codable, Sendable, Equatable, Identifiable {
    var name: String
    var size: Int64
    var upload: String?
    var sha256: String?
    var note: String?
    var id: String { name }
}

struct FilesResponse: Codable, Sendable, Equatable {
    var files: [FileRecord]?
    /// Nil when the printer couldn't be asked, with the reason in `cardNote`.
    var card: [CardFile]?
    var cardNote: String?

    enum CodingKeys: String, CodingKey {
        case files, card
        case cardNote = "card_note"
    }
}

struct CopyResponse: Codable, Sendable {
    var file: FileRecord
    var job: CopyJob?
}

// MARK: - Actions

struct PreheatResponse: Codable, Sendable {
    var bed: Int
    var nozzle: Int
    var heatersOffAt: Date

    enum CodingKeys: String, CodingKey {
        case bed, nozzle
        case heatersOffAt = "heaters_off_at"
    }
}

struct CoolResponse: Codable, Sendable {
    var off: Bool
    var cancelling: Bool?
}

struct EstopResponse: Codable, Sendable {
    var m112: Bool
    var plugOff: Bool
    var problems: [String]?

    enum CodingKeys: String, CodingKey {
        case m112, problems
        case plugOff = "plug_off"
    }
}

struct MeshInfo: Codable, Sendable {
    var lines: [String]?
    var mesh: MeshReport?
    var parseError: String?

    enum CodingKeys: String, CodingKey {
        case lines, mesh
        case parseError = "parse_error"
    }
}

struct HueLight: Codable, Sendable, Identifiable {
    var id: String
    var name: String
    var archetype: String
    var on: Bool
}

struct TramRequest: Encodable, Sendable {
    var bedClear: Bool
    var inset: Int?
    var `repeat`: Int?

    enum CodingKeys: String, CodingKey {
        case inset, `repeat`
        case bedClear = "bed_clear"
    }
}

struct PrintRequest: Encodable, Sendable {
    var name: String
    var from: String
    var bedClear: Bool
    var at: Date?

    enum CodingKeys: String, CodingKey {
        case name, from, at
        case bedClear = "bed_clear"
    }
}

// MARK: - JSON

enum JSON {
    /// Go writes RFC 3339 with fractional seconds, and leaves them out when they're zero.
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            if let date = try? Date(s, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true).timeZone(separator: .colon)) {
                return date
            }
            if let date = try? Date(s, strategy: .iso8601) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "not an RFC 3339 time: \(s)")
        }
        return d
    }()

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}
