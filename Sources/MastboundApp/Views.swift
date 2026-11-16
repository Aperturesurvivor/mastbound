import MastboundCore
import SwiftUI

struct RootView: View {
    @Bindable var model: AppModel
    /// Screenshots pass a fixed screen and skip the timers.
    var fixedScreen: Screen?

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
                case .active(let remaining, let end):
                    ActiveView(model: model, remaining: remaining, end: end, recoveryRemaining: nil)
                case .recovering(let remaining, let recovery, let end):
                    ActiveView(model: model, remaining: remaining, end: end, recoveryRemaining: recovery)
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
    static let presets = [1, 7, 30, 90, 365].map(DurationOption.init)
}

struct StartView: View {
    let model: AppModel
    let lastEnd: EndRecord?
    @State private var days = 30
    @State private var confirming = false

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
            PresetGrid(days: $days).padding(.top, 10)
            DayStepper(days: $days).padding(.top, Theme.spacing)

            Spacer(minLength: 24)

            HStack {
                Text("Ends")
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Text(endDate.formatted(date: .abbreviated, time: .shortened))
                    .monospacedDigit()
            }
            .font(.system(size: 13))
            .padding(.bottom, 14)

            Button(confirming ? "Confirm — start \(DurationOption(days: days).title)" : "Start") {
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

            Text(confirming ? "There is no way to end it early from the app." : "You will be asked for your Mac password.")
                .font(.system(size: 11))
                .foregroundStyle(confirming ? Theme.warning : Theme.textTertiary)
                .frame(maxWidth: .infinity)
                .padding(.top, 10)
        }
        .onChange(of: days) { confirming = false }
    }

    private var endDate: Date { Date().addingTimeInterval(Double(days) * 86_400) }
}

private struct PresetGrid: View {
    @Binding var days: Int
    var body: some View {
        HStack(spacing: 6) {
            ForEach(DurationOption.presets) { option in
                let selected = option.days == days
                Button { days = option.days } label: {
                    Text(option.title)
                        .font(.system(size: 12, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Theme.background : Theme.textPrimary)
                        .frame(maxWidth: .infinity, minHeight: 34)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(selected ? Theme.textPrimary : Theme.surface)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(selected ? .clear : Theme.stroke)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct DayStepper: View {
    @Binding var days: Int
    var range: ClosedRange<Int> = 1...365

    var body: some View {
        HStack {
            Text("Custom")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            stepButton("minus") { days = max(range.lowerBound, days - 1) }
                .disabled(days <= range.lowerBound)
            Text("\(days) \(days == 1 ? "day" : "days")")
                .font(.system(size: 13, weight: .medium))
                .monospacedDigit()
                .frame(minWidth: 72)
            stepButton("plus") { days = min(range.upperBound, days + 1) }
                .disabled(days >= range.upperBound)
        }
        .padding(.leading, 14).padding(.trailing, 6)
        .frame(height: 44)
        .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.stroke))
    }

    private func stepButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 32, height: 32)
                .background(Circle().fill(Theme.surfaceRaised))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .buttonRepeatBehavior(.enabled)
    }
}

// MARK: - Active and recovering

struct ActiveView: View {
    let model: AppModel
    let remaining: Double
    let end: Date?
    let recoveryRemaining: Double?
    @State private var addingTime = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 12)
            Text(recoveryRemaining != nil ? "ENDING EARLY" : "TIME LEFT")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(recoveryRemaining != nil ? Theme.warning : Theme.textTertiary)
            // During an early end, count down to when the block really ends.
            Countdown(seconds: recoveryRemaining ?? remaining).padding(.top, 14)
            if let end = recoveryRemaining.map({ Date().addingTimeInterval($0) }) ?? end {
                Text("Ends \(end.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().year().hour().minute()))")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .monospacedDigit()
                    .padding(.top, 10)
            }
            if let recoveryRemaining {
                RecoveryNote(commitmentRemaining: remaining).padding(.top, 28)
            }
            Spacer(minLength: 24)

            if recoveryRemaining != nil {
                Button(model.isBusy ? "Keeping it…" : "Keep my commitment") {
                    Task { await model.cancelRecovery() }
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
            Text("Blocking adult sites on this Mac.")
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
                .foregroundStyle(Theme.warning)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
    }
}
