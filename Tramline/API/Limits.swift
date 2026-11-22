import Foundation

/// What the desktop GUI gets from `tramline gui`'s `/gui/info`, which the phone can't ask
/// the Pi for. Keep these in step with the Go code named beside each.
enum Limits {
    /// `server.MaxUpload` in `internal/server/upload.go`.
    static let maxUpload: Int64 = 256 << 20
    /// `tram.Tolerance` in `internal/tram/tram.go`.
    static let tramTolerance = 0.05
    /// `copyBytesPerSecond` in `internal/server/upload.go`.
    static let copyBytesPerSecond = 14_000.0
    /// `server.ScheduleMinLead` and `server.ScheduleMaxLead` in `internal/server/schedule.go`.
    static let scheduleMinLead: TimeInterval = 15 * 60
    static let scheduleMaxLead: TimeInterval = 30 * 24 * 3600
    /// `FILE_NAME` in `internal/webui/gui/gui.js`.
    static func isFileName(_ name: String) -> Bool {
        name.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9._-]{0,63}/) != nil
    }
    /// The port `tramline serve` listens on.
    static let defaultPort = 8726
}
