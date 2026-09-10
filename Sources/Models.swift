import AppKit
import Foundation

struct RunningApp: Identifiable, Equatable {
    var id: String { "\(bundleIdentifier)-\(processIdentifier)" }

    let name: String
    let bundleIdentifier: String
    let processIdentifier: pid_t
    let icon: NSImage?

    init?(runningApplication: NSRunningApplication) {
        guard let bundleIdentifier = runningApplication.bundleIdentifier else {
            return nil
        }

        self.name = runningApplication.localizedName ?? bundleIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.processIdentifier = runningApplication.processIdentifier
        self.icon = runningApplication.icon
    }
}

struct FocusSession: Codable, Identifiable, Equatable {
    let id: UUID
    let allowedAppName: String
    let allowedBundleID: String
    let allowedProcessIdentifier: Int32
    let allowedBundleIDsMulti: [String]?
    let goal: String
    let startedAt: Date
    var endedAt: Date?
    var violations: [FocusViolation]
    var escapes: [FocusEscape]

    init(app: RunningApp, goal: String, startedAt: Date = Date()) {
        self.id = UUID()
        self.allowedAppName = app.name
        self.allowedBundleID = app.bundleIdentifier
        self.allowedProcessIdentifier = app.processIdentifier
        self.allowedBundleIDsMulti = nil
        self.goal = goal
        self.startedAt = startedAt
        self.violations = []
        self.escapes = []
    }

    init(anchorApp: RunningApp, allowedBundleIDsMulti: [String], goal: String, startedAt: Date = Date()) {
        self.id = UUID()
        self.allowedAppName = anchorApp.name
        self.allowedBundleID = anchorApp.bundleIdentifier
        self.allowedProcessIdentifier = anchorApp.processIdentifier
        self.goal = goal
        self.startedAt = startedAt
        self.violations = []
        self.escapes = []
        self.allowedBundleIDsMulti = allowedBundleIDsMulti
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(UUID.self, forKey: .id)
        allowedAppName = try container.decode(String.self, forKey: .allowedAppName)
        allowedBundleID = try container.decode(String.self, forKey: .allowedBundleID)
        allowedProcessIdentifier = try container.decode(Int32.self, forKey: .allowedProcessIdentifier)
        allowedBundleIDsMulti = try container.decodeIfPresent([String].self, forKey: .allowedBundleIDsMulti)
        goal = try container.decodeIfPresent(String.self, forKey: .goal) ?? "Stay focused on \(allowedAppName)"
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        endedAt = try container.decodeIfPresent(Date.self, forKey: .endedAt)
        violations = try container.decode([FocusViolation].self, forKey: .violations)
        escapes = try container.decode([FocusEscape].self, forKey: .escapes)
    }

    var elapsed: TimeInterval {
        (endedAt ?? Date()).timeIntervalSince(startedAt)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case allowedAppName
        case allowedBundleID
        case allowedProcessIdentifier
        case allowedBundleIDsMulti
        case goal
        case startedAt
        case endedAt
        case violations
        case escapes
    }
}

struct FocusViolation: Codable, Identifiable, Equatable {
    let id: UUID
    let timestamp: Date
    let attemptedAppName: String
    let attemptedBundleID: String

    init(app: RunningApp, timestamp: Date = Date()) {
        self.id = UUID()
        self.timestamp = timestamp
        self.attemptedAppName = app.name
        self.attemptedBundleID = app.bundleIdentifier
    }
}

struct FocusEscape: Codable, Identifiable, Equatable {
    let id: UUID
    let startedAt: Date
    let duration: TimeInterval
    let reason: String?

    init(startedAt: Date = Date(), duration: TimeInterval, reason: String? = nil) {
        self.id = UUID()
        self.startedAt = startedAt
        self.duration = duration
        self.reason = reason
    }
}

struct FocusRules: Codable, Equatable {
    var allowSystemApps: Bool = true
    var allowFinder: Bool = false
    var gracePeriodSeconds: Int = 3
    var escapeLimit: Int?
    var requireReason: Bool = false
    var returnAutomatically: Bool = false

    var allowedBundleIDs: Set<String> {
        var bundleIDs: Set<String> = [
            Bundle.main.bundleIdentifier ?? "FocusGuard"
        ]

        if allowSystemApps {
            bundleIDs.formUnion([
                "com.apple.systempreferences",
                "com.apple.SystemSettings",
                "com.apple.controlcenter",
                "com.apple.notificationcenterui"
            ])
        }

        if allowFinder {
            bundleIDs.insert("com.apple.finder")
        }

        return bundleIDs
    }
}

struct UserSettings: Codable, Equatable {
    var gracePeriodSeconds: Int = 3
    var requireReasonToLeave: Bool = false
    var allowTemporaryEscapes: Bool = true
    var defaultEscapeDuration: TimeInterval = 60
    var launchAtLogin: Bool = false
}

enum FocusState: Equatable {
    case idle
    case focusing(FocusSession)
    case gracePeriod(FocusSession, until: Date)
    case intervention(FocusSession, violation: FocusViolation)
    case paused(FocusSession)

    var activeSession: FocusSession? {
        switch self {
        case .idle:
            return nil
        case .focusing(let session),
             .gracePeriod(let session, _),
             .intervention(let session, _),
             .paused(let session):
            return session
        }
    }
}

enum StopReason: String {
    case user
    case quit
}
