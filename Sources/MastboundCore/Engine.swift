import Darwin
import Foundation

/// Everything the daemon and `mastboundctl` do to files, in one place.
///
/// Rules:
/// - Every read-change-write of the state runs under `paths.lockFile`.
/// - Any error leaves `/etc/hosts` as it is (fail closed, I4).
/// - The state is written before `/etc/hosts`, so a crash between the two is
///   repaired by the next `reconcile`.
public struct Engine: Sendable {
    public let paths: Paths
    /// Hash pinned at build time for the installed list (`BundledList.sha256`).
    public let bundledListSHA256: String
    public let clock: @Sendable () throws -> ClockReading
    /// Called after `/etc/hosts` changes, to flush DNS caches.
    public let afterHostsChange: @Sendable () -> Void
    /// Per-engine memory of checked files. The daemon keeps one engine for
    /// its whole life; each `mastboundctl` run starts with an empty cache.
    let cache = EngineCache()

    /// The state is saved at least this often while a commitment runs, so
    /// `status.json` stays current. Credit is not lost between saves: it is
    /// always measured from the last saved reading.
    public static let saveIntervalSeconds: Double = 60
    public static let maximumHostsBytes = 32 * 1024 * 1024

    public init(
        paths: Paths,
        bundledListSHA256: String,
        clock: @escaping @Sendable () throws -> ClockReading,
        afterHostsChange: @escaping @Sendable () -> Void = {}
    ) {
        self.paths = paths
        self.bundledListSHA256 = bundledListSHA256
        self.clock = clock
        self.afterHostsChange = afterHostsChange
    }

    public struct Report: Equatable, Sendable {
        public var phase: Phase
        public var hostsChanged: Bool
        public var stateSaved: Bool
        /// Problems that did not stop enforcement, for the log.
        public var warnings: [String]
    }

    // MARK: Daemon

    /// One daemon tick: credit time, end the commitment if due, and make the
    /// hosts section match the state. Also repairs a hand-edited section.
    @discardableResult
    public func reconcile() throws -> Report {
        try locked { try reconcileLocked() }
    }

    private func reconcileLocked() throws -> Report {
        let hostsSignature = try FileSignature(of: paths.hostsFile)
        let saved = try loadState(hostsText: { try readHosts().text })
        let reading = try clock()
        let next = saved.state.ticked(at: reading)

        var report = Report(phase: next.phase, hostsChanged: false, stateSaved: false, warnings: [])
        let desired = next.phase == .idle
            ? DesiredBlock.none
            : try desiredBlock(for: next, warnings: &report.warnings)

        if !saved.exists || needsSave(old: saved.state, new: next, at: reading) {
            try saveState(next, at: reading)
            report.stateSaved = true
        }

        // Skip the slow read and render when the hosts file is exactly the one
        // this engine last checked and the wanted block has not changed. Any
        // edit or replacement of the file changes its signature (repair check).
        if cache.verifiedHosts(signature: hostsSignature, blockID: desired.id) == false {
            let hosts = try readHosts()
            let rendered = try HostsSection.render(existing: hosts.text, blockedDomains: desired.domains)
            if rendered != hosts.text {
                try FileStore.writeAtomically(
                    Data(rendered.utf8), to: paths.hostsFile,
                    mode: hosts.mode, owner: hosts.owner, group: hosts.group
                )
                report.hostsChanged = true
                afterHostsChange()
            }
            cache.setVerifiedHosts(signature: try FileSignature(of: paths.hostsFile), blockID: desired.id)
        }

        if next.phase == .idle {
            try removeIfPresent(paths.lockedListFile)
        }
        return report
    }

    struct DesiredBlock {
        /// Changes whenever the set of domains changes.
        var id: String
        var domains: [String]
        static let none = DesiredBlock(id: "none", domains: [])
    }

    /// The domains to block while a commitment runs: the list locked at start
    /// plus the installed list, if each is valid. If neither is valid, throw
    /// so the current block stays.
    private func desiredBlock(for state: EngineState, warnings: inout [String]) throws -> DesiredBlock {
        var lists: [Blocklist] = []
        if let commitment = state.commitment {
            do {
                lists.append(try loadList(at: paths.lockedListFile, expectedSHA256: commitment.listSHA256))
            } catch {
                warnings.append("Locked list unusable: \(error.localizedDescription)")
            }
        }
        do {
            lists.append(try loadInstalledList())
        } catch {
            warnings.append("Installed list unusable: \(error.localizedDescription)")
        }
        guard !lists.isEmpty else {
            throw MastboundError.invalidList("No valid list is available; the current block is kept.")
        }
        let id = Set(lists.map(\.sha256)).sorted().joined(separator: "+")
        if let domains = cache.union(id: id) { return DesiredBlock(id: id, domains: domains) }
        let domains = try Enforcement.blockedDomains(for: state, lists: lists.map(\.domains))
        cache.setUnion(id: id, domains: domains)
        return DesiredBlock(id: id, domains: domains)
    }

    /// Reads and checks a list, or returns the cached copy if the file has
    /// not changed since it was last checked.
    private func loadList(at url: URL, expectedSHA256: String) throws -> Blocklist {
        let signature = try FileSignature(of: url)
        if let cached = cache.list(path: url.path, signature: signature), cached.sha256 == expectedSHA256 {
            return cached
        }
        let data = try FileStore.read(at: url, expectedOwner: paths.owner, maximumSize: Blocklist.maximumBytes)
        let list = try Blocklist.load(data, expectedSHA256: expectedSHA256)
        cache.setList(path: url.path, signature: signature, list: list)
        return list
    }

    private func needsSave(old: EngineState, new: EngineState, at reading: ClockReading) -> Bool {
        guard let oldCommitment = old.commitment, let newCommitment = new.commitment else {
            return old != new
        }
        if old.phase != new.phase || oldCommitment.startedAt != newCommitment.startedAt { return true }
        let last = oldCommitment.lastReading
        if last.bootSessionID != reading.bootSessionID { return true }
        let elapsed = Double(reading.monotonicNanoseconds &- last.monotonicNanoseconds) / 1_000_000_000
        return reading.monotonicNanoseconds < last.monotonicNanoseconds || elapsed >= Self.saveIntervalSeconds
    }

    // MARK: Commands

    /// Starts a commitment with the installed list, then applies the block.
    @discardableResult
    public func start(durationSeconds: Double) throws -> EngineState {
        let state = try locked { () throws -> EngineState in
            let hosts = try readHosts()
            let saved = try loadState(hostsText: { hosts.text })
            let reading = try clock()
            let list = try loadInstalledList()
            let next = try saved.state.starting(durationSeconds: durationSeconds, listSHA256: list.sha256, at: reading)
            // Locked list first: if a crash comes before the state write, the
            // state is still idle and the next reconcile removes this file.
            try FileStore.writeAtomically(
                try Blocklist.serialize(list.domains), to: paths.lockedListFile,
                mode: 0o600, owner: paths.owner, group: paths.group
            )
            try saveState(next, at: reading)
            return next
        }
        try reconcile()
        return state
    }

    @discardableResult
    public func extend(bySeconds seconds: Double) throws -> EngineState {
        try change { try $0.extending(bySeconds: seconds, at: $1) }
    }

    @discardableResult
    public func requestRecovery(confirmation: String) throws -> EngineState {
        try change { try $0.requestingRecovery(confirmation: confirmation, at: $1) }
    }

    @discardableResult
    public func cancelRecovery() throws -> EngineState {
        try change { try $0.cancellingRecovery(at: $1) }
    }

    /// I3: true only when no commitment is running. Changes nothing.
    public func canUninstall() throws -> Bool {
        try locked {
            let hosts = try readHosts()
            return try loadState(hostsText: { hosts.text }).state.ticked(at: try clock()).canUninstall
        }
    }

    /// I3: removes the hosts section and the state files, only when idle.
    /// The caller then removes the launch daemon and helper files.
    public func prepareUninstall() throws {
        try locked {
            let hosts = try readHosts()
            let saved = try loadState(hostsText: { hosts.text })
            let current = saved.state.ticked(at: try clock())
            guard current.canUninstall else {
                throw MastboundError.notAllowed("A commitment is running. Mastbound cannot be removed until it ends.")
            }
            let rendered = try HostsSection.render(existing: hosts.text, blockedDomains: [])
            if rendered != hosts.text {
                try FileStore.writeAtomically(
                    Data(rendered.utf8), to: paths.hostsFile,
                    mode: hosts.mode, owner: hosts.owner, group: hosts.group
                )
                afterHostsChange()
            }
            for file in [paths.lockedListFile, paths.stateFile, paths.statusFile] {
                try removeIfPresent(file)
            }
        }
    }

    /// Reads `status.json`. Needs no root.
    public func readStatus() throws -> StatusReport {
        try StatusReport.decode(FileStore.read(at: paths.statusFile, expectedOwner: paths.owner, maximumSize: 64 * 1024))
    }

    private func change(_ transition: (EngineState, ClockReading) throws -> EngineState) throws -> EngineState {
        let state = try locked { () throws -> EngineState in
            let hosts = try readHosts()
            let saved = try loadState(hostsText: { hosts.text })
            let reading = try clock()
            let next = try transition(saved.state, reading)
            try saveState(next, at: reading)
            return next
        }
        try reconcile()
        return state
    }

    // MARK: Files

    private struct HostsFile {
        var text: String
        var mode: mode_t
        var owner: uid_t
        var group: gid_t
    }

    private func readHosts() throws -> HostsFile {
        let data = try FileStore.read(at: paths.hostsFile, expectedOwner: paths.owner, maximumSize: Self.maximumHostsBytes)
        guard let text = String(data: data, encoding: .utf8) else {
            throw MastboundError.unsafeFile("The hosts file is not valid UTF-8.")
        }
        var fileStat = stat()
        guard lstat(paths.hostsFile.path, &fileStat) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return HostsFile(text: text, mode: fileStat.st_mode & 0o777, owner: fileStat.st_uid, group: fileStat.st_gid)
    }

    /// A missing state file means idle, but only if no Mastbound section is in
    /// `/etc/hosts`. A section with no state means the state was removed, so
    /// fail closed instead of unblocking.
    private func loadState(hostsText: () throws -> String) throws -> (state: EngineState, exists: Bool) {
        guard FileManager.default.fileExists(atPath: paths.stateFile.path) else {
            guard try !hostsText().contains(HostsSection.beginMarker) else {
                throw MastboundError.invalidState("The state file is missing but a block is in place; the block is kept.")
            }
            return (.idle, false)
        }
        let data = try FileStore.read(at: paths.stateFile, expectedOwner: paths.owner, maximumSize: EngineState.maximumEncodedSize)
        return (try EngineState.decode(data), true)
    }

    private func saveState(_ state: EngineState, at reading: ClockReading) throws {
        try FileStore.writeAtomically(try state.encoded(), to: paths.stateFile, mode: 0o600, owner: paths.owner, group: paths.group)
        try FileStore.writeAtomically(
            try StatusReport(state: state, at: reading).encoded(), to: paths.statusFile,
            mode: 0o644, owner: paths.owner, group: paths.group
        )
    }

    private func loadInstalledList() throws -> Blocklist {
        try loadList(at: paths.installedList, expectedSHA256: bundledListSHA256)
    }

    private func removeIfPresent(_ url: URL) throws {
        guard unlink(url.path) == 0 || errno == ENOENT else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func locked<T>(_ body: () throws -> T) throws -> T {
        try FileLock.withExclusiveLock(at: paths.lockFile, body)
    }
}
