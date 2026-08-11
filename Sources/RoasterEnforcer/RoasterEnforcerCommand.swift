import Darwin
import Foundation
import OSLog
import RoasterCore

private struct Options {
    var configurationURL: URL
    var adultBlocklistURL: URL
    var stateURL: URL
    var hostsURL: URL
    var expectedUserID: uid_t
    var once: Bool
    var clear: Bool
    var interval: TimeInterval

    static func parse(_ arguments: [String]) throws -> Options {
        var values: [String: String] = [:]
        var flags = Set<String>()
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--once" || argument == "--clear" {
                flags.insert(argument)
                index += 1
                continue
            }
            guard argument.hasPrefix("--"), index + 1 < arguments.count else {
                throw EnforcerError.invalidArguments("Unexpected argument: \(argument)")
            }
            values[argument] = arguments[index + 1]
            index += 2
        }

        guard let configurationPath = values["--config"],
              let adultBlocklistPath = values["--adult-blocklist"],
              let userIDString = values["--expected-uid"],
              let expectedUserID = uid_t(userIDString) else {
            throw EnforcerError.invalidArguments("Config, adult blocklist, and expected UID are required.")
        }
        let interval = TimeInterval(values["--interval"] ?? "15") ?? 15
        guard (5...300).contains(interval) else {
            throw EnforcerError.invalidArguments("Polling interval must be between 5 and 300 seconds.")
        }

        return Options(
            configurationURL: URL(fileURLWithPath: configurationPath),
            adultBlocklistURL: URL(fileURLWithPath: adultBlocklistPath),
            stateURL: URL(fileURLWithPath: values["--state"] ?? RoasterPaths.systemStateURL.path),
            hostsURL: URL(fileURLWithPath: values["--hosts"] ?? RoasterPaths.systemHostsURL.path),
            expectedUserID: expectedUserID,
            once: flags.contains("--once"),
            clear: flags.contains("--clear"),
            interval: interval
        )
    }
}

private final class Runtime {
    private let options: Options
    private let logger = Logger(
        subsystem: "com.josiahwilson.ScreenTimeRoasterMac",
        category: "enforcer"
    )
    private let pf = PFController()
    private var lastAppliedDomains: [String]?
    private var lastAppliedEndpoints: [NetworkEndpoint]?
    private var adultListSignature: String?
    private var adultDomains: [String] = []

    init(options: Options) {
        self.options = options
    }

    func runForever() {
        while true {
            do {
                try reconcile()
            } catch {
                logger.error("Reconciliation failed closed; existing enforcement is preserved: \(error.localizedDescription, privacy: .public)")
            }
            if options.once { return }
            Thread.sleep(forTimeInterval: options.interval)
        }
    }

    func clearAll() throws {
        let state = try? SecureFileIO.readState(at: options.stateURL)
        try SecureFileIO.rewriteHosts(at: options.hostsURL, blockedDomains: [])
        try pf.clear()
        try pf.release(token: state?.pfEnableToken)
        try SecureFileIO.removeState(at: options.stateURL)
        try SecureFileIO.removeRegularFile(
            at: RoasterPaths.systemAdultBlocklistURL,
            expectedOwner: 0
        )
        flushDNSCaches()
        logger.notice("All Screen Time Roaster Mac enforcement was removed.")
    }

    private func reconcile() throws {
        let configuration = try SecureFileIO.readConfiguration(
            at: options.configurationURL,
            expectedOwner: options.expectedUserID
        )
        let existingState = try SecureFileIO.readState(at: options.stateURL)
        var state = try EnforcementPolicy.decide(
            now: Date(),
            configuration: configuration,
            existingState: existingState
        )
        if state != existingState {
            try SecureFileIO.writeState(state, to: options.stateURL)
        }

        let permanentDomains: [String]
        if state.permanentProtectionLocked {
            let loaded = try loadAdultDomainsIfNeeded()
            let allowlist = Set(state.permanentAllowlist)
            permanentDomains = loaded.filter { !allowlist.contains($0) }
        } else {
            permanentDomains = []
        }

        let desiredDomains = try DomainValidator.normalize(
            permanentDomains + state.scheduledDomains,
            maximumCount: AdultBlocklistParser.maximumMergedDomains
        )
        let desiredEndpoints = state.scheduledEndpoints

        if lastAppliedDomains == nil {
            lastAppliedDomains = try SecureFileIO.managedHostsDomains(at: options.hostsURL)
        }
        if lastAppliedDomains != desiredDomains {
            try SecureFileIO.rewriteHosts(at: options.hostsURL, blockedDomains: desiredDomains)
            lastAppliedDomains = desiredDomains
            flushDNSCaches()
        }

        if !desiredEndpoints.isEmpty {
            let existingToken = existingState?.pfEnableToken
            let enabledToken = try pf.ensureEnabled(existingToken: existingToken)
            state.pfEnableToken = enabledToken
            if state != existingState {
                do {
                    try SecureFileIO.writeState(state, to: options.stateURL)
                } catch {
                    if existingToken == nil { try? pf.release(token: enabledToken) }
                    throw error
                }
            }
            if lastAppliedEndpoints != desiredEndpoints {
                try pf.load(endpoints: desiredEndpoints)
                lastAppliedEndpoints = desiredEndpoints
            }
        } else {
            if lastAppliedEndpoints == nil || lastAppliedEndpoints != [] {
                try pf.clear()
                lastAppliedEndpoints = []
            }
            try pf.release(token: existingState?.pfEnableToken)
            state.pfEnableToken = nil
            if state != existingState {
                try SecureFileIO.writeState(state, to: options.stateURL)
            }
        }
    }

    private func loadAdultDomainsIfNeeded() throws -> [String] {
        let attributes = try FileManager.default.attributesOfItem(atPath: options.adultBlocklistURL.path)
        let size = attributes[.size] as? NSNumber
        let modification = attributes[.modificationDate] as? Date
        let signature = "\(size?.uint64Value ?? 0):\(modification?.timeIntervalSince1970 ?? 0)"
        if signature != adultListSignature {
            let userDomains = try SecureFileIO.readAdultBlocklist(
                at: options.adultBlocklistURL,
                expectedOwner: options.expectedUserID
            )
            let systemDomains: [String]
            if FileManager.default.fileExists(atPath: RoasterPaths.systemAdultBlocklistURL.path) {
                systemDomains = try SecureFileIO.readAdultBlocklist(
                    at: RoasterPaths.systemAdultBlocklistURL,
                    expectedOwner: 0
                )
            } else {
                systemDomains = []
            }
            adultDomains = try DomainValidator.normalize(
                systemDomains + userDomains,
                maximumCount: AdultBlocklistParser.maximumMergedDomains
            )
            if adultDomains != systemDomains {
                try SecureFileIO.writeSystemAdultBlocklist(
                    adultDomains,
                    to: RoasterPaths.systemAdultBlocklistURL
                )
            }
            adultListSignature = signature
        }
        return adultDomains
    }

    private func flushDNSCaches() {
        _ = try? FixedCommandRunner.run(executable: "/usr/bin/dscacheutil", arguments: ["-flushcache"])
        _ = try? FixedCommandRunner.run(executable: "/usr/bin/killall", arguments: ["-HUP", "mDNSResponder"])
    }
}

@main
private struct RoasterEnforcerCommand {
    static func main() {
        do {
            guard geteuid() == 0 else { throw EnforcerError.requiresRoot }
            let options = try Options.parse(Array(CommandLine.arguments.dropFirst()))
            let runtime = Runtime(options: options)
            if options.clear {
                try runtime.clearAll()
            } else {
                runtime.runForever()
            }
        } catch {
            FileHandle.standardError.write(Data("RoasterEnforcer: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
