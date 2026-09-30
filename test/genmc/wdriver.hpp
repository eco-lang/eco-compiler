// Common header of the weak-memory drivers W1-W5
// (plans/threaded-gc-tla-W-weak-memory.md §3; test/genmc/AUDIT.md).
//
// INCLUDE IT LAST, after the allocator headers: it redefines assert (below),
// and each <cassert> a header includes would reset it.
//
// Each driver is a small concurrent program over the REAL std-only allocator
// headers (MarkWork.hpp, MinorWork.hpp, TenureWork.hpp, BitmapScan.hpp) or over
// a pinned reduction of OldGenSpace code (W4).
//
// Under the checker (run_drivers.py, -DWDRIVER_GENMC): the driver is compiled
// to LLVM IR by the clang of GenMC's LLVM (19) with the ORDINARY system headers
// (glibc, libstdc++ 12), as the runtime is, and the IR is handed to GenMC.
// GenMC's own C headers are not used: they replace <pthread.h>, <stdlib.h> and
// <stdio.h> for C programs, and libstdc++'s C++20 <atomic> cannot compile
// against them. GenMC intercepts only its __VERIFIER_* functions (plus
// operator new / delete), so threads, the mutex, assume and assert are routed
// to those here. Without WDRIVER_GENMC the driver is an ordinary pthreads
// program (syntax checks, native smoke runs).
#pragma once
#include <cassert>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <new>

#if defined(WDRIVER_GENMC)
#include <genmc_internal.h>   // -idirafter <genmc>/include/genmc/runtime

// A pruned execution (the condition is false) is not an error: the checker's
// form of a wait loop, with the wait's condition kept.
#define VERIFIER_ASSUME(c) __VERIFIER_assume_internal(static_cast<bool>(c), GENMC_ASSUME_USER)
// A wait loop's pause (e.g. waitPublished's) that prunes the spin: the REAL
// wait loop runs, and an execution in which it would spin is cut.
inline void prunePause(unsigned) { VERIFIER_ASSUME(false); }

using wthread = __VERIFIER_thread_t;
inline wthread spawn(void* (*f)(void*), void* arg = nullptr) {
    return __VERIFIER_thread_create(nullptr, f, arg);
}
inline void join(wthread t) { (void)__VERIFIER_thread_join(t); }

// A pthread_mutex_t / std::mutex stand-in (GenMC models its mutex as a lock).
// await(pred), called with the mutex held, is `cv.wait(lk, pred)`: an
// assumption under the checker (an execution in which pred is false here is
// pruned; the waiter holds the lock when pred is read, as after a wake-up).
struct WMutex {
    __VERIFIER_mutex_t m = __VERIFIER_MUTEX_INITIALIZER;
    void lock() { __VERIFIER_mutex_lock(&m); }
    void unlock() { __VERIFIER_mutex_unlock(&m); }
    template <class Pred> void await(Pred pred) { VERIFIER_ASSUME(pred()); }
};

// The drivers' asserts fail AT THEIR OWN LINE: GenMC 0.19 loses the assertion
// text (GenMCDriver::handleError moves the message into the error label before
// reporting it), so run_drivers.py identifies a failed assertion by the ERROR
// event's file:line and reads the expression from the source.
#undef assert
#define assert(e) \
    (static_cast<bool>(e) ? static_cast<void>(0) : __VERIFIER_assert_fail(#e, __FILE__, __LINE__))

// An assert inside an allocator header uses glibc's macro, which calls
// __assert_fail: report it too (its location is this line; the runner names it
// "a header assertion").
extern "C" void __assert_fail(const char* expr, const char* file, unsigned int line,
                              const char*) noexcept {
    __VERIFIER_assert_fail(expr, file, static_cast<int>(line));   // header assertion
    __builtin_unreachable();
}

// The headers' fatal paths name glibc's stderr (fprintf(stderr, ...); GenMC
// turns fprintf into a no-op). An undefined external global crashes GenMC's
// interpreter (a segfault at start-up), so define them for the checker.
FILE* stderr = nullptr;
FILE* stdout = nullptr;

// GenMC intercepts operator new(size_t) and operator delete(void*) by their
// mangled names (_Znwm, _ZdlPv) and nothing else. The deque allocates its
// buffer with new[], and clang 19 emits sized deletes, so route the other
// replaceable forms to those two (defining replacement allocation functions is
// ordinary C++).
void* operator new[](std::size_t n) { return ::operator new(n); }
void operator delete[](void* p) noexcept { ::operator delete(p); }
void operator delete(void* p, std::size_t) noexcept { ::operator delete(p); }
void operator delete[](void* p, std::size_t) noexcept { ::operator delete(p); }

#else  // native build
#include <pthread.h>
#include <sched.h>

// Natively an assumption is a wait: the condition is re-evaluated until it
// holds (for try_lock() that is lock()).
#define VERIFIER_ASSUME(c) \
    do { while (!(c)) sched_yield(); } while (false)
inline void prunePause(unsigned) { sched_yield(); }

using wthread = pthread_t;
inline wthread spawn(void* (*f)(void*), void* arg = nullptr) {
    pthread_t t;
    pthread_create(&t, nullptr, f, arg);
    return t;
}
inline void join(wthread t) { pthread_join(t, nullptr); }

struct WMutex {
    pthread_mutex_t m = PTHREAD_MUTEX_INITIALIZER;
    void lock() { pthread_mutex_lock(&m); }
    void unlock() { pthread_mutex_unlock(&m); }
    // cv.wait(lk, pred): release the lock while waiting (a native assumption
    // under a held lock would deadlock).
    template <class Pred> void await(Pred pred) {
        while (!pred()) { unlock(); sched_yield(); lock(); }
    }
};
#endif

inline void* argOf(intptr_t i) { return reinterpret_cast<void*>(i); }
inline int intOf(void* p) { return static_cast<int>(reinterpret_cast<intptr_t>(p)); }
