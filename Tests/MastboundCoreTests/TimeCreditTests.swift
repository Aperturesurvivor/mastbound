import Foundation
import Testing
@testable import MastboundCore

@Suite("I6 time credit")
struct TimeCreditTests {
    @Test("I6: same boot credits monotonic time")
    func sameBootUsesMonotonic() {
        let credit = TimeCredit.seconds(from: reading(mono: 100, wall: 0), to: reading(mono: 160, wall: 60))
        #expect(credit == 60)
    }

    @Test("I6: wall clock jump forward in the same boot is not credited")
    func forwardJumpIgnored() {
        let credit = TimeCredit.seconds(from: reading(mono: 100, wall: 0), to: reading(mono: 105, wall: 365 * day))
        #expect(credit == 5)
    }

    @Test("I6: wall clock jump back in the same boot does not remove credit")
    func backwardJumpIgnored() {
        let credit = TimeCredit.seconds(from: reading(mono: 100, wall: 0), to: reading(mono: 105, wall: -30 * day))
        #expect(credit == 5)
    }

    @Test("I6: monotonic clock going back in the same boot credits zero")
    func monotonicBackwardsCreditsZero() {
        #expect(TimeCredit.seconds(from: reading(mono: 100, wall: 0), to: reading(mono: 50, wall: 10)) == 0)
    }

    @Test("I7: across a reboot the wall-clock change is credited")
    func rebootUsesWall() {
        let credit = TimeCredit.seconds(
            from: reading(boot: "A", mono: 5000, wall: 0),
            to: reading(boot: "B", mono: 30, wall: 2 * hour)
        )
        #expect(credit == 2 * hour)
    }

    @Test("I7: across a reboot a wall clock that went back credits zero")
    func rebootWithClockBackCreditsZero() {
        let credit = TimeCredit.seconds(
            from: reading(boot: "A", mono: 5000, wall: 0),
            to: reading(boot: "B", mono: 30, wall: -40 * 365 * day)
        )
        #expect(credit == 0)
    }

    @Test("System clock gives a boot ID and a monotonic clock that does not go back")
    func systemClockIsUsable() throws {
        let first = try SystemClock.now()
        let second = try SystemClock.now()
        #expect(!first.bootSessionID.isEmpty)
        #expect(first.bootSessionID == second.bootSessionID)
        #expect(second.monotonicNanoseconds >= first.monotonicNanoseconds)
    }
}
