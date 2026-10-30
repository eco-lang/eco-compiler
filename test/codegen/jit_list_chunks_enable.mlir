// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// XFAIL: cpp-review-bugs.md "eco_enable_list_chunks is missing from the JIT symbol map" -- not fixed yet
//
// The front end marks @main with `eco.list_chunks` (list chunks are on by default, Config.elm), and
// EcoToLLVM then makes main call eco_enable_list_chunks. buildRuntimeSymbolMap (RuntimeSymbols.cpp)
// does not register that symbol, so the JIT falls back to a process-symbol search. That works in
// test/test (built with ENABLE_EXPORTS), but ecoc exports no dynamic symbols, so `ecoc -emit=jit`
// on compiler output fails to resolve it. Fixtures run ecoc as a subprocess, so this hits the real
// binary.
//
// CHECK-NOT: Symbols not found
// CHECK: [eco.dbg] 7

module {
  func.func @main() -> i64 attributes {eco.list_chunks} {
    %c7 = arith.constant 7 : i64
    eco.dbg %c7 : i64
    %z = arith.constant 0 : i64
    return %z : i64
  }
}
