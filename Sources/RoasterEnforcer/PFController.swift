import Foundation
import RoasterCore

struct CommandResult {
    let status: Int32
    let standardOutput: String
    let standardError: String

    var combinedOutput: String { standardOutput + "\n" + standardError }
}

enum FixedCommandRunner {
    static func run(
        executable: String,
        arguments: [String],
        standardInput: Data? = nil
    ) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        let inputPipe = standardInput == nil ? nil : Pipe()
        process.standardInput = inputPipe

        try process.run()
        if let standardInput, let inputPipe {
            inputPipe.fileHandleForWriting.write(standardInput)
            try? inputPipe.fileHandleForWriting.close()
        }
        process.waitUntilExit()

        let output = String(
            data: outputPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        let error = String(
            data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        return CommandResult(
            status: process.terminationStatus,
            standardOutput: output,
            standardError: error
        )
    }
}

final class PFController {
    private let anchor = RoasterPaths.pfAnchor

    func ensureEnabled(existingToken: String?) throws -> String? {
        let status = try FixedCommandRunner.run(executable: "/sbin/pfctl", arguments: ["-s", "info"])
        if status.combinedOutput.localizedCaseInsensitiveContains("Status: Enabled") {
            return existingToken
        }

        let enable = try FixedCommandRunner.run(executable: "/sbin/pfctl", arguments: ["-E"])
        guard enable.status == 0 else {
            throw EnforcerError.commandFailed("Could not enable PF: \(enable.combinedOutput)")
        }
        let pattern = try NSRegularExpression(pattern: #"Token\s*:\s*([0-9A-Fa-f]+)"#)
        let range = NSRange(enable.combinedOutput.startIndex..., in: enable.combinedOutput)
        guard let match = pattern.firstMatch(in: enable.combinedOutput, range: range),
              let tokenRange = Range(match.range(at: 1), in: enable.combinedOutput) else {
            throw EnforcerError.commandFailed("PF was enabled but returned no reference token.")
        }
        return String(enable.combinedOutput[tokenRange])
    }

    func load(endpoints: [NetworkEndpoint]) throws {
        let rules = try PFRuleRenderer.render(endpoints: endpoints)
        let result = try FixedCommandRunner.run(
            executable: "/sbin/pfctl",
            arguments: ["-a", anchor, "-f", "-"],
            standardInput: Data(rules.utf8)
        )
        guard result.status == 0 else {
            throw EnforcerError.commandFailed("Could not load the isolated PF anchor: \(result.combinedOutput)")
        }
    }

    func clear() throws {
        let result = try FixedCommandRunner.run(
            executable: "/sbin/pfctl",
            arguments: ["-a", anchor, "-F", "all"]
        )
        if result.status != 0,
           !result.combinedOutput.localizedCaseInsensitiveContains("pf not enabled") {
            throw EnforcerError.commandFailed("Could not clear the isolated PF anchor: \(result.combinedOutput)")
        }
    }

    func release(token: String?) throws {
        guard let token else { return }
        let result = try FixedCommandRunner.run(
            executable: "/sbin/pfctl",
            arguments: ["-X", token]
        )
        guard result.status == 0 else {
            throw EnforcerError.commandFailed("Could not release the PF reference token: \(result.combinedOutput)")
        }
    }
}

enum EnforcerError: Error, LocalizedError {
    case invalidArguments(String)
    case requiresRoot
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidArguments(let message), .commandFailed(let message): return message
        case .requiresRoot: return "The installed enforcer must run as root."
        }
    }
}
