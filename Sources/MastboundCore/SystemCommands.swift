import Darwin
import Foundation

/// Runs fixed system programs with fixed arguments. Never runs a shell.
public enum SystemCommands {
    public struct Result: Sendable {
        public var status: Int32
        public var output: String
        /// True if the program did not finish in time and was killed.
        public var timedOut: Bool
    }

    /// Runs `executable` and waits at most `timeout` seconds. A program that
    /// hangs (for example a DNS flush on a busy system) is killed, so the
    /// daemon loop never stops on it.
    @discardableResult
    public static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 10) throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()

        // Read on another thread, so a full pipe cannot block the wait.
        let output = OutputBox()
        let reader = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            output.set(pipe.fileHandleForReading.readDataToEndOfFile())
            reader.signal()
        }

        var timedOut = false
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            kill(process.processIdentifier, SIGKILL)
            _ = finished.wait(timeout: .now() + 2)
        }
        // A killed program's children may keep the pipe open; do not wait long.
        _ = reader.wait(timeout: .now() + 1)
        return Result(
            status: timedOut ? -1 : process.terminationStatus,
            output: String(decoding: output.get(), as: UTF8.self),
            timedOut: timedOut
        )
    }

    public static func flushDNSCaches() {
        _ = try? run("/usr/bin/dscacheutil", ["-flushcache"], timeout: 5)
        _ = try? run("/usr/bin/killall", ["-HUP", "mDNSResponder"], timeout: 5)
    }
}

private final class OutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func set(_ new: Data) { lock.withLock { data = new } }
    func get() -> Data { lock.withLock { data } }
}
