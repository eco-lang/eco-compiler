//===- SignalService.cpp - Process signals as POD events ------------------===//
//
// See SignalService.hpp. Leaky singleton with a detached reader thread
// (§3.4). The handler is async-signal-safe: it reads one atomic int and
// calls write(2), preserving errno.
//
// Templates used: none (POD only, G1).
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
#include <signal.h>
#include <unistd.h>
#endif

namespace Eco::System {

namespace {

[[maybe_unused]] bool signalReady() { return SignalService::instance().hasReady(); }

#ifndef _WIN32
// Write end of the self-pipe, read by the handler. Lock-free int.
std::atomic<int> g_sigWriteFd{-1};
static_assert(std::atomic<int>::is_always_lock_free, "handler needs a lock-free fd");

extern "C" void ecoSystemSignalHandler(int signo) {
    int saved = errno;
    int fd = g_sigWriteFd.load(std::memory_order_relaxed);
    if (fd >= 0) {
        unsigned char b = static_cast<unsigned char>(signo);
        ssize_t r;
        do { r = ::write(fd, &b, 1); } while (r < 0 && errno == EINTR);
        // EAGAIN (pipe full): the signal is dropped, as coalesced signals are.
    }
    errno = saved;
}

void readerThread(int rfd) {
    unsigned char buf[64];
    for (;;) {
        ssize_t r = ::read(rfd, buf, sizeof buf);
        if (r < 0) {
            if (errno == EINTR) continue;
            return;   // the pipe is never closed; defensive
        }
        if (r == 0) return;
        for (ssize_t i = 0; i < r; ++i) SignalService::instance().post(buf[i]);
    }
}
#endif

} // namespace

SignalService& SignalService::instance() {
    static SignalService* inst = new SignalService();   // leaky (§3.4)
    return *inst;
}

SignalService::SignalService() {
    // Bound on the constructing (main) thread; the reader thread must never
    // be the first caller of Scheduler::instance().
    sched_ = &Scheduler::instance();
}

void SignalService::post(int signo) {
    {
        std::lock_guard<std::mutex> lk(readyMutex_);
        ready_.push_back(signo);
        readyCount_.fetch_add(1, std::memory_order_acq_rel);
    }
    // Outside readyMutex_ (the Scheduler reads hasReady() under its mutex).
    sched_->notifyWorkAvailableFromAsync();
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

#else

bool SignalService::ensureStarted() {
    if (started_) return true;
    int fds[2] = {-1, -1};
    if (makeCloexecPipe(fds, /*nonBlocking=*/false) != 0) return false;
    // The handler must never block: only the write end is non-blocking.
    int fl = ::fcntl(fds[1], F_GETFL);
    if (fl < 0 || ::fcntl(fds[1], F_SETFL, fl | O_NONBLOCK) < 0) {
        ::close(fds[0]);
        ::close(fds[1]);
        return false;
    }
    try {
        std::thread(readerThread, fds[0]).detach();
    } catch (...) {
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
    if (sched_->embedMode()) return false;   // the host owns signals (§3.7)
    if (signo <= 0 || signo >= kMaxSig || signo >= NSIG) return false;
    if (signo == SIGKILL || signo == SIGSTOP) return false;
    if (counts_[signo] > 0) {
        ++counts_[signo];
        return true;
    }
    if (!ensureStarted()) return false;

    auto* old = static_cast<struct sigaction*>(saved_[signo]);
    if (!old) {
        old = new struct sigaction();   // leaky, one per signal ever used
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

void signalDrain() {
    auto& svc = SignalService::instance();
    int signo;
    while (svc.tryPop(signo)) {
        SignalService::DispatchFn fn = svc.dispatch();
        if (!fn) continue;
        try {
            fn(signo);
        } catch (const std::exception& e) {
            ::Eco::Kernel::reportFatal(e.what());   // never unwind into the loop (F21)
        } catch (...) {
            ::Eco::Kernel::reportFatal("unknown native exception in signal dispatch");
        }
    }
}

} // namespace Eco::System
