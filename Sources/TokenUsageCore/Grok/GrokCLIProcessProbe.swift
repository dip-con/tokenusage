import Darwin
import Foundation

/// Whether any `grok` CLI process is running, including its background leader and the
/// self-updated `grok-<version>-macos-<arch>` binaries it re-executes into.
public enum GrokCLIProcessProbe {
    public static func isRunning() -> Bool {
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        guard capacity > 64 else { return true }
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.size)))
        // Failing to enumerate must not unlock renewal of a token the CLI may be holding.
        guard count > 0 else { return true }
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        for pid in pids.prefix(count) where pid > 0 {
            guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { continue }
            let name = (String(cString: path) as NSString).lastPathComponent
            if name == "grok" || (name.hasPrefix("grok-") && name.contains("-macos-")) {
                return true
            }
        }
        return false
    }
}
