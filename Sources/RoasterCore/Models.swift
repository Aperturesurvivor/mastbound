import Foundation

public struct BlockSchedule: Codable, Equatable, Sendable {
    public var startMinute: Int
    public var endMinute: Int
    public var weekdays: Set<Int>

    public init(
        startMinute: Int = 22 * 60,
        endMinute: Int = 7 * 60,
        weekdays: Set<Int> = Set(1...7)
    ) {
        self.startMinute = startMinute
        self.endMinute = endMinute
        self.weekdays = weekdays
    }

    public func validate() throws {
        guard (0..<1440).contains(startMinute), (0..<1440).contains(endMinute) else {
            throw RoasterError.invalidSchedule("Times must fall within a calendar day.")
        }
        guard startMinute != endMinute else {
            throw RoasterError.invalidSchedule("Start and end time cannot be identical.")
        }
        guard !weekdays.isEmpty, weekdays.allSatisfy({ (1...7).contains($0) }) else {
            throw RoasterError.invalidSchedule("At least one valid weekday is required.")
        }
    }
}

public struct NetworkEndpoint: Codable, Equatable, Hashable, Sendable {
    public enum Transport: String, Codable, Sendable {
        case tcp
        case udp
    }

    public var address: String
    public var port: UInt16
    public var transport: Transport

    public init(address: String, port: UInt16, transport: Transport = .tcp) {
        self.address = address
        self.port = port
        self.transport = transport
    }

    public func validated() throws -> NetworkEndpoint {
        try TargetValidator.validate(self)
        return self
    }
}

public struct ScheduledRule: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var enabled: Bool
    public var schedule: BlockSchedule
    public var domains: [String]
    public var endpoints: [NetworkEndpoint]

    public init(
        id: UUID = UUID(),
        name: String,
        enabled: Bool = true,
        schedule: BlockSchedule,
        domains: [String] = [],
        endpoints: [NetworkEndpoint] = []
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.schedule = schedule
        self.domains = domains
        self.endpoints = endpoints
    }

    public func validated() throws -> ScheduledRule {
        try schedule.validate()
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty, normalizedName.count <= 80 else {
            throw RoasterError.invalidSchedule("Each rule requires a short name.")
        }
        var copy = self
        copy.name = normalizedName
        copy.domains = try DomainValidator.normalize(domains)
        copy.endpoints = try TargetValidator.normalize(endpoints)
        guard !copy.domains.isEmpty || !copy.endpoints.isEmpty else {
            throw RoasterError.invalidDomain("Rule \"\(normalizedName)\" has no targets.")
        }
        return copy
    }
}

public struct PermanentProtection: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var allowlist: [String]

    public init(enabled: Bool = true, allowlist: [String] = []) {
        self.enabled = enabled
        self.allowlist = allowlist
    }

    public func validated() throws -> PermanentProtection {
        var copy = self
        copy.allowlist = try DomainValidator.normalize(allowlist)
        return copy
    }
}

public struct RoasterConfiguration: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var enabled: Bool
    public var scheduledRules: [ScheduledRule]
    public var permanentProtection: PermanentProtection

    public init(
        version: Int = RoasterConfiguration.currentVersion,
        enabled: Bool = true,
        scheduledRules: [ScheduledRule] = RoasterConfiguration.defaultRules,
        permanentProtection: PermanentProtection = PermanentProtection()
    ) {
        self.version = version
        self.enabled = enabled
        self.scheduledRules = scheduledRules
        self.permanentProtection = permanentProtection
    }

    public func validated() throws -> RoasterConfiguration {
        guard version == Self.currentVersion else {
            throw RoasterError.unsupportedConfigurationVersion(version)
        }
        guard scheduledRules.count <= 16 else {
            throw RoasterError.invalidSchedule("No more than 16 scheduled rules are allowed.")
        }
        var copy = self
        copy.scheduledRules = try scheduledRules.map { try $0.validated() }
        guard Set(copy.scheduledRules.map(\.id)).count == copy.scheduledRules.count else {
            throw RoasterError.invalidSchedule("Scheduled rule identifiers must be unique.")
        }
        copy.permanentProtection = try permanentProtection.validated()
        return copy
    }

    public static let defaultRules = [
        ScheduledRule(
            name: "Social media after dark",
            schedule: BlockSchedule(startMinute: 22 * 60, endMinute: 7 * 60),
            domains: DomainValidator.defaultDomains
        )
    ]

    public static func jellyfinRule(address: String, port: UInt16 = 8096) -> ScheduledRule {
        ScheduledRule(
            name: "Jellyfin after 11 PM",
            schedule: BlockSchedule(startMinute: 23 * 60, endMinute: 7 * 60),
            endpoints: [NetworkEndpoint(address: address, port: port)]
        )
    }
}

public struct ActiveRuleState: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var startedAt: Date
    public var activeUntil: Date
    public var domains: [String]
    public var endpoints: [NetworkEndpoint]

    public init(
        id: UUID,
        name: String,
        startedAt: Date,
        activeUntil: Date,
        domains: [String],
        endpoints: [NetworkEndpoint]
    ) {
        self.id = id
        self.name = name
        self.startedAt = startedAt
        self.activeUntil = activeUntil
        self.domains = domains
        self.endpoints = endpoints
    }
}

public struct EnforcementState: Codable, Equatable, Sendable {
    public var activeRules: [ActiveRuleState]
    public var pfEnableToken: String?
    public var permanentProtectionLocked: Bool
    public var permanentAllowlist: [String]

    public init(
        activeRules: [ActiveRuleState] = [],
        pfEnableToken: String? = nil,
        permanentProtectionLocked: Bool = false,
        permanentAllowlist: [String] = []
    ) {
        self.activeRules = activeRules
        self.pfEnableToken = pfEnableToken
        self.permanentProtectionLocked = permanentProtectionLocked
        self.permanentAllowlist = permanentAllowlist
    }

    public var scheduledDomains: [String] {
        Array(Set(activeRules.flatMap(\.domains))).sorted()
    }

    public var scheduledEndpoints: [NetworkEndpoint] {
        Array(Set(activeRules.flatMap(\.endpoints))).sorted {
            ($0.address, $0.port, $0.transport.rawValue) < ($1.address, $1.port, $1.transport.rawValue)
        }
    }
}

public enum RoasterError: Error, LocalizedError, Equatable {
    case invalidSchedule(String)
    case invalidDomain(String)
    case unsupportedConfigurationVersion(Int)
    case unsafeFile(String)
    case malformedManagedSection(String)
    case configurationTooLarge

    public var errorDescription: String? {
        switch self {
        case .invalidSchedule(let message), .invalidDomain(let message),
             .unsafeFile(let message), .malformedManagedSection(let message):
            return message
        case .unsupportedConfigurationVersion(let version):
            return "Unsupported configuration version: \(version)."
        case .configurationTooLarge:
            return "The configuration exceeds the 64 KiB safety limit."
        }
    }
}
