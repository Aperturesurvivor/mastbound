import Foundation
@testable import MastboundCore

/// A clock reading with plain-number inputs. `wall` and `mono` are seconds.
func reading(boot: String = "boot-A", mono: Double, wall: Double) -> ClockReading {
    ClockReading(
        wall: Date(timeIntervalSince1970: 1_800_000_000 + wall),
        monotonicNanoseconds: UInt64(mono * 1_000_000_000),
        bootSessionID: boot
    )
}

let hour: Double = 3600
let day: Double = 86_400
let sampleSHA = String(repeating: "a", count: 64)

/// Deterministic random numbers, so property tests always repeat the same way.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
