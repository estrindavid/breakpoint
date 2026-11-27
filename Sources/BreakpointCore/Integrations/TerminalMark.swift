import Foundation

/// The mark in Unicode block characters, for `breakpoint --version` in a terminal (SPEC §5.8).
///
/// Piped or redirected, `--version` prints exactly `breakpoint <version>` (one line, nothing else),
/// so scripts can keep reading it. In a terminal it prints the mark beside the version, in mint when
/// the terminal takes colour; `NO_COLOR` (any non-empty value) and `TERM=dumb` turn colour off.
public enum TerminalMark {
    /// The solid tag with its two eyes knocked out (2 × 3 pixels each, set a little high), 16 × 8
    /// pixels as half blocks (four lines).
    public static let art = [
        "▄███████████▄   ",
        "███  ██  █████▄ ",
        "███▄▄██▄▄█████▀ ",
        "▀███████████▀   ",
    ]

    public enum Colour: Equatable, Sendable {
        /// 24-bit: mint #3DD6B0 exactly.
        case trueColour
        /// 256 colours: 79 (#5FD7AF), the nearest to mint.
        case palette256
    }

    /// The colour a terminal takes, or `nil` for plain text.
    public static func colour(isTerminal: Bool, environment: [String: String]) -> Colour? {
        guard isTerminal else { return nil }
        if let noColor = environment["NO_COLOR"], !noColor.isEmpty { return nil }
        let term = environment["TERM"] ?? ""
        if term.isEmpty || term == "dumb" { return nil }
        let colorTerm = (environment["COLORTERM"] ?? "").lowercased()
        return colorTerm == "truecolor" || colorTerm == "24bit" ? .trueColour : .palette256
    }

    /// What `breakpoint --version` prints (with the final newline).
    public static func versionOutput(version: String, isTerminal: Bool, environment: [String: String]) -> String {
        let plain = "breakpoint \(version)"
        guard isTerminal else { return plain + "\n" }
        let colour = colour(isTerminal: isTerminal, environment: environment)
        let mint: String
        switch colour {
        case .trueColour: mint = "\u{1B}[38;2;61;214;176m"
        case .palette256: mint = "\u{1B}[38;5;79m"
        case nil: mint = ""
        }
        let reset = colour == nil ? "" : "\u{1B}[0m"
        let dim = colour == nil ? "" : "\u{1B}[2m"
        let beside = ["", plain, "\(dim)Break reminders that wait for your agent.\(reset)", ""]
        return zip(art, beside)
            .map { mark, text in
                "  \(mint)\(mark)\(reset)  \(text)".replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
            }
            .joined(separator: "\n") + "\n"
    }
}
