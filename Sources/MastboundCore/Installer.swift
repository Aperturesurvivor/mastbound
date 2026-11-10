import Darwin
import Foundation

/// Copies the daemon, the tool and the list into the root-owned helper folder
/// and writes the launchd plist. It never touches the state, so an upgrade
/// keeps a running commitment (I9). Calling `launchctl` is the caller's job.
public enum Installer {
    public static let executableNames = ["mastboundd", "mastboundctl"]

    /// - Parameter sourceDirectory: folder that holds `mastboundd`,
    ///   `mastboundctl` and `adult-domains.txt` (the app's Resources folder,
    ///   or a build folder).
    public static func installFiles(from sourceDirectory: URL, paths: Paths, bundledListSHA256: String) throws {
        // Check everything before changing anything.
        let listData = try FileStore.read(
            at: sourceDirectory.appendingPathComponent(Paths.listFileName),
            expectedOwner: nil, maximumSize: Blocklist.maximumBytes
        )
        _ = try Blocklist.load(listData, expectedSHA256: bundledListSHA256)
        var executables: [(name: String, data: Data)] = []
        for name in executableNames {
            let source = sourceDirectory.appendingPathComponent(name)
            let data = try FileStore.read(at: source, expectedOwner: nil, maximumSize: 64 * 1024 * 1024)
            guard data.starts(with: [0xCF, 0xFA, 0xED, 0xFE]) || data.starts(with: [0xCA, 0xFE, 0xBA, 0xBE]) else {
                throw MastboundError.unsafeFile("\(source.path) is not a Mach-O executable.")
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
