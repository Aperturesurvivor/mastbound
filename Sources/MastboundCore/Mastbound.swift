/// Shared constants for the Mastbound commitment core.
public enum Mastbound {
    #if MASTBOUND_UPGRADE_MARK
    public static let version = "0.1.0-dev+upgrade" // real-system upgrade check only
    #else
    public static let version = "0.1.2"
    #endif
}
