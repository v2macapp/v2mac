import Foundation
import Observation
import V2MacCore

/// Extra local proxies, one per chosen server, beside the main connection (spec 12.13). Each runs
/// its own core with global routing on its own port, and ends when it is stopped or V2Mac quits.
@MainActor @Observable
final class ProxyServerService {
    struct Proxy: Identifiable {
        /// The server's profile id: a server has at most one proxy.
        let id: UUID
        let name: String
        let port: Int
        let allowLAN: Bool
        var state: CoreState = .starting
        var address: String { "127.0.0.1:\(port)" }
    }

    struct Options {
        var firstPort: Int
        var allowLAN: Bool
        var username: String
        var password: String
    }

    private(set) var proxies: [Proxy] = []
    @ObservationIgnored private var runners: [UUID: CoreRunner] = [:]
    @ObservationIgnored private let logs: LogStore
    /// The network the cores dial out on: the chosen interface, or the physical one in TUN mode.
    @ObservationIgnored var outboundInterface: @MainActor () -> String? = { nil }
    /// Lets the servers through the kill switch before their cores start (spec 9.8).
    @ObservationIgnored var beforeStarting: @MainActor (_ hosts: [String]) async -> Void = { _ in }
    /// The main connection's port, which a proxy must not take.
    @ObservationIgnored var mainPort: @MainActor () -> Int = { Prefs.inbound.port }

    init(logs: LogStore) { self.logs = logs }

    func proxy(for id: UUID) -> Proxy? { proxies.first { $0.id == id } }

    /// The ports `create` would give `count` servers, skipping ports in use.
    func plannedPorts(count: Int, from first: Int, allowLAN: Bool) -> [Int] {
        let host = allowLAN ? "0.0.0.0" : "127.0.0.1"
        let taken = Set(proxies.map(\.port)).union([mainPort(), Prefs.inbound.port])
        var ports: [Int] = []
        var port = max(first, 1024)
        while ports.count < count, port <= 65535 {
            if !taken.contains(port), PortUtil.isFree(port: port, host: host) { ports.append(port) }
            port += 1
        }
        return ports
    }

    /// Starts a proxy for each server that has none yet, on consecutive free ports from `firstPort`.
    func create(_ servers: [ActiveServer], options: Options) {
        let servers = servers.filter { proxy(for: $0.id) == nil }
        let ports = plannedPorts(count: servers.count, from: options.firstPort, allowLAN: options.allowLAN)
        for (server, port) in zip(servers, ports) {
            proxies.append(Proxy(id: server.id, name: server.name, port: port, allowLAN: options.allowLAN))
            Task { await start(server, port: port, options: options) }
        }
    }

    private func start(_ server: ActiveServer, port: Int, options: Options) async {
        await beforeStarting(KillSwitch.hosts(in: server.config, kind: server.kind))
        let runner = CoreRunner(executable: AppPaths.coreExecutable, assetDirectory: AppPaths.assetsDirectory,
                                runDirectory: AppPaths.runDirectory.appendingPathComponent("proxy-\(port)", isDirectory: true))
        guard proxy(for: server.id) != nil else { return }
        runners[server.id] = runner
        let tag = "[v2mac] Proxy :\(port) (\(server.name))"
        Task { [logs] in for await line in runner.logs { logs.append("\(tag) \(line)") } }
        Task { [weak self] in
            for await state in runner.states { self?.setState(state, for: server.id) }
        }
        do {
            let inbound = InboundSettings(port: port, allowLAN: options.allowLAN,
                                          username: options.username, password: options.password)
            let run = RunOptions(inbound: inbound, logLevel: .warning, metricsPort: try PortUtil.freePort(),
                                 dialer: Prefs.dialer, dns: Prefs.dns, outboundInterface: outboundInterface())
            let config: JSONValue
            switch server.kind {
            case .outbound:
                var outbound = server.config
                if Prefs.allowInsecure, InsecureTLS.isRequested(by: outbound) { outbound = await InsecureTLS.pinning(outbound) }
                config = try ConfigBuilder.build(outbound: outbound, options: run, routing: .global)
            case .custom:
                config = try ConfigBuilder.buildCustom(config: server.config, options: run, routing: .global)
            }
            guard proxy(for: server.id) != nil else { return }
            try await runner.start(config: config, readyPort: port, listenHost: inbound.listenAddress)
            logs.append("\(tag) started")
        } catch {
            logs.append("\(tag) failed: \(error.localizedDescription)")
            setState(.failed(error.localizedDescription), for: server.id)
        }
    }

    private func setState(_ state: CoreState, for id: UUID) {
        guard let index = proxies.firstIndex(where: { $0.id == id }) else { return }
        proxies[index].state = state
    }

    func stop(_ id: UUID) {
        proxies.removeAll { $0.id == id }
        if let runner = runners.removeValue(forKey: id) { Task { await runner.stop() } }
    }

    /// On quit: waits until every core has stopped.
    func stopAll() async {
        let all = runners.values
        proxies = []
        runners = [:]
        for runner in all { await runner.stop() }
    }
}
