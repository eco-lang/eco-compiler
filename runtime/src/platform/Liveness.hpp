//===- Liveness.hpp - Program-liveness holds -------------------------------===//
//
// The program keeps running while something it waits for is still to come,
// such as a timer, a reply or a subscription. A hold is one such reason, and
// this header is the vocabulary for naming and releasing holds.
//
// A hold is one unit of program liveness: acquiring one adds one to the
// Scheduler's pending-async count, and releasing it takes one away. Each hold
// is owned by one kernel object for one reason, and must be released exactly
// once on every path. A hold is named by a `HoldToken`.
//
// Holds are acquired through `Scheduler::parkResume`, which parks a resume
// and keys the hold by its resume token, or through `Scheduler::acquireHold`
// for a free-standing hold. They are released through
// `Scheduler::releaseHold`, either directly or through the two owners
// declared here: `LivenessHold`, which may be kept for any length of time and
// moved, and `HoldRelease`, which releases at the end of a scope. Their
// members are defined in Scheduler.cpp.
//
//===----------------------------------------------------------------------===//

#ifndef ECO_PLATFORM_LIVENESS_HPP
#define ECO_PLATFORM_LIVENESS_HPP

#include <cstdint>

namespace Elm::Platform {

/**
 * The reason a hold exists.
 *
 * Every kind keeps the program alive in the same way. The kind is recorded
 * for the hold census in builds that keep one, and is also carried in every
 * free-standing hold's token. It separates out Host: a free-standing Host
 * hold keeps the event loop alive but does not make the program count as
 * busy to an embedding host. Host holds must be acquired free-standing; a
 * resume-keyed one is counted on acquire but not uncounted on release.
 */
enum class HoldKind : uint8_t { Task, Subscription, Item, Host, Port };

// Returns the enumerator's name as a static string, or "?" for a value that
// is not an enumerator.
const char* holdKindName(HoldKind k) noexcept;

// The identifier of one hold.
//
// A hold acquired by `Scheduler::parkResume` has the resume token as its
// identifier, with bit 63 clear. A free-standing hold has bit 63 set and is
// numbered from a separate counter, so the two kinds of token do not collide.
// A token is plain data and may be copied and stored, but the hold it names
// must be released once only, whichever copy is used. The compiler enforces
// none of this.
using HoldToken = uint64_t;
// The token that names no hold.
constexpr HoldToken kNoHold = 0;
// The bit that is set in every free-standing hold's token and clear in every
// resume-keyed one.
constexpr HoldToken kFreeHoldBit = 1ull << 63;

/**
 * The owner of at most one hold, which it releases when destroyed.
 *
 * A default-constructed `LivenessHold` owns nothing. One that owns a hold is
 * obtained from `acquire` or `adopt`. It cannot be copied. Moving hands the
 * hold over and leaves the moved-from object owning nothing, and move
 * assignment first releases the hold the target owned. Releasing goes
 * through `Scheduler::releaseHold`, which may be called from any thread.
 */
class LivenessHold {
public:
    // Creates an owner of no hold.
    LivenessHold() noexcept = default;
    // Acquires a free-standing hold of kind `kind` and returns its owner.
    // `site` names the acquiring code in census reports. Census builds keep
    // the pointer after the hold is released, so it must stay valid for the
    // rest of the run; a string literal does.
    static LivenessHold acquire(HoldKind kind, const char* site);
    // Returns an owner of the hold named by `t`, which takes over the duty of
    // releasing it. The caller must not release `t` itself afterwards.
    static LivenessHold adopt(HoldToken t) noexcept;
    // Takes over the hold `o` owned, leaving `o` owning nothing.
    LivenessHold(LivenessHold&& o) noexcept;
    // Releases the hold this object owned, then takes over the one `o` owned.
    LivenessHold& operator=(LivenessHold&& o) noexcept;
    LivenessHold(const LivenessHold&) = delete;
    LivenessHold& operator=(const LivenessHold&) = delete;
    ~LivenessHold();
    // Releases the owned hold, if any, and leaves this object owning nothing.
    // Calling it again does nothing.
    void release() noexcept;
    // Gives up ownership without releasing, and returns the token of the hold
    // that was owned, or `kNoHold`. The caller takes over the release.
    HoldToken detach() noexcept;
    // Returns the token of the owned hold, or `kNoHold`. Ownership stays here.
    HoldToken token() const noexcept { return t_; }
    // Returns whether a hold is owned.
    explicit operator bool() const noexcept { return t_ != kNoHold; }
private:
    // Creates the owner of the hold named by `t`.
    explicit LivenessHold(HoldToken t) noexcept : t_(t) {}
    HoldToken t_ = kNoHold;
};

/**
 * A guard that releases one hold at the end of its scope.
 *
 * It is meant for the resume-keyed hold of a result that has just been taken
 * off a queue. Constructed before the code that resumes the waiting task, it
 * releases the hold only after that code has run, so the hold outlasts the
 * publication of the result. It cannot be copied or moved. Given `kNoHold`,
 * it releases nothing.
 */
class HoldRelease {
public:
    // Creates a guard that will release the hold named by `t`.
    explicit HoldRelease(HoldToken t) noexcept : t_(t) {}
    ~HoldRelease();
    // Stops the guard from releasing anything, for when the duty to release
    // has passed elsewhere.
    void dismiss() noexcept { t_ = kNoHold; }
    HoldRelease(const HoldRelease&) = delete;
    HoldRelease& operator=(const HoldRelease&) = delete;
private:
    HoldToken t_;
};

} // namespace Elm::Platform

#endif // ECO_PLATFORM_LIVENESS_HPP
