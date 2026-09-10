import Foundation

/// The whole state machine, pure and testable: `(State, Event) -> (State, [Effect])`.
/// No AppKit, no timers, no I/O. The app layer feeds it events and runs the effects.
enum FocusReducer {
    static func reduce(
        _ state: AppState,
        _ event: AppEvent,
        context: ReducerContext = .live,
        config: FocusGuardConfig = .current
    ) -> (AppState, [Effect]) {
        var state = state
        var effects: [Effect] = []
        let now = context.now()

        switch event {
        case .launched(let restoredSession, let safeMode):
            if let safeMode {
                state.phase = .safeMode(safeMode.reason)
                state.statusMessage = safeMode.message
                effects.append(.log(LogEvent(
                    SafeModePayload(reason: safeMode.reason, detail: safeMode.detail),
                    id: context.newID(),
                    timestamp: now
                )))
                break
            }

            if let session = restoredSession, session.endedAt == nil {
                state.phase = .session(session)
                state.statusMessage = "Resumed: \(session.goal)"
                effects.append(.persistSession(session))
            } else {
                state.phase = .idle
                effects.append(.persistSession(nil))
            }

        case .sessionStartRequested(let request):
            guard state.canStartSession else { break }
            let session = makeSession(request, state: state, now: now, context: context, config: config)
            state.phase = .session(session)
            state.statusMessage = startMessage(for: session)
            effects.append(.log(LogEvent(
                SessionStartedPayload(
                    sessionID: session.id,
                    kind: session.kind,
                    goal: session.goal,
                    anchorBundleID: session.anchor.bundleID,
                    allowedBundleIDs: session.allowedBundleIDs,
                    allowedSites: session.allowedSites,
                    plannedEnd: session.plannedEnd,
                    presetID: session.presetID
                ),
                id: context.newID(),
                timestamp: now
            )))
            effects.append(.persistSession(session))
            effects.append(.dismissIntervention)

        case .appActivated(let app):
            let previous = state.frontmostApp
            let dwell = state.frontmostSince.map { now.timeIntervalSince($0) } ?? 0
            state.frontmostApp = app
            if previous?.bundleID != app.bundleID { state.frontmostSince = now }

            switch state.phase {
            case .idle, .safeMode:
                break

            case .session(var session):
                if let previous, previous.bundleID != app.bundleID, dwell >= config.appsUsedThreshold {
                    session.noteUsage(of: previous, seconds: dwell)
                }
                let decision = Allowlist.decide(app: app, session: session, baseline: state.settings.baseline)
                if case .violation(let kind) = decision {
                    let (updated, violationEffects) = enterIntervention(
                        session: session, kind: kind, app: app, state: &state, now: now, context: context
                    )
                    session = updated
                    effects += violationEffects
                } else {
                    state.phase = .session(session)
                }

            case .gracePeriod(let session, let until):
                if now >= until {
                    state.phase = .session(session)
                    effects.append(.cancelEscapeTimer)
                    let decision = Allowlist.decide(app: app, session: session, baseline: state.settings.baseline)
                    if case .violation(let kind) = decision {
                        let (_, violationEffects) = enterIntervention(
                            session: session, kind: kind, app: app, state: &state, now: now, context: context
                        )
                        effects += violationEffects
                    }
                }

            case .intervention:
                effects.append(.bringInterventionToFront)
            }

        case .urlObserved(let browser, let url):
            guard state.phase.isEnforcing, var session = state.phase.session else { break }
            if let host = URLNormalizer.host(of: url) {
                session.noteVisit(host: host)
                state.phase = rebuild(state.phase, with: session)
            }

            let decision = Allowlist.decide(
                url: url, in: browser, session: session, blocklist: state.settings.blocklist
            )
            if case .violation(let kind) = decision {
                if case .intervention = state.phase {
                    effects.append(.bringInterventionToFront)
                } else {
                    let (_, violationEffects) = enterIntervention(
                        session: session, kind: kind, app: browser, state: &state, now: now, context: context
                    )
                    effects += violationEffects
                }
            }

        case .urlReadFailed(let browser, let failures):
            guard state.settings.failClosedURLReading,
                  failures >= config.urlFailClosedPolls,
                  state.phase.isEnforcing,
                  let session = state.phase.session else { break }
            if case .intervention = state.phase {
                effects.append(.bringInterventionToFront)
            } else {
                let (_, violationEffects) = enterIntervention(
                    session: session,
                    kind: .unverifiableURL(browser: browser.bundleID),
                    app: browser,
                    state: &state,
                    now: now,
                    context: context
                )
                effects += violationEffects
            }

        case .returnRequested:
            guard let session = state.phase.session else { break }
            state.phase = .session(session)
            state.statusMessage = "Returned to \(session.anchor.name)."
            effects.append(.dismissIntervention)
            effects.append(.cancelEscapeTimer)
            effects.append(.activateApp(bundleID: session.anchor.bundleID))

        case .addToSessionRequested(let target, let reason):
            // Reachable from the intervention panel and from the menu during a session.
            let existing: (session: Session, violation: Violation?)?
            switch state.phase {
            case .intervention(let session, let violation): existing = (session, violation)
            case .session(let session): existing = (session, nil)
            case .idle, .gracePeriod, .safeMode: existing = nil
            }
            guard var session = existing?.session else { break }

            if let violation = existing?.violation, !violation.isAddable {
                effects.append(.bringInterventionToFront)
                state.statusMessage = "Blocked sites can never be added to a session."
                break
            }

            let addition = SessionAddition(id: context.newID(), timestamp: now, target: target, reason: reason)
            session.add(addition)
            let wasIntervention = existing?.violation != nil
            state.phase = .session(session)
            state.statusMessage = "Added to this session: \(describe(target))."
            effects.append(.log(LogEvent(
                AdditionPayload(sessionID: session.id, target: target, reason: reason),
                id: context.newID(),
                timestamp: now
            )))
            effects.append(.persistSession(session))
            if wasIntervention { effects.append(.dismissIntervention) }

        case .escapeRequested(let duration, let reason):
            guard var session = state.phase.session, state.settings.allowTemporaryEscapes else { break }
            let escape = Escape(id: context.newID(), startedAt: now, duration: duration, reason: reason)
            session.escapes.append(escape)
            let until = now.addingTimeInterval(duration)
            state.phase = .gracePeriod(session, until: until)
            state.statusMessage = "Temporary escape started."
            effects.append(.dismissIntervention)
            effects.append(.persistSession(session))
            effects.append(.scheduleEscapeEnd(at: until))

        case .escapeExpired:
            guard case .gracePeriod(let session, _) = state.phase else { break }
            state.phase = .session(session)
            effects.append(.cancelEscapeTimer)
            if let app = state.frontmostApp {
                let decision = Allowlist.decide(app: app, session: session, baseline: state.settings.baseline)
                if case .violation(let kind) = decision {
                    let (_, violationEffects) = enterIntervention(
                        session: session, kind: kind, app: app, state: &state, now: now, context: context
                    )
                    effects += violationEffects
                }
            }

        case .endRequested(let outcome):
            guard var session = state.phase.session else { break }
            session.endedAt = now
            session.outcome = outcome
            state.phase = .idle
            state.statusMessage = "Focus ended."
            effects.append(.log(LogEvent(
                SessionEndedPayload(
                    sessionID: session.id,
                    kind: session.kind,
                    goal: session.goal,
                    outcome: outcome,
                    startedAt: session.startedAt,
                    endedAt: now,
                    plannedEnd: session.plannedEnd,
                    violationCount: session.violations.count,
                    additionCount: session.additions.count
                ),
                id: context.newID(),
                timestamp: now
            )))
            if !session.appsUsed.isEmpty || !session.domainsVisited.isEmpty {
                effects.append(.log(LogEvent(
                    AppsUsedSnapshotPayload(
                        sessionID: session.id,
                        apps: session.appsUsed,
                        domains: session.domainsVisited
                    ),
                    id: context.newID(),
                    timestamp: now
                )))
            }
            effects.append(.persistSession(nil))
            effects.append(.dismissIntervention)
            effects.append(.cancelEscapeTimer)

        case .permissionsChanged(let health):
            let old = state.permissions
            state.permissions = health
            effects += permissionEffects(from: old, to: health, now: now, context: context)

        case .settingsEdited(let newSettings):
            let plan = SettingsChangeClassifier.plan(
                from: state.settings, to: newSettings, now: now, delay: config.looseningDelay
            )
            state.settings = plan.settings
            state.pendingChanges += plan.scheduled

            for change in plan.applied {
                effects.append(.log(LogEvent(
                    SettingsChangeAppliedPayload(changeID: nil, change: change, delayed: false),
                    id: context.newID(),
                    timestamp: now
                )))
            }
            for pending in plan.scheduled {
                effects.append(.log(LogEvent(
                    SettingsChangeScheduledPayload(
                        changeID: pending.id, change: pending.change, effectiveAt: pending.effectiveAt
                    ),
                    id: context.newID(),
                    timestamp: now
                )))
            }
            if !plan.applied.isEmpty { effects.append(.persistSettings(state.settings)) }
            if !plan.scheduled.isEmpty {
                effects.append(.persistPendingChanges(state.pendingChanges))
                state.statusMessage = "\(plan.scheduled.count) change(s) take effect in 24 hours."
            }

        case .pendingChangeCancelled(let id):
            guard let index = state.pendingChanges.firstIndex(where: { $0.id == id }) else { break }
            let pending = state.pendingChanges.remove(at: index)
            effects.append(.log(LogEvent(
                SettingsChangeCancelledPayload(changeID: pending.id, change: pending.change),
                id: context.newID(),
                timestamp: now
            )))
            effects.append(.persistPendingChanges(state.pendingChanges))

        case .presetsLoaded(let presets):
            state.presets = presets

        case .tick:
            let due = state.pendingChanges.filter { $0.isDue(at: now) }
            if !due.isEmpty {
                state.pendingChanges.removeAll { pending in due.contains { $0.id == pending.id } }
                for pending in due {
                    SettingsChangeClassifier.apply(pending.change, to: &state.settings)
                    effects.append(.log(LogEvent(
                        SettingsChangeAppliedPayload(changeID: pending.id, change: pending.change, delayed: true),
                        id: context.newID(),
                        timestamp: now
                    )))
                }
                effects.append(.persistSettings(state.settings))
                effects.append(.persistPendingChanges(state.pendingChanges))
            }

            if case .gracePeriod(_, let until) = state.phase, now >= until {
                let (expiredState, expiredEffects) = reduce(state, .escapeExpired, context: context, config: config)
                state = expiredState
                effects += expiredEffects
            }

        case .statusMessageCleared:
            state.statusMessage = nil
        }

        effects.append(urlMonitoringEffect(for: state))
        return (state, dedupeMonitoring(effects))
    }

    // MARK: - Helpers

    private static func makeSession(
        _ request: SessionRequest,
        state: AppState,
        now: Date,
        context: ReducerContext,
        config: FocusGuardConfig
    ) -> Session {
        var allowed = request.allowedBundleIDs
        if !allowed.contains(request.anchor.bundleID) { allowed.insert(request.anchor.bundleID, at: 0) }

        var plannedEnd: Date?
        switch request.kind {
        case .full:
            if let duration = request.duration {
                plannedEnd = now.addingTimeInterval(min(duration, state.settings.maxFullSessionLength))
            }
        case .open:
            plannedEnd = now.addingTimeInterval(config.openSessionLength)
        }

        return Session(
            id: context.newID(),
            kind: request.kind,
            goal: request.goal,
            anchor: request.anchor,
            allowedBundleIDs: allowed,
            allowedSites: request.allowedSites,
            allowAllNonBlockedSites: request.allowAllNonBlockedSites,
            startedAt: now,
            plannedEnd: plannedEnd,
            presetID: request.presetID
        )
    }

    private static func enterIntervention(
        session: Session,
        kind: ViolationKind,
        app: AppIdentity,
        state: inout AppState,
        now: Date,
        context: ReducerContext
    ) -> (Session, [Effect]) {
        var session = session
        let violation = Violation(id: context.newID(), timestamp: now, kind: kind, app: app)
        session.record(violation)
        state.phase = .intervention(session, violation)
        state.statusMessage = statusMessage(for: kind)

        return (session, [
            .log(LogEvent(
                ViolationPayload(
                    sessionID: session.id,
                    kind: kind,
                    appBundleID: app.bundleID,
                    appName: app.name
                ),
                id: context.newID(),
                timestamp: now
            )),
            .persistSession(session),
            .showIntervention(session, violation)
        ])
    }

    private static func permissionEffects(
        from old: PermissionHealth,
        to new: PermissionHealth,
        now: Date,
        context: ReducerContext
    ) -> [Effect] {
        var effects: [Effect] = []
        func compare(_ name: String, _ was: Bool, _ isHealthy: Bool, detail: String?) {
            guard was != isHealthy else { return }
            if isHealthy {
                effects.append(.log(LogEvent(
                    PermissionRestoredPayload(permission: name), id: context.newID(), timestamp: now
                )))
            } else {
                effects.append(.log(LogEvent(
                    PermissionPayload(permission: name, detail: detail ?? ""),
                    id: context.newID(),
                    timestamp: now
                )))
            }
        }
        compare("accessibility", old.accessibilityTrusted, new.accessibilityTrusted, detail: new.detail)
        compare("automation", old.automationAuthorized, new.automationAuthorized, detail: new.detail)
        return effects
    }

    private static func rebuild(_ phase: AppPhase, with session: Session) -> AppPhase {
        switch phase {
        case .session: return .session(session)
        case .intervention(_, let violation): return .intervention(session, violation)
        case .gracePeriod(_, let until): return .gracePeriod(session, until: until)
        case .idle, .safeMode: return phase
        }
    }

    /// URL polling follows the frontmost browser for as long as a session exists, including
    /// while an intervention panel is up. v1 stopped polling on the first URL violation and
    /// never restarted it.
    private static func urlMonitoringEffect(for state: AppState) -> Effect {
        guard state.phase.isEnforcing,
              let app = state.frontmostApp,
              KnownBrowser.isBrowser(bundleID: app.bundleID) else {
            return .monitorURLs(nil)
        }
        return .monitorURLs(app)
    }

    private static func dedupeMonitoring(_ effects: [Effect]) -> [Effect] {
        var seenMonitor = false
        return effects.reversed().filter { effect in
            guard case .monitorURLs = effect else { return true }
            defer { seenMonitor = true }
            return !seenMonitor
        }.reversed()
    }

    private static func startMessage(for session: Session) -> String {
        switch session.kind {
        case .open: return "Open session: \(session.goal)"
        case .full:
            return session.allowedBundleIDs.count > 1
                ? "Focusing on \(session.allowedBundleIDs.count) apps."
                : "Focusing on \(session.anchor.name)."
        }
    }

    private static func statusMessage(for kind: ViolationKind) -> String {
        switch kind {
        case .app(let app): return "You left your focus apps for \(app.name)."
        case .blockedSite(let domain, _): return "Blocked distracting site: \(domain)"
        case .unlistedSite(let host, _): return "\(host) is not in this session's site list."
        case .unpinnedPage(let host, _): return "Only the pinned page on \(host) is allowed."
        case .unverifiableURL: return "Focus Guard can't verify this page."
        }
    }

    private static func describe(_ target: AdditionTarget) -> String {
        switch target {
        case .app(let app): return app.name
        case .site(let rule): return rule.pattern
        }
    }
}
