import Darwin
import Foundation

/// Safe reads and atomic writes for files that control enforcement.
public enum FileStore {
    /// Reads a regular file. Refuses symlinks, other file types, a wrong
    /// owner, group- or world-writable files, and files over `maximumSize`.
    public static func read(at url: URL, expectedOwner: uid_t?, maximumSize: Int) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ELOOP {
                throw MastboundError.unsafeFile("Refusing a symbolic link: \(url.path)")
            }
            throw posixError()
        }
        defer { close(descriptor) }

        // Check the opened descriptor, not the path, so the file cannot be
        // swapped between the check and the read.
        var fileStat = stat()
        guard fstat(descriptor, &fileStat) == 0 else { throw posixError() }
        guard (fileStat.st_mode & S_IFMT) == S_IFREG else {
            throw MastboundError.unsafeFile("Refusing a non-regular file: \(url.path)")
        }
        if let expectedOwner, fileStat.st_uid != expectedOwner {
            throw MastboundError.unsafeFile("Unexpected owner for \(url.path).")
        }
        guard (fileStat.st_mode & 0o022) == 0 else {
            throw MastboundError.unsafeFile("Refusing a group- or world-writable file: \(url.path)")
        }
        guard fileStat.st_size <= maximumSize else {
            throw MastboundError.fileTooLarge("\(url.path) is larger than \(maximumSize) bytes.")
        }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            guard count > 0 else { throw posixError() }
            guard data.count + count <= maximumSize else {
                throw MastboundError.fileTooLarge("\(url.path) grew past \(maximumSize) bytes.")
            }
            data.append(buffer, count: count)
        }
        return data
    }

    /// Writes `data` to a new temp file in the same folder, syncs it, renames
    /// it over `url`, then syncs the folder. A crash leaves the old file or
    /// the new file, never a partial one. The folder must already exist.
    public static func writeAtomically(
        _ data: Data,
        to url: URL,
        mode: mode_t,
        owner: uid_t,
        group: gid_t
    ) throws {
        let directory = url.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).tmp"
        )
        let descriptor = open(
            temporary.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode
        )
        guard descriptor >= 0 else { throw posixError() }

        do {
            try data.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                var written = 0
                while written < bytes.count {
                    let count = Darwin.write(descriptor, base.advanced(by: written), bytes.count - written)
                    guard count > 0 else { throw posixError() }
                    written += count
                }
            }
            guard fchmod(descriptor, mode) == 0,
                  fchown(descriptor, owner, group) == 0,
                  fsync(descriptor) == 0 else { throw posixError() }
        } catch {
            close(descriptor)
            unlink(temporary.path)
            throw error
        }
        guard close(descriptor) == 0 else {
            unlink(temporary.path)
            throw posixError()
        }
        guard rename(temporary.path, url.path) == 0 else {
            let error = posixError()
            unlink(temporary.path)
            throw error
        }
        try syncDirectory(directory)
    }

    private static func syncDirectory(_ directory: URL) throws {
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw posixError() }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw posixError() }
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
