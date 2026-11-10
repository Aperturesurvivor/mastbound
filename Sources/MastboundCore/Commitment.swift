import Foundation

/// Fixed limits for every commitment. See docs/rewrite-plan.md §2.
public enum Policy {
    public static let minimumDurationSeconds: Double = 60 * 60            // 1 hour
    public static let maximumRemainingSeconds: Double = 365 * 24 * 60 * 60 // D4: 365 days
    public static let recoveryDelaySeconds: Double = 24 * 60 * 60         // D1: 24 hours
    public static let recoveryPhrase = "I want to end my commitment early"
}

public enum Phase: String, Codable, Equatable, Sendable {
    /// No commitment. Nothing is blocked.
    case idle
    /// Commitment running. The list is blocked.
    case active
    /// Commitment running, early recovery requested. The list is still
    /// blocked until the recovery delay has passed.
    case recovering
}

public struct Commitment: Codable, Equatable, Sendable {
    public var startedAt: Date
    /// Total length. Only grows (I2).
    public var durationSeconds: Double
    /// Time accepted as passed, from `TimeCredit` (I6).
    public var creditedSeconds: Double
    /// Reading at the last update. The next credit is measured from here.
    public var lastReading: ClockReading
    /// SHA-256 of the list in force when the commitment started.
    public var listSHA256: String
    /// `creditedSeconds` at the moment recovery was requested, if it was.
    public var recoveryRequestedAtCredit: Double?

    public var remainingSeconds: Double { max(0, durationSeconds - creditedSeconds) }

    /// Credited time still needed before recovery clears the block.
    public var recoveryRemainingSeconds: Double? {
        recoveryRequestedAtCredit.map {
            max(0, Policy.recoveryDelaySeconds - (creditedSeconds - $0))
        }
    }
}

public enum EndReason: String, Codable, Equatable, Sendable {
    case completed
    case recovered
}

public struct EndRecord: Codable, Equatable, Sendable {
    public var reason: EndReason
    public var endedAt: Date
}

/// The complete root-owned state. Every change is a pure function that
/// returns a new value, so each rule can be tested without root or real time.
public struct EngineState: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var commitment: Commitment?
    public var lastEnd: EndRecord?

    public init(version: Int = EngineState.currentVersion, commitment: Commitment? = nil, lastEnd: EndRecord? = nil) {
        self.version = version
        self.commitment = commitment
        self.lastEnd = lastEnd
    }

    public static let idle = EngineState()

    public var phase: Phase {
        guard let commitment else { return .idle }
        return commitment.recoveryRequestedAtCredit == nil ? .active : .recovering
    }

    /// I3: the daemon and its files may be removed only when nothing is active.
    public var canUninstall: Bool { phase == .idle }

    /// Estimated end on the wall clock, for display only. The real end is
    /// decided by credited time.
    public func estimatedEnd(from reading: ClockReading) -> Date? {
        guard let commitment else { return nil }
        var remaining = commitment.remainingSeconds
        if let recovery = commitment.recoveryRemainingSeconds { remaining = min(remaining, recovery) }
        return reading.wall.addingTimeInterval(remaining)
    }

    // MARK: Transitions

    /// Adds credited time and ends the commitment when it is due.
    public func ticked(at reading: ClockReading) -> EngineState {
        guard var commitment else { return self }
        commitment.creditedSeconds += TimeCredit.seconds(from: commitment.lastReading, to: reading)
        commitment.lastReading = reading

        if commitment.creditedSeconds >= commitment.durationSeconds {
            return EngineState(lastEnd: EndRecord(reason: .completed, endedAt: reading.wall))
        }
        if let requested = commitment.recoveryRequestedAtCredit,
           commitment.creditedSeconds - requested >= Policy.recoveryDelaySeconds {
            return EngineState(lastEnd: EndRecord(reason: .recovered, endedAt: reading.wall))
        }
        var next = self
        next.commitment = commitment
        return next
    }

    public func starting(durationSeconds: Double, listSHA256: String, at reading: ClockReading) throws -> EngineState {
        let current = ticked(at: reading)
        guard current.phase == .idle else {
            throw MastboundError.notAllowed("A commitment is already running.")
        }
        guard durationSeconds.isFinite,
              durationSeconds >= Policy.minimumDurationSeconds,
              durationSeconds <= Policy.maximumRemainingSeconds else {
            throw MastboundError.notAllowed("The duration must be from 1 hour to 365 days.")
        }
        guard Self.isSHA256(listSHA256) else {
            throw MastboundError.invalidList("The list hash is not a SHA-256 value.")
        }
        return EngineState(
            commitment: Commitment(
                startedAt: reading.wall,
                durationSeconds: durationSeconds,
                creditedSeconds: 0,
                lastReading: reading,
                listSHA256: listSHA256,
                recoveryRequestedAtCredit: nil
            ),
            lastEnd: current.lastEnd
        )
    }

    /// I2: adds time. There is no way to subtract time.
    public func extending(bySeconds seconds: Double, at reading: ClockReading) throws -> EngineState {
        var next = ticked(at: reading)
        guard var commitment = next.commitment else {
            throw MastboundError.notAllowed("No commitment is running.")
        }
        guard seconds.isFinite, seconds > 0 else {
            throw MastboundError.notAllowed("An extension must add a positive amount of time.")
        }
        guard commitment.remainingSeconds + seconds <= Policy.maximumRemainingSeconds else {
            throw MastboundError.notAllowed("The time left cannot be more than 365 days.")
        }
        commitment.durationSeconds += seconds
        next.commitment = commitment
        return next
    }

    /// D1: starts the recovery delay. The block stays on during the delay.
    public func requestingRecovery(confirmation: String, at reading: ClockReading) throws -> EngineState {
        var next = ticked(at: reading)
        guard next.phase == .active, var commitment = next.commitment else {
            throw MastboundError.notAllowed("Recovery can be requested only during an active commitment.")
        }
        guard confirmation == Policy.recoveryPhrase else {
            throw MastboundError.notAllowed("The confirmation phrase does not match.")
        }
        commitment.recoveryRequestedAtCredit = commitment.creditedSeconds
        next.commitment = commitment
        return next
    }

    public func cancellingRecovery(at reading: ClockReading) throws -> EngineState {
        var next = ticked(at: reading)
        guard next.phase == .recovering, var commitment = next.commitment else {
            throw MastboundError.notAllowed("No recovery is waiting.")
        }
        commitment.recoveryRequestedAtCredit = nil
        next.commitment = commitment
        return next
    }

    // MARK: Validation

    /// Checks a decoded state. The daemon must fail closed if this throws.
    public func validated() throws -> EngineState {
        guard version == Self.currentVersion else {
            throw MastboundError.invalidState("Unsupported state version \(version).")
        }
        if let commitment {
            let numbers = [commitment.durationSeconds, commitment.creditedSeconds]
            guard numbers.allSatisfy({ $0.isFinite && $0 >= 0 }),
                  commitment.durationSeconds >= Policy.minimumDurationSeconds,
                  Self.isSHA256(commitment.listSHA256) else {
                throw MastboundError.invalidState("The saved commitment has invalid values.")
            }
            if let requested = commitment.recoveryRequestedAtCredit {
                guard requested.isFinite, requested >= 0, requested <= commitment.creditedSeconds else {
                    throw MastboundError.invalidState("The saved recovery request is invalid.")
                }
            }
        }
        return self
    }

    static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}

// MARK: Encoding

extension EngineState {
    public static let maximumEncodedSize = 64 * 1024

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(try validated())
    }

    public static func decode(_ data: Data) throws -> EngineState {
        guard data.count <= maximumEncodedSize else {
            throw MastboundError.fileTooLarge("The state file is too large.")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let state: EngineState
        do {
            state = try decoder.decode(EngineState.self, from: data)
        } catch {
            throw MastboundError.invalidState("The state file could not be read: \(error.localizedDescription)")
        }
        return try state.validated()
    }
}

/// I1, I10: what the managed hosts section must contain.
public enum Enforcement {
    /// While a commitment runs, block the union of all given lists (for
    /// example the list locked at start and the list in a newer build), so an
    /// upgrade can add domains but never remove them. When idle, block nothing.
    public static func blockedDomains(for state: EngineState, lists: [[String]]) throws -> [String] {
        guard state.phase != .idle else { return [] }
        let union = Set(lists.joined())
        return try DomainValidator.normalize(Array(union), maximumCount: HostsSection.maximumDomains)
    }
}
