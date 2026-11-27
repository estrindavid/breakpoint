import Foundation
#if os(Windows)
import WinSDK

// The handful of POSIX names Core uses that the Windows C runtime lacks. Each behaves as its
// POSIX namesake for the way Core calls it; nothing here is public.

/// File modes have no meaning on NTFS; kept so the installers' signatures are the same.
typealias mode_t = UInt16

/// `memmem`: the first occurrence of `needle` in `haystack`, found with `memchr` and `memcmp`.
func memmem(_ haystack: UnsafeRawPointer?, _ haystackLength: Int,
            _ needle: UnsafeRawPointer?, _ needleLength: Int) -> UnsafeMutableRawPointer? {
    guard let haystack, let needle else { return nil }
    guard needleLength > 0 else { return UnsafeMutableRawPointer(mutating: haystack) }
    guard haystackLength >= needleLength else { return nil }
    let first = Int32(needle.load(as: UInt8.self))
    var start = haystack
    var remaining = haystackLength
    while remaining >= needleLength {
        guard let hit = memchr(start, first, remaining - needleLength + 1) else { return nil }
        if memcmp(hit, needle, needleLength) == 0 { return hit }
        let skipped = UnsafeRawPointer(hit) - start + 1
        start += skipped
        remaining -= skipped
    }
    return nil
}
#endif

enum FileSystemShim {
    /// Removes an empty folder (`rmdir`); false if it is not empty or cannot be removed.
    static func removeEmptyDirectory(_ url: URL) -> Bool {
        #if os(Windows)
        return PathDisplay.native(url).withCString(encodedAs: UTF16.self) { RemoveDirectoryW($0) }
        #else
        return rmdir(url.path) == 0
        #endif
    }
}
