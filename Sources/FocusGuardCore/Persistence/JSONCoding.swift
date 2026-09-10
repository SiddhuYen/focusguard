import Foundation

/// One encoder/decoder pair for everything on disk. ISO-8601 *with fractional seconds*:
/// plain .iso8601 truncates to whole seconds, which loses timestamp fidelity on every
/// round-trip and makes persisted state compare unequal to what was written.
enum JSONCoding {
    static let style = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    static let wholeSecondStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: false)

    static func string(from date: Date) -> String {
        date.formatted(style)
    }

    static func date(from string: String) -> Date? {
        (try? style.parse(string)) ?? (try? wholeSecondStyle.parse(string))
    }

    static func encoder(pretty: Bool = false) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty
            ? [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
            : [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(string(from: date))
        }
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            guard let parsed = date(from: raw) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Bad date: \(raw)")
            }
            return parsed
        }
        return decoder
    }
}
