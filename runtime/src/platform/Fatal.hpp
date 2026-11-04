//===- Fatal.hpp - The runtime's one fatal-error path ----------------------===//
//
// `reportFatal` ends the process after a fault that cannot be delivered to Elm code as a Task failure: a C++
// exception that reached a binding trampoline (TaskBinding.hpp) or a kernel export (`ECO_KERNEL_GUARD`, which
// forwards here through `Eco::Kernel::reportFatal`), or an unsupported platform feature. Every such ending goes
// through it, so it is also where process-wide cleanup that must survive a fatal end hooks in: a kernel that has
// changed state outside the process, such as the terminal mode, registers a pre-fatal hook with `addPreFatalHook`
// to put it back before the abort.
//
// The header is self-contained (no runtime library symbol), so the runtime, the kernels and the tests can all
// include it. The hook table is a function-local static of an inline function, one per program.
//
//===----------------------------------------------------------------------===//

#ifndef ELM_PLATFORM_FATAL_HPP
#define ELM_PLATFORM_FATAL_HPP

#include <atomic>
#include <cstddef>
#include <cstdio>
#include <cstdlib>
#include <exception>
#include <new>

namespace Elm::Platform {

/// A function `reportFatal` calls before it aborts. It runs on the thread that reports the fault, possibly while
/// another thread is mid-operation, so it must only do what is safe in that state: plain system calls on state it
/// owns (as `tcsetattr`), no heap allocation, no locks the faulting code may hold, and no Elm heap access.
using PreFatalHook = void (*)();

namespace detail {

/// The most pre-fatal hooks that can be registered; `addPreFatalHook` refuses more.
inline constexpr std::size_t kMaxPreFatalHooks = 8;

/// The registered hooks, in registration order; null slots are unused.
inline std::atomic<PreFatalHook>* preFatalHooks() {
    static std::atomic<PreFatalHook> hooks[kMaxPreFatalHooks] = {};
    return hooks;
}

/// Set by the first `reportFatal`, so that a fault inside a hook (which reports again) does not run the hooks a
/// second time.
inline std::atomic<bool>& fatalInProgress() {
    static std::atomic<bool> flag{false};
    return flag;
}

} // namespace detail

/// Registers `hook` to run when `reportFatal` ends the process, and returns whether it was registered. Registering
/// the same hook again is a no-op that returns true; a full table returns false. Hooks cannot be removed: a hook
/// whose state no longer needs cleanup should check that itself and do nothing. Thread-safe.
inline bool addPreFatalHook(PreFatalHook hook) {
    if (!hook) return false;
    auto* hooks = detail::preFatalHooks();
    for (std::size_t i = 0; i < detail::kMaxPreFatalHooks; ++i) {
        PreFatalHook cur = hooks[i].load(std::memory_order_acquire);
        if (cur == hook) return true;
        if (!cur) {
            PreFatalHook expected = nullptr;
            if (hooks[i].compare_exchange_strong(expected, hook, std::memory_order_acq_rel)) return true;
            if (expected == hook) return true;
        }
    }
    return false;
}

/// Reports an unrecoverable native fault and aborts the process.
///
/// It flushes stdout, runs the pre-fatal hooks in registration order (only on the first call, if a hook itself
/// reports a fault), writes `[eco-runtime] FATAL: ` followed by `what` (or `(null)` when `what` is null) to stderr,
/// and calls `std::abort`.
[[noreturn]] inline void reportFatal(const char* what) {
    std::fflush(stdout);
    if (!detail::fatalInProgress().exchange(true)) {
        auto* hooks = detail::preFatalHooks();
        for (std::size_t i = 0; i < detail::kMaxPreFatalHooks; ++i) {
            if (PreFatalHook h = hooks[i].load(std::memory_order_acquire)) h();
        }
    }
    std::fprintf(stderr, "\n[eco-runtime] FATAL: %s\n", what ? what : "(null)");
    std::fflush(stderr);
    std::abort();
}

/// Reports the exception being handled with `reportFatal`, as `ECO_KERNEL_GUARD` does: a `std::bad_alloc` as
/// running out of memory, any other `std::exception` by its `what()`, and anything else as an unknown native
/// exception. Must be called from inside a `catch` handler.
[[noreturn]] inline void reportFatalCurrentException() {
    try {
        throw;
    } catch (const std::bad_alloc&) {
        reportFatal("out of memory in kernel");
    } catch (const std::exception& e) {
        reportFatal(e.what());
    } catch (...) {
        reportFatal("unknown native exception in kernel");
    }
}

} // namespace Elm::Platform

#endif // ELM_PLATFORM_FATAL_HPP
