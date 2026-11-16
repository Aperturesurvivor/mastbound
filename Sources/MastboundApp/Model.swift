import Foundation
import MastboundCore
import Observation

/// What the screen shows. Built from `status.json`, which any user can read.
enum Screen: Equatable {
    case loading
    case idle(lastEnd: EndRecord?)
    case active(remaining: Double, end: Date?)
    case recovering(remaining: Double, recoveryRemaining: Double, end: Date?)
    case problem(String)
}

/// Runs privileged `mastboundctl` commands. The real one asks for the admin
/// password; the demo one only changes a fake status.
protocol CommandRunner: Sendable {
    func start(seconds: Double) async throws
    func extend(seconds: Double) async throws
    /// No password: cancelling an early end only keeps the block longer.
    func cancelRecovery() async throws
    func readStatus() throws -> StatusReport?
}

@MainActor
@Observable
final class AppModel {
    private(set) var screen: Screen = .loading
    private(set) var isBusy = false
    var errorMessage: String?
    /// Wall time of the last status read, to count down between reads.
    private var readAt = Date()
    private var report: StatusReport?
    private let runner: CommandRunner
    let isDemo: Bool

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

    private func updateScreen() {
        guard let report else { screen = .idle(lastEnd: nil); return }
        // status.json is written by the daemon, at most a few seconds old.
        let age = max(0, Date().timeIntervalSince(report.updatedAt)) + Date().timeIntervalSince(readAt)
        switch report.phase {
        case .idle:
            screen = .idle(lastEnd: report.lastEnd)
        case .active:
            screen = .active(remaining: max(0, (report.remainingSeconds ?? 0) - age), end: report.estimatedEnd)
        case .recovering:
            screen = .recovering(
                remaining: max(0, (report.remainingSeconds ?? 0) - age),
                recoveryRemaining: max(0, (report.recoveryRemainingSeconds ?? 0) - age),
                end: report.estimatedEnd
            )
        }
    }

    func start(seconds: Double) async { await run { try await self.runner.start(seconds: seconds) } }
    func extend(seconds: Double) async { await run { try await self.runner.extend(seconds: seconds) } }
    func cancelRecovery() async { await run { try await self.runner.cancelRecovery() } }

    private func run(_ action: @escaping () async throws -> Void) async {
        isBusy = true
        defer { isBusy = false }
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
