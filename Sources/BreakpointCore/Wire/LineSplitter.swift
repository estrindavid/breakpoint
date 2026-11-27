import Foundation

/// Splits a connection's byte stream into wire lines (SPEC §6), the same way on every platform:
/// lines end at `\n`; a line longer than `WireMessage.maxLineBytes` is dropped up to its newline;
/// blank lines (spaces, tabs, `\r`) are skipped; a final line without a newline counts when the
/// peer closes.
struct LineSplitter {
    private var buffer = Data()
    private var discarding = false

    /// Feeds bytes; returns the complete lines they finish, in order.
    mutating func consume(_ bytes: UnsafeRawBufferPointer) -> [Data] {
        var lines: [Data] = []
        var start = bytes.startIndex
        while let newline = bytes[start...].firstIndex(of: 0x0A) {
            let piece = bytes[start..<newline]
            if discarding {
                discarding = false
                buffer.removeAll()
            } else {
                buffer.append(contentsOf: piece)
                let line = buffer
                buffer = Data()
                if line.count <= WireMessage.maxLineBytes, !line.allSatisfy({ $0 == 0x20 || $0 == 0x0D || $0 == 0x09 }) {
                    lines.append(line)
                }
            }
            start = newline + 1
        }
        guard !discarding else { return lines }
        buffer.append(contentsOf: bytes[start...])
        if buffer.count > WireMessage.maxLineBytes {
            // Oversized: drop everything up to the next newline.
            buffer = Data()
            discarding = true
        }
        return lines
    }

    /// The peer closed: the unterminated last line, if there is a usable one.
    mutating func finish() -> Data? {
        defer { buffer = Data() }
        guard !discarding, !buffer.isEmpty, buffer.count <= WireMessage.maxLineBytes else { return nil }
        return buffer
    }
}
