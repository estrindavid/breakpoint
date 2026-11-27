import BreakpointCore
import BreakpointRuntime
import CBreakpointWin32
import Foundation
import WinSDK

/// The update check's network access on Windows (SPEC §2.11), with WinHTTP: the system's own
/// HTTP stack (TLS from Windows, the system proxy settings), no third-party code.
///
/// The same rules as on macOS: one HTTPS GET of `UpdateFeed.url` (here `update-feed-windows.json`),
/// and the archive only when the person installs; no cookies, no cache, no credentials
/// (`WINHTTP_DISABLE_COOKIES`, `WINHTTP_FLAG_REFRESH`, no auto-logon); headers
/// `User-Agent: Breakpoint/<version>`, `Accept: application/json`, `Accept-Language: en` and nothing
/// else; GitHub's redirect to its download host is followed; at most `UpdateFeed.maximumSize`
/// bytes of feed and `UpdateFeed.maximumArchiveSize` of archive are read (a larger answer is
/// dropped as it arrives); only HTTP 200 counts. The archive is verified against its signature
/// before anything uses it.
@MainActor
public final class WindowsUpdateFetcher: UpdateFetching {
    public enum FetchError: Error, Equatable, CustomStringConvertible {
        case status(Int)
        case tooLarge
        case network(UInt32)

        public var description: String {
            switch self {
            case .status(let code): return "HTTP \(code)"
            case .tooLarge: return "the answer was larger than expected"
            case .network(let code): return "WinHTTP error \(code)"
            }
        }
    }

    private let url: URL

    public init(url: URL = UpdateFeed.url) { self.url = url }

    public func fetch(_ completion: @escaping @MainActor (Result<Data, Error>) -> Void) {
        let url = url
        DispatchQueue.global(qos: .utility).async {
            let result = Self.get(url, limit: UpdateFeed.maximumSize, accept: "application/json")
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(result) } }
        }
    }

    public func download(_ url: URL, into folder: URL, _ completion: @escaping @MainActor (Result<URL, Error>) -> Void) {
        guard UpdateFeed.isTrusted(url) else {
            completion(.failure(UpdateInstallError.download("an address outside the repository")))
            return
        }
        let destination = folder.appendingPathComponent(url.lastPathComponent.isEmpty ? "update.zip" : url.lastPathComponent)
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<URL, Error> = Self.get(url, limit: UpdateFeed.maximumArchiveSize, accept: "*/*").flatMap { data in
                Result {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try? FileManager.default.removeItem(at: destination)
                    try data.write(to: destination)
                    return destination
                }
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(result) } }
        }
    }

    /// A blocking GET (run off the main thread), through `bp_http_get` (WinHTTP).
    nonisolated static func get(_ url: URL, limit: Int, accept: String) -> Result<Data, Error> {
        let agent = "Breakpoint/\(BreakpointVersion.current)"
        let headers = "Accept: \(accept)\r\nAccept-Language: en\r\n"
        var result = url.absoluteString.wide.withUnsafeBufferPointer { address in
            agent.wide.withUnsafeBufferPointer { userAgent in
                headers.wide.withUnsafeBufferPointer { extra in
                    bp_http_get(address.baseAddress, userAgent.baseAddress, extra.baseAddress, limit,
                                Int32(Timing.updateRequestTimeout * 1000), Int32(Timing.updateDownloadTimeout * 1000))
                }
            }
        }
        defer { bp_http_free(&result) }
        if result.tooLarge != 0 { return .failure(FetchError.tooLarge) }
        if result.error != 0 { return .failure(FetchError.network(result.error)) }
        guard result.status == 200 else { return .failure(FetchError.status(Int(result.status))) }
        guard let bytes = result.data else { return .success(Data()) }
        return .success(Data(bytes: bytes, count: result.length))
    }
}
