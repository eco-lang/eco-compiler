//===- EcoSlotCastBarriers.h - Fold-proof boxed-slot cast barriers --------===//
//
// A boxed slot is a 64-bit word that holds a heap pointer. Converting it to a
// GC-tracked `ptr addrspace(1)` and back with raw `inttoptr` and `ptrtoint` is
// unsafe before statepoint rewriting (RS4GC): when inlining brings such a pair
// together, LLVM's simplifier folds `ptrtoint(inttoptr(x))` to `x`. That leaves
// a raw `i64` holding a pointer live across the inlined body's safepoints, where
// RS4GC cannot see it, and the value is stale after any collection there.
//
// This component names the two barrier functions used instead of those casts.
// Each is a declaration with no body, marked gc-leaf (it does not collect), so
// no pass before RS4GC can fold through a call to it. After RS4GC,
// `StripEcoCastBarriers` (EcoPtrIntVerify.cpp) replaces every call with the
// bare cast and deletes the declaration. This header also holds the switch
// that turns barrier emission off.
//
//===----------------------------------------------------------------------===//

#ifndef ECO_SLOT_CAST_BARRIERS_H
#define ECO_SLOT_CAST_BARRIERS_H

#include <cstdlib>

namespace eco {

/// The symbol of the barrier that converts an `i64` slot word to a
/// `ptr addrspace(1)`.
inline constexpr const char kSlotToHPtrSym[] = "__eco_slot_to_hptr";
/// The symbol of the barrier that converts a `ptr addrspace(1)` to an `i64`
/// slot word.
inline constexpr const char kHPtrToSlotSym[] = "__eco_hptr_to_slot";

/// Returns whether slot crossings are emitted as barrier calls rather than bare
/// casts. This is true unless the environment variable
/// `ECO_SLOT_CAST_BARRIERS` is exactly `0`. The variable is read on the first
/// call and the answer is kept for the life of the process.
///
/// Turning barriers off is safe only if no inlining before RS4GC can bring a
/// cast pair together across a safepoint. When this returns false, the
/// backend's `$cap` inline prepass (`runCapInlinePrepass`, EcoBackend.cpp)
/// restricts its size-based selection to functions whose bodies make no
/// GC-capable calls (an explicit `ECO_CAP_INLINE_LIST` bypasses this).
inline bool slotCastBarriersEnabled() {
    static const bool enabled = [] {
        const char *e = ::getenv("ECO_SLOT_CAST_BARRIERS");
        return !(e && e[0] == '0' && e[1] == '\0');
    }();
    return enabled;
}

} // namespace eco

#endif // ECO_SLOT_CAST_BARRIERS_H
