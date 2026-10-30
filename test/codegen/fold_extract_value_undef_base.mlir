// RUN: %ecoc %s -emit=llvm 2>&1 | %FileCheck %s
//
// FoldExtractValuePass: an extract of a field no insert wrote, at the base of an
// insertvalue chain on undef, folds to undef of the extract's type. The pass once
// returned UndefValue::get(nullptr) as a sentinel here, which dereferenced a null
// type and crashed the compiler (cpp-review-bugs.md).
//
// CHECK: define internal i64 @undefBase(
// CHECK-NEXT: ret i64 undef

module {
  llvm.func internal @undefBase(%a: i64) -> i64 attributes {garbageCollector = "eco-gc"} {
    %u = llvm.mlir.undef : !llvm.struct<(i64, i64)>
    %s = llvm.insertvalue %a, %u[0] : !llvm.struct<(i64, i64)>
    %r = llvm.extractvalue %s[1] : !llvm.struct<(i64, i64)>
    llvm.return %r : i64
  }
  func.func @main() -> i64 {
    %c = arith.constant 7 : i64
    %r = llvm.call @undefBase(%c) : (i64) -> i64
    return %r : i64
  }
}
