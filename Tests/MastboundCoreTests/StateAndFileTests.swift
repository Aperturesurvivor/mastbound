import Darwin
import Foundation
import Testing
@testable import MastboundCore

@Suite("State encoding")
struct StateEncodingTests {
    @Test("I7, I9: state survives encode and decode exactly")
    func roundTrip() throws {
        let state = try EngineState.idle
            .starting(durationSeconds: 3 * day, listSHA256: sampleSHA, at: reading(mono: 12.345, wall: 0.5))
            .requestingRecovery(confirmation: Policy.recoveryPhrase, at: reading(mono: 99.75, wall: 88))
        #expect(try EngineState.decode(state.encoded()) == state)
    }

    @Test("I4: damaged or unexpected state is refused", arguments: [
        "", "{}", "not json", #"{"version":2}"#,
        #"{"version":1,"commitment":{"startedAt":0,"durationSeconds":-5,"creditedSeconds":0,"listSHA256":"\#(String(repeating: "a", count: 64))","lastReading":{"wall":0,"monotonicNanoseconds":0,"bootSessionID":"A"}}}"#,
        #"{"version":1,"commitment":{"startedAt":0,"durationSeconds":7200,"creditedSeconds":0,"listSHA256":"short","lastReading":{"wall":0,"monotonicNanoseconds":0,"bootSessionID":"A"}}}"#,
        #"{"version":1,"commitment":{"startedAt":0,"durationSeconds":7200,"creditedSeconds":10,"recoveryRequestedAtCredit":50,"listSHA256":"\#(String(repeating: "a", count: 64))","lastReading":{"wall":0,"monotonicNanoseconds":0,"bootSessionID":"A"}}}"#,
    ])
    func refusesBadState(json: String) {
        #expect(throws: MastboundError.self) { try EngineState.decode(Data(json.utf8)) }
    }

    @Test("A minimal idle state decodes")
    func idleDecodes() throws {
        #expect(try EngineState.decode(Data(#"{"version":1}"#.utf8)) == .idle)
    }
}

@Suite("I11 file store")
struct FileStoreTests {
    private func tempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mastbound-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func write(_ text: String, to url: URL) throws {
        try FileStore.writeAtomically(Data(text.utf8), to: url, mode: 0o600, owner: getuid(), group: getgid())
    }

    @Test("I11: write then read gives the same bytes and mode 0600")
    func roundTrip() throws {
        let file = try tempDirectory().appendingPathComponent("state.json")
        try write("first", to: file)
        try write("second", to: file)
        #expect(try FileStore.read(at: file, expectedOwner: getuid(), maximumSize: 100) == Data("second".utf8))
        let mode = (try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue
        #expect(mode == 0o600)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path)
        #expect(leftovers == ["state.json"])
    }

    @Test("I11: a write that fails leaves the old file unchanged")
    func failedWriteKeepsOld() throws {
        let directory = try tempDirectory()
        let file = directory.appendingPathComponent("state.json")
        try write("old", to: file)
        chmod(directory.path, 0o500) // temp file cannot be created
        defer { chmod(directory.path, 0o700) }
        #expect(throws: (any Error).self) { try write("new", to: file) }
        #expect(try FileStore.read(at: file, expectedOwner: getuid(), maximumSize: 100) == Data("old".utf8))
    }

    @Test("Read refuses a symbolic link")
    func refusesSymlink() throws {
        let directory = try tempDirectory()
        let target = directory.appendingPathComponent("target")
        try write("x", to: target)
        let link = directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(throws: MastboundError.self) { try FileStore.read(at: link, expectedOwner: nil, maximumSize: 100) }
    }

    @Test("Read refuses a wrong owner, a group-writable file, a folder and a large file")
    func refusesUnsafeFiles() throws {
        let directory = try tempDirectory()
        let file = directory.appendingPathComponent("f")
        try write("12345", to: file)
        #expect(throws: MastboundError.self) { try FileStore.read(at: file, expectedOwner: getuid() + 1, maximumSize: 100) }
        #expect(throws: MastboundError.self) { try FileStore.read(at: file, expectedOwner: nil, maximumSize: 4) }
        chmod(file.path, 0o620)
        #expect(throws: MastboundError.self) { try FileStore.read(at: file, expectedOwner: nil, maximumSize: 100) }
        #expect(throws: MastboundError.self) { try FileStore.read(at: directory, expectedOwner: nil, maximumSize: 100) }
    }

    @Test("Read of a missing file throws")
    func missingFile() throws {
        let file = try tempDirectory().appendingPathComponent("missing")
        #expect(throws: (any Error).self) { try FileStore.read(at: file, expectedOwner: nil, maximumSize: 100) }
    }
}
