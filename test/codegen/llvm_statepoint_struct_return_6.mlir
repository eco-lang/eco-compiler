// LLVM-upstream regression probe.
// Run via test/codegen/run_llvm_statepoint_probes.sh (drives
// eco-boot-native -emit=obj through SelectionDAG).
//
//
// LLVM-upstream regression probe: a function with `gc "eco-gc"` calls a
// callee returning {i64×6}. After RS4GC wraps the call in
// `llvm.experimental.gc.statepoint.p0`, SelectionDAG must lower the resulting
// `llvm.experimental.gc.result.sl_i64...s` intrinsic. LLVM 21's
// StatepointLowering walks past the lowered call expecting CALLSEQ_END but
// finds the CopyFromReg-per-field chain for the struct result, asserting at
// StatepointLowering.cpp:354.
//
// N=1..3 pass; N=4..8 trip the assertion. This fixture documents the
// LLVM-version boundary. If LLVM is upgraded and the assertion is fixed
// upstream, the N=4..8 cases will start XPASSing — at that point bump
// `kMaxDirectFields` in EcoUnboxedAggCrossSpec.cpp accordingly.
module attributes {llvm.target_triple = "x86_64-unknown-linux-gnu"} {
  llvm.func @callee_6() -> !llvm.struct<(i64, i64, i64, i64, i64, i64)> attributes {garbageCollector = "eco-gc"} {
    %0 = llvm.mlir.poison : !llvm.struct<(i64, i64, i64, i64, i64, i64)>
    %1 = llvm.mlir.constant(1 : i64) : i64
    %2 = llvm.insertvalue %1, %0[0] : !llvm.struct<(i64, i64, i64, i64, i64, i64)>
    %3 = llvm.mlir.constant(2 : i64) : i64
    %4 = llvm.insertvalue %3, %2[1] : !llvm.struct<(i64, i64, i64, i64, i64, i64)>
    %5 = llvm.mlir.constant(3 : i64) : i64
    %6 = llvm.insertvalue %5, %4[2] : !llvm.struct<(i64, i64, i64, i64, i64, i64)>
    %7 = llvm.mlir.constant(4 : i64) : i64
    %8 = llvm.insertvalue %7, %6[3] : !llvm.struct<(i64, i64, i64, i64, i64, i64)>
    %9 = llvm.mlir.constant(5 : i64) : i64
    %10 = llvm.insertvalue %9, %8[4] : !llvm.struct<(i64, i64, i64, i64, i64, i64)>
    %11 = llvm.mlir.constant(6 : i64) : i64
    %12 = llvm.insertvalue %11, %10[5] : !llvm.struct<(i64, i64, i64, i64, i64, i64)>
    llvm.return %12 : !llvm.struct<(i64, i64, i64, i64, i64, i64)>
  }
  llvm.func @caller_6() -> i64 attributes {garbageCollector = "eco-gc"} {
    %r = llvm.call @callee_6() : () -> !llvm.struct<(i64, i64, i64, i64, i64, i64)>
    %x = llvm.extractvalue %r[0] : !llvm.struct<(i64, i64, i64, i64, i64, i64)>
    llvm.return %x : i64
  }
}
