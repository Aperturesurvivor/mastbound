import Darwin
import Foundation
import MastboundCore

/// The only way to end a commitment early. It is slow on purpose: a person
/// who has a real reason (a wrong site in the list, a Mac that must be sold)
/// can get through it, and a person acting on an urge has time to change
/// their mind. After it, the block still stays for `Policy.recoveryDelaySeconds`
/// (72 hours), and one click in the app cancels the early end.
///
/// Any wrong answer stops the flow and changes nothing. There is no retry
/// inside the flow; run the command again to start over from step 1.
enum QuitFlow {
    struct Stopped: Error {}

    static let statements = [
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

    static func run(engine: Engine) throws {
        guard isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1 else {
            throw MastboundError.notAllowed("Ending early must be done by a person at a Terminal window, not by a script.")
        }
        let status = try engine.readStatus()
        guard status.phase == .active, let remaining = status.remainingSeconds else {
            throw MastboundError.notAllowed(status.phase == .recovering
                ? "An early end is already in progress."
                : "No commitment is running.")
        }
        let days = Int(remaining / 86_400)
        let daysText = days == 1 ? "1 day" : "\(days) days"
        let delay = Policy.recoveryDelaySeconds >= 3_600
            ? "\(Int(Policy.recoveryDelaySeconds / 3_600)) hours"
            : "\(Int(Policy.recoveryDelaySeconds / 60)) minutes"

        do {
            say("""

            ENDING YOUR COMMITMENT EARLY
            ============================

            You have \(formatDuration(remaining)) left.

            This takes a while on purpose. If you finish every step:
              - the block stays on for \(delay) more,
              - then it ends.
            You can cancel during those \(delay) with one click in the
            Mastbound app, or with: mastboundctl recover --cancel

            Any wrong answer stops here and changes nothing.

            """)
            try expect("Type 'continue' to read the terms: ", "continue")

            // Step 1: the terms, in a new order each time.
            let terms = statements.map { $0.replacingOccurrences(of: "{days}", with: daysText).replacingOccurrences(of: "{delay}", with: delay) }.shuffled()
            say("\nSTEP 1 OF 5: TERMS (\(terms.count) items)\n")
            for (index, term) in terms.enumerated() {
                say("\n  [ ] \(index + 1). \(term)")
                if index % 3 == 2 {
                    // Every third term must be typed out in full.
                    try expect("  Type this statement exactly to tick the box:\n  > ", term)
                } else {
                    try expect("  Type 'I agree' to tick the box: ", "I agree")
                }
                say("  [x] Agreed.")
            }

            // Step 2: wait, with typing thrown away.
            let pause = Policy.isTestBuild ? 5 : 120
            say("\nSTEP 2 OF 5: WAIT\n\nNothing to do for \(pause / 60 > 0 ? "\(pause / 60) minutes" : "\(pause) seconds"). Breathe. Drink some water.")
            var left = pause
            while left > 0 {
                let step = min(left, Policy.isTestBuild ? 5 : 30)
                sleep(UInt32(step))
                left -= step
                if left > 0 { say("  \(left) s left…") }
            }
            tcflush(STDIN_FILENO, TCIFLUSH)

            // Step 3: know what is being given up.
            say("\nSTEP 3 OF 5: THE NUMBER\n")
            try expect("How many full days are left in your commitment? (shown at the top) ", String(days))

            // Step 4: the phrase.
            say("\nSTEP 4 OF 5: THE PHRASE\n")
            try expect("Type: \(Policy.recoveryPhrase)\n> ", Policy.recoveryPhrase)

            // Step 5: last chance.
            say("""

            STEP 5 OF 5: LAST CHANCE

            If you go on, the block stays for \(delay) more and then ends.
            If you stop now, nothing changes and you keep your \(daysText).

            """)
            try expect("Type END in capital letters to start the \(delay) wait: ", "END")
        } catch is Stopped {
            say("\nStopped. Nothing changed. Your commitment continues.\n")
            exit(1)
        }

        try engine.requestRecovery(confirmation: Policy.recoveryPhrase)
        say("\nThe \(delay) wait has started. The block stays on until it ends.")
        say("To cancel, click \"Keep my commitment\" in the app, or run: mastboundctl recover --cancel\n")
    }

    private static func say(_ text: String) {
        print(text)
        fflush(stdout)
    }

    /// Reads one line; anything other than `answer` (exactly) stops the flow.
    private static func expect(_ prompt: String, _ answer: String) throws {
        print(prompt, terminator: "")
        fflush(stdout)
        guard let line = readLine(strippingNewline: true), line == answer else {
            say("\nThat does not match.")
            throw Stopped()
        }
    }

    static func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds)
        let days = total / 86_400, hours = (total % 86_400) / 3_600, minutes = (total % 3_600) / 60
        return days > 0 ? "\(days) d \(hours) h \(minutes) min" : "\(hours) h \(minutes) min"
    }
}
