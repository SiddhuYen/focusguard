import Foundation

/// Turns "the user edited settings" into a list of individual changes, so tightening ones
/// can apply now and loosening ones can be scheduled 24 hours out (3.8).
enum SettingsChangeClassifier {
    static func diff(from old: Settings, to new: Settings) -> [SettingsChange] {
        var changes: [SettingsChange] = []

        let oldDomains = Set(old.blocklist.domains)
        let newDomains = Set(new.blocklist.domains)
        changes += newDomains.subtracting(oldDomains).sorted().map { .blockedDomainAdded($0) }
        changes += oldDomains.subtracting(newDomains).sorted().map { .blockedDomainRemoved($0) }

        let oldBaseline = old.baseline.systemBundleIDs.union(old.baseline.extraBundleIDs)
        let newBaseline = new.baseline.systemBundleIDs.union(new.baseline.extraBundleIDs)
        changes += newBaseline.subtracting(oldBaseline).sorted().map { .baselineAppAdded($0) }
        changes += oldBaseline.subtracting(newBaseline).sorted().map { .baselineAppRemoved($0) }

        if old.baseline.passwordManagerBundleIDs != new.baseline.passwordManagerBundleIDs {
            changes.append(.passwordManagerSet(
                from: old.baseline.passwordManagerBundleIDs.sorted(),
                to: new.baseline.passwordManagerBundleIDs.sorted()
            ))
        }

        func trigger(_ kind: GateTriggerKind, _ was: Bool, _ now: Bool) {
            guard was != now else { return }
            changes.append(now ? .gateTriggerEnabled(kind) : .gateTriggerDisabled(kind))
        }
        trigger(.unlock, old.gateOnUnlock, new.gateOnUnlock)
        trigger(.wake, old.gateOnWake, new.gateOnWake)
        trigger(.idleReturn, old.gateOnIdleReturn, new.gateOnIdleReturn)

        if old.idleThreshold != new.idleThreshold {
            changes.append(.idleThresholdChanged(from: old.idleThreshold, to: new.idleThreshold))
        }
        if old.maxFullSessionLength != new.maxFullSessionLength {
            changes.append(.maxFullSessionLengthChanged(from: old.maxFullSessionLength, to: new.maxFullSessionLength))
        }
        if old.openSessionCountdownEnabled != new.openSessionCountdownEnabled {
            changes.append(new.openSessionCountdownEnabled ? .openSessionCountdownEnabled : .openSessionCountdownDisabled)
        }
        if old.failClosedURLReading != new.failClosedURLReading {
            changes.append(new.failClosedURLReading ? .failClosedURLReadingEnabled : .failClosedURLReadingDisabled)
        }
        if old.overrideCountdown != new.overrideCountdown {
            changes.append(.overrideCountdownChanged(from: old.overrideCountdown, to: new.overrideCountdown))
        }
        if old.overrideDuration != new.overrideDuration {
            changes.append(.overrideDurationChanged(from: old.overrideDuration, to: new.overrideDuration))
        }
        if old.overridePhrase != new.overridePhrase {
            changes.append(.overridePhraseChanged(from: old.overridePhrase, to: new.overridePhrase))
        }
        if old.launchAtLogin != new.launchAtLogin {
            changes.append(.launchAtLoginChanged(to: new.launchAtLogin))
        }
        if old.requireReasonToLeave != new.requireReasonToLeave {
            changes.append(.legacyRequireReasonChanged(to: new.requireReasonToLeave))
        }
        if old.allowTemporaryEscapes != new.allowTemporaryEscapes {
            changes.append(.legacyAllowEscapesChanged(to: new.allowTemporaryEscapes))
        }
        if old.defaultEscapeDuration != new.defaultEscapeDuration {
            changes.append(.legacyEscapeDurationChanged(from: old.defaultEscapeDuration, to: new.defaultEscapeDuration))
        }

        return changes
    }

    static func apply(_ change: SettingsChange, to settings: inout Settings) {
        switch change {
        case .blockedDomainAdded(let domain):
            settings.blocklist.add(domain)
        case .blockedDomainRemoved(let domain):
            settings.blocklist.remove(domain)
        case .baselineAppAdded(let bundleID):
            settings.baseline.extraBundleIDs.insert(bundleID)
        case .baselineAppRemoved(let bundleID):
            settings.baseline.extraBundleIDs.remove(bundleID)
            settings.baseline.systemBundleIDs.remove(bundleID)
        case .passwordManagerSet(_, let to):
            settings.baseline.passwordManagerBundleIDs = Set(to)
        case .gateTriggerEnabled(let kind):
            setTrigger(kind, to: true, in: &settings)
        case .gateTriggerDisabled(let kind):
            setTrigger(kind, to: false, in: &settings)
        case .idleThresholdChanged(_, let to):
            settings.idleThreshold = to
        case .maxFullSessionLengthChanged(_, let to):
            settings.maxFullSessionLength = to
        case .openSessionCountdownEnabled:
            settings.openSessionCountdownEnabled = true
        case .openSessionCountdownDisabled:
            settings.openSessionCountdownEnabled = false
        case .failClosedURLReadingEnabled:
            settings.failClosedURLReading = true
        case .failClosedURLReadingDisabled:
            settings.failClosedURLReading = false
        case .overrideCountdownChanged(_, let to):
            settings.overrideCountdown = to
        case .overrideDurationChanged(_, let to):
            settings.overrideDuration = to
        case .overridePhraseChanged(_, let to):
            settings.overridePhrase = to
        case .launchAtLoginChanged(let to):
            settings.launchAtLogin = to
        case .legacyRequireReasonChanged(let to):
            settings.requireReasonToLeave = to
        case .legacyAllowEscapesChanged(let to):
            settings.allowTemporaryEscapes = to
        case .legacyEscapeDurationChanged(_, let to):
            settings.defaultEscapeDuration = to
        }
    }

    private static func setTrigger(_ kind: GateTriggerKind, to value: Bool, in settings: inout Settings) {
        switch kind {
        case .unlock: settings.gateOnUnlock = value
        case .wake: settings.gateOnWake = value
        case .idleReturn: settings.gateOnIdleReturn = value
        }
    }

    /// Splits an edit into what applies now and what has to wait.
    struct Plan: Equatable, Sendable {
        var applied: [SettingsChange] = []
        var scheduled: [PendingChange] = []
        var settings: Settings
    }

    static func plan(
        from old: Settings,
        to new: Settings,
        now: Date,
        delay: TimeInterval = FocusGuardConfig.current.looseningDelay
    ) -> Plan {
        var result = Plan(settings: old)
        for change in diff(from: old, to: new) {
            switch change.direction {
            case .tightening, .neutral:
                apply(change, to: &result.settings)
                result.applied.append(change)
            case .loosening:
                result.scheduled.append(PendingChange(change: change, scheduledAt: now, delay: delay))
            }
        }
        return result
    }
}
