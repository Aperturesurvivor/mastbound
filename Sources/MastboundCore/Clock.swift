import Darwin
import Foundation

/// One reading of the clocks the daemon uses to count commitment time.
public struct ClockReading: Codable, Equatable, Sendable {
    /// System wall clock. Can be changed by an administrator.
    public var wall: Date
    /// `mach_continuous_time` in nanoseconds. Counts sleep, cannot be set,
    /// and restarts from zero at boot.
    public var monotonicNanoseconds: UInt64
    /// Identifies one boot (`kern.bootsessionuuid`).
    public var bootSessionID: String

    public init(wall: Date, monotonicNanoseconds: UInt64, bootSessionID: String) {
        self.wall = wall
        self.monotonicNanoseconds = monotonicNanoseconds
        self.bootSessionID = bootSessionID
    }
}

/// Decides how much commitment time passed between two readings (I6).
public enum TimeCredit {
    /// - Same boot: credit monotonic time only, so wall-clock changes have no
    ///   effect in either direction.
    /// - Different boot: the monotonic clock restarted, so the only evidence is
    ///   the wall clock. Credit its change, or 0 if it went back. A clock
    ///   change made while the Mac was off is accepted; this is a documented
    ///   limit.
    public static func seconds(from previous: ClockReading, to current: ClockReading) -> Double {
        if previous.bootSessionID == current.bootSessionID {
            guard current.monotonicNanoseconds >= previous.monotonicNanoseconds else { return 0 }
            return Double(current.monotonicNanoseconds - previous.monotonicNanoseconds) / 1_000_000_000
        }
        let wallDelta = current.wall.timeIntervalSince(previous.wall)
        return wallDelta.isFinite ? max(0, wallDelta) : 0
    }
}

/// Reads the real clocks of this Mac.
public enum SystemClock {
    public static func now() throws -> ClockReading {
        ClockReading(
            wall: Date(),
            monotonicNanoseconds: continuousNanoseconds(),
            bootSessionID: try bootSessionID()
        )
    }

    static func continuousNanoseconds() -> UInt64 {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let ticks = mach_continuous_time()
        return ticks.multipliedReportingOverflow(by: UInt64(timebase.numer)).partialValue
            / UInt64(timebase.denom)
    }

    static func bootSessionID() throws -> String {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 1 else {
            throw MastboundError.invalidState("Could not read the boot session ID.")
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0 else {
            throw MastboundError.invalidState("Could not read the boot session ID.")
        }
        let value = String(decoding: buffer.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
        guard !value.isEmpty else {
            throw MastboundError.invalidState("The boot session ID is empty.")
        }
        return value
    }
}
