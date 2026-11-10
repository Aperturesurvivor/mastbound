import CryptoKit
import Foundation

/// The adult-domain list shipped inside the app (I12).
///
/// Canonical form: one valid domain per line, lowercase, sorted, no
/// duplicates, each line ends with "\n". Only data in exactly this form is
/// accepted, so one list always has one SHA-256.
public struct Blocklist: Equatable, Sendable {
    public static let maximumBytes = 16 * 1024 * 1024

    public let domains: [String]
    public let sha256: String

    /// Parses canonical list data and computes its hash.
    public static func parse(_ data: Data) throws -> Blocklist {
        guard data.count <= maximumBytes else {
            throw MastboundError.fileTooLarge("The list is larger than \(maximumBytes) bytes.")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw MastboundError.invalidList("The list is not valid UTF-8.")
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let domains = try DomainValidator.normalize(lines, maximumCount: HostsSection.maximumDomains)
        guard !domains.isEmpty else {
            throw MastboundError.invalidList("The list is empty.")
        }
        guard try serialize(domains) == data else {
            throw MastboundError.invalidList("The list is not in canonical form.")
        }
        return Blocklist(domains: domains, sha256: sha256Hex(data))
    }

    /// Parses the list and requires its hash to equal `expectedSHA256`.
    public static func load(_ data: Data, expectedSHA256: String) throws -> Blocklist {
        let list = try parse(data)
        guard list.sha256 == expectedSHA256.lowercased() else {
            throw MastboundError.invalidList("The list does not match its pinned SHA-256.")
        }
        return list
    }

    public static func serialize(_ domains: [String]) throws -> Data {
        let normalized = try DomainValidator.normalize(domains, maximumCount: HostsSection.maximumDomains)
        return Data((normalized.joined(separator: "\n") + "\n").utf8)
    }

    /// Reads upstream hosts-file sources (used only by the list build script).
    /// Keeps rows of the form `0.0.0.0 name` or `127.0.0.1 name` with a valid
    /// name; skips every other row.
    public static func domainsFromHostsSource(_ data: Data) throws -> [String] {
        guard let text = String(data: data, encoding: .utf8) else {
            throw MastboundError.invalidList("A list source is not valid UTF-8.")
        }
        let skipped: Set<String> = ["localhost", "localhost.localdomain", "local", "broadcasthost", "0.0.0.0"]
        var domains: [String] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count >= 2, fields[0] == "0.0.0.0" || fields[0] == "127.0.0.1" else { continue }
            let name = fields[1].lowercased()
            guard !skipped.contains(name), (try? DomainValidator.validate(name)) != nil else { continue }
            domains.append(name)
        }
        return domains
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
