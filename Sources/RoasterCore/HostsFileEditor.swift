import Foundation

public enum HostsFileEditor {
    public static let beginMarker = "# BEGIN SCREEN TIME ROASTER MAC — MANAGED BLOCK"
    public static let endMarker = "# END SCREEN TIME ROASTER MAC — MANAGED BLOCK"

    public static func render(existing: String, blockedDomains: [String]) throws -> String {
        let domains = try DomainValidator.normalize(blockedDomains, maximumCount: 250_000)
        var lines = existing.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }

        let beginIndexes = lines.indices.filter { lines[$0] == beginMarker }
        let endIndexes = lines.indices.filter { lines[$0] == endMarker }
        guard beginIndexes.count == endIndexes.count,
              beginIndexes.count <= 1 else {
            throw RoasterError.malformedManagedSection(
                "The managed hosts section has mismatched or duplicate markers; refusing to edit it."
            )
        }
        if let begin = beginIndexes.first, let end = endIndexes.first {
            guard begin < end else {
                throw RoasterError.malformedManagedSection(
                    "The managed hosts section markers are out of order; refusing to edit it."
                )
            }
            lines.removeSubrange(begin...end)
            while lines.last == "" { lines.removeLast() }
        }

        if !domains.isEmpty {
            if !lines.isEmpty { lines.append("") }
            lines.append(beginMarker)
            lines.append("# Generated from a validated exact-domain list. Do not edit this section by hand.")
            for domain in domains {
                lines.append("0.0.0.0\t\(domain)")
                lines.append("::\t\(domain)")
            }
            lines.append(endMarker)
        }

        return lines.joined(separator: "\n") + "\n"
    }

    public static func managedDomains(in contents: String) throws -> [String] {
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let beginIndexes = lines.indices.filter { lines[$0] == beginMarker }
        let endIndexes = lines.indices.filter { lines[$0] == endMarker }
        guard beginIndexes.count == endIndexes.count, beginIndexes.count <= 1 else {
            throw RoasterError.malformedManagedSection("Managed hosts markers are malformed.")
        }
        guard let begin = beginIndexes.first, let end = endIndexes.first else { return [] }
        guard begin < end else {
            throw RoasterError.malformedManagedSection("Managed hosts markers are out of order.")
        }

        let domains = lines[(begin + 1)..<end].compactMap { line -> String? in
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count == 2, fields[0] == "0.0.0.0" else { return nil }
            return String(fields[1])
        }
        return try DomainValidator.normalize(domains, maximumCount: 250_000)
    }
}
