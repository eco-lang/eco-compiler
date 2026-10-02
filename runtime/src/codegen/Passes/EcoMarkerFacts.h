//===- EcoMarkerFacts.h - The marker table (may-GC / leafness facts) -------===//
//
// One table, read by the MLIR capacity-hoisting planner (EcoCapHoistPlan)
// and asserted against the expanded module by the LLVM backend
// (applyCapacityHoisting), so the two views of a marker cannot drift.
// plans/mlir-split-backend-01-cap-hoist-plan.md §2.2 / Part II P3; plan 02
// will add the final-view column.
//
// "Hoisting view" = how LLVM Phase A classifies a call AFTER the
// pre-hoisting expansions (runEcoBackend steps 1-7): a marker that expands
// into leaf-only code is transparent even when its MLIR declaration carries
// no gc-leaf passthrough, and a marker declared gc-leaf in MLIR that expands
// into a statepoint-capable call is NOT.
//
//===----------------------------------------------------------------------===//
#ifndef ECO_MARKER_FACTS_H
#define ECO_MARKER_FACTS_H

#include "llvm/ADT/StringRef.h"

namespace eco::markers {

enum class Hoist { FromDecl, Leaf, NotLeaf };

// List cursors (Passes/EcoListCursor.cpp): declared without passthrough,
// expanded by expandListCursorMarkers into diamonds whose only calls are
// leaf barriers and __eco_resolve_fwd.
inline bool isCursorMarker(llvm::StringRef c) {
    return c.starts_with("__eco_list_cur") ||
           c == "__eco_list_step_node_inline" ||
           c == "__eco_list_step_idx_inline" || c == "eco_list_pos_view";
}

// Scratch helpers (Passes/EcoListTemplate.cpp ensureDecl): stamped gc-leaf by
// the backend before hoisting (EcoBackend.cpp runEcoBackend).
inline bool isScratchHelper(llvm::StringRef c) {
    return c == "eco_scratch_mark" || c == "eco_scratch_push_boxed" ||
           c == "eco_scratch_push_scalar";
}

// The TLI arm of llvm::callsGCLeafFunction: libm functions the runtime
// declares. Plan 00 measured zero TLI-only leaf calls; the list keeps the
// emulation exact should one appear.
inline bool isLibmLeaf(llvm::StringRef c) {
    static const char *names[] = {
        "asin", "acos",  "atan",  "atan2", "sin",   "cos",  "tan",
        "exp",  "log",   "log2",  "log10", "pow",   "sqrt", "floor",
        "ceil", "trunc", "round", "fabs",  "fmod",  "ldexp"};
    for (const char *n : names)
        if (c == n)
            return true;
    return false;
}

// Runtime entry points that consume nursery headroom even though they are
// gc-leaf (CGEN_074 "headroom breakers").
inline bool isHeadroomBreaker(llvm::StringRef c) {
    return c == "eco_gc_alloc_region_fast" ||
           (c.starts_with("eco_alloc_") && c.ends_with("_fast"));
}

// Hoisting view for a direct call to `callee`. `valueEqLeaf` is true iff
// ECO_VALUE_EQ_GCLEAF=1 or the module being classified holds a gc-leaf
// `Elm_Kernel_Utils_equal` declaration (the value-eq expansion calls it).
inline Hoist hoistView(llvm::StringRef callee, bool valueEqLeaf) {
    if (callee == "__eco_list_tail_inline")
        return Hoist::NotLeaf; // -> eco_list_tail_hybrid (not leaf)
    if (callee == "__eco_value_eq")
        return valueEqLeaf ? Hoist::Leaf : Hoist::NotLeaf;
    if (isCursorMarker(callee) || isScratchHelper(callee))
        return Hoist::Leaf;
    return Hoist::FromDecl;
}

// Final view (plan 02 §5.1 / Part II Q3): may a call to `callee` reach a GC
// once every pre-RS4GC expansion has run? Read by EcoGcFreePropagation.
//   FromDecl      - not a marker: the declaration's gc-leaf / libm / intrinsic
//   Leaf          - the expansion emits leaf-only code
//   Poison        - the expansion emits a call that can GC (or an indirect call)
//   UnlessCovered - leaf only in an eco-cap-covered function (unchecked bump)
//   ValueEq       - leaf iff the planned value-eq predicate `veq` holds
enum class Final { FromDecl, Leaf, Poison, UnlessCovered, ValueEq };

inline bool isMarkerName(llvm::StringRef c) { return c.starts_with("__eco_"); }

inline Final finalView(llvm::StringRef c) {
    if (c == "__eco_alloc_inline")
        return Final::UnlessCovered;
    if (c == "__eco_list_tail_inline" || c == "__eco_sat_begin" ||
        c == "__eco_sat_end")
        return Final::Poison;
    if (c == "__eco_value_eq")
        return Final::ValueEq;
    if (c == "__eco_resolve_fwd" || c == "__eco_get_tag_inline" ||
        c == "__eco_list_head_inline" || c == "__eco_string_len_inline" ||
        c == "__eco_slot_to_hptr" || c == "__eco_hptr_to_slot" ||
        isCursorMarker(c) || isScratchHelper(c))
        return Final::Leaf;
    return Final::FromDecl;
}

// Expansion-callee column: what a declaration that a pre-RS4GC expansion
// calls must carry. -1 = no row, 0 = must NOT be gc-leaf, 1 = must be gc-leaf.
// Checked against the module's declarations (EcoBackend.cpp checkMarkerDecls).
inline int expansionCalleeLeaf(llvm::StringRef c, bool veq) {
    if (c == "eco_list_tail_hybrid" || c == "eco_alloc_inline_slow" ||
        c == "eco_ensure_nursery_slow")
        return 0;
    if (c == "eco_list_head_hybrid" || c == "__eco_resolve_fwd" ||
        c == "eco_follow_forward" || c == "__eco_slot_to_hptr" ||
        c == "eco_bump_state" || isScratchHelper(c))
        return 1;
    if (c == "Elm_Kernel_Utils_equal")
        return veq ? 1 : 0;
    return -1;
}

// R1 gap (plan 01 §3, plan 02 F11): a declaration may carry gc-leaf without
// any eco-cap-* fact only if it is a runtime / kernel / intrinsic / libm
// name. A generated function whose copied declaration lost its eco-cap facts
// would otherwise read as a transparent leaf.
inline bool isTrustedLeafDecl(llvm::StringRef c) {
    return c.starts_with("eco_") || c.starts_with("__eco_") ||
           c.starts_with("Elm_Kernel_") || c.starts_with("Eco_Kernel_") ||
           c.starts_with("llvm.") || isLibmLeaf(c);
}

} // namespace eco::markers

#endif // ECO_MARKER_FACTS_H
