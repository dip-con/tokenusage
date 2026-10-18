import Darwin
import Foundation

/// Whether a CLI that renews its own token is running. Every failure to look counts as "running":
/// a wrong "no" lets the app rotate a refresh token a live CLI still holds, which signs it out.
enum CLIProcessProbe {
    static func anyRunning(where matches: (_ path: String, _ arguments: [String]) -> Bool) -> Bool {
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        guard capacity > 64 else { return true }
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.size)))
        guard count > 0 else { return true }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        for pid in pids.prefix(count) where pid > 0 && pid != getpid() {
            guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { continue }
            let path = String(cString: buffer)
            if matches(path, arguments(of: pid)) { return true }
        }
        return false
    }

    /// argv of another process of this user, via KERN_PROCARGS2; empty when it cannot be read.
    private static func arguments(of pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else {
            return []
        }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &bytes, &size, nil, 0) == 0 else { return [] }
        let argc = bytes.withUnsafeBytes { Int($0.load(as: Int32.self)) }
        var index = MemoryLayout<Int32>.size
        while index < size, bytes[index] != 0 { index += 1 }
        while index < size, bytes[index] == 0 { index += 1 }
        var result: [String] = []
        while result.count < argc, index < size {
            let start = index
            while index < size, bytes[index] != 0 { index += 1 }
            result.append(String(decoding: bytes[start..<index], as: UTF8.self))
            index += 1
        }
        return result
    }
}

/// Any `grok` CLI process, including its background leader and the self-updated
/// `grok-<version>-macos-<arch>` binaries it re-executes into.
public enum GrokCLIProcessProbe {
    public static func isRunning() -> Bool {
        CLIProcessProbe.anyRunning { path, _ in
            let name = (path as NSString).lastPathComponent
            return name == "grok" || (name.hasPrefix("grok-") && name.contains("-macos-"))
        }
    }
}

/// Any Claude Code process: the native install (`~/.local/share/claude/versions/<version>`), a
/// binary named `claude` (editor extensions, Homebrew), or `@anthropic-ai/claude-code` under node.
public enum ClaudeCodeProcessProbe {
    public static func isRunning() -> Bool {
        CLIProcessProbe.anyRunning { path, arguments in
            if (path as NSString).lastPathComponent == "claude"
                || path.contains("/claude/versions/")
                || path.contains("claude-code") {
                return true
            }
            return arguments.prefix(3).contains { argument in
                argument.contains("claude-code")
                    || (argument as NSString).lastPathComponent == "claude"
            }
        }
    }
}
