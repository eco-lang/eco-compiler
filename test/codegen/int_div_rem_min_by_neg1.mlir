// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// MIN_INT divided by -1 (found while triaging SD-21 / the CHECK-order test gap
// in plans/review-bug-list-fixes.md). IntDivOpLowering (and the remainderBy / modBy
// lowerings) guard only rhs == 0, so `sdiv`/`srem` MIN_INT, -1 is LLVM
// immediate UB: the folded result is poison and eco.dbg prints whatever is in
// the register (a different garbage value on every run). With runtime operands,
// x86 idiv would raise SIGFPE instead (not exercised here).
//
// arithmetic_int_minmax.mlir already computes MIN_INT // -1 and prints garbage,
// but its expected text for that line (-9223372036854775808) is satisfied by
// an EARLIER output line because the harness matches CHECK lines in any order, so
// it passes. Here the three results are chained with CHECK-NEXT and anchored
// with {{$}} so each line is checked where it is printed.
//
// Expected (wrapping two's complement, as arithmetic_int_minmax.mlir expects):
//   MIN_INT // -1          = MIN_INT
//   remainderBy -1 MIN_INT = 0
//   modBy -1 MIN_INT       = 0

module {
  func.func @main() -> i64 {
    %min_int = arith.constant -9223372036854775808 : i64
    %neg1 = arith.constant -1 : i64
    %marker = arith.constant 4242 : i64

    eco.dbg %marker : i64

    %d = eco.int.div %min_int, %neg1 : i64
    eco.dbg %d : i64

    %r = eco.int.remainderby %neg1, %min_int : i64
    eco.dbg %r : i64

    %m = eco.int.modby %neg1, %min_int : i64
    eco.dbg %m : i64

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}

// CHECK: [eco.dbg] 4242{{$}}
// CHECK-NEXT: [eco.dbg] -9223372036854775808{{$}}
// CHECK-NEXT: [eco.dbg] 0{{$}}
// CHECK-NEXT: [eco.dbg] 0{{$}}
