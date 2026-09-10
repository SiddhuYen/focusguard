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
        let previousPhase = state.phase
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
                if session.hasExpired(at: now) {
                    // It ran out while you were away: end it and ask about it at the gate.
                    effects += endSession(
                        session, outcome: .expired, at: session.plannedEnd ?? now,
                        state: &state, context: context, trigger: .launch
                    )
                } else {
                    state.phase = .session(session)
                    state.statusMessage = "Resumed: \(session.goal)"
                    effects.append(.persistSession(session))
                }
            } else {
                effects += showGate(trigger: .launch, state: &state, now: now, context: context)
            }

        case .gateTriggered(let trigger):
            switch state.phase {
            case .session(let session), .intervention(let session, _):
                // Resume rule: come back before the session ends and there is no gate.
                if session.hasExpired(at: now) {
                    effects += endSession(
                        session, outcome: .expired, at: session.plannedEnd ?? now,
                        state: &state, context: context, trigger: trigger
                    )
                }

            case .review:
                break

            case .overridden(let override):
                if now >= override.until {
                    effects += finishOverride(override, early: false, state: &state, now: now, context: context)
                }

            case .safeMode(let reason):
                // A crash loop skips the gate once; the restart escape skips it for the
                // whole launch (3.9.2, 3.9.3).
                if reason == .crashLoop {
                    state.statusMessage = nil
                    effects += showGate(trigger: trigger, state: &state, now: now, context: context)
                }

            case .gate:
                break
            }

        case .gateAnswered(let finished):
            guard case .gate(var gateContext) = state.phase, let prompt = gateContext.lastSession else { break }
            effects.append(.log(LogEvent(
                GateAnsweredPayload(sessionID: prompt.sessionID, finished: finished),
                id: context.newID(),
                timestamp: now
            )))
            gateContext.lastSession = nil
            state.phase = .gate(gateContext)

        case .sessionStartRequested(let request):
            guard state.canStartSession else { break }
            let session = makeSession(request, state: state, now: now, context: context, config: config)
            state.phase = .session(session)
            state.frontmostSince = now
            state.statusMessage = nil
            effects.append(.log(LogEvent(
                startedPayload(for: session), id: context.newID(), timestamp: now
            )))
            effects.append(.persistSession(session))
            state.recentGoals = updatedRecents(
                state.recentGoals, with: session, now: now, context: context, blocklist: state.settings.blocklist
            )
            effects.append(.persistRecentGoals(state.recentGoals))
            if session.kind == .full {
                effects.append(.hideApps(allowed: session.allowedBundleIDs))
            }
            effects.append(.activateApp(bundleID: session.anchor.bundleID))

        case .openSessionExtended:
            guard let session = state.phase.session,
                  session.kind == .open,
                  session.extensionsUsed == 0 else { break }
            var extended = session
            // Ten minutes total, measured from the original end: answering the panel a
            // little late must not buy extra time (3.2).
            let base = session.plannedEnd ?? now
            extended.plannedEnd = base.addingTimeInterval(config.openSessionExtension)
            extended.extensionsUsed = 1
            state.phase = .session(extended)
            effects.append(.log(LogEvent(
                SessionExtendedPayload(
                    sessionID: extended.id,
                    by: config.openSessionExtension,
                    newPlannedEnd: extended.plannedEnd ?? now
                ),
                id: context.newID(),
                timestamp: now
            )))
            effects.append(.persistSession(extended))

        case .convertToFullRequested(let request):
            guard let open = state.phase.session, open.kind == .open else { break }
            var finished = creditingCurrentApp(open, state: state, now: now, config: config)
            finished.endedAt = now
            finished.outcome = .converted
            effects.append(.log(LogEvent(
                endedPayload(for: finished, outcome: .converted, endedAt: now),
                id: context.newID(),
                timestamp: now
            )))
            // What the open session actually used is the whole point of converting.
            if !finished.appsUsed.isEmpty || !finished.domainsVisited.isEmpty {
                effects.append(.log(LogEvent(
                    AppsUsedSnapshotPayload(
                        sessionID: finished.id,
                        apps: finished.appsUsed,
                        domains: finished.domainsVisited
                    ),
                    id: context.newID(),
                    timestamp: now
                )))
            }

            var converted = request
            converted.kind = .full
            converted.convertedFrom = open.id
            let session = makeSession(converted, state: state, now: now, context: context, config: config)
            state.phase = .session(session)
            effects.append(.log(LogEvent(
                SessionConvertedPayload(
                    fromSessionID: open.id,
                    toSessionID: session.id,
                    goal: session.goal,
                    allowedBundleIDs: session.allowedBundleIDs
                ),
                id: context.newID(),
                timestamp: now
            )))
            effects.append(.log(LogEvent(startedPayload(for: session), id: context.newID(), timestamp: now)))
            effects.append(.persistSession(session))
            state.recentGoals = updatedRecents(
                state.recentGoals, with: session, now: now, context: context, blocklist: state.settings.blocklist
            )
            effects.append(.persistRecentGoals(state.recentGoals))
            effects.append(.hideApps(allowed: session.allowedBundleIDs))

        case .reviewExtended(let amount):
            guard case .review(let session, _) = state.phase else { break }
            var extended = session
            let base = max(session.plannedEnd ?? now, now)
            let cap = session.startedAt.addingTimeInterval(state.settings.maxFullSessionLength)
            extended.plannedEnd = min(base.addingTimeInterval(amount), cap)
            extended.extensionsUsed += 1
            state.phase = .session(extended)
            effects.append(.log(LogEvent(
                SessionExtendedPayload(
                    sessionID: extended.id,
                    by: amount,
                    newPlannedEnd: extended.plannedEnd ?? now
                ),
                id: context.newID(),
                timestamp: now
            )))
            effects.append(.persistSession(extended))

        case .reviewAnswered(let finished):
            guard case .review(let session, _) = state.phase else { break }
            effects += endSession(
                session,
                outcome: finished ? .finished : .notFinished,
                at: now,
                state: &state,
                context: context,
                trigger: .sessionEnded,
                answered: finished
            )

        case .endRequested:
            guard let session = state.phase.session else { break }
            state.phase = .review(session, .endedByUser)

        case .forceEnd(let outcome):
            guard let session = state.phase.session else { break }
            effects += endSession(
                session, outcome: outcome, at: now, state: &state, context: context, trigger: .sessionEnded
            )

        case .appActivated(let app):
            let previous = state.frontmostApp
            let dwell = state.frontmostSince.map { now.timeIntervalSince($0) } ?? 0
            state.frontmostApp = app
            if previous?.bundleID != app.bundleID { state.frontmostSince = now }

            switch state.phase {
            case .gate, .review, .overridden, .safeMode:
                break

            case .session(var session):
                if let previous, previous.bundleID != app.bundleID {
                    let credited = min(dwell, now.timeIntervalSince(session.startedAt))
                    if credited >= config.appsUsedThreshold {
                        session.noteUsage(of: previous, seconds: credited)
                    }
                }
                let decision = Allowlist.decide(app: app, session: session, baseline: state.settings.baseline)
                if case .violation(let kind) = decision {
                    effects += enterIntervention(
                        session: session, kind: kind, app: app, state: &state, now: now, context: context
                    )
                } else {
                    state.phase = .session(session)
                }

            case .intervention:
                break
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
            if case .violation(let kind) = decision, !isIntervention(state.phase) {
                effects += enterIntervention(
                    session: session, kind: kind, app: browser, state: &state, now: now, context: context
                )
            }

        case .urlReadFailed(let browser, let failures):
            guard state.settings.failClosedURLReading,
                  failures >= failClosedThreshold(for: browser, config: config),
                  state.phase.isEnforcing,
                  let session = state.phase.session,
                  !isIntervention(state.phase) else { break }
            effects += enterIntervention(
                session: session,
                kind: .unverifiableURL(browser: browser.bundleID),
                app: browser,
                state: &state,
                now: now,
                context: context
            )

        case .returnRequested:
            guard case .intervention(let session, _) = state.phase else { break }
            state.phase = .session(session)
            state.statusMessage = "Returned to \(session.anchor.name)."
            effects.append(.activateApp(bundleID: session.anchor.bundleID))

        case .addToSessionRequested(let target, let reason):
            let existing: (session: Session, violation: Violation?)?
            switch state.phase {
            case .intervention(let session, let violation): existing = (session, violation)
            case .session(let session): existing = (session, nil)
            case .gate, .review, .overridden, .safeMode: existing = nil
            }
            guard var session = existing?.session else { break }

            if let violation = existing?.violation, !violation.isAddable {
                effects.append(.bringInterventionToFront)
                state.statusMessage = "Blocked sites can never be added to a session."
                break
            }

            let addition = SessionAddition(id: context.newID(), timestamp: now, target: target, reason: reason)
            session.add(addition)
            state.phase = .session(session)
            state.statusMessage = "Added to this session: \(describe(target))."
            effects.append(.log(LogEvent(
                AdditionPayload(sessionID: session.id, target: target, reason: reason),
                id: context.newID(),
                timestamp: now
            )))
            effects.append(.persistSession(session))

        case .overrideStarted(let reason):
            let override = OverrideState(
                startedAt: now,
                until: now.addingTimeInterval(state.settings.overrideDuration),
                reason: reason,
                suspendedSession: state.phase.session
            )
            state.phase = .overridden(override)
            state.statusMessage = "Override active until \(override.until.formatted(date: .omitted, time: .shortened))."
            effects.append(.log(LogEvent(
                OverrideStartedPayload(reason: reason, until: override.until),
                id: context.newID(),
                timestamp: now
            )))

        case .overrideEnded(let early):
            guard case .overridden(let override) = state.phase else { break }
            effects += finishOverride(override, early: early, state: &state, now: now, context: context)

        case .sleepRequested:
            effects.append(.log(LogEvent(
                SleepRequestedPayload(source: "gate", succeeded: true),
                id: context.newID(),
                timestamp: now
            )))
            effects.append(.sleepMac)

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

        case .presetCreated(let preset, let source):
            var preset = preset
            preset.allowedSites = portableSites(preset.allowedSites, blocklist: state.settings.blocklist)
            state.presets.removeAll { $0.id == preset.id }
            state.presets.append(preset)
            effects.append(.log(LogEvent(
                PresetCreatedPayload(presetID: preset.id, name: preset.name, source: source),
                id: context.newID(),
                timestamp: now
            )))
            effects.append(.persistPresets(state.presets))

        case .recentGoalsLoaded(let recents):
            state.recentGoals = recents

        case .tick(let idleSeconds):
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

            if case .overridden(let override) = state.phase, now >= override.until {
                effects += finishOverride(override, early: false, state: &state, now: now, context: context)
            }

            if let session = state.phase.session,
               state.phase.isEnforcing,
               session.hasExpired(at: now) {
                // An empty chair gets no panel: the gate handles it when you come back.
                if idleSeconds < state.settings.idleThreshold {
                    state.phase = .review(session, .timeUp)
                }
            }

        case .statusMessageCleared:
            state.statusMessage = nil
        }

        var result = transitionEffects(from: previousPhase, to: state.phase)
        result += effects
        result.append(urlMonitoringEffect(for: state))
        return (state, dedupeMonitoring(result))
    }

    // MARK: - Phase transitions

    /// Windows follow the phase, so no handler has to remember to open or close them.
    private static func transitionEffects(from old: AppPhase, to new: AppPhase) -> [Effect] {
        var effects: [Effect] = []

        switch (old, new) {
        case (.intervention, .intervention(_, let violation)):
            if case .intervention(_, let previous) = old, previous.id != violation.id {
                effects.append(.showIntervention(new.session!, violation))
            }
        case (.intervention, _):
            effects.append(.dismissIntervention)
        case (_, .intervention(let session, let violation)):
            effects.append(.showIntervention(session, violation))
        default:
            break
        }

        switch (old, new) {
        case (.review, .review(let session, let reason)):
            if case .review(let previous, _) = old, previous.id != session.id {
                effects.append(.showReview(session, reason))
            }
        case (.review, _):
            effects.append(.dismissReview)
        case (_, .review(let session, let reason)):
            effects.append(.showReview(session, reason))
        default:
            break
        }

        switch (old, new) {
        case (.gate(let oldContext), .gate(let newContext)):
            // Also covers the first gate of a launch, where the state starts out gated.
            if oldContext != newContext {
                effects.append(.showShield(newContext))
                effects.append(.setKiosk(true))
            }
        case (.gate, _):
            effects.append(.setKiosk(false))
            effects.append(.hideShield)
        case (_, .gate(let gateContext)):
            effects.append(.showShield(gateContext))
            effects.append(.setKiosk(true))
        default:
            break
        }

        return effects
    }

    // MARK: - Helpers

    private static func showGate(
        trigger: GateTrigger,
        state: inout AppState,
        now: Date,
        context: ReducerContext,
        lastSession: LastSessionPrompt? = nil,
        offerSleep: Bool = false
    ) -> [Effect] {
        state.phase = .gate(GateContext(
            trigger: trigger,
            shownAt: now,
            lastSession: lastSession,
            offerSleep: offerSleep
        ))
        return [.log(LogEvent(
            GateShownPayload(trigger: trigger, lastSessionID: lastSession?.sessionID),
            id: context.newID(),
            timestamp: now
        ))]
    }

    /// Credits time in the app you are in right now. Usage is otherwise only counted on
    /// the way out of an app, so a session spent in a single app would record nothing.
    private static func creditingCurrentApp(
        _ session: Session,
        state: AppState,
        now: Date,
        config: FocusGuardConfig
    ) -> Session {
        guard let app = state.frontmostApp, let since = state.frontmostSince else { return session }
        let dwell = min(now.timeIntervalSince(since), now.timeIntervalSince(session.startedAt))
        guard dwell >= config.appsUsedThreshold else { return session }
        var session = session
        session.noteUsage(of: app, seconds: dwell)
        return session
    }

    private static func endSession(
        _ session: Session,
        outcome: SessionOutcome,
        at endedAt: Date,
        state: inout AppState,
        context: ReducerContext,
        trigger: GateTrigger,
        answered: Bool? = nil
    ) -> [Effect] {
        var session = creditingCurrentApp(session, state: state, now: endedAt, config: .current)
        session.endedAt = endedAt
        session.outcome = outcome

        var effects: [Effect] = [.log(LogEvent(
            endedPayload(for: session, outcome: outcome, endedAt: endedAt),
            id: context.newID(),
            timestamp: endedAt
        ))]

        if !session.appsUsed.isEmpty || !session.domainsVisited.isEmpty {
            effects.append(.log(LogEvent(
                AppsUsedSnapshotPayload(
                    sessionID: session.id,
                    apps: session.appsUsed,
                    domains: session.domainsVisited
                ),
                id: context.newID(),
                timestamp: endedAt
            )))
        }

        if let answered {
            effects.append(.log(LogEvent(
                GateAnsweredPayload(sessionID: session.id, finished: answered),
                id: context.newID(),
                timestamp: endedAt
            )))
        }

        effects.append(.persistSession(nil))

        // Only ask "did you finish?" at the gate when nobody answered it already.
        let prompt = answered == nil
            ? LastSessionPrompt(sessionID: session.id, goal: session.goal, endedAt: endedAt)
            : nil
        effects += showGate(
            trigger: trigger,
            state: &state,
            now: context.now(),
            context: context,
            lastSession: prompt,
            offerSleep: true
        )
        return effects
    }

    private static func finishOverride(
        _ override: OverrideState,
        early: Bool,
        state: inout AppState,
        now: Date,
        context: ReducerContext
    ) -> [Effect] {
        var effects: [Effect] = [.log(LogEvent(
            OverrideEndedPayload(startedAt: override.startedAt, early: early),
            id: context.newID(),
            timestamp: now
        ))]

        if let session = override.suspendedSession, !session.hasExpired(at: now) {
            state.phase = .session(session)
            state.statusMessage = "Override ended. Back in: \(session.goal)"
        } else {
            state.statusMessage = nil
            effects += showGate(trigger: .overrideExpired, state: &state, now: now, context: context)
        }
        return effects
    }

    private static func makeSession(
        _ request: SessionRequest,
        state: AppState,
        now: Date,
        context: ReducerContext,
        config: FocusGuardConfig
    ) -> Session {
        var allowed = request.allowedBundleIDs
        if !allowed.contains(request.anchor.bundleID) { allowed.insert(request.anchor.bundleID, at: 0) }

        let plannedEnd: Date
        switch request.kind {
        case .full:
            let duration = request.duration ?? config.fullSessionQuickPicks[1]
            plannedEnd = now.addingTimeInterval(min(duration, state.settings.maxFullSessionLength))
        case .open:
            plannedEnd = now.addingTimeInterval(config.openSessionLength)
        }

        var session = Session(
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
        session.convertedFrom = request.convertedFrom
        return session
    }

    /// Strips pinned pages that only worked because they were pinned inside one full
    /// session on a blocked domain (3.5, the rule proposed in the Phase 0 audit).
    static func portableSites(_ sites: [SiteRule], blocklist: Blocklist) -> [SiteRule] {
        sites.filter { rule in
            guard rule.scope == .pinnedPage else { return true }
            guard let host = URL(string: rule.pattern).flatMap(URLNormalizer.host(of:)) else { return true }
            return blocklist.blocks(host: host) == nil
        }
    }

    private static func updatedRecents(
        _ recents: [RecentGoal],
        with session: Session,
        now: Date,
        context: ReducerContext,
        blocklist: Blocklist
    ) -> [RecentGoal] {
        var recents = recents.filter { $0.goal.caseInsensitiveCompare(session.goal) != .orderedSame }
        recents.insert(
            RecentGoal(
                id: context.newID(),
                goal: session.goal,
                allowedBundleIDs: session.allowedBundleIDs,
                allowedSites: portableSites(session.allowedSites, blocklist: blocklist),
                duration: session.plannedEnd.map { $0.timeIntervalSince(session.startedAt) },
                lastUsed: now
            ),
            at: 0
        )
        return Array(recents.prefix(50))
    }

    private static func enterIntervention(
        session: Session,
        kind: ViolationKind,
        app: AppIdentity,
        state: inout AppState,
        now: Date,
        context: ReducerContext
    ) -> [Effect] {
        var session = session
        let violation = Violation(id: context.newID(), timestamp: now, kind: kind, app: app)
        session.record(violation)
        state.phase = .intervention(session, violation)
        state.statusMessage = statusMessage(for: kind)

        return [
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
            .persistSession(session)
        ]
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

    private static func startedPayload(for session: Session) -> SessionStartedPayload {
        SessionStartedPayload(
            sessionID: session.id,
            kind: session.kind,
            goal: session.goal,
            anchorBundleID: session.anchor.bundleID,
            allowedBundleIDs: session.allowedBundleIDs,
            allowedSites: session.allowedSites,
            allowAllNonBlockedSites: session.allowAllNonBlockedSites,
            plannedEnd: session.plannedEnd,
            presetID: session.presetID
        )
    }

    private static func endedPayload(
        for session: Session,
        outcome: SessionOutcome,
        endedAt: Date
    ) -> SessionEndedPayload {
        SessionEndedPayload(
            sessionID: session.id,
            kind: session.kind,
            goal: session.goal,
            outcome: outcome,
            startedAt: session.startedAt,
            endedAt: endedAt,
            plannedEnd: session.plannedEnd,
            violationCount: session.violations.count,
            additionCount: session.additions.count
        )
    }

    private static func rebuild(_ phase: AppPhase, with session: Session) -> AppPhase {
        switch phase {
        case .session: return .session(session)
        case .intervention(_, let violation): return .intervention(session, violation)
        case .review(_, let reason): return .review(session, reason)
        case .gate, .overridden, .safeMode: return phase
        }
    }

    static func failClosedThreshold(for browser: AppIdentity, config: FocusGuardConfig) -> Int {
        let known = KnownBrowser(bundleID: browser.bundleID)
        return known?.readsURLViaAccessibility == true
            ? config.urlFailClosedPollsAccessibility
            : config.urlFailClosedPolls
    }

    private static func isIntervention(_ phase: AppPhase) -> Bool {
        if case .intervention = phase { return true }
        return false
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
