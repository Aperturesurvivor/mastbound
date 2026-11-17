import Foundation
import Testing
@testable import MastboundCore

private func started(duration: Double = 10 * day, at r: ClockReading = reading(mono: 0, wall: 0)) throws -> EngineState {
    try EngineState.idle.starting(durationSeconds: duration, listSHA256: sampleSHA, at: r)
}

@Suite("Commitment transitions")
struct CommitmentTransitionTests {
    @Test("Start moves idle to active")
    func startFromIdle() throws {
        let state = try started()
        #expect(state.phase == .active)
        #expect(state.commitment?.remainingSeconds == 10 * day)
    }

    @Test("Start is refused while a commitment runs")
    func startTwiceRefused() throws {
        let state = try started()
        #expect(throws: MastboundError.self) {
            try state.starting(durationSeconds: day, listSHA256: sampleSHA, at: reading(mono: 1, wall: 1))
        }
    }

    @Test("D4: start refuses durations under 1 hour or over 365 days", arguments: [
        0.0, 59.0 * 60, 365.0 * 86_400 + 1, -1.0, Double.infinity, Double.nan,
    ])
    func startDurationLimits(duration: Double) {
        #expect(throws: MastboundError.self) {
            try EngineState.idle.starting(durationSeconds: duration, listSHA256: sampleSHA, at: reading(mono: 0, wall: 0))
        }
    }

    @Test("D4: start accepts exactly 1 hour and exactly 365 days", arguments: [3600.0, 365.0 * 86_400])
    func startDurationBounds(duration: Double) throws {
        #expect(try started(duration: duration).phase == .active)
    }

    @Test("Start refuses a value that is not a SHA-256")
    func startNeedsListHash() {
        #expect(throws: MastboundError.self) {
            try EngineState.idle.starting(durationSeconds: day, listSHA256: "abc", at: reading(mono: 0, wall: 0))
        }
    }

    @Test("D3: commitment ends when credited time reaches the duration")
    func endsWhenDue() throws {
        let state = try started(duration: day)
        #expect(state.ticked(at: reading(mono: day - 1, wall: day - 1)).phase == .active)
        let ended = state.ticked(at: reading(mono: day, wall: day))
        #expect(ended.phase == .idle)
        #expect(ended.lastEnd?.reason == .completed)
    }

    @Test("I6: setting the clock forward a year does not end the commitment")
    func clockForwardDoesNotEnd() throws {
        let state = try started(duration: day)
        let ticked = state.ticked(at: reading(mono: 10, wall: 365 * day))
        #expect(ticked.phase == .active)
        #expect(ticked.commitment?.creditedSeconds == 10)
    }

    @Test("I7: a reboot keeps the commitment and credits time that passed")
    func rebootKeepsCommitment() throws {
        let state = try started(duration: day)
        let afterReboot = state
            .ticked(at: reading(boot: "A", mono: hour, wall: hour))
            .ticked(at: reading(boot: "B", mono: 20, wall: 3 * hour))
        #expect(afterReboot.phase == .active)
        #expect(afterReboot.commitment?.creditedSeconds == 3 * hour)
    }

    @Test("Ticking an idle state changes nothing")
    func idleTickIsNoOp() {
        #expect(EngineState.idle.ticked(at: reading(mono: 5, wall: 5)) == .idle)
    }
}

@Suite("I2 extension")
struct ExtensionTests {
    @Test("I2: extend adds time")
    func extendAdds() throws {
        let state = try started(duration: day).extending(bySeconds: day, at: reading(mono: 0, wall: 0))
        #expect(state.commitment?.durationSeconds == 2 * day)
    }

    @Test("I2: extend refuses zero, negative and non-finite values", arguments: [0, -1, -day, Double.nan, -Double.infinity, Double.infinity])
    func extendRejectsNonPositive(seconds: Double) throws {
        let state = try started()
        #expect(throws: MastboundError.self) {
            try state.extending(bySeconds: seconds, at: reading(mono: 0, wall: 0))
        }
    }

    @Test("D4: extend refuses more than 365 days left")
    func extendCap() throws {
        let state = try started(duration: 300 * day)
        #expect(throws: MastboundError.self) {
            try state.extending(bySeconds: 66 * day, at: reading(mono: 0, wall: 0))
        }
        // After time passes, the same extension fits.
        let later = try state.extending(bySeconds: 66 * day, at: reading(mono: day, wall: day))
        #expect(later.commitment?.remainingSeconds == 365 * day)
    }

    @Test("Extend is refused when idle")
    func extendIdleRefused() {
        #expect(throws: MastboundError.self) {
            try EngineState.idle.extending(bySeconds: day, at: reading(mono: 0, wall: 0))
        }
    }

    @Test("Extend is refused after the commitment ended, even if not yet ticked")
    func extendAfterEndRefused() throws {
        let state = try started(duration: day)
        #expect(throws: MastboundError.self) {
            try state.extending(bySeconds: day, at: reading(mono: 2 * day, wall: 2 * day))
        }
    }
}

@Suite("D1 recovery")
struct RecoveryTests {
    private func recovering() throws -> EngineState {
        try started(duration: 30 * day)
            .requestingRecovery(confirmation: Policy.recoveryPhrase, at: reading(mono: hour, wall: hour))
    }

    @Test("D1: recovery needs the exact phrase", arguments: ["", "i want to end my commitment early", "yes"])
    func recoveryNeedsPhrase(phrase: String) throws {
        let state = try started()
        #expect(throws: MastboundError.self) {
            try state.requestingRecovery(confirmation: phrase, at: reading(mono: 0, wall: 0))
        }
    }

    @Test("D1: during the recovery delay the list stays blocked")
    func blockStaysDuringDelay() throws {
        let state = try recovering().ticked(at: reading(mono: hour + Policy.recoveryDelaySeconds - 1, wall: hour + Policy.recoveryDelaySeconds - 1))
        #expect(state.phase == .recovering)
        #expect(try Enforcement.blockedDomains(for: state, lists: [["adult.example"]]) == ["adult.example"])
    }

    @Test("D1: recovery ends the commitment after 72 hours of credited time")
    func recoveryEndsAfterDelay() throws {
        #expect(Policy.recoveryDelaySeconds == 72 * hour)
        let ended = try recovering().ticked(at: reading(mono: hour + Policy.recoveryDelaySeconds, wall: hour + Policy.recoveryDelaySeconds))
        #expect(ended.phase == .idle)
        #expect(ended.lastEnd?.reason == .recovered)
    }

    @Test("D1, I6: a clock jump does not shorten the recovery delay")
    func clockJumpDoesNotSkipDelay() throws {
        let state = try recovering().ticked(at: reading(mono: hour + 60, wall: 10 * day))
        #expect(state.phase == .recovering)
    }

    @Test("D1: cancel returns to active and the delay starts over next time")
    func cancelRecovery() throws {
        let cancelled = try recovering().cancellingRecovery(at: reading(mono: 2 * hour, wall: 2 * hour))
        #expect(cancelled.phase == .active)
        let again = try cancelled.requestingRecovery(confirmation: Policy.recoveryPhrase, at: reading(mono: 3 * hour, wall: 3 * hour))
        #expect(again.ticked(at: reading(mono: hour + Policy.recoveryDelaySeconds, wall: hour + Policy.recoveryDelaySeconds)).phase == .recovering)
    }

    @Test("Recovery cannot be requested twice or when idle")
    func recoveryRefusals() throws {
        let state = try recovering()
        #expect(throws: MastboundError.self) {
            try state.requestingRecovery(confirmation: Policy.recoveryPhrase, at: reading(mono: 2 * hour, wall: 2 * hour))
        }
        #expect(throws: MastboundError.self) {
            try EngineState.idle.requestingRecovery(confirmation: Policy.recoveryPhrase, at: reading(mono: 0, wall: 0))
        }
        #expect(throws: MastboundError.self) {
            try EngineState.idle.cancellingRecovery(at: reading(mono: 0, wall: 0))
        }
    }

    @Test("Extend is allowed while recovering")
    func extendWhileRecovering() throws {
        let state = try recovering().extending(bySeconds: day, at: reading(mono: 2 * hour, wall: 2 * hour))
        #expect(state.phase == .recovering)
        #expect(state.commitment?.durationSeconds == 31 * day)
    }
}

@Suite("I3 uninstall gate")
struct UninstallGateTests {
    @Test("I3: uninstall is allowed only when idle")
    func uninstallOnlyWhenIdle() throws {
        #expect(EngineState.idle.canUninstall)
        let active = try started()
        #expect(!active.canUninstall)
        let recovering = try active.requestingRecovery(confirmation: Policy.recoveryPhrase, at: reading(mono: 0, wall: 0))
        #expect(!recovering.canUninstall)
        #expect(active.ticked(at: reading(mono: 10 * day, wall: 10 * day)).canUninstall)
    }
}

@Suite("Property tests")
struct CommitmentPropertyTests {
    /// Random sequences of operations and clock changes. After each step,
    /// check the rules that must always hold.
    @Test("I2, I6, D4: rules hold over 20,000 random steps", arguments: [UInt64(1), 2, 3, 4, 5])
    func randomSequences(seed: UInt64) throws {
        var rng = SplitMix64(state: seed)
        var state = EngineState.idle
        var boot = 0
        var mono: Double = 0
        var wall: Double = 0

        for _ in 0..<4000 {
            // Advance real time, sometimes reboot, sometimes change the wall clock.
            let step = Double.random(in: 0...(6 * hour), using: &rng)
            mono += step
            wall += step
            if Int.random(in: 0..<50, using: &rng) == 0 {
                wall += Double.random(in: -400 * day...400 * day, using: &rng) // clock change
            }
            if Int.random(in: 0..<100, using: &rng) == 0 {
                boot += 1
                mono = Double.random(in: 0...60, using: &rng) // monotonic restarts
            }
            let now = reading(boot: "boot-\(boot)", mono: mono, wall: wall)

            let before = state.ticked(at: now)
            let next: EngineState
            switch Int.random(in: 0..<6, using: &rng) {
            case 0: next = (try? before.starting(durationSeconds: Double.random(in: 0...(400 * day), using: &rng), listSHA256: sampleSHA, at: now)) ?? before
            case 1: next = (try? before.extending(bySeconds: Double.random(in: -day...(100 * day), using: &rng), at: now)) ?? before
            case 2: next = (try? before.requestingRecovery(confirmation: Policy.recoveryPhrase, at: now)) ?? before
            case 3: next = (try? before.cancellingRecovery(at: now)) ?? before
            default: next = before
            }

            if let old = before.commitment, let new = next.commitment, old.startedAt == new.startedAt {
                #expect(new.durationSeconds >= old.durationSeconds)   // I2
                #expect(new.creditedSeconds >= old.creditedSeconds)   // I6
            }
            if let commitment = next.commitment {
                #expect(commitment.remainingSeconds <= Policy.maximumRemainingSeconds) // D4
                #expect(commitment.creditedSeconds < commitment.durationSeconds)
            }
            #expect(next.canUninstall == (next.phase == .idle))      // I3
            #expect(try next.validated() == next)
            state = next
        }
    }
}

@Suite("Build settings")
struct BuildSettingTests {
    @Test("Normal builds use the real limits, not the test-build limits")
    func realLimits() {
        #expect(!Policy.isTestBuild)
        #expect(Policy.minimumDurationSeconds == 3600)
        #expect(Policy.recoveryDelaySeconds == 72 * 3_600)
    }
}

@Suite("In-app early-end flow")
struct QuitFlowGateTests {
    private func open() throws -> EngineState {
        try started(duration: 30 * day).beginningQuit(at: reading(mono: hour, wall: hour))
    }

    @Test("Opening the flow keeps the block fully on")
    func openKeepsBlock() throws {
        let state = try open()
        #expect(state.phase == .active)
        #expect(state.commitment?.quitElapsedSeconds == 0)
        #expect(try Enforcement.blockedDomains(for: state, lists: [["adult.example"]]) == ["adult.example"])
    }

    @Test("Finish is refused before the minimum time, even with a clock jump")
    func finishTooSoon() throws {
        #expect(Policy.quitFlowMinimumSeconds == hour)
        let early = reading(mono: hour + Policy.quitFlowMinimumSeconds - 1, wall: 50 * day)
        #expect(throws: MastboundError.self) {
            try open().finishingQuit(confirmation: Policy.recoveryPhrase, at: early)
        }
    }

    @Test("Finish after the minimum time starts the 72-hour delay")
    func finishStartsDelay() throws {
        let at = reading(mono: hour + Policy.quitFlowMinimumSeconds, wall: hour + Policy.quitFlowMinimumSeconds)
        let state = try open().finishingQuit(confirmation: Policy.recoveryPhrase, at: at)
        #expect(state.phase == .recovering)
        #expect(state.commitment?.quitStartedAtCredit == nil)
        #expect(state.commitment?.recoveryRemainingSeconds == Policy.recoveryDelaySeconds)
    }

    @Test("Finish needs the phrase and an open flow")
    func finishRefusals() throws {
        let at = reading(mono: 3 * hour, wall: 3 * hour)
        #expect(throws: MastboundError.self) { try open().finishingQuit(confirmation: "yes", at: at) }
        #expect(throws: MastboundError.self) {
            try started(duration: 30 * day).finishingQuit(confirmation: Policy.recoveryPhrase, at: at)
        }
        #expect(throws: MastboundError.self) { try EngineState.idle.beginningQuit(at: at) }
    }

    @Test("An unfinished flow lapses after the window")
    func flowLapses() throws {
        let late = hour + Policy.quitFlowWindowSeconds + 1
        let state = try open().ticked(at: reading(mono: late, wall: late))
        #expect(state.commitment?.quitStartedAtCredit == nil)
        #expect(throws: MastboundError.self) {
            try state.finishingQuit(confirmation: Policy.recoveryPhrase, at: reading(mono: late, wall: late))
        }
    }

    @Test("Opening again starts the clock again")
    func reopenRestartsClock() throws {
        let again = try open().beginningQuit(at: reading(mono: 1.5 * hour, wall: 1.5 * hour))
        #expect(throws: MastboundError.self) {
            try again.finishingQuit(confirmation: Policy.recoveryPhrase, at: reading(mono: 2.2 * hour, wall: 2.2 * hour))
        }
    }

    @Test("Stop closes an open flow or a delay, and nothing else")
    func stop() throws {
        let at = reading(mono: 2 * hour, wall: 2 * hour)
        #expect(try open().stoppingEarlyEnd(at: at).commitment?.quitStartedAtCredit == nil)
        let recovering = try started(duration: 30 * day).requestingRecovery(confirmation: Policy.recoveryPhrase, at: at)
        #expect(try recovering.stoppingEarlyEnd(at: at).phase == .active)
        #expect(throws: MastboundError.self) { try started(duration: 30 * day).stoppingEarlyEnd(at: at) }
    }

    @Test("A saved open flow survives encoding; a damaged one is refused")
    func encoding() throws {
        let state = try open()
        #expect(try EngineState.decode(state.encoded()) == state)
        var bad = state
        let credited = bad.commitment?.creditedSeconds ?? 0
        bad.commitment?.quitStartedAtCredit = credited + 10
        #expect(throws: MastboundError.self) { try bad.validated() }
    }
}

@Suite("Quit terms text")
struct QuitTermsTextTests {
    @Test("The progress statement shows the exact time kept so far")
    func progress() {
        #expect(QuitTerms.progressText(elapsedSeconds: 3 * 86_400 + 4 * 3_600 + 59) == "3 days and 4 hours")
        #expect(QuitTerms.progressText(elapsedSeconds: 86_400) == "1 day")
        #expect(QuitTerms.progressText(elapsedSeconds: 5 * 3_600 + 12 * 60) == "5 hours and 12 minutes")
        #expect(QuitTerms.progressText(elapsedSeconds: 3_600 + 60) == "1 hour and 1 minute")
        #expect(QuitTerms.progressText(elapsedSeconds: 20) == "1 minute")
        let filled = QuitTerms.filled(elapsedSeconds: 2 * 3_600)
        #expect(filled.contains("I am trading 2 hours of progress for a few minutes."))
        #expect(!filled.joined().contains("{"))
    }
}
