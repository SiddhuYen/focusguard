import AppKit
import ApplicationServices
import Foundation

/// Decides at launch whether the app is safe to gate with, and keeps the liveness records
/// that make crashes, kills, and downtime visible afterwards (3.9.2, 3.9.3, 3.10).
@MainActor
final class LaunchGuard {
    private let store: StateStore
    private let log: EventLogStore
    private let config: FocusGuardConfig
    private var record: LaunchRecord
    private var heartbeatTimer: Timer?
    private(set) var safeMode: SafeModeEntry?

    init(
        store: StateStore,
        log: EventLogStore,
        config: FocusGuardConfig = .current,
        modifiersHeld: Bool = LaunchGuard.escapeModifiersHeld(),
        uptime: TimeInterval = LaunchGuard.currentUptime()
    ) {
        self.store = store
        self.log = log
        self.config = config

        var records = store.loadLaunchRecords()
        let heartbeat = store.loadHeartbeat()

        // Close out the previous run. With no clean-exit marker, the last heartbeat plus
        // one interval is the best *upper* bound on when it died: the run definitely
        // reached its last beat and cannot have survived a full interval past it. Using
        // the bound rather than the beat itself keeps a long-lived run that was killed
        // from looking like a one-second startup crash.
        var uncleanExit = false
        if var previous = records.last, !previous.exitedCleanly {
            uncleanExit = true
            if let beat = heartbeat?.timestamp, beat >= previous.launchedAt {
                previous.exitedAt = beat.addingTimeInterval(config.heartbeatInterval)
            }
            records[records.count - 1] = previous
        }

        let restartEscape = CrashLoopDetector.isRestartEscape(
            modifiersHeld: modifiersHeld,
            systemUptime: uptime,
            maxUptime: config.restartEscapeMaxUptime
        )
        let crashLoop = CrashLoopDetector.evaluate(
            records: records,
            now: Date(),
            threshold: config.crashLoopThreshold,
            window: config.crashLoopWindow
        )
        if restartEscape {
            safeMode = SafeModeEntry(
                reason: .restartEscape,
                detail: "Control+Option+Command held \(Int(uptime))s after boot"
            )
        } else if crashLoop {
            safeMode = SafeModeEntry(
                reason: .crashLoop,
                detail: "\(config.crashLoopThreshold) unclean exits within \(Int(config.crashLoopWindow))s of launch"
            )
        } else {
            safeMode = nil
        }

        record = LaunchRecord(
            launchedAt: .nowLoggable,
            version: BuildInfo.versionStamp,
            signature: BuildInfo.signature,
            safeMode: safeMode?.reason
        )
        records.append(record)
        store.saveLaunchRecords(records)

        log.append(AppLaunchedPayload(
            version: BuildInfo.version,
            build: BuildInfo.build,
            systemUptime: uptime,
            safeMode: safeMode?.reason,
            uncleanExit: uncleanExit,
            accessibilityTrusted: AXIsProcessTrusted()
        ))

        reportHangMarkerIfPresent()
        reportBuildChangeIfNeeded(previous: records.dropLast().last)
        reportHeartbeatGapIfNeeded(heartbeat: heartbeat, records: records)
    }

    static func escapeModifiersHeld() -> Bool {
        #if DEBUG
        // The real escape needs a fresh boot, which is not something to require while
        // developing. FOCUSGUARD_SIMULATE_RESTART_ESCAPE=1 exercises the same path.
        if ProcessInfo.processInfo.environment["FOCUSGUARD_SIMULATE_RESTART_ESCAPE"] == "1" { return true }
        #endif
        return NSEvent.modifierFlags.isSuperset(of: [.control, .option, .command])
    }

    static func currentUptime() -> TimeInterval {
        #if DEBUG
        if ProcessInfo.processInfo.environment["FOCUSGUARD_SIMULATE_RESTART_ESCAPE"] == "1" { return 0 }
        #endif
        return ProcessInfo.processInfo.systemUptime
    }

    // MARK: - Liveness

    func startHeartbeat() {
        writeHeartbeat(reason: nil)
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: config.heartbeatInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.writeHeartbeat(reason: nil) }
        }
    }

    func noteSystemEvent(_ reason: String) {
        writeHeartbeat(reason: reason)
    }

    func markCleanExit(reason: String) {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil

        var records = store.loadLaunchRecords()
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index].exitedCleanly = true
            records[index].exitedAt = .nowLoggable
            store.saveLaunchRecords(records)
        }
        writeHeartbeat(reason: reason)
        log.append(AppTerminatingPayload(clean: true, reason: reason))
    }

    private func writeHeartbeat(reason: String?) {
        store.saveHeartbeat(Heartbeat(timestamp: .nowLoggable, reason: reason))
    }

    // MARK: - Post-mortems

    private func reportHangMarkerIfPresent() {
        guard let marker = store.loadHangMarker() else { return }
        log.append(
            HangDetectedPayload(unresponsiveSeconds: marker.unresponsiveSeconds),
            at: marker.detectedAt
        )
        store.clearHangMarker()
    }

    private func reportBuildChangeIfNeeded(previous: LaunchRecord?) {
        guard let previous else { return }
        guard previous.version != record.version || previous.signature != record.signature else { return }
        log.append(BuildChangedPayload(
            previousVersion: previous.version,
            version: record.version,
            previousSignature: previous.signature,
            signature: record.signature
        ))
    }

    private func reportHeartbeatGapIfNeeded(heartbeat: Heartbeat?, records: [LaunchRecord]) {
        guard let heartbeat else { return }
        let gap = record.launchedAt.timeIntervalSince(heartbeat.timestamp)
        guard gap > config.heartbeatGapThreshold else { return }
        // Sleep, shutdown, and clean quits explain themselves.
        let explained = heartbeat.reason != nil
        log.append(HeartbeatGapPayload(from: heartbeat.timestamp, to: record.launchedAt, explained: explained))
    }
}
