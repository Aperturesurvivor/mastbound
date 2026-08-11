import Testing
@testable import RoasterCore

@Test func preservesUnrelatedContentAndIsIdempotent() throws {
    let original = "127.0.0.1 localhost\n10.0.0.2 internal.example\n"
    let first = try HostsFileEditor.render(existing: original, blockedDomains: ["x.com"])
    let second = try HostsFileEditor.render(existing: first, blockedDomains: ["x.com"])
    #expect(first == second)
    #expect(first.contains("10.0.0.2 internal.example"))
    #expect(try HostsFileEditor.managedDomains(in: first) == ["x.com"])
    #expect(try HostsFileEditor.render(existing: first, blockedDomains: []) == original)
}

@Test func refusesMalformedMarkers() {
    let malformed = "127.0.0.1 localhost\n\(HostsFileEditor.beginMarker)\n"
    #expect(throws: (any Error).self) {
        try HostsFileEditor.render(existing: malformed, blockedDomains: ["x.com"])
    }
}

@Test func largeDomainSetRendersOneExactMappingPerDomain() throws {
    let domains = (0..<10_000).map { "site\($0).example.com" }
    let rendered = try HostsFileEditor.render(
        existing: "127.0.0.1 localhost\n",
        blockedDomains: domains
    )
    #expect(try HostsFileEditor.managedDomains(in: rendered).count == domains.count)
}
