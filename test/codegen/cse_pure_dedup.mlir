// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// kernel-opt-10 Phase 1: values are UNCHANGED whether or not MLIR CSE merged
// structurally identical pure ops. Two textually identical constructs project
// to the same values with CSE on (one allocation) and off (two).
//
// (b) is the Phase-0.1 purity-audit regression lock: `eco.array.get` is [Pure]
// and CSE merges pure ops REGARDLESS of intervening effects, so this is only
// sound because every eco.array.* writer CLONES. `%v0` (get before set) and
// `%v1` (same get repeated after the set — CSE may merge it with %v0) must BOTH
// read the OLD value, and `%v2` (get on the set's result) the new one. This
// fixture fails loudly the day someone makes an array writer mutate in place
// while array.get keeps [Pure] — the fix then is dropping [Pure] for
// MemoryEffects<[MemRead]> in the same commit.

module {
  func.func @main() -> i64 {
    %c1 = arith.constant 1 : i64
    %c2 = arith.constant 2 : i64

    %b1 = eco.box %c1 : i64 -> !eco.value
    %b2 = eco.box %c2 : i64 -> !eco.value

    // (a) two identical constructs: CSE may merge the allocations; the
    // projected values must not change.
    %x = eco.construct.custom(%b1, %b2) {tag = 0 : i64, size = 2 : i64} : (!eco.value, !eco.value) -> !eco.value
    %y = eco.construct.custom(%b1, %b2) {tag = 0 : i64, size = 2 : i64} : (!eco.value, !eco.value) -> !eco.value

    %px = eco.project.custom %x[0] : !eco.value -> !eco.value
    %vx = eco.unbox %px : !eco.value -> i64
    eco.dbg %vx : i64
    // CHECK: [eco.dbg] 1

    %py = eco.project.custom %y[1] : !eco.value -> !eco.value
    %vy = eco.unbox %py : !eco.value -> i64
    eco.dbg %vy : i64
    // CHECK: [eco.dbg] 2

    // (b) the array clone invariant.
    %arr = eco.array.singleton %c1 : i64 -> !eco.value
    %i0 = arith.constant 0 : i64

    %v0 = eco.array.get %arr[%i0] : i64
    eco.dbg %v0 : i64
    // CHECK: [eco.dbg] 1

    %arr2 = eco.array.set %arr[%i0] = %c2 : i64

    // Identical to %v0's get: CSE may merge them across the set. Sound only
    // because array.set clones.
    %v1 = eco.array.get %arr[%i0] : i64
    eco.dbg %v1 : i64
    // CHECK: [eco.dbg] 1

    %v2 = eco.array.get %arr2[%i0] : i64
    eco.dbg %v2 : i64
    // CHECK: [eco.dbg] 2

    %z = arith.constant 0 : i64
    return %z : i64
  }
}
