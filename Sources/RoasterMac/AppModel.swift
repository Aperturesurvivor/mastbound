import Darwin
import CryptoKit
import Foundation
import RoasterCore

@MainActor
final class AppModel: ObservableObject {
    @Published var configuration = RoasterConfiguration()
    @Published var metadata: AdultBlocklistMetadata?
    @Published var enforcementState: EnforcementState?
    @Published var message = "Loading…"
    @Published var isBusy = false

    let configURL = RoasterPaths.configurationURL()
    let blocklistURL = RoasterPaths.adultBlocklistURL()

    var isInstalled: Bool {
        FileManager.default.fileExists(
            atPath: "/Library/LaunchDaemons/\(RoasterPaths.launchDaemonLabel).plist"
        ) && FileManager.default.isExecutableFile(
            atPath: "/Library/PrivilegedHelperTools/RoasterEnforcer"
        )
    }

    var permanentProtectionIsLocked: Bool {
        enforcementState?.permanentProtectionLocked == true
            || (isInstalled && configuration.permanentProtection.enabled)
    }

    func start() async {
        do {
            if FileManager.default.fileExists(atPath: configURL.path) {
                configuration = try SecureFileIO.readConfiguration(at: configURL, expectedOwner: getuid())
            } else {
                try SecureFileIO.writeConfiguration(configuration, to: configURL)
            }
            metadata = try SecureFileIO.readAdultBlocklistMetadata(
                at: RoasterPaths.adultBlocklistMetadataURL()
            )
            refreshStatus()
            message = isInstalled ? "Enforcement service installed." : "Install the enforcement service when ready."
        } catch {
            message = error.localizedDescription
        }
    }

    func save() {
        do {
            configuration = try configuration.validated()
            try SecureFileIO.writeConfiguration(configuration, to: configURL)
            message = "Saved. The service will reconcile within 15 seconds."
        } catch {
            message = error.localizedDescription
        }
    }

    func refreshAdultProtection() async {
        isBusy = true
        defer { isBusy = false }
        do {
            metadata = try await AdultBlocklistDownloader().refresh()
            message = "Adult-content list updated and validated."
        } catch {
            message = "Adult-content update failed; the existing cache was preserved. \(error.localizedDescription)"
        }
    }

    func install() async {
        guard FileManager.default.fileExists(atPath: blocklistURL.path) else {
            message = "Update the adult-content list before installing enforcement."
            return
        }
        save()
        isBusy = true
        defer { isBusy = false }
        do {
            guard let bundleURL = Bundle.main.bundleURL as URL?,
                  let installer = Bundle.main.url(forResource: "RoasterInstaller", withExtension: nil) else {
                throw CocoaError(.fileNoSuchFile)
            }
            let output = try await runPrivileged(
                installer: installer,
                arguments: [
                    "install",
                    "--app-bundle", bundleURL.path,
                    "--user-home", FileManager.default.homeDirectoryForCurrentUser.path,
                    "--uid", String(getuid()),
                    "--expected-bundle-cdhash", try codeDirectoryHash(of: bundleURL),
                ]
            )
            refreshStatus()
            message = output.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            message = "Installation failed: \(error.localizedDescription)"
        }
    }

    func uninstallEnforcement() async {
        isBusy = true
        defer { isBusy = false }
        do {
            guard let installer = Bundle.main.url(forResource: "RoasterInstaller", withExtension: nil) else {
                throw CocoaError(.fileNoSuchFile)
            }
            let output = try await runPrivileged(installer: installer, arguments: ["uninstall"])
            refreshStatus()
            message = output.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            message = "Uninstall failed: \(error.localizedDescription)"
        }
    }

    func refreshStatus() {
        enforcementState = try? SecureFileIO.readState(at: RoasterPaths.systemStateURL)
        objectWillChange.send()
    }

    private func runPrivileged(installer: URL, arguments: [String]) async throws -> String {
        let installerData = try Data(contentsOf: installer, options: .mappedIfSafe)
        let installerHash = SHA256.hash(data: installerData)
            .map { String(format: "%02x", $0) }
            .joined()
        let privilegedScript = """
        set -eu
        source_installer=$1
        expected_hash=$2
        shift 2
        staging_dir=$(/usr/bin/mktemp -d /private/var/run/ScreenTimeRoaster.XXXXXX)
        staged_installer="$staging_dir/RoasterInstaller"
        cleanup() {
            /bin/rm -f "$staged_installer"
            /bin/rmdir "$staging_dir"
        }
        trap cleanup EXIT HUP INT TERM
        /usr/bin/install -o root -g wheel -m 0755 "$source_installer" "$staged_installer"
        actual_hash=$(/usr/bin/shasum -a 256 "$staged_installer" | /usr/bin/awk '{print $1}')
        if [ "$actual_hash" != "$expected_hash" ]; then
            echo "The installer changed after authorization was requested." >&2
            exit 74
        fi
        "$staged_installer" "$@"
        """
        let commandParts = [
            "/bin/sh", "-c", privilegedScript, "--", installer.path, installerHash,
        ] + arguments
        let command = commandParts.map(shellQuote).joined(separator: " ")
        let script = "do shell script \(appleScriptString(command)) with administrator privileges"

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-e", script]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                do {
                    try process.run()
                    process.waitUntilExit()
                    let output = String(
                        data: pipe.fileHandleForReading.readDataToEndOfFile(),
                        encoding: .utf8
                    ) ?? ""
                    guard process.terminationStatus == 0 else {
                        throw NSError(
                            domain: "ScreenTimeRoasterMac.Install",
                            code: Int(process.terminationStatus),
                            userInfo: [NSLocalizedDescriptionKey: output]
                        )
                    }
                    continuation.resume(returning: output)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func appleScriptString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func codeDirectoryHash(of appBundle: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["-d", "--verbose=4", appBundle.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let expression = try NSRegularExpression(pattern: #"(?m)^CDHash=([0-9A-Fa-f]{40,64})$"#)
        let range = NSRange(output.startIndex..., in: output)
        guard process.terminationStatus == 0,
              let match = expression.firstMatch(in: output, range: range),
              let hashRange = Range(match.range(at: 1), in: output) else {
            throw NSError(
                domain: "ScreenTimeRoasterMac.Install",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Could not bind authorization to this app build."]
            )
        }
        return output[hashRange].lowercased()
    }
}
