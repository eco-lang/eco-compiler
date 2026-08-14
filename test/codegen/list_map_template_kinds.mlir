// RUN: %ecoc %s -emit=mlir-llvm 2>&1 | %FileCheck %s --check-prefix=KIND
//
// plans/list-map-mlir-template.md / CGEN_078(d): `in_kind` and `out_kind` are
// INDEPENDENT 2-bit slot kinds, and the expansion derives the head-projection
// type, the scratch push variant and the finisher's kind from them alone.
//
// The kind-changing case is the one that catches a collapse: Int in, boxed
// out. If the expansion ever reused one kind for both axes (the `ListOps::take`
// defect class), the head would be projected at the wrong width or the result
// pushed through the wrong door. `push_scalar` is for unboxed results and
// `push_boxed` for `!eco.value` results — an Int→boxed map must use
// `push_boxed`, and an Int→Int map must use `push_scalar`.

module {
  func.func private @boxcb$cap(%cap: !eco.value, %x: i64) -> !eco.value {
    %s = eco.string_literal "v" : !eco.value
    eco.return %s : !eco.value
  }

  func.func private @intcb$cap(%cap: !eco.value, %x: i64) -> i64 {
    eco.return %x : i64
  }

  // Int elements -> boxed results: in_kind=1, out_kind=0 -> push_boxed.
  func.func @main(%xs: !eco.value, %f: !eco.value, %c: !eco.value) -> !eco.value attributes {eco.list_chunks} {
    %r = eco.list.map %xs, %f captures(%c : !eco.value) {callee = @boxcb$cap, in_kind = 1 : i64, out_kind = 0 : i64} : !eco.value
    eco.return %r : !eco.value
  }

  // Int elements -> Int results: in_kind=1, out_kind=1 -> push_scalar.
  func.func @scalar_out(%xs: !eco.value, %f: !eco.value, %c: !eco.value) -> !eco.value attributes {eco.list_chunks} {
    %r = eco.list.map %xs, %f captures(%c : !eco.value) {callee = @intcb$cap, in_kind = 1 : i64, out_kind = 1 : i64} : !eco.value
    eco.return %r : !eco.value
  }
}

// KIND-DAG: llvm.call @eco_scratch_push_boxed
// KIND-DAG: llvm.call @eco_scratch_push_scalar
// KIND-DAG: llvm.call @eco_scratch_finish_fwd
