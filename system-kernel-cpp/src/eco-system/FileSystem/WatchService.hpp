//===- WatchService.hpp - File system watcher thread for System.File -----===//
//
// plans/eco-system-library.md Phase 4 step 4.5 / §3.8: the service behind
// `System.File.watch` / `watchRecursive`.
//
//   * Linux: one inotify instance read by one detached thread. The thread
//     only reads raw (wd, mask, name) records and queues them; every mapping
//     (wd → watch, recursive sub-directory watches, IN_IGNORED clean-up) is
//     done on the main thread when the queue is drained, so the watch tables
//     need no lock. inotify_add_watch / inotify_rm_watch are called from the
//     main thread and take effect in the kernel directly, so the reader
//     thread never needs waking (no wake pipe).
//   * Elsewhere (macOS, …), or on Linux with ECO_SYSTEM_WATCH_POLL=1: one
//     detached thread that polls every watched tree once a second and diffs
//     stat snapshots (entry added/removed/replaced → Moved, size/mtime/ctime
//     changed → Changed).
//   * Windows: no watching (§1); the manager crashes with a clear message.
//
// Events reach the main thread as POD WatchEvent values (G1):
// (watchId, kind 0 Changed / 1 Moved, relative path or none), following
// node's fs.watch: IN_ATTRIB/IN_MODIFY are "change", every create, delete
// or move is "rename" (libuv's mapping).
//
// The service holds no pendingAsync count itself: the System.File manager
// holds one per active watch (§3.4 keep-alive rule).
//
// Templates used: none (POD only, G1).
//
//===----------------------------------------------------------------------===//

#ifndef ECO_SYSTEM_FILESYSTEM_WATCH_SERVICE_HPP
#define ECO_SYSTEM_FILESYSTEM_WATCH_SERVICE_HPP

#include <cstdint>
#include <string>
#include <vector>

namespace Eco::System::Fs {

struct WatchEvent {
    int64_t watchId = 0;
    int kind = 0;           // 0 Changed, 1 Moved (C.2 tagger argument)
    bool hasPath = false;
    std::string path;       // relative to the watched path
};

class WatchService {
public:
    // Main thread (the first call binds the Scheduler).
    static WatchService& instance();

    // Main thread. Starts watching `path`. Returns a watch id > 0, or 0 when
    // the path cannot be watched (it then produces no events; gren ignores
    // watch errors too).
    int64_t add(const std::string& path, bool recursive);

    // Main thread. Stops watch `id` (unknown ids are ignored). Events of the
    // watch that are already queued may still be drained; the manager drops
    // events of ids it no longer knows.
    void remove(int64_t id);

    // Main thread. Moves every queued event to `out`, mapped to watch ids.
    void drain(std::vector<WatchEvent>& out);

    // Lock-free; any thread (the Scheduler's ready predicate).
    bool hasEvents() const;

    struct Impl;

private:
    WatchService();
    Impl* impl_;
};

} // namespace Eco::System::Fs

#endif // ECO_SYSTEM_FILESYSTEM_WATCH_SERVICE_HPP
