import Testing
@testable import RoasterCore

@Test func toolAccessAcceptsOnlyExactScheduledHTTPSDomains() throws {
    let url = try ToolAccessPolicy.validatedURL("HTTPS://WWW.YouTube.com/watch?v=abc")
    #expect(url.absoluteString == "https://www.youtube.com/watch?v=abc")
    _ = try ToolAccessPolicy.validatedURL("https://x.com/someone/status/1")

    #expect(throws: (any Error).self) {
        try ToolAccessPolicy.validatedURL("http://x.com/")
    }
    #expect(throws: (any Error).self) {
        try ToolAccessPolicy.validatedURL("https://example.com/")
    }
    #expect(throws: (any Error).self) {
        try ToolAccessPolicy.validatedURL("https://evil.x.com/")
    }
    #expect(throws: (any Error).self) {
        try ToolAccessPolicy.validatedURL("https://user:password@x.com/")
    }
    #expect(throws: (any Error).self) {
        try ToolAccessPolicy.validatedURL("https://x.com:8443/")
    }
    #expect(throws: (any Error).self) {
        try ToolAccessPolicy.validatedURL("https://x.com\\@example.com/")
    }
}
