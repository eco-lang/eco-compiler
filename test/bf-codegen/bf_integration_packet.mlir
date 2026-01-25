// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test encode/decode full packet structure:
// [version: u8] [flags: u8] [payload_len: u16] [payload: bytes] [checksum: u32]

module {
  func.func @main() -> i64 {
    // Encode packet
    %size = arith.constant 32 : i32
    %buffer = bf.alloc %size : i64
    %c0 = bf.cursor.init %buffer : i64 -> !bf.cursor

    // Write header
    %version = arith.constant 1 : i64
    %c1 = bf.write.u8 %c0, %version : !bf.cursor

    %flags = arith.constant 0x42 : i64
    %c2 = bf.write.u8 %c1, %flags : !bf.cursor

    %payload_len = arith.constant 4 : i64
    %c3 = bf.write.u16 %c2, %payload_len (be) : !bf.cursor

    // Write 4-byte payload
    %p1 = arith.constant 0xDE : i64
    %c4 = bf.write.u8 %c3, %p1 : !bf.cursor
    %p2 = arith.constant 0xAD : i64
    %c5 = bf.write.u8 %c4, %p2 : !bf.cursor
    %p3 = arith.constant 0xBE : i64
    %c6 = bf.write.u8 %c5, %p3 : !bf.cursor
    %p4 = arith.constant 0xEF : i64
    %c7 = bf.write.u8 %c6, %p4 : !bf.cursor

    // Write checksum
    %checksum = arith.constant 0x12345678 : i64
    %c8 = bf.write.u32 %c7, %checksum (be) : !bf.cursor

    // Decode packet
    %rc0 = bf.decoder.cursor.init %buffer : i64 -> !bf.cursor
    %r_version, %rc1 = bf.read.u8 %rc0 : i64, !bf.cursor
    %r_flags, %rc2 = bf.read.u8 %rc1 : i64, !bf.cursor
    %r_payload_len, %rc3 = bf.read.u16 %rc2 (be) : i64, !bf.cursor

    // Read payload bytes
    %rp1, %rc4 = bf.read.u8 %rc3 : i64, !bf.cursor
    %rp2, %rc5 = bf.read.u8 %rc4 : i64, !bf.cursor
    %rp3, %rc6 = bf.read.u8 %rc5 : i64, !bf.cursor
    %rp4, %rc7 = bf.read.u8 %rc6 : i64, !bf.cursor

    %r_checksum, %rc8 = bf.read.u32 %rc7 (be) : i64, !bf.cursor

    eco.dbg %r_version : i64
    // CHECK: 1
    eco.dbg %r_flags : i64
    // CHECK: 66
    eco.dbg %r_payload_len : i64
    // CHECK: 4
    eco.dbg %r_checksum : i64
    // CHECK: 305419896

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
