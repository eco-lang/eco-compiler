//===- AsyncRelease.hpp - RAII pendingAsync decrement --------------------===//
//
// G10: a drain decrements pendingAsync exactly once for every queued result,
// on every path (resumed, orphaned by a kill, or failed by an exception).
// Construct one per popped result; `dismiss()` only when ownership of the
// count passes elsewhere (e.g. a parked token that stays counted).
//
// Templates used: T2, T9 (drain side).
//
//===----------------------------------------------------------------------===//

#ifndef ECO_SYSTEM_CORE_ASYNC_RELEASE_HPP
#define ECO_SYSTEM_CORE_ASYNC_RELEASE_HPP

#include "eco-system/Core/Core.hpp"

namespace Eco::System {

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
