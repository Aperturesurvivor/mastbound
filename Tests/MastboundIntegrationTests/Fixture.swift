import Darwin
import Foundation
@testable import MastboundCore

let hour: Double = 3600
let day: Double = 86_400
let originalHosts = "127.0.0.1\tlocalhost\n255.255.255.255\tbroadcasthost\n::1             localhost\n"

/// A clock the test moves by hand. Safe to use from several threads.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var boot = 0
    private var mono: Double = 1000
    private var wall: Double = 0

    func now() -> ClockReading {
        lock.withLock {
            ClockReading(
                wall: Date(timeIntervalSince1970: 1_800_000_000 + wall),
                monotonicNanoseconds: UInt64(mono * 1_000_000_000),
                bootSessionID: "boot-\(boot)"
            )
        }
    }
    func advance(_ seconds: Double) { lock.withLock { mono += seconds; wall += seconds } }
    func changeWallClock(by seconds: Double) { lock.withLock { wall += seconds } }
    /// Reboot after `offSeconds` with the Mac turned off.
    func reboot(offSeconds: Double) { lock.withLock { boot += 1; mono = 20; wall += offSeconds } }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

/// A complete Mastbound layout in a new temp folder.
struct Fixture {
    let root: URL
    let paths: Paths
    let clock = TestClock()
    let flushes = Counter()
    let list: [String]
    let listSHA: String

    init(list: [String] = ["a.example", "b.example", "c.example"]) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("mastbound-it-\(UUID().uuidString)")
        paths = .testing(root: root)
        for directory in [root, paths.stateDirectory, paths.helperDirectory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        }
        try FileStore.writeAtomically(Data(originalHosts.utf8), to: paths.hostsFile, mode: 0o644, owner: getuid(), group: getgid())
        let data = try Blocklist.serialize(list)
        try FileStore.writeAtomically(data, to: paths.installedList, mode: 0o644, owner: getuid(), group: getgid())
        self.list = try Blocklist.parse(data).domains
        listSHA = try Blocklist.parse(data).sha256
    }

    /// A new engine, as after a daemon restart. `listSHA` can be changed to
    /// act as a newer build.
    /// SafeSearch is off unless a test asks for it (see SafeSearchTests).
    func engine(listSHA: String? = nil, safeSearch: [HostsRedirect] = []) -> Engine {
        let clock = self.clock, flushes = self.flushes
        return Engine(paths: paths, bundledListSHA256: listSHA ?? self.listSHA,
                      clock: { clock.now() }, afterHostsChange: { flushes.increment() },
                      safeSearch: safeSearch)
    }

    func hosts() throws -> String { try String(contentsOf: paths.hostsFile, encoding: .utf8) }
    func blocked() throws -> [String] { try HostsSection.managedDomains(in: hosts()) }
    func state() throws -> EngineState {
        try EngineState.decode(FileStore.read(at: paths.stateFile, expectedOwner: nil, maximumSize: 1 << 20))
    }
    func mode(_ url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }
    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    /// Writes a fake installable build (Mach-O header + filler) to a new folder.
    func makeBuild(list: [String]) throws -> (directory: URL, sha: String) {
        let directory = root.appendingPathComponent("build-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        for name in Installer.executableNames {
            try Data([0xCF, 0xFA, 0xED, 0xFE] + Array(name.utf8)).write(to: directory.appendingPathComponent(name))
        }
        let data = try Blocklist.serialize(list)
        try data.write(to: directory.appendingPathComponent(Paths.listFileName))
        return (directory, try Blocklist.parse(data).sha256)
    }
}
