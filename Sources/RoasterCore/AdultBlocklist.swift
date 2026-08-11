import CryptoKit
import Foundation

public enum ReviewedAdultBlocklist {
    public static let revision = "92a38fd106abe49f50ed6904ff0e867f4eb44f9f"
    public static let domainCount = 76_744
    public static let sha256 = "6113a8bd81f45149e586f23e5cb33b03a5a24ef9d32d196877c54dd333d2f0b3"

    @discardableResult
    public static func validate(_ domains: [String]) throws -> Data {
        let serialized = try AdultBlocklistParser.serialize(domains)
        let digest = SHA256.hash(data: serialized).map { String(format: "%02x", $0) }.joined()
        guard domains.count == domainCount, digest == sha256 else {
            throw RoasterError.unsafeFile(
                "The adult-domain cache does not match the reviewed release snapshot."
            )
        }
        return serialized
    }
}

public struct AdultBlocklistSource: Codable, Equatable, Sendable {
    public var name: String
    public var url: URL
    public var homepage: URL
    public var license: String

    public init(name: String, url: URL, homepage: URL, license: String) {
        self.name = name
        self.url = url
        self.homepage = homepage
        self.license = license
    }

    public static let stevenBlackPornSources: [AdultBlocklistSource] = [
        source("BigDargon hostsVN adult", "bigdargon", "https://github.com/bigdargon/hostsVN", "MIT"),
        source("brijrajparmar27 pornography", "brijrajparmar27", "https://github.com/brijrajparmar27/host-sources", "CC BY 4.0"),
        source("Clefspeare13 pornhosts", "clefspeare13", "https://github.com/Clefspeare13/pornhosts", "MIT"),
        source("Sinfonietta snuff-site list", "sinfonietta-snuff", "https://github.com/Sinfonietta/hostfiles", "MIT"),
        source("Sinfonietta pornography list", "sinfonietta", "https://github.com/Sinfonietta/hostfiles", "MIT"),
        source("Tiuxo pornography list", "tiuxo", "https://github.com/tiuxo/hosts", "CC BY 4.0"),
    ]

    private static func source(
        _ name: String,
        _ folder: String,
        _ homepage: String,
        _ license: String
    ) -> AdultBlocklistSource {
        AdultBlocklistSource(
            name: name,
            url: URL(
                string: "https://raw.githubusercontent.com/StevenBlack/hosts/\(ReviewedAdultBlocklist.revision)/extensions/porn/\(folder)/hosts"
            )!,
            homepage: URL(string: homepage)!,
            license: license
        )
    }
}

public struct AdultBlocklistMetadata: Codable, Equatable, Sendable {
    public var fetchedAt: Date
    public var domainCount: Int
    public var sha256: String
    public var sources: [AdultBlocklistSource]

    public init(fetchedAt: Date, domainCount: Int, sha256: String, sources: [AdultBlocklistSource]) {
        self.fetchedAt = fetchedAt
        self.domainCount = domainCount
        self.sha256 = sha256
        self.sources = sources
    }
}

public enum AdultBlocklistParser {
    public static let maximumSourceBytes = 8 * 1024 * 1024
    public static let maximumMergedDomains = 250_000

    public static func parseHostsData(_ data: Data) throws -> [String] {
        guard data.count <= maximumSourceBytes else {
            throw RoasterError.configurationTooLarge
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw RoasterError.invalidDomain("An adult-blocklist source was not valid UTF-8.")
        }
        var domains: [String] = []
        domains.reserveCapacity(80_000)
        for rawLine in text.split(whereSeparator: \Character.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count >= 2 else { continue }
            let address = fields[0]
            guard address == "0.0.0.0" || address == "127.0.0.1" else { continue }
            let candidate = String(fields[1]).lowercased()
            guard candidate != "localhost", candidate != "localhost.localdomain",
                  candidate != "local", candidate != "broadcasthost",
                  candidate != "0.0.0.0" else { continue }
            do {
                try DomainValidator.validate(candidate)
                domains.append(candidate)
            } catch {
                continue
            }
            guard domains.count <= maximumMergedDomains else {
                throw RoasterError.invalidDomain("Adult blocklist source exceeds the domain safety limit.")
            }
        }
        return try DomainValidator.normalize(domains, maximumCount: maximumMergedDomains)
    }

    public static func serialize(_ domains: [String]) throws -> Data {
        let normalized = try DomainValidator.normalize(domains, maximumCount: maximumMergedDomains)
        return Data((normalized.joined(separator: "\n") + "\n").utf8)
    }

    public static func parseSerialized(_ data: Data) throws -> [String] {
        guard data.count <= 16 * 1024 * 1024,
              let text = String(data: data, encoding: .utf8) else {
            throw RoasterError.configurationTooLarge
        }
        let domains = text.split(whereSeparator: \Character.isNewline).map(String.init)
        return try DomainValidator.normalize(domains, maximumCount: maximumMergedDomains)
    }
}
