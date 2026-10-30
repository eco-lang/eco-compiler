// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// XFAIL: cpp-review-bugs.md "elm_utf8_decode has no bounds check" (latent part: bf.require passes a negative length) -- not fixed yet
//
// RequireOpLowering (BFToLLVM.cpp) computes end = GEP(ptr, len) with len an i32 and tests
// `end ule buffer end`. A negative length sign-extends, so the "end" lies BEFORE the cursor and the
// check passes. A read guarded by it then reads with that length: with Bytes.Decode.string fused
// (it does not fuse today, see test/elm-bytes/src/DecodeStringStrictFusedTest.elm),
// `signedInt32 BE |> andThen string` over FF FF FF FF would call elm_utf8_decode with length
// 0xFFFFFFFF and read far out of bounds. Length prefixes of LenI8/LenI16/LenI32, or a LenU32 of 2^31
// or more truncated to i32, all reach it. bf_require_zero.mlir and bf_require_fail.mlir are the
// controls.
//
// The correct result: requiring -1 bytes fails (0).
//
// CHECK: [eco.dbg] 0

module {
  func.func @main() -> i64 {
    %size = arith.constant 4 : i32
    %buffer = bf.alloc %size : !eco.value
    %cursor = bf.decoder.cursor.init %buffer : !eco.value -> !bf.cursor

    %neg = arith.constant -1 : i32
    %ok = bf.require %cursor, %neg : i1

    %ok_int = arith.extui %ok : i1 to i64
    eco.dbg %ok_int : i64

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
