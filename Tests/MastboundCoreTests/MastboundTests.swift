import Testing
@testable import MastboundCore

@Test func versionIsSet() {
    #expect(!Mastbound.version.isEmpty)
}
