import Darwin
import Foundation
import Testing
@testable import MastboundCore

/// Ranked domains: "z.example" and "x.example" are not in the fixture list.
private let ranking = ["z.example", "c.example", "x.example", "a.example", "b.example"]

private extension Fixture {
    func resolverEngine(limit: Int = 10, ranking rank: [String]? = nil) -> Engine {
        let clock = self.clock, flushes = self.flushes
        return Engine(paths: paths, bundledListSHA256: listSHA,
                      clock: { clock.now() }, afterHostsChange: { flushes.increment() },
                      resolverRanking: rank ?? ranking, resolverLimit: limit, safeSearch: [])
    }
    var resolverDir: URL { paths.resolverDirectory }
    func resolverFile(_ name: String) -> URL { resolverDir.appendingPathComponent(name) }
    func resolverNames() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: resolverDir.path)) ?? []).sorted()
    }
    func text(_ name: String) throws -> String { try String(contentsOf: resolverFile(name), encoding: .utf8) }
    func writeForeign(_ name: String, _ text: String = "nameserver 192.0.2.1\n") throws {
        try FileManager.default.createDirectory(at: resolverDir, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: resolverFile(name))
    }
}

@Suite("Resolver files")
struct ResolverFileTests {
    @Test("Start: files for blocked ranked domains, in rank order, exact content, mode 0644")
    func start() throws {
        let f = try Fixture()
        try f.resolverEngine().start(durationSeconds: day)
        // Rank order is c, a, b. z and x are ranked but not blocked: no file.
        #expect(f.resolverNames() == ["a.example", "b.example", "c.example"])
        for name in f.resolverNames() {
            #expect(try f.text(name) == ResolverFiles.content)
            #expect(try f.mode(f.resolverFile(name)) == 0o644)
        }
        #expect(!f.exists(f.resolverFile("z.example")))
        #expect(!f.exists(f.resolverFile("x.example")))
    }

    @Test("Start: the limit is respected and the best ranked domains win")
    func limit() throws {
        let f = try Fixture()
        try f.resolverEngine(limit: 2).start(durationSeconds: day)
        #expect(f.resolverNames() == ["a.example", "c.example"])
        #expect(try f.blocked() == f.list) // every domain is still in hosts
    }

    @Test("Idle: reconcile creates no resolver folder")
    func idleCreatesNothing() throws {
        let f = try Fixture()
        let report = try f.resolverEngine().reconcile()
        #expect(report.phase == .idle)
        #expect(!report.resolverFilesChanged)
        #expect(!f.exists(f.resolverDir))
    }

    @Test("A foreign file with a wanted name is replaced with Mastbound's content and a warning names it")
    func foreignWantedName() throws {
        let f = try Fixture()
        try f.writeForeign("c.example", "nameserver 192.0.2.1\n# mine\n")
        let engine = f.resolverEngine()
        try engine.start(durationSeconds: day) // start() drops its report
        #expect(try f.text("c.example") == ResolverFiles.content)
        #expect(try f.mode(f.resolverFile("c.example")) == 0o644)
        // Put a foreign file there again, while the engine runs: the report has the warning.
        try FileManager.default.removeItem(at: f.resolverFile("c.example"))
        try f.writeForeign("c.example", "nameserver 192.0.2.1\n# mine\n")
        let report = try engine.reconcile()
        #expect(report.resolverFilesChanged)
        #expect(report.warnings.contains { $0.contains(f.resolverFile("c.example").path) })
        #expect(try f.text("c.example") == ResolverFiles.content)
        #expect(try f.text("a.example") == ResolverFiles.content)
        #expect(try f.text("b.example") == ResolverFiles.content)
    }

    @Test("A foreign file with another name is never changed or removed")
    func foreignOtherName() throws {
        let f = try Fixture()
        try f.writeForeign("corp.internal")
        try f.writeForeign("other.example", "# Mastbound is not the first line\n" + ResolverFiles.marker)
        let engine = f.resolverEngine()
        try engine.start(durationSeconds: 2 * hour)
        f.clock.advance(hour)
        try f.resolverEngine().reconcile()
        let expectedA = "nameserver 192.0.2.1\n"
        #expect(try f.text("corp.internal") == expectedA)
        f.clock.advance(hour)
        #expect(try f.resolverEngine().reconcile().phase == .idle)
        #expect(try f.text("corp.internal") == expectedA)
        #expect(f.exists(f.resolverFile("other.example")))
        #expect(f.resolverNames() == ["corp.internal", "other.example"])
    }

    @Test("Repair: a deleted file comes back")
    func repairDeleted() throws {
        let f = try Fixture()
        try f.resolverEngine().start(durationSeconds: day)
        try FileManager.default.removeItem(at: f.resolverFile("a.example"))
        let report = try f.resolverEngine().reconcile()
        #expect(report.resolverFilesChanged)
        #expect(try f.text("a.example") == ResolverFiles.content)
        #expect(try f.mode(f.resolverFile("a.example")) == 0o644)
    }

    @Test("Repair: a marked file with wrong content, replaced by rename, is restored")
    func repairWrongContent() throws {
        let f = try Fixture()
        let engine = f.resolverEngine() // same engine, so the cache is in play
        try engine.start(durationSeconds: day)
        try FileStore.writeAtomically(
            Data((ResolverFiles.marker + "nameserver 8.8.8.8\n").utf8), to: f.resolverFile("b.example"),
            mode: 0o644, owner: getuid(), group: getgid())
        let report = try engine.reconcile()
        #expect(report.resolverFilesChanged)
        #expect(try f.text("b.example") == ResolverFiles.content)
        // A second tick has nothing to do.
        #expect(try !engine.reconcile().resolverFilesChanged)
    }

    @Test("Recovering: the files stay during the 72-hour wait")
    func recovering() throws {
        let f = try Fixture()
        try f.resolverEngine().start(durationSeconds: 30 * day)
        try f.resolverEngine().requestRecovery(confirmation: Policy.recoveryPhrase)
        f.clock.advance(Policy.recoveryDelaySeconds - 1)
        #expect(try f.resolverEngine().reconcile().phase == .recovering)
        #expect(f.resolverNames() == ["a.example", "b.example", "c.example"])
        f.clock.advance(1)
        #expect(try f.resolverEngine().reconcile().phase == .idle)
        #expect(f.resolverNames().isEmpty)
    }

    @Test("End of the commitment: Mastbound files go, foreign files stay")
    func endRemoves() throws {
        let f = try Fixture()
        try f.writeForeign("corp.internal")
        try f.writeForeign("not-listed.example", "nameserver 192.0.2.7\n")
        try f.resolverEngine().start(durationSeconds: 2 * hour)
        #expect(f.resolverNames() == ["a.example", "b.example", "c.example", "corp.internal", "not-listed.example"])
        f.clock.advance(2 * hour)
        #expect(try f.resolverEngine().reconcile().phase == .idle)
        #expect(f.resolverNames() == ["corp.internal", "not-listed.example"])
        #expect(try f.text("not-listed.example") == "nameserver 192.0.2.7\n")
        #expect(try f.hosts() == originalHosts)
    }

    @Test("prepareUninstall when idle removes Mastbound files and keeps foreign files")
    func uninstall() throws {
        let f = try Fixture()
        try f.resolverEngine().start(durationSeconds: hour)
        f.clock.advance(hour)
        try f.resolverEngine().reconcile()
        #expect(f.resolverNames().isEmpty)
        // Put files back by hand, with a foreign one beside them.
        try Data(ResolverFiles.content.utf8).write(to: f.resolverFile("a.example"))
        try Data(ResolverFiles.content.utf8).write(to: f.resolverFile("not-in-list.example"))
        try f.writeForeign("corp.internal")
        try f.resolverEngine().prepareUninstall()
        #expect(f.resolverNames() == ["corp.internal"])
        #expect(try f.text("corp.internal") == "nameserver 192.0.2.1\n")
    }

    @Test("A symlink as the resolver folder: no throw, hosts block applied, warning, nothing written through it")
    func symlinkFolder() throws {
        let f = try Fixture()
        let target = f.root.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: f.resolverDir, withDestinationURL: target)
        try f.resolverEngine().start(durationSeconds: day)
        let report = try f.resolverEngine().reconcile()
        #expect(try f.blocked() == f.list)
        #expect(report.warnings.contains { $0.contains("Resolver files not updated") })
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
        // The link itself is untouched.
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: f.resolverDir.path)) == target.path)
    }

    @Test("wanted: rank order, only blocked domains, limit")
    func wantedUnit() {
        let blocked: Set<String> = ["a.test", "b.test", "d.test", "e.test"]
        let ranked = ["e.test", "c.test", "a.test", "x.test", "d.test", "b.test"]
        #expect(ResolverFiles.wanted(ranking: ranked, blocked: blocked, limit: 10) == ["e.test", "a.test", "d.test", "b.test"])
        #expect(ResolverFiles.wanted(ranking: ranked, blocked: blocked, limit: 3) == ["e.test", "a.test", "d.test"])
        #expect(ResolverFiles.wanted(ranking: ranked, blocked: blocked, limit: 0).isEmpty)
        #expect(ResolverFiles.wanted(ranking: ranked, blocked: [], limit: 5).isEmpty)
        #expect(ResolverFiles.wanted(ranking: [], blocked: blocked, limit: 5).isEmpty)
    }

    @Test("Flush: happens when files change, not on a second reconcile with no change")
    func flushes() throws {
        let f = try Fixture()
        let engine = f.resolverEngine()
        try engine.start(durationSeconds: day)
        let afterStart = f.flushes.value
        #expect(afterStart >= 2) // hosts and resolver files
        f.clock.advance(5)
        #expect(try !engine.reconcile().resolverFilesChanged)
        #expect(f.flushes.value == afterStart)
        // A fresh engine (empty cache) checks the files and still does not flush.
        #expect(try !f.resolverEngine().reconcile().resolverFilesChanged)
        #expect(f.flushes.value == afterStart)
        // A change in the folder alone causes exactly one flush.
        try FileManager.default.removeItem(at: f.resolverFile("c.example"))
        #expect(try engine.reconcile().resolverFilesChanged)
        #expect(f.flushes.value == afterStart + 1)
        #expect(try !engine.reconcile().resolverFilesChanged)
        #expect(f.flushes.value == afterStart + 1)
    }
}

// MARK: - Edge cases

private extension Fixture {
    func inode(_ name: String) -> UInt64 {
        ((try? FileManager.default.attributesOfItem(atPath: resolverFile(name).path))?[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
    }
    /// Changes the bytes of a file without replacing it: same inode.
    func editInPlace(_ name: String, _ text: String) throws {
        let handle = try FileHandle(forWritingTo: resolverFile(name))
        defer { try? handle.close() }
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(text.utf8))
    }
    func domainNames(_ count: Int) -> [String] { (0..<count).map { String(format: "d%05d.example", $0) } }
}

@Suite("Resolver files: edge cases")
struct ResolverFileEdgeTests {
    // MARK: In-place edits, same engine across ticks

    @Test("In-place edit of the content (same inode) is restored on the next tick")
    func inPlaceContent() throws {
        let f = try Fixture()
        let engine = f.resolverEngine()
        try engine.start(durationSeconds: day)
        let before = f.inode("a.example")
        try f.editInPlace("a.example", ResolverFiles.marker + "nameserver 8.8.8.8\n")
        #expect(f.inode("a.example") == before)
        let report = try engine.reconcile()
        #expect(report.resolverFilesChanged)
        #expect(try f.text("a.example") == ResolverFiles.content)
        #expect(try f.mode(f.resolverFile("a.example")) == 0o644)
        #expect(try !engine.reconcile().resolverFilesChanged)
    }

    @Test("In-place removal of the marker (same inode) is restored, with a warning")
    func inPlaceMarkerRemoved() throws {
        let f = try Fixture()
        let engine = f.resolverEngine()
        try engine.start(durationSeconds: day)
        let before = f.inode("b.example")
        try f.editInPlace("b.example", "nameserver 8.8.8.8\n")
        #expect(f.inode("b.example") == before)
        let report = try engine.reconcile()
        #expect(report.resolverFilesChanged)
        #expect(report.warnings.contains { $0.contains(f.resolverFile("b.example").path) })
        #expect(try f.text("b.example") == ResolverFiles.content)
        #expect(try f.mode(f.resolverFile("b.example")) == 0o644)
        let again = try engine.reconcile()
        #expect(!again.resolverFilesChanged)
        #expect(again.warnings.isEmpty)
    }

    @Test("chmod 0666 in place (same inode, same bytes) is restored to 0644")
    func inPlaceChmod() throws {
        let f = try Fixture()
        let engine = f.resolverEngine()
        try engine.start(durationSeconds: day)
        let before = f.inode("c.example")
        #expect(chmod(f.resolverFile("c.example").path, 0o666) == 0)
        #expect(f.inode("c.example") == before)
        let report = try engine.reconcile()
        #expect(report.resolverFilesChanged)
        #expect(try f.text("c.example") == ResolverFiles.content)
        #expect(try f.mode(f.resolverFile("c.example")) == 0o644)
        #expect(try !engine.reconcile().resolverFilesChanged)
    }

    // MARK: Odd files with a wanted name

    @Test("A 0-byte file and a marker-only file with a wanted name are replaced")
    func emptyAndMarkerOnly() throws {
        let f = try Fixture()
        try FileManager.default.createDirectory(at: f.resolverDir, withIntermediateDirectories: true)
        try Data().write(to: f.resolverFile("a.example"))
        try Data(ResolverFiles.marker.utf8).write(to: f.resolverFile("b.example"))
        try f.resolverEngine().start(durationSeconds: day)
        for name in ["a.example", "b.example", "c.example"] {
            #expect(try f.text(name) == ResolverFiles.content)
            #expect(try f.mode(f.resolverFile(name)) == 0o644)
        }
        #expect(f.resolverNames() == ["a.example", "b.example", "c.example"])
    }

    @Test("A leftover .mastbound-*.tmp with the marker is removed; one without it stays")
    func leftoverTemp() throws {
        let f = try Fixture()
        try FileManager.default.createDirectory(at: f.resolverDir, withIntermediateDirectories: true)
        let ours = ".mastbound-\(UUID().uuidString).tmp"
        let theirs = ".mastbound-\(UUID().uuidString).tmp"
        try Data(ResolverFiles.content.utf8).write(to: f.resolverFile(ours))
        try Data("nameserver 192.0.2.1\n".utf8).write(to: f.resolverFile(theirs))
        try f.resolverEngine().start(durationSeconds: day)
        #expect(!f.exists(f.resolverFile(ours)))
        #expect(f.exists(f.resolverFile(theirs)))
        #expect(f.resolverNames() == ([theirs, "a.example", "b.example", "c.example"]).sorted())
    }

    @Test("A wanted name that is a directory: not removed, warning, other files written, hosts applied")
    func wantedNameIsDirectory() throws {
        let f = try Fixture()
        let directory = f.resolverFile("c.example")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: directory.appendingPathComponent("inner"))
        let engine = f.resolverEngine()
        try engine.start(durationSeconds: day)
        let report = try engine.reconcile()
        #expect(try f.blocked() == f.list)
        #expect(report.warnings.contains { $0.contains(directory.path) })
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) && isDirectory.boolValue)
        #expect(try String(contentsOf: directory.appendingPathComponent("inner"), encoding: .utf8) == "keep")
        #expect(try f.text("a.example") == ResolverFiles.content)
        #expect(try f.text("b.example") == ResolverFiles.content)
        // Same result on the next tick, and the end of the commitment leaves the directory alone.
        f.clock.advance(day)
        #expect(try engine.reconcile().phase == .idle)
        #expect(f.exists(directory.appendingPathComponent("inner")))
        #expect(try f.hosts() == originalHosts)
    }

    @Test("A wanted name that is a symlink: never followed; the link is replaced by a real file")
    func wantedNameIsSymlink() throws {
        let f = try Fixture()
        let target = f.root.appendingPathComponent("target.txt")
        try Data("secret\n".utf8).write(to: target)
        try FileManager.default.createDirectory(at: f.resolverDir, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: f.resolverFile("c.example"), withDestinationURL: target)
        let engine = f.resolverEngine()
        try engine.start(durationSeconds: day)
        // Nothing was written through the link.
        #expect(try String(contentsOf: target, encoding: .utf8) == "secret\n")
        // The link itself was replaced by a regular file with Mastbound's content.
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: f.resolverFile("c.example").path)) == nil)
        #expect(try f.text("c.example") == ResolverFiles.content)
        #expect(try f.mode(f.resolverFile("c.example")) == 0o644)
        #expect(try f.blocked() == f.list)
        // A dangling link behaves the same.
        try FileManager.default.removeItem(at: f.resolverFile("a.example"))
        try FileManager.default.createSymbolicLink(at: f.resolverFile("a.example"), withDestinationURL: f.root.appendingPathComponent("missing"))
        #expect(try engine.reconcile().resolverFilesChanged)
        #expect(try f.text("a.example") == ResolverFiles.content)
        #expect(!f.exists(f.root.appendingPathComponent("missing")))
    }

    // MARK: Ranking rules

    @Test("wanted: duplicates and case variants give one entry; one-label and invalid names are dropped")
    func wantedDedupAndInvalid() {
        let blocked: Set<String> = ["a.example", "b.example", "a", "bad_name.example"]
        let ranked = ["A.Example", "a.example", "a", "bad_name.example", "B.EXAMPLE", "b.example", "A.EXAMPLE"]
        #expect(ResolverFiles.wanted(ranking: ranked, blocked: blocked, limit: 10) == ["a.example", "b.example"])
    }

    @Test("A ranking with duplicates and a case variant (A.Example) gives one file")
    func duplicatesGiveOneFile() throws {
        let f = try Fixture()
        let rank = ["A.Example", "z.example", "a.example", "c.example", "C.example", "b.example", "a.example"]
        try f.resolverEngine(ranking: rank).start(durationSeconds: day)
        #expect(f.resolverNames() == ["a.example", "b.example", "c.example"])
        #expect(try f.text("a.example") == ResolverFiles.content)
    }

    @Test("Protected names never get a file; they stay in hosts")
    func protectedNames() throws {
        let list = ["a.example", "printer.local", "x.ts.net", "foo.arpa", "m.corp", "nas.home", "api.internal", "ts.net", "hp.lan", "d.localhost", "w.intranet"]
        let f = try Fixture(list: list)
        let rank = ["printer.local", "x.ts.net", "foo.arpa", "m.corp", "nas.home", "api.internal", "ts.net",
                    "hp.lan", "d.localhost", "w.intranet", "a.example"]
        try f.resolverEngine(ranking: rank).start(durationSeconds: day)
        #expect(f.resolverNames() == ["a.example"])
        #expect(Set(try f.blocked()) == Set(list))
        for name in rank where name != "a.example" {
            #expect(ResolverFiles.isProtected(name))
        }
        #expect(!ResolverFiles.isProtected("notlocal.example"))
        #expect(!ResolverFiles.isProtected("mylocal"))
    }

    @Test("Shipped ResolverRanking: no protected names, no duplicates, all valid")
    func shippedRanking() throws {
        let domains = ResolverRanking.domains
        #expect(!domains.isEmpty)
        #expect(Set(domains.map { $0.lowercased() }).count == domains.count)
        #expect(domains.allSatisfy { $0 == $0.lowercased() })
        let protected = domains.filter(ResolverFiles.isProtected)
        #expect(protected.isEmpty, "protected: \(protected.prefix(5))")
        let invalid = domains.filter { (try? DomainValidator.validate($0)) == nil }
        #expect(invalid.isEmpty, "invalid: \(invalid.prefix(5))")
    }

    @Test("No entry of Resources/resolver-exclude.txt is in ResolverRanking.domains")
    func excludeFile() throws {
        // #filePath is <root>/Tests/MastboundIntegrationTests/ResolverFileTests.swift
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("Resources/resolver-exclude.txt"), encoding: .utf8)
        let excluded = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        #expect(excluded.count > 10)
        let ranked = Set(ResolverRanking.domains.map { $0.lowercased() })
        let leaked = excluded.filter { ranked.contains($0.lowercased()) }
        #expect(leaked.isEmpty, "excluded but ranked: \(leaked)")
    }

    // MARK: Folder safety

    @Test("A group-writable resolver folder: warning, no files, hosts still applies")
    func groupWritableFolder() throws {
        let f = try Fixture()
        try FileManager.default.createDirectory(at: f.resolverDir, withIntermediateDirectories: true)
        #expect(chmod(f.resolverDir.path, 0o775) == 0)
        let engine = f.resolverEngine()
        try engine.start(durationSeconds: day)
        let report = try engine.reconcile()
        #expect(report.warnings.contains { $0.contains("Resolver files not updated") })
        #expect(f.resolverNames().isEmpty)
        #expect(try f.blocked() == f.list)
        #expect(!report.resolverFilesChanged)
    }

    // MARK: Upgrade, VPN

    @Test("The ranking shrinks after an upgrade: stale Mastbound files are removed")
    func rankingShrinks() throws {
        let f = try Fixture()
        try f.resolverEngine(ranking: ["c.example", "a.example", "b.example"]).start(durationSeconds: day)
        #expect(f.resolverNames() == ["a.example", "b.example", "c.example"])
        try f.writeForeign("vpn.example")
        let flushesBefore = f.flushes.value
        let report = try f.resolverEngine(ranking: ["c.example"]).reconcile()
        #expect(report.resolverFilesChanged)
        #expect(f.resolverNames() == ["c.example", "vpn.example"])
        #expect(try f.text("c.example") == ResolverFiles.content)
        #expect(f.flushes.value == flushesBefore + 1)
        #expect(try f.blocked() == f.list)
    }

    @Test("A VPN-style foreign file added while files are in place: no flush, file untouched")
    func vpnFileAddedLater() throws {
        let f = try Fixture()
        let engine = f.resolverEngine()
        try engine.start(durationSeconds: day)
        let flushesBefore = f.flushes.value
        try f.writeForeign("vpn.corp.example", "nameserver 10.0.0.1\nsearch corp.example\n")
        let data = try Data(contentsOf: f.resolverFile("vpn.corp.example"))
        let inodeBefore = f.inode("vpn.corp.example")
        for _ in 0..<2 {
            f.clock.advance(5)
            let report = try engine.reconcile()
            #expect(!report.resolverFilesChanged)
            #expect(report.warnings.isEmpty)
            #expect(f.flushes.value == flushesBefore)
        }
        #expect(try Data(contentsOf: f.resolverFile("vpn.corp.example")) == data)
        #expect(f.inode("vpn.corp.example") == inodeBefore)
        #expect(f.resolverNames() == ["a.example", "b.example", "c.example", "vpn.corp.example"])
    }

    // MARK: Uninstall

    @Test("prepareUninstall during a commitment refuses and the files stay")
    func uninstallRefusedWhileActive() throws {
        let f = try Fixture()
        let engine = f.resolverEngine()
        try engine.start(durationSeconds: day)
        let hosts = try f.hosts()
        #expect(throws: MastboundError.self) { try engine.prepareUninstall() }
        #expect(f.resolverNames() == ["a.example", "b.example", "c.example"])
        #expect(try f.hosts() == hosts)
        #expect(f.exists(f.paths.stateFile))
    }

    @Test("prepareUninstall with an unremovable Mastbound file throws; hosts and state are untouched",
          .enabled(if: getuid() != 0))
    func uninstallFailsOnRemoval() throws {
        let f = try Fixture()
        let engine = f.resolverEngine()
        try engine.start(durationSeconds: hour)
        f.clock.advance(hour)
        #expect(try engine.reconcile().phase == .idle)
        #expect(f.resolverNames().isEmpty)
        // Leave a Mastbound file and a hosts block behind, as after a crash.
        try Data(ResolverFiles.content.utf8).write(to: f.resolverFile("a.example"))
        let blockedHosts = try HostsSection.render(existing: f.hosts(), blockedDomains: ["a.example"])
        try Data(blockedHosts.utf8).write(to: f.paths.hostsFile)
        let hostsBefore = try Data(contentsOf: f.paths.hostsFile)
        let stateBefore = try Data(contentsOf: f.paths.stateFile)
        let statusBefore = try Data(contentsOf: f.paths.statusFile)

        #expect(chmod(f.resolverDir.path, 0o555) == 0)
        defer { chmod(f.resolverDir.path, 0o755) }
        #expect(throws: MastboundError.self) { try engine.prepareUninstall() }
        #expect(try Data(contentsOf: f.paths.hostsFile) == hostsBefore)
        #expect(try Data(contentsOf: f.paths.stateFile) == stateBefore)
        #expect(try Data(contentsOf: f.paths.statusFile) == statusBefore)
        #expect(f.exists(f.resolverFile("a.example")))

        // With the folder writable again, the uninstall goes through.
        #expect(chmod(f.resolverDir.path, 0o755) == 0)
        try engine.prepareUninstall()
        #expect(f.resolverNames().isEmpty)
        #expect(try f.hosts() == originalHosts)
        #expect(!f.exists(f.paths.stateFile))
    }

    // MARK: Limit edges

    @Test("wanted: exactly limit and limit + 1 candidates")
    func limitEdgesUnit() {
        let names = (0..<6).map { "n\($0).example" }
        let blocked = Set(names)
        #expect(ResolverFiles.wanted(ranking: Array(names.prefix(5)), blocked: blocked, limit: 5) == Array(names.prefix(5)))
        #expect(ResolverFiles.wanted(ranking: names, blocked: blocked, limit: 5) == Array(names.prefix(5)))
        #expect(ResolverFiles.wanted(ranking: Array(names.prefix(4)), blocked: blocked, limit: 5) == Array(names.prefix(4)))
        #expect(ResolverFiles.limit == 4_000)
    }

    @Test("Engine with exactly limit and limit + 1 wanted domains")
    func limitEdgesEngine() throws {
        let names = (0..<6).map { "n\($0).example" }
        // Exactly the limit.
        let exact = try Fixture(list: Array(names.prefix(5)))
        try exact.resolverEngine(limit: 5, ranking: names).start(durationSeconds: day)
        #expect(exact.resolverNames() == Array(names.prefix(5)))
        // One over: the lowest ranked one gets no file but stays in hosts.
        let over = try Fixture(list: names)
        try over.resolverEngine(limit: 5, ranking: names).start(durationSeconds: day)
        #expect(over.resolverNames() == Array(names.prefix(5)))
        #expect(!over.exists(over.resolverFile(names[5])))
        #expect(try over.blocked() == names)
    }

    // MARK: Performance

    @Test("4,000 files: cold sync and warm tick; a warm tick with no change is under 200 ms")
    func performance() throws {
        let names = (0..<ResolverFiles.limit).map { String(format: "d%05d.example", $0) }
        let f = try Fixture(list: names)
        let clock = ContinuousClock()
        let engine = f.resolverEngine(limit: ResolverFiles.limit, ranking: names)

        let cold = try clock.measure { try engine.start(durationSeconds: day) }
        #expect(f.resolverNames().count == ResolverFiles.limit)

        f.clock.advance(5)
        var warmReport: Engine.Report?
        let warm = try clock.measure { warmReport = try engine.reconcile() }
        #expect(warmReport?.resolverFilesChanged == false)
        #expect(warmReport?.warnings.isEmpty == true)

        // A new engine has an empty cache: it checks every file's content.
        let fresh = f.resolverEngine(limit: ResolverFiles.limit, ranking: names)
        let checked = try clock.measure { _ = try fresh.reconcile() }
        let freshWarm = try clock.measure { _ = try fresh.reconcile() }

        print("PERF cold start (hosts + 4000 files): \(cold)")
        print("PERF warm tick, no change:            \(warm)")
        print("PERF new engine, files in place:      \(checked)")
        print("PERF second tick of that engine:      \(freshWarm)")
        #expect(warm < .milliseconds(200))
        #expect(freshWarm < .milliseconds(200))
    }
}
