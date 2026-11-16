import Darwin
import Foundation

/// The password-free way to cancel an early end. Any user can create the
/// request file; the daemon sees it on its next tick, cancels the early end
/// and removes the file. Cancelling only makes the block last longer, so this
/// is not a way around the commitment.
public enum CancelRequest {
    /// Creates the request. Works without root.
    public static func write(paths: Paths) throws {
        let descriptor = open(paths.cancelRecoveryRequest.path, O_WRONLY | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o644)
        if descriptor < 0 {
            if errno == EEXIST || errno == ELOOP { return } // already requested
            throw MastboundError.posix(paths.cancelRecoveryRequest, "create")
        }
        close(descriptor)
    }

    static func isPresent(paths: Paths) -> Bool {
        var fileStat = stat()
        return lstat(paths.cancelRecoveryRequest.path, &fileStat) == 0
    }

    /// `unlink` removes the name only, so a symbolic link placed here cannot
    /// make root delete anything else.
    static func clear(paths: Paths) {
        _ = unlink(paths.cancelRecoveryRequest.path)
    }
}
