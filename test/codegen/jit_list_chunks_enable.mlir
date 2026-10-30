// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// The front end marks @main with `eco.list_chunks` (list chunks are on by default, Config.elm), and
// EcoToLLVM then makes main call eco_enable_list_chunks. buildRuntimeSymbolMap (RuntimeSymbols.cpp)
// did not register that symbol (cpp-review-bugs.md, fixed 2026-10-30), so the JIT fell back to a
// process-symbol search: that works in test/test (built with ENABLE_EXPORTS), but ecoc exports no
// dynamic symbols, so `ecoc -emit=jit` on compiler output failed to resolve it. This line runs ecoc
// as a subprocess, so it uses the real binary. RuntimeSymbolMapTest checks the whole map.
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
