import Darwin
import Foundation

/// Identity of a file's current contents, from `lstat`. An atomic replace
/// changes the inode; an in-place edit changes the size or the modification
/// time (nanoseconds on APFS).
struct FileSignature: Equatable, Sendable {
    var device: dev_t
    var inode: ino_t
    var size: off_t
    var modifiedSeconds: Int
    var modifiedNanoseconds: Int
    var mode: mode_t
    var owner: uid_t
    var group: gid_t

    init(of url: URL) throws {
        var fileStat = stat()
        guard lstat(url.path, &fileStat) == 0 else {
            throw MastboundError.posix(url, "inspect")
        }
        device = fileStat.st_dev
        inode = fileStat.st_ino
        size = fileStat.st_size
        modifiedSeconds = fileStat.st_mtimespec.tv_sec
        modifiedNanoseconds = fileStat.st_mtimespec.tv_nsec
        mode = fileStat.st_mode
        owner = fileStat.st_uid
        group = fileStat.st_gid
    }
}

/// Memory that lets a daemon tick skip unchanged work. Only an optimization:
/// an empty cache gives the same results, more slowly.
final class EngineCache: @unchecked Sendable {
    private let lock = NSLock()
    private var lists: [String: (signature: FileSignature, list: Blocklist)] = [:]
    private var unionID: String?
    private var unionDomains: [String] = []
    private var unionResolverDomains: [String] = []
    private var hosts: (signature: FileSignature, blockID: String)?
    private var resolver: (snapshot: ResolverFiles.Snapshot, blockID: String)?

    func list(path: String, signature: FileSignature) -> Blocklist? {
        lock.withLock { lists[path].flatMap { $0.signature == signature ? $0.list : nil } }
    }

    func setList(path: String, signature: FileSignature, list: Blocklist) {
        lock.withLock { lists[path] = (signature, list) }
    }

    func union(id: String) -> (domains: [String], resolverDomains: [String])? {
        lock.withLock { unionID == id ? (unionDomains, unionResolverDomains) : nil }
    }

    func setUnion(id: String, domains: [String], resolverDomains: [String]) {
        lock.withLock { unionID = id; unionDomains = domains; unionResolverDomains = resolverDomains }
    }

    /// True when the resolver files are exactly as the last sync left them
    /// for this block: same folder signature and same signature per file.
    func resolverUnchanged(directory: URL, wanted: [String], blockID: String) -> Bool {
        guard let saved = lock.withLock({ resolver }), saved.blockID == blockID else { return false }
        return ResolverFiles.isUnchanged(directory: directory, wanted: wanted, snapshot: saved.snapshot)
    }

    func setResolver(snapshot: ResolverFiles.Snapshot, blockID: String) {
        lock.withLock { resolver = (snapshot, blockID) }
    }

    func clearResolver() {
        lock.withLock { resolver = nil }
    }

    func verifiedHosts(signature: FileSignature, blockID: String) -> Bool {
        lock.withLock { hosts?.signature == signature && hosts?.blockID == blockID }
    }

    func setVerifiedHosts(signature: FileSignature, blockID: String) {
        lock.withLock { hosts = (signature, blockID) }
    }
}
