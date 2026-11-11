import Darwin
import Foundation

/// Copies the daemon, the tool and the list into the root-owned helper folder
/// and writes the launchd plist. It never touches the state, so an upgrade
/// keeps a running commitment (I9). Calling `launchctl` is the caller's job.
public enum Installer {
    public static let executableNames = ["mastboundd", "mastboundctl"]

    /// - Parameter sourceDirectory: folder that holds `mastboundd`,
    ///   `mastboundctl` and `adult-domains.txt`. It must be a trusted
    ///   folder (see `requireTrustedSource`), for example a root-owned copy
    ///   of the app's Resources folder. A build folder in a home folder is
    ///   refused on the real system.
    public static func installFiles(from sourceDirectory: URL, paths: Paths, bundledListSHA256: String) throws {
        // Check everything before changing anything.
        let source = try requireTrustedSource(sourceDirectory, paths: paths)
        let listData = try FileStore.read(
            at: source.appendingPathComponent(Paths.listFileName),
            expectedOwner: paths.owner, maximumSize: Blocklist.maximumBytes
        )
        _ = try Blocklist.load(listData, expectedSHA256: bundledListSHA256)
        var executables: [(name: String, data: Data)] = []
        for name in executableNames {
            let file = source.appendingPathComponent(name)
            let data = try FileStore.read(at: file, expectedOwner: paths.owner, maximumSize: 64 * 1024 * 1024)
            guard data.starts(with: [0xCF, 0xFA, 0xED, 0xFE]) || data.starts(with: [0xCA, 0xFE, 0xBA, 0xBE]) else {
                throw MastboundError.unsafeFile("\(file.path) is not a Mach-O executable.")
            }
            executables.append((name, data))
        }

        try makeDirectory(paths.helperDirectory, paths: paths)
        try makeDirectory(paths.stateDirectory, paths: paths)
        for executable in executables {
            try FileStore.writeAtomically(
                executable.data, to: paths.helperDirectory.appendingPathComponent(executable.name),
                mode: 0o755, owner: paths.owner, group: paths.group
            )
        }
        try FileStore.writeAtomically(listData, to: paths.installedList, mode: 0o644, owner: paths.owner, group: paths.group)
        try FileStore.writeAtomically(
            try launchDaemonPlist(paths: paths), to: paths.launchDaemonPlist,
            mode: 0o644, owner: paths.owner, group: paths.group
        )
    }

    /// Removes the helper files and the plist. Call only after
    /// `Engine.prepareUninstall()` succeeded.
    public static func removeFiles(paths: Paths) throws {
        let files = executableNames.map { paths.helperDirectory.appendingPathComponent($0) }
            + [paths.installedList, paths.launchDaemonPlist, paths.lockFile]
        for file in files where unlink(file.path) != 0 && errno != ENOENT {
            throw MastboundError.posix(file, "remove")
        }
        for directory in [paths.helperDirectory, paths.stateDirectory] where rmdir(directory.path) != 0 && errno != ENOENT {
            throw MastboundError.unsafeFile("Could not remove \(directory.path); it is not empty.")
        }
    }

    public static func launchDaemonPlist(paths: Paths) throws -> Data {
        let plist: [String: Any] = [
            "Label": Paths.launchDaemonLabel,
            "ProgramArguments": [paths.installedDaemon.path],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ThrottleInterval": 10,
        ]
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    /// Creates `url` if needed, then requires it to be a real folder with the
    /// expected owner and no group or world write access. A missing parent
    /// (for example `/Library/PrivilegedHelperTools` on a clean Mac) is
    /// created the same way; an existing parent must not be writable by
    /// other users, or someone else could swap the folder.
    private static func makeDirectory(_ url: URL, paths: Paths) throws {
        let parent = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parent.path) {
            try makeDirectory(parent, paths: paths)
        } else {
            try requireNotWritableByOthers(parent)
        }
        if mkdir(url.path, 0o755) != 0 && errno != EEXIST {
            throw MastboundError.posix(url, "create")
        }
        var fileStat = stat()
        guard lstat(url.path, &fileStat) == 0, (fileStat.st_mode & S_IFMT) == S_IFDIR else {
            throw MastboundError.unsafeFile("\(url.path) is not a folder.")
        }
        if fileStat.st_uid != paths.owner || fileStat.st_gid != paths.group {
            guard chown(url.path, paths.owner, paths.group) == 0 else {
                throw MastboundError.posix(url, "set the owner of")
            }
        }
        guard chmod(url.path, 0o755) == 0 else { throw MastboundError.posix(url, "set the mode of") }
    }

    /// Root copies `mastboundd` from the source folder and later runs it. If
    /// another user could change that folder or its files, they could get
    /// their code run as root. So the resolved folder and every folder above
    /// it must be owned by root or `paths.owner` and not writable by other
    /// users (a sticky folder such as `/tmp` is allowed). The files are
    /// checked for owner and mode when they are read. Returns the resolved
    /// folder, so the checked path is the path that is read.
    static func requireTrustedSource(_ directory: URL, paths: Paths) throws -> URL {
        guard let resolved = realpath(directory.path, nil) else { throw MastboundError.posix(directory, "resolve") }
        defer { free(resolved) }
        let source = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
        var current = source
        while true {
            var fileStat = stat()
            guard lstat(current.path, &fileStat) == 0 else { throw MastboundError.posix(current, "inspect") }
            guard (fileStat.st_mode & S_IFMT) == S_IFDIR else {
                throw MastboundError.unsafeFile("\(current.path) is not a folder.")
            }
            guard fileStat.st_uid == 0 || fileStat.st_uid == paths.owner else {
                throw MastboundError.unsafeFile(
                    "Install source \(source.path) is not trusted: \(current.path) has another owner. Copy the build to a root-owned folder first."
                )
            }
            let writableByOthers = (fileStat.st_mode & 0o022) != 0
            let sticky = (fileStat.st_mode & S_ISVTX) != 0
            guard !writableByOthers || (sticky && current != source) else {
                throw MastboundError.unsafeFile(
                    "Install source \(source.path) is not trusted: \(current.path) is writable by other users. Copy the build to a root-owned folder first."
                )
            }
            if current.path == "/" { break }
            current = current.deletingLastPathComponent()
        }
        return source
    }

    /// Allows the sticky bit (as on `/tmp`), which stops others from
    /// replacing entries they do not own.
    private static func requireNotWritableByOthers(_ url: URL) throws {
        var fileStat = stat()
        guard stat(url.path, &fileStat) == 0 else { throw MastboundError.posix(url, "inspect") }
        let writableByOthers = (fileStat.st_mode & 0o022) != 0
        let sticky = (fileStat.st_mode & S_ISVTX) != 0
        guard !writableByOthers || sticky else {
            throw MastboundError.unsafeFile("\(url.path) is writable by other users.")
        }
    }
}
