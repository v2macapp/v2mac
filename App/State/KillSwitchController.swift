import Foundation
import Observation
import V2MacCore

/// Spec 9.8. The block goes up before a connection starts and stays through restarts, crashes
/// and failures; only a disconnect, turning the setting off or quitting lifts it. The root
/// helper holds the rules, so they also outlive an app that stopped unexpectedly. What it shows
/// comes from the helper reading pf back (`KillSwitch.statusFile`), not from the request (F02).
@MainActor @Observable
final class KillSwitchController {
    enum State: Equatable {
        case off
        case arming
        case armed
        /// A block nobody asked for any more: V2Mac stopped while it was up.
        case leftOver
        case failed(String)
    }

    private(set) var state: State = .off
    private let session: TunController
    private let marker: URL
    /// Addresses handed to the helper this session. The list only grows, so a server used or
    /// tested earlier stays reachable.
    @ObservationIgnored private var allowed: Set<String> = []
    /// Bumped by every arm and lift, so a slower earlier one does not set the state.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var watch: Task<Void, Never>?
    /// Spec 9.8: the block covers the local network too. Takes effect at once while it is up.
    var blocksLAN = false {
        didSet {
            session.requestKillSwitchBlocksLAN(blocksLAN)
            if blocksLAN { FileManager.default.createFile(atPath: blockLANFlag.path, contents: nil) }
            else { try? FileManager.default.removeItem(at: blockLANFlag) }
        }
    }

    /// Traffic outside the connection is refused right now.
    var isBlocking: Bool { state == .armed || state == .leftOver }

    init(session: TunController, marker: URL = KillSwitch.marker(name: AppPaths.dataFolderName)) {
        self.session = session
        self.marker = marker
        if FileManager.default.fileExists(atPath: marker.path) { state = .leftOver }
    }

    private var flag: URL { session.stateDirectory.appendingPathComponent(KillSwitch.flag) }
    private var allowFile: URL { session.stateDirectory.appendingPathComponent(KillSwitch.allowFile) }
    private var resolverFile: URL { session.stateDirectory.appendingPathComponent(KillSwitch.resolverFile) }
    private var blockLANFlag: URL { session.stateDirectory.appendingPathComponent(KillSwitch.blockLANFlag) }

    /// What the helper last read back from pf, and when; nil when it wrote nothing.
    private func status() -> (text: String, date: Date)? {
        let url = session.rootDirectory.appendingPathComponent(KillSwitch.statusFile)
        guard let date = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return (text.trimmingCharacters(in: .whitespacesAndNewlines), date)
    }

    /// Puts the block up with `hosts` reachable and port 53 open only to `resolvers`; true once
    /// the helper reads it back from pf. Already up, it only adds the hosts.
    func arm(allowing hosts: [String], resolvers: [String]) async -> Bool {
        generation += 1
        let current = generation
        await add(hosts)
        session.requestResolvers(resolvers)
        try? (resolvers.joined(separator: "\n") + "\n").write(to: resolverFile, atomically: true, encoding: .utf8)
        if state == .armed, session.isSessionAlive, FileManager.default.fileExists(atPath: flag.path) { return true }
        state = .arming
        // A block left from before is replaced; the helper's read-back of the new one is newer than this.
        let start = Date()
        FileManager.default.createFile(atPath: flag.path, contents: nil)
        session.requestKillSwitch(true)
        switch await session.startSession() {
        case .started: break
        case .cancelled: return fail(String(localized: "Administrator access was cancelled."), current)
        case .failed(let message): return fail(message, current)
        }
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline, current == generation {
            if let status = status(), status.date >= start, status.text == "armed" {
                state = .armed
                watchStatus(current)
                return true
            }
            // The helper takes the request back when the rules cannot be loaded.
            if !FileManager.default.fileExists(atPath: flag.path) {
                let file = session.rootDirectory.appendingPathComponent(KillSwitch.errorFile)
                let detail = (try? String(contentsOf: file, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
                return fail(detail.flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "The firewall rules could not be loaded."), current)
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return current == generation ? fail(String(localized: "The firewall did not answer."), current) : false
    }

    /// Lets the core reach these servers while the block is up, for tests and new servers.
    func allow(_ hosts: [String]) async {
        // Also while `.failed` from the watch: the request stands and the helper re-arms.
        guard FileManager.default.fileExists(atPath: flag.path) else { return }
        await add(hosts)
    }

    /// Lifts the block. A helper is needed for that: when the one that put it up is gone, a new
    /// one is started without the request, and it takes the rules away.
    func lift() async {
        generation += 1
        let current = generation
        watch?.cancel()
        try? FileManager.default.removeItem(at: flag)
        try? FileManager.default.removeItem(at: allowFile)
        try? FileManager.default.removeItem(at: resolverFile)
        allowed = []
        session.requestKillSwitch(false)
        session.requestAllowedAddresses([])
        session.requestResolvers([])
        guard FileManager.default.fileExists(atPath: marker.path) else {
            state = .off
            return
        }
        if !session.isSessionAlive {
            guard case .started = await session.startSession() else {
                if current == generation { state = .leftOver }
                return
            }
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline, FileManager.default.fileExists(atPath: marker.path) {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard current == generation else { return }
        state = FileManager.default.fileExists(atPath: marker.path) ? .leftOver : .off
    }

    private func add(_ hosts: [String]) async {
        let new = Set(await KillSwitch.addresses(of: hosts)).subtracting(allowed)
        guard !new.isEmpty else { return }
        allowed.formUnion(new)
        session.requestAllowedAddresses(allowed.sorted())
        try? (allowed.sorted().joined(separator: "\n") + "\n").write(to: allowFile, atomically: true, encoding: .utf8)
    }

    /// Follows the helper's read-back while the block is up: the helper checks pf every few
    /// seconds and puts the rules back when they were changed, so `.failed` can turn back into `.armed`.
    private func watchStatus(_ current: Int) {
        watch?.cancel()
        watch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, current == self.generation else { return }
                let status = self.status()
                if let status, status.date.timeIntervalSinceNow > -15 {
                    // The helper's English reasons are catalog keys.
                    self.state = status.text == "armed" ? .armed : .failed(String(localized: String.LocalizationValue(status.text)))
                } else {
                    self.state = .failed(String(localized: "The firewall did not answer."))
                }
            }
        }
    }

    private func fail(_ message: String, _ current: Int) -> Bool {
        guard current == generation else { return false }
        watch?.cancel()
        try? FileManager.default.removeItem(at: flag)
        session.requestKillSwitch(false)
        state = .failed(message)
        return false
    }
}
