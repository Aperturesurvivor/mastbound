import Foundation

public enum DomainValidator {
    public static let defaultDomains = [
        "x.com",
        "www.x.com",
        "twitter.com",
        "www.twitter.com",
        "mobile.twitter.com",
        "t.co",
        "instagram.com",
        "www.instagram.com",
        "m.instagram.com",
        "facebook.com",
        "www.facebook.com",
        "m.facebook.com",
        "messenger.com",
        "www.messenger.com",
        "youtube.com",
        "www.youtube.com",
        "m.youtube.com",
        "youtu.be",
        "youtube-nocookie.com",
        "www.youtube-nocookie.com",
    ]

    private static let allowedScalars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-.")

    public static func normalize(
        _ rawDomains: [String],
        maximumCount: Int = 128
    ) throws -> [String] {
        guard rawDomains.count <= maximumCount else {
            throw RoasterError.invalidDomain("No more than \(maximumCount) domains are allowed.")
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
            throw RoasterError.invalidDomain("Domain is too long: \(domain)")
        }
        guard domain.contains("."), domain != "localhost" else {
            throw RoasterError.invalidDomain("A full public domain is required: \(domain)")
        }
        guard domain.unicodeScalars.allSatisfy({ allowedScalars.contains($0) }) else {
            throw RoasterError.invalidDomain("Domain contains unsupported characters: \(domain)")
        }
        guard !domain.contains("..") else {
            throw RoasterError.invalidDomain("Domain contains an empty label: \(domain)")
        }

        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else {
            throw RoasterError.invalidDomain("A full public domain is required: \(domain)")
        }
        for label in labels {
            guard !label.isEmpty, label.utf8.count <= 63,
                  label.first != "-", label.last != "-" else {
                throw RoasterError.invalidDomain("Domain has an invalid label: \(domain)")
            }
        }
        guard labels.last?.allSatisfy({ $0.isNumber }) == false else {
            throw RoasterError.invalidDomain("IP addresses are not accepted as domains: \(domain)")
        }
    }
}
