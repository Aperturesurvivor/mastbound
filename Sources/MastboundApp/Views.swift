import MastboundCore
import SwiftUI

struct RootView: View {
    @Bindable var model: AppModel
    /// Screenshots pass a fixed screen and skip the timers.
    var fixedScreen: Screen?
    /// Screenshots of the early-end flow.
    var fixedQuitStep: QuitStep?
    var fixedSlowDown = false

    var body: some View {
        let screen = fixedScreen ?? model.screen
        VStack(spacing: 0) {
            Header(isDemo: model.isDemo)
            Group {
                switch screen {
                case .loading:
                    ProgressView().controlSize(.small).frame(maxHeight: .infinity)
                case .idle(let lastEnd):
                    StartView(model: model, lastEnd: lastEnd)
                case .active(let remaining, let end, let quitElapsed):
                    if let step = fixedQuitStep {
                        QuitFlowView(model: model, remaining: remaining, quitElapsed: quitElapsed, initialStep: step, slowDown: fixedSlowDown, forSnapshot: true)
                    } else if model.quitFlowOpen {
                        QuitFlowView(model: model, remaining: remaining, quitElapsed: quitElapsed)
                    } else {
                        ActiveView(model: model, remaining: remaining, end: end, recoveryRemaining: nil, quitElapsed: quitElapsed)
                    }
                case .recovering(let remaining, let recovery, let end):
                    ActiveView(model: model, remaining: remaining, end: end, recoveryRemaining: recovery, quitElapsed: nil)
                case .problem(let message):
                    ProblemView(message: message)
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 28)
        }
        .frame(width: Theme.windowSize.width, height: Theme.windowSize.height)
        .background(Theme.background)
        .foregroundStyle(Theme.textPrimary)
        .preferredColorScheme(.dark)
        .task(id: fixedScreen == nil) {
            guard fixedScreen == nil else { return }
            model.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                model.refresh()
            }
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

private struct Header: View {
    let isDemo: Bool
    var body: some View {
        HStack(spacing: 8) {
            Text("Mastbound")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            if isDemo {
                Text("Demo").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 36) // room for the hidden title bar's window buttons
        .padding(.bottom, 8)
    }
}

// MARK: - Start

struct DurationOption: Hashable, Identifiable {
    let days: Int
    var id: Int { days }
    var title: String {
        switch days {
        case 1: "1 day"
        case 7: "1 week"
        case 365: "1 year"
        default: "\(days) days"
        }
    }
    /// Big number and unit: weeks and months read better than "90 days".
    /// Months are 30-day steps; the end date shows the exact day.
    var parts: (number: String, unit: String) {
        switch days {
        case 365: ("1", "year")
        case 30: ("1", "month")
        case 7: ("1", "week")
        case let d where d >= 60 && d % 30 == 0: ("\(d / 30)", "months")
        case let d where d >= 14 && d % 7 == 0: ("\(d / 7)", "weeks")
        case let d: ("\(d)", d == 1 ? "day" : "days")
        }
    }
    var longTitle: String { "\(parts.number) \(parts.unit)" }

    /// Slider stops: fine at the short end, wider at the long end.
    static let stops = [1, 2, 3, 4, 5, 6, 7, 10, 14, 21, 30, 45, 60, 90, 120, 150, 180, 240, 300, 365]
    static let ticks: [(days: Int, label: String)] = [(1, "1d"), (7, "1w"), (30, "1m"), (90, "3m"), (180, "6m"), (365, "1y")]
}

struct StartView: View {
    let model: AppModel
    let lastEnd: EndRecord?
    @State private var index = DurationOption.stops.firstIndex(of: 30)!
    @State private var confirming = false

    private var days: Int { DurationOption.stops[index] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 12)
            Text("How long do you\nwant to commit?")
                .font(.system(size: 28, weight: .semibold))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            Text("Adult sites stay blocked for the whole time, even after a restart or if you delete the app.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
                .lineSpacing(3)
                .padding(.top, 10)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 24)

            SectionLabel(text: "Duration")
            let parts = DurationOption(days: days).parts
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(parts.number)
                    .font(.system(size: 56, weight: .thin))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(parts.unit)
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.top, 8)
            .animation(.snappy(duration: 0.18), value: days)

            StopSlider(index: $index, count: DurationOption.stops.count)
                .padding(.top, 14)
            TickRow(index: $index).padding(.top, 4)

            Spacer(minLength: 24)

            HStack {
                Text("Ends").foregroundStyle(Theme.textSecondary)
                Spacer()
                Text(endDate.formatted(.dateTime.month(.abbreviated).day().year().hour().minute()))
                    .monospacedDigit()
            }
            .font(.system(size: 13))
            .padding(.bottom, 14)

            Button(confirming ? "Confirm — start \(DurationOption(days: days).longTitle)" : "Start") {
                if confirming {
                    confirming = false
                    Task { await model.start(seconds: Double(days) * 86_400) }
                } else {
                    withAnimation(.easeOut(duration: 0.15)) { confirming = true }
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(model.isBusy)
            .keyboardShortcut(.defaultAction)

            Text(confirming ? "Ending early takes over an hour, then \(QuitTerms.delayText) more." : "You will be asked for your Mac password.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
                .frame(maxWidth: .infinity)
                .padding(.top, 10)
        }
        .onChange(of: index) { confirming = false }
    }

    private var endDate: Date { Date().addingTimeInterval(Double(days) * 86_400) }
}

/// A slider that snaps to `count` stops. Drag or click anywhere on it;
/// arrow keys move one stop.
private struct StopSlider: View {
    @Binding var index: Int
    let count: Int
    static let thumb: CGFloat = 26
    @GestureState private var dragging = false

    var body: some View {
        GeometryReader { geometry in
            let travel = geometry.size.width - Self.thumb
            let x = Self.thumb / 2 + travel * CGFloat(index) / CGFloat(count - 1)
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.surfaceRaised)
                    .frame(height: 6)
                    .padding(.horizontal, Self.thumb / 2)
                Capsule().fill(Theme.textPrimary)
                    .frame(width: max(0, x - Self.thumb / 2), height: 6)
                    .offset(x: Self.thumb / 2)
                Circle().fill(Theme.textPrimary)
                    .frame(width: Self.thumb, height: Self.thumb)
                    .background(Circle().fill(Theme.textPrimary.opacity(dragging ? 0.12 : 0.08)).frame(width: Self.thumb + (dragging ? 20 : 12), height: Self.thumb + (dragging ? 20 : 12)))
                    .shadow(color: .black.opacity(0.5), radius: 4, y: 2)
                    .offset(x: x - Self.thumb / 2)
                    .animation(.snappy(duration: 0.12), value: index)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($dragging) { _, state, _ in state = true }
                    .onChanged { value in
                        let fraction = (value.location.x - Self.thumb / 2) / max(1, travel)
                        let new = Int((fraction * CGFloat(count - 1)).rounded())
                        index = min(count - 1, max(0, new))
                    }
            )
        }
        .frame(height: 36)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { index = max(0, index - 1); return .handled }
        .onKeyPress(.rightArrow) { index = min(count - 1, index + 1); return .handled }
        .accessibilityElement()
        .accessibilityLabel("Duration")
        .accessibilityValue(DurationOption(days: DurationOption.stops[index]).longTitle)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: index = min(count - 1, index + 1)
            case .decrement: index = max(0, index - 1)
            @unknown default: break
            }
        }
    }
}

/// 1d … 1y under the slider, each one a shortcut to that stop.
private struct TickRow: View {
    @Binding var index: Int

    var body: some View {
        GeometryReader { geometry in
            let travel = geometry.size.width - StopSlider.thumb
            let last = CGFloat(DurationOption.stops.count - 1)
            ForEach(DurationOption.ticks, id: \.days) { tick in
                let stop = DurationOption.stops.firstIndex(of: tick.days)!
                Button(tick.label) { index = stop }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(stop <= index ? Theme.textSecondary : Theme.textTertiary)
                    .fixedSize()
                    .position(x: StopSlider.thumb / 2 + travel * CGFloat(stop) / last, y: 10)
            }
        }
        .frame(height: 20)
    }
}

// MARK: - Active and recovering

struct ActiveView: View {
    let model: AppModel
    let remaining: Double
    let end: Date?
    let recoveryRemaining: Double?
    /// Set when an early-end flow is open but its screens are closed.
    let quitElapsed: Double?
    @State private var addingTime = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 12)
            Text(recoveryRemaining != nil ? "ENDING EARLY" : "TIME LEFT")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(Theme.textTertiary)
            // During an early end, count down to when the block really ends.
            Countdown(seconds: recoveryRemaining ?? remaining).padding(.top, 14)
            if let end = recoveryRemaining.map({ Date().addingTimeInterval($0) }) ?? end {
                Text("Ends \(end.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().year().hour().minute()))")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .monospacedDigit()
                    .padding(.top, 10)
            }
            if recoveryRemaining != nil {
                RecoveryNote(commitmentRemaining: remaining).padding(.top, 28)
            } else if quitElapsed != nil {
                Text("An early end was started and not finished. It lapses on its own.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 28)
            }
            Spacer(minLength: 24)

            if recoveryRemaining != nil || quitElapsed != nil {
                Button(model.isBusy ? "Keeping it…" : "Keep my commitment") {
                    Task { await model.stopEarlyEnd() }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(model.isBusy)
                .padding(.bottom, Theme.spacing)
            }
            if addingTime {
                AddTimeRow(model: model, remaining: remaining) { addingTime = false }
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            } else {
                Button("Add time") { withAnimation(.easeOut(duration: 0.15)) { addingTime = true } }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(model.isBusy)
            }
            HStack(spacing: 6) {
                Text("Blocking adult sites on this Mac.")
                if recoveryRemaining == nil {
                    Text("·")
                    Button(quitElapsed == nil ? "End early" : "Start over") { model.openQuitFlow() }
                        .buttonStyle(.plain)
                        .disabled(model.isBusy)
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(Theme.textTertiary)
            .padding(.top, 12)
        }
    }
}

/// Days on top, then hours : minutes : seconds.
struct Countdown: View {
    let seconds: Double

    var body: some View {
        let total = Int(seconds.rounded(.down))
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        let secs = total % 60
        VStack(spacing: 4) {
            if days > 0 {
                Text("\(days)")
                    .font(.system(size: 88, weight: .thin))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(days == 1 ? "day left" : "days left")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
            }
            Text(String(format: "%02d:%02d:%02d", hours, minutes, secs))
                .font(.system(size: days > 0 ? 22 : 56, weight: days > 0 ? .regular : .thin))
                .monospacedDigit()
                .foregroundStyle(days > 0 ? Theme.textSecondary : Theme.textPrimary)
                .padding(.top, days > 0 ? 14 : 0)
        }
    }
}

private struct RecoveryNote: View {
    let commitmentRemaining: Double
    var body: some View {
        let days = Int(commitmentRemaining / 86_400)
        Text("Your commitment had \(days == 1 ? "1 day" : "\(days) days") left.")
            .font(.system(size: 12))
            .foregroundStyle(Theme.textSecondary)
            .multilineTextAlignment(.center)
    }
}

private struct AddTimeRow: View {
    let model: AppModel
    let remaining: Double
    let done: () -> Void
    private let options = [1, 7, 30]

    var body: some View {
        VStack(spacing: Theme.spacing) {
            SectionLabel(text: "Add time")
            HStack(spacing: 6) {
                ForEach(options, id: \.self) { days in
                    let allowed = remaining + Double(days) * 86_400 <= Policy.maximumRemainingSeconds
                    Button("+ \(DurationOption(days: days).title)") {
                        done()
                        Task { await model.extend(seconds: Double(days) * 86_400) }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(!allowed || model.isBusy)
                }
            }
            Button("Cancel", action: done)
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .padding(.top, 4)
        }
    }
}

// MARK: - Problem

private struct ProblemView: View {
    let message: String
    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Theme.textSecondary)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
    }
}
