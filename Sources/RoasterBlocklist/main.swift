import Foundation
import RoasterCore

@main
struct RoasterBlocklistCommand {
    static func main() async {
        do {
            let configURL = RoasterPaths.configurationURL()
            let arguments = Array(CommandLine.arguments.dropFirst())
            let jellyfinAddress: String?
            if let addressIndex = arguments.firstIndex(of: "--jellyfin-address"),
               arguments.indices.contains(addressIndex + 1) {
                jellyfinAddress = arguments[addressIndex + 1]
            } else {
                jellyfinAddress = nil
            }

            var configuration: RoasterConfiguration
            if !FileManager.default.fileExists(atPath: configURL.path) {
                configuration = RoasterConfiguration()
            } else {
                configuration = try SecureFileIO.readConfiguration(at: configURL, expectedOwner: getuid())
            }
            if let jellyfinAddress {
                let jellyfinRule = try RoasterConfiguration.jellyfinRule(address: jellyfinAddress).validated()
                if let existingIndex = configuration.scheduledRules.firstIndex(where: { $0.name == jellyfinRule.name }) {
                    configuration.scheduledRules[existingIndex] = jellyfinRule
                } else {
                    configuration.scheduledRules.append(jellyfinRule)
                }
            }
            try SecureFileIO.writeConfiguration(configuration, to: configURL)
            let metadata = try await AdultBlocklistDownloader().refresh()
            print("Validated and cached \(metadata.domainCount) adult-content domains.")
            print("SHA-256: \(metadata.sha256)")
        } catch {
            FileHandle.standardError.write(Data("Blocklist refresh failed: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
