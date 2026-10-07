//===- WatchService.cpp - File system watcher thread for System.File -----===//
//
// See WatchService.hpp. Leaky singleton with detached threads (§3.4). The
// threads touch only POD (G1): they queue raw records under `qMutex` and wake
// the scheduler loop with notifyWorkAvailableFromAsync().
//
// Templates used: none (POD only, G1).
//
//===----------------------------------------------------------------------===//

#include "eco-system/FileSystem/WatchService.hpp"

#include "platform/Scheduler.hpp"

#include <atomic>
#include <chrono>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <filesystem>
#include <map>
#include <mutex>
#include <system_error>
#include <thread>
#include <unordered_map>
#include <utility>

#if !defined(_WIN32)
#include <cerrno>
#include <sys/stat.h>
#include <unistd.h>
#endif
#if defined(__linux__)
#include <fcntl.h>
#include <sys/inotify.h>
#endif

namespace Eco::System::Fs {

namespace {

using ::Elm::Platform::Scheduler;

// A queued record. inotify mode: (wd, mask, name), mapped on the main
// thread. Poll mode: an already mapped event.
struct Raw {
    bool mapped = false;
    int wd = -1;
    uint32_t mask = 0;
    std::string name;
    WatchEvent ev;
};

#if !defined(_WIN32)
// Poll-mode signature of one entry.
struct Sig {
    uint64_t ino = 0;
    uint32_t type = 0;
    int64_t mtimeNs = 0;
    int64_t ctimeNs = 0;
    int64_t size = 0;
    bool operator==(const Sig& o) const {
        return ino == o.ino && type == o.type && mtimeNs == o.mtimeNs && ctimeNs == o.ctimeNs &&
               size == o.size;
    }
};
using Snapshot = std::map<std::string, Sig>;   // relative path ("" = the root itself)

bool sigOf(const std::string& p, Sig& s) {
    struct stat sb;
    if (::lstat(p.c_str(), &sb) != 0) return false;
    s.ino = static_cast<uint64_t>(sb.st_ino);
    s.type = static_cast<uint32_t>(sb.st_mode & S_IFMT);
#if defined(__APPLE__)
    s.mtimeNs = static_cast<int64_t>(sb.st_mtimespec.tv_sec) * 1000000000 + sb.st_mtimespec.tv_nsec;
    s.ctimeNs = static_cast<int64_t>(sb.st_ctimespec.tv_sec) * 1000000000 + sb.st_ctimespec.tv_nsec;
#else
    s.mtimeNs = static_cast<int64_t>(sb.st_mtim.tv_sec) * 1000000000 + sb.st_mtim.tv_nsec;
    s.ctimeNs = static_cast<int64_t>(sb.st_ctim.tv_sec) * 1000000000 + sb.st_ctim.tv_nsec;
#endif
    s.size = static_cast<int64_t>(sb.st_size);
    return true;
}

// The root's own entry plus its children (recursively when asked). Never
// follows symlinks. Returns false when the root itself is missing.
bool takeSnapshot(const std::string& root, bool recursive, Snapshot& out) {
    out.clear();
    Sig rootSig;
    if (!sigOf(root, rootSig)) return false;
    out[""] = rootSig;
    if (rootSig.type != S_IFDIR) return true;
    namespace fs = std::filesystem;
    std::error_code ec;
    auto addEntry = [&](const fs::path& p) {
        std::error_code rec;
        fs::path rel = fs::relative(p, fs::path(root), rec);
        if (rec) return;
        Sig s;
        if (sigOf(p.string(), s)) out[rel.generic_string()] = s;
    };
    if (recursive) {
        fs::recursive_directory_iterator it(root, fs::directory_options::skip_permission_denied, ec), end;
        for (; !ec && it != end; it.increment(ec)) addEntry(it->path());
    } else {
        fs::directory_iterator it(root, fs::directory_options::skip_permission_denied, ec), end;
        for (; !ec && it != end; it.increment(ec)) addEntry(it->path());
    }
    return true;
}
#endif

} // namespace

struct WatchService::Impl {
    Scheduler* sched = nullptr;

    // --- The queue (any thread) ---
    std::mutex qMutex;
    std::deque<Raw> queue;
    std::atomic<size_t> queued{0};

    void push(Raw r) {
        {
            std::lock_guard<std::mutex> lk(qMutex);
            queue.push_back(std::move(r));
            queued.fetch_add(1, std::memory_order_acq_rel);
        }
        sched->notifyWorkAvailableFromAsync();   // outside qMutex
    }

    int64_t nextId = 1;
    bool pollMode = false;

#if defined(__linux__)
    // --- inotify mode (main thread only, except `inotifyFd` reads) ---
    int inotifyFd = -1;
    struct WdUse {
        int64_t watchId;
        std::string rel;   // "" for the watched path itself
    };
    struct InotifyWatch {
        std::string root;
        bool recursive = false;
        std::vector<int> wds;
    };
    std::unordered_map<int, std::vector<WdUse>> wdUses;
    std::unordered_map<int64_t, InotifyWatch> iwatches;

    static constexpr uint32_t kMask = IN_ATTRIB | IN_CREATE | IN_MODIFY | IN_DELETE | IN_DELETE_SELF |
                                      IN_MOVE_SELF | IN_MOVED_FROM | IN_MOVED_TO;

    bool startInotify() {
        if (inotifyFd >= 0) return true;
        int fd = ::inotify_init1(IN_CLOEXEC);
        if (fd < 0) return false;
        inotifyFd = fd;
        try {
            std::thread([this, fd] { inotifyThread(fd); }).detach();
        } catch (...) {
            ::close(fd);
            inotifyFd = -1;
            return false;
        }
        return true;
    }

    // The reader thread: raw records only (G1).
    void inotifyThread(int fd) {
        alignas(struct inotify_event) char buf[64 * 1024];
        for (;;) {
            ssize_t n = ::read(fd, buf, sizeof buf);
            if (n < 0) {
                if (errno == EINTR) continue;
                return;   // the fd is never closed; a real error ends the thread
            }
            for (char* p = buf; p < buf + n;) {
                auto* e = reinterpret_cast<struct inotify_event*>(p);
                Raw r;
                r.wd = e->wd;
                r.mask = e->mask;
                if (e->len) r.name = std::string(e->name);   // NUL-padded
                push(std::move(r));
                p += sizeof(struct inotify_event) + e->len;
            }
        }
    }

    bool addDir(int64_t id, const std::string& abs, const std::string& rel) {
        int wd = ::inotify_add_watch(inotifyFd, abs.c_str(), kMask);
        if (wd < 0) return false;
        auto& uses = wdUses[wd];
        for (auto& u : uses)
            if (u.watchId == id) return true;   // already watched by this watch
        uses.push_back(WdUse{id, rel});
        iwatches[id].wds.push_back(wd);
        return true;
    }

    // Adds watches for every directory below `abs` (recursive watches).
    void addTree(int64_t id, const std::string& abs, const std::string& rel) {
        namespace fs = std::filesystem;
        std::error_code ec;
        fs::recursive_directory_iterator it(abs, fs::directory_options::skip_permission_denied, ec), end;
        for (; !ec && it != end; it.increment(ec)) {
            std::error_code sec;
            if (!it->is_directory(sec) || it->is_symlink(sec)) continue;
            std::error_code rec;
            fs::path r = fs::relative(it->path(), fs::path(abs), rec);
            if (rec) continue;
            std::string sub = rel.empty() ? r.generic_string() : rel + "/" + r.generic_string();
            addDir(id, it->path().string(), sub);
        }
    }

    void dropWd(int64_t id, int wd, bool rmWatch) {
        auto it = wdUses.find(wd);
        if (it == wdUses.end()) return;
        auto& uses = it->second;
        for (size_t i = 0; i < uses.size();) {
            if (uses[i].watchId == id) uses.erase(uses.begin() + static_cast<long>(i));
            else ++i;
        }
        if (uses.empty()) {
            if (rmWatch) ::inotify_rm_watch(inotifyFd, wd);
            wdUses.erase(it);
        }
    }

    // Main thread: one raw inotify record → events.
    void mapInotify(const Raw& r, std::vector<WatchEvent>& out) {
        auto it = wdUses.find(r.wd);
        if (it == wdUses.end()) return;
        std::vector<WdUse> uses = it->second;   // copy: the tables change below
        if (r.mask & IN_IGNORED) {              // the kernel dropped the watch
            for (auto& u : uses) {
                auto w = iwatches.find(u.watchId);
                if (w != iwatches.end()) {
                    auto& v = w->second.wds;
                    for (size_t i = 0; i < v.size();) {
                        if (v[i] == r.wd) v.erase(v.begin() + static_cast<long>(i));
                        else ++i;
                    }
                }
            }
            wdUses.erase(r.wd);
            return;
        }
        if (r.mask & IN_Q_OVERFLOW) return;
        bool rename = (r.mask & (IN_CREATE | IN_DELETE | IN_DELETE_SELF | IN_MOVE_SELF | IN_MOVED_FROM |
                                 IN_MOVED_TO)) != 0;
        bool change = (r.mask & (IN_ATTRIB | IN_MODIFY)) != 0;
        if (!rename && !change) return;
        bool self = r.name.empty();
        for (auto& u : uses) {
            auto w = iwatches.find(u.watchId);
            if (w == iwatches.end()) continue;
            if (self && !u.rel.empty()) continue;   // a sub-directory's own event: its parent reports it
            WatchEvent ev;
            ev.watchId = u.watchId;
            ev.kind = rename ? 1 : 0;
            if (!self) {
                ev.hasPath = true;
                ev.path = u.rel.empty() ? r.name : u.rel + "/" + r.name;
                if (w->second.recursive && (r.mask & IN_ISDIR) && (r.mask & (IN_CREATE | IN_MOVED_TO))) {
                    std::string abs = w->second.root + "/" + ev.path;
                    if (addDir(u.watchId, abs, ev.path)) addTree(u.watchId, abs, ev.path);
                }
            }
            out.push_back(std::move(ev));
        }
    }
#endif

#if !defined(_WIN32)
    // --- Poll mode ---
    struct PollWatch {
        std::string root;
        bool recursive = false;
        Snapshot snap;
    };
    std::mutex pMutex;                          // guards pwatches (POD only)
    std::map<int64_t, PollWatch> pwatches;
    bool pollThreadStarted = false;

    bool startPollThread() {
        if (pollThreadStarted) return true;
        try {
            std::thread([this] { pollThread(); }).detach();
        } catch (...) {
            return false;
        }
        pollThreadStarted = true;
        return true;
    }

    void pollThread() {
        for (;;) {
            std::this_thread::sleep_for(std::chrono::seconds(1));
            std::vector<std::pair<int64_t, std::pair<std::string, bool>>> todo;
            {
                std::lock_guard<std::mutex> lk(pMutex);
                for (auto& [id, w] : pwatches) todo.push_back({id, {w.root, w.recursive}});
            }
            for (auto& [id, spec] : todo) {
                Snapshot now;
                bool exists = takeSnapshot(spec.first, spec.second, now);
                std::vector<WatchEvent> evs;
                {
                    std::lock_guard<std::mutex> lk(pMutex);
                    auto it = pwatches.find(id);
                    if (it == pwatches.end()) continue;
                    Snapshot& old = it->second.snap;
                    if (!exists && !old.empty()) {
                        WatchEvent ev;
                        ev.watchId = id;
                        ev.kind = 1;   // the watched path itself went away
                        evs.push_back(ev);
                    } else {
                        for (auto& [rel, sig] : now) {
                            auto o = old.find(rel);
                            if (o == old.end() || o->second.ino != sig.ino || o->second.type != sig.type) {
                                evs.push_back(WatchEvent{id, 1, !rel.empty(), rel});   // added / replaced
                            } else if (!(o->second == sig) && sig.type != S_IFDIR) {
                                // Directories change when their entries do; those are reported.
                                evs.push_back(WatchEvent{id, 0, !rel.empty(), rel});
                            }
                        }
                        for (auto& [rel, sig] : old)
                            if (!now.count(rel) && !rel.empty()) evs.push_back(WatchEvent{id, 1, true, rel});
                    }
                    old = std::move(now);
                }
                for (auto& ev : evs) {
                    Raw r;
                    r.mapped = true;
                    r.ev = std::move(ev);
                    push(std::move(r));
                }
            }
        }
    }
#endif
};

WatchService& WatchService::instance() {
    static WatchService* s = new WatchService();   // leaky (§3.4)
    return *s;
}

WatchService::WatchService() : impl_(new Impl()) {
    impl_->sched = &Scheduler::instance();   // bound on the main thread
#if defined(__linux__)
    const char* poll = std::getenv("ECO_SYSTEM_WATCH_POLL");
    impl_->pollMode = poll && *poll && std::strcmp(poll, "0") != 0;
#elif !defined(_WIN32)
    impl_->pollMode = true;
#endif
}

int64_t WatchService::add(const std::string& path, bool recursive) {
#if defined(_WIN32)
    (void)path;
    (void)recursive;
    return 0;
#else
    Impl& m = *impl_;
#if defined(__linux__)
    if (!m.pollMode) {
        if (!m.startInotify()) return 0;
        int64_t id = m.nextId++;
        m.iwatches[id] = Impl::InotifyWatch{path, recursive, {}};
        if (!m.addDir(id, path, "")) {
            m.iwatches.erase(id);
            return 0;
        }
        if (recursive) m.addTree(id, path, "");
        return id;
    }
#endif
    Impl::PollWatch w;
    w.root = path;
    w.recursive = recursive;
    if (!takeSnapshot(path, recursive, w.snap)) return 0;
    if (!m.startPollThread()) return 0;
    int64_t id = m.nextId++;
    {
        std::lock_guard<std::mutex> lk(m.pMutex);
        m.pwatches[id] = std::move(w);
    }
    return id;
#endif
}

void WatchService::remove(int64_t id) {
#if !defined(_WIN32)
    Impl& m = *impl_;
#if defined(__linux__)
    if (!m.pollMode) {
        auto it = m.iwatches.find(id);
        if (it == m.iwatches.end()) return;
        std::vector<int> wds = it->second.wds;
        m.iwatches.erase(it);
        for (int wd : wds) m.dropWd(id, wd, /*rmWatch=*/true);
        return;
    }
#endif
    std::lock_guard<std::mutex> lk(m.pMutex);
    m.pwatches.erase(id);
#else
    (void)id;
#endif
}

void WatchService::drain(std::vector<WatchEvent>& out) {
    std::deque<Raw> raws;
    {
        std::lock_guard<std::mutex> lk(impl_->qMutex);
        raws.swap(impl_->queue);
        impl_->queued.store(0, std::memory_order_release);
    }
    for (auto& r : raws) {
        if (r.mapped) {
            out.push_back(std::move(r.ev));
            continue;
        }
#if defined(__linux__)
        impl_->mapInotify(r, out);
#endif
    }
}

bool WatchService::hasEvents() const {
    return impl_->queued.load(std::memory_order_acquire) > 0;
}

} // namespace Eco::System::Fs
