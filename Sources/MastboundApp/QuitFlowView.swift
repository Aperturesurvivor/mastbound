import MastboundCore
import SwiftUI

// The in-app early-end flow. It is long on purpose: more than an hour of
// terms, puzzles, writing and waiting, and then the 72-hour delay. "Keep my
// commitment" is the big button on every step and stops it with one click.
//
// The app's steps are friction only. The real lock is in the daemon: it
// refuses to finish until the flow has been open for
// `Policy.quitFlowMinimumSeconds` (1 hour) of credited time.

enum QuitStep: Int, CaseIterable {
    case intro, terms, codes, math, grid, reasons, coolOff, hold, facts, final

    var title: String {
        switch self {
        case .intro: "End early?"
        case .terms: "Terms"
        case .codes: "Codes"
        case .math: "Sums"
        case .grid: "Grids"
        case .reasons: "Write"
        case .coolOff: "Wait"
        case .hold: "Hold"
        case .facts: "Facts"
        case .final: "Last step"
        }
    }
}

struct QuitFlowView: View {
    let model: AppModel
    let remaining: Double
    let quitElapsed: Double?
    @State private var step: QuitStep
    @State private var began: Bool
    /// Answers given faster than a careful person would. Three in a row of
    /// these (not necessarily in a row) bring up the slow-down screen.
    @State private var quickCount = 0
    @State private var slowingDown: Bool
    /// ImageRenderer draws ScrollView content blank, so screenshots skip it.
    private let forSnapshot: Bool

    init(model: AppModel, remaining: Double, quitElapsed: Double?, initialStep: QuitStep = .intro, slowDown: Bool = false, forSnapshot: Bool = false) {
        self.model = model
        self.forSnapshot = forSnapshot
        self.remaining = remaining
        self.quitElapsed = quitElapsed
        _step = State(initialValue: initialStep)
        _began = State(initialValue: initialStep != .intro)
        _slowingDown = State(initialValue: slowDown)
    }

    private var timing: QuitTiming { model.timing }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                // No step count and no progress bar: the person does not
                // get to see how much is left.
                Text("ENDING EARLY")
                    .foregroundStyle(Theme.textSecondary)
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Rectangle().fill(Theme.surfaceRaised).frame(height: 1)
            }
            .padding(.top, 4)

            if forSnapshot {
                content.environment(\.isSnapshot, true)
                Spacer(minLength: 0)
            } else {
                ScrollView { content }
                    .scrollIndicators(.never)
                    .id(step) // start each step at the top
            }

            Button(model.isBusy ? "Keeping it…" : "Keep my commitment") {
                Task {
                    if began { await model.stopEarlyEnd() } else { model.closeQuitFlow() }
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(model.isBusy)
            .padding(.top, 12)
        }
        .onChange(of: quitElapsed == nil) { _, isNil in
            // The open flow lapsed or was stopped from somewhere else.
            if began && isNil { model.closeQuitFlow() }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(slowingDown ? "Slow down" : step.title)
                .font(.system(size: 22, weight: .semibold))
                .padding(.top, 18)
                .padding(.bottom, 12)
            ZStack(alignment: .topLeading) {
                // Kept alive under the slow-down screen, so no progress is lost.
                stepBody
                    .opacity(slowingDown ? 0 : 1)
                    .disabled(slowingDown)
                    .accessibilityHidden(slowingDown)
                if slowingDown {
                    SlowDownView {
                        withAnimation(.easeOut(duration: 0.3)) { slowingDown = false }
                    }
                    .transition(.opacity)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Steps call this after each answer. Every third quick answer stops
    /// the flow until the person drags the resisting slider and holds it.
    private func pace(quick: Bool) {
        guard quick else { return }
        quickCount += 1
        if quickCount >= 3 {
            quickCount = 0
            withAnimation(.easeOut(duration: 0.3)) { slowingDown = true }
        }
    }

    private func next() {
        guard let following = QuitStep(rawValue: step.rawValue + 1) else { return }
        withAnimation(.easeOut(duration: 0.15)) { step = following }
    }

    @ViewBuilder private var stepBody: some View {
        switch step {
        case .intro:
            IntroStep(model: model, remaining: remaining, timing: timing) {
                began = true
                next()
            }
        case .terms: TermsStep(elapsed: model.elapsedNow(), timing: timing, pace: pace, done: next)
        case .codes: CodesStep(timing: timing, pace: pace, done: next)
        case .math: MathStep(timing: timing, pace: pace, done: next)
        case .grid: GridStep(timing: timing, pace: pace, done: next)
        case .reasons: ReasonsStep(timing: timing, done: next)
        case .coolOff: CoolOffStep(timing: timing, done: next)
        case .hold: HoldStep(timing: timing, done: next)
        case .facts: FactsStep(remaining: remaining, timing: timing, done: next)
        case .final: FinalStep(model: model, quitElapsed: quitElapsed, timing: timing)
        }
    }
}

// MARK: - Shared parts

private struct Prose: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(Theme.textSecondary)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The quiet button that moves the flow forward.
private struct ForwardButton: View {
    let title: String
    var enabled = true
    let action: () -> Void
    var body: some View {
        Button(title, action: action)
            .buttonStyle(SecondaryButtonStyle())
            .disabled(!enabled)
            .padding(.top, 16)
    }
}

/// True in `--snapshot` renders, where AppKit text controls draw blank.
private struct SnapshotKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    var isSnapshot: Bool {
        get { self[SnapshotKey.self] }
        set { self[SnapshotKey.self] = newValue }
    }
}

private struct Field: View {
    let placeholder: String
    @Binding var text: String
    var onSubmit: () -> Void = {}
    @Environment(\.isSnapshot) private var isSnapshot
    var body: some View {
        Group {
            if isSnapshot {
                Text(placeholder).foregroundStyle(Theme.textTertiary).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField(placeholder, text: $text)
            }
        }
            .textFieldStyle(.plain)
            .font(.system(size: 14))
            .autocorrectionDisabled()
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.stroke))
            .onSubmit(onSubmit)
    }
}

/// After a wrong answer: "Wrong. Try again in 18 s."
private struct Penalty {
    var until: Date?
    mutating func start(_ seconds: Double) { until = Date().addingTimeInterval(seconds) }
    func secondsLeft(at now: Date) -> Int {
        guard let until else { return 0 }
        return max(0, Int(until.timeIntervalSince(now).rounded(.up)))
    }
}

private struct PenaltyNote: View {
    let penalty: Penalty
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let left = penalty.secondsLeft(at: context.date)
            Text(left > 0 ? "Wrong. Try again in \(left) s." : " ")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .padding(.top, 8)
        }
    }
}

/// Re-renders once a second, so waits and locks count down.
private struct Ticking<Content: View>: View {
    @ViewBuilder let content: (Date) -> Content
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in content(context.date) }
    }
}

private func clock(_ seconds: Double) -> String {
    let total = max(0, Int(seconds.rounded(.up)))
    return total >= 3_600
        ? String(format: "%d:%02d:%02d", total / 3_600, (total % 3_600) / 60, total % 60)
        : String(format: "%d:%02d", total / 60, total % 60)
}

// MARK: - 1. Intro

private struct IntroStep: View {
    let model: AppModel
    let remaining: Double
    let timing: QuitTiming
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Prose("Over \(timing.gate >= 3600 ? "an hour" : "\(Int(timing.gate / 60)) minutes") of puzzles and waiting. Then the block stays \(QuitTerms.delayText) more.")
            ForwardButton(title: model.isBusy ? "Waiting for password…" : "Begin", enabled: !model.isBusy) {
                Task { if await model.beginQuit() { done() } }
            }
        }
    }
}

// MARK: - Slow down

/// Shown after three quick answers. The person must drag a slider that
/// resists more the further it goes, then hold it at the end.
private struct SlowDownView: View {
    let done: () -> Void
    static let holdSeconds = 10.0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("You seem pretty eager to break your commitment. You should slow down.")
                .font(.system(size: 20, weight: .light))
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
            ResistingSlider(holdSeconds: Self.holdSeconds, done: done)
                .padding(.top, 36)
        }
    }
}

private struct ResistingSlider: View {
    let holdSeconds: Double
    let done: () -> Void
    /// How far the pointer has moved, in points. The knob moves less and
    /// less for each point: the last part needs about three times the
    /// track's length of pull.
    @State private var pull = 0.0
    @State private var heldSince: Date?
    @State private var held = 0.0
    private let knob = 44.0
    private let inset = 4.0

    var body: some View {
        VStack(spacing: 10) {
            GeometryReader { geometry in
                let travel = max(1, geometry.size.width - knob - inset * 2)
                let fraction = 1 - exp(-pull / (travel * 0.6))
                let atEnd = fraction >= 0.95
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.surface)
                    Capsule().strokeBorder(Theme.stroke)
                    Capsule().fill(Theme.surfaceRaised)
                        .frame(width: knob + inset * 2 + travel * fraction)
                    Text(atEnd ? "Keep holding" : "Slide to keep going")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(maxWidth: .infinity)
                        .opacity(atEnd ? 1 : max(0, 1 - fraction * 2))
                    Circle()
                        .fill(Theme.textPrimary)
                        .frame(width: knob, height: knob)
                        .overlay(
                            Image(systemName: "chevron.right")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Theme.background)
                        )
                        .offset(x: inset + travel * fraction)
                        .gesture(
                            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                                .onChanged { value in pull = max(0, value.translation.width) }
                                .onEnded { _ in
                                    withAnimation(.spring(response: 0.45, dampingFraction: 0.7)) { pull = 0 }
                                }
                        )
                }
                .onChange(of: atEnd) { _, now in heldSince = now ? Date() : nil }
            }
            .frame(height: knob + inset * 2)

            // How long it has been held at the end.
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.surfaceRaised)
                    Capsule().fill(Theme.textSecondary).frame(width: geometry.size.width * held)
                }
            }
            .frame(height: 3)
            .opacity(heldSince == nil ? 0 : 1)
            Text(heldSince == nil ? " " : "\(Int((holdSeconds * (1 - held)).rounded(.up))) s")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
                .monospacedDigit()
        }
        .task(id: heldSince) {
            guard let start = heldSince else { held = 0; return }
            while !Task.isCancelled {
                held = min(1, Date().timeIntervalSince(start) / holdSeconds)
                if held >= 1 { done(); return }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }
}

// MARK: - 2. Terms

private struct TermsStep: View {
    let timing: QuitTiming
    let pace: (_ quick: Bool) -> Void
    let done: () -> Void
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var introDone = false
    @State private var introShown = false
    @State private var buttonShown = false
    @State private var terms: [String]
    @State private var index = 0
    @State private var shownAt = Date()
    @State private var typed = ""
    @State private var penalty = Penalty()

    init(elapsed: Double?, timing: QuitTiming, pace: @escaping (_ quick: Bool) -> Void, done: @escaping () -> Void) {
        self.timing = timing
        self.pace = pace
        self.done = done
        _terms = State(initialValue: QuitTerms.filled(elapsedSeconds: elapsed).shuffled())
    }

    /// Every third term must be typed out in full.
    private var mustType: Bool { index % 3 == 2 }

    var body: some View {
        if introDone { statements } else { intro }
    }

    /// A first screen that fades in slowly, before the statements.
    private var intro: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Read each statement. Agree to all \(terms.count) to go on.")
                .font(.system(size: 20, weight: .light))
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 36)
                .opacity(introShown || isSnapshot ? 1 : 0)
            ForwardButton(title: "Continue", enabled: buttonShown) {
                introDone = true
                shownAt = Date()
            }
            .padding(.top, 24)
            .opacity(buttonShown || isSnapshot ? 1 : 0)
        }
        .onAppear {
            withAnimation(.easeIn(duration: 1.8)) { introShown = true }
            withAnimation(.easeIn(duration: 0.6).delay(2.6)) { buttonShown = true }
        }
    }

    private var statements: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("TERM \(index + 1) OF \(terms.count)")
                .font(.system(size: 11, weight: .semibold)).tracking(0.8)
                .foregroundStyle(Theme.textTertiary)
            Text(terms[index])
                .font(.system(size: 15))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.surface))
                .padding(.top, 8)

            Ticking { now in
                let wait = max(0, timing.termDelay - now.timeIntervalSince(shownAt))
                let locked = penalty.secondsLeft(at: now) > 0
                VStack(alignment: .leading, spacing: 0) {
                    if mustType {
                        Prose("Type it to agree.").padding(.top, 14).padding(.bottom, 8)
                        Field(placeholder: "Type the statement", text: $typed, onSubmit: checkTyped)
                        ForwardButton(title: "Agree", enabled: !locked && !typed.isEmpty, action: checkTyped)
                    } else {
                        Button {
                            pace(Date().timeIntervalSince(shownAt) - timing.termDelay < 1.5)
                            advance()
                        } label: {
                            HStack(spacing: 10) {
                                RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.strokeStrong, lineWidth: 1.5)
                                    .frame(width: 18, height: 18)
                                Text(wait > 0 ? "I agree (\(Int(wait.rounded(.up))) s)" : "I agree")
                                    .font(.system(size: 14))
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(wait > 0)
                        .foregroundStyle(wait > 0 ? Theme.textTertiary : Theme.textPrimary)
                        .padding(.top, 16)
                    }
                }
            }
            PenaltyNote(penalty: penalty)
        }
    }

    private func checkTyped() {
        guard penalty.secondsLeft(at: Date()) == 0 else { return }
        if typed.trimmingCharacters(in: .whitespaces) == terms[index] {
            // About 80 words a minute or faster.
            pace(Date().timeIntervalSince(shownAt) < Double(terms[index].count) * 0.15)
            advance()
        } else {
            typed = ""
            penalty.start(timing.penalty)
        }
    }

    private func advance() {
        typed = ""
        if index + 1 < terms.count {
            index += 1
            shownAt = Date()
        } else {
            done()
        }
    }
}

// MARK: - 3. Distorted codes

/// A code drawn with each letter turned and moved, over noise lines.
struct CaptchaCode: Equatable {
    struct Glyph: Equatable { var character: Character; var angle: Double; var dy: Double; var size: Double; var heavy: Bool }
    var text: String
    var glyphs: [Glyph]
    var lines: [[CGPoint]]

    static let alphabet = Array("ABCDEFGHJKMNPQRSTUVWXYZ23456789")

    static func random(length: Int = 6) -> CaptchaCode {
        let characters = (0..<length).map { _ in alphabet.randomElement()! }
        return CaptchaCode(
            text: String(characters),
            glyphs: characters.map {
                Glyph(character: $0, angle: .random(in: -32...32), dy: .random(in: -9...9), size: .random(in: 24...34), heavy: .random())
            },
            lines: (0..<7).map { _ in
                (0..<4).map { _ in CGPoint(x: .random(in: 0...1), y: .random(in: 0...1)) }
            }
        )
    }
}

struct CaptchaImage: View {
    let code: CaptchaCode
    var body: some View {
        Canvas { context, size in
            for line in code.lines {
                var path = Path()
                path.move(to: CGPoint(x: line[0].x * size.width, y: line[0].y * size.height))
                path.addCurve(
                    to: CGPoint(x: line[3].x * size.width, y: line[3].y * size.height),
                    control1: CGPoint(x: line[1].x * size.width, y: line[1].y * size.height),
                    control2: CGPoint(x: line[2].x * size.width, y: line[2].y * size.height)
                )
                context.stroke(path, with: .color(Theme.textSecondary.opacity(0.55)), lineWidth: 1.4)
            }
            let step = size.width / CGFloat(code.glyphs.count + 1)
            for (index, glyph) in code.glyphs.enumerated() {
                var copy = context
                copy.translateBy(x: step * CGFloat(index + 1), y: size.height / 2 + glyph.dy)
                copy.rotate(by: .degrees(glyph.angle))
                let text = Text(String(glyph.character))
                    .font(.system(size: glyph.size, weight: glyph.heavy ? .heavy : .light, design: index % 2 == 0 ? .serif : .rounded))
                    .foregroundStyle(Theme.textPrimary)
                copy.draw(copy.resolve(text), at: .zero)
            }
        }
        .frame(height: 84)
        .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.surfaceRaised))
        .accessibilityLabel("Distorted code")
    }
}

private struct CodesStep: View {
    let timing: QuitTiming
    let pace: (_ quick: Bool) -> Void
    let done: () -> Void
    static let rounds = 5
    @State private var round = 0
    @State private var shownAt = Date()
    @State private var code = CaptchaCode.random()
    @State private var typed = ""
    @State private var penalty = Penalty()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Prose("Type the code. \(round + 1) of \(Self.rounds).")
            CaptchaImage(code: code).padding(.top, 14)
            HStack {
                Spacer()
                Button("New code") { code = .random(); typed = ""; shownAt = Date() }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            }
            .padding(.vertical, 8)
            Field(placeholder: "Code", text: $typed, onSubmit: check)
            Ticking { now in
                ForwardButton(title: "Check", enabled: penalty.secondsLeft(at: now) == 0 && !typed.isEmpty, action: check)
            }
            PenaltyNote(penalty: penalty)
        }
    }

    private func check() {
        guard penalty.secondsLeft(at: Date()) == 0 else { return }
        let answer = typed.uppercased().filter { !$0.isWhitespace }
        typed = ""
        if answer == code.text {
            pace(Date().timeIntervalSince(shownAt) < 5)
            round += 1
            if round == Self.rounds { done() }
        } else {
            penalty.start(timing.penalty)
        }
        code = .random()
        shownAt = Date()
    }
}

// MARK: - 4. Arithmetic

private struct MathStep: View {
    let timing: QuitTiming
    let pace: (_ quick: Bool) -> Void
    let done: () -> Void
    static let rounds = 5
    @State private var round = 0
    @State private var shownAt = Date()
    @State private var problem = Problem.random()
    @State private var typed = ""
    @State private var penalty = Penalty()

    struct Problem: Equatable {
        var a: Int, b: Int, c: Int
        var answer: Int { a * b - c }
        static func random() -> Problem { Problem(a: .random(in: 13...97), b: .random(in: 13...97), c: .random(in: 101...899)) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Prose("No calculator. \(round + 1) of \(Self.rounds).")
            Text("\(problem.a) × \(problem.b) − \(problem.c) = ?")
                .font(.system(size: 30, weight: .light))
                .monospacedDigit()
                .padding(.vertical, 22)
                .frame(maxWidth: .infinity)
            Field(placeholder: "Answer", text: $typed, onSubmit: check)
            Ticking { now in
                ForwardButton(title: "Check", enabled: penalty.secondsLeft(at: now) == 0 && !typed.isEmpty, action: check)
            }
            PenaltyNote(penalty: penalty)
        }
    }

    private func check() {
        guard penalty.secondsLeft(at: Date()) == 0 else { return }
        let answer = Int(typed.filter { $0.isNumber || $0 == "-" })
        typed = ""
        if answer == problem.answer {
            pace(Date().timeIntervalSince(shownAt) < 10)
            round += 1
            if round == Self.rounds { done() }
        } else {
            penalty.start(timing.penalty)
        }
        problem = .random()
        shownAt = Date()
    }
}

// MARK: - 5. Grid

private struct GridStep: View {
    let timing: QuitTiming
    let pace: (_ quick: Bool) -> Void
    let done: () -> Void
    static let rounds = 3
    @State private var round = 0
    @State private var shownAt = Date()
    @State private var grid = Grid.random()
    @State private var selected: Set<Int> = []
    @State private var penalty = Penalty()

    struct Grid: Equatable {
        struct Cell: Equatable { var digit: Int; var angle: Double; var size: Double; var dx: Double; var dy: Double }
        var target: Int
        var cells: [Cell]
        var answer: Set<Int> { Set(cells.indices.filter { cells[$0].digit == target }) }

        /// No 1, 6 or 9: turned, they look like 7, 9 and 6.
        static let digits = [0, 2, 3, 4, 5, 7, 8]

        static func random() -> Grid {
            let target = digits.randomElement()!
            let hits = Set((0..<16).shuffled().prefix(.random(in: 3...6)))
            let cells = (0..<16).map { index -> Cell in
                let digit = hits.contains(index) ? target : digits.filter { $0 != target }.randomElement()!
                return Cell(digit: digit, angle: .random(in: -25...25), size: .random(in: 18...30), dx: .random(in: -10...10), dy: .random(in: -7...7))
            }
            return Grid(target: target, cells: cells)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Prose("Select every \(grid.target). \(round + 1) of \(Self.rounds).")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                ForEach(grid.cells.indices, id: \.self) { index in
                    let cell = grid.cells[index]
                    let on = selected.contains(index)
                    Button {
                        if on { selected.remove(index) } else { selected.insert(index) }
                    } label: {
                        Text("\(cell.digit)")
                            .font(.system(size: cell.size, weight: index % 3 == 0 ? .black : .regular, design: index % 2 == 0 ? .serif : .rounded))
                            .rotationEffect(.degrees(cell.angle))
                            .offset(x: cell.dx, y: cell.dy)
                            .frame(maxWidth: .infinity)
                            .frame(height: 56)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(on ? Theme.surfaceRaised : Theme.surface))
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(on ? Theme.textPrimary : Theme.stroke, lineWidth: on ? 1.5 : 1))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 14)
            Ticking { now in
                ForwardButton(title: "Verify", enabled: penalty.secondsLeft(at: now) == 0, action: check)
            }
            PenaltyNote(penalty: penalty)
        }
    }

    private func check() {
        guard penalty.secondsLeft(at: Date()) == 0 else { return }
        if selected == grid.answer {
            pace(Date().timeIntervalSince(shownAt) < 5)
            round += 1
            if round == Self.rounds { done(); return }
        } else {
            penalty.start(timing.penalty)
        }
        selected = []
        grid = .random()
        shownAt = Date()
    }
}

// MARK: - 6. Written answers

private struct ReasonsStep: View {
    let timing: QuitTiming
    let done: () -> Void
    static let prompts = [
        "What are you feeling right now, and when did it start?",
        "Who would you be letting down, and what would you say to them?",
        "What will you do in the next hour instead, if you stop here?",
    ]
    static let minimumCharacters = 150
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var index = 0
    @State private var text = ""
    @State private var shownAt = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Prose("\(index + 1) of \(Self.prompts.count).")
            Text(Self.prompts[index])
                .font(.system(size: 15))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)
            Group {
                if isSnapshot { Color.clear } else { TextEditor(text: $text) }
            }
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(height: 130)
                .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.surface))
                .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.stroke))
                .padding(.top, 10)
            Ticking { now in
                let count = text.trimmingCharacters(in: .whitespacesAndNewlines).count
                let wait = max(0, timing.reasonMinimum - now.timeIntervalSince(shownAt))
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(min(count, Self.minimumCharacters)) / \(Self.minimumCharacters) characters" + (wait > 0 ? " · \(Int(wait.rounded(.up))) s" : ""))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                        .monospacedDigit()
                        .padding(.top, 6)
                    ForwardButton(title: "Next", enabled: count >= Self.minimumCharacters && wait == 0) {
                        text = ""
                        shownAt = Date()
                        if index + 1 < Self.prompts.count { index += 1 } else { done() }
                    }
                }
            }
        }
    }
}

// MARK: - 7. Cooling-off wait

private struct CoolOffStep: View {
    let timing: QuitTiming
    let done: () -> Void
    @State private var startedAt = Date()

    var body: some View {
        Ticking { now in
            let left = max(0, timing.coolOff - now.timeIntervalSince(startedAt))
            VStack(alignment: .leading, spacing: 0) {
                Prose("The urge gets weaker from here.")
                Text(clock(left))
                    .font(.system(size: 56, weight: .thin))
                    .monospacedDigit()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                ForwardButton(title: "Continue", enabled: left == 0, action: done)
            }
        }
    }
}

// MARK: - 8. Hold

private struct HoldStep: View {
    let timing: QuitTiming
    let done: () -> Void
    @State private var pressing = false
    @State private var progress = 0.0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Prose("Hold for \(Int(timing.hold)) seconds. Letting go starts over.")
            ZStack {
                Circle().stroke(Theme.surfaceRaised, lineWidth: 6)
                Circle().trim(from: 0, to: progress)
                    .stroke(Theme.textPrimary, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(pressing ? "\(Int((timing.hold * (1 - progress)).rounded(.up))) s" : "Hold")
                    .font(.system(size: 20, weight: .light))
                    .monospacedDigit()
            }
            .frame(width: 150, height: 150)
            .contentShape(Circle())
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in if !pressing { pressing = true } }
                    .onEnded { _ in pressing = false }
            )
        }
        .task(id: pressing) {
            guard pressing else { progress = 0; return }
            let start = Date()
            while !Task.isCancelled {
                progress = min(1, Date().timeIntervalSince(start) / timing.hold)
                if progress >= 1 { done(); return }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }
}

// MARK: - 9. Facts

private struct FactsStep: View {
    let remaining: Double
    let timing: QuitTiming
    let done: () -> Void
    @State private var days = ""
    @State private var phrase = ""
    @State private var penalty = Penalty()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Prose("Full days left?")
            Field(placeholder: "Days left", text: $days).padding(.top, 10)
            Prose("Type:").padding(.top, 16)
            Text(Policy.recoveryPhrase)
                .font(.system(size: 14, weight: .medium))
                .padding(.vertical, 8)
            Field(placeholder: "Sentence", text: $phrase, onSubmit: check)
            Ticking { now in
                ForwardButton(title: "Check", enabled: penalty.secondsLeft(at: now) == 0 && !days.isEmpty && !phrase.isEmpty, action: check)
            }
            PenaltyNote(penalty: penalty)
        }
    }

    private func check() {
        guard penalty.secondsLeft(at: Date()) == 0 else { return }
        if Int(days.trimmingCharacters(in: .whitespaces)) == Int(remaining / 86_400), phrase == Policy.recoveryPhrase {
            done()
        } else {
            days = ""
            phrase = ""
            penalty.start(timing.penalty * 3)
        }
    }
}

// MARK: - 10. Final

private struct FinalStep: View {
    let model: AppModel
    let quitElapsed: Double?
    let timing: QuitTiming
    @State private var understood = false
    @State private var typed = ""

    var body: some View {
        let wait = max(0, timing.gate - (quitElapsed ?? 0))
        VStack(alignment: .leading, spacing: 0) {
            if wait > 0 {
                Prose("Opens in")
                Text(clock(wait))
                    .font(.system(size: 56, weight: .thin))
                    .monospacedDigit()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else {
                Prose("Then the block stays \(QuitTerms.delayText) more.")
            }
            Button {
                understood.toggle()
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(understood ? Theme.textPrimary : Theme.strokeStrong, lineWidth: 1.5)
                        .background(RoundedRectangle(cornerRadius: 4).fill(understood ? Theme.textPrimary : .clear))
                        .overlay(Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.background).opacity(understood ? 1 : 0))
                        .frame(width: 18, height: 18)
                    Text("I decided this myself.")
                        .font(.system(size: 13))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 16)
            Prose("Type END.").padding(.top, 16).padding(.bottom, 8)
            Field(placeholder: "END", text: $typed)
            Button(model.isBusy ? "Waiting for password…" : "End early") {
                Task { _ = await model.finishQuit() }
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(wait > 0 || !understood || typed != "END" || model.isBusy)
            .padding(.top, 16)
        }
    }
}
