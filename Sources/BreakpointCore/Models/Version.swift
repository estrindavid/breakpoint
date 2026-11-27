import Foundation

/// The single source of the version number. `scripts/build-app.sh` reads `current` from this file
/// for `CFBundleShortVersionString`; the CLI prints it for `--version`; `CLIInstaller` compares it to
/// decide whether `~/.breakpoint/bin/breakpoint` needs refreshing.
public enum BreakpointVersion {
    public static let current = "0.3.1"
    public static let bundleIdentifier = "com.breakpointapp.Breakpoint"
}
