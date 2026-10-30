// RUN: %ecoc %s -emit=llvm 2>&1 | %FileCheck %s
//
// FoldExtractValuePass: an insertvalue at [0] writes the whole sub-aggregate that
// holds field [0, 1], so an extract of [0, 1] reads the newer sub-aggregate's field
// (%b, argument %0), not the older insert at [0, 1] (%c, argument %1). The pass once
// passed over prefix inserts and returned the stale value: a silent miscompile.
//
// CHECK: define internal i64 @prefixInsert(i64 %0, i64 %1)
// CHECK-NEXT: ret i64 %0

module {
  llvm.func internal @prefixInsert(%b: i64, %c: i64) -> i64 attributes {garbageCollector = "eco-gc"} {
    %u = llvm.mlir.undef : !llvm.struct<(struct<(i64, i64)>, i64)>
    %ui = llvm.mlir.undef : !llvm.struct<(i64, i64)>
    %in = llvm.insertvalue %b, %ui[1] : !llvm.struct<(i64, i64)>
    %s0 = llvm.insertvalue %c, %u[0, 1] : !llvm.struct<(struct<(i64, i64)>, i64)>
    %s1 = llvm.insertvalue %in, %s0[0] : !llvm.struct<(struct<(i64, i64)>, i64)>
    %r = llvm.extractvalue %s1[0, 1] : !llvm.struct<(struct<(i64, i64)>, i64)>
    llvm.return %r : i64
  }
  func.func @main() -> i64 {
    %b = arith.constant 7 : i64
    %c = arith.constant 9 : i64
    %r = llvm.call @prefixInsert(%b, %c) : (i64, i64) -> i64
    return %r : i64
  }
}
