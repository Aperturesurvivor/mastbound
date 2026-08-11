import Darwin
import Foundation

public enum PFRuleRenderer {
    public static func render(endpoints: [NetworkEndpoint]) throws -> String {
        let endpoints = try TargetValidator.normalize(endpoints)
        guard !endpoints.isEmpty else { return "" }
        var lines = [
            "# Screen Time Roaster Mac — generated rules",
            "# Loaded only into the com.apple/ScreenTimeRoasterMac anchor.",
        ]
        for endpoint in endpoints {
            var ipv4 = in_addr()
            let family = endpoint.address.withCString { inet_pton(AF_INET, $0, &ipv4) == 1 }
                ? "inet"
                : "inet6"
            lines.append(
                "block drop out quick \(family) proto \(endpoint.transport.rawValue) "
                    + "from any to \(endpoint.address) port = \(endpoint.port)"
            )
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
