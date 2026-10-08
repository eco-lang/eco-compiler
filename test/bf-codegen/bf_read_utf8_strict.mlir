// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// bf.read.utf8 (the fused Bytes.Decode.string lowering -> elm_utf8_decode) is
// STRICT: it reads only the `len` bytes it is given and fails (ok = 0) on any
// truncated sequence, stray continuation / 0xF8+ lead, overlong form,
// surrogate or cp > U+10FFFF. The non-fused kernel decoder
// (Elm_Kernel_Bytes_read_string) must agree — see K8d and
// test/elm-bytes/src/DecodeStringStrict{Fused,Kernel}Test.elm.
//
// Each buffer is allocated with EXACTLY its bytes, so a truncated sequence
// ends at the end of the buffer. The harness matches CHECK lines in any order,
// so each case prints a distinct 4-digit code: 1000 + case_id * 10 + ok.

// case 1: truncated 2-byte at end of buffer [C3] -> ok = 0
// CHECK: [eco.dbg] 1010
// CHECK-NOT: [eco.dbg] 1011
// case 2: truncated inside range: [C3 A9], read 1 -> ok = 0
// CHECK: [eco.dbg] 1020
// CHECK-NOT: [eco.dbg] 1021
// case 3: truncated 4-byte at end of buffer [F0 9F 98] -> ok = 0
// CHECK: [eco.dbg] 1030
// CHECK-NOT: [eco.dbg] 1031
// case 4: ASCII then truncated [41 C3] -> ok = 0
// CHECK: [eco.dbg] 1040
// CHECK-NOT: [eco.dbg] 1041
// case 5: stray continuation [80] -> ok = 0
// CHECK: [eco.dbg] 1050
// CHECK-NOT: [eco.dbg] 1051
// case 6: invalid lead [F8] -> ok = 0
// CHECK: [eco.dbg] 1060
// CHECK-NOT: [eco.dbg] 1061
// case 7: overlong 2-byte [C0 80] -> ok = 0
// CHECK: [eco.dbg] 1070
// CHECK-NOT: [eco.dbg] 1071
// case 8: surrogate [ED A0 80] -> ok = 0
// CHECK: [eco.dbg] 1080
// CHECK-NOT: [eco.dbg] 1081
// case 9: above U+10FFFF [F4 90 80 80] -> ok = 0
// CHECK: [eco.dbg] 1090
// CHECK-NOT: [eco.dbg] 1091
// case 10: bad continuation [C3 41] -> ok = 0
// CHECK: [eco.dbg] 1100
// CHECK-NOT: [eco.dbg] 1101
// case 11: control: [C3 A9] read 2 = U+00E9 -> ok = 1
// CHECK: [eco.dbg] 1111
// CHECK-NOT: [eco.dbg] 1110
// case 12: control: [F0 9F 98 80] read 4 = U+1F600 -> ok = 1
// CHECK: [eco.dbg] 1121
// CHECK-NOT: [eco.dbg] 1120
// case 13: bounds guard the fused decoder emits first: require 2 of a 1-byte buffer -> 0
// CHECK: [eco.dbg] 1130
// CHECK-NOT: [eco.dbg] 1131

module {
  func.func @main() -> i64 {
    // case 1: truncated 2-byte at end of buffer [C3]
    %c1_size = arith.constant 1 : i32
    %c1_buf = bf.alloc %c1_size : !eco.value
    %c1_w0 = bf.cursor.init %c1_buf : !eco.value -> !bf.cursor
    %c1_b0 = arith.constant 195 : i64
    %c1_w1 = bf.write.u8 %c1_w0, %c1_b0 : !bf.cursor
    %c1_r0 = bf.decoder.cursor.init %c1_buf : !eco.value -> !bf.cursor
    %c1_len = arith.constant 1 : i32
    %c1_str, %c1_r1, %c1_ok = bf.read.utf8 %c1_r0, %c1_len : !eco.value, !bf.cursor, i1
    %c1_ok64 = arith.extui %c1_ok : i1 to i64
    %c1_base = arith.constant 1010 : i64
    %c1_code = arith.addi %c1_base, %c1_ok64 : i64
    eco.dbg %c1_code : i64

    // case 2: truncated inside range: [C3 A9], read 1
    %c2_size = arith.constant 2 : i32
    %c2_buf = bf.alloc %c2_size : !eco.value
    %c2_w0 = bf.cursor.init %c2_buf : !eco.value -> !bf.cursor
    %c2_b0 = arith.constant 195 : i64
    %c2_w1 = bf.write.u8 %c2_w0, %c2_b0 : !bf.cursor
    %c2_b1 = arith.constant 169 : i64
    %c2_w2 = bf.write.u8 %c2_w1, %c2_b1 : !bf.cursor
    %c2_r0 = bf.decoder.cursor.init %c2_buf : !eco.value -> !bf.cursor
    %c2_len = arith.constant 1 : i32
    %c2_str, %c2_r1, %c2_ok = bf.read.utf8 %c2_r0, %c2_len : !eco.value, !bf.cursor, i1
    %c2_ok64 = arith.extui %c2_ok : i1 to i64
    %c2_base = arith.constant 1020 : i64
    %c2_code = arith.addi %c2_base, %c2_ok64 : i64
    eco.dbg %c2_code : i64

    // case 3: truncated 4-byte at end of buffer [F0 9F 98]
    %c3_size = arith.constant 3 : i32
    %c3_buf = bf.alloc %c3_size : !eco.value
    %c3_w0 = bf.cursor.init %c3_buf : !eco.value -> !bf.cursor
    %c3_b0 = arith.constant 240 : i64
    %c3_w1 = bf.write.u8 %c3_w0, %c3_b0 : !bf.cursor
    %c3_b1 = arith.constant 159 : i64
    %c3_w2 = bf.write.u8 %c3_w1, %c3_b1 : !bf.cursor
    %c3_b2 = arith.constant 152 : i64
    %c3_w3 = bf.write.u8 %c3_w2, %c3_b2 : !bf.cursor
    %c3_r0 = bf.decoder.cursor.init %c3_buf : !eco.value -> !bf.cursor
    %c3_len = arith.constant 3 : i32
    %c3_str, %c3_r1, %c3_ok = bf.read.utf8 %c3_r0, %c3_len : !eco.value, !bf.cursor, i1
    %c3_ok64 = arith.extui %c3_ok : i1 to i64
    %c3_base = arith.constant 1030 : i64
    %c3_code = arith.addi %c3_base, %c3_ok64 : i64
    eco.dbg %c3_code : i64

    // case 4: ASCII then truncated [41 C3]
    %c4_size = arith.constant 2 : i32
    %c4_buf = bf.alloc %c4_size : !eco.value
    %c4_w0 = bf.cursor.init %c4_buf : !eco.value -> !bf.cursor
    %c4_b0 = arith.constant 65 : i64
    %c4_w1 = bf.write.u8 %c4_w0, %c4_b0 : !bf.cursor
    %c4_b1 = arith.constant 195 : i64
    %c4_w2 = bf.write.u8 %c4_w1, %c4_b1 : !bf.cursor
    %c4_r0 = bf.decoder.cursor.init %c4_buf : !eco.value -> !bf.cursor
    %c4_len = arith.constant 2 : i32
    %c4_str, %c4_r1, %c4_ok = bf.read.utf8 %c4_r0, %c4_len : !eco.value, !bf.cursor, i1
    %c4_ok64 = arith.extui %c4_ok : i1 to i64
    %c4_base = arith.constant 1040 : i64
    %c4_code = arith.addi %c4_base, %c4_ok64 : i64
    eco.dbg %c4_code : i64

    // case 5: stray continuation [80]
    %c5_size = arith.constant 1 : i32
    %c5_buf = bf.alloc %c5_size : !eco.value
    %c5_w0 = bf.cursor.init %c5_buf : !eco.value -> !bf.cursor
    %c5_b0 = arith.constant 128 : i64
    %c5_w1 = bf.write.u8 %c5_w0, %c5_b0 : !bf.cursor
    %c5_r0 = bf.decoder.cursor.init %c5_buf : !eco.value -> !bf.cursor
    %c5_len = arith.constant 1 : i32
    %c5_str, %c5_r1, %c5_ok = bf.read.utf8 %c5_r0, %c5_len : !eco.value, !bf.cursor, i1
    %c5_ok64 = arith.extui %c5_ok : i1 to i64
    %c5_base = arith.constant 1050 : i64
    %c5_code = arith.addi %c5_base, %c5_ok64 : i64
    eco.dbg %c5_code : i64

    // case 6: invalid lead [F8]
    %c6_size = arith.constant 1 : i32
    %c6_buf = bf.alloc %c6_size : !eco.value
    %c6_w0 = bf.cursor.init %c6_buf : !eco.value -> !bf.cursor
    %c6_b0 = arith.constant 248 : i64
    %c6_w1 = bf.write.u8 %c6_w0, %c6_b0 : !bf.cursor
    %c6_r0 = bf.decoder.cursor.init %c6_buf : !eco.value -> !bf.cursor
    %c6_len = arith.constant 1 : i32
    %c6_str, %c6_r1, %c6_ok = bf.read.utf8 %c6_r0, %c6_len : !eco.value, !bf.cursor, i1
    %c6_ok64 = arith.extui %c6_ok : i1 to i64
    %c6_base = arith.constant 1060 : i64
    %c6_code = arith.addi %c6_base, %c6_ok64 : i64
    eco.dbg %c6_code : i64

    // case 7: overlong 2-byte [C0 80]
    %c7_size = arith.constant 2 : i32
    %c7_buf = bf.alloc %c7_size : !eco.value
    %c7_w0 = bf.cursor.init %c7_buf : !eco.value -> !bf.cursor
    %c7_b0 = arith.constant 192 : i64
    %c7_w1 = bf.write.u8 %c7_w0, %c7_b0 : !bf.cursor
    %c7_b1 = arith.constant 128 : i64
    %c7_w2 = bf.write.u8 %c7_w1, %c7_b1 : !bf.cursor
    %c7_r0 = bf.decoder.cursor.init %c7_buf : !eco.value -> !bf.cursor
    %c7_len = arith.constant 2 : i32
    %c7_str, %c7_r1, %c7_ok = bf.read.utf8 %c7_r0, %c7_len : !eco.value, !bf.cursor, i1
    %c7_ok64 = arith.extui %c7_ok : i1 to i64
    %c7_base = arith.constant 1070 : i64
    %c7_code = arith.addi %c7_base, %c7_ok64 : i64
    eco.dbg %c7_code : i64

    // case 8: surrogate [ED A0 80]
    %c8_size = arith.constant 3 : i32
    %c8_buf = bf.alloc %c8_size : !eco.value
    %c8_w0 = bf.cursor.init %c8_buf : !eco.value -> !bf.cursor
    %c8_b0 = arith.constant 237 : i64
    %c8_w1 = bf.write.u8 %c8_w0, %c8_b0 : !bf.cursor
    %c8_b1 = arith.constant 160 : i64
    %c8_w2 = bf.write.u8 %c8_w1, %c8_b1 : !bf.cursor
    %c8_b2 = arith.constant 128 : i64
    %c8_w3 = bf.write.u8 %c8_w2, %c8_b2 : !bf.cursor
    %c8_r0 = bf.decoder.cursor.init %c8_buf : !eco.value -> !bf.cursor
    %c8_len = arith.constant 3 : i32
    %c8_str, %c8_r1, %c8_ok = bf.read.utf8 %c8_r0, %c8_len : !eco.value, !bf.cursor, i1
    %c8_ok64 = arith.extui %c8_ok : i1 to i64
    %c8_base = arith.constant 1080 : i64
    %c8_code = arith.addi %c8_base, %c8_ok64 : i64
    eco.dbg %c8_code : i64

    // case 9: above U+10FFFF [F4 90 80 80]
    %c9_size = arith.constant 4 : i32
    %c9_buf = bf.alloc %c9_size : !eco.value
    %c9_w0 = bf.cursor.init %c9_buf : !eco.value -> !bf.cursor
    %c9_b0 = arith.constant 244 : i64
    %c9_w1 = bf.write.u8 %c9_w0, %c9_b0 : !bf.cursor
    %c9_b1 = arith.constant 144 : i64
    %c9_w2 = bf.write.u8 %c9_w1, %c9_b1 : !bf.cursor
    %c9_b2 = arith.constant 128 : i64
    %c9_w3 = bf.write.u8 %c9_w2, %c9_b2 : !bf.cursor
    %c9_b3 = arith.constant 128 : i64
    %c9_w4 = bf.write.u8 %c9_w3, %c9_b3 : !bf.cursor
    %c9_r0 = bf.decoder.cursor.init %c9_buf : !eco.value -> !bf.cursor
    %c9_len = arith.constant 4 : i32
    %c9_str, %c9_r1, %c9_ok = bf.read.utf8 %c9_r0, %c9_len : !eco.value, !bf.cursor, i1
    %c9_ok64 = arith.extui %c9_ok : i1 to i64
    %c9_base = arith.constant 1090 : i64
    %c9_code = arith.addi %c9_base, %c9_ok64 : i64
    eco.dbg %c9_code : i64

    // case 10: bad continuation [C3 41]
    %c10_size = arith.constant 2 : i32
    %c10_buf = bf.alloc %c10_size : !eco.value
    %c10_w0 = bf.cursor.init %c10_buf : !eco.value -> !bf.cursor
    %c10_b0 = arith.constant 195 : i64
    %c10_w1 = bf.write.u8 %c10_w0, %c10_b0 : !bf.cursor
    %c10_b1 = arith.constant 65 : i64
    %c10_w2 = bf.write.u8 %c10_w1, %c10_b1 : !bf.cursor
    %c10_r0 = bf.decoder.cursor.init %c10_buf : !eco.value -> !bf.cursor
    %c10_len = arith.constant 2 : i32
    %c10_str, %c10_r1, %c10_ok = bf.read.utf8 %c10_r0, %c10_len : !eco.value, !bf.cursor, i1
    %c10_ok64 = arith.extui %c10_ok : i1 to i64
    %c10_base = arith.constant 1100 : i64
    %c10_code = arith.addi %c10_base, %c10_ok64 : i64
    eco.dbg %c10_code : i64

    // case 11: control: [C3 A9] read 2 = U+00E9
    %c11_size = arith.constant 2 : i32
    %c11_buf = bf.alloc %c11_size : !eco.value
    %c11_w0 = bf.cursor.init %c11_buf : !eco.value -> !bf.cursor
    %c11_b0 = arith.constant 195 : i64
    %c11_w1 = bf.write.u8 %c11_w0, %c11_b0 : !bf.cursor
    %c11_b1 = arith.constant 169 : i64
    %c11_w2 = bf.write.u8 %c11_w1, %c11_b1 : !bf.cursor
    %c11_r0 = bf.decoder.cursor.init %c11_buf : !eco.value -> !bf.cursor
    %c11_len = arith.constant 2 : i32
    %c11_str, %c11_r1, %c11_ok = bf.read.utf8 %c11_r0, %c11_len : !eco.value, !bf.cursor, i1
    %c11_ok64 = arith.extui %c11_ok : i1 to i64
    %c11_base = arith.constant 1110 : i64
    %c11_code = arith.addi %c11_base, %c11_ok64 : i64
    eco.dbg %c11_code : i64

    // case 12: control: [F0 9F 98 80] read 4 = U+1F600
    %c12_size = arith.constant 4 : i32
    %c12_buf = bf.alloc %c12_size : !eco.value
    %c12_w0 = bf.cursor.init %c12_buf : !eco.value -> !bf.cursor
    %c12_b0 = arith.constant 240 : i64
    %c12_w1 = bf.write.u8 %c12_w0, %c12_b0 : !bf.cursor
    %c12_b1 = arith.constant 159 : i64
    %c12_w2 = bf.write.u8 %c12_w1, %c12_b1 : !bf.cursor
    %c12_b2 = arith.constant 152 : i64
    %c12_w3 = bf.write.u8 %c12_w2, %c12_b2 : !bf.cursor
    %c12_b3 = arith.constant 128 : i64
    %c12_w4 = bf.write.u8 %c12_w3, %c12_b3 : !bf.cursor
    %c12_r0 = bf.decoder.cursor.init %c12_buf : !eco.value -> !bf.cursor
    %c12_len = arith.constant 4 : i32
    %c12_str, %c12_r1, %c12_ok = bf.read.utf8 %c12_r0, %c12_len : !eco.value, !bf.cursor, i1
    %c12_ok64 = arith.extui %c12_ok : i1 to i64
    %c12_base = arith.constant 1120 : i64
    %c12_code = arith.addi %c12_base, %c12_ok64 : i64
    eco.dbg %c12_code : i64

    // case 13: bounds guard
    %c13_size = arith.constant 1 : i32
    %c13_buf = bf.alloc %c13_size : !eco.value
    %c13_r0 = bf.decoder.cursor.init %c13_buf : !eco.value -> !bf.cursor
    %c13_need = arith.constant 2 : i32
    %c13_ok = bf.require %c13_r0, %c13_need : i1
    %c13_ok64 = arith.extui %c13_ok : i1 to i64
    %c13_base = arith.constant 1130 : i64
    %c13_code = arith.addi %c13_base, %c13_ok64 : i64
    eco.dbg %c13_code : i64

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
