import Foundation

enum EventType: String, Codable, Equatable, Sendable, CaseIterable {
    case appLaunched
    case appTerminating
    case gateShown
    case gateAnswered
    case sessionStarted
    case sessionExtended
    case sessionConverted
    case sessionEnded
    case appsUsedSnapshot
    case violation
    case additionToSession
    case overrideStarted
    case overrideEnded
    case safeModeEntered
    case hangDetected
    case heartbeatGap
    case buildChanged
    case permissionLost
    case permissionRestored
    case urlReadHealth
    case activitySample
    case quitBlocked
    case testingExit
    case settingsChangeScheduled
    case settingsChangeCancelled
    case settingsChangeApplied
    case presetCreated
    case presetSuggested
    case sleepRequested
    case sessionImported
}

protocol EventPayload: Codable, Equatable, Sendable {
    static var eventType: EventType { get }
}

/// One line of the append-only log: `{ "id", "timestamp", "type", "payload" }`.
struct LogEvent: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let timestamp: Date
    let type: EventType
    let payload: JSONValue

    init(id: UUID = UUID(), timestamp: Date = Date(), type: EventType, payload: JSONValue = .object([:])) {
        self.id = id
        self.timestamp = timestamp
        self.type = type
        self.payload = payload
    }

    init<P: EventPayload>(_ payload: P, id: UUID = UUID(), timestamp: Date = Date()) {
        self.id = id
        self.timestamp = timestamp
        self.type = P.eventType
        self.payload = (try? JSONValue.encode(payload)) ?? .object([:])
    }

    func decode<P: EventPayload>(_ type: P.Type = P.self) -> P? {
        guard self.type == P.eventType else { return nil }
        return try? JSONValue.decode(P.self, from: payload)
    }
}

extension JSONValue {
    static func encode<T: Encodable>(_ value: T) throws -> JSONValue {
        let data = try JSONCoding.encoder().encode(value)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    static func decode<T: Decodable>(_ type: T.Type, from value: JSONValue) throws -> T {
        let data = try JSONEncoder().encode(value)
        return try JSONCoding.decoder().decode(T.self, from: data)
    }
}
