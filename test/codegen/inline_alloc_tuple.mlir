// RUN: %ecoc %s -emit=mlir-llvm 2>&1 | %FileCheck %s --check-prefix=MARK
// RUN: %ecoc %s -emit=llvm 2>&1 | %FileCheck %s --check-prefix=EXP
// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s --check-prefix=JIT
//
// Inline nursery allocation (plans/inline-nursery-allocation.md, HEAP_034),
// N3.1: eco.construct.tuple2/tuple3 lower to the `__eco_alloc_inline` marker
// + ONE constant header-word store + fresh field stores — no runtime alloc
// call, no store calls. The marker is expanded by expandInlineAllocs
// (EcoBackend.cpp, pre-RS4GC) into the bump-pointer fast/slow diamond
// against eco_bump_state()'s {ptr, end}, with eco_alloc_inline_slow as the
// only statepoint. The JIT leg executes the expanded code end-to-end (and
// covers the RuntimeSymbols mappings for both new exports).

module {
  func.func @main() -> i64 {
    %a = arith.constant 42 : i64
    %f = arith.constant 2.5 : f64

    // (i64, f64): 2-bit kinds Int|Float -> mask 0b1001 = 9.
    // Header word = Tag_Tuple2(4) | 9<<10 | 24<<32.
    %t2 = eco.construct.tuple2 %a, %f {unboxed_bitmap = 9} : i64, f64 -> !eco.value
    %p0 = eco.project.tuple2 %t2[0] : !eco.value -> i64
    eco.dbg %p0 : i64
    // JIT: 42
    %p1 = eco.project.tuple2 %t2[1] : !eco.value -> f64
    eco.dbg %p1 : f64
    // JIT: 2.5

    // Boxed second slot (kind 00): the fresh store must go through the
    // REP_LLVM_002 barriered helper (eco.boxed_slot-tagged).
    %boxed = eco.box %a : i64 -> !eco.value
    %t2b = eco.construct.tuple2 %a, %boxed {unboxed_bitmap = 1} : i64, !eco.value -> !eco.value
    %q1 = eco.project.tuple2 %t2b[1] : !eco.value -> !eco.value
    %q1u = eco.unbox %q1 : !eco.value -> i64
    eco.dbg %q1u : i64
    // JIT: 42

    // Tuple3 (i64, i64, f64): kinds 01|01|10 -> mask 0b100101 = 37.
    %t3 = eco.construct.tuple3 %a, %p0, %f {unboxed_bitmap = 37} : i64, i64, f64 -> !eco.value
    %r2 = eco.project.tuple3 %t3[2] : !eco.value -> f64
    eco.dbg %r2 : f64
    // JIT: 2.5

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}

// ---- Marker level (pre-expansion MLIR-LLVM) --------------------------------
// MARK: llvm.func @main
// The tuple2 alloc is the marker + a constant header store; no runtime
// alloc/store calls survive for the converted classes.
// MARK: llvm.call @__eco_alloc_inline
// Header word for (i64,f64) tuple2: 4 | 9<<10 | 24<<32 = 103079224324.
// MARK: llvm.mlir.constant(103079224324 : i64)
// MARK-NOT: llvm.call @eco_alloc_tuple2_uninit
// MARK-NOT: llvm.call @eco_alloc_tuple3_uninit
// MARK-NOT: llvm.call @eco_store_tuple_field

// ---- Post-backend LLVM (expanded diamond) ----------------------------------
// EXP: define{{.*}}@main
// EXP: call ptr @eco_bump_state()
// EXP: load ptr addrspace(1)
// EXP: icmp ugt ptr addrspace(1)
// EXP: call ptr addrspace(1) @eco_alloc_inline_slow(i64 24)
// EXP: phi ptr addrspace(1)
// No marker survives the expansion; no ptrtoint appears in the diamond
// (the bump slots are loaded/stored AS ptr addrspace(1) — REP_LLVM_001).
// EXP-NOT: __eco_alloc_inline
