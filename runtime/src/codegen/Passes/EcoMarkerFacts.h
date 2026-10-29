//===- EcoMarkerFacts.h - The marker table (may-GC / leafness facts) -------===//
//
// Several passes must agree on whether a call can reach a garbage collection,
// and for some callees the answer is not on the declaration, so this header
// holds those answers as one table that all of them read.
//
// A marker is a declaration-only `__eco_*` function that the LLVM backend
// replaces with inline code before RS4GC (LLVM's RewriteStatepointsForGC)
// runs. A call to a marker is never executed, so what matters is the code it
// expands into. That code may be leaf-only even though the declaration is not
// gc-leaf, and a declaration may be gc-leaf even though its expansion calls a
// function that can collect. A gc-leaf function is one that never reaches a
// collection, and a call to it needs no statepoint. A few runtime functions
// that are not markers are in the table too.
//
// The answer depends on how far the expansions have got, so the table has
// two views of a callee.
//
// The hoisting view (`hoistView`) is how a call is classified after the
// expansions that run before capacity hoisting. Capacity hoisting
// (CGEN_074) replaces per-allocation nursery checks with one check of
// headroom earlier in the function, which is valid only if nothing between
// the check and the allocations can collect or use up that headroom. The
// MLIR planner `EcoCapHoistPlan` reads this view.
//
// The final view (`finalView`) is how a call is classified once every
// expansion before RS4GC has run. `EcoGcFreePropagation` reads it to decide
// which generated functions can be stamped gc-leaf.
//
// The rest are checks on the module. `expansionCalleeLeaf` says what the
// declarations that the expansions call must carry, and the LLVM backend
// compares it against the module's declarations and reports any
// disagreement as an error. `isTrustedLeafDecl` names the declarations that may be
// gc-leaf on their own authority. `isHeadroomBreaker` names the gc-leaf
// runtime calls that still consume nursery headroom.
//
// Each predicate mirrors code elsewhere: the expansions in `EcoBackend.cpp`
// and the runtime declarations. Nothing ties them together at compile time,
// so the table changes whenever an expansion does.
//
//===----------------------------------------------------------------------===//
#ifndef ECO_MARKER_FACTS_H
#define ECO_MARKER_FACTS_H

#include "llvm/ADT/StringRef.h"

namespace eco::markers {

/**
 * How the hoisting view classifies a direct call. `FromDecl` means the
 * callee is not in the table and is classified by its declaration: gc-leaf,
 * a libm function, or a defined callee.
 */
enum class Hoist { FromDecl, Leaf, NotLeaf };

// Returns whether `c` is one of the list-cursor markers that
// `EcoListCursor` emits, all of which both views treat as leaf.
//
// The `__eco_list_cur*` and `__eco_list_step_*_inline` markers are declared
// without gc-leaf and expand into loads. `eco_list_pos_view`, the runtime
// function the pass also emits, is not in the set: it allocates a chunk view
// when idx > 0 and so can collect, and it is classified by its declaration,
// which is not gc-leaf.
inline bool isCursorMarker(llvm::StringRef c) {
    return c.starts_with("__eco_list_cur") ||
           c == "__eco_list_step_node_inline" ||
           c == "__eco_list_step_idx_inline";
}

// Returns whether `c` is one of the list scratch-stack runtime calls that
// cannot collect: `eco_scratch_mark` and the two pushes.
//
// `EcoListTemplate` declares them without gc-leaf, and the LLVM backend
// stamps them gc-leaf before capacity hoisting. `eco_scratch_finish`
// allocates and is not in the set.
inline bool isScratchHelper(llvm::StringRef c) {
    return c == "eco_scratch_mark" || c == "eco_scratch_push_boxed" ||
           c == "eco_scratch_push_scalar";
}

// Returns whether `c` is one of the libm functions that LLVM's
// `callsGCLeafFunction` treats as gc-leaf through the target library info,
// whatever its declaration says.
//
// The passes that classify calls in MLIR cannot ask LLVM, so they use this
// list to give the same answer.
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

// Returns whether `c` is a headroom breaker: a runtime allocation entry
// point that is gc-leaf but bumps the nursery, so it uses up headroom that a
// hoisted capacity check reserved.
//
// These are `eco_gc_alloc_region_fast` and every `eco_alloc_*_fast` name.
inline bool isHeadroomBreaker(llvm::StringRef c) {
    return c == "eco_gc_alloc_region_fast" ||
           (c.starts_with("eco_alloc_") && c.ends_with("_fast"));
}

// Returns how a direct call to `callee` is classified after the expansions
// that precede capacity hoisting.
//
// `__eco_list_tail_inline` is `NotLeaf`, because its expansion calls
// `eco_list_tail_hybrid`, which can collect. `__eco_value_eq` expands into
// code that calls `Elm_Kernel_Utils_equal`, so it is `Leaf` only when
// `valueEqLeaf` is true, which the caller may set only when that function
// is, or will be made, gc-leaf.
// Cursor markers and scratch helpers are `Leaf`. Every other callee,
// including other markers, is `FromDecl`.
inline Hoist hoistView(llvm::StringRef callee, bool valueEqLeaf) {
    if (callee == "__eco_list_tail_inline")
        return Hoist::NotLeaf;
    if (callee == "__eco_value_eq")
        return valueEqLeaf ? Hoist::Leaf : Hoist::NotLeaf;
    if (isCursorMarker(callee) || isScratchHelper(callee))
        return Hoist::Leaf;
    return Hoist::FromDecl;
}

/**
 * Whether a call can reach a collection once every expansion before RS4GC
 * has run, as the final view classifies it.
 *
 * `FromDecl` means the callee is not in the table and its declaration
 * decides: gc-leaf, a libm function or a leaf intrinsic. `Leaf` and `Poison`
 * mean the call cannot and can collect. `UnlessCovered` means leaf only
 * inside a function that capacity hoisting covers, where the bump is
 * unchecked. `ValueEq` means leaf only when the planned value-eq predicate
 * holds.
 */
enum class Final { FromDecl, Leaf, Poison, UnlessCovered, ValueEq };

// Returns whether `c` has the `__eco_` prefix that every marker name has.
//
// `EcoGcFreePropagation` rejects a call to a declared function with such a
// name that `finalView` classifies as `FromDecl`, so every marker needs a
// row in `finalView`.
inline bool isMarkerName(llvm::StringRef c) { return c.starts_with("__eco_"); }

// Returns how a call to `c` is classified once every expansion before RS4GC
// has run.
//
// `__eco_alloc_inline` expands into a nursery bump whose slow path can
// collect, unless capacity hoisting has made the bump unchecked, so it is
// `UnlessCovered`. `__eco_value_eq` is `ValueEq`. `__eco_list_tail_inline`,
// `__eco_sat_begin` and `__eco_sat_end` are `Poison`. The pointer and
// projection markers, the cursor markers and the scratch helpers are `Leaf`.
// Anything else is `FromDecl`.
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

// Returns whether a declaration of `c`, a function that an expansion before
// RS4GC calls, must be gc-leaf: 1 if it must, 0 if it must not, and -1 if
// the table says nothing about `c`.
//
// The slow paths `eco_list_tail_hybrid`, `eco_alloc_inline_slow` and
// `eco_ensure_nursery_slow` must not be gc-leaf, because they can collect.
// `Elm_Kernel_Utils_equal` must be gc-leaf exactly when `veq`, the planned
// value-eq predicate, holds.
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

// Returns whether `c` names a function that may be gc-leaf on its own
// authority: a runtime, kernel or LLVM intrinsic function, or a libm
// function.
//
// The test is by prefix (`eco_`, `__eco_`, `Elm_Kernel_`, `Eco_Kernel_`,
// `llvm.`), so it trusts any function so named. Callers reject a gc-leaf
// definition with any other name unless a gc-free plan stamped it.
inline bool isTrustedLeafDecl(llvm::StringRef c) {
    return c.starts_with("eco_") || c.starts_with("__eco_") ||
           c.starts_with("Elm_Kernel_") || c.starts_with("Eco_Kernel_") ||
           c.starts_with("llvm.") || isLibmLeaf(c);
}

} // namespace eco::markers

#endif // ECO_MARKER_FACTS_H
