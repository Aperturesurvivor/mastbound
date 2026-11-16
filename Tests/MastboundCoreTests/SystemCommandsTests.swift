import Foundation
import Testing
@testable import MastboundCore

@Suite("System commands")
struct SystemCommandsTests {
    @Test("A program that hangs is killed after the time limit, so the daemon loop goes on")
    func hangingProgramIsKilled() throws {
        let start = Date()
        let result = try SystemCommands.run("/bin/sleep", ["30"], timeout: 0.5)
        #expect(result.timedOut)
        #expect(Date().timeIntervalSince(start) < 5)
    }

    @Test("A normal program returns its status and output")
    func normalProgram() throws {
        let result = try SystemCommands.run("/bin/echo", ["hello"])
        #expect(!result.timedOut)
        #expect(result.status == 0)
        #expect(result.output == "hello\n")
    }
}
