// RUN: %ecoc %s -emit=llvm 2>&1 | %FileCheck %s --check-prefix=LEAF
//
// plans/list-map-mlir-template.md Goal 3 / CGEN_078(e) + CGEN_072(b)(d): with
// an ALLOCATION-FREE callback the templated loop body compiles to a
// statepoint-free scalar loop.
//
// Two independent things have to hold, and the second is the one that is easy
// to lose:
//
//  1. The devirtualized callee is called DIRECTLY and is not wrapped in a
//     `gc.statepoint`. `propagateGcFreeLeafAttrs` stamps the `$cap` clone
//     `gc-leaf-function` (a callee-to-caller fixpoint over RS4GC's own
//     `callsGCLeafFunction`), so RS4GC emits no statepoint and no relocation
//     for that call.
//
//  2. **`eco_list_tail_hybrid` must be absent.** It is named CGEN_072(a)
//     poison — it allocates the successor chunk view — so if `EcoListCursor`
//     fails to rewrite the loop to the `(node, idx)` form, the tail projection
//     keeps that call on its chunk edge and forces a statepoint per element
//     even though the callback is gc-leaf. Cursor pickup is therefore a hard
//     PRECONDITION of the statepoint-free property, not a speed nicety, and
//     this negative is what pins it.
//
// Patterns are deliberately callee-scoped one-liners rather than region
// checks: `CodegenIsolatedTest` passes only the emit mode from the RUN line
// and FileCheck's patterns are unscoped and order-insensitive against
// subprocess stdout, so a region-shaped check would not mean what it appears
// to mean. `-emit=llvm` runs the full backend — `propagateGcFreeLeafAttrs`
// and RS4GC included — and prints the post-RS4GC module.

module {
  // Allocation-free: projects nothing, allocates nothing, calls nothing.
  func.func private @leafcb$cap(%cap: !eco.value, %x: i64) -> i64 {
    %k = arith.constant 3 : i64
    %y = eco.int.mul %x, %k : i64
    eco.return %y : i64
  }

  func.func @main(%xs: !eco.value, %f: !eco.value, %c: !eco.value) -> !eco.value attributes {eco.list_chunks} {
    %r = eco.list.map %xs, %f captures(%c : !eco.value) {callee = @leafcb$cap, in_kind = 1 : i64, out_kind = 1 : i64} : !eco.value
    eco.return %r : !eco.value
  }
}

// The direct call survives, unstatepointed.
// LEAF: call{{.*}}@"leafcb$cap"

// Cursor pickup: the chunk-edge allocation is gone. Safe unscoped — this
// fixture has one templated loop and nothing else that could project a tail.
// LEAF-NOT: eco_list_tail_hybrid
