import Darwin
import Foundation

/// Every error the core can raise. Callers must treat any of these as
/// "do not change enforcement" (fail closed).
public enum MastboundError: Error, LocalizedError, Equatable, Sendable {
    case invalidDomain(String)
    case invalidList(String)
    case invalidState(String)
    case notAllowed(String)
    case unsafeFile(String)
    case fileTooLarge(String)
    case malformedHostsSection(String)
    case fileSystem(String)

    public var errorDescription: String? {
        switch self {
        case .invalidDomain(let message), .invalidList(let message),
             .invalidState(let message), .notAllowed(let message),
             .unsafeFile(let message), .fileTooLarge(let message),
             .malformedHostsSection(let message), .fileSystem(let message):
            return message
        }
    }

    /// A system call failed on `url`. Reads `errno` at once, so call it
    /// directly after the failing call.
    public static func posix(_ url: URL, _ action: String) -> MastboundError {
        let code = errno
        return .fileSystem("Could not \(action) \(url.path): \(String(cString: strerror(code)))")
    }
}
