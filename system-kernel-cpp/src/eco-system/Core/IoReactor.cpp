//===- IoReactor.cpp - The shared non-blocking IO event loop --------------===//
//
// See IoReactor.hpp (plans/eco-system-sockets.md §3.3.1). Leaky singleton
// with a detached thread (base plan §3.4): std::exit never destroys state a
// live reactor thread still uses.
//
// State split:
//   * shared (any thread): the command queue (cmdMu), the quiesce handshake
//     (qMu/qCv), the iteration counter;
//   * reactor thread only, no lock: the slot table, the timer heap, the
//     backend's event buffer.
// No lock is ever held while a handler or a command runs (rule 6).
//
// Templates used: none (POD only, G1).
//
//===----------------------------------------------------------------------===//

#include "eco-system/Core/IoReactor.hpp"

#include <atomic>
#include <cassert>
#include <cerrno>
#include <chrono>
#include <climits>
#include <condition_variable>
#include <cstdio>
#include <cstring>
#include <deque>
#include <exception>
#include <mutex>
#include <queue>
#include <thread>
#include <utility>
#include <vector>

#if defined(_WIN32)
#define ECO_IOR_STUB 1
#elif defined(__linux__)
#define ECO_IOR_EPOLL 1
#include <sys/epoll.h>
#include <sys/eventfd.h>
#include <unistd.h>
#elif defined(__APPLE__) || defined(__FreeBSD__) || defined(__OpenBSD__) || defined(__NetBSD__) || \
    defined(__DragonFly__)
#define ECO_IOR_KQUEUE 1
#include <fcntl.h>
#include <sys/event.h>
#include <sys/time.h>
#include <sys/types.h>
#include <unistd.h>
#else
#error "IoReactor: no backend for this platform (epoll, kqueue or the WIN32 stub)"
#endif

// Reactor-thread-only entry points check their thread in assert builds.
#define ECO_IOR_REACTOR_ONLY() assert(::Eco::System::IoReactor::onReactorThread())

namespace Eco::System {

namespace {

thread_local bool t_onReactor = false;

[[maybe_unused]] constexpr uint64_t kWakeKey = 0;   // never a handler key (generations start at 1)
[[maybe_unused]] constexpr int kMaxEvents = 256;

inline uint32_t slotOf(uint64_t key) { return static_cast<uint32_t>(key & 0xFFFFFFFFu); }
inline uint32_t genOf(uint64_t key) { return static_cast<uint32_t>(key >> 32); }
inline uint64_t makeKey(uint32_t slot, uint32_t gen) {
    return static_cast<uint64_t>(slot) | (static_cast<uint64_t>(gen) << 32);
}

// Handlers and commands must not take the reactor down: an exception escaping
// a detached thread would terminate the process.
template <typename F>
void guarded(const char* what, F&& f) {
    try {
        f();
    } catch (const std::exception& e) {
        std::fprintf(stderr, "[eco-system] IoReactor: exception in %s: %s\n", what, e.what());
        std::fflush(stderr);
    } catch (...) {
        std::fprintf(stderr, "[eco-system] IoReactor: unknown exception in %s\n", what);
        std::fflush(stderr);
    }
}

struct Ev {
    uint64_t key;
    bool r, w, e;
};

} // namespace

bool IoReactor::onReactorThread() { return t_onReactor; }

int64_t IoReactor::nowMs() const {
    return std::chrono::duration_cast<std::chrono::milliseconds>(
               std::chrono::steady_clock::now().time_since_epoch())
        .count();
}

// ---------------------------------------------------------------------------
// Impl
// ---------------------------------------------------------------------------

struct IoReactor::Impl {
    // --- shared ---------------------------------------------------------------
    bool ok = false;   // backend created and thread started (set before instance() returns)

    std::mutex cmdMu;
    std::deque<std::function<void()>> cmds;

    std::atomic<uint64_t> iterations{0};

    std::atomic<bool> quiesceRequested{false};
    std::mutex qMu;
    std::condition_variable qCv;
    bool quiesceAck = false;   // under qMu

    // --- reactor thread only -----------------------------------------------
    struct Slot {
        std::shared_ptr<IoHandler> h;
        int fd = -1;
        uint32_t gen = 1;
        bool live = false;
        bool wantR = false;   // what is in the kernel set
        bool wantW = false;
        int64_t timerDeadline = 0;   // 0: none
        uint64_t timerSeq = 0;
    };
    std::vector<Slot> slots;
    std::vector<uint32_t> freeSlots;   // LIFO

    struct TimerEntry {
        int64_t deadline;
        uint64_t seq;
        uint64_t key;
    };
    struct TimerLater {
        bool operator()(const TimerEntry& a, const TimerEntry& b) const {
            return a.deadline > b.deadline || (a.deadline == b.deadline && a.seq > b.seq);
        }
    };
    std::priority_queue<TimerEntry, std::vector<TimerEntry>, TimerLater> timers;
    uint64_t timerSeq = 0;
    size_t liveTimers = 0;

    std::vector<Ev> batch;

    // --- backend --------------------------------------------------------------
    int pollFd = -1;   // epoll / kqueue
    int wakeFd = -1;   // eventfd (epoll only)

    Slot* live(uint64_t key) {
        uint32_t idx = slotOf(key);
        if (key == 0 || idx >= slots.size()) return nullptr;
        Slot& s = slots[idx];
        if (!s.live || s.gen != genOf(key)) return nullptr;
        return &s;
    }

    bool timerValid(const TimerEntry& t) {
        Slot* s = live(t.key);
        return s && s->timerDeadline == t.deadline && s->timerSeq == t.seq;
    }

    // Drops stale entries when they dominate the heap (setTimer re-arms
    // lazily: the old entry stays until popped).
    void maybeCompactTimers() {
        if (timers.size() <= 64 || timers.size() <= 4 * liveTimers) return;
        std::vector<TimerEntry> keep;
        keep.reserve(liveTimers);
        while (!timers.empty()) {
            if (timerValid(timers.top())) keep.push_back(timers.top());
            timers.pop();
        }
        for (auto& t : keep) timers.push(t);
    }

    // ms until the earliest live timer (0 if due), or -1 for none.
    int64_t nextTimeout(int64_t now) {
        while (!timers.empty() && !timerValid(timers.top())) timers.pop();
        if (timers.empty()) return -1;
        int64_t d = timers.top().deadline - now;
        return d < 0 ? 0 : d;
    }

    [[noreturn]] void park() {
        {
            std::lock_guard<std::mutex> lk(qMu);
            quiesceAck = true;
        }
        qCv.notify_all();
        std::unique_lock<std::mutex> lk(qMu);
        for (;;) qCv.wait(lk);
    }

    void checkQuiesce() {
        if (quiesceRequested.load(std::memory_order_acquire)) park();
    }

    bool backendInit();
    void wake();
    void resetWake();
    // Waits up to timeoutMs (-1: forever); fills `batch`; true if the wake
    // event was among the results.
    bool backendWait(int64_t timeoutMs);
    // Brings the kernel set to (r, w) for the slot; updates s.wantR/wantW to
    // what the kernel holds. 0 or errno.
    int backendCtl(Slot& s, uint64_t key, bool r, bool w);

    void dispatchEvent(uint64_t key, bool r, bool w, bool e) {
        checkQuiesce();
        Slot* s = live(key);
        if (!s) return;   // removed (stale generation, rule 2)
        r = r && s->wantR;
        w = w && s->wantW;
        if (!s->wantR && !s->wantW) return;   // no interest any more (rule 1)
        if (!r && !w && !e) return;
        std::shared_ptr<IoHandler> h = s->h;   // keeps it alive if it removes itself
        guarded("onReady", [&] { h->onReady(r, w, e); });
    }

    void fireTimers(int64_t now) {
        std::vector<TimerEntry> due;
        while (!timers.empty()) {
            const TimerEntry& t = timers.top();
            if (!timerValid(t)) {
                timers.pop();
                continue;
            }
            if (t.deadline > now) break;
            due.push_back(t);
            timers.pop();
        }
        for (const TimerEntry& t : due) {
            checkQuiesce();
            if (!timerValid(t)) continue;   // cancelled or removed by an earlier timer
            Slot* s = live(t.key);
            s->timerDeadline = 0;
            --liveTimers;
            std::shared_ptr<IoHandler> h = s->h;
            guarded("onTimer", [&] { h->onTimer(); });
        }
    }

    void drainCommands() {
        std::deque<std::function<void()>> todo;
        {
            std::lock_guard<std::mutex> lk(cmdMu);
            todo.swap(cmds);
        }
        for (auto& fn : todo) {
            checkQuiesce();
            guarded("a submitted command", [&] { fn(); });
        }
    }

    void closeAllNow() {
        std::vector<std::pair<uint64_t, std::shared_ptr<IoHandler>>> snap;
        for (uint32_t i = 0; i < slots.size(); ++i) {
            if (slots[i].live) snap.emplace_back(makeKey(i, slots[i].gen), slots[i].h);
        }
        for (auto& entry : snap) {
            checkQuiesce();
            if (!live(entry.first)) continue;   // removed by an earlier onCloseAll
            IoHandler* h = entry.second.get();   // kept alive by `snap`
            guarded("onCloseAll", [h] { h->onCloseAll(); });
        }
    }
};

// ---------------------------------------------------------------------------
// Backends
// ---------------------------------------------------------------------------

#if defined(ECO_IOR_EPOLL)

bool IoReactor::Impl::backendInit() {
    pollFd = ::epoll_create1(EPOLL_CLOEXEC);
    if (pollFd < 0) return false;
    wakeFd = ::eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK);
    if (wakeFd < 0) return false;
    struct epoll_event ev;
    std::memset(&ev, 0, sizeof(ev));
    ev.events = EPOLLIN;   // level-triggered: stays ready until resetWake()
    ev.data.u64 = kWakeKey;
    return ::epoll_ctl(pollFd, EPOLL_CTL_ADD, wakeFd, &ev) == 0;
}

void IoReactor::Impl::wake() {
    uint64_t one = 1;
    while (::write(wakeFd, &one, sizeof(one)) < 0 && errno == EINTR) {
    }
    // EAGAIN: the counter is saturated, so the reactor is woken anyway.
}

void IoReactor::Impl::resetWake() {
    uint64_t v;
    while (::read(wakeFd, &v, sizeof(v)) < 0 && errno == EINTR) {
    }
}

bool IoReactor::Impl::backendWait(int64_t timeoutMs) {
    struct epoll_event evs[kMaxEvents];
    int t = timeoutMs < 0 ? -1 : (timeoutMs > INT_MAX ? INT_MAX : static_cast<int>(timeoutMs));
    int n = ::epoll_wait(pollFd, evs, kMaxEvents, t);
    batch.clear();
    if (n <= 0) return false;   // timeout, or EINTR (the next iteration retries)
    bool sawWake = false;
    for (int i = 0; i < n; ++i) {
        uint64_t key = evs[i].data.u64;
        uint32_t f = evs[i].events;
        if (key == kWakeKey) {
            sawWake = true;
            continue;
        }
        batch.push_back(Ev{key, (f & EPOLLIN) != 0, (f & EPOLLOUT) != 0,
                           (f & (EPOLLERR | EPOLLHUP | EPOLLRDHUP)) != 0});
    }
    return sawWake;
}

int IoReactor::Impl::backendCtl(Slot& s, uint64_t key, bool r, bool w) {
    bool inKernel = s.wantR || s.wantW;
    if (!r && !w) {
        // Rule 1: no interest -> not in the kernel set. ENOENT/EBADF mean it
        // is not there either.
        if (inKernel) (void)::epoll_ctl(pollFd, EPOLL_CTL_DEL, s.fd, nullptr);
        s.wantR = s.wantW = false;
        return 0;
    }
    struct epoll_event ev;
    std::memset(&ev, 0, sizeof(ev));
    ev.events = (r ? EPOLLIN : 0u) | (w ? EPOLLOUT : 0u);
    ev.data.u64 = key;
    int op = inKernel ? EPOLL_CTL_MOD : EPOLL_CTL_ADD;
    if (::epoll_ctl(pollFd, op, s.fd, &ev) < 0) {
        int e = errno;
        int alt = (e == ENOENT && op == EPOLL_CTL_MOD) ? EPOLL_CTL_ADD
                  : (e == EEXIST && op == EPOLL_CTL_ADD) ? EPOLL_CTL_MOD
                                                         : -1;
        if (alt < 0 || ::epoll_ctl(pollFd, alt, s.fd, &ev) < 0) return alt < 0 ? e : errno;
    }
    s.wantR = r;
    s.wantW = w;
    return 0;
}

#elif defined(ECO_IOR_KQUEUE)

namespace {
constexpr uintptr_t kWakeIdent = 1;   // EVFILT_USER ident
inline void* keyData(uint64_t key) { return reinterpret_cast<void*>(static_cast<uintptr_t>(key)); }
} // namespace

bool IoReactor::Impl::backendInit() {
    pollFd = ::kqueue();
    if (pollFd < 0) return false;
    int fl = ::fcntl(pollFd, F_GETFD);
    if (fl >= 0) (void)::fcntl(pollFd, F_SETFD, fl | FD_CLOEXEC);
    struct kevent kev;
    // EV_CLEAR: retrieving the event resets it (rule 4).
    EV_SET(&kev, kWakeIdent, EVFILT_USER, EV_ADD | EV_CLEAR, 0, 0, keyData(kWakeKey));
    return ::kevent(pollFd, &kev, 1, nullptr, 0, nullptr) == 0;
}

void IoReactor::Impl::wake() {
    struct kevent kev;
    EV_SET(&kev, kWakeIdent, EVFILT_USER, 0, NOTE_TRIGGER, 0, keyData(kWakeKey));
    while (::kevent(pollFd, &kev, 1, nullptr, 0, nullptr) < 0 && errno == EINTR) {
    }
}

void IoReactor::Impl::resetWake() {}   // EV_CLEAR did it when the event was retrieved

bool IoReactor::Impl::backendWait(int64_t timeoutMs) {
    struct kevent evs[kMaxEvents];
    struct timespec ts;
    struct timespec* tsp = nullptr;
    if (timeoutMs >= 0) {
        ts.tv_sec = static_cast<time_t>(timeoutMs / 1000);
        ts.tv_nsec = static_cast<long>((timeoutMs % 1000) * 1000000);
        tsp = &ts;
    }
    int n = ::kevent(pollFd, nullptr, 0, evs, kMaxEvents, tsp);
    batch.clear();
    if (n <= 0) return false;   // timeout, or EINTR
    bool sawWake = false;
    for (int i = 0; i < n; ++i) {
        if (evs[i].filter == EVFILT_USER) {
            sawWake = true;
            continue;
        }
        uint64_t key = static_cast<uint64_t>(reinterpret_cast<uintptr_t>(evs[i].udata));
        bool hup = (evs[i].flags & (EV_EOF | EV_ERROR)) != 0;
        batch.push_back(Ev{key, evs[i].filter == EVFILT_READ, evs[i].filter == EVFILT_WRITE, hup});
    }
    return sawWake;
}

int IoReactor::Impl::backendCtl(Slot& s, uint64_t key, bool r, bool w) {
    // One kevent call per filter, so a failure leaves a known state.
    auto change = [&](int16_t filter, bool want, bool& have) -> int {
        if (want == have) return 0;
        struct kevent kev;
        EV_SET(&kev, static_cast<uintptr_t>(s.fd), filter, want ? (EV_ADD | EV_ENABLE) : EV_DELETE, 0, 0,
               keyData(key));
        if (::kevent(pollFd, &kev, 1, nullptr, 0, nullptr) < 0) {
            int e = errno;
            if (!want && (e == ENOENT || e == EBADF)) {   // not registered: already deleted
                have = false;
                return 0;
            }
            return e;
        }
        have = want;
        return 0;
    };
    int e = change(EVFILT_READ, r, s.wantR);
    if (e != 0) return e;
    return change(EVFILT_WRITE, w, s.wantW);
}

#else // ECO_IOR_STUB

bool IoReactor::Impl::backendInit() { return false; }
void IoReactor::Impl::wake() {}
void IoReactor::Impl::resetWake() {}
bool IoReactor::Impl::backendWait(int64_t) {
    batch.clear();
    return false;
}
int IoReactor::Impl::backendCtl(Slot&, uint64_t, bool, bool) { return ENOTSUP; }

#endif

// ---------------------------------------------------------------------------
// IoReactor
// ---------------------------------------------------------------------------

IoReactor& IoReactor::instance() {
    static IoReactor* r = new IoReactor();   // leaky (§3.4)
    return *r;
}

IoReactor::IoReactor() : impl_(new Impl()) {
#if !defined(ECO_IOR_STUB)
    if (!impl_->backendInit()) {
        int e = errno;
        std::fprintf(stderr, "[eco-system] IoReactor: cannot create the event loop (%s); socket IO is unavailable\n",
                     std::strerror(e));
        std::fflush(stderr);
        return;
    }
    impl_->ok = true;
    try {
        std::thread([this] {
            t_onReactor = true;
            for (;;) runOnce(-1);
        }).detach();
    } catch (...) {
        impl_->ok = false;
        std::fprintf(stderr, "[eco-system] IoReactor: cannot start the reactor thread; socket IO is unavailable\n");
        std::fflush(stderr);
    }
#endif
}

void IoReactor::submit(std::function<void()> fn) {
    if (!impl_->ok || !fn) return;   // Windows stub / no event loop: dropped
    {
        std::lock_guard<std::mutex> lk(impl_->cmdMu);
        impl_->cmds.push_back(std::move(fn));
    }
    impl_->wake();   // after the push, outside the mutex (rule 4)
}

uint64_t IoReactor::add(std::shared_ptr<IoHandler> h, int fd) {
    ECO_IOR_REACTOR_ONLY();
    if (!h || h->key_ != 0) return 0;
    Impl& m = *impl_;
    uint32_t idx;
    if (!m.freeSlots.empty()) {
        idx = m.freeSlots.back();
        m.freeSlots.pop_back();
    } else {
        idx = static_cast<uint32_t>(m.slots.size());
        m.slots.emplace_back();
    }
    Impl::Slot& s = m.slots[idx];
    s.live = true;
    s.fd = fd;
    s.wantR = s.wantW = false;
    s.timerDeadline = 0;
    s.timerSeq = 0;
    uint64_t key = makeKey(idx, s.gen);
    h->key_ = key;
    s.h = std::move(h);
    return key;
}

int IoReactor::setInterest(uint64_t key, bool read, bool write) {
    ECO_IOR_REACTOR_ONLY();
    Impl::Slot* s = impl_->live(key);
    if (!s || s->fd < 0) return 0;
    if (s->wantR == read && s->wantW == write) return 0;
    return impl_->backendCtl(*s, key, read, write);
}

void IoReactor::setTimer(uint64_t key, int64_t deadlineMonoMs) {
    ECO_IOR_REACTOR_ONLY();
    Impl& m = *impl_;
    Impl::Slot* s = m.live(key);
    if (!s) return;
    if (s->timerDeadline != 0) --m.liveTimers;
    s->timerDeadline = deadlineMonoMs;
    if (deadlineMonoMs != 0) {
        s->timerSeq = ++m.timerSeq;
        m.timers.push(Impl::TimerEntry{deadlineMonoMs, s->timerSeq, key});
        ++m.liveTimers;
    }
    m.maybeCompactTimers();
}

void IoReactor::remove(uint64_t key) {
    ECO_IOR_REACTOR_ONLY();
    Impl& m = *impl_;
    Impl::Slot* s = m.live(key);
    if (!s) return;
    if (s->fd >= 0 && (s->wantR || s->wantW)) (void)m.backendCtl(*s, key, false, false);
    if (s->timerDeadline != 0) {
        --m.liveTimers;
        s->timerDeadline = 0;
    }
    s->live = false;
    s->wantR = s->wantW = false;
    s->fd = -1;
    s->gen = s->gen + 1;
    if (s->gen == 0) s->gen = 1;
    std::shared_ptr<IoHandler> h = std::move(s->h);
    s->h.reset();
    m.freeSlots.push_back(slotOf(key));
    if (h) h->key_ = 0;
    // `h` may be the last reference: the handler is destroyed here, after the
    // slot table is consistent again.
}

void IoReactor::runOnce(int64_t timeoutMs) {
    ECO_IOR_REACTOR_ONLY();
    Impl& m = *impl_;
    m.iterations.fetch_add(1, std::memory_order_relaxed);
    m.checkQuiesce();
    int64_t t = m.nextTimeout(nowMs());
    if (timeoutMs >= 0 && (t < 0 || timeoutMs < t)) t = timeoutMs;
    bool sawWake = m.backendWait(t);
    if (sawWake) m.resetWake();   // before draining commands (rule 4)
    m.fireTimers(nowMs());
    std::vector<Ev> evs;
    evs.swap(m.batch);
    for (const Ev& ev : evs) m.dispatchEvent(ev.key, ev.r, ev.w, ev.e);
    evs.clear();
    if (m.batch.empty()) m.batch.swap(evs);   // keep the capacity
    m.drainCommands();
}

void IoReactor::injectEventForTest(uint64_t key, bool readable, bool writable, bool errorOrHangup) {
    ECO_IOR_REACTOR_ONLY();
    impl_->dispatchEvent(key, readable, writable, errorOrHangup);
}

uint64_t IoReactor::loopIterations() const {
    return impl_->iterations.load(std::memory_order_relaxed);
}

void IoReactor::closeAll() {
    Impl& m = *impl_;
    if (!m.ok || m.quiesceRequested.load(std::memory_order_acquire)) return;
    if (onReactorThread()) {
        m.closeAllNow();
        return;
    }
    struct Done {
        std::mutex mu;
        std::condition_variable cv;
        bool done = false;
    };
    auto st = std::make_shared<Done>();
    Impl* mp = impl_;
    submit([mp, st] {
        mp->closeAllNow();
        {
            std::lock_guard<std::mutex> lk(st->mu);
            st->done = true;
        }
        st->cv.notify_all();
    });
    std::unique_lock<std::mutex> lk(st->mu);
    while (!st->done) {
        st->cv.wait_for(lk, std::chrono::milliseconds(50));
        // A quiesced reactor never runs the command: do not hang.
        if (!st->done && m.quiesceRequested.load(std::memory_order_acquire)) return;
    }
}

bool IoReactor::quiesce(int64_t timeoutMs) {
    Impl& m = *impl_;
    if (!m.ok) return true;
    m.quiesceRequested.store(true, std::memory_order_release);
    if (onReactorThread()) return true;   // nothing more is dispatched after this handler
    m.wake();
    std::unique_lock<std::mutex> lk(m.qMu);
    return m.qCv.wait_for(lk, std::chrono::milliseconds(timeoutMs < 0 ? 0 : timeoutMs),
                          [&] { return m.quiesceAck; });
}

} // namespace Eco::System
