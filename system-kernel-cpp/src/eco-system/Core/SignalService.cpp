//===- SignalService.cpp - Process signals as POD events ------------------===//
//
// The handler is async-signal-safe: it loads one lock-free atomic int and calls write(2), preserving errno. It runs on
// whichever thread the kernel picks among those not blocking the signal.
//
// Why a signal is never lost to the loop going quiescent: the loop's readiness check (`pollReady`) reads the pipe
// itself instead of relying on the reader thread having run, and the reader holds `pipeMutex_` from each read until
// its bytes are queued. So, as seen by anyone who takes `pipeMutex_`, a byte the handler wrote is in the pipe or in
// `ready_` until it is popped.
//
//===----------------------------------------------------------------------===//

#include "eco-system/Core/SignalService.hpp"
#include "eco-system/Core/AsyncSources.hpp"
#include "eco-system/Core/FdChannel.hpp"   // makeCloexecPipe

#include <cerrno>
#include <thread>

#ifndef _WIN32
#include <csignal>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <time.h>
#include <unistd.h>
#endif

namespace Eco::System {

namespace {

// Returns whether the signal drain has work, queuing any signal already received; the drain source's predicate.
[[maybe_unused]] bool signalReady() { return SignalService::instance().pollReady(); }

#ifndef _WIN32
// The write end of the self-pipe, or -1 before it exists. The handler reads it, so it must be a lock-free atomic.
std::atomic<int> g_sigWriteFd{-1};
static_assert(std::atomic<int>::is_always_lock_free, "handler needs a lock-free fd");

// Writes `signo` as one byte to the self-pipe, if it exists. A byte that finds the pipe full (EAGAIN) is dropped.
extern "C" void ecoSystemSignalHandler(int signo) {
    int saved = errno;
    int fd = g_sigWriteFd.load(std::memory_order_relaxed);
    if (fd >= 0) {
        unsigned char b = static_cast<unsigned char>(signo);
        ssize_t r;
        do { r = ::write(fd, &b, 1); } while (r < 0 && errno == EINTR);
    }
    errno = saved;
}

// Runs the reader thread: waits for the read end `rfd` to become readable, moves its bytes into the queue and wakes
// `sched`, for as long as poll succeeds. The eco thread may have taken the bytes first in `pollReady`; then there is
// nothing to queue and no wake-up. The thread returns on a poll error other than EINTR, or on POLLERR or POLLNVAL.
void readerThread(int rfd, Scheduler* sched) {
    for (;;) {
        struct pollfd p {};
        p.fd = rfd;
        p.events = POLLIN;
        int r = ::poll(&p, 1, -1);
        if (r < 0) {
            if (errno == EINTR) continue;
            return;
        }
        if (p.revents & (POLLERR | POLLNVAL)) return;   // the pipe is never closed
        if (SignalService::instance().takeFromPipe()) {
            // Notified outside pipeMutex_ and readyMutex_: the scheduler calls pollReady() with its own lock held.
            sched->notifyWorkAvailableFromAsync();
        }
    }
}
#endif

} // namespace

SignalService& SignalService::instance() {
    // Never destroyed, so the detached reader thread can use it after exit begins.
    static SignalService* inst = new SignalService();
    return *inst;
}

SignalService::SignalService() {
    // Bound on the constructing thread, which must be the eco thread; the reader thread must never be the first
    // caller of Scheduler::instance().
    sched_ = &Scheduler::instance();
}

void SignalService::queue(int signo) {
    std::lock_guard<std::mutex> lk(readyMutex_);
    ready_.push_back(signo);
    readyCount_.fetch_add(1, std::memory_order_acq_rel);
}

bool SignalService::pollReady() {
    if (hasReady()) return true;
    if (!started_) return false;
    // Dequeue pending signals first: one whose handler runs instead (on
    // this thread, at the return of a syscall) has written the pipe by the
    // time we read it.
    takePending();
    takeFromPipe();
    return hasReady();
}

bool SignalService::tryPop(int& signo) {
    std::lock_guard<std::mutex> lk(readyMutex_);
    if (ready_.empty()) return false;
    signo = ready_.front();
    ready_.pop_front();
    readyCount_.fetch_sub(1, std::memory_order_acq_rel);
    return true;
}

int SignalService::subscribers(int signo) const {
    if (signo <= 0 || signo >= kMaxSig) return 0;
    return counts_[signo];
}

#ifdef _WIN32

bool SignalService::ensureStarted() { return false; }
bool SignalService::subscribe(int) { return false; }
void SignalService::unsubscribe(int) {}
bool SignalService::takeFromPipe() { return false; }
void SignalService::takePending() {}

#else

bool SignalService::takeFromPipe() {
    std::lock_guard<std::mutex> lk(pipeMutex_);
    bool any = false;
    unsigned char buf[64];
    for (;;) {
        ssize_t r = ::read(readFd_, buf, sizeof buf);
        if (r < 0) {
            if (errno == EINTR) continue;
            break;   // EAGAIN: empty
        }
        if (r == 0) break;
        for (ssize_t i = 0; i < r; ++i) queue(buf[i]);
        any = true;
    }
    return any;
}

void SignalService::takePending() {
#if defined(__linux__)
    // A subscribed signal pending for the process (or this thread) whose
    // handler has not run yet: take it here, as the handler would have.
    // sigtimedwait dequeues atomically, so the handler and this call never
    // both see one instance. Elsewhere (no sigtimedwait, e.g. macOS) the
    // handler's own pipe write is the only path.
    sigset_t set;
    sigemptyset(&set);
    bool any = false;
    for (int s = 1; s < kMaxSig && s < NSIG; ++s) {
        if (counts_[s] > 0) {
            sigaddset(&set, s);
            any = true;
        }
    }
    if (!any) return;
    struct timespec zero {};
    for (;;) {
        int s = ::sigtimedwait(&set, nullptr, &zero);
        if (s > 0) {
            queue(s);
            continue;
        }
        if (s < 0 && errno == EINTR) continue;
        break;   // EAGAIN: none pending
    }
#endif
}

bool SignalService::ensureStarted() {
    if (started_) return true;
    int fds[2] = {-1, -1};
    // Both ends non-blocking: the handler must never block, and the read end is read by two threads (the reader
    // after poll, the eco thread in pollReady), so a read may find it already empty.
    if (makeCloexecPipe(fds, /*nonBlocking=*/true) != 0) return false;
    readFd_ = fds[0];
    try {
        std::thread(readerThread, fds[0], sched_).detach();
    } catch (...) {
        readFd_ = -1;
        ::close(fds[0]);
        ::close(fds[1]);
        return false;
    }
    g_sigWriteFd.store(fds[1], std::memory_order_release);
    addDrainSource(&signalDrain, &signalReady);
    started_ = true;
    return true;
}

bool SignalService::subscribe(int signo) {
    if (sched_->embedMode()) return false;   // the host owns signals
    if (signo <= 0 || signo >= kMaxSig || signo >= NSIG) return false;
    if (signo == SIGKILL || signo == SIGSTOP) return false;
    if (counts_[signo] > 0) {
        ++counts_[signo];
        return true;
    }
    if (!ensureStarted()) return false;

    auto* old = static_cast<struct sigaction*>(saved_[signo]);
    if (!old) {
        old = new struct sigaction();   // never freed; one per signal ever subscribed
        saved_[signo] = old;
    }
    struct sigaction sa {};
    sa.sa_handler = &ecoSystemSignalHandler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = SA_RESTART;
    if (::sigaction(signo, &sa, old) != 0) return false;
    counts_[signo] = 1;
    return true;
}

void SignalService::unsubscribe(int signo) {
    if (signo <= 0 || signo >= kMaxSig) return;
    if (counts_[signo] == 0) return;   // unmatched (e.g. an embed-mode no-op)
    if (--counts_[signo] > 0) return;
    auto* old = static_cast<struct sigaction*>(saved_[signo]);
    if (old) ::sigaction(signo, old, nullptr);   // restore the previous disposition
}

#endif // _WIN32

// ---------------------------------------------------------------------------
// Listeners (eco thread)
// ---------------------------------------------------------------------------

SignalService::ListenerId SignalService::addListener(int signo, Listener fn, void* ctx) {
    if (!fn) return 0;
    if (!subscribe(signo)) return 0;
    ListenerId id = nextListenerId_++;
    listeners_.push_back(ListenerRec{id, signo, fn, ctx});
    return id;
}

void SignalService::removeListener(ListenerId id) {
    if (id == 0) return;
    for (auto it = listeners_.begin(); it != listeners_.end(); ++it) {
        if (it->id == id) {
            int signo = it->signo;
            listeners_.erase(it);
            unsubscribe(signo);
            return;
        }
    }
}

int SignalService::listenerCount(int signo) const {
    int n = 0;
    for (const auto& l : listeners_)
        if (l.signo == signo) ++n;
    return n;
}

void SignalService::dispatch(int signo) {
    // A snapshot, because a listener may add or remove listeners; each entry is rechecked against the live list
    // before it is called.
    std::vector<ListenerRec> snap;
    for (const auto& l : listeners_)
        if (l.signo == signo) snap.push_back(l);
    for (const auto& l : snap) {
        bool live = false;
        for (const auto& cur : listeners_) {
            if (cur.id == l.id) { live = true; break; }
        }
        if (live) l.fn(signo, l.ctx);
    }
}

#ifdef _WIN32
void SignalService::chainToPrevious(int) {}
#else
void SignalService::chainToPrevious(int signo) {
    if (signo <= 0 || signo >= kMaxSig || counts_[signo] == 0) return;
    auto* old = static_cast<struct sigaction*>(saved_[signo]);
    if (!old) return;
    struct sigaction ours {};
    if (::sigaction(signo, old, &ours) != 0) return;
    ::raise(signo);   // synchronous on this thread; default action may end the process
    ::sigaction(signo, &ours, nullptr);   // survived: listen again
}
#endif

void signalDrain() {
    auto& svc = SignalService::instance();
    int signo;
    while (svc.tryPop(signo)) {
        try {
            svc.dispatch(signo);
        } catch (const std::exception& e) {
            ::Eco::Kernel::reportFatal(e.what());   // never unwind into the scheduler loop
        } catch (...) {
            ::Eco::Kernel::reportFatal("unknown native exception in signal dispatch");
        }
    }
}

} // namespace Eco::System
