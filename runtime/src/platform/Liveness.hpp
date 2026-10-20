//===- Liveness.hpp - Program-liveness holds -------------------------------===//
//
// One hold = one unit of program liveness (one Scheduler::pendingAsync_
// count), owned by one kernel object for one reason, released exactly once
// on every path (plans/program-liveness-rule.md §2.1, §5.1; LIVE_003).
//
// Holds are acquired through Scheduler::parkResume (keyed by the resume
// token) or Scheduler::acquireHold (free-standing), and released through
// Scheduler::releaseHold, LivenessHold or HoldRelease.
//
//===----------------------------------------------------------------------===//

#ifndef ECO_PLATFORM_LIVENESS_HPP
#define ECO_PLATFORM_LIVENESS_HPP

#include <cstdint>

namespace Elm::Platform {

// Why a hold exists. Census and embed activity only; holds of every kind count
// the same for liveness, except Host (not "busy", §8).
enum class HoldKind : uint8_t { Task, Subscription, Item, Host, Port };

const char* holdKindName(HoldKind k) noexcept;

// The id of one hold. 0 = no hold. A hold acquired by parkResume has the
// resume token as its id (bit 63 clear); a free-standing hold has bit 63 set
// (from its own counter), so the two never collide. Plain data: may be stored
// in a table entry and copied, but released once.
using HoldToken = uint64_t;
constexpr HoldToken kNoHold = 0;
constexpr HoldToken kFreeHoldBit = 1ull << 63;

// Owns at most one hold. Move-only. Destruction releases a still-owned hold.
// Thread-safe in the same sense as Scheduler::releaseHold. Members are defined
// in Scheduler.cpp.
class LivenessHold {
public:
    LivenessHold() noexcept = default;
    static LivenessHold acquire(HoldKind kind, const char* site);  // a free-standing hold
    static LivenessHold adopt(HoldToken t) noexcept;  // takes over a token's release duty
    LivenessHold(LivenessHold&& o) noexcept;           // o becomes empty
    LivenessHold& operator=(LivenessHold&& o) noexcept;  // releases own, then takes o's
    LivenessHold(const LivenessHold&) = delete;
    LivenessHold& operator=(const LivenessHold&) = delete;
    ~LivenessHold();                                    // release() if owned
    void release() noexcept;                            // idempotent
    HoldToken detach() noexcept;                        // gives up ownership, returns the token
    HoldToken token() const noexcept { return t_; }
    explicit operator bool() const noexcept { return t_ != kNoHold; }
private:
    explicit LivenessHold(HoldToken t) noexcept : t_(t) {}
    HoldToken t_ = kNoHold;
};

// RAII release of one hold, typically the resume-keyed hold of a popped result
// (plans/program-liveness-rule.md §5.1). `dismiss()` when ownership passes
// elsewhere. Construct it before resuming, so the release happens after the
// result has been published (§6.2). Defined in Scheduler.cpp.
class HoldRelease {
public:
    explicit HoldRelease(HoldToken t) noexcept : t_(t) {}
    ~HoldRelease();
    void dismiss() noexcept { t_ = kNoHold; }
    HoldRelease(const HoldRelease&) = delete;
    HoldRelease& operator=(const HoldRelease&) = delete;
private:
    HoldToken t_;
};

} // namespace Elm::Platform

#endif // ECO_PLATFORM_LIVENESS_HPP
