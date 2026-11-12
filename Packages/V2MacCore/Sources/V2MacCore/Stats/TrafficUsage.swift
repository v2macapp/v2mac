import Foundation

/// Bytes through the proxy: this session's (from the user's connect to the next one) and a
/// total kept across launches until the user resets it (spec 12.8).
public struct TrafficUsage: Sendable, Equatable, Codable {
    public var sessionUp: Int64 = 0
    public var sessionDown: Int64 = 0
    public var sessionStart: Date?
    public var totalUp: Int64 = 0
    public var totalDown: Int64 = 0
    public var totalSince: Date?
    /// Bytes (both ways) that went direct. Nil when counted before the split existed, so the
    /// whole amount's share is unknown.
    public var sessionDirect: Int64? = 0
    public var totalDirect: Int64? = 0

    public init() {}

    public var session: Int64 { sessionUp + sessionDown }
    public var total: Int64 { totalUp + totalDown }
    /// What went through a server; nil when unknown.
    public var sessionProxy: Int64? { sessionDirect.map { max(session - $0, 0) } }
    public var totalProxy: Int64? { totalDirect.map { max(total - $0, 0) } }

    public mutating func add(up: Int64, down: Int64, direct: Int64 = 0, now: Date = Date()) {
        guard up > 0 || down > 0 else { return }
        sessionUp += up
        sessionDown += down
        totalUp += up
        totalDown += down
        let direct = min(max(direct, 0), up + down)
        sessionDirect? += direct
        totalDirect? += direct
        if totalSince == nil { totalSince = now }
    }

    public mutating func startSession(at date: Date = Date()) {
        sessionUp = 0
        sessionDown = 0
        sessionDirect = 0
        sessionStart = date
    }

    public mutating func resetTotal(at date: Date = Date()) {
        totalUp = 0
        totalDown = 0
        totalDirect = 0
        totalSince = date
    }
}

extension TrafficSnapshot {
    /// Bytes counted since `previous`. A new core starts its counters at zero, so after a
    /// reset (or with no previous reading) everything in this snapshot is new.
    /// `direct` is the part of both that went direct.
    public func bytes(since previous: TrafficSnapshot?) -> (up: Int64, down: Int64, direct: Int64) {
        guard let previous, uplink >= previous.uplink, downlink >= previous.downlink else { return (uplink, downlink, directUplink + directDownlink) }
        let direct = max(directUplink - previous.directUplink, 0) + max(directDownlink - previous.directDownlink, 0)
        return (uplink - previous.uplink, downlink - previous.downlink, direct)
    }
}
