import Foundation

/// One `/etc/hosts` row pair that sends a name to a fixed address instead of
/// blocking it.
public struct HostsRedirect: Equatable, Hashable, Sendable {
    public var name: String
    public var ipv4: String
    /// `nil` writes `::`, so the name has no usable IPv6 address and the
    /// browser must use `ipv4`.
    public var ipv6: String?

    public init(name: String, ipv4: String, ipv6: String?) {
        self.name = name
        self.ipv4 = ipv4
        self.ipv6 = ipv6
    }
}

/// Forced SafeSearch. Google, Bing and DuckDuckGo each run servers that
/// always filter explicit results, images included, whatever the page or
/// account setting says. While a commitment runs, their search names point
/// to those servers.
///
/// The addresses are fixed in the app, not looked up at run time. On
/// 2026-11-19 two of the four addresses that DNS gave for strict.bing.com
/// served unfiltered results, and so did both of its IPv6 addresses. A
/// lookup can also be answered by a DNS server the user controls. So each
/// address here was checked by hand, and IPv6 is always `::`, which makes
/// the browser use the checked IPv4 address. `script/check-safesearch.sh`
/// checks that each one still filters; run it before every release.
public enum SafeSearch {
    /// forcesafesearch.google.com
    static let google = "216.239.38.120"
    /// strict.bing.com (only some of its addresses filter)
    static let bing = "150.171.28.16"
    /// safe.duckduckgo.com
    static let duckDuckGo = "52.149.247.1"

    /// Every redirect, sorted by name.
    public static let redirects: [HostsRedirect] = {
        var rows: [HostsRedirect] = []
        for domain in GoogleDomains.all {
            for name in [domain, "www." + domain] {
                rows.append(HostsRedirect(name: name, ipv4: google, ipv6: nil))
            }
        }
        for name in ["bing.com", "www.bing.com"] {
            rows.append(HostsRedirect(name: name, ipv4: bing, ipv6: nil))
        }
        for name in ["duckduckgo.com", "www.duckduckgo.com", "html.duckduckgo.com", "lite.duckduckgo.com", "start.duckduckgo.com"] {
            rows.append(HostsRedirect(name: name, ipv4: duckDuckGo, ipv6: nil))
        }
        return rows.sorted { $0.name < $1.name }
    }()

    /// Names that also get a resolver file, so Safari cannot take addresses
    /// from the real DNS server's HTTPS record (see `ResolverFiles`). Only
    /// search host names: a file for `google.com` would also stop Gmail,
    /// Maps and every other Google name.
    public static func resolverNames(for redirects: [HostsRedirect]) -> [String] {
        let allowed: Set<String> = ["www.bing.com", "www.duckduckgo.com", "html.duckduckgo.com", "lite.duckduckgo.com", "start.duckduckgo.com"]
        return redirects.map(\.name).filter { name in
            allowed.contains(name) || (name.hasPrefix("www.google."))
        }
    }
}
