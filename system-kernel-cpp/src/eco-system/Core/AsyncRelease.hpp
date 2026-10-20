//===- AsyncRelease.hpp - RAII pendingAsync decrement --------------------===//
//
// G10: a drain decrements pendingAsync exactly once for every queued result,
// on every path (resumed, orphaned by a kill, or failed by an exception).
// Construct one per popped result; `dismiss()` only when ownership of the
// count passes elsewhere (e.g. a parked token that stays counted).
//
// Templates used: T2, T9 (drain side).
//
// TRANSITIONAL (plans/program-liveness-rule.md §5.1, phases 4-5): replaced by
// the hold API's HoldRelease (runtime/src/platform/Liveness.hpp, re-exported
// into Eco::System below and by Core.hpp), which releases one hold BY TOKEN.
// The modules migrated in phase 4 (Core, SysWorkPool, FileSystem,
// ChildProcess, Stream, StreamPipe, HttpStream, Tls) no longer use this
// class; Socket, Udp, HttpServer and WebSocket still do until phase 5, which
// deletes this header. A raw decrement here pairs with a raw
// incrementPendingAsync in those modules only.
//
//===----------------------------------------------------------------------===//

#ifndef ECO_SYSTEM_CORE_ASYNC_RELEASE_HPP
#define ECO_SYSTEM_CORE_ASYNC_RELEASE_HPP

#include "eco-system/Core/Core.hpp"

namespace Eco::System {

using ::Elm::Platform::HoldRelease;   // the replacement (also via Core.hpp)

class AsyncRelease {
public:
    explicit AsyncRelease(bool active = true) : active_(active) {}
    ~AsyncRelease() {
        if (active_) Scheduler::instance().decrementPendingAsync();
    }
    void dismiss() { active_ = false; }

    AsyncRelease(const AsyncRelease&) = delete;
    AsyncRelease& operator=(const AsyncRelease&) = delete;

private:
    bool active_;
};

} // namespace Eco::System

#endif // ECO_SYSTEM_CORE_ASYNC_RELEASE_HPP
