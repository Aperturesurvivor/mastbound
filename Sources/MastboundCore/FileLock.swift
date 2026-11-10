import Darwin
import Foundation

/// An exclusive `flock` on one file. The daemon and `mastboundctl` both take
/// it around every read-change-write of the state, so neither can overwrite
/// the other's change.
enum FileLock {
    static func withExclusiveLock<T>(at url: URL, _ body: () throws -> T) throws -> T {
        let descriptor = open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw MastboundError.posix(url, "open") }
        defer { close(descriptor) } // closing releases the lock
        while flock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else { throw MastboundError.posix(url, "lock") }
        }
        return try body()
    }
}
