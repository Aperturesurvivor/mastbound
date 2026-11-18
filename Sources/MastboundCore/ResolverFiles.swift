import Darwin
import Foundation

/// Per-domain files in `/etc/resolver` (see resolver(5)). `/etc/hosts` only
/// answers address lookups. Safari also asks for HTTPS records (type 65); the
/// system sends that question to the real DNS server, and the answer carries
/// the site's addresses as hints, which Safari then uses. A resolver file for
/// a domain sends every question for it and its subdomains to a server that
/// does not exist, so the HTTPS record fails too, while `/etc/hosts` still
/// answers the address lookup with `0.0.0.0`.
///
/// macOS stops publishing its DNS setup at somewhere between 6,000 and
/// 6,500 resolver files, so only the most visited domains get one
/// (`ResolverRanking`). Every listed domain stays in `/etc/hosts`.
///
/// Ownership: a file whose name is a wanted domain is always made exactly
/// Mastbound's, whatever it held before (a file with a blocked domain's name
/// can only be a way around the block). A file with any other name is
/// Mastbound's only if it starts with `marker`; other files, for example a
/// VPN's, are never changed or removed.
public enum ResolverFiles {
    public static let marker = "# Mastbound: managed file, removed when the commitment ends.\n"
    public static let content = marker + "nameserver 127.0.0.1\nport 9\ntimeout 1\n"
    /// How many domains get a file. Keep well under the macOS limit.
    public static let limit = 4_000

    /// Names that must never get a file: a mistake in the data would break
    /// Bonjour, a VPN or local names for the whole Mac.
    static let protectedSuffixes = ["local", "localhost", "arpa", "internal", "lan", "home", "intranet", "corp", "ts.net"]

    public struct Result: Equatable, Sendable {
        public var changed = false
        public var warnings: [String] = []
    }

    /// The domains that get a file: the first `limit` ranked domains that are
    /// in `blocked`, without duplicates or protected names.
    public static func wanted(ranking: [String], blocked: Set<String>, limit: Int = limit) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        result.reserveCapacity(min(limit, ranking.count))
        for domain in ranking where result.count < limit {
            let name = domain.lowercased()
            guard blocked.contains(name), !isProtected(name), seen.insert(name).inserted,
                  (try? DomainValidator.validate(name)) != nil else { continue }
            result.append(name)
        }
        return result
    }

    static func isProtected(_ name: String) -> Bool {
        protectedSuffixes.contains { name == $0 || name.hasSuffix("." + $0) }
    }

    /// Signatures of the wanted files after a sync, so a later tick can see
    /// an in-place edit with one `lstat` per file.
    public struct Snapshot: Equatable, Sendable {
        var directory: FileSignature?
        var files: [String: FileSignature]
    }

    /// True if nothing changed since `snapshot` was taken for `wanted`.
    static func isUnchanged(directory: URL, wanted: [String], snapshot: Snapshot) -> Bool {
        guard (try? FileSignature(of: directory)) == snapshot.directory, snapshot.files.count == wanted.count else { return false }
        for name in wanted {
            guard let old = snapshot.files[name],
                  (try? FileSignature(of: directory.appendingPathComponent(name))) == old else { return false }
        }
        return true
    }

    /// Makes the files in `directory` match `wanted` exactly. Errors for one
    /// file become warnings, so the other files still get written.
    public static func sync(directory: URL, wanted: [String], owner: uid_t, group: gid_t) throws -> (result: Result, snapshot: Snapshot) {
        var result = Result()
        let wantedSet = Set(wanted)
        var directoryStat = stat()
        if lstat(directory.path, &directoryStat) != 0 {
            guard errno == ENOENT else { throw MastboundError.posix(directory, "inspect") }
            if wantedSet.isEmpty { return (result, Snapshot(directory: nil, files: [:])) }
            guard mkdir(directory.path, 0o755) == 0 || errno == EEXIST else {
                throw MastboundError.posix(directory, "create")
            }
            guard lchown(directory.path, owner, group) == 0 else { throw MastboundError.posix(directory, "set the owner of") }
            guard lstat(directory.path, &directoryStat) == 0 else { throw MastboundError.posix(directory, "inspect") }
        }
        guard (directoryStat.st_mode & S_IFMT) == S_IFDIR else {
            throw MastboundError.unsafeFile("\(directory.path) is not a real folder.")
        }
        guard directoryStat.st_uid == owner, directoryStat.st_mode & 0o022 == 0 else {
            throw MastboundError.unsafeFile("\(directory.path) is not owned by root or can be written by others.")
        }

        // Folder entries, by lowercased name: APFS is usually case-insensitive.
        var entries: [String: String] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
            entries[name.lowercased()] = name
        }
        var wrote = false
        for (key, name) in entries {
            let file = directory.appendingPathComponent(name)
            if wantedSet.contains(key) {
                if name == key, hasExactContent(file, owner: owner, group: group) { continue }
                if !isOurs(file) {
                    result.warnings.append("\(file.path) held other settings for a blocked domain; it was replaced.")
                }
                if !remove(file, into: &result) { continue }
                entries[key] = nil
            } else if isOurs(file) {
                if remove(file, into: &result) { entries[key] = nil }
            }
        }
        for name in wanted where entries[name] == nil {
            do {
                try writeNew(directory.appendingPathComponent(name), owner: owner, group: group)
                wrote = true
                result.changed = true
            } catch {
                result.warnings.append("Resolver file not written: \(error.localizedDescription)")
            }
        }
        if wrote { syncDirectory(directory) }

        var files: [String: FileSignature] = [:]
        for name in wanted {
            if let signature = try? FileSignature(of: directory.appendingPathComponent(name)) { files[name] = signature }
        }
        return (result, Snapshot(directory: try? FileSignature(of: directory), files: files))
    }

    /// Removes every Mastbound file. Leaves the folder and other files.
    /// Throws if any of them could not be removed.
    public static func removeAll(directory: URL) throws -> Bool {
        var directoryStat = stat()
        guard lstat(directory.path, &directoryStat) == 0 else {
            guard errno == ENOENT else { throw MastboundError.posix(directory, "inspect") }
            return false
        }
        guard (directoryStat.st_mode & S_IFMT) == S_IFDIR else { return false }
        var changed = false
        for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
            let file = directory.appendingPathComponent(name)
            guard isOurs(file) else { continue }
            guard unlink(file.path) == 0 || errno == ENOENT else { throw MastboundError.posix(file, "remove") }
            changed = true
        }
        return changed
    }

    private static func remove(_ file: URL, into result: inout Result) -> Bool {
        guard unlink(file.path) == 0 || errno == ENOENT else {
            result.warnings.append("Could not remove \(file.path): \(String(cString: strerror(errno)))")
            return false
        }
        result.changed = true
        return true
    }

    private static func isOurs(_ file: URL) -> Bool {
        var fileStat = stat()
        guard lstat(file.path, &fileStat) == 0, (fileStat.st_mode & S_IFMT) == S_IFREG,
              fileStat.st_size >= marker.utf8.count, fileStat.st_size <= 4_096 else { return false }
        let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        let expected = Array(marker.utf8)
        var buffer = [UInt8](repeating: 0, count: expected.count)
        return read(descriptor, &buffer, expected.count) == expected.count && buffer == expected
    }

    private static func hasExactContent(_ file: URL, owner: uid_t, group: gid_t) -> Bool {
        var fileStat = stat()
        guard lstat(file.path, &fileStat) == 0, (fileStat.st_mode & S_IFMT) == S_IFREG,
              fileStat.st_uid == owner, fileStat.st_gid == group,
              fileStat.st_mode & 0o7777 == 0o644 else { return false }
        return (try? FileStore.read(at: file, expectedOwner: owner, maximumSize: 4_096)) == Data(content.utf8)
    }

    /// Temp file, then rename, so a crash leaves no file or a whole one. The
    /// folder is synced once after all writes.
    private static func writeNew(_ file: URL, owner: uid_t, group: gid_t) throws {
        let temporary = file.deletingLastPathComponent().appendingPathComponent(".mastbound-\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { throw MastboundError.posix(temporary, "create") }
        let bytes = Array(content.utf8)
        let ok = Darwin.write(descriptor, bytes, bytes.count) == bytes.count
            && fchown(descriptor, owner, group) == 0 && fchmod(descriptor, 0o644) == 0 && fsync(descriptor) == 0
        close(descriptor)
        guard ok, rename(temporary.path, file.path) == 0 else {
            unlink(temporary.path)
            throw MastboundError.posix(file, "write")
        }
    }

    private static func syncDirectory(_ directory: URL) {
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { return }
        fsync(descriptor)
        close(descriptor)
    }
}
