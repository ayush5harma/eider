import Darwin
import Foundation

/// Which processes run from an app bundle. Read from the kernel (libproc), not
/// from `ps` or NSWorkspace: the first is not on the architecture's allowed
/// list, and the second can be stale in a command-line tool with no run loop.
enum RunningProcesses {
    /// Process ids whose executable lives inside `bundle` (path prefix, so
    /// `A.app` never matches `A.app.old`).
    static func pids(insideBundle bundle: URL) -> [Int32] {
        let prefix = bundle.resolvingSymlinksInPath().path + "/"
        return pids { $0.hasPrefix(prefix) }
    }

    /// Process ids whose executable path contains `fragment`, e.g. `/Name.app/`.
    static func pids(pathContaining fragment: String) -> [Int32] {
        pids { $0.contains(fragment) }
    }

    private static func pids(where matches: (String) -> Bool) -> [Int32] {
        let bytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard bytes > 0 else { return [] }
        var all = [Int32](repeating: 0, count: Int(bytes) / MemoryLayout<Int32>.size + 16)
        let filled = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &all, Int32(all.count * MemoryLayout<Int32>.size))
        guard filled > 0 else { return [] }
        var found: [Int32] = []
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        for pid in all.prefix(Int(filled) / MemoryLayout<Int32>.size) where pid > 0 {
            guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { continue }
            if matches(String(cString: path)) { found.append(pid) }
        }
        return found
    }
}
