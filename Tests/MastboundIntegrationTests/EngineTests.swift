import Darwin
import Foundation
import Testing
@testable import MastboundCore

@Suite("Engine: normal use")
struct EngineNormalUseTests {
    @Test("A fresh install is idle, blocks nothing and writes a status file")
    func freshInstall() throws {
        let f = try Fixture()
        let report = try f.engine().reconcile()
        #expect(report.phase == .idle)
        #expect(try f.hosts() == originalHosts)
        #expect(try f.engine().readStatus().phase == .idle)
    }

    @Test("I1: start blocks the list at once; files have the right modes")
    func startBlocks() throws {
        let f = try Fixture()
        try f.engine().start(durationSeconds: day)
        #expect(try f.blocked() == f.list)
        #expect(try f.hosts().hasPrefix(originalHosts))
        #expect(try f.mode(f.paths.stateFile) == 0o600)
        #expect(try f.mode(f.paths.lockedListFile) == 0o600)
        #expect(try f.mode(f.paths.statusFile) == 0o644)
        #expect(try f.engine().readStatus().phase == .active)
        #expect(f.flushes.value == 1)
    }

    @Test("Ticks with nothing to do write nothing")
    func noNeedlessWrites() throws {
        let f = try Fixture()
        try f.engine().start(durationSeconds: day)
        for _ in 0..<10 {
            f.clock.advance(5)
            let report = try f.engine().reconcile()
            #expect(!report.hostsChanged)
            #expect(!report.stateSaved)
        }
        f.clock.advance(60)
        #expect(try f.engine().reconcile().stateSaved) // status refresh every 60 s
        #expect(f.flushes.value == 1)
    }

    @Test("I1: a hand-removed block is restored on the next tick")
    func repair() throws {
        let f = try Fixture()
        try f.engine().start(durationSeconds: day)
        try FileStore.writeAtomically(Data((originalHosts + "10.0.0.9 nas.local\n").utf8), to: f.paths.hostsFile, mode: 0o644, owner: getuid(), group: getgid())
        #expect(try f.engine().reconcile().hostsChanged)
        #expect(try f.blocked() == f.list)
        #expect(try f.hosts().contains("10.0.0.9 nas.local")) // I10
    }

    @Test("D3, I10: at the end the block is removed and the hosts file is as before")
    func expiry() throws {
        let f = try Fixture()
        try f.engine().start(durationSeconds: 2 * hour)
        f.clock.advance(2 * hour - 1)
        #expect(try f.engine().reconcile().phase == .active)
        f.clock.advance(1)
        let report = try f.engine().reconcile()
        #expect(report.phase == .idle)
        #expect(try f.hosts() == originalHosts)
        #expect(!f.exists(f.paths.lockedListFile))
        #expect(try f.engine().readStatus().lastEnd?.reason == .completed)
    }

    @Test("I6: setting the clock a year forward keeps the block")
    func clockForward() throws {
        let f = try Fixture()
        try f.engine().start(durationSeconds: day)
        f.clock.changeWallClock(by: 365 * day)
        f.clock.advance(5)
        #expect(try f.engine().reconcile().phase == .active)
        #expect(try f.blocked() == f.list)
    }

    @Test("I7: after a reboot the block stays and time off is counted")
    func reboot() throws {
        let f = try Fixture()
        try f.engine().start(durationSeconds: day)
        f.clock.advance(hour)
        try f.engine().reconcile()
        f.clock.reboot(offSeconds: 3 * hour)
        #expect(try f.engine().reconcile().phase == .active)
        #expect(try f.blocked() == f.list)
        let credited = try #require(try f.state().commitment).creditedSeconds
        #expect(abs(credited - 4 * hour) < 61) // last save may be up to 60 s old
    }

    @Test("D1: recovery keeps the block for 72 hours, then removes it")
    func recovery() throws {
        let f = try Fixture()
        try f.engine().start(durationSeconds: 30 * day)
        try f.engine().requestRecovery(confirmation: Policy.recoveryPhrase)
        f.clock.advance(Policy.recoveryDelaySeconds - 1)
        #expect(try f.engine().reconcile().phase == .recovering)
        #expect(try f.blocked() == f.list)
        f.clock.advance(1)
        #expect(try f.engine().reconcile().phase == .idle)
        #expect(try f.hosts() == originalHosts)
        #expect(try f.engine().readStatus().lastEnd?.reason == .recovered)
    }

    @Test("A cancel request from any user ends the early end and is removed")
    func cancelRequest() throws {
        let f = try Fixture()
        try FileManager.default.createDirectory(at: f.paths.requestsDirectory, withIntermediateDirectories: false)
        try f.engine().start(durationSeconds: 30 * day)
        try f.engine().requestRecovery(confirmation: Policy.recoveryPhrase)
        try CancelRequest.write(paths: f.paths)
        #expect(try f.engine().reconcile().phase == .active)
        #expect(!f.exists(f.paths.cancelRecoveryRequest))
        f.clock.advance(Policy.recoveryDelaySeconds + hour)
        #expect(try f.engine().reconcile().phase == .active)
        #expect(try f.blocked() == f.list)
    }

    @Test("App flow: begin, finish too soon refused, finish later, cancel request closes an open flow")
    func appFlow() throws {
        let f = try Fixture()
        try FileManager.default.createDirectory(at: f.paths.requestsDirectory, withIntermediateDirectories: false)
        try f.engine().start(durationSeconds: 30 * day)
        try f.engine().beginQuit()
        #expect(try f.engine().readStatus().quitElapsedSeconds == 0)
        try CancelRequest.write(paths: f.paths)
        #expect(try f.engine().reconcile().phase == .active)
        #expect(try f.engine().readStatus().quitElapsedSeconds == nil)

        try f.engine().beginQuit()
        f.clock.advance(Policy.quitFlowMinimumSeconds - 60)
        #expect(throws: MastboundError.self) { try f.engine().finishQuit(confirmation: Policy.recoveryPhrase) }
        f.clock.advance(60)
        try f.engine().finishQuit(confirmation: Policy.recoveryPhrase)
        #expect(try f.engine().readStatus().phase == .recovering)
        #expect(try f.blocked() == f.list)
    }

    @Test("A cancel request while active changes nothing and is removed")
    func cancelRequestWhileActive() throws {
        let f = try Fixture()
        try FileManager.default.createDirectory(at: f.paths.requestsDirectory, withIntermediateDirectories: false)
        try f.engine().start(durationSeconds: 30 * day)
        let before = try #require(try f.state().commitment)
        try CancelRequest.write(paths: f.paths)
        #expect(try f.engine().reconcile().phase == .active)
        #expect(!f.exists(f.paths.cancelRecoveryRequest))
        #expect(try f.state().commitment?.durationSeconds == before.durationSeconds)
    }

    @Test("A symbolic link as the cancel request is removed, not followed")
    func cancelRequestLink() throws {
        let f = try Fixture()
        try FileManager.default.createDirectory(at: f.paths.requestsDirectory, withIntermediateDirectories: false)
        let victim = f.root.appendingPathComponent("victim")
        try Data("keep".utf8).write(to: victim)
        try f.engine().start(durationSeconds: 30 * day)
        try f.engine().requestRecovery(confirmation: Policy.recoveryPhrase)
        try FileManager.default.createSymbolicLink(at: f.paths.cancelRecoveryRequest, withDestinationURL: victim)
        #expect(try f.engine().reconcile().phase == .active)
        #expect(try String(contentsOf: victim, encoding: .utf8) == "keep")
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: f.paths.cancelRecoveryRequest.path)) == nil)
    }

    @Test("Refused commands change nothing")
    func refusedCommands() throws {
        let f = try Fixture()
        #expect(throws: MastboundError.self) { try f.engine().extend(bySeconds: hour) }
        try f.engine().start(durationSeconds: day)
        let before = try Data(contentsOf: f.paths.stateFile)
        #expect(throws: MastboundError.self) { try f.engine().start(durationSeconds: day) }
        #expect(throws: MastboundError.self) { try f.engine().requestRecovery(confirmation: "please") }
        #expect(throws: MastboundError.self) { try f.engine().extend(bySeconds: -hour) }
        #expect(try Data(contentsOf: f.paths.stateFile) == before)
    }
}

@Suite("Engine: failures keep the block (I4, I5)")
struct EngineFailureTests {
    private func startedFixture() throws -> Fixture {
        let f = try Fixture()
        try f.engine().start(durationSeconds: day)
        return f
    }

    @Test("I4: a damaged state file keeps the block")
    func damagedState() throws {
        let f = try startedFixture()
        try FileStore.writeAtomically(Data("{garbage".utf8), to: f.paths.stateFile, mode: 0o600, owner: getuid(), group: getgid())
        let before = try f.hosts()
        #expect(throws: (any Error).self) { try f.engine().reconcile() }
        #expect(try f.hosts() == before)
    }

    @Test("I4, I5: a deleted state file keeps the block")
    func deletedState() throws {
        let f = try startedFixture()
        try FileManager.default.removeItem(at: f.paths.stateFile)
        let before = try f.hosts()
        #expect(throws: MastboundError.self) { try f.engine().reconcile() }
        #expect(try f.hosts() == before)
    }

    @Test("I4: a world-writable state file is refused and the block stays")
    func unsafeStateMode() throws {
        let f = try startedFixture()
        chmod(f.paths.stateFile.path, 0o666)
        let before = try f.hosts()
        #expect(throws: MastboundError.self) { try f.engine().reconcile() }
        #expect(try f.hosts() == before)
    }

    @Test("A missing installed list still blocks with the locked list")
    func missingInstalledList() throws {
        let f = try startedFixture()
        try FileManager.default.removeItem(at: f.paths.installedList)
        try FileStore.writeAtomically(Data(originalHosts.utf8), to: f.paths.hostsFile, mode: 0o644, owner: getuid(), group: getgid())
        let report = try f.engine().reconcile()
        #expect(try f.blocked() == f.list)
        #expect(report.warnings.count == 1)
    }

    @Test("A changed installed list is ignored; the locked list still blocks")
    func tamperedInstalledList() throws {
        let f = try startedFixture()
        try FileStore.writeAtomically(try Blocklist.serialize(["a.example"]), to: f.paths.installedList, mode: 0o644, owner: getuid(), group: getgid())
        try f.engine().reconcile()
        #expect(try f.blocked() == f.list)
    }

    @Test("I4: with no valid list at all, the current block stays")
    func noValidList() throws {
        let f = try startedFixture()
        try FileManager.default.removeItem(at: f.paths.installedList)
        try FileManager.default.removeItem(at: f.paths.lockedListFile)
        let before = try f.hosts()
        #expect(throws: MastboundError.self) { try f.engine().reconcile() }
        #expect(try f.hosts() == before)
    }

    @Test("I11: a failed hosts write changes nothing; the next tick applies it")
    func failedHostsWrite() throws {
        let f = try startedFixture()
        try FileStore.writeAtomically(Data(originalHosts.utf8), to: f.paths.hostsFile, mode: 0o644, owner: getuid(), group: getgid())
        chmod(f.root.path, 0o555) // the hosts temp file cannot be created
        #expect(throws: (any Error).self) { try f.engine().reconcile() }
        chmod(f.root.path, 0o755)
        #expect(try f.hosts() == originalHosts)
        try f.engine().reconcile()
        #expect(try f.blocked() == f.list)
    }

    @Test("Damaged hosts markers are not edited")
    func damagedMarkers() throws {
        let f = try startedFixture()
        let damaged = originalHosts + HostsSection.beginMarker + "\n"
        try FileStore.writeAtomically(Data(damaged.utf8), to: f.paths.hostsFile, mode: 0o644, owner: getuid(), group: getgid())
        #expect(throws: MastboundError.self) { try f.engine().reconcile() }
        #expect(try f.hosts() == damaged)
    }
}

@Suite("Engine: crash between writes")
struct EngineCrashTests {
    @Test("Crash after the locked list but before the state: nothing is blocked and the copy is removed")
    func crashDuringStart() throws {
        let f = try Fixture()
        try f.engine().reconcile()
        try FileStore.writeAtomically(try Blocklist.serialize(f.list), to: f.paths.lockedListFile, mode: 0o600, owner: getuid(), group: getgid())
        #expect(try f.engine().reconcile().phase == .idle)
        #expect(try f.hosts() == originalHosts)
        #expect(!f.exists(f.paths.lockedListFile))
    }

    @Test("Crash after the state but before the hosts write: the next tick applies the state")
    func crashBeforeHostsWrite() throws {
        let f = try Fixture()
        try f.engine().start(durationSeconds: day)
        // Ended state saved, but the old hosts section is still present.
        try FileStore.writeAtomically(try EngineState.idle.encoded(), to: f.paths.stateFile, mode: 0o600, owner: getuid(), group: getgid())
        try f.engine().reconcile()
        #expect(try f.hosts() == originalHosts)
    }

    @Test("A leftover temp file from a crash does not block later writes")
    func leftoverTempFile() throws {
        let f = try Fixture()
        try Data("partial".utf8).write(to: f.paths.stateDirectory.appendingPathComponent(".state.json.leftover.tmp"))
        try f.engine().start(durationSeconds: day)
        #expect(try f.blocked() == f.list)
    }
}

@Suite("Engine: install, upgrade and uninstall")
struct EngineInstallTests {
    @Test("Install refuses a source folder that other users can write")
    func installRefusesWritableSource() throws {
        let f = try Fixture()
        let build = try f.makeBuild(list: f.list)
        #expect(chmod(build.directory.path, 0o777) == 0)
        #expect(throws: MastboundError.self) {
            try Installer.installFiles(from: build.directory, paths: f.paths, bundledListSHA256: build.sha)
        }
        #expect(!FileManager.default.fileExists(atPath: f.paths.installedDaemon.path))
    }

    @Test("Install refuses a source folder below a folder that other users can write")
    func installRefusesWritableSourceParent() throws {
        let f = try Fixture()
        let parent = f.root.appendingPathComponent("shared", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        let build = try f.makeBuild(list: f.list)
        let moved = parent.appendingPathComponent("build", isDirectory: true)
        try FileManager.default.moveItem(at: build.directory, to: moved)
        #expect(chmod(parent.path, 0o777) == 0)
        #expect(throws: MastboundError.self) {
            try Installer.installFiles(from: moved, paths: f.paths, bundledListSHA256: build.sha)
        }
        #expect(!FileManager.default.fileExists(atPath: f.paths.installedDaemon.path))
    }

    @Test("Install refuses a source daemon that other users can write")
    func installRefusesWritableSourceFile() throws {
        let f = try Fixture()
        let build = try f.makeBuild(list: f.list)
        #expect(chmod(build.directory.appendingPathComponent("mastboundd").path, 0o666) == 0)
        #expect(throws: MastboundError.self) {
            try Installer.installFiles(from: build.directory, paths: f.paths, bundledListSHA256: build.sha)
        }
        #expect(!FileManager.default.fileExists(atPath: f.paths.installedDaemon.path))
    }

    @Test("Install checks the real folder behind a symbolic link")
    func installResolvesSourceLink() throws {
        let f = try Fixture()
        let parent = f.root.appendingPathComponent("shared", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        let build = try f.makeBuild(list: f.list)
        let moved = parent.appendingPathComponent("build", isDirectory: true)
        try FileManager.default.moveItem(at: build.directory, to: moved)
        #expect(chmod(parent.path, 0o777) == 0)
        let link = f.root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: moved)
        #expect(throws: MastboundError.self) {
            try Installer.installFiles(from: link, paths: f.paths, bundledListSHA256: build.sha)
        }
    }

    @Test("Install copies the build and writes a launchd plist that points at the helper folder (I8)")
    func installFiles() throws {
        let f = try Fixture()
        let build = try f.makeBuild(list: f.list)
        try Installer.installFiles(from: build.directory, paths: f.paths, bundledListSHA256: build.sha)
        #expect(try f.mode(f.paths.installedDaemon) == 0o755)
        #expect(try f.mode(f.paths.installedTool) == 0o755)
        let plist = try #require(NSDictionary(contentsOf: f.paths.launchDaemonPlist) as? [String: Any])
        #expect(plist["ProgramArguments"] as? [String] == [f.paths.installedDaemon.path])
        #expect(plist["KeepAlive"] as? Bool == true)
        #expect(plist["Label"] as? String == Paths.launchDaemonLabel)
    }

    @Test("Install creates missing parent folders, as on a clean Mac")
    func installCreatesMissingParents() throws {
        let f = try Fixture()
        var paths = f.paths
        paths.helperDirectory = f.root.appendingPathComponent("PrivilegedHelperTools/Mastbound", isDirectory: true)
        paths.stateDirectory = f.root.appendingPathComponent("Application Support/Mastbound", isDirectory: true)
        let build = try f.makeBuild(list: f.list)
        try Installer.installFiles(from: build.directory, paths: paths, bundledListSHA256: build.sha)
        #expect(FileManager.default.fileExists(atPath: paths.installedDaemon.path))
        #expect(try f.mode(paths.helperDirectory.deletingLastPathComponent()) == 0o755)
        #expect(try f.mode(paths.stateDirectory) == 0o755)
    }

    @Test("Install refuses a parent folder that other users can write")
    func installRefusesOpenParent() throws {
        let f = try Fixture()
        var paths = f.paths
        let open = f.root.appendingPathComponent("open")
        try FileManager.default.createDirectory(at: open, withIntermediateDirectories: false)
        chmod(open.path, 0o777)
        paths.helperDirectory = open.appendingPathComponent("Mastbound")
        let build = try f.makeBuild(list: f.list)
        #expect(throws: MastboundError.self) {
            try Installer.installFiles(from: build.directory, paths: paths, bundledListSHA256: build.sha)
        }
    }

    @Test("File errors name the file")
    func errorsNameTheFile() throws {
        let f = try Fixture()
        let missing = f.root.appendingPathComponent("no-such-file")
        do {
            _ = try FileStore.read(at: missing, expectedOwner: nil, maximumSize: 10)
            Issue.record("Expected an error")
        } catch {
            #expect(error.localizedDescription.contains(missing.path))
            #expect(error.localizedDescription.contains("No such file"))
        }
    }

    @Test("Install refuses a build with a wrong list hash or a non-executable, and changes nothing")
    func installRefusesBadBuild() throws {
        let f = try Fixture()
        let build = try f.makeBuild(list: f.list)
        #expect(throws: MastboundError.self) {
            try Installer.installFiles(from: build.directory, paths: f.paths, bundledListSHA256: String(repeating: "0", count: 64))
        }
        try Data("#!/bin/sh\n".utf8).write(to: build.directory.appendingPathComponent("mastboundd"))
        #expect(throws: MastboundError.self) {
            try Installer.installFiles(from: build.directory, paths: f.paths, bundledListSHA256: build.sha)
        }
        #expect(!f.exists(f.paths.installedDaemon))
        #expect(!f.exists(f.paths.launchDaemonPlist))
    }

    @Test("I9: an upgrade keeps the commitment and can add domains but not remove them")
    func upgrade() throws {
        let f = try Fixture()
        try f.engine().start(durationSeconds: 10 * day)
        f.clock.advance(day)
        try f.engine().reconcile()
        let before = try f.state()

        let newList = ["b.example", "c.example", "d.example"] // drops a, adds d
        let build = try f.makeBuild(list: newList)
        try Installer.installFiles(from: build.directory, paths: f.paths, bundledListSHA256: build.sha)
        #expect(try f.state() == before)

        f.clock.advance(5)
        try f.engine(listSHA: build.sha).reconcile()
        #expect(try f.blocked() == ["a.example", "b.example", "c.example", "d.example"])
        #expect(try f.engine(listSHA: build.sha).readStatus().phase == .active)
    }

    @Test("I3: uninstall is refused while a commitment runs and changes nothing")
    func uninstallRefused() throws {
        let f = try Fixture()
        try f.engine().start(durationSeconds: day)
        #expect(try !f.engine().canUninstall())
        let hosts = try f.hosts()
        #expect(throws: MastboundError.self) { try f.engine().prepareUninstall() }
        #expect(try f.hosts() == hosts)
        #expect(f.exists(f.paths.stateFile))
    }

    @Test("I3: after the end, uninstall removes the block and every file")
    func uninstallAfterEnd() throws {
        let f = try Fixture()
        let build = try f.makeBuild(list: f.list)
        try Installer.installFiles(from: build.directory, paths: f.paths, bundledListSHA256: build.sha)
        #expect(try f.mode(f.paths.requestsDirectory) == 0o1777)
        // Files other users left in the sticky requests folder do not block removal.
        try Data("junk".utf8).write(to: f.paths.requestsDirectory.appendingPathComponent("junk"))
        try f.engine().start(durationSeconds: hour)
        f.clock.advance(hour)
        #expect(try f.engine().canUninstall())
        try f.engine().prepareUninstall()
        try Installer.removeFiles(paths: f.paths)
        #expect(try f.hosts() == originalHosts)
        #expect(!f.exists(f.paths.helperDirectory))
        #expect(!f.exists(f.paths.stateDirectory))
        #expect(!f.exists(f.paths.launchDaemonPlist))
    }
}

@Suite("Engine: concurrency")
struct EngineConcurrencyTests {
    @Test("No extension is lost while the daemon ticks and saves at the same time")
    func concurrentExtendAndReconcile() async throws {
        let f = try Fixture()
        try f.engine().start(durationSeconds: 300 * day)
        let extensions = 200
        let daemon = f.engine(), tool = f.engine(), clock = f.clock
        let done = Counter(), ticks = Counter()

        // Each tick moves the clock past the save interval, so the daemon
        // writes the state on every tick and races with the tool.
        let ticker = Task.detached {
            while done.value == 0 {
                clock.advance(Engine.saveIntervalSeconds + 1)
                if (try? daemon.reconcile()) != nil { ticks.increment() }
            }
        }
        try await Task.detached {
            for _ in 0..<extensions { try tool.extend(bySeconds: 60) }
        }.value
        done.increment()
        _ = await ticker.value

        let duration = try #require(try f.state().commitment).durationSeconds
        #expect(ticks.value > 50)
        #expect(duration == 300 * day + Double(extensions) * 60)
    }
}

@Suite("Engine: shipped list")
struct EngineShippedListTests {
    static let listURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources").appendingPathComponent(Paths.listFileName)

    @Test("I12: the shipped list matches its pinned hash and count")
    func shippedListMatchesPin() throws {
        let list = try Blocklist.load(Data(contentsOf: Self.listURL), expectedSHA256: BundledList.sha256)
        #expect(list.domains.count == BundledList.domainCount)
    }

    @Test("With the full shipped list, a normal tick takes under 50 ms; a repair still works")
    func fullListTickTime() throws {
        let domains = try Blocklist.parse(Data(contentsOf: Self.listURL)).domains
        let f = try Fixture(list: domains)
        let daemon = f.engine() // one engine for its whole life, like mastboundd
        let clock = ContinuousClock()
        let first = try clock.measure { try daemon.reconcile() }
        try f.engine().start(durationSeconds: day)
        #expect(try f.blocked().count == domains.count)

        f.clock.advance(5)
        let cold = try clock.measure { try daemon.reconcile() } // parses both lists once
        var slowest = Duration.zero
        for _ in 0..<5 {
            f.clock.advance(5)
            slowest = max(slowest, try clock.measure { try daemon.reconcile() })
        }
        // A hand edit must still be found and repaired.
        try FileStore.writeAtomically(Data(originalHosts.utf8), to: f.paths.hostsFile, mode: 0o644, owner: getuid(), group: getgid())
        f.clock.advance(5)
        var repaired = false
        let repair = try clock.measure { repaired = try daemon.reconcile().hostsChanged }
        #expect(repaired)
        #expect(try f.blocked().count == domains.count)
        print("Full list: first idle tick \(first), first active tick \(cold), slowest normal tick \(slowest), repair tick \(repair)")
        #expect(slowest < .milliseconds(50))
        #expect(cold < .seconds(10))
    }
}
