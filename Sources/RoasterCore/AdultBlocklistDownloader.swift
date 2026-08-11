import CryptoKit
import Foundation

public actor AdultBlocklistDownloader {
    public init() {}

    public func refresh(
        sources: [AdultBlocklistSource] = AdultBlocklistSource.stevenBlackPornSources,
        destination: URL = RoasterPaths.adultBlocklistURL(),
        metadataDestination: URL = RoasterPaths.adultBlocklistMetadataURL()
    ) async throws -> AdultBlocklistMetadata {
        guard !sources.isEmpty, sources.count <= 16 else {
            throw RoasterError.invalidDomain("The adult blocklist must use between 1 and 16 sources.")
        }

        var merged = Set<String>()
        for source in sources {
            guard source.url.scheme == "https",
                  source.url.host == "raw.githubusercontent.com" else {
                throw RoasterError.invalidDomain("Blocklist sources must use the approved HTTPS host.")
            }
            let data = try await download(source.url)
            let domains = try AdultBlocklistParser.parseHostsData(data)
            merged.formUnion(domains)
            guard merged.count <= AdultBlocklistParser.maximumMergedDomains else {
                throw RoasterError.invalidDomain("Merged adult blocklist exceeds the domain safety limit.")
            }
        }

        let domains = merged.sorted()
        let serialized = try AdultBlocklistParser.serialize(domains)
        let digest = SHA256.hash(data: serialized).map { String(format: "%02x", $0) }.joined()
        let metadata = AdultBlocklistMetadata(
            fetchedAt: Date(),
            domainCount: domains.count,
            sha256: digest,
            sources: sources
        )
        try SecureFileIO.writeAdultBlocklist(domains, to: destination)
        try SecureFileIO.writeAdultBlocklistMetadata(metadata, to: metadataDestination)
        return metadata
    }

    private func download(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("ScreenTimeRoasterMac/1.0", forHTTPHeaderField: "User-Agent")

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let response = response as? HTTPURLResponse,
              response.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        if let expectedLength = response.value(forHTTPHeaderField: "Content-Length"),
           let count = Int(expectedLength),
           count > AdultBlocklistParser.maximumSourceBytes {
            throw RoasterError.configurationTooLarge
        }

        var data = Data()
        data.reserveCapacity(min(Int(response.expectedContentLength), AdultBlocklistParser.maximumSourceBytes))
        for try await byte in bytes {
            guard data.count < AdultBlocklistParser.maximumSourceBytes else {
                throw RoasterError.configurationTooLarge
            }
            data.append(byte)
        }
        return data
    }
}
