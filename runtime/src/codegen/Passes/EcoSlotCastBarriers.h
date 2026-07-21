//===- EcoSlotCastBarriers.h - Fold-proof boxed-slot cast barriers --------===//
//
// REP_LLVM_002 (plans/fold-proof-boxed-slot-crossings.md).
//
// A raw `inttoptr`/`ptrtoint` pair met across an inlining seam is annihilated
// by InlineFunction's SimplifyInstruction (`ptrtoint(inttoptr(x)) -> x`),
// leaving a raw i64 live across the spliced body's statepoints — invisible to
// RS4GC and stale after any GC inside the body (two bisected, IR-verified
// miscompiles: capture unpacking and tuple-projection -> args-slot store).
// Boxed-SLOT i64 <-> ptr addrspace(1) crossings are therefore emitted as
// calls to two DECLARE-ONLY gc-leaf barrier functions the inliner cannot
// fold through; StripEcoCastBarriers (EcoPtrIntVerify.cpp) rewrites every
// barrier call back to the bare cast strictly post-RS4GC, so codegen and the
// per-partition -O2 see exactly the pre-barrier IR.
//
// This header is shared by the MLIR-side emission helpers
// (EcoToLLVMInternal.h), the LLVM-side strip pass, and the backend's `$cap`
// inline prepass (EcoBackend.cpp), which couples the GC-call-free guard to
// the barrier switch.
//
//===----------------------------------------------------------------------===//

#ifndef ECO_SLOT_CAST_BARRIERS_H
#define ECO_SLOT_CAST_BARRIERS_H

#include <cstdlib>

namespace eco {

/// Barrier symbol names. i64 (slot word) -> ptr addrspace(1), and back.
inline constexpr const char kSlotToHPtrSym[] = "__eco_slot_to_hptr";
inline constexpr const char kHPtrToSlotSym[] = "__eco_hptr_to_slot";

/// Master switch for barrier EMISSION. Default ON; `ECO_SLOT_CAST_BARRIERS=0`
/// disables it (escape hatch / A-B lever). Disabling is only sound because
/// `runCapInlinePrepass` (EcoBackend.cpp) then forces the GC-call-free `$cap`
/// inline guard back on — barriers-off + full-population inlining would
/// reconstruct the bisected REP_LLVM_001(a) miscompiles.
inline bool slotCastBarriersEnabled() {
    static const bool enabled = [] {
        const char *e = ::getenv("ECO_SLOT_CAST_BARRIERS");
        return !(e && e[0] == '0' && e[1] == '\0');
    }();
    return enabled;
}

} // namespace eco

#endif // ECO_SLOT_CAST_BARRIERS_H
