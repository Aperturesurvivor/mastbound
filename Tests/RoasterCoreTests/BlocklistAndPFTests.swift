import Foundation
import Testing
@testable import RoasterCore

@Test func parsesOnlyValidHostsRows() throws {
    let data = Data("""
    # comment
    0.0.0.0 adult.example
    127.0.0.1 second.example
    0.0.0.0 invalid_name.example
    ::1 localhost
    1.2.3.4 unrelated.example

    """.utf8)
    #expect(try AdultBlocklistParser.parseHostsData(data) == ["adult.example", "second.example"])
}

@Test func pfRendererUsesValidatedLiteralEndpoint() throws {
    let rules = try PFRuleRenderer.render(
        endpoints: [NetworkEndpoint(address: "192.0.2.10", port: 8096)]
    )
    #expect(rules.contains("block drop out quick inet proto tcp"))
    #expect(rules.contains("to 192.0.2.10 port = 8096"))
    #expect(!rules.contains("anchor \"*\""))
}
