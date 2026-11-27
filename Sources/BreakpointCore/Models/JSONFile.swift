import Foundation

/// Reads and writes one Codable value as a pretty-printed JSON file, atomically.
///
/// Used by `SettingsStore` and the run-length estimator's `sessions.json`. Writing creates the
/// parent directory (mode 0700) and replaces the file via a temporary file in the same directory,
/// so a crash never leaves a half-written file.
public struct JSONFile<Value: Codable>: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    public var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    /// The decoded value, `nil` if the file does not exist. Throws if it exists but cannot be read
    /// or decoded.
    public func read() throws -> Value? {
        guard exists else { return nil }
        let data = try SafeFile.read(url)
        return try JSONFile.decoder.decode(Value.self, from: data)
    }

    /// Writes `value` atomically (mode 0600).
    public func write(_ value: Value) throws {
        let data = try JSONFile.encoder.encode(value)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try SafeFile.writeAtomically(data, to: url)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Dates as ISO 8601 with fractional seconds for readable files.
    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(ISO8601.string(from: date))
        }
        return encoder
    }

    public static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            if let seconds = try? c.decode(Double.self) { return Date(timeIntervalSince1970: seconds) }
            let string = try c.decode(String.self)
            guard let date = ISO8601.date(from: string) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "Bad date \(string)")
            }
            return date
        }
        return decoder
    }
}

/// ISO 8601 with fractional seconds, UTC. Shared by every file format on disk.
///
/// The formatters are made once: creating one costs far more than using it, and reading a long
/// history decodes thousands of dates. `ISO8601DateFormatter` is thread-safe.
public enum ISO8601 {
    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let whole: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    public static func string(from date: Date) -> String {
        fractional.string(from: date)
    }

    public static func date(from string: String) -> Date? {
        fractional.date(from: string) ?? whole.date(from: string)
    }
}
