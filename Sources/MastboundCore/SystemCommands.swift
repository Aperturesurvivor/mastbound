import Foundation

/// Runs fixed system programs with fixed arguments. Never runs a shell.
public enum SystemCommands {
    public struct Result: Sendable {
        public var status: Int32
        public var output: String
    }

    @discardableResult
    public static func run(_ executable: String, _ arguments: [String]) throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Result(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }

    public static func flushDNSCaches() {
        _ = try? run("/usr/bin/dscacheutil", ["-flushcache"])
        _ = try? run("/usr/bin/killall", ["-HUP", "mDNSResponder"])
    }
}
