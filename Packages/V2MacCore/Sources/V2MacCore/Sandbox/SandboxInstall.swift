import CryptoKit
import Foundation

/// One sandbox release, as its signed `pin.json` describes it (sandbox plan: "Versions"). Once its signature
/// holds, the release's manifest and, before every launch, the helper's executable must match it.
public struct SandboxPin: Codable, Sendable, Equatable {
    /// The release's `files.json` (`BundleManifest`).
    public var url: URL
    /// SHA-256 of the manifest, lowercase hex.
    public var sha256: String
    /// SHA-256 of `V2Mac Sandbox.app/Contents/MacOS/V2Mac Sandbox`.
    public var executableSHA256: String
    /// What a first install downloads: every file's zip.
    public var size: Int64
    /// The release's version, shown when it updates an installed sandbox.
    public var version: String?
    /// The `SandboxLink.version` it speaks: a V2Mac runs only a sandbox with its own.
    public var link: Int?

    /// Where each V2Mac looks for the newest release, with `<url>.sig` beside it.
    public static let latestURL = URL(string: "https://github.com/v2macapp/v2mac-sandbox/releases/latest/download/pin.json")!

    public init(url: URL, sha256: String, executableSHA256: String, size: Int64, version: String? = nil, link: Int? = nil) {
        self.url = url
        self.sha256 = sha256
        self.executableSHA256 = executableSHA256
        self.size = size
        self.version = version
        self.link = link
    }
}

/// A `pin.json` with its signature by the project's update key; the signature is why it can be trusted,
/// whether it just came from the network or from the sandbox folder.
public struct SignedSandboxPin: Sendable, Equatable {
    public let pin: SandboxPin
    let data: Data
    let signature: Data

    public init(data: Data, signature: Data, key: Curve25519.Signing.PublicKey = AppInstaller.updateKey) throws {
        guard AppInstaller.isSigned(data, signature: signature, by: key) else { throw SandboxInstallError.checksumMismatch }
        pin = try JSONDecoder().decode(SandboxPin.self, from: data)
        self.data = data
        self.signature = signature
    }
}

/// What this V2Mac can do with the installed and the newest sandbox. `SandboxLink.version` is the only thing
/// they must share; apart from that each updates on its own.
public struct SandboxCompatibility: Sendable, Equatable {
    /// The installed sandbox speaks this V2Mac's link.
    public let canOpen: Bool
    /// The newest release runs on this V2Mac and is newer than what is installed (never a step back).
    public let offersUpdate: Bool
    /// The newest release needs a newer V2Mac.
    public let needsNewerApp: Bool
    /// This V2Mac is ahead of every published sandbox.
    public let needsNewerSandbox: Bool

    public init(installed: SandboxPin?, latest: SandboxPin?, link: Int) {
        canOpen = installed?.link == link
        offersUpdate = latest?.link == link && (installed == nil || Self.isNewer(latest?.version, than: installed?.version))
        needsNewerApp = (latest?.link ?? 0) > link
        needsNewerSandbox = latest.map { ($0.link ?? 0) < link } ?? false
    }

    static func isNewer(_ a: String?, than b: String?) -> Bool {
        guard let a else { return false }
        guard let b else { return true }
        return a.compare(b, options: .numeric) == .orderedDescending
    }
}

public enum SandboxInstallError: Error, Sendable, Equatable, LocalizedError {
    case checksumMismatch
    case unpackFailed
    case helperChanged

    public var errorDescription: String? {
        switch self {
        case .checksumMismatch: String(localized: "The downloaded sandbox does not match the one this V2Mac expects.")
        case .unpackFailed: String(localized: "The downloaded sandbox could not be unpacked.")
        case .helperChanged: String(localized: "The sandbox helper on disk was changed. Remove the sandbox and download it again.")
        }
    }
}

/// Layout of `<data>/sandbox/` and the steps that fill it.
public struct SandboxFiles: Sendable {
    public var root: URL
    public init(root: URL) { self.root = root }

    public static let appName = "V2Mac Sandbox.app"
    public var app: URL { root.appendingPathComponent(Self.appName, isDirectory: true) }
    public var executable: URL { app.appendingPathComponent("Contents/MacOS/V2Mac Sandbox") }
    /// Partial and finished downloads, named by their SHA-256, kept between attempts for resuming.
    public var downloads: URL { root.appendingPathComponent("download", isDirectory: true) }
    public var isInstalled: Bool { FileManager.default.isExecutableFile(atPath: executable.path) }
    private var storedPin: URL { root.appendingPathComponent("pin.json") }
    private var storedSignature: URL { root.appendingPathComponent("pin.json.sig") }

    /// The newest release's signed `pin.json`.
    public func fetchLatest(download: ResumableDownload, from url: URL = SandboxPin.latestURL,
                            key: Curve25519.Signing.PublicKey = AppInstaller.updateKey) async throws -> SignedSandboxPin {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        func fetch(_ url: URL) async throws -> Data {
            let file = root.appendingPathComponent("latest-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: file) }
            try await download.fetch(url, to: file, expectedSize: 1 << 16)
            return try Data(contentsOf: file)
        }
        return try await SignedSandboxPin(data: fetch(url), signature: fetch(URL(string: url.absoluteString + ".sig")!), key: key)
    }

    /// Records the release just installed; `installedPin` checks its signature each time it is read.
    public func remember(_ signed: SignedSandboxPin) throws {
        try signed.data.write(to: storedPin, options: .atomic)
        try signed.signature.write(to: storedSignature, options: .atomic)
    }

    /// The installed release, nil when it was never recorded (installed before updates were signed) or its record
    /// fails its signature; the app then treats the sandbox as needing an update.
    public func installedPin(key: Curve25519.Signing.PublicKey = AppInstaller.updateKey) -> SandboxPin? {
        guard let data = try? Data(contentsOf: storedPin), let signature = try? Data(contentsOf: storedSignature) else { return nil }
        return (try? SignedSandboxPin(data: data, signature: signature, key: key))?.pin
    }

    /// Fetches the release's manifest.
    func manifest(_ pin: SandboxPin, download: ResumableDownload) async throws -> BundleManifest {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("files.json")
        try? fm.removeItem(at: file) // a leftover would be resumed, not replaced
        defer { try? fm.removeItem(at: file) }
        try await download.fetch(pin.url, to: file, expectedSize: Int64(BundleManifest.maxSize))
        guard try Self.sha256(of: file) == pin.sha256 else { throw SandboxInstallError.checksumMismatch }
        return try BundleManifest(data: Data(contentsOf: file))
    }

    /// Fetches the release's manifest and plans every file against the installed bundle.
    public func plan(_ pin: SandboxPin, download: ResumableDownload) async throws -> [(file: BundleManifest.File, step: BundleManifest.Step)] {
        let manifest = try await manifest(pin, download: download)
        return manifest.plan(installed: manifest.current(in: app).mapValues(\.sha256))
    }

    /// Builds the release in `staging/` file by file (`BundleManifest.build`), checks it and puts it
    /// in place of the installed helper, which stays until every check has passed.
    public func install(_ pin: SandboxPin, download: ResumableDownload,
                        onProgress: (@Sendable (DownloadProgress) -> Void)? = nil) async throws {
        let fm = FileManager.default
        let manifest = try await manifest(pin, download: download)
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        try? fm.removeItem(at: staging)
        defer { try? fm.removeItem(at: staging) }
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        let staged = SandboxFiles(root: staging)
        try await manifest.build(at: staged.app, from: app, release: pin.url, downloads: downloads, download: download, onProgress: onProgress)
        try staged.verify(pin)
        try? fm.removeItem(at: app)
        try fm.moveItem(at: staged.app, to: app)
        try? fm.removeItem(at: downloads)
        try? fm.removeItem(at: root.appendingPathComponent("download.part")) // from the whole-zip releases
    }

    /// Run before every launch: the executable on disk must still be the release's.
    public func verify(_ pin: SandboxPin) throws {
        guard (try? Self.sha256(of: executable)) == pin.executableSHA256 else { throw SandboxInstallError.helperChanged }
    }

    public static func sha256(of file: URL) throws -> String { try BundleManifest.sha256(of: file) }

    /// Default RAM cap (sandbox plan: "Resources"): a quarter of the Mac's memory, 2–8 GB.
    public static func defaultRAMCapMB(physicalMemory: UInt64) -> Int {
        min(max(Int(physicalMemory >> 20) / 4, 2048), 8192)
    }
}

/// Downloads a large file into `destination`, continuing a partial file with a `Range` request.
/// Each route is tried in order (spec 11); the partial file survives a failure for the next attempt.
public struct ResumableDownload: Sendable {
    public var routes: [FetchRoute]
    public var timeout: TimeInterval

    public init(routes: [FetchRoute], timeout: TimeInterval = 60) {
        self.routes = routes.isEmpty ? [.direct] : routes
        self.timeout = timeout
    }

    public func fetch(_ url: URL, to destination: URL, expectedSize: Int64,
                      onProgress: (@Sendable (DownloadProgress) -> Void)? = nil) async throws {
        var lastError: Error = DownloadError.network("No route available.")
        for route in routes {
            do {
                return try await fetch(url, to: destination, expectedSize: expectedSize, route: route, onProgress: onProgress)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private func fetch(_ url: URL, to destination: URL, expectedSize: Int64, route: FetchRoute,
                       onProgress: (@Sendable (DownloadProgress) -> Void)?) async throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: destination.path) { fm.createFile(atPath: destination.path, contents: nil) }
        let have = (try? fm.attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? 0
        if have >= expectedSize, expectedSize > 0 { return }
        var request = URLRequest(url: url)
        if have > 0 { request.setValue("bytes=\(have)-", forHTTPHeaderField: "Range") }
        let writer = try Writer(file: destination, have: have, limit: expectedSize, onProgress: onProgress)
        let session = SessionFactory.make(route: route, timeout: timeout, delegate: writer)
        defer { session.finishTasksAndInvalidate() }
        let task = session.dataTask(with: request)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                writer.continuation = continuation
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    /// Delegate callbacks arrive one at a time on the session's serial queue.
    private final class Writer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        let handle: FileHandle
        let limit: Int64
        let onProgress: (@Sendable (DownloadProgress) -> Void)?
        var continuation: CheckedContinuation<Void, Error>?
        private var written: Int64
        private var failure: Error?
        private var lastReport = ContinuousClock.now

        init(file: URL, have: Int64, limit: Int64, onProgress: (@Sendable (DownloadProgress) -> Void)?) throws {
            handle = try FileHandle(forWritingTo: file)
            written = have
            self.limit = limit
            self.onProgress = onProgress
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            guard BoundedFetch.allowsRedirect(from: response.url, to: request.url) else {
                failure = URLError(.appTransportSecurityRequiresSecureConnection)
                task.cancel()
                return completionHandler(nil)
            }
            completionHandler(request)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 206: break
            case 200: // the server ignored the Range: start over
                written = 0
            default:
                failure = DownloadError.http(status)
                return completionHandler(.cancel)
            }
            do {
                try handle.truncate(atOffset: UInt64(written))
                try handle.seekToEnd()
            } catch {
                failure = error
                return completionHandler(.cancel)
            }
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            written += Int64(data.count)
            guard written <= limit else {
                failure = DownloadError.tooLarge
                return dataTask.cancel()
            }
            do { try handle.write(contentsOf: data) } catch {
                failure = error
                return dataTask.cancel()
            }
            if let onProgress, ContinuousClock.now - lastReport >= .milliseconds(100) {
                lastReport = .now
                onProgress(DownloadProgress(received: written, total: limit))
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            try? handle.close()
            guard let continuation else { return }
            self.continuation = nil
            if let error = failure ?? error { return continuation.resume(throwing: error) }
            onProgress?(DownloadProgress(received: written, total: limit))
            continuation.resume()
        }
    }
}
