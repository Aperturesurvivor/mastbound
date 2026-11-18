import Foundation
import MastboundCore
import Observation

/// What the screen shows. Built from `status.json`, which any user can read.
enum Screen: Equatable {
    case loading
    case idle(lastEnd: EndRecord?)
    /// `quitElapsed` is set while an in-app early-end flow is open.
    case active(remaining: Double, end: Date?, quitElapsed: Double?)
    case recovering(remaining: Double, recoveryRemaining: Double, end: Date?)
    case problem(String)
    /// A commitment runs, but the daemon has stopped writing its status, for
    /// example because "mastboundd" was turned off in Login Items.
    case serviceOff
}

/// Runs privileged `mastboundctl` commands. The real one asks for the admin
/// password; the demo one only changes a fake status.
protocol CommandRunner: Sendable {
    func start(seconds: Double) async throws
    func extend(seconds: Double) async throws
    /// No password: stopping an early end (an open flow or the 72-hour
    /// wait) only keeps the block on.
    func stopEarlyEnd() async throws
    /// Opens the early-end flow (password). Starts the daemon's clock only.
    func beginQuit() async throws
    /// Finishes the flow (password). The daemon refuses it until the flow
    /// has been open for the minimum time.
    func finishQuit() async throws
    /// Waits used by the flow. The demo uses short ones.
    var timing: QuitTiming { get }
    func readStatus() throws -> StatusReport?
}

@MainActor
@Observable
final class AppModel {
    private(set) var screen: Screen = .loading
    /// The command that is running now, if any. Each button shows its own
    /// busy text only for its own command.
    private(set) var busy: BusyAction?
    var isBusy: Bool { busy != nil }
    var errorMessage: String?
    /// Wall time of the last status read, to count down between reads.
    private var readAt = Date()
    private var report: StatusReport?
    private let runner: CommandRunner
    let isDemo: Bool
    /// When the app first saw an old status during a commitment. A short
    /// gap (for example just after a wake) does not count.
    private var staleSince: Date?
    /// The daemon saves at least once a minute while a commitment runs.
    static let staleAfterSeconds: Double = 180
    static let staleGraceSeconds: Double = 20

    init(runner: CommandRunner, isDemo: Bool) {
        self.runner = runner
        self.isDemo = isDemo
    }

    /// Reads the status file again. Called once a second by the view.
    func refresh() {
        do {
            report = try runner.readStatus()
            readAt = Date()
            updateScreen()
        } catch {
            screen = .problem("Mastbound could not read its status. The block, if any, stays on.")
        }
    }

    /// Moves the countdown between reads without touching the file.
    func tick() { updateScreen() }

    /// Credited time since the commitment started, as of now.
    func elapsedNow() -> Double? {
        guard let report, let elapsed = report.elapsedSeconds else { return nil }
        return elapsed + max(0, Date().timeIntervalSince(report.updatedAt)) + Date().timeIntervalSince(readAt)
    }

    private func updateScreen() {
        guard let report else { screen = .idle(lastEnd: nil); return }
        // status.json is written by the daemon, at most a few seconds old.
        let age = max(0, Date().timeIntervalSince(report.updatedAt)) + Date().timeIntervalSince(readAt)
        if report.phase != .idle, Date().timeIntervalSince(report.updatedAt) > Self.staleAfterSeconds {
            let since = staleSince ?? Date()
            staleSince = since
            if Date().timeIntervalSince(since) >= Self.staleGraceSeconds {
                screen = .serviceOff
                return
            }
        } else {
            staleSince = nil
        }
        switch report.phase {
        case .idle:
            screen = .idle(lastEnd: report.lastEnd)
        case .active:
            screen = .active(
                remaining: max(0, (report.remainingSeconds ?? 0) - age),
                end: report.estimatedEnd,
                quitElapsed: report.quitElapsedSeconds.map { $0 + age }
            )
        case .recovering:
            screen = .recovering(
                remaining: max(0, (report.remainingSeconds ?? 0) - age),
                recoveryRemaining: max(0, (report.recoveryRemainingSeconds ?? 0) - age),
                end: report.estimatedEnd
            )
        }
    }

    func start(seconds: Double) async { await run(.start) { try await self.runner.start(seconds: seconds) } }
    func extend(seconds: Double) async { await run(.extend) { try await self.runner.extend(seconds: seconds) } }
    func stopEarlyEnd() async {
        quitFlowOpen = false
        await run(.stop) { try await self.runner.stopEarlyEnd() }
    }

    // MARK: Early-end flow

    /// True while the flow's screens are shown. Kept in memory only: closing
    /// the app drops the progress, and the open flow lapses on its own.
    var quitFlowOpen = false
    var timing: QuitTiming { runner.timing }

    /// A short line on the countdown after the flow closed on its own.
    var notice: String?

    /// Shows the flow. The password and the daemon clock come at step 1.
    func openQuitFlow() { notice = nil; quitFlowOpen = true }

    /// Leaves the flow: before step 1 has asked for the password, or after
    /// the daemon closed it (then `notice` says why).
    func closeQuitFlow(notice: String? = nil) {
        self.notice = notice
        quitFlowOpen = false
    }

    /// Returns true if the daemon clock started.
    func beginQuit() async -> Bool {
        var ok = false
        await run(.begin) { try await self.runner.beginQuit(); ok = true }
        return ok
    }

    func finishQuit() async -> Bool {
        var ok = false
        await run(.finish) { try await self.runner.finishQuit(); ok = true }
        if ok { quitFlowOpen = false }
        return ok
    }

    private func run(_ kind: BusyAction, _ action: @escaping () async throws -> Void) async {
        notice = nil
        busy = kind
        defer { busy = nil }
        do {
            try await action()
            refresh()
        } catch AdminCommandError.cancelled {
            // The user closed the password prompt. Nothing changed.
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

enum BusyAction: Sendable { case start, extend, begin, finish, stop }

/// How long each wait in the early-end flow lasts.
struct QuitTiming: Sendable {
    /// Seconds before each terms box can be ticked.
    var termDelay: Double
    /// The cooling-off wait, with nothing to do.
    var coolOff: Double
    /// How long the hold button must be held.
    var hold: Double
    /// Lock after a wrong answer.
    var penalty: Double
    /// Least time spent on each written answer.
    var reasonMinimum: Double
    /// The daemon's own minimum, shown as the last countdown.
    var gate: Double

    #if MASTBOUND_TESTING
    // Test builds: the daemon lets an open flow lapse after 20 minutes, so
    // the long waits are cut to fit. Never set for a release.
    static let real = QuitTiming(termDelay: 6, coolOff: 60, hold: 15, penalty: 20, reasonMinimum: 10, gate: Policy.quitFlowMinimumSeconds)
    #else
    static let real = QuitTiming(termDelay: 6, coolOff: 15 * 60, hold: 90, penalty: 20, reasonMinimum: 60, gate: Policy.quitFlowMinimumSeconds)
    #endif
    static let demo = QuitTiming(termDelay: 1, coolOff: 15, hold: 5, penalty: 3, reasonMinimum: 3, gate: 120)
}
