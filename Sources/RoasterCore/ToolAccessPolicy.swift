import Foundation

public enum ToolAccessPolicy {
    public static let allowedDomains = Set(DomainValidator.defaultDomains)

    public static func validatedURL(_ rawValue: String) throws -> URL {
        guard !rawValue.isEmpty, rawValue.utf8.count <= 8_192,
              !rawValue.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }),
              !rawValue.contains("\\"),
              var components = URLComponents(string: rawValue),
              components.scheme?.lowercased() == "https",
              components.user == nil,
              components.password == nil,
              components.port == nil || components.port == 443,
              let host = components.host?.lowercased(),
              allowedDomains.contains(host) else {
            throw RoasterError.invalidDomain(
                "Tool access accepts only HTTPS URLs on the scheduled social-media domains."
            )
        }

        components.scheme = "https"
        components.host = host
        guard let normalized = components.url else {
            throw RoasterError.invalidDomain("The tool URL is malformed.")
        }
        return normalized
    }
}
