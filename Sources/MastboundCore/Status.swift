import Foundation

/// The public part of the state, written to `status.json` (mode 0644). It
/// holds no domains, so any user may read it.
public struct StatusReport: Codable, Equatable, Sendable {
    public var phase: Phase
    public var remainingSeconds: Double?
    public var recoveryRemainingSeconds: Double?
    /// Credited time since the in-app early-end flow began, if it is open.
    public var quitElapsedSeconds: Double?
    /// Credited time since the commitment started.
    public var elapsedSeconds: Double?
    public var estimatedEnd: Date?
    public var lastEnd: EndRecord?
    public var updatedAt: Date

    public init(state: EngineState, at reading: ClockReading) {
        phase = state.phase
        remainingSeconds = state.commitment?.remainingSeconds
        recoveryRemainingSeconds = state.commitment?.recoveryRemainingSeconds
        quitElapsedSeconds = state.commitment?.quitElapsedSeconds
        elapsedSeconds = state.commitment?.creditedSeconds
        estimatedEnd = state.estimatedEnd(from: reading)
        lastEnd = state.lastEnd
        updatedAt = reading.wall
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> StatusReport {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(StatusReport.self, from: data)
    }
}
