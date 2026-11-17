import Foundation
import MastboundCore

enum AdminCommandError: LocalizedError {
    case cancelled
    case missingResources
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .cancelled: "Cancelled."
        case .missingResources: "This copy of Mastbound is missing its helper files. Download it again."
        case .failed(let message): message
        }
    }
}

/// Runs `mastboundctl` as root through one standard admin password prompt.
///
/// `start` first copies the helper files into a new root-owned folder under
/// `/private/var/db`, because `mastboundctl install` refuses a source folder
/// that other users can write (SECURITY.md rule 9). `extend` uses the tool
/// that is already installed in `/Library/PrivilegedHelperTools/Mastbound`.
///
/// Known limit: root copies from the app bundle, so software that can write
/// the app bundle before the prompt could swap the helper. Code signing (P5)
/// is the planned fix.
struct AdminRunner: CommandRunner {
    let resources: URL

    static func fromBundle() -> AdminRunner? {
        let candidates = [Bundle.main.resourceURL, Bundle.main.executableURL?.deletingLastPathComponent()]
        for case let folder? in candidates {
            let ctl = folder.appendingPathComponent("mastboundctl")
            if FileManager.default.isExecutableFile(atPath: ctl.path) { return AdminRunner(resources: folder) }
        }
        return nil
    }

    func start(seconds: Double) async throws {
        let script = """
        set -eu
        src="$1"; shift
        stage=$(/usr/bin/mktemp -d /private/var/db/mastbound-stage.XXXXXX)
        trap '/bin/rm -rf "$stage"' EXIT
        for f in mastboundctl mastboundd adult-domains.txt; do /bin/cp "$src/$f" "$stage/$f"; done
        /usr/sbin/chown -R root:wheel "$stage"
        /bin/chmod 755 "$stage" "$stage/mastboundctl" "$stage/mastboundd"
        /bin/chmod 644 "$stage/adult-domains.txt"
        "$stage/mastboundctl" "$@"
        """
        try await runAsAdmin(script: script, arguments: [resources.path, "start", "--minutes", minutes(seconds)])
    }

    func extend(seconds: Double) async throws {
        let script = #"set -eu; "$1" extend --minutes "$2""#
        try await runAsAdmin(script: script, arguments: [Paths.system.installedTool.path, minutes(seconds)])
    }

    var timing: QuitTiming { .real }

    func beginQuit() async throws {
        let script = #"set -eu; "$1" recover --begin"#
        try await runAsAdmin(script: script, arguments: [Paths.system.installedTool.path])
    }

    func finishQuit() async throws {
        let script = #"set -eu; "$1" recover --finish "$2""#
        try await runAsAdmin(script: script, arguments: [Paths.system.installedTool.path, Policy.recoveryPhrase])
    }

    /// Leaves a request for the daemon, which acts on it within one tick
    /// (5 s). Then waits for the status to change, so the button can show
    /// progress.
    func stopEarlyEnd() async throws {
        try CancelRequest.write(paths: .system)
        for _ in 0..<30 {
            let status = try readStatus()
            if status?.phase != .recovering && status?.quitElapsedSeconds == nil { return }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw AdminCommandError.failed("The Mastbound service did not answer. Your request is saved and will be used when it runs.")
    }

    func readStatus() throws -> StatusReport? {
        let url = Paths.system.statusFile
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try StatusReport.decode(Data(contentsOf: url))
    }

    private func minutes(_ seconds: Double) -> String { String(Int((seconds / 60).rounded())) }

    /// `do shell script … with administrator privileges` shows the system
    /// password prompt. Arguments are passed as quoted words, never pasted
    /// into the script text.
    private func runAsAdmin(script: String, arguments: [String]) async throws {
        let words = ([script, "mastbound"] + arguments).map(appleScriptQuoted).joined(separator: " & \" \" & ")
        let source = "do shell script \"/bin/sh -c \" & \(words) with administrator privileges"
        try await Task.detached {
            var error: NSDictionary?
            guard let apple = NSAppleScript(source: source) else { throw AdminCommandError.failed("Could not prepare the command.") }
            _ = apple.executeAndReturnError(&error)
            if let error {
                if (error[NSAppleScript.errorNumber] as? Int) == -128 { throw AdminCommandError.cancelled }
                let message = (error[NSAppleScript.errorMessage] as? String) ?? "The command failed."
                throw AdminCommandError.failed(message.replacingOccurrences(of: "mastboundctl: ", with: ""))
            }
        }.value
    }

    /// `quoted form of "<text>"`, with the text escaped for an AppleScript
    /// string literal.
    private func appleScriptQuoted(_ text: String) -> String {
        let escaped = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "quoted form of \"\(escaped)\""
    }
}

/// For design work: no password, no system changes. It counts down in real
/// time from a fake status.
final class DemoRunner: CommandRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var report: StatusReport?
    let timing: QuitTiming

    init(initial: StatusReport? = nil, timing: QuitTiming = .demo) {
        report = initial
        self.timing = timing
    }

    func start(seconds: Double) async throws {
        try await Task.sleep(for: .milliseconds(600))
        set(.init(phase: .active, remaining: seconds))
    }

    func extend(seconds: Double) async throws {
        try await Task.sleep(for: .milliseconds(400))
        guard let current = try readStatus(), let remaining = current.remainingSeconds else { return }
        set(.init(phase: current.phase, remaining: remaining + seconds, recovery: current.recoveryRemainingSeconds, quitElapsed: current.quitElapsedSeconds))
    }

    func stopEarlyEnd() async throws {
        try await Task.sleep(for: .milliseconds(500))
        guard let current = try readStatus(), let remaining = current.remainingSeconds else { return }
        set(.init(phase: .active, remaining: remaining))
    }

    func beginQuit() async throws {
        try await Task.sleep(for: .milliseconds(500))
        guard let current = try readStatus(), current.phase == .active, let remaining = current.remainingSeconds else {
            throw AdminCommandError.failed("No commitment is running.")
        }
        set(.init(phase: .active, remaining: remaining, quitElapsed: 0))
    }

    func finishQuit() async throws {
        try await Task.sleep(for: .milliseconds(500))
        guard let current = try readStatus(), let remaining = current.remainingSeconds,
              let elapsed = current.quitElapsedSeconds else {
            throw AdminCommandError.failed("No early end is in progress. Start again from the app.")
        }
        guard elapsed >= timing.gate else { throw AdminCommandError.failed("It is too soon.") }
        set(.init(phase: .recovering, remaining: remaining, recovery: Policy.recoveryDelaySeconds))
    }

    func readStatus() throws -> StatusReport? {
        lock.lock(); defer { lock.unlock() }
        guard var report else { return nil }
        // Count down from when the fake status was made.
        let age = Date().timeIntervalSince(report.updatedAt)
        report.remainingSeconds = report.remainingSeconds.map { max(0, $0 - age) }
        report.recoveryRemainingSeconds = report.recoveryRemainingSeconds.map { max(0, $0 - age) }
        report.quitElapsedSeconds = report.quitElapsedSeconds.map { $0 + age }
        report.elapsedSeconds = report.elapsedSeconds.map { $0 + age }
        report.updatedAt = Date()
        return report
    }

    /// Keeps the time since the start across fake changes.
    private func set(_ new: StatusReport) {
        let elapsed = (try? readStatus())?.elapsedSeconds
        var new = new
        if new.phase != .idle { new.elapsedSeconds = new.elapsedSeconds ?? elapsed ?? 0 }
        lock.lock(); report = new; lock.unlock()
    }
}

extension StatusReport {
    /// A fake report for the demo and for screenshots.
    init(phase: Phase, remaining: Double?, recovery: Double? = nil, quitElapsed: Double? = nil, elapsed: Double? = nil, lastEnd: EndRecord? = nil) {
        let data = try! JSONSerialization.data(withJSONObject: [
            "phase": phase.rawValue,
            "updatedAt": ISO8601DateFormatter().string(from: Date()),
        ])
        var report = try! StatusReport.decode(data)
        report.remainingSeconds = remaining
        report.recoveryRemainingSeconds = recovery
        report.quitElapsedSeconds = quitElapsed
        report.elapsedSeconds = elapsed
        report.estimatedEnd = remaining.map { Date().addingTimeInterval($0) }
        report.lastEnd = lastEnd
        self = report
    }
}
