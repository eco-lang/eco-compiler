// RUN: %ecoc %s -emit=llvm 2>&1 | %FileCheck %s
//
// FoldExtractValuePass: folding %c (block ^use, first in layout) deletes the dead
// chain %b, and with it %a, an extract still queued because its block ^def comes
// later in layout. The work list once held raw pointers and the pass then read the
// freed %a, crashing the compiler; it now holds weak handles.
//
// CHECK: define internal i64 @queuedFreed(
// CHECK: ret i64 %1

module {
  llvm.func internal @queuedFreed(%x: !llvm.struct<(i64, i64)>, %d: i64) -> i64 attributes {garbageCollector = "eco-gc"} {
    llvm.br ^def
  ^use:
    %c = llvm.extractvalue %b[0] : !llvm.struct<(i64, i64)>
    llvm.return %c : i64
  ^def:
    %a = llvm.extractvalue %x[0] : !llvm.struct<(i64, i64)>
    %u = llvm.mlir.undef : !llvm.struct<(i64, i64)>
    %y = llvm.insertvalue %d, %u[0] : !llvm.struct<(i64, i64)>
    %b = llvm.insertvalue %a, %y[1] : !llvm.struct<(i64, i64)>
    llvm.br ^use
  }
  func.func @main() -> i64 {
    %c = arith.constant 7 : i64
    return %c : i64
  }
}
