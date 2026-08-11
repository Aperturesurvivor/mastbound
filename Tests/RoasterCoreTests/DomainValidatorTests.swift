import Testing
@testable import RoasterCore

@Test func normalizesAndDeduplicatesDomains() throws {
    #expect(
        try DomainValidator.normalize([" WWW.YouTube.com. ", "www.youtube.com", "x.com"])
            == ["www.youtube.com", "x.com"]
    )
}

@Test func rejectsInjectionAndIPInputs() {
    #expect(throws: (any Error).self) {
        try DomainValidator.normalize(["example.com\n127.0.0.1 evil.com"])
    }
    #expect(throws: (any Error).self) { try DomainValidator.normalize(["192.0.2.10"]) }
    #expect(throws: (any Error).self) { try DomainValidator.normalize(["*.example.com"]) }
    #expect(throws: (any Error).self) { try DomainValidator.normalize(["-bad.example.com"]) }
}

@Test func endpointRequiresLiteralAddress() throws {
    _ = try NetworkEndpoint(address: "192.0.2.10", port: 8096).validated()
    #expect(throws: (any Error).self) {
        try NetworkEndpoint(address: "jellyfin.example.com", port: 8096).validated()
    }
    #expect(throws: (any Error).self) {
        try NetworkEndpoint(address: "0.0.0.0", port: 8096).validated()
    }
}
