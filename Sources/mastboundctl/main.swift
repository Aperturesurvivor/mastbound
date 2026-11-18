import Darwin
import Foundation
import MastboundCore

// Command tool. The only way to change Mastbound's state. See
// docs/rewrite-plan.md §4.4 for the command contract the UI uses.

let usage = """
usage:
  mastboundctl status
  mastboundctl version
  mastboundctl install
  mastboundctl start  (--minutes N | --hours N | --days N)
  mastboundctl extend (--minutes N | --hours N | --days N)
  mastboundctl recover --cancel     (no password needed)
  mastboundctl recover --begin      (used by the app's early-end flow)
  mastboundctl recover --finish PHRASE  (only 1 hour or more after --begin)
  mastboundctl uninstall
"""

struct UsageError: Error {}

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("mastboundctl: \(message)\n".utf8))
    exit(code)
}

/// Test builds only: `MASTBOUND_SANDBOX=<folder>` uses a test layout in that
/// folder and skips the root check, so the quit flow can be tried safely.
let sandbox: URL? = Policy.isTestBuild
    ? ProcessInfo.processInfo.environment["MASTBOUND_SANDBOX"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    : nil

func requireRoot() {
    guard geteuid() == 0 || sandbox != nil else { fail("this command needs administrator rights (run with sudo).") }
}

func durationSeconds(_ arguments: [String]) throws -> Double {
    guard arguments.count == 2, let value = Double(arguments[1]), value.isFinite, value > 0 else { throw UsageError() }
    switch arguments[0] {
    case "--minutes": return value * 60
    case "--hours": return value * 3600
    case "--days": return value * 86_400
    default: throw UsageError()
    }
}

func format(_ seconds: Double) -> String {
    let total = Int(seconds.rounded(.up))
    let days = total / 86_400, hours = (total % 86_400) / 3600, minutes = (total % 3600) / 60
    return days > 0 ? "\(days)d \(hours)h \(minutes)m" : "\(hours)h \(minutes)m"
}

func printStatus(_ engine: Engine) throws {
    if Policy.isTestBuild { print("WARNING: test build with short durations; not for real use") }
    guard FileManager.default.fileExists(atPath: engine.paths.statusFile.path) else {
        print("phase: not installed")
        return
    }
    let status = try engine.readStatus()
    print("phase: \(status.phase.rawValue)")
    if status.phase != .idle, Date().timeIntervalSince(status.updatedAt) > 180 {
        print("WARNING: the background service is not running. The block stays on, but the commitment cannot end.")
        print("Turn on \"mastboundd\" in System Settings > General > Login Items & Extensions.")
    }
    if let remaining = status.remainingSeconds { print("time left: \(format(remaining))") }
    if let recovery = status.recoveryRemainingSeconds { print("recovery clears in: \(format(recovery))") }
    if let quit = status.quitElapsedSeconds { print("early-end flow open for: \(format(quit))") }
    if let end = status.estimatedEnd { print("estimated end: \(end.formatted(date: .abbreviated, time: .shortened))") }
    if let last = status.lastEnd { print("last commitment: \(last.reason.rawValue) at \(last.endedAt.formatted())") }
}

/// The folder this program runs from. It must hold mastboundd and the list.
func sourceDirectory() -> URL {
    let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
    return executable.resolvingSymlinksInPath().deletingLastPathComponent()
}

func daemonIsLoaded() -> Bool {
    guard sandbox == nil else { return false } // a sandbox never touches launchd
    return (try? SystemCommands.run("/bin/launchctl", ["print", "system/\(Paths.launchDaemonLabel)"]).status) == 0
}

func loadDaemon(_ paths: Paths) throws {
    guard sandbox == nil else { return }
    if daemonIsLoaded() {
        try SystemCommands.run("/bin/launchctl", ["bootout", "system/\(Paths.launchDaemonLabel)"])
        // bootout returns before launchd has removed the job; a bootstrap
        // too soon fails with error 5. Wait for the job to go.
        for _ in 0..<50 where daemonIsLoaded() { usleep(100_000) }
    }
    var last = ""
    for attempt in 0..<5 {
        if attempt > 0 { sleep(1) }
        let result = try SystemCommands.run("/bin/launchctl", ["bootstrap", "system", paths.launchDaemonPlist.path])
        if result.status == 0 || daemonIsLoaded() { return }
        last = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    throw MastboundError.notAllowed(
        "The Mastbound background service could not start (\(last)). If \"mastboundd\" is off in System Settings > General > Login Items & Extensions, turn it on and try again."
    )
}

func install(_ engine: Engine) throws {
    try Installer.installFiles(from: sourceDirectory(), paths: engine.paths, bundledListSHA256: engine.bundledListSHA256)
    try loadDaemon(engine.paths)
}

func uninstall(_ engine: Engine) throws {
    // Check first, so a refused uninstall never stops the daemon.
    guard try engine.canUninstall() else {
        throw MastboundError.notAllowed("A commitment is running. Mastbound cannot be removed until it ends.")
    }
    if daemonIsLoaded() {
        try SystemCommands.run("/bin/launchctl", ["bootout", "system/\(Paths.launchDaemonLabel)"])
    }
    do {
        try engine.prepareUninstall()
    } catch {
        try? loadDaemon(engine.paths) // put the daemon back
        throw error
    }
    try Installer.removeFiles(paths: engine.paths)
}

let engine = Engine(
    paths: sandbox.map { Paths.testing(root: $0) } ?? .system,
    bundledListSHA256: BundledList.sha256,
    clock: { try SystemClock.now() },
    afterHostsChange: { SystemCommands.flushDNSCaches() }
)
let arguments = Array(CommandLine.arguments.dropFirst())

do {
    switch arguments.first {
    case "status":
        try printStatus(engine)
    case "version":
        print(Mastbound.version + (Policy.isTestBuild ? " (test build)" : ""))
    case "install":
        requireRoot()
        try install(engine)
        print("Mastbound is installed.")
    case "start":
        requireRoot()
        let seconds = try durationSeconds(Array(arguments.dropFirst()))
        try install(engine)
        try engine.start(durationSeconds: seconds)
        try printStatus(engine)
    case "extend":
        requireRoot()
        try engine.extend(bySeconds: try durationSeconds(Array(arguments.dropFirst())))
        try printStatus(engine)
    case "recover":
        let rest = Array(arguments.dropFirst())
        if rest == ["--cancel"] {
            // No password: cancelling only keeps the block longer.
            if geteuid() == 0 && sandbox == nil {
                try engine.stopEarlyEnd()
            } else {
                try CancelRequest.write(paths: engine.paths)
                func pending() -> Bool {
                    guard let status = try? engine.readStatus() else { return false }
                    return status.phase == .recovering || status.quitElapsedSeconds != nil
                }
                var waited = 0
                while pending(), waited < 20 { sleep(1); waited += 1 }
                if pending() { print("The cancel request is waiting for the Mastbound service.") }
            }
            try printStatus(engine)
        } else if rest == ["--begin"] {
            // The app's flow. Starts a clock only; the block stays fully on.
            requireRoot()
            try engine.beginQuit()
            try printStatus(engine)
        } else if rest.count == 2, rest[0] == "--finish" {
            // Refused until the flow has been open for the minimum time.
            requireRoot()
            try engine.finishQuit(confirmation: rest[1])
            try printStatus(engine)
        } else if Policy.isTestBuild, rest.count == 2, rest[0] == "--confirm" {
            // Test builds only, for the scripted real-system checks.
            requireRoot()
            try engine.requestRecovery(confirmation: rest[1])
            try printStatus(engine)
        } else {
            throw UsageError()
        }
    case "uninstall":
        requireRoot()
        try uninstall(engine)
        print("Mastbound is removed.")
    default:
        throw UsageError()
    }
} catch is UsageError {
    fail(usage, code: 2)
} catch {
    fail(error.localizedDescription)
}
