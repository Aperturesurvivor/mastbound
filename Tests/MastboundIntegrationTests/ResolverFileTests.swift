import Darwin
import Foundation
import Testing
@testable import MastboundCore

/// Ranked domains: "z.example" and "x.example" are not in the fixture list.
private let ranking = ["z.example", "c.example", "x.example", "a.example", "b.example"]

private extension Fixture {
    func resolverEngine(limit: Int = 10) -> Engine {
        let clock = self.clock, flushes = self.flushes
        return Engine(paths: paths, bundledListSHA256: listSHA,
                      clock: { clock.now() }, afterHostsChange: { flushes.increment() },
                      resolverRanking: ranking, resolverLimit: limit)
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

    @Test("A foreign file with a wanted name is left unchanged and a warning names it")
    func foreignWantedName() throws {
        let f = try Fixture()
        let foreign = "nameserver 192.0.2.1\n# mine\n"
        try f.writeForeign("c.example", foreign)
        let before = try Data(contentsOf: f.resolverFile("c.example"))
        try f.resolverEngine().start(durationSeconds: day)
        let report = try f.resolverEngine().reconcile()
        #expect(try Data(contentsOf: f.resolverFile("c.example")) == before)
        #expect(report.warnings.contains { $0.contains(f.resolverFile("c.example").path) })
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
        try f.writeForeign("b.example", "nameserver 192.0.2.7\n")
        try f.resolverEngine().start(durationSeconds: 2 * hour)
        #expect(f.resolverNames() == ["a.example", "b.example", "c.example", "corp.internal"])
        f.clock.advance(2 * hour)
        #expect(try f.resolverEngine().reconcile().phase == .idle)
        #expect(f.resolverNames() == ["b.example", "corp.internal"])
        #expect(try f.text("b.example") == "nameserver 192.0.2.7\n")
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
        let blocked: Set<String> = ["a", "b", "d", "e"]
        let ranked = ["e", "c", "a", "x", "d", "b"]
        #expect(ResolverFiles.wanted(ranking: ranked, blocked: blocked, limit: 10) == ["e", "a", "d", "b"])
        #expect(ResolverFiles.wanted(ranking: ranked, blocked: blocked, limit: 3) == ["e", "a", "d"])
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
