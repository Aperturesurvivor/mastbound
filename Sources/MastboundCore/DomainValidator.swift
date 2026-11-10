import Foundation

/// Strict grammar for exact domain names. Nothing reaches `/etc/hosts`
/// without passing `validate`.
public enum DomainValidator {
    private static let allowedScalars = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-."
    )

    /// Trims, lowercases, removes outer dots, validates, deduplicates and sorts.
    public static func normalize(_ rawDomains: [String], maximumCount: Int) throws -> [String] {
        guard rawDomains.count <= maximumCount else {
            throw MastboundError.invalidDomain("No more than \(maximumCount) domains are allowed.")
        }
        var result = Set<String>()
        for rawDomain in rawDomains {
            let normalized = rawDomain
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            guard !normalized.isEmpty else { continue }
            try validate(normalized)
            result.insert(normalized)
        }
        return result.sorted()
    }

    public static func validate(_ domain: String) throws {
        guard domain.utf8.count <= 253 else {
            throw MastboundError.invalidDomain("Domain is too long: \(domain)")
        }
        guard domain.unicodeScalars.allSatisfy({ allowedScalars.contains($0) }) else {
            throw MastboundError.invalidDomain("Domain contains unsupported characters: \(domain)")
        }
        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else {
            throw MastboundError.invalidDomain("A full domain is required: \(domain)")
        }
        for label in labels {
            guard !label.isEmpty, label.utf8.count <= 63,
                  label.first != "-", label.last != "-" else {
                throw MastboundError.invalidDomain("Domain has an invalid label: \(domain)")
            }
        }
        guard labels.last?.allSatisfy(\.isNumber) == false else {
            throw MastboundError.invalidDomain("IP addresses are not domains: \(domain)")
        }
    }
}
