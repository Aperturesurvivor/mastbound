import Darwin
import Foundation
import RoasterCore

private enum InstallerError: Error, LocalizedError {
    case requiresRoot
    case invalidArguments(String)
    case unsafeSource(String)
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .requiresRoot: return "Administrator authorization is required."
        case .invalidArguments(let message), .unsafeSource(let message), .commandFailed(let message):
            return message
        }
    }
}

private struct InstallRequest {
    let appBundle: URL
    let userHome: URL
    let userID: uid_t
    let expectedBundleCDHash: String

    static func parse(_ arguments: [String]) throws -> InstallRequest {
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            guard arguments[index].hasPrefix("--"), index + 1 < arguments.count else {
                throw InstallerError.invalidArguments("Invalid installer arguments.")
            }
            values[arguments[index]] = arguments[index + 1]
            index += 2
        }
        guard let appBundle = values["--app-bundle"],
              let userHome = values["--user-home"],
              let userIDString = values["--uid"],
              let userID = uid_t(userIDString),
              let expectedBundleCDHash = values["--expected-bundle-cdhash"],
              expectedBundleCDHash.range(
                of: #"^[0-9a-f]{40,64}$"#,
                options: .regularExpression
              ) != nil else {
            throw InstallerError.invalidArguments(
                "App bundle, user home, UID, and the pre-authorization bundle hash are required."
            )
        }
        let homeURL = URL(fileURLWithPath: userHome).standardizedFileURL
        guard homeURL.path.hasPrefix("/Users/"),
              homeURL.pathComponents.count == 3 else {
            throw InstallerError.invalidArguments("The user home must be a direct child of /Users.")
        }
        return InstallRequest(
            appBundle: URL(fileURLWithPath: appBundle).standardizedFileURL,
            userHome: homeURL,
            userID: userID,
            expectedBundleCDHash: expectedBundleCDHash
        )
    }
}

private enum Installer {
    static let installedApp = URL(fileURLWithPath: "/Applications/Screen Time Roaster Mac.app")
    static let helper = URL(fileURLWithPath: "/Library/PrivilegedHelperTools/RoasterEnforcer")
    static let launchDaemon = URL(
        fileURLWithPath: "/Library/LaunchDaemons/\(RoasterPaths.launchDaemonLabel).plist"
    )

    static func install(_ request: InstallRequest) throws {
        try requireRoot()
        let sourceHelper = request.appBundle.appendingPathComponent("Contents/Resources/RoasterEnforcer")
        try validateRegularExecutable(sourceHelper)
        try validateRegularExecutable(
            request.appBundle.appendingPathComponent("Contents/Resources/RoasterInstaller")
        )

        let configURL = RoasterPaths.configurationURL(homeDirectory: request.userHome)
        let blocklistURL = RoasterPaths.adultBlocklistURL(homeDirectory: request.userHome)
        try validateUserFile(configURL, owner: request.userID)
        try validateUserFile(blocklistURL, owner: request.userID)

        try verifySignature(request.appBundle, expectedCDHash: request.expectedBundleCDHash)
        try installAppBundle(
            from: request.appBundle,
            expectedCDHash: request.expectedBundleCDHash
        )
        try writeLaunchDaemon(
            configURL: configURL,
            blocklistURL: blocklistURL,
            userID: request.userID
        )

        _ = try? run("/bin/launchctl", ["bootout", "system/\(RoasterPaths.launchDaemonLabel)"])
        let bootstrap = try run("/bin/launchctl", ["bootstrap", "system", launchDaemon.path])
        guard bootstrap.status == 0 else {
            throw InstallerError.commandFailed("launchctl bootstrap failed: \(bootstrap.output)")
        }
        let kickstart = try run(
            "/bin/launchctl",
            ["kickstart", "-k", "system/\(RoasterPaths.launchDaemonLabel)"]
        )
        guard kickstart.status == 0 else {
            throw InstallerError.commandFailed("launchctl kickstart failed: \(kickstart.output)")
        }
    }

    static func uninstall() throws {
        try requireRoot()
        let arguments: [String]?
        if FileManager.default.fileExists(atPath: launchDaemon.path),
           let plist = NSDictionary(contentsOf: launchDaemon) as? [String: Any] {
            arguments = plist["ProgramArguments"] as? [String]
        } else {
            arguments = nil
        }
        _ = try? run("/bin/launchctl", ["bootout", "system/\(RoasterPaths.launchDaemonLabel)"])

        let enforcementArtifactsExist = FileManager.default.fileExists(atPath: helper.path)
            || FileManager.default.fileExists(atPath: RoasterPaths.systemStateURL.path)
        if enforcementArtifactsExist {
            guard let arguments, !arguments.isEmpty,
                  FileManager.default.isExecutableFile(atPath: helper.path) else {
                throw InstallerError.unsafeSource(
                    "Enforcement is incomplete. Repair the installation before uninstalling so system rules can be cleared safely."
                )
            }
            let clear = try run(helper.path, Array(arguments.dropFirst()) + ["--clear"])
            guard clear.status == 0 else {
                throw InstallerError.commandFailed("Enforcement cleanup failed: \(clear.output)")
            }
        }
        try removeExactFileIfPresent(helper)
        try removeExactFileIfPresent(launchDaemon)
    }

    private static func requireRoot() throws {
        guard geteuid() == 0 else { throw InstallerError.requiresRoot }
    }

    private static func validateRegularExecutable(_ url: URL) throws {
        var fileStat = stat()
        guard lstat(url.path, &fileStat) == 0,
              (fileStat.st_mode & S_IFMT) == S_IFREG,
              (fileStat.st_mode & 0o111) != 0 else {
            throw InstallerError.unsafeSource("Expected a regular executable at \(url.path).")
        }
    }

    private static func validateUserFile(_ url: URL, owner: uid_t) throws {
        var fileStat = stat()
        guard lstat(url.path, &fileStat) == 0,
              (fileStat.st_mode & S_IFMT) == S_IFREG,
              fileStat.st_uid == owner,
              (fileStat.st_mode & 0o022) == 0 else {
            throw InstallerError.unsafeSource("User configuration has unsafe ownership or permissions: \(url.path)")
        }
    }

    private static func verifySignature(_ url: URL, expectedCDHash: String) throws {
        let result = try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", url.path])
        guard result.status == 0 else {
            throw InstallerError.unsafeSource("The staged app signature is invalid: \(result.output)")
        }
        let details = try run("/usr/bin/codesign", ["-d", "--verbose=4", url.path])
        let expression = try NSRegularExpression(pattern: #"(?m)^CDHash=([0-9A-Fa-f]{40,64})$"#)
        let range = NSRange(details.output.startIndex..., in: details.output)
        guard details.status == 0,
              let match = expression.firstMatch(in: details.output, range: range),
              let hashRange = Range(match.range(at: 1), in: details.output),
              details.output[hashRange].lowercased() == expectedCDHash else {
            throw InstallerError.unsafeSource(
                "The app changed after administrator authorization was requested; refusing to install it."
            )
        }
    }

    private static func installAppBundle(from source: URL, expectedCDHash: String) throws {
        var sourceStat = stat()
        guard lstat(source.path, &sourceStat) == 0,
              (sourceStat.st_mode & S_IFMT) == S_IFDIR else {
            throw InstallerError.unsafeSource("The app bundle source is not a regular directory.")
        }
        let protectedStagingDirectory = helper.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: protectedStagingDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )
        var stagingDirectoryStat = stat()
        guard lstat(protectedStagingDirectory.path, &stagingDirectoryStat) == 0,
              (stagingDirectoryStat.st_mode & S_IFMT) == S_IFDIR,
              stagingDirectoryStat.st_uid == 0,
              (stagingDirectoryStat.st_mode & 0o022) == 0 else {
            throw InstallerError.unsafeSource("The protected staging directory has unsafe permissions.")
        }
        let staging = protectedStagingDirectory.appendingPathComponent(
            ".Screen Time Roaster Mac.install.\(getpid()).app"
        )
        let backup = protectedStagingDirectory.appendingPathComponent(
            ".Screen Time Roaster Mac.backup.\(getpid()).app"
        )
        try removeExactDirectoryIfPresent(staging)
        try removeExactDirectoryIfPresent(backup)
        do {
            try FileManager.default.copyItem(at: source, to: staging)
            try setRootOwnershipRecursively(staging)
            try validateInstalledExecutables(in: staging)
            try verifySignature(staging, expectedCDHash: expectedCDHash)
            try installHelper(
                from: staging.appendingPathComponent("Contents/Resources/RoasterEnforcer")
            )

            var movedExistingAside = false
            if FileManager.default.fileExists(atPath: installedApp.path) {
                try validateRegularDirectory(installedApp)
                guard rename(installedApp.path, backup.path) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                movedExistingAside = true
            }
            guard rename(staging.path, installedApp.path) == 0 else {
                if movedExistingAside {
                    _ = rename(backup.path, installedApp.path)
                }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            try removeExactDirectoryIfPresent(backup)
        } catch {
            try? removeExactDirectoryIfPresent(staging)
            throw error
        }
    }

    private static func setRootOwnershipRecursively(_ root: URL) throws {
        try hardenOwnershipAndMode(root)
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: [],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw InstallerError.unsafeSource("Could not enumerate the installed app bundle.")
        }
        for case let itemURL as URL in enumerator {
            try hardenOwnershipAndMode(itemURL)
        }
        if let enumerationError { throw enumerationError }
    }

    private static func hardenOwnershipAndMode(_ url: URL) throws {
        var fileStat = stat()
        guard lstat(url.path, &fileStat) == 0,
              lchown(url.path, 0, 0) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard (fileStat.st_mode & S_IFMT) != S_IFLNK else { return }
        let hardenedMode = mode_t(fileStat.st_mode & 0o777 & ~0o022)
        guard chmod(url.path, hardenedMode) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func validateInstalledExecutables(in appBundle: URL) throws {
        try validateRegularExecutable(appBundle.appendingPathComponent("Contents/MacOS/RoasterMac"))
        for name in ["RoasterEnforcer", "RoasterBlocklist", "RoasterInstaller"] {
            try validateRegularExecutable(appBundle.appendingPathComponent("Contents/Resources/\(name)"))
        }
    }

    private static func validateRegularDirectory(_ url: URL) throws {
        var fileStat = stat()
        guard lstat(url.path, &fileStat) == 0,
              (fileStat.st_mode & S_IFMT) == S_IFDIR else {
            throw InstallerError.unsafeSource("Expected a regular directory at \(url.path).")
        }
    }

    private static func removeExactDirectoryIfPresent(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try validateRegularDirectory(url)
        try FileManager.default.removeItem(at: url)
    }

    private static func installHelper(from source: URL) throws {
        try FileManager.default.createDirectory(
            at: helper.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )
        if FileManager.default.fileExists(atPath: helper.path) {
            var helperStat = stat()
            guard lstat(helper.path, &helperStat) == 0,
                  (helperStat.st_mode & S_IFMT) == S_IFREG else {
                throw InstallerError.unsafeSource("Refusing to replace a non-regular helper target.")
            }
        }
        let temporary = helper.deletingLastPathComponent().appendingPathComponent(".RoasterEnforcer.install")
        try removeExactFileIfPresent(temporary)
        try FileManager.default.copyItem(at: source, to: temporary)
        guard chmod(temporary.path, 0o755) == 0,
              chown(temporary.path, 0, 0) == 0,
              rename(temporary.path, helper.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func writeLaunchDaemon(configURL: URL, blocklistURL: URL, userID: uid_t) throws {
        if FileManager.default.fileExists(atPath: launchDaemon.path) {
            var daemonStat = stat()
            guard lstat(launchDaemon.path, &daemonStat) == 0,
                  (daemonStat.st_mode & S_IFMT) == S_IFREG else {
                throw InstallerError.unsafeSource("Refusing to replace a non-regular launch daemon plist.")
            }
        }
        let plist: [String: Any] = [
            "Label": RoasterPaths.launchDaemonLabel,
            "ProgramArguments": [
                helper.path,
                "--config", configURL.path,
                "--adult-blocklist", blocklistURL.path,
                "--expected-uid", String(userID),
                "--interval", "15",
            ],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ProcessType": "Background",
            "ThrottleInterval": 10,
            "StandardOutPath": "/var/log/ScreenTimeRoasterMac.log",
            "StandardErrorPath": "/var/log/ScreenTimeRoasterMac.error.log",
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        let temporary = launchDaemon.deletingLastPathComponent().appendingPathComponent(
            ".\(RoasterPaths.launchDaemonLabel).install.plist"
        )
        try data.write(to: temporary, options: .atomic)
        guard chmod(temporary.path, 0o644) == 0,
              chown(temporary.path, 0, 0) == 0,
              rename(temporary.path, launchDaemon.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func removeExactFileIfPresent(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        var fileStat = stat()
        guard lstat(url.path, &fileStat) == 0,
              (fileStat.st_mode & S_IFMT) == S_IFREG else {
            throw InstallerError.unsafeSource("Refusing to remove a non-regular target: \(url.path)")
        }
        guard unlink(url.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func run(_ executable: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(
            data: pipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        return (process.terminationStatus, output)
    }
}

@main
private struct RoasterInstallerCommand {
    static func main() {
        do {
            guard let command = CommandLine.arguments.dropFirst().first else {
                throw InstallerError.invalidArguments("Expected install or uninstall.")
            }
            switch command {
            case "install":
                let request = try InstallRequest.parse(Array(CommandLine.arguments.dropFirst(2)))
                try Installer.install(request)
                print("Screen Time Roaster Mac installed and enforcement started.")
            case "uninstall":
                try Installer.uninstall()
                print("Screen Time Roaster Mac enforcement removed.")
            default:
                throw InstallerError.invalidArguments("Expected install or uninstall.")
            }
        } catch {
            FileHandle.standardError.write(Data("RoasterInstaller: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
