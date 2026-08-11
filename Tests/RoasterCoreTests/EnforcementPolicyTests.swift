import Foundation
import Testing
@testable import RoasterCore

private var policyCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
}

private func policyDate(_ value: String) -> Date {
    ISO8601DateFormatter().date(from: value)!
}

@Test func startsEveryActiveRule() throws {
    let social = ScheduledRule(
        name: "Social",
        schedule: BlockSchedule(startMinute: 22 * 60, endMinute: 7 * 60),
        domains: ["x.com"]
    )
    let jellyfin = ScheduledRule(
        name: "Jellyfin",
        schedule: BlockSchedule(startMinute: 23 * 60, endMinute: 7 * 60),
        endpoints: [NetworkEndpoint(address: "192.0.2.10", port: 8096)]
    )
    let state = try EnforcementPolicy.decide(
        now: policyDate("2026-08-11T23:30:00Z"),
        configuration: RoasterConfiguration(scheduledRules: [social, jellyfin]),
        existingState: nil,
        calendar: policyCalendar
    )
    #expect(state.activeRules.count == 2)
    #expect(state.scheduledDomains == ["x.com"])
    #expect(state.scheduledEndpoints == [NetworkEndpoint(address: "192.0.2.10", port: 8096)])
}

@Test func activeRuleCannotBeRemovedOrShortened() throws {
    let existing = ActiveRuleState(
        id: UUID(),
        name: "Social",
        startedAt: policyDate("2026-08-11T22:00:00Z"),
        activeUntil: policyDate("2026-08-12T07:00:00Z"),
        domains: ["x.com"],
        endpoints: []
    )
    let configuration = RoasterConfiguration(
        enabled: false,
        scheduledRules: [],
        permanentProtection: PermanentProtection(enabled: false)
    )
    let state = try EnforcementPolicy.decide(
        now: policyDate("2026-08-11T23:00:00Z"),
        configuration: configuration,
        existingState: EnforcementState(activeRules: [existing]),
        calendar: policyCalendar
    )
    #expect(state.activeRules == [existing])
}

@Test func activeRuleAcceptsOnlyAdditiveTargets() throws {
    let identifier = UUID()
    let existing = ActiveRuleState(
        id: identifier,
        name: "Social",
        startedAt: policyDate("2026-08-11T22:00:00Z"),
        activeUntil: policyDate("2026-08-12T07:00:00Z"),
        domains: ["x.com", "instagram.com"],
        endpoints: []
    )
    let edited = ScheduledRule(
        id: identifier,
        name: "Social",
        enabled: false,
        schedule: BlockSchedule(startMinute: 23 * 60, endMinute: 1 * 60),
        domains: ["youtube.com"]
    )
    let state = try EnforcementPolicy.decide(
        now: policyDate("2026-08-11T23:00:00Z"),
        configuration: RoasterConfiguration(scheduledRules: [edited]),
        existingState: EnforcementState(activeRules: [existing]),
        calendar: policyCalendar
    )
    #expect(state.activeRules.first?.domains == ["instagram.com", "x.com", "youtube.com"])
    #expect(state.activeRules.first?.activeUntil == existing.activeUntil)
}

@Test func permanentProtectionCannotBeDisabledAfterItLocks() throws {
    let existing = EnforcementState(
        permanentProtectionLocked: true,
        permanentAllowlist: ["false-positive.example"]
    )
    let configuration = RoasterConfiguration(
        enabled: false,
        scheduledRules: [],
        permanentProtection: PermanentProtection(enabled: false, allowlist: [])
    )
    let state = try EnforcementPolicy.decide(
        now: policyDate("2026-08-11T12:00:00Z"),
        configuration: configuration,
        existingState: existing,
        calendar: policyCalendar
    )
    #expect(state.permanentProtectionLocked)
    #expect(state.permanentAllowlist == ["false-positive.example"])
}

@Test func permanentProtectionCanTransitionFromUnlockedToLocked() throws {
    let existing = EnforcementState(permanentProtectionLocked: false)
    let configuration = RoasterConfiguration(
        scheduledRules: [],
        permanentProtection: PermanentProtection(
            enabled: true,
            allowlist: ["false-positive.example"]
        )
    )
    let state = try EnforcementPolicy.decide(
        now: policyDate("2026-08-11T12:00:00Z"),
        configuration: configuration,
        existingState: existing,
        calendar: policyCalendar
    )
    #expect(state.permanentProtectionLocked)
    #expect(state.permanentAllowlist == ["false-positive.example"])
}
