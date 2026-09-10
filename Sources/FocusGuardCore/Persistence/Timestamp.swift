import Foundation

extension Date {
    /// Timestamps on disk are ISO-8601 with milliseconds, so domain timestamps are created
    /// at that precision. Note the format is only accurate to ~1ms: a Date is not
    /// guaranteed to survive a string round-trip bit-for-bit, so compare persisted
    /// timestamps with a millisecond tolerance rather than with ==.
    var loggable: Date {
        Date(timeIntervalSinceReferenceDate: (timeIntervalSinceReferenceDate * 1000).rounded() / 1000)
    }

    static var nowLoggable: Date { Date().loggable }

    func isSameInstant(as other: Date, tolerance: TimeInterval = 0.002) -> Bool {
        abs(timeIntervalSinceReferenceDate - other.timeIntervalSinceReferenceDate) <= tolerance
    }
}
