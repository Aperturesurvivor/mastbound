import Foundation

public enum RoasterPaths {
    public static let applicationSupportDirectoryName = "ScreenTimeRoasterMac"
    public static let configurationFileName = "config.json"
    public static let adultBlocklistFileName = "adult-domains.txt"
    public static let adultBlocklistMetadataFileName = "adult-domains-metadata.json"

    public static let systemStateURL = URL(fileURLWithPath: "/var/db/ScreenTimeRoasterMac/state.json")
    public static let systemAdultBlocklistURL = URL(
        fileURLWithPath: "/var/db/ScreenTimeRoasterMac/adult-domains.txt"
    )
    public static let systemHostsURL = URL(fileURLWithPath: "/etc/hosts")
    public static let launchDaemonLabel = "com.josiahwilson.screentimeroastermac.enforcer"
    public static let pfAnchor = "com.apple/ScreenTimeRoasterMac"

    public static func userSupportDirectory(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        homeDirectory
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(applicationSupportDirectoryName, isDirectory: true)
    }

    public static func configurationURL(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        userSupportDirectory(homeDirectory: homeDirectory).appendingPathComponent(configurationFileName)
    }

    public static func adultBlocklistURL(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        userSupportDirectory(homeDirectory: homeDirectory).appendingPathComponent(adultBlocklistFileName)
    }

    public static func adultBlocklistMetadataURL(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        userSupportDirectory(homeDirectory: homeDirectory).appendingPathComponent(adultBlocklistMetadataFileName)
    }
}
