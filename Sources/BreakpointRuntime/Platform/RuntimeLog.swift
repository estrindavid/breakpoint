import Foundation
import BreakpointCore

// The coordinator's log. On Apple platforms it is os.Logger (subsystem
// com.breakpointapp.Breakpoint, category "app"), unchanged. Elsewhere a logger with the same
// call spelling, `log.info("… \(value, privacy: .public)")`, writes one line per message to the
// debugger (OutputDebugString on Windows) and to standard error.

#if canImport(os)
import os

let log = Logger(subsystem: BreakpointVersion.bundleIdentifier, category: "app")
#else

let log = RuntimeLogger(category: "app")

/// os.Logger's privacy marks; here every value is written as is (the log stays on the device
/// and never holds keystrokes, prompts or names: the callers only log errors and states).
public enum LogPrivacy: Sendable {
    case `public`, `private`, auto
}

public struct LogMessage: ExpressibleByStringInterpolation, ExpressibleByStringLiteral {
    public struct StringInterpolation: StringInterpolationProtocol {
        var text = ""
        public init(literalCapacity: Int, interpolationCount: Int) { text.reserveCapacity(literalCapacity) }
        public mutating func appendLiteral(_ literal: String) { text += literal }
        public mutating func appendInterpolation<T>(_ value: T, privacy: LogPrivacy = .auto) { text += "\(value)" }
    }

    let text: String
    public init(stringLiteral value: String) { text = value }
    public init(stringInterpolation: StringInterpolation) { text = stringInterpolation.text }
}

public struct RuntimeLogger: Sendable {
    let category: String

    public func debug(_ message: LogMessage) { write("debug", message) }
    public func info(_ message: LogMessage) { write("info", message) }
    public func notice(_ message: LogMessage) { write("notice", message) }
    public func error(_ message: LogMessage) { write("error", message) }
    public func fault(_ message: LogMessage) { write("fault", message) }

    private func write(_ level: String, _ message: LogMessage) {
        let line = "[Breakpoint \(category) \(level)] \(message.text)\n"
        PlatformLogSink.write(line)
    }
}
#endif

/// Where the portable logger's lines go; the Windows app also sends them to the debugger.
public enum PlatformLogSink {
    nonisolated(unsafe) public static var extra: ((String) -> Void)?

    static func write(_ line: String) {
        FileHandle.standardError.write(Data(line.utf8))
        extra?(line)
    }
}
