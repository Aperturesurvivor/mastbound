import Darwin
import Foundation
import MastboundCore
import OSLog

// Root daemon started by launchd. Every 5 seconds it reconciles the state and
// the /etc/hosts section. Errors keep the current block (fail closed).

let logger = Logger(subsystem: "com.josiahwilson.mastbound", category: "daemon")
let interval: UInt32 = 5

guard geteuid() == 0 else {
    FileHandle.standardError.write(Data("mastboundd must run as root.\n".utf8))
    exit(1)
}

let engine = Engine(
    paths: .system,
    bundledListSHA256: BundledList.sha256,
    clock: { try SystemClock.now() },
    afterHostsChange: { SystemCommands.flushDNSCaches() }
)
logger.notice("mastboundd \(Mastbound.version, privacy: .public) started")

var lastMessage = ""
var lastMessageTime = Date.distantPast
@MainActor func logOnce(_ message: String, error: Bool) {
    // Do not repeat the same message more than once a minute.
    guard message != lastMessage || Date().timeIntervalSince(lastMessageTime) >= 60 else { return }
    lastMessage = message
    lastMessageTime = Date()
    if error {
        logger.error("\(message, privacy: .public)")
    } else {
        logger.notice("\(message, privacy: .public)")
    }
}

var lastPhase: Phase?
while true {
    do {
        let report = try engine.reconcile()
        if report.phase != lastPhase {
            logger.notice("Phase is now \(report.phase.rawValue, privacy: .public)")
            lastPhase = report.phase
        }
        if report.hostsChanged { logger.notice("Updated the hosts section") }
        for warning in report.warnings { logOnce(warning, error: false) }
    } catch {
        logOnce("Reconcile failed; the current block is kept: \(error.localizedDescription)", error: true)
    }
    sleep(interval)
}
