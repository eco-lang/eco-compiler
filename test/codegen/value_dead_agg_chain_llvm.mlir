// RUN: %ecoc %s -emit=llvm -opt 2>&1 | %FileCheck %s
//
// Dead aggregate-chain sweep (T1.3.5 K-bootstrap forensics, 2026-08-03).
// The pre-RS4GC `$cap` AlwaysInliner prepass (runCapInlinePrepass, active
// whenever optLevel != None) folds extract(insertvalue) via InlineFunction's
// SimplifyInstruction while cloning a wrapper body, RAUWs the field values
// into the consumers, and leaves the cloned insertvalue chain behind DEAD.
// FoldExtractValuePass used to visit only ExtractValueInsts, so a chain
// with no surviving extracts was never deleted — and
// RewriteStatepointsForGC walks ALL instructions (live or not) and hits
// its "support for FCA unimplemented" assert on the dead chain's own
// aggregate operands. The pass now sweeps trivially-dead insertvalue
// chains after folding.
//
// True-to-life reproduction: a small `$cap`-named wrapper whose body is
// make + projections + an allocating consumer, called directly from
// another function. The prepass marks it alwaysinline (well under the
// size threshold), the AlwaysInliner splices it into the caller folding
// the projections, and the orphaned chain must then be swept before the
// serial RS4GC runs. Without the sweep this file aborts inside RS4GC.

module {
  func.func @probe_pair$cap(%a: !eco.value, %b: !eco.value) -> !eco.value {
    %agg = eco.make.tuple2 %a, %b : (!eco.value, !eco.value) -> !eco.tuple2<!eco.value, !eco.value>
    %x = eco.project.tuple2 %agg[0] : !eco.tuple2<!eco.value, !eco.value> -> !eco.value
    %y = eco.project.tuple2 %agg[1] : !eco.tuple2<!eco.value, !eco.value> -> !eco.value
    // Allocating op: forces a statepoint so RS4GC statepoints and walks
    // the caller after inlining.
    %c = eco.construct.tuple2 %x, %y : !eco.value, !eco.value -> !eco.value
    eco.return %c : !eco.value
  }

  func.func @probe_caller(%a: !eco.value, %b: !eco.value) -> !eco.value {
    %r = "eco.call"(%a, %b) {callee = @probe_pair$cap} : (!eco.value, !eco.value) -> !eco.value
    eco.return %r : !eco.value
  }
}

// Lowering must complete (no RS4GC "FCA unimplemented" abort) and no
// aggregate-with-gc-pointer chain may survive anywhere in the output:
// CHECK: define {{.*}}@probe_caller
// CHECK-NOT: insertvalue { ptr addrspace(1), ptr addrspace(1) }
