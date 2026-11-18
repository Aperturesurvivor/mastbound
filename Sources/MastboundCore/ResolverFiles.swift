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
/// macOS stops publishing its DNS setup at somewhere between 5,000 and
/// 10,000 resolver files, so only the most visited domains get one
/// (`ResolverRanking`). Every listed domain stays in `/etc/hosts`.
///
/// Only files that start with `marker` are Mastbound's. Other files in the
/// folder are never changed or removed.
public enum ResolverFiles {
    public static let marker = "# Mastbound: managed file, removed when the commitment ends.\n"
    public static let content = marker + "nameserver 127.0.0.1\nport 9\ntimeout 1\n"
    /// How many domains get a file. Keep well under the macOS limit.
    public static let limit = 4_000

    public struct Result: Equatable, Sendable {
        public var changed = false
        public var warnings: [String] = []
    }

    /// The domains that get a file: the first `limit` ranked domains that are
    /// in `blocked`.
    public static func wanted(ranking: [String], blocked: Set<String>, limit: Int = limit) -> [String] {
        var result: [String] = []
        result.reserveCapacity(min(limit, ranking.count))
        for domain in ranking where result.count < limit && blocked.contains(domain) {
            result.append(domain)
        }
        return result
    }

    /// Makes Mastbound's files in `directory` match `wanted` exactly.
    public static func sync(directory: URL, wanted: [String], owner: uid_t, group: gid_t) throws -> Result {
        var result = Result()
        let wantedSet = Set(wanted)
        var directoryStat = stat()
        if lstat(directory.path, &directoryStat) != 0 {
            guard errno == ENOENT else { throw MastboundError.posix(directory, "inspect") }
            if wantedSet.isEmpty { return result }
            guard mkdir(directory.path, 0o755) == 0 || errno == EEXIST else {
                throw MastboundError.posix(directory, "create")
            }
            guard chown(directory.path, owner, group) == 0 else { throw MastboundError.posix(directory, "set the owner of") }
            guard lstat(directory.path, &directoryStat) == 0 else { throw MastboundError.posix(directory, "inspect") }
        }
        guard (directoryStat.st_mode & S_IFMT) == S_IFDIR else {
            throw MastboundError.unsafeFile("\(directory.path) is not a real folder.")
        }

        let entries = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        var present = Set<String>()
        for name in entries {
            let file = directory.appendingPathComponent(name)
            guard isOurs(file) else {
                if wantedSet.contains(name) {
                    result.warnings.append("\(file.path) is not Mastbound's file; it was left unchanged.")
                }
                continue
            }
            if wantedSet.contains(name), hasExactContent(file, owner: owner, group: group) {
                present.insert(name)
            } else {
                guard unlink(file.path) == 0 || errno == ENOENT else { throw MastboundError.posix(file, "remove") }
                result.changed = true
            }
        }
        let others = Set(entries).subtracting(present)
        for name in wanted where !present.contains(name) && !others.contains(name) {
            guard (try? DomainValidator.validate(name)) != nil else { continue }
            try writeNew(directory.appendingPathComponent(name), owner: owner, group: group)
            result.changed = true
        }
        // Files that were ours but had the wrong content were removed above;
        // write them again.
        for name in wanted where !present.contains(name) && others.contains(name) {
            let file = directory.appendingPathComponent(name)
            var fileStat = stat()
            if lstat(file.path, &fileStat) != 0 && errno == ENOENT {
                try writeNew(file, owner: owner, group: group)
                result.changed = true
            }
        }
        return result
    }

    /// Removes every Mastbound file. Leaves the folder and other files.
    public static func removeAll(directory: URL) throws -> Bool {
        try sync(directory: directory, wanted: [], owner: 0, group: 0).changed
    }

    private static func isOurs(_ file: URL) -> Bool {
        var fileStat = stat()
        guard lstat(file.path, &fileStat) == 0, (fileStat.st_mode & S_IFMT) == S_IFREG,
              fileStat.st_size <= 4_096 else { return false }
        guard let data = try? FileStore.read(at: file, expectedOwner: nil, maximumSize: 4_096) else { return false }
        return data.starts(with: Data(marker.utf8))
    }

    private static func hasExactContent(_ file: URL, owner: uid_t, group: gid_t) -> Bool {
        var fileStat = stat()
        guard lstat(file.path, &fileStat) == 0, fileStat.st_uid == owner, fileStat.st_gid == group,
              fileStat.st_mode & 0o777 == 0o644 else { return false }
        return (try? FileStore.read(at: file, expectedOwner: owner, maximumSize: 4_096)) == Data(content.utf8)
    }

    private static func writeNew(_ file: URL, owner: uid_t, group: gid_t) throws {
        let descriptor = open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { throw MastboundError.posix(file, "create") }
        defer { close(descriptor) }
        let bytes = Array(content.utf8)
        guard Darwin.write(descriptor, bytes, bytes.count) == bytes.count,
              fchown(descriptor, owner, group) == 0, fchmod(descriptor, 0o644) == 0 else {
            unlink(file.path)
            throw MastboundError.posix(file, "write")
        }
    }
}
