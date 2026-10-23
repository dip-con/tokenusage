import XCTest
@testable import TokenUsageCore

final class ClaudeCodeProcessProbeTests: XCTestCase {
    private let nativeClaude = "/Users/me/.local/share/claude/versions/2.1.283"

    func testInteractiveClaudeCodeHoldsTheKeychainCredential() {
        XCTAssertTrue(ClaudeCodeProcessProbe.holdsKeychainCredential(
            path: nativeClaude,
            arguments: ["/Users/me/.local/bin/claude"],
            environment: ["HOME=/Users/me", "TERM=xterm-256color"]
        ))
    }

    func testClaudeCodeSignedInThroughEnvironmentTokenDoesNotCount() {
        XCTAssertFalse(ClaudeCodeProcessProbe.holdsKeychainCredential(
            path: nativeClaude,
            arguments: ["/Users/me/.local/bin/claude", "--output-format", "stream-json"],
            environment: ["HOME=/Users/me", "CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-test"]
        ))
    }

    func testEmptyEnvironmentTokenStillCounts() {
        XCTAssertTrue(ClaudeCodeProcessProbe.holdsKeychainCredential(
            path: nativeClaude,
            arguments: [],
            environment: ["CLAUDE_CODE_OAUTH_TOKEN="]
        ))
    }

    func testOtherProcessesDoNotCount() {
        XCTAssertFalse(ClaudeCodeProcessProbe.holdsKeychainCredential(
            path: "/usr/bin/python3",
            arguments: ["python3", "server.py"],
            environment: []
        ))
    }

    func testProcessArgumentsBufferSplitsArgumentsFromEnvironment() {
        var bytes = withUnsafeBytes(of: Int32(2).littleEndian) { Array($0) }
        bytes += Array("/bin/claude".utf8) + [0, 0, 0]
        bytes += Array("claude".utf8) + [0] + Array("-p".utf8) + [0]
        bytes += Array("A=1".utf8) + [0] + Array("CLAUDE_CODE_OAUTH_TOKEN=x".utf8) + [0, 0]
        bytes += Array("ptr_munge=".utf8) + [0]

        let commandLine = CLIProcessProbe.commandLine(fromProcessArguments: bytes)

        XCTAssertEqual(commandLine.arguments, ["claude", "-p"])
        XCTAssertEqual(commandLine.environment, ["A=1", "CLAUDE_CODE_OAUTH_TOKEN=x"])
    }
}
