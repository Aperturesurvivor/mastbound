import RoasterCore
import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                statusCard
                permanentProtectionCard
                scheduledRulesCard
                actionBar
            }
            .padding(28)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .toolbar {
            Button("Refresh status") { model.refreshStatus() }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Screen Time Roaster Mac")
                .font(.system(size: 32, weight: .bold, design: .rounded))
            Text("Automatic, local-only boundaries that close the device-shift loophole.")
                .foregroundStyle(.secondary)
        }
    }

    private var statusCard: some View {
        GroupBox("Current status") {
            VStack(alignment: .leading, spacing: 8) {
                Label(
                    model.isInstalled ? "Enforcement service installed" : "Enforcement service not installed",
                    systemImage: model.isInstalled ? "checkmark.shield.fill" : "shield.slash"
                )
                if let state = model.enforcementState, !state.activeRules.isEmpty {
                    ForEach(state.activeRules) { rule in
                        Label(
                            "\(rule.name) until \(rule.activeUntil.formatted(date: .omitted, time: .shortened))",
                            systemImage: "lock.fill"
                        )
                    }
                } else if model.isInstalled {
                    Label("Internal enforcement details are private to the root service", systemImage: "lock.shield")
                } else {
                    Label("No scheduled rule is active right now", systemImage: "clock")
                }
                Text(model.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    private var permanentProtectionCard: some View {
        GroupBox("Permanent adult-content protection") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Keep the validated adult-domain list blocked at all times", isOn: $model.configuration.permanentProtection.enabled)
                    .disabled(model.permanentProtectionIsLocked)
                if let metadata = model.metadata {
                    Text("\(metadata.domainCount.formatted()) domains cached · updated \(metadata.fetchedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Text("No validated adult-content list is cached yet.")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                HStack {
                    Button(model.isBusy ? "Working…" : "Update validated list") {
                        Task { await model.refreshAdultProtection() }
                    }
                    .disabled(model.isBusy)
                    Link("Source and attribution", destination: URL(string: "https://github.com/StevenBlack/hosts")!)
                }
                Text("Downloads happen in the unprivileged app. The root service never accesses the internet and accepts only strict domain syntax from the local cache.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if model.permanentProtectionIsLocked {
                    Text("Protection is locked and additive. Removing it requires the administrator-authorized enforcement uninstall.")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    private var scheduledRulesCard: some View {
        GroupBox("Recurring rules") {
            VStack(spacing: 16) {
                ForEach($model.configuration.scheduledRules) { $rule in
                    RuleEditor(rule: $rule)
                    if rule.id != model.configuration.scheduledRules.last?.id {
                        Divider()
                    }
                }
            }
            .padding(6)
        }
    }

    private var actionBar: some View {
        HStack {
            Button("Save configuration") { model.save() }
                .buttonStyle(.borderedProminent)
            Button(model.isInstalled ? "Repair installation" : "Install enforcement") {
                Task { await model.install() }
            }
            .disabled(model.isBusy)
            Spacer()
            if model.isInstalled {
                Button("Remove enforcement", role: .destructive) {
                    Task { await model.uninstallEnforcement() }
                }
                .disabled(model.isBusy)
            }
        }
    }
}

private struct RuleEditor: View {
    @Binding var rule: ScheduledRule

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $rule.enabled) {
                TextField("Rule name", text: $rule.name)
                    .font(.headline)
                    .textFieldStyle(.plain)
            }
            HStack {
                DatePicker("Start", selection: minuteBinding(\ScheduledRule.schedule.startMinute), displayedComponents: .hourAndMinute)
                DatePicker("End", selection: minuteBinding(\ScheduledRule.schedule.endMinute), displayedComponents: .hourAndMinute)
            }
            if !rule.domains.isEmpty {
                Text("Domains")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextEditor(text: domainsBinding)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 92)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            }
            ForEach($rule.endpoints.indices, id: \.self) { index in
                HStack {
                    TextField("IP address", text: $rule.endpoints[index].address)
                    TextField(
                        "Port",
                        value: $rule.endpoints[index].port,
                        format: .number.grouping(.never)
                    )
                    .frame(width: 100)
                }
            }
            Text("Active rules are immutable until their scheduled end. New targets can be added while active; removals take effect afterward.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var domainsBinding: Binding<String> {
        Binding(
            get: { rule.domains.joined(separator: "\n") },
            set: { rule.domains = $0.split(whereSeparator: \Character.isNewline).map(String.init) }
        )
    }

    private func minuteBinding(_ keyPath: WritableKeyPath<ScheduledRule, Int>) -> Binding<Date> {
        Binding(
            get: {
                let minute = rule[keyPath: keyPath]
                return Calendar.current.date(
                    bySettingHour: minute / 60,
                    minute: minute % 60,
                    second: 0,
                    of: Date()
                ) ?? Date()
            },
            set: {
                let components = Calendar.current.dateComponents([.hour, .minute], from: $0)
                rule[keyPath: keyPath] = (components.hour ?? 0) * 60 + (components.minute ?? 0)
            }
        )
    }
}
