import Foundation
import BreakpointCore
import BreakpointRuntime

// `UpdateFetching` is declared in BreakpointRuntime (Platform/PlatformServices.swift).

/// One HTTPS GET of `UpdateFeed.url` a day, and the archive when the person installs an update:
/// - an ephemeral session: no cookies, no cache, no credentials, nothing stored on disk;
/// - headers: `User-Agent: Breakpoint/<version>`, `Accept: application/json` and a fixed
///   `Accept-Language: en` (no identifiers, no settings, no history, no system profile, no locale);
/// - GitHub answers with a redirect to the file on its download host, which the session follows;
/// - at most `UpdateFeed.maximumSize` bytes are received (a larger answer is cancelled while it
///   arrives), and only an HTTP 200 is accepted;
/// - the archive (an Update click, or automatic installs) comes from a page inside the repository,
///   is at most `UpdateFeed.maximumArchiveSize`, and is not quarantined (this app does not set
///   `LSFileQuarantineEnabled`); it is checked against its signature before anything uses it.
@MainActor
public final class UpdateFetcher: UpdateFetching {
    public enum FetchError: Error, Equatable {
        case status(Int)
        case tooLarge
    }

    private let url: URL
    private let session: URLSession

    public init(url: URL = UpdateFeed.url) {
        self.url = url
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = Timing.updateRequestTimeout
        configuration.timeoutIntervalForResource = Timing.updateDownloadTimeout
        configuration.waitsForConnectivity = false
        // A fixed Accept-Language: otherwise URLSession sends the person's preferred languages and region.
        configuration.httpAdditionalHeaders = ["User-Agent": "Breakpoint/\(BreakpointVersion.current)",
                                               "Accept": "application/json", "Accept-Language": "en"]
        session = URLSession(configuration: configuration)
    }

    /// Cancels `task` as soon as the response says, or the bytes received show, that it is larger
    /// than `limit`, so an oversized answer is never received whole (in memory or on disk).
    final class SizeLimit: @unchecked Sendable {
        private var observation: NSKeyValueObservation?
        private let lock = NSLock()
        private var _exceeded = false
        var exceeded: Bool { lock.withLock { _exceeded } }

        func watch(_ task: URLSessionTask, limit: Int) {
            let limit = Int64(limit)
            observation = task.observe(\.countOfBytesReceived) { [weak self] task, _ in
                guard task.countOfBytesReceived > limit || task.countOfBytesExpectedToReceive > limit else { return }
                guard let self else { return }
                self.lock.withLock { self._exceeded = true }
                task.cancel()
            }
        }

        func stop() { observation?.invalidate() }
    }

    public func fetch(_ completion: @escaping @MainActor (Result<Data, Error>) -> Void) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let limit = SizeLimit()
        let task = session.dataTask(with: request) { data, response, error in
            limit.stop()
            let result: Result<Data, Error>
            if limit.exceeded {
                result = .failure(FetchError.tooLarge)
            } else if let error {
                result = .failure(error)
            } else if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                result = .failure(FetchError.status(http.statusCode))
            } else if let data, data.count <= UpdateFeed.maximumSize {
                result = .success(data)
            } else {
                result = .failure(FetchError.tooLarge)
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(result) } }
        }
        limit.watch(task, limit: UpdateFeed.maximumSize)
        task.resume()
    }

    public func download(_ url: URL, into folder: URL, _ completion: @escaping @MainActor (Result<URL, Error>) -> Void) {
        guard UpdateFeed.isTrusted(url) else {
            completion(.failure(UpdateInstallError.download("an address outside the repository")))
            return
        }
        let request = URLRequest(url: url)
        let destination = folder.appendingPathComponent(url.lastPathComponent.isEmpty ? "update.zip" : url.lastPathComponent)
        let limit = SizeLimit()
        let task = session.downloadTask(with: request) { location, response, error in
            limit.stop()
            let result: Result<URL, Error>
            if limit.exceeded {
                result = .failure(FetchError.tooLarge)
            } else if let error {
                result = .failure(error)
            } else if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                result = .failure(FetchError.status(http.statusCode))
            } else if let location {
                // The temporary file is removed when this handler returns: move it first.
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                            attributes: [.posixPermissions: 0o700])
                    try? FileManager.default.removeItem(at: destination)
                    try FileManager.default.moveItem(at: location, to: destination)
                    let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.intValue ?? 0
                    result = size <= UpdateFeed.maximumArchiveSize ? .success(destination) : .failure(FetchError.tooLarge)
                } catch {
                    result = .failure(error)
                }
            } else {
                result = .failure(FetchError.status(0))
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(result) } }
        }
        limit.watch(task, limit: UpdateFeed.maximumArchiveSize)
        task.resume()
    }
}
