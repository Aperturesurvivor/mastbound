import Darwin
import Foundation
import Testing
@testable import MastboundCore

private let google = HostsRedirect(name: "www.google.com", ipv4: "216.239.38.120", ipv6: "2001:4860:4802:32::78")
private let ddg = HostsRedirect(name: "duckduckgo.com", ipv4: "52.149.247.1", ipv6: nil)
private let rows = [google, ddg]

private func section(_ hosts: String) -> [String] {
    let lines = hosts.split(separator: "\n").map(String.init)
    guard let begin = lines.firstIndex(of: HostsSection.beginMarker),
          let end = lines.firstIndex(of: HostsSection.endMarker) else { return [] }
    return Array(lines[(begin + 1)..<end])
}

private func resolverNames(_ f: Fixture) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: f.paths.resolverDirectory.path)) ?? []).sorted()
}

@Suite("Forced SafeSearch")
struct SafeSearchTests {
    @Test("Start writes the SafeSearch rows; IPv6 is :: when there is none")
    func startWritesRows() throws {
        let f = try Fixture()
        try f.engine(safeSearch: rows).start(durationSeconds: day)
        let body = section(try f.hosts())
        #expect(body.contains("216.239.38.120\twww.google.com"))
        #expect(body.contains("2001:4860:4802:32::78\twww.google.com"))
        #expect(body.contains("52.149.247.1\tduckduckgo.com"))
        #expect(body.contains("::\tduckduckgo.com"))
        #expect(body.contains("# Forced SafeSearch"))
        #expect(try f.blocked() == f.list) // the block itself is unchanged
        #expect(try f.hosts().hasPrefix(originalHosts))
    }

    @Test("Search host names get a resolver file; bare domains do not")
    func resolverFiles() throws {
        let f = try Fixture()
        try f.engine(safeSearch: rows).start(durationSeconds: day)
        let names = resolverNames(f)
        #expect(names.contains("www.google.com"))
        #expect(!names.contains("duckduckgo.com"))
        #expect(try String(contentsOf: f.paths.resolverDirectory.appendingPathComponent("www.google.com"), encoding: .utf8) == ResolverFiles.content)
    }

    @Test("Idle: no section, no files")
    func idleWritesNothing() throws {
        let f = try Fixture()
        try f.engine(safeSearch: rows).reconcile()
        #expect(try f.hosts() == originalHosts)
        #expect(resolverNames(f).isEmpty)
    }

    @Test("End of the commitment removes the rows and the files")
    func endRemoves() throws {
        let f = try Fixture()
        try f.engine(safeSearch: rows).start(durationSeconds: hour)
        f.clock.advance(hour + 10)
        #expect(try f.engine(safeSearch: rows).reconcile().phase == .idle)
        #expect(try f.hosts() == originalHosts)
        #expect(resolverNames(f).isEmpty)
    }

    @Test("A hand-edited SafeSearch row is repaired on the next tick")
    func repairsEdit() throws {
        let f = try Fixture()
        let engine = f.engine(safeSearch: rows)
        try engine.start(durationSeconds: day)
        let good = try f.hosts()
        let edited = good.replacingOccurrences(of: "216.239.38.120\twww.google.com", with: "142.250.1.1\twww.google.com")
        #expect(edited != good)
        try Data(edited.utf8).write(to: f.paths.hostsFile)
        f.clock.advance(5)
        #expect(try engine.reconcile().hostsChanged)
        #expect(try f.hosts() == good)
    }

    @Test("A deleted SafeSearch resolver file comes back")
    func repairsResolverFile() throws {
        let f = try Fixture()
        let engine = f.engine(safeSearch: rows)
        try engine.start(durationSeconds: day)
        try FileManager.default.removeItem(at: f.paths.resolverDirectory.appendingPathComponent("www.google.com"))
        f.clock.advance(5)
        #expect(try engine.reconcile().resolverFilesChanged)
        #expect(resolverNames(f).contains("www.google.com"))
    }

    @Test("A name that is also blocked stays blocked, with no redirect")
    func blockWins() throws {
        let f = try Fixture(list: ["a.example", "www.google.com"])
        try f.engine(safeSearch: rows).start(durationSeconds: day)
        let body = section(try f.hosts())
        #expect(body.contains("0.0.0.0\twww.google.com"))
        #expect(!body.contains("216.239.38.120\twww.google.com"))
        #expect(body.filter { $0.hasSuffix("\twww.google.com") }.count == 2)
    }

    @Test("Uninstall after the end leaves no SafeSearch row")
    func uninstallClean() throws {
        let f = try Fixture()
        try f.engine(safeSearch: rows).start(durationSeconds: hour)
        f.clock.advance(hour + 10)
        let engine = f.engine(safeSearch: rows)
        try engine.reconcile()
        try engine.prepareUninstall()
        #expect(try !f.hosts().contains("216.239.38.120"))
    }

    @Test("Bad addresses and bad names are refused")
    func refusesBadRows() throws {
        #expect(throws: (any Error).self) {
            try HostsSection.render(existing: "", blockedDomains: [], redirects: [HostsRedirect(name: "www.google.com", ipv4: "999.1.1.1", ipv6: nil)])
        }
        #expect(throws: (any Error).self) {
            try HostsSection.render(existing: "", blockedDomains: [], redirects: [HostsRedirect(name: "www.google.com", ipv4: "216.239.38.120", ipv6: "nope")])
        }
        #expect(throws: (any Error).self) {
            try HostsSection.render(existing: "", blockedDomains: [], redirects: [HostsRedirect(name: "bad name", ipv4: "216.239.38.120", ipv6: nil)])
        }
    }

    @Test("Duplicate and upper-case names give one row pair")
    func dedupe() throws {
        let upper = HostsRedirect(name: "WWW.Google.com", ipv4: "216.239.38.120", ipv6: nil)
        let text = try HostsSection.render(existing: "", blockedDomains: [], redirects: [google, upper, google])
        #expect(section(text).filter { $0.hasSuffix("\twww.google.com") }.count == 2)
    }

    @Test("Built-in list: Google, Bing and DuckDuckGo, valid, sorted, no duplicates")
    func builtInList() throws {
        let names = SafeSearch.redirects.map(\.name)
        #expect(Set(names).count == names.count)
        #expect(names == names.sorted())
        for name in ["google.com", "www.google.com", "www.google.co.uk", "google.de", "bing.com", "www.bing.com", "duckduckgo.com", "html.duckduckgo.com"] {
            #expect(names.contains(name), "missing \(name)")
        }
        #expect(GoogleDomains.all.count >= 150)
        _ = try HostsSection.render(existing: "", blockedDomains: [], redirects: SafeSearch.redirects)
        let resolver = SafeSearch.resolverNames(for: SafeSearch.redirects)
        #expect(!resolver.contains("google.com"))
        #expect(!resolver.contains("bing.com"))
        #expect(resolver.contains("www.google.com"))
        #expect(resolver.allSatisfy { !ResolverFiles.isProtected($0) })
        // Total resolver files stay well under the macOS limit (6,000).
        #expect(ResolverFiles.limit + resolver.count < 5_000)
    }

    @Test("The release engine has SafeSearch on by default")
    func onByDefault() throws {
        let f = try Fixture()
        let clock = f.clock
        let engine = Engine(paths: f.paths, bundledListSHA256: f.listSHA, clock: { clock.now() })
        try engine.start(durationSeconds: day)
        #expect(try f.hosts().contains("216.239.38.120\twww.google.com"))
        #expect(try f.hosts().contains("150.171.28.16\twww.bing.com"))
    }
}
