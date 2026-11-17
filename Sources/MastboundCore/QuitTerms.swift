import Foundation

/// The statements a person must agree to before an early end, in Terminal
/// (`mastboundctl recover`) and in the app. `{days}` and `{delay}` are filled in.
public enum QuitTerms {
    public static let statements = [
        "I'm quitting because I care more about my carnal desires than human connection.",
        "I am choosing a screen over the people who love me.",
        "I made this commitment with a clear head, and I am breaking it with a cloudy one.",
        "I know this urge will pass whether or not I give in to it.",
        "I am trading {days} of progress for a few minutes.",
        "I would not want the people I respect to watch me do this.",
        "Nobody is making me do this. This is my choice, and mine alone.",
        "I am not quitting because the block is broken. I am quitting because I am weak right now.",
        "I accept that tomorrow I will have to explain this to myself.",
        "A person who keeps promises to themselves would close this window now.",
        "I know the block stays for {delay} more anyway, and I am starting the wait regardless.",
        "I am ignoring the person who set this up: me.",
    ]

    /// "3 days", "1 day".
    public static func daysText(remainingSeconds: Double) -> String {
        let days = Int(remainingSeconds / 86_400)
        return days == 1 ? "1 day" : "\(days) days"
    }

    /// "72 hours" (or "2 minutes" in a test build).
    public static var delayText: String {
        Policy.recoveryDelaySeconds >= 3_600
            ? "\(Int(Policy.recoveryDelaySeconds / 3_600)) hours"
            : "\(Int(Policy.recoveryDelaySeconds / 60)) minutes"
    }

    public static func filled(remainingSeconds: Double) -> [String] {
        let days = daysText(remainingSeconds: remainingSeconds)
        return statements.map {
            $0.replacingOccurrences(of: "{days}", with: days).replacingOccurrences(of: "{delay}", with: delayText)
        }
    }
}
