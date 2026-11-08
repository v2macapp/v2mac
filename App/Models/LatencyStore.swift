import Foundation
import SwiftData
import V2MacCore

/// Background writer for latency results.
@ModelActor
actor LatencyStore {
    /// Every save makes the server list fetch and rebuild all its rows, which with a long
    /// subscription froze the window, so results are saved a few times a second; `flush` saves the rest.
    private var lastSave = ContinuousClock.now

    private func saveSoon() throws {
        if ContinuousClock.now - lastSave > .milliseconds(400) { try flush() }
    }

    func flush() throws {
        lastSave = .now
        if modelContext.hasChanges { try modelContext.save() }
    }

    func apply(id: UUID, outcome: LatencyOutcome?, kind: String) throws {
        guard let profile = try modelContext.fetch(FetchDescriptor<Profile>(predicate: #Predicate { $0.id == id })).first else { return }
        profile.delayKindRaw = kind
        profile.delayTestedAt = Date()
        switch outcome {
        case .ok(let ms)?:
            profile.delayState = .ok
            profile.delayMs = ms
        case .timeout?:
            profile.delayState = .timeout
            profile.delayMs = nil
        case .invalid?:
            profile.delayState = .invalid
            profile.delayMs = nil
        case nil:
            profile.delayState = .na
            profile.delayMs = nil
        }
        try saveSoon()
    }

    func applySpeed(id: UUID, outcome: SpeedOutcome?) throws {
        guard let profile = try modelContext.fetch(FetchDescriptor<Profile>(predicate: #Predicate { $0.id == id })).first else { return }
        switch outcome {
        case .ok(let bps)?: profile.speedBps = bps
        case .failed?: profile.speedBps = 0
        case nil: profile.speedBps = nil
        }
        try saveSoon()
    }
}
