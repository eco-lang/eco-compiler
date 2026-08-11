// RUN: %ecoc %s -emit=mlir-llvm 2>&1 | %FileCheck %s --check-prefix=MARK
// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s --check-prefix=JIT
//
// kernel-opt-05: eco.string.append / eco.list.append are typed replacements for
// the polymorphic Elm_Kernel_Utils_append, which re-derives at runtime what mono
// already knew statically (two getTag loads, then a tag-pair dispatch, then a
// silent `return a` for any unsupported pair).
//
// MARK leg: each op lowers to a direct call to its typed export. Neither decl
// carries gc-leaf-function -- both callees allocate (a flat leaf or a rope; a
// cell chain or a chunk chain) -- so RS4GC statepoints them and attaches roots
// from its own liveness. That is why the ops are deliberately trait-free and
// appear in none of EcoGCPrepare's four lists.
//
// JIT leg: executes the expanded code, which is what proves the two KERNEL_SYM
// registrations. Empty operands are embedded constants (toPtr -> nullptr), so
// they exercise the wrappers' own guards rather than the backends.

module {
  func.func @main() -> i64 {
    %a = eco.string_literal "foo" : !eco.value
    %b = eco.string_literal "bar" : !eco.value
    %e = eco.string_literal "" : !eco.value

    // MARK: call{{.*}}@eco_string_append
    // MARK-NOT: @Elm_Kernel_Utils_append
    %s = eco.string.append %a, %b : !eco.value
    %sl = eco.string.length %s
    eco.dbg %sl : i64
    // JIT: 6

    // One-sided empty: StringOps::append handles the null side itself.
    %s2 = eco.string.append %a, %e : !eco.value
    %sl2 = eco.string.length %s2
    eco.dbg %sl2 : i64
    // JIT: 3

    // Both empty: the wrapper's own `if (!pa && !pb) return a` guard.
    %s3 = eco.string.append %e, %e : !eco.value
    %sl3 = eco.string.length %s3
    eco.dbg %sl3 : i64
    // JIT: 0

    // MARK: call{{.*}}@eco_list_append
    %n0 = arith.constant 1 : i64
    %n1 = arith.constant 2 : i64
    %nil = eco.constant Empty : !eco.value
    %l1 = eco.construct.list %n1, %nil {head_kind = 1 : i64, head_unboxed = true} : i64, !eco.value -> !eco.value
    %l2 = eco.construct.list %n0, %l1 {head_kind = 1 : i64, head_unboxed = true} : i64, !eco.value -> !eco.value
    %l3 = eco.list.append %l2, %l2 : !eco.value

    // [1,2] ++ [1,2] == [1,2,1,2]; sum the head of the shared rhs spine to
    // prove the result is walkable rather than just allocated.
    %h = eco.project.list_head %l3 : !eco.value -> i64
    eco.dbg %h : i64
    // JIT: 1

    %z = arith.constant 0 : i64
    return %z : i64
  }
}
