import Foundation

/// `breakpoint status --line`: the app's state as one short line for a shell prompt, tmux or a
/// coding agent's status bar (SPEC §5.8). Two parts joined by " · ", in the menu bar's words:
///
/// - The break (always there while the app runs): "stretch 1:20 left" on a break, the nudge's
///   own title ("2-min stretch?"), the pause sentence ("paused until 15:30"), "stretch due", or
///   "eye rest in 12 min".
/// - The agents (only while one works or needs you): "Claude working 3 min", "Claude needs you";
///   several are counted, needs you first so a bar that cuts the end keeps it: "1 needs you ·
///   2 working".
///
/// Every time is measured against the report's `generatedAt` (the app's clock), so the line
/// agrees with the menu bar.
public enum StatusLine {
    public static let separator = " · "

    /// What each part is painted with: the app's own colours (`Theme.Palette`).
    public enum Tone: Equatable, Sendable {
        case plain
        /// A break on screen, offered or due.
        case mint
        /// An agent working.
        case indigo
        /// An agent needs you.
        case amber
        /// Paused.
        case dim
    }

    public struct Part: Equatable, Sendable {
        public var text: String
        public var tone: Tone
    }

    public static func parts(_ report: StatusReport) -> [Part] {
        [breakPart(report)] + agentParts(report)
    }

    static func breakPart(_ report: StatusReport) -> Part {
        let now = report.generatedAt
        if let active = report.activeBreak {
            let remaining = active.length - max(0, now.timeIntervalSince(active.startedAt))
            return Part(text: "\(active.kind.noun) \(DurationFormat.clock(remaining)) left", tone: .mint)
        }
        if let nudge = report.nudge { return Part(text: nudge.title, tone: .mint) }
        if let paused = report.paused { return Part(text: lowercasedFirst(paused), tone: .dim) }
        let next = report.nextBreak ?? {
            // An app before 0.3 does not send it: the timers against the cadence.
            let eyesIn = report.cadence.eyesEvery - report.timers.screenTime
            let moveIn = report.cadence.moveEvery - report.timers.stillTime
            return StatusReport.NextBreak(kind: moveIn <= eyesIn ? .move : .eyes, seconds: min(eyesIn, moveIn))
        }()
        if next.seconds <= 0 { return Part(text: "\(next.kind.noun) due", tone: .mint) }
        return Part(text: "\(next.kind.noun) in \(DurationFormat.minutes(next.seconds, rounding: .up))", tone: .plain)
    }

    static func agentParts(_ report: StatusReport) -> [Part] {
        let active = report.sessions.filter { $0.state != .idle }
        if active.count == 1, let one = active.first {
            let name = one.source.displayName
            if one.state == .waiting { return [Part(text: Copy.needsYou(agent: name), tone: .amber)] }
            let elapsed = one.runStartedAt.map { report.generatedAt.timeIntervalSince($0) } ?? 0
            let time = elapsed >= 60 ? " " + DurationFormat.minutes(elapsed) : ""
            return [Part(text: "\(name) working\(time)", tone: .indigo)]
        }
        let waiting = active.filter { $0.state == .waiting }.count
        let working = active.count - waiting
        var parts: [Part] = []
        if waiting > 0 { parts.append(Part(text: "\(waiting) \(waiting == 1 ? "needs" : "need") you", tone: .amber)) }
        if working > 0 { parts.append(Part(text: "\(working) working", tone: .indigo)) }
        return parts
    }

    /// The whole line; coloured when `colour` is given (as `TerminalMark` detects it).
    public static func render(_ report: StatusReport, colour: TerminalMark.Colour? = nil) -> String {
        let painted = parts(report).map { paint($0.text, $0.tone, colour) }
        return painted.joined(separator: paint(separator, .dim, colour))
    }

    static func paint(_ text: String, _ tone: Tone, _ colour: TerminalMark.Colour?) -> String {
        guard let colour, let code = code(tone, colour) else { return text }
        return "\u{1B}[\(code)m\(text)\u{1B}[0m"
    }

    static func code(_ tone: Tone, _ colour: TerminalMark.Colour) -> String? {
        let rgb: (Int, Int, Int, palette: Int)
        switch tone {
        case .plain: return nil
        case .dim: return "2"
        case .mint: rgb = (0x3D, 0xD6, 0xB0, 79)
        case .indigo: rgb = (0x6C, 0x7C, 0xFF, 69)
        case .amber: rgb = (0xFF, 0xB4, 0x54, 215)
        }
        switch colour {
        case .trueColour: return "38;2;\(rgb.0);\(rgb.1);\(rgb.2)"
        case .palette256: return "38;5;\(rgb.palette)"
        }
    }

    static func lowercasedFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.lowercased() + text.dropFirst()
    }
}
