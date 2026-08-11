import Darwin
import Foundation

public enum TargetValidator {
    public static func normalize(_ endpoints: [NetworkEndpoint]) throws -> [NetworkEndpoint] {
        guard endpoints.count <= 64 else {
            throw RoasterError.invalidDomain("No more than 64 network endpoints are allowed.")
        }
        for endpoint in endpoints { try validate(endpoint) }
        return Array(Set(endpoints)).sorted {
            ($0.address, $0.port, $0.transport.rawValue) < ($1.address, $1.port, $1.transport.rawValue)
        }
    }

    public static func validate(_ endpoint: NetworkEndpoint) throws {
        guard endpoint.port > 0 else {
            throw RoasterError.invalidDomain("Network endpoint ports must be between 1 and 65535.")
        }
        var ipv4 = in_addr()
        var ipv6 = in6_addr()
        let isIPv4 = endpoint.address.withCString { inet_pton(AF_INET, $0, &ipv4) == 1 }
        let isIPv6 = endpoint.address.withCString { inet_pton(AF_INET6, $0, &ipv6) == 1 }
        guard isIPv4 || isIPv6 else {
            throw RoasterError.invalidDomain("Endpoint must use a literal IP address: \(endpoint.address)")
        }
        guard endpoint.address != "0.0.0.0", endpoint.address != "::" else {
            throw RoasterError.invalidDomain("Unspecified network addresses cannot be blocked as endpoints.")
        }
    }
}
