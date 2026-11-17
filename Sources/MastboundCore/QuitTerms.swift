import Foundation

/// The statements a person must agree to before an early end in the app.
/// `{progress}` and `{delay}` are filled in.
public enum QuitTerms {
    public static let statements = [
        "I'm quitting because I care more about my carnal desires than human connection.",
        "I am choosing a screen over the people who love me.",
        "I made this commitment with a clear head, and I am breaking it with a cloudy one.",
        "I know this urge will pass whether or not I give in to it.",
        "I am trading {progress} for a few minutes.",
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

    /// The exact time kept so far: "3 days and 4 hours", "5 hours and
    /// 12 minutes", "1 minute".
    public static func progressText(elapsedSeconds: Double) -> String {
        func unit(_ n: Int, _ name: String) -> String { n == 1 ? "1 \(name)" : "\(n) \(name)s" }
        let total = max(0, Int(elapsedSeconds))
        let days = total / 86_400, hours = (total % 86_400) / 3_600, minutes = (total % 3_600) / 60
        if days > 0 { return hours > 0 ? "\(unit(days, "day")) and \(unit(hours, "hour"))" : unit(days, "day") }
        if hours > 0 { return minutes > 0 ? "\(unit(hours, "hour")) and \(unit(minutes, "minute"))" : unit(hours, "hour") }
        return unit(max(1, minutes), "minute")
    }

    /// `elapsedSeconds` is the credited time since the commitment started.
    public static func filled(elapsedSeconds: Double?) -> [String] {
        let progress = elapsedSeconds.map { "\(progressText(elapsedSeconds: $0)) of progress" } ?? "my progress"
        return statements.map {
            $0.replacingOccurrences(of: "{progress}", with: progress).replacingOccurrences(of: "{delay}", with: delayText)
        }
    }
}
