// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// eco.constant.spare (CGEN_089) and eco.is_word (CGEN_090), plans/constructor-representation-followups.md F2:
// a spare word is the Empty constant with a level in null_cons_idx (HEAP_085), and eco.is_word is true
// exactly for the one word it names. Spare words of different levels, Empty and the null-cons word of the
// same index are all different words. A spare word survives a minor collection inside a heap object (the
// GC skips any ptr_ind word), and a `select` of two constants, which LLVM may fold into an inttoptr of a
// constant, passes EcoPtrIntVerify.

module {
  llvm.func @eco_minor_gc()

  func.func @main() -> i64 {
    %empty = eco.constant Empty : !eco.value
    %s1 = eco.constant.spare 1 : !eco.value
    %s2 = eco.constant.spare 2 : !eco.value
    %nc1 = eco.constant.null_cons 1 : !eco.value
    %i = arith.constant 7 : i64
    %boxed = eco.box %i : i64 -> !eco.value

    // A spare word is a constant word: eco.is_constant holds for it.
    %k = eco.is_constant %s1 : !eco.value -> i1
    %ki = arith.extui %k : i1 to i64
    eco.dbg %ki : i64
    // CHECK: 1

    // eco.is_word [2, 1] (the level-1 spare word) holds only for %s1.
    %a = eco.is_word %s1 [2, 1] : !eco.value -> i1
    %b = eco.is_word %empty [2, 1] : !eco.value -> i1
    %c = eco.is_word %s2 [2, 1] : !eco.value -> i1
    %d = eco.is_word %nc1 [2, 1] : !eco.value -> i1
    %e = eco.is_word %boxed [2, 1] : !eco.value -> i1
    %ai = arith.extui %a : i1 to i64
    %bi = arith.extui %b : i1 to i64
    %ci = arith.extui %c : i1 to i64
    %di = arith.extui %d : i1 to i64
    %ei = arith.extui %e : i1 to i64
    eco.dbg %ai : i64
    // CHECK: 1
    eco.dbg %bi : i64
    // CHECK: 0
    eco.dbg %ci : i64
    // CHECK: 0
    eco.dbg %di : i64
    // CHECK: 0
    eco.dbg %ei : i64
    // CHECK: 0

    // eco.is_word [2, 0] is the Empty word exactly; [3, 1] the null-cons word of index 1 exactly.
    %f = eco.is_word %empty [2, 0] : !eco.value -> i1
    %g = eco.is_word %s1 [2, 0] : !eco.value -> i1
    %h = eco.is_word %nc1 [3, 1] : !eco.value -> i1
    %j = eco.is_word %s1 [3, 1] : !eco.value -> i1
    %fi = arith.extui %f : i1 to i64
    %gi = arith.extui %g : i1 to i64
    %hi = arith.extui %h : i1 to i64
    %ji = arith.extui %j : i1 to i64
    eco.dbg %fi : i64
    // CHECK: 1
    eco.dbg %gi : i64
    // CHECK: 0
    eco.dbg %hi : i64
    // CHECK: 1
    eco.dbg %ji : i64
    // CHECK: 0

    // A select of two spare words (EcoPtrIntVerify accepts the constant words).
    %t = arith.constant true
    %sel = arith.select %t, %s2, %s1 : !eco.value
    %m = eco.is_word %sel [2, 2] : !eco.value -> i1
    %mi = arith.extui %m : i1 to i64
    eco.dbg %mi : i64
    // CHECK: 1

    // Stored in a heap object across a minor collection, the spare word comes back unchanged.
    %obj = eco.construct.custom(%s2, %boxed) <{slot_kinds = array<i8: 0, 0>, tag = 0 : i64, size = 2 : i64}> : (!eco.value, !eco.value) -> !eco.value
    llvm.call @eco_minor_gc() : () -> ()
    %back = eco.project.custom %obj[0] : !eco.value -> !eco.value
    %n = eco.is_word %back [2, 2] : !eco.value -> i1
    %ni = arith.extui %n : i1 to i64
    eco.dbg %ni : i64
    // CHECK: 1

    %r = arith.constant 0 : i64
    return %r : i64
  }
}
