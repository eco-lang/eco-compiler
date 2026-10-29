//===- eco_entry.cpp - Entry point wrapper for AOT-compiled binaries ------===//
//
// A compiled Elm program is a library of functions with no C `main` of its own,
// so an executable needs this file to start the runtime and then run the
// program.
//
// The code generators rename the Elm module's `main` function to `eco_main`, so
// that the C `main` defined here can exist beside it. This `main` starts a
// thread with a stack of `ECO_DEFAULT_STACK_SIZE` and waits for it. That thread
// becomes the process's one mutator, the thread that runs Elm code and
// allocates (`Elm::Allocator` states the one-mutator rule). On it,
// `eco_main_thread` sets up the heap, its roots and the effect managers in
// order, then calls `eco_main`. The process exits with the code the program
// recorded through `eco_set_exit_code`, not with what `eco_main` returns.
//
// Executables only: a shared-library build is started by its host through the
// embedding API in `embed/eco_embed.h` instead, and does not link this file.
//
// The rest of the file, compiled only with `ENABLE_GC_STATS`, prints the
// collector's statistics once when the process ends: at a normal exit through
// an `atexit` handler, and on a fatal or terminating signal through a handler
// that then re-raises it.
//
//===----------------------------------------------------------------------===//

#include "../allocator/P1Census.hpp"
#include "../allocator/Allocator.hpp"
#include "../allocator/StackMap.hpp"
#include "../allocator/GCStats.hpp"
#include "../allocator/RuntimeExports.h"
#include "../platform/StackMapSection.hpp"
#include "../../eco-kernel-cpp/src/eco-kernel/Env.hpp"

#include <cstdlib>
#include <cstdio>
#include <cstring>
#include <atomic>
#include <csignal>
#include <iostream>

#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <process.h>   // _beginthreadex
#include <io.h>        // _write, _fileno
// Windows has no SIGBUS, SIGQUIT or SIGPIPE. The statistics handlers use the
// CRT's `signal` for the six signals it has, and a console control handler for
// Ctrl+C, Ctrl+Break, console close, logoff and shutdown.
#else
#include <pthread.h>
#include <unistd.h>
#endif

// The stack size, in bytes (64 MiB), of the thread that runs the Elm program.
//
// Compiled Elm code recurses deeply; the Elm compiler compiling itself can
// exhaust a typical 8 MiB default stack.
static constexpr size_t ECO_DEFAULT_STACK_SIZE = 64ULL * 1024 * 1024;

// Fills `Elm::globalStackMap()` from the stack map section of this
// executable, which the collector needs to find roots in Elm frames.
//
// The section is found by `eco::platform::findStackMapSection`. Its addresses
// are already the ones the code runs at, so it is parsed with a load base of 0.
// A missing section, or one that fails to parse, is not reported except in
// `ECO_GC_DEBUG` builds; the map is then left as it was or emptied.
static void initStackMapFromSelf() {
    auto sec = eco::platform::findStackMapSection(/*addr=*/nullptr);

    if (sec.data && sec.size > 0) {
        bool ok = Elm::globalStackMap().parse(sec.data, sec.size, /*loadBase=*/0);
#if ECO_GC_DEBUG
        fprintf(stderr, "[init] stackmap: data=%p size=%zu parsed=%d hasRecords=%d\n",
                (void*)sec.data, sec.size, (int)ok,
                (int)Elm::globalStackMap().hasRecords());
#endif
        (void)ok;
    } else {
#if ECO_GC_DEBUG
        fprintf(stderr, "[init] stackmap: NOT FOUND (data=%p size=%zu)\n",
                (void*)sec.data, sec.size);
#endif
    }
}

extern "C" {

// Registers the program's module-level globals as GC roots. It is generated
// code, and a program with no globals and no type graph has none.
//
// Outside Windows the declaration is weak, so the address is null when no
// definition is linked. On Windows it is an ordinary declaration, which the
// link must resolve.
#if defined(_WIN32)
void __eco_init_globals();
#else
__attribute__((weak)) void __eco_init_globals();
#endif

// Runs the Elm program: the generated module's `main` function, renamed
// `eco_main` by the code generator.
//
// It returns the Elm `main` value as an `!eco.value` word, not an exit
// status. A program that exits through the kernel's process exit calls
// `exit` and never returns.
int64_t eco_main();

// Registers the program's effect managers with the scheduler.
void eco_register_all_effect_managers();

// Registers the Eco kernel's own GC roots.
void Eco_Kernel_register_all_gc_roots();

} // extern "C"

/**
 * What `main` hands to the Elm thread, and what the thread hands back:
 * the command-line arguments and, in `result`, the process exit code.
 */
struct MainArgs {
    int argc;
    char **argv;
    int result;
};

// Runs the Elm program on the calling thread, making it the mutator, and
// stores the exit code in `arg`'s `result`.
//
// `arg` must point to a `MainArgs`. Returns null, so that it fits the thread
// entry shape. The steps run in this order: the allocator and the thread's
// heap; the kernel's GC roots, before any Elm code can collect; the stack
// map; the module globals, if any; the arguments for
// `Eco::Kernel::Env::init`; the effect managers; and then `eco_main`. The
// exit code is `eco_get_exit_code()`, read after the heap is destroyed. A
// program that calls `exit` leaves before any step after `eco_main`.
//
// With `ECO_GC_EXIT_MAJOR` starting with `1`, it runs one major collection
// after `eco_main` returns, before the heap is destroyed. That changes what
// the exit statistics (one more major collection, with its pause and the
// residency it leaves), and nothing the program computes.
static void *eco_main_thread(void *arg) {
    auto *args = static_cast<MainArgs *>(arg);

    Elm::Allocator::instance().initialize();
    Elm::Allocator::instance().initThread();

    Eco_Kernel_register_all_gc_roots();

    initStackMapFromSelf();

    if (__eco_init_globals)
        __eco_init_globals();

    Eco::Kernel::Env::init(args->argc, args->argv);

    eco_register_all_effect_managers();

    (void)eco_main();

    if (const char *exit_major = std::getenv("ECO_GC_EXIT_MAJOR");
        exit_major && exit_major[0] == '1') {
        Elm::Allocator::instance().majorGC();
    }

    Elm::Allocator::instance().cleanupThread();

    args->result = eco_get_exit_code();
    return nullptr;
}

// ============================================================================
// GC statistics at exit
// ============================================================================
//
// The statistics are printed once per process, by whichever of the exit paths
// gets there first: the `atexit` handler, a signal handler, or on Windows the
// console control handler.
//
// The signal path is not async-signal-safe. Printing writes to `std::cout` and
// `Elm::Allocator::getCombinedStats` takes the allocator's mutex, so a signal
// raised while the interrupted thread holds that mutex or is inside the stream
// can deadlock or crash in the handler.
#if ENABLE_GC_STATS
// Whether the statistics have been printed, or are being printed, already.
static std::atomic<bool> g_stats_printed{false};

// Prints the combined GC statistics to stdout, headed by a line on stderr that
// names `reason`, unless they have already been printed in this process.
//
// The stderr line is written with a single `write` call, so it appears even if
// the process dies while the statistics are printed. The C++ and C stream
// buffers are flushed afterwards, since a caller may terminate the process
// next.
static void printGCStatsOnce(const char *reason) {
    if (g_stats_printed.exchange(true)) return;
    {
        char buf[128];
        int n = std::snprintf(buf, sizeof(buf),
                              "\n[gc-stats] %s — printing GC statistics\n",
                              reason);
        if (n > 0) {
#if defined(_WIN32)
            ::_write(::_fileno(stderr), buf, static_cast<unsigned int>(n));
#else
            ::write(STDERR_FILENO, buf, static_cast<size_t>(n));
#endif
        }
    }
    Elm::Allocator::instance().getCombinedStats().print();
    // `std::cout` buffers separately from `stdout`, even with `stdout`
    // unbuffered, and a re-raised signal would discard what it holds.
    std::cout.flush();
    std::fflush(stdout);
    std::fflush(stderr);
}

// Prints the GC statistics at a normal process exit, after making the
// figures final.
//
// It runs on the thread that called `exit`, or that returned from `main`.
// When that thread still has a heap (a program that called `exit` from Elm
// code) and `ECO_GC_EXIT_MAJOR` starts with `1`, it first runs a major
// collection, as `eco_main_thread` does when `eco_main` returns. It then
// finishes the calling thread's last tenure job and waits for posted GC
// helper jobs, so that their work is counted. The signal handler does none of
// this.
static void atexitPrintStats() {
    if (const char *exit_major = std::getenv("ECO_GC_EXIT_MAJOR");
        exit_major && exit_major[0] == '1' &&
        Elm::Allocator::instance().getCurrentThreadHeap() != nullptr) {
        Elm::Allocator::instance().majorGC();
    }
    Elm::Allocator::instance().finishTenureForExit();
    Elm::Allocator::instance().drainHelperWork();
    printGCStatsOnce("normal exit");
}

// Prints the GC statistics, and in census builds the P1 census report, then
// restores the default action for `sig` and raises it again, so that the
// process ends as it would have without this handler.
//
// It is not async-signal-safe; see the section comment above.
static void signalPrintStats(int sig) {
    std::signal(sig, SIG_DFL);
    const char *name = "signal";
    switch (sig) {
        case SIGABRT: name = "SIGABRT"; break;
        case SIGSEGV: name = "SIGSEGV"; break;
        case SIGFPE:  name = "SIGFPE";  break;
        case SIGILL:  name = "SIGILL";  break;
        case SIGINT:  name = "SIGINT";  break;
        case SIGTERM: name = "SIGTERM"; break;
#if !defined(_WIN32)
        case SIGBUS:  name = "SIGBUS";  break;
        case SIGQUIT: name = "SIGQUIT"; break;
        case SIGPIPE: name = "SIGPIPE"; break;
#endif
    }
    printGCStatsOnce(name);
#if P1_CENSUS_COMPILED
    Elm::p1::reportNow();
#endif
    std::raise(sig);
}

#if defined(_WIN32)
// Prints the GC statistics for a console control event (Ctrl+C, Ctrl+Break,
// console close, logoff or shutdown), naming the event, and returns `FALSE`
// so that the next handler in the chain decides what happens next.
static BOOL WINAPI consoleCtrlHandler(DWORD ctrlType) {
    const char* name = "console-ctrl";
    switch (ctrlType) {
        case CTRL_C_EVENT:        name = "CTRL_C_EVENT";        break;
        case CTRL_BREAK_EVENT:    name = "CTRL_BREAK_EVENT";    break;
        case CTRL_CLOSE_EVENT:    name = "CTRL_CLOSE_EVENT";    break;
        case CTRL_LOGOFF_EVENT:   name = "CTRL_LOGOFF_EVENT";   break;
        case CTRL_SHUTDOWN_EVENT: name = "CTRL_SHUTDOWN_EVENT"; break;
    }
    printGCStatsOnce(name);
    return FALSE;
}
#endif

// Installs the handlers that print the GC statistics: `atexitPrintStats` for a
// normal exit, and `signalPrintStats` for SIGABRT, SIGSEGV, SIGFPE, SIGILL,
// SIGINT and SIGTERM, plus SIGBUS and SIGQUIT outside Windows. On Windows it
// also installs `consoleCtrlHandler`. Does nothing without `ENABLE_GC_STATS`.
static void installStatsHandlers() {
    std::atexit(atexitPrintStats);

#if !defined(_WIN32)
    // SIGPIPE is left out: `installSigpipeIgnore` ignores it.
    struct sigaction sa{};
    sa.sa_handler = signalPrintStats;
    sigemptyset(&sa.sa_mask);
    // No SA_RESETHAND: the handler restores SIG_DFL itself.
    sa.sa_flags = SA_NODEFER;
    int signals[] = {
        SIGABRT, SIGSEGV, SIGBUS, SIGFPE, SIGILL,
        SIGINT, SIGTERM, SIGQUIT
    };
    for (int s : signals) {
        sigaction(s, &sa, nullptr);
    }
#else
    int signals[] = { SIGABRT, SIGSEGV, SIGFPE, SIGILL, SIGINT, SIGTERM };
    for (int s : signals) {
        std::signal(s, signalPrintStats);
    }
    SetConsoleCtrlHandler(consoleCtrlHandler, TRUE);
#endif
}
#else
// Does nothing: this build has no GC statistics to print.
static void installStatsHandlers() {}
#endif

// Sets SIGPIPE to be ignored, outside Windows, so that a write to a pipe whose
// reader has gone fails with `EPIPE`, which the kernel's IO functions report
// as an error to the program, instead of killing the process. Windows has no
// SIGPIPE, so there it does nothing.
static void installSigpipeIgnore() {
#if !defined(_WIN32)
    std::signal(SIGPIPE, SIG_IGN);
#endif
}

// Runs the Elm program on a new thread with a stack of
// `ECO_DEFAULT_STACK_SIZE`, and returns its exit code.
//
// Before starting the thread it makes `stdout` and `stderr` unbuffered,
// ignores SIGPIPE, installs the statistics handlers and, outside Windows,
// records this thread with `eco_set_process_main_thread`. If the thread cannot
// be created, the program runs on this thread, with this thread's stack. On
// Windows the process is ended with `TerminateProcess` instead of by
// returning.
int main(int argc, char **argv) {
    // Unbuffered, so output written before the process is killed, including
    // statistics printed by a signal handler, is not lost.
    std::setvbuf(stdout, nullptr, _IONBF, 0);
    std::setvbuf(stderr, nullptr, _IONBF, 0);

    installSigpipeIgnore();
    installStatsHandlers();

#if !defined(_WIN32)
    // Recorded before the Elm thread starts, so no reader can race it.
    eco_set_process_main_thread(pthread_self());
#endif

    MainArgs args{argc, argv, 0};

#if defined(_WIN32)
    /**
     * Adapts `eco_main_thread` to the thread entry type `_beginthreadex` takes.
     */
    struct WinAdapter {
        // Runs `eco_main_thread(a)` with the entry signature
        // `_beginthreadex` requires.
        static unsigned __stdcall run(void* a) {
            eco_main_thread(a);
            return 0;
        }
    };
    uintptr_t h = ::_beginthreadex(nullptr, ECO_DEFAULT_STACK_SIZE,
                                   &WinAdapter::run, &args, 0, nullptr);
    if (h == 0) {
        eco_main_thread(&args);
    } else {
        ::WaitForSingleObject(reinterpret_cast<HANDLE>(h), INFINITE);
        ::CloseHandle(reinterpret_cast<HANDLE>(h));
    }
#else
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setstacksize(&attr, ECO_DEFAULT_STACK_SIZE);

    pthread_t thread;
    if (pthread_create(&thread, &attr, eco_main_thread, &args) != 0) {
        eco_main_thread(&args);
    } else {
        pthread_join(thread, nullptr);
    }

    pthread_attr_destroy(&attr);
#endif

#if defined(_WIN32)
    // Windows ends the process here rather than by returning. The scheduler's
    // service threads are detached and never told to stop. Returning would run
    // `exit`, whose `ExitProcess` kills those threads, possibly while one holds
    // a lock, and then runs DLL detach and static destructors that may need the
    // same lock, so the process can hang. `TerminateProcess` runs neither. It
    // also skips the `atexit` handlers, so no statistics are printed here.
    std::cout.flush();
    std::cerr.flush();
    ::TerminateProcess(::GetCurrentProcess(), static_cast<UINT>(args.result));
    // `TerminateProcess` may return before the process is gone; returning
    // from `main` would then reach the teardown avoided above.
    for (;;) { ::Sleep(1000); }
#endif
    return args.result;
}
