// How the embedding API starts a program on its own thread and stops it again.
//
// The eco thread is started much as `main()` in `codegen/eco_entry.cpp` starts a standalone program, without
// the parts that belong to a process rather than a program: no signal handlers and no statistics printed at
// exit, since those are the host's. Three things differ because the program is a guest in someone else's
// process.
//
// First, the collector finds stack roots through the stack map section of the compiled code, and that code
// may be in a shared object rather than the executable. So the section is looked up in whichever loaded
// module contains `eco_main`.
//
// Second, the runtime's singletons must be constructed on the eco thread. `PlatformRuntime` and `Scheduler`
// register their GC roots, from their constructors, with the root set of the thread that constructs them,
// and only the eco thread's root set is scanned when it collects. So the host-thread functions here record
// the flags and the idle hook in `EmbedState` for the eco thread to apply, and `eco_app_stop`, the one that
// uses `Scheduler`, returns before start and relies on the header's rule that it is not called while
// `eco_app_start` is in progress.
//
// Third, an embedded program must not finish just because it has nothing to do while it waits for the host.
// The eco thread takes a Host hold on the scheduler before it runs the program, and `eco_app_stop` releases
// it. `eco_app_start` waits on a handshake that the program's ready hook posts, or the thread posts as it
// finishes, whichever comes first.

#include "eco_embed.h"

#include "../allocator/Allocator.hpp"
#include "../allocator/RuntimeExports.h"
#include "../allocator/StackMap.hpp"
#include "../platform/PlatformRuntime.hpp"
#include "../platform/PortRuntime.hpp"
#include "../platform/Scheduler.hpp"

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <process.h>   // _beginthreadex
#else
#include <pthread.h>
#endif
#include <vector>

#include "../platform/StackMapSection.hpp"

// The stack size of the eco thread in bytes, 64 MiB, the same as `eco_entry.cpp` gives its program thread:
// deeply recursive Elm code, such as a JSON decoder, overflows a typical default thread stack.
static constexpr size_t ECO_EMBED_STACK_SIZE = 64ULL * 1024 * 1024;

// The Host hold that keeps the event loop from returning while the program waits for the host, or
// `kNoHold` when none is held. The eco thread stores it before running the program; `eco_app_stop` takes it,
// on whatever thread calls it, and releases it.
static std::atomic<Elm::Platform::HoldToken> g_lifetime{Elm::Platform::kNoHold};

extern "C" {
// Initializes the program's global values. Generated with the program only when it needs it, so it is
// declared weak and is null when absent.
__attribute__((weak)) void __eco_init_globals();
// Runs the compiled program's `main` and returns the Elm value it produces, not an exit status.
int64_t eco_main();
// Registers every effect manager linked into the program with `PlatformRuntime`.
void eco_register_all_effect_managers();
// Registers the GC roots kept by the Eco kernel libraries.
void Eco_Kernel_register_all_gc_roots();
}  // extern "C"

namespace Eco::Kernel::Env {
// Records `argc` and `argv` as the program's command line. `argv` is kept and read later, while the program
// runs.
void init(int argc, char** argv);
}

namespace {

// Parses the stack map section of the loaded module, executable or shared object, whose image contains
// `addr` into the global stack map. If that section is not found, prints a warning to `stderr` and parses
// nothing, and the collector will then find no stack roots in that code.
void initStackMapForModuleContaining(void* addr) {
    auto sec = eco::platform::findStackMapSection(addr);

    if (sec.data && sec.size > 0) {
        // The loader has relocated the section, so its addresses are already absolute.
        (void)Elm::globalStackMap().parse(sec.data, sec.size, /*loadBase=*/0);
    } else {
        std::fprintf(stderr,
                     "eco embed: warning: .llvm_stackmaps not found for the "
                     "module containing eco_main; GC stack roots will be "
                     "missing\n");
    }
}

/**
 * The state of the one embedded program a process may run, shared by the host-thread functions and the eco
 * thread.
 *
 * `started` and `stopped` each change once, from false to true, and are never reset. `exitCode` is meaningful
 * once the eco thread has finished. `argc`, `argv` and the flags are written by `eco_app_start` before it
 * creates the thread. The idle hook must be set before `eco_app_start` and not changed after, since the eco
 * thread reads it on every activity change.
 */
struct EmbedState {
    std::atomic<bool> started{false};
#if defined(_WIN32)
    HANDLE thread = nullptr;
    DWORD threadId = 0;
#else
    pthread_t thread{};
#endif
    // Whether `thread` names a thread that has been created and not yet waited for.
    std::atomic<bool> threadValid{false};
    std::atomic<int> exitCode{0};
    std::atomic<bool> stopped{false};

    // The start handshake. `ready` is set, under `readyMutex`, by the program's ready hook or as the eco
    // thread finishes, whichever comes first.
    std::mutex readyMutex;
    std::condition_variable readyCV;
    bool ready = false;

    // Serializes `eco_app_join`: waiting for the same thread from two callers at once is undefined behaviour.
    std::mutex joinMutex;

    int argc = 0;
    char** argv = nullptr;

    std::string flagsJson;
    bool hasFlags = false;  // Whether the host gave flags; `flagsJson` is empty and unused otherwise.

    // The hook set by `eco_set_idle_hook`, or null for none.
    void (*idleHook)(int busy, void* user) = nullptr;
    void* idleHookUser = nullptr;
};

// Returns the process's one `EmbedState`, constructed on first use.
EmbedState& state() {
    static EmbedState s;
    return s;
}

// Passes the scheduler's report of whether the program is busy on to the host's idle hook, as 1 or 0. It is
// installed as the `Scheduler::ActivityHook` only when the host set an idle hook before start.
void schedActivityTrampoline(bool busy, void* /*user*/) {
    auto& s = state();
    if (s.idleHook)
        s.idleHook(busy ? 1 : 0, s.idleHookUser);
}

// Completes the start handshake, releasing an `eco_app_start` waiting for it. Later calls change nothing.
void postReady() {
    auto& s = state();
    {
        std::lock_guard<std::mutex> lk(s.readyMutex);
        s.ready = true;
    }
    s.readyCV.notify_all();
}

// Completes the start handshake; the program's `PlatformRuntime::ReadyHook`.
void readyHookTrampoline(void* /*user*/) { postReady(); }

// Stops the program and waits for the eco thread to finish, when the process exits while it may still be
// running, for example because the host called `exit` without calling `eco_app_stop`. Does not wait when
// called on the eco thread itself.
//
// The eco thread registers it with `atexit` before it first uses the runtime's lazily constructed statics.
// Exit handlers and static destructors run in the reverse order of registration and construction, so this
// runs before the destructors of statics constructed earlier, and the thread is not left running on memory
// they free. Statics constructed later are destroyed before it runs; `Scheduler`, `PlatformRuntime` and
// `PortRuntime` are allocated with `new` and never destroyed, so they are never torn down under it.
void atexitStopEcoThread() {
    eco_app_stop();
    // `exit` may have been called from the eco thread, by the program itself, and a thread cannot wait for
    // itself.
    auto& s = state();
    if (s.threadValid.load()) {
#if defined(_WIN32)
        if (GetCurrentThreadId() == s.threadId) return;
#else
        if (pthread_equal(pthread_self(), s.thread)) return;
#endif
    }
    eco_app_join();
}

// Runs the program on the eco thread: initializes the runtime for this thread, applies what the host
// recorded before start, takes the Host hold, runs `eco_main`, and records the exit code. Completes the start
// handshake as it finishes, in case the ready hook never did.
void* ecoEmbedThread(void* /*arg*/) {
    auto& s = state();

    std::atexit(atexitStopEcoThread);

    Elm::Allocator::instance().initialize();
    Elm::Allocator::instance().initThread();
    Eco_Kernel_register_all_gc_roots();
    initStackMapForModuleContaining(reinterpret_cast<void*>(&eco_main));
    if (__eco_init_globals) __eco_init_globals();
    Eco::Kernel::Env::init(s.argc, s.argv);
    eco_register_all_effect_managers();

    // The first uses of PlatformRuntime and Scheduler, so they are constructed on this thread.
    auto& platform = Elm::Platform::PlatformRuntime::instance();
    platform.setReadyHook(readyHookTrampoline, nullptr);
    if (s.hasFlags) {
        platform.setPendingFlagsJson(s.flagsJson);
    }

    // Taken before eco_main, so the event loop cannot find itself without work and return before the host
    // has had a chance to send anything.
    auto& sched = Elm::Platform::Scheduler::instance();
    sched.setEmbedMode(true);
    g_lifetime.store(sched.acquireHold(Elm::Platform::HoldKind::Host, "eco_embed"));
    if (s.idleHook)
        sched.setActivityHook(schedActivityTrampoline, nullptr);

    // The value eco_main returns is the program's `main`, not an exit status. The exit code is whatever the
    // program recorded with eco_set_exit_code, as in eco_entry.cpp.
    (void)eco_main();

    Elm::Allocator::instance().cleanupThread();
    s.exitCode.store(eco_get_exit_code());

    // For a program that is not a worker, or a worker that returned before its ready hook, this is what
    // releases eco_app_start.
    postReady();
    return nullptr;
}

}  // namespace

// ---- C ABI ----

extern "C" {

int eco_app_start(int argc, char** argv, const char* flags_json) {
    auto& s = state();

    bool expected = false;
    if (!s.started.compare_exchange_strong(expected, true)) {
        return ECO_APP_ERR_ALREADY_STARTED;
    }

    s.argc = argc;
    s.argv = argv;

    // Recorded, not applied: applying them here would construct PlatformRuntime on the host thread.
    if (flags_json != nullptr) {
        s.flagsJson = flags_json;
        s.hasFlags = true;
    }

#if defined(_WIN32)
    struct WinAdapter {
        // Runs `ecoEmbedThread` with the signature `_beginthreadex` expects.
        static unsigned __stdcall run(void* a) {
            ecoEmbedThread(a);
            return 0;
        }
    };
    // _beginthreadex writes the thread id as an `unsigned`, which is the same width as DWORD on Windows.
    unsigned tmpId = 0;
    uintptr_t h = ::_beginthreadex(nullptr, ECO_EMBED_STACK_SIZE,
                                   &WinAdapter::run, nullptr, 0, &tmpId);
    s.threadId = tmpId;
    if (h == 0) {
        return ECO_APP_ERR_THREAD;
    }
    s.thread = reinterpret_cast<HANDLE>(h);
#else
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setstacksize(&attr, ECO_EMBED_STACK_SIZE);
    int rc = pthread_create(&s.thread, &attr, ecoEmbedThread, nullptr);
    pthread_attr_destroy(&attr);
    if (rc != 0) {
        return ECO_APP_ERR_THREAD;
    }
#endif
    s.threadValid.store(true);

    {
        std::unique_lock<std::mutex> lk(s.readyMutex);
        s.readyCV.wait(lk, [&s] { return s.ready; });
    }
    return 0;
}

void eco_app_stop(void) {
    auto& s = state();
    if (!s.started.load()) {
        // Returning here also keeps the Scheduler from being constructed on this thread.
        return;
    }
    bool expected = false;
    if (!s.stopped.compare_exchange_strong(expected, true)) {
        return;
    }
    auto& sched = Elm::Platform::Scheduler::instance();
    sched.requestStop();
    // Releasing the hold also wakes the event loop.
    if (Elm::Platform::HoldToken t = g_lifetime.exchange(Elm::Platform::kNoHold))
        sched.releaseHold(t);
}

int eco_app_join(void) {
    auto& s = state();
    std::lock_guard<std::mutex> lk(s.joinMutex);
    if (!s.threadValid.load()) {
        return s.started.load() ? s.exitCode.load() : -1;
    }
#if defined(_WIN32)
    ::WaitForSingleObject(s.thread, INFINITE);
    ::CloseHandle(s.thread);
    s.thread = nullptr;
#else
    pthread_join(s.thread, nullptr);
#endif
    s.threadValid.store(false);
    return s.exitCode.load();
}

void eco_set_idle_hook(void (*cb)(int busy, void* user), void* user) {
    // Recorded, not applied: applying it here would construct the Scheduler on the host thread.
    auto& s = state();
    s.idleHook = cb;
    s.idleHookUser = user;
}

// ---- Ports -----------------------------------------------------------------
//
// The port functions are also defined, weak, in platform/PortRuntime.cpp, whose comment says why both
// copies exist. These strong copies are the ones a shared-library link can export, because this library's
// symbols are not hidden there and EcoRuntimeStatic's are. They are left out on Windows, where the
// PortRuntime.cpp copies are not weak and two definitions would clash.
#if !defined(_WIN32)

int eco_port_send(const char* port, const char* json_utf8) {
    return Elm::Platform::PortRuntime::instance().sendIncoming(port, json_utf8)
               ? 0
               : 1;
}

int eco_port_subscribe(const char* port, eco_port_callback cb, void* user) {
    return Elm::Platform::PortRuntime::instance().subscribeOutgoing(port, cb,
                                                                    user)
               ? 0
               : 1;
}

int eco_port_unsubscribe(const char* port, eco_port_callback cb, void* user) {
    return Elm::Platform::PortRuntime::instance().unsubscribeOutgoing(port, cb,
                                                                      user)
               ? 0
               : 1;
}

int eco_port_count(void) {
    return Elm::Platform::PortRuntime::instance().portCount();
}

const char* eco_port_name(int i) {
    return Elm::Platform::PortRuntime::instance().portName(i);
}

int eco_port_is_incoming(const char* port) {
    return Elm::Platform::PortRuntime::instance().isIncoming(port);
}

#endif  // !defined(_WIN32)

}  // extern "C"
