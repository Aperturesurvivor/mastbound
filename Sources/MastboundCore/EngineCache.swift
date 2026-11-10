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
    private var hosts: (signature: FileSignature, blockID: String)?

    func list(path: String, signature: FileSignature) -> Blocklist? {
        lock.withLock { lists[path].flatMap { $0.signature == signature ? $0.list : nil } }
    }

    func setList(path: String, signature: FileSignature, list: Blocklist) {
        lock.withLock { lists[path] = (signature, list) }
    }

    func union(id: String) -> [String]? {
        lock.withLock { unionID == id ? unionDomains : nil }
    }

    func setUnion(id: String, domains: [String]) {
        lock.withLock { unionID = id; unionDomains = domains }
    }

    func verifiedHosts(signature: FileSignature, blockID: String) -> Bool {
        lock.withLock { hosts?.signature == signature && hosts?.blockID == blockID }
    }

    func setVerifiedHosts(signature: FileSignature, blockID: String) {
        lock.withLock { hosts = (signature, blockID) }
    }
}
