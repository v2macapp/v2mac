import Foundation

public struct TrafficSnapshot: Sendable, Equatable {
    public var uplink: Int64
    public var downlink: Int64
    /// The part of `uplink` and `downlink` that left through direct outbounds; the rest went through a server.
    public var directUplink: Int64
    public var directDownlink: Int64
    public var date: Date

    public init(uplink: Int64, downlink: Int64, directUplink: Int64 = 0, directDownlink: Int64 = 0, date: Date = Date()) {
        self.uplink = uplink
        self.downlink = downlink
        self.directUplink = directUplink
        self.directDownlink = directDownlink
        self.date = date
    }
}

public struct TrafficRate: Sendable, Equatable {
    public var upBytesPerSecond: Double
    public var downBytesPerSecond: Double
    public var directUpBytesPerSecond: Double = 0
    public var directDownBytesPerSecond: Double = 0

    public static let zero = TrafficRate(upBytesPerSecond: 0, downBytesPerSecond: 0)
}

extension TrafficSnapshot {
    /// Rate between two snapshots. Counter resets (core restart) yield zero.
    public func rate(since previous: TrafficSnapshot) -> TrafficRate {
        let dt = date.timeIntervalSince(previous.date)
        guard dt > 0, uplink >= previous.uplink, downlink >= previous.downlink else { return .zero }
        // Direct can never exceed the total it is part of (the two counters are read together but kept apart).
        func direct(_ now: Int64, _ before: Int64, _ total: Double) -> Double { min(Double(max(now - before, 0)) / dt, total) }
        let up = Double(uplink - previous.uplink) / dt, down = Double(downlink - previous.downlink) / dt
        return TrafficRate(upBytesPerSecond: up, downBytesPerSecond: down,
                           directUpBytesPerSecond: direct(directUplink, previous.directUplink, up),
                           directDownBytesPerSecond: direct(directDownlink, previous.directDownlink, down))
    }
}

public enum StatsError: Error, Sendable, Equatable {
    case badResponse
}

/// Reads traffic counters from Xray's metrics endpoint (`/debug/vars`).
public struct StatsClient: Sendable {
    private let url: URL
    private let inboundTags: [String]
    private let directTags: [String]
    private let session: URLSession

    public init(port: Int, inboundTags: [String] = ConfigBuilder.trafficInboundTags, directTags: [String] = []) {
        self.url = URL(string: "http://127.0.0.1:\(port)/debug/vars")!
        self.inboundTags = inboundTags
        self.directTags = directTags
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = 2
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
    }

    public func snapshot() async throws -> TrafficSnapshot {
        let (data, response) = try await session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw StatsError.badResponse }
        return try Self.parse(data, inboundTags: inboundTags, directTags: directTags)
    }

    /// Sums the counters of `inboundTags`, and of the `directTags` outbounds as the direct part.
    /// Missing counters (no traffic yet) read as zero.
    public static func parse(_ data: Data, inboundTags: [String], directTags: [String] = [], now: Date = Date()) throws -> TrafficSnapshot {
        guard let root = try? JSONValue.parse(data), case .object = root else { throw StatsError.badResponse }
        func sum(_ kind: String, _ tags: [String]) -> (up: Int64, down: Int64) {
            var up = 0.0, down = 0.0
            for tag in tags {
                let entry = root["stats"]?[kind]?[tag]
                up += entry?["uplink"]?.doubleValue ?? 0
                down += entry?["downlink"]?.doubleValue ?? 0
            }
            return (Int64(up), Int64(down))
        }
        let total = sum("inbound", inboundTags), direct = sum("outbound", directTags)
        return TrafficSnapshot(uplink: total.up, downlink: total.down, directUplink: direct.up, directDownlink: direct.down, date: now)
    }

    /// Outbounds whose traffic leaves this Mac directly: `freedom` ones that no other outbound dials
    /// through (a fragment dialer carries a server's traffic).
    public static func directTags(of config: JSONValue) -> [String] {
        let outbounds = config["outbounds"]?.arrayValue ?? []
        let carriers = Set(outbounds.flatMap { [$0["streamSettings"]?["sockopt"]?["dialerProxy"]?.stringValue, $0["proxySettings"]?["tag"]?.stringValue] }.compactMap { $0 })
        return outbounds.filter { $0["protocol"]?.stringValue == "freedom" }.compactMap { $0["tag"]?.stringValue }.filter { !carriers.contains($0) }
    }

    /// Counters and, when the config has an observatory, whether each probed outbound answers.
    public func read() async throws -> (snapshot: TrafficSnapshot, observatory: [String: Bool]) {
        let (data, response) = try await session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw StatsError.badResponse }
        return (try Self.parse(data, inboundTags: inboundTags, directTags: directTags), Self.observatory(data))
    }

    /// `observatory` in `/debug/vars`: outbound tag → alive. An outbound not probed yet is missing.
    public static func observatory(_ data: Data) -> [String: Bool] {
        guard let entries = (try? JSONValue.parse(data))?["observatory"]?.objectValue else { return [:] }
        return entries.mapValues { $0["alive"]?.boolValue ?? false }
    }

    public static func parse(_ data: Data, inboundTag: String, now: Date = Date()) throws -> TrafficSnapshot {
        try parse(data, inboundTags: [inboundTag], now: now)
    }
}
