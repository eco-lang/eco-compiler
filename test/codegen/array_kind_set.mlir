// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// HEAP_046: an array of Ints built from boxed values (eco.array.push of !eco.value operands, which lowers
// to elm_array_push_box) is an Int array holding them raw. eco.array.set of an i64 then stores into an
// array already of that kind, and every element reads back as its value after a minor collection.
// Before HEAP_046 was enforced, push_box built a kind-0 array of boxed Ints and eco.array.set relabelled
// the copy kind 1 without converting it: the untouched elements read back as pointer bits, and the
// collector stopped tracing their boxes.

module {
  llvm.func @eco_minor_gc()

  func.func @main() -> i64 {
    %c10 = arith.constant 10 : i64
    %c20 = arith.constant 20 : i64
    %c30 = arith.constant 30 : i64
    %c99 = arith.constant 99 : i64
    %b10 = eco.box %c10 : i64 -> !eco.value
    %b20 = eco.box %c20 : i64 -> !eco.value
    %b30 = eco.box %c30 : i64 -> !eco.value

    %e = eco.array.empty : !eco.value
    %a1 = eco.array.push %b10, %e : !eco.value -> !eco.value
    %a2 = eco.array.push %b20, %a1 : !eco.value -> !eco.value
    %a3 = eco.array.push %b30, %a2 : !eco.value -> !eco.value

    %i0 = arith.constant 0 : i64
    %i1 = arith.constant 1 : i64
    %i2 = arith.constant 2 : i64
    %s = eco.array.set %a3[%i1] = %c99 : i64

    llvm.call @eco_minor_gc() : () -> ()

    %v0 = eco.array.get %s[%i0] : i64
    eco.dbg %v0 : i64
    // CHECK: [eco.dbg] 10
    %v1 = eco.array.get %s[%i1] : i64
    eco.dbg %v1 : i64
    // CHECK: [eco.dbg] 99
    %v2 = eco.array.get %s[%i2] : i64
    eco.dbg %v2 : i64
    // CHECK: [eco.dbg] 30

    %z = arith.constant 0 : i64
    return %z : i64
  }
}
