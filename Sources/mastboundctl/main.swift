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
  mastboundctl recover --confirm "\(Policy.recoveryPhrase)"
  mastboundctl recover --cancel
  mastboundctl uninstall
"""

struct UsageError: Error {}

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("mastboundctl: \(message)\n".utf8))
    exit(code)
}

func requireRoot() {
    guard geteuid() == 0 else { fail("this command needs administrator rights (run with sudo).") }
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
    if let remaining = status.remainingSeconds { print("time left: \(format(remaining))") }
    if let recovery = status.recoveryRemainingSeconds { print("recovery clears in: \(format(recovery))") }
    if let end = status.estimatedEnd { print("estimated end: \(end.formatted(date: .abbreviated, time: .shortened))") }
    if let last = status.lastEnd { print("last commitment: \(last.reason.rawValue) at \(last.endedAt.formatted())") }
}

/// The folder this program runs from. It must hold mastboundd and the list.
func sourceDirectory() -> URL {
    let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
    return executable.resolvingSymlinksInPath().deletingLastPathComponent()
}

func daemonIsLoaded() -> Bool {
    (try? SystemCommands.run("/bin/launchctl", ["print", "system/\(Paths.launchDaemonLabel)"]).status) == 0
}

func loadDaemon(_ paths: Paths) throws {
    if daemonIsLoaded() {
        try SystemCommands.run("/bin/launchctl", ["bootout", "system/\(Paths.launchDaemonLabel)"])
    }
    let result = try SystemCommands.run("/bin/launchctl", ["bootstrap", "system", paths.launchDaemonPlist.path])
    guard result.status == 0 else { throw MastboundError.notAllowed("launchctl bootstrap failed: \(result.output)") }
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
    paths: .system,
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
        requireRoot()
        let rest = Array(arguments.dropFirst())
        if rest == ["--cancel"] {
            try engine.cancelRecovery()
        } else if rest.count == 2, rest[0] == "--confirm" {
            try engine.requestRecovery(confirmation: rest[1])
        } else {
            throw UsageError()
        }
        try printStatus(engine)
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
