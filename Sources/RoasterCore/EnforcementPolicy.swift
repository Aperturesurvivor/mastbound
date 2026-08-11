import Foundation

public enum EnforcementPolicy {
    public static func decide(
        now: Date,
        configuration: RoasterConfiguration,
        existingState: EnforcementState?,
        calendar: Calendar = .autoupdatingCurrent
    ) throws -> EnforcementState {
        let configuration = try configuration.validated()
        let existingByID = Dictionary(
            uniqueKeysWithValues: (existingState?.activeRules ?? []).map { ($0.id, $0) }
        )
        var activeRules: [ActiveRuleState] = []
        var processedIDs = Set<UUID>()

        for rule in configuration.scheduledRules {
            processedIDs.insert(rule.id)
            if let existing = existingByID[rule.id], existing.activeUntil > now {
                activeRules.append(ActiveRuleState(
                    id: existing.id,
                    name: existing.name,
                    startedAt: existing.startedAt,
                    activeUntil: existing.activeUntil,
                    domains: try DomainValidator.normalize(existing.domains + rule.domains),
                    endpoints: try TargetValidator.normalize(existing.endpoints + rule.endpoints)
                ))
                continue
            }

            guard configuration.enabled, rule.enabled,
                  let interval = try ScheduleEvaluator.activeInterval(
                    at: now,
                    schedule: rule.schedule,
                    calendar: calendar
                  ) else { continue }
            activeRules.append(ActiveRuleState(
                id: rule.id,
                name: rule.name,
                startedAt: max(now, interval.start),
                activeUntil: interval.end,
                domains: rule.domains,
                endpoints: rule.endpoints
            ))
        }

        for existing in existingByID.values
            where existing.activeUntil > now && !processedIDs.contains(existing.id) {
            activeRules.append(existing)
        }

        let protectionWasLocked = existingState?.permanentProtectionLocked == true
        let protectionIsLocked = protectionWasLocked || configuration.permanentProtection.enabled

        return EnforcementState(
            activeRules: activeRules.sorted { $0.id.uuidString < $1.id.uuidString },
            pfEnableToken: existingState?.pfEnableToken,
            permanentProtectionLocked: protectionIsLocked,
            permanentAllowlist: protectionWasLocked
                ? existingState?.permanentAllowlist ?? []
                : configuration.permanentProtection.allowlist
        )
    }
}
