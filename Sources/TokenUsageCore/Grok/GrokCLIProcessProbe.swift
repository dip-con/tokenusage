import Darwin
import Foundation

/// Whether a CLI that renews its own token is running. Every failure to look counts as "running":
/// a wrong "no" lets the app rotate a refresh token a live CLI still holds, which signs it out.
enum CLIProcessProbe {
    static func anyRunning(
        where matches: (_ path: String, _ arguments: [String], _ environment: [String]) -> Bool
    ) -> Bool {
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        guard capacity > 64 else { return true }
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.size)))
        guard count > 0 else { return true }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        for pid in pids.prefix(count) where pid > 0 && pid != getpid() {
            guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { continue }
            let path = String(cString: buffer)
            let commandLine = commandLine(of: pid)
            if matches(path, commandLine.arguments, commandLine.environment) { return true }
        }
        return false
    }

    /// argv and environment of another process of this user, via KERN_PROCARGS2; empty when they
    /// cannot be read.
    private static func commandLine(of pid: pid_t) -> (arguments: [String], environment: [String]) {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else {
            return ([], [])
        }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &bytes, &size, nil, 0) == 0 else { return ([], []) }
        return commandLine(fromProcessArguments: Array(bytes.prefix(size)))
    }

    /// Splits a KERN_PROCARGS2 buffer: argc, the executable path, padding, argv, then `KEY=value`
    /// environment strings up to the first empty one.
    static func commandLine(
        fromProcessArguments bytes: [UInt8]
    ) -> (arguments: [String], environment: [String]) {
        let size = bytes.count
        guard size > MemoryLayout<Int32>.size else { return ([], []) }
        let argc = bytes.withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
        var index = MemoryLayout<Int32>.size
        while index < size, bytes[index] != 0 { index += 1 }
        while index < size, bytes[index] == 0 { index += 1 }
        var arguments: [String] = []
        while arguments.count < argc, index < size {
            let start = index
            while index < size, bytes[index] != 0 { index += 1 }
            arguments.append(String(decoding: bytes[start..<index], as: UTF8.self))
            index += 1
        }
        var environment: [String] = []
        while index < size, bytes[index] != 0 {
            let start = index
            while index < size, bytes[index] != 0 { index += 1 }
            environment.append(String(decoding: bytes[start..<index], as: UTF8.self))
            index += 1
        }
        return (arguments, environment)
    }
}

/// Any `grok` CLI process, including its background leader and the self-updated
/// `grok-<version>-macos-<arch>` binaries it re-executes into.
public enum GrokCLIProcessProbe {
    public static func isRunning() -> Bool {
        CLIProcessProbe.anyRunning { path, _, _ in
            let name = (path as NSString).lastPathComponent
            return name == "grok" || (name.hasPrefix("grok-") && name.contains("-macos-"))
        }
    }
}

/// Any Claude Code process: the native install (`~/.local/share/claude/versions/<version>`), a
/// binary named `claude` (editor extensions, Homebrew), or `@anthropic-ai/claude-code` under node.
///
/// A process started with `CLAUDE_CODE_OAUTH_TOKEN` signs in with that token and never reads or
/// renews the Keychain credential, so it does not count. Agent SDK hosts keep such processes alive
/// around the clock; counting them left the signed-in account expired for days.
public enum ClaudeCodeProcessProbe {
    public static func isRunning() -> Bool {
        CLIProcessProbe.anyRunning(where: holdsKeychainCredential)
    }

    static func holdsKeychainCredential(
        path: String,
        arguments: [String],
        environment: [String]
    ) -> Bool {
        let isClaudeCode = (path as NSString).lastPathComponent == "claude"
            || path.contains("/claude/versions/")
            || path.contains("claude-code")
            || arguments.prefix(3).contains { argument in
                argument.contains("claude-code")
                    || (argument as NSString).lastPathComponent == "claude"
            }
        guard isClaudeCode else { return false }
        let usesEnvironmentToken = environment.contains {
            $0.hasPrefix("CLAUDE_CODE_OAUTH_TOKEN=") && $0.count > "CLAUDE_CODE_OAUTH_TOKEN=".count
        }
        return !usesEnvironmentToken
    }
}
