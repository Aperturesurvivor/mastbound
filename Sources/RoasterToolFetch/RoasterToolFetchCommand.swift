import Darwin
import Foundation
import RoasterCore

private enum ToolFetchError: Error, LocalizedError {
    case invalidArguments
    case unauthorizedParent
    case curlUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidArguments:
            return "Usage: roaster-tool-fetch [--head] https://<scheduled-domain>/<path>"
        case .unauthorizedParent:
            return "Tool access is available only to processes launched by the signed OpenAI Codex app."
        case .curlUnavailable:
            return "The system curl executable is unavailable."
        }
    }
}

private enum CodexAncestry {
    static let expectedIdentifier = "com.openai.codex"
    static let expectedTeamIdentifier = "2DC432GLL2"

    static func isAuthorized() -> Bool {
        var processID = getppid()
        for _ in 0..<16 where processID > 1 {
            if let executablePath = executablePath(for: processID),
               let bundlePath = appBundlePath(containing: executablePath),
               hasExpectedSignature(bundlePath) {
                return true
            }
            guard let next = parentProcessID(for: processID), next != processID else {
                break
            }
            processID = next
        }
        return false
    }

    private static func parentProcessID(for processID: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.stride)
        let actualSize = proc_pidinfo(
            processID,
            PROC_PIDTBSDINFO,
            0,
            &info,
            expectedSize
        )
        guard actualSize == expectedSize else { return nil }
        return pid_t(info.pbi_ppid)
    }

    private static func executablePath(for processID: pid_t) -> String? {
        var buffer = [UInt8](repeating: 0, count: 4_096)
        let length = proc_pidpath(processID, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
    }

    private static func appBundlePath(containing executablePath: String) -> String? {
        guard let marker = executablePath.range(of: ".app/Contents/") else { return nil }
        return String(executablePath[..<marker.lowerBound]) + ".app"
    }

    private static func hasExpectedSignature(_ bundlePath: String) -> Bool {
        let verification = run(
            "/usr/bin/codesign",
            ["--verify", "--deep", "--strict", bundlePath]
        )
        guard verification.status == 0 else { return false }

        let details = run(
            "/usr/bin/codesign",
            ["-d", "--verbose=4", bundlePath]
        )
        guard details.status == 0 else { return false }
        let lines = details.output.split(whereSeparator: \.isNewline)
        return lines.contains("Identifier=\(expectedIdentifier)")
            && lines.contains("TeamIdentifier=\(expectedTeamIdentifier)")
    }

    private static func run(_ executable: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let output = String(
                data: pipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            return (process.terminationStatus, output)
        } catch {
            return (1, "")
        }
    }
}

@main
private struct RoasterToolFetchCommand {
    static func main() {
        do {
            var arguments = Array(CommandLine.arguments.dropFirst())
            let useHead = arguments.first == "--head"
            if useHead { arguments.removeFirst() }
            guard arguments.count == 1 else { throw ToolFetchError.invalidArguments }
            guard CodexAncestry.isAuthorized() else { throw ToolFetchError.unauthorizedParent }
            let target = try ToolAccessPolicy.validatedURL(arguments[0])

            let curlPath = "/usr/bin/curl"
            guard FileManager.default.isExecutableFile(atPath: curlPath) else {
                throw ToolFetchError.curlUnavailable
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: curlPath)
            var curlArguments = [
                "--disable",
                "--silent",
                "--show-error",
                "--fail-with-body",
                "--connect-timeout", "10",
                "--max-time", "30",
                "--max-filesize", "26214400",
                "--proto", "=https",
                "--proto-redir", "=https",
                "--doh-url", "https://cloudflare-dns.com/dns-query",
                "--user-agent", "ScreenTimeRoasterToolFetch/1.0",
            ]
            if useHead { curlArguments.append("--head") }
            curlArguments.append(contentsOf: ["--url", target.absoluteString])
            process.arguments = curlArguments
            process.environment = [
                "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            ]
            process.standardInput = FileHandle.standardInput
            process.standardOutput = FileHandle.standardOutput
            process.standardError = FileHandle.standardError
            try process.run()
            process.waitUntilExit()
            exit(process.terminationStatus)
        } catch {
            FileHandle.standardError.write(Data("roaster-tool-fetch: \(error.localizedDescription)\n".utf8))
            exit(2)
        }
    }
}
