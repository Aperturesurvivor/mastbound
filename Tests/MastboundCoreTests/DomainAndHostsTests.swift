import Foundation
import Testing
@testable import MastboundCore

@Suite("Domain grammar")
struct DomainTests {
    @Test("Normalizes, deduplicates and sorts")
    func normalizes() throws {
        #expect(try DomainValidator.normalize([" WWW.Example.com. ", "www.example.com", "b.example"], maximumCount: 10)
            == ["b.example", "www.example.com"])
    }

    @Test("Refuses injection, wildcards, IPs and bad labels", arguments: [
        "example.com\n127.0.0.1 evil.com", "192.0.2.10", "*.example.com", "-bad.example.com",
        "bad-.example.com", "a..example.com", "localhost", "exa mple.com", "ex\tample.com",
        String(repeating: "a", count: 64) + ".com", "ünicode.com",
    ])
    func refusesBadInput(input: String) {
        #expect(throws: MastboundError.self) { try DomainValidator.normalize([input], maximumCount: 10) }
    }

    @Test("Refuses more domains than the limit")
    func countLimit() {
        #expect(throws: MastboundError.self) {
            try DomainValidator.normalize(["a.example", "b.example"], maximumCount: 1)
        }
    }
}

@Suite("I10 hosts section")
struct HostsSectionTests {
    @Test("I10: other lines are kept and rendering twice gives the same file")
    func preservesAndIsIdempotent() throws {
        let original = "127.0.0.1 localhost\n10.0.0.2 internal.example\n"
        let first = try HostsSection.render(existing: original, blockedDomains: ["x.example"])
        #expect(try HostsSection.render(existing: first, blockedDomains: ["x.example"]) == first)
        #expect(first.hasPrefix(original))
        #expect(try HostsSection.managedDomains(in: first) == ["x.example"])
    }

    @Test("I10: an empty list removes only the Mastbound section")
    func removalRestoresOriginal() throws {
        let original = "127.0.0.1 localhost\n10.0.0.2 internal.example\n"
        let blocked = try HostsSection.render(existing: original, blockedDomains: ["x.example"])
        #expect(try HostsSection.render(existing: blocked, blockedDomains: []) == original)
    }

    @Test("I10: the legacy Screen Time Roaster section is left unchanged")
    func legacySectionUntouched() throws {
        let legacy = "# BEGIN SCREEN TIME ROASTER MAC — MANAGED BLOCK\n0.0.0.0\told.example\n# END SCREEN TIME ROASTER MAC — MANAGED BLOCK\n"
        let original = "127.0.0.1 localhost\n\n" + legacy
        let rendered = try HostsSection.render(existing: original, blockedDomains: ["x.example"])
        #expect(rendered.contains(legacy))
        #expect(try HostsSection.render(existing: rendered, blockedDomains: []) == original)
    }

    @Test("I4: damaged markers are refused, not edited", arguments: [
        "\(HostsSection.beginMarker)\n",
        "\(HostsSection.endMarker)\n",
        "\(HostsSection.endMarker)\n\(HostsSection.beginMarker)\n",
        "\(HostsSection.beginMarker)\n\(HostsSection.endMarker)\n\(HostsSection.beginMarker)\n\(HostsSection.endMarker)\n",
    ])
    func refusesDamagedMarkers(body: String) {
        let text = "127.0.0.1 localhost\n" + body
        #expect(throws: MastboundError.self) { try HostsSection.render(existing: text, blockedDomains: ["x.example"]) }
        #expect(throws: MastboundError.self) { try HostsSection.managedDomains(in: text) }
    }

    @Test("I1: a list the size of the shipped list renders one IPv4 and one IPv6 line per domain")
    func largeList() throws {
        let domains = (0..<80_000).map { "site\($0).example.com" }
        let rendered = try HostsSection.render(existing: "127.0.0.1 localhost\n", blockedDomains: domains)
        #expect(try HostsSection.managedDomains(in: rendered).count == domains.count)
        #expect(rendered.components(separatedBy: "\n::\t").count - 1 == domains.count)
    }
}

@Suite("I12 blocklist")
struct BlocklistTests {
    private let canonical = Data("a.example\nb.example\n".utf8)

    @Test("I12: canonical data parses and its hash is stable")
    func parsesCanonical() throws {
        let list = try Blocklist.parse(canonical)
        #expect(list.domains == ["a.example", "b.example"])
        #expect(try Blocklist.load(canonical, expectedSHA256: list.sha256) == list)
    }

    @Test("I12: a wrong hash is refused")
    func refusesWrongHash() {
        #expect(throws: MastboundError.self) { try Blocklist.load(canonical, expectedSHA256: sampleSHA) }
    }

    @Test("I12: non-canonical data is refused", arguments: [
        "b.example\na.example\n", "a.example\na.example\n", "A.example\n", "a.example", "a.example\n\n", "", "bad_name.example\n",
    ])
    func refusesNonCanonical(text: String) {
        #expect(throws: MastboundError.self) { try Blocklist.parse(Data(text.utf8)) }
    }

    @Test("Upstream hosts sources keep only valid block rows")
    func readsHostsSources() throws {
        let source = Data("""
        # comment
        0.0.0.0 adult.example
        127.0.0.1 second.example # trailing comment
        0.0.0.0 invalid_name.example
        0.0.0.0 localhost
        ::1 localhost
        1.2.3.4 unrelated.example
        0.0.0.0
        """.utf8)
        #expect(try Blocklist.domainsFromHostsSource(source) == ["adult.example", "second.example"])
    }
}

@Suite("I1 enforcement")
struct EnforcementTests {
    @Test("I1: idle blocks nothing; active blocks the union of all lists")
    func blockedDomains() throws {
        let active = try EngineState.idle.starting(durationSeconds: day, listSHA256: sampleSHA, at: reading(mono: 0, wall: 0))
        #expect(try Enforcement.blockedDomains(for: .idle, lists: [["a.example"]]).isEmpty)
        #expect(try Enforcement.blockedDomains(for: active, lists: [["b.example", "a.example"], ["a.example", "c.example"]])
            == ["a.example", "b.example", "c.example"])
    }

    @Test("I1: two copies of a large list do not pass the size limit")
    func unionDeduplicatesBeforeLimit() throws {
        let active = try EngineState.idle.starting(durationSeconds: day, listSHA256: sampleSHA, at: reading(mono: 0, wall: 0))
        let list = (0..<200_000).map { "s\($0).example" }
        #expect(try Enforcement.blockedDomains(for: active, lists: [list, list]).count == 200_000)
    }
}
