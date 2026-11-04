//===- WatchService.hpp - File system watcher thread for FileSystem -----===//
//
// A program that asks to be told when files change needs something that notices the change while the program is
// busy doing other things. This component is that watcher, the backend behind `FileSystem.watch` and
// `watchRecursive`: it turns changes under a watched path into `WatchEvent` values that the thread running the Elm
// scheduler collects with `drain`.
//
// A watch is one request to observe one path, identified by the id `add` returns. A non-recursive watch of a
// directory observes the directory and its direct entries; a recursive one observes the whole tree below it. A
// watch of a file observes the file itself. Every event has one of two kinds: *Changed* (kind 0), an entry's
// contents or attributes changed, and *Moved* (kind 1), an entry was created, deleted, renamed or replaced. An event
// names the entry by its path relative to the watched path, or names no path when the event is about the watched
// path itself.
//
// There are two ways to notice a change, and the service uses one of them for its whole life.
//
//   * inotify, on Linux unless the environment variable `ECO_SYSTEM_WATCH_POLL` is set to anything other than
//     empty or `0`. One detached thread reads the inotify instance and queues each record unchanged. Turning a
//     record into events, and adding the watches for directories created inside a recursive watch, happens in
//     `drain`, so the tables that map inotify watches to ids are used by one thread only. An attribute change or
//     a modification is Changed; a create, delete or move is Moved. Directories that are symbolic links are not
//     followed below the watched path. A queue overflow record is dropped, so changes it stands for are lost.
//   * Poll mode, on other POSIX systems, or on Linux when the variable asks for it. One detached thread takes a
//     snapshot of every watched tree once a second (the type, inode, size, mtime and ctime of each entry, read
//     without following symbolic links) and compares it with the last one. An entry that appeared, disappeared,
//     or has a different inode or type is Moved. Any other difference is Changed, except on a directory, whose
//     own differences are not reported. When the watched path itself disappears, one Moved event with no path is
//     reported.
//
// On Windows nothing is watched: `add` returns 0.
//
// The service is never destroyed and its threads are never joined. It holds no liveness hold of its own, so an
// active watch does not by itself keep the program running; whoever adds the watch must hold one.
//
//===----------------------------------------------------------------------===//

#ifndef ECO_SYSTEM_FILESYSTEM_WATCH_SERVICE_HPP
#define ECO_SYSTEM_FILESYSTEM_WATCH_SERVICE_HPP

#include <cstdint>
#include <string>
#include <vector>

namespace Eco::System::Fs {

/// One change noticed under a watched path.
struct WatchEvent {
    int64_t watchId = 0;
    int kind = 0;           ///< 0 for Changed, 1 for Moved.
    bool hasPath = false;   ///< False when the event is about the watched path itself; `path` is then empty.
    std::string path;       ///< Relative to the watched path, with `/` separators.
};

/// The process's one file watcher, which owns every watch and the queue of events they produce.
///
/// `add`, `remove` and `drain` use state that no lock guards, so they must all be called from one thread, the
/// one that runs the Elm scheduler. Only `hasEvents` may be called from any thread.
class WatchService {
public:
    /// Returns the service, creating it on the first call. The first call binds the service to
    /// `Elm::Platform::Scheduler::instance()`, which it wakes whenever an event is queued, and reads
    /// `ECO_SYSTEM_WATCH_POLL`, on Linux, to choose between inotify and poll mode.
    static WatchService& instance();

    /// Starts watching `path`, and its whole tree when `recursive` is true. Returns a new watch id, which is
    /// greater than 0, or 0 when the path cannot be watched, for instance because it does not exist or the
    /// watcher thread cannot be started. A failed watch produces no events and reports no error.
    int64_t add(const std::string& path, bool recursive);

    /// Stops watch `id`. An unknown id is ignored. Events of the watch that were already queued may still be
    /// returned by a later `drain`.
    void remove(int64_t id);

    /// Appends every event queued since the last call to `out`, and empties the queue. In inotify mode this is
    /// also where a directory created inside a recursive watch starts to be watched.
    void drain(std::vector<WatchEvent>& out);

    /// Returns whether any record is queued for `drain`. It reads an atomic counter only. A true result may still
    /// yield no events, since some queued inotify records map to none.
    bool hasEvents() const;

    /// The service's private state.
    struct Impl;

private:
    /// Creates the service and chooses its mode; see `instance`.
    WatchService();
    Impl* impl_;   ///< Owned, never freed: the service lives until the process ends.
};

} // namespace Eco::System::Fs

#endif // ECO_SYSTEM_FILESYSTEM_WATCH_SERVICE_HPP
