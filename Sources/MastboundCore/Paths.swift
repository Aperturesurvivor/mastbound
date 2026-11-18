import Darwin
import Foundation

/// Every file location Mastbound uses. Tests use `Paths.testing(root:)` so
/// nothing touches the real system.
public struct Paths: Sendable, Equatable {
    public static let launchDaemonLabel = "com.josiahwilson.mastbound"

    /// Root-owned folder for state. Not in any user's home folder (I5).
    public var stateDirectory: URL
    /// Root-owned folder for the installed daemon, tool and list (I8).
    public var helperDirectory: URL
    public var hostsFile: URL
    /// Per-domain DNS settings (resolver(5)). See `ResolverFiles`.
    public var resolverDirectory: URL
    public var launchDaemonPlist: URL
    /// Owner of every file Mastbound writes. Root (0) on a real system.
    public var owner: uid_t
    public var group: gid_t

    public var stateFile: URL { stateDirectory.appendingPathComponent("state.json") }
    /// Readable by everyone, so the UI can show status without a password.
    public var statusFile: URL { stateDirectory.appendingPathComponent("status.json") }
    /// Copy of the list taken at start; its hash is in the state.
    public var lockedListFile: URL { stateDirectory.appendingPathComponent("locked-list.txt") }
    public var lockFile: URL { stateDirectory.appendingPathComponent(".lock") }
    /// Sticky folder that any user may write (mode 1777), like `/tmp`. The
    /// only request it carries is "cancel the early end", which can only make
    /// the block last longer, so it needs no password.
    public var requestsDirectory: URL { stateDirectory.appendingPathComponent("requests", isDirectory: true) }
    public var cancelRecoveryRequest: URL { requestsDirectory.appendingPathComponent("cancel-recovery") }

    public var installedDaemon: URL { helperDirectory.appendingPathComponent("mastboundd") }
    public var installedTool: URL { helperDirectory.appendingPathComponent("mastboundctl") }
    public var installedList: URL { helperDirectory.appendingPathComponent(Paths.listFileName) }

    public static let listFileName = "adult-domains.txt"

    public static let system = Paths(
        stateDirectory: URL(fileURLWithPath: "/Library/Application Support/Mastbound", isDirectory: true),
        helperDirectory: URL(fileURLWithPath: "/Library/PrivilegedHelperTools/Mastbound", isDirectory: true),
        hostsFile: URL(fileURLWithPath: "/etc/hosts"),
        resolverDirectory: URL(fileURLWithPath: "/etc/resolver", isDirectory: true),
        launchDaemonPlist: URL(fileURLWithPath: "/Library/LaunchDaemons/\(launchDaemonLabel).plist"),
        owner: 0,
        group: 0
    )

    /// A full layout under `root`, owned by the current user.
    public static func testing(root: URL) -> Paths {
        Paths(
            stateDirectory: root.appendingPathComponent("state", isDirectory: true),
            helperDirectory: root.appendingPathComponent("helper", isDirectory: true),
            hostsFile: root.appendingPathComponent("hosts"),
            resolverDirectory: root.appendingPathComponent("resolver", isDirectory: true),
            launchDaemonPlist: root.appendingPathComponent("\(launchDaemonLabel).plist"),
            owner: getuid(),
            group: getgid()
        )
    }
}
