// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// SD-22 (review-bug-list.md): a bf.cursor is a pair of RAW pointers into the
// ByteBuffer body ({ptr, end}, BFOPS_025). A buffer under the 8 KiB large-
// object threshold is allocated in the nursery (allocByteBufferBlank), and
// fused code allocates while a cursor is live: every cons cell of a fused
// decode loop, the new buffer of bf.read.bytes (allocated BEFORE the memcpy
// from the old cursor pointer), the string of bf.read.utf8 (elm_utf8_decode
// allocates between its validate and copy passes), and any value expression
// of a fused encoder compiled after bf.alloc. Any of those may run a minor
// GC, which moves the buffer; nothing re-derives the cursor afterwards.
//
// This fixture makes that GC explicit (eco_minor_gc at the point where fused
// code would allocate) and then keeps using the cursors:
//   A. decoder: bf.decoder.cursor.init, minor GC, bf.read.u8 x4 -> must
//      still read 0x11 0x22 0x33 0x44 (printed as 2017, 2034, 2051, 2068).
//   B. decoder: bf.read.bytes through the stale cursor -> first byte must
//      still be 0x11 (printed as 3017).
//   C. encoder: bf.cursor.init, two writes, minor GC, two more writes, then
//      read the (moved) buffer through a fresh cursor -> must hold all four
//      bytes 0xA1 0xA2 0xA3 0xA4 (printed as 4161 .. 4164).
// Each GC point runs two minor GCs (one is enough under the region nursery,
// the legacy semi-space nursery needs two), and then the fixture allocates
// and fills 260 fresh 16-byte nursery buffers with 0xEE, which reuse the
// evacuated nursery memory the stale cursors point at.
// The buffers stay live (bf.bytes_width at the end), so the GC moves them
// rather than freeing them.
//
// Observed 2026-10-24 (ecoc -emit=jit, both ECO_NURSERY_REGIONS=1 and =0):
// 2014 2000 2000 2000 3014 4161 4162 4000 4000.
//
// Fixed 2026-10-24 (BFOPS_039): BFToLLVM re-derives every cursor live across
// an op that may collect (bf.cursor.offsets / bf.cursor.rebase), and
// bf.read.bytes re-derives its source pointer after its own allocation.

// CHECK: [eco.dbg] 2017
// CHECK: [eco.dbg] 2034
// CHECK: [eco.dbg] 2051
// CHECK: [eco.dbg] 2068
// CHECK: [eco.dbg] 3017
// CHECK: [eco.dbg] 4161
// CHECK: [eco.dbg] 4162
// CHECK: [eco.dbg] 4163
// CHECK: [eco.dbg] 4164

module {
  llvm.func @eco_minor_gc()

  func.func @fill_ee() -> !eco.value {
    %n = arith.constant 16 : i32
    %b = bf.alloc %n : !eco.value
    %c0 = bf.cursor.init %b : !eco.value -> !bf.cursor
    %v = arith.constant 4008636142 : i64
    %c1 = bf.write.u32 %c0, %v (le) : !bf.cursor
    %c2 = bf.write.u32 %c1, %v (le) : !bf.cursor
    %c3 = bf.write.u32 %c2, %v (le) : !bf.cursor
    %c4 = bf.write.u32 %c3, %v (le) : !bf.cursor
    return %b : !eco.value
  }

  // Allocates and fills %n 16-byte buffers (garbage once returned).
  func.func @fill_n(%n: i64) -> i64 {
    %z = arith.constant 0 : i64
    %one = arith.constant 1 : i64
    %done = arith.cmpi sle, %n, %z : i64
    %r = scf.if %done -> i64 {
      scf.yield %z : i64
    } else {
      %b = func.call @fill_ee() : () -> !eco.value
      %m = arith.subi %n, %one : i64
      %x = func.call @fill_n(%m) : (i64) -> i64
      scf.yield %x : i64
    }
    return %r : i64
  }

  func.func @main() -> i64 {
    %nfill = arith.constant 256 : i64
    // ---- A/B: decoder cursor across a minor GC ----
    %size = arith.constant 16 : i32
    %buf = bf.alloc %size : !eco.value
    %w0 = bf.cursor.init %buf : !eco.value -> !bf.cursor
    %v11 = arith.constant 17 : i64
    %v22 = arith.constant 34 : i64
    %v33 = arith.constant 51 : i64
    %v44 = arith.constant 68 : i64
    %w1 = bf.write.u8 %w0, %v11 : !bf.cursor
    %w2 = bf.write.u8 %w1, %v22 : !bf.cursor
    %w3 = bf.write.u8 %w2, %v33 : !bf.cursor
    %w4 = bf.write.u8 %w3, %v44 : !bf.cursor

    %r0 = bf.decoder.cursor.init %buf : !eco.value -> !bf.cursor
    %rb0 = bf.decoder.cursor.init %buf : !eco.value -> !bf.cursor

    // A GC point inside fused code (a cons cell, a read.bytes buffer, ...).
    // Two minors: under the region nursery (HEAP_069) one is enough for the
    // evacuated memory to be reused at once; the legacy semi-space nursery
    // (ECO_NURSERY_REGIONS=0) hands it back only at the second.
    llvm.call @eco_minor_gc() : () -> ()
    llvm.call @eco_minor_gc() : () -> ()
    %f1 = func.call @fill_ee() : () -> !eco.value
    %f2 = func.call @fill_ee() : () -> !eco.value
    %f3 = func.call @fill_ee() : () -> !eco.value
    %f4 = func.call @fill_ee() : () -> !eco.value
    %fn1 = func.call @fill_n(%nfill) : (i64) -> i64

    %a1, %r1 = bf.read.u8 %r0 : i64, !bf.cursor
    %a2, %r2 = bf.read.u8 %r1 : i64, !bf.cursor
    %a3, %r3 = bf.read.u8 %r2 : i64, !bf.cursor
    %a4, %r4 = bf.read.u8 %r3 : i64, !bf.cursor
    %base2 = arith.constant 2000 : i64
    %p1 = arith.addi %base2, %a1 : i64
    %p2 = arith.addi %base2, %a2 : i64
    %p3 = arith.addi %base2, %a3 : i64
    %p4 = arith.addi %base2, %a4 : i64
    eco.dbg %p1 : i64
    eco.dbg %p2 : i64
    eco.dbg %p3 : i64
    eco.dbg %p4 : i64

    %four = arith.constant 4 : i32
    %copied, %rb1, %okb = bf.read.bytes %rb0, %four : !eco.value, !bf.cursor, i1
    %cc0 = bf.decoder.cursor.init %copied : !eco.value -> !bf.cursor
    %b1, %cc1 = bf.read.u8 %cc0 : i64, !bf.cursor
    %base3 = arith.constant 3000 : i64
    %q1 = arith.addi %base3, %b1 : i64
    eco.dbg %q1 : i64

    // ---- C: encoder cursor across a minor GC ----
    %esize = arith.constant 16 : i32
    %ebuf = bf.alloc %esize : !eco.value
    %e0 = bf.cursor.init %ebuf : !eco.value -> !bf.cursor
    %va1 = arith.constant 161 : i64
    %va2 = arith.constant 162 : i64
    %va3 = arith.constant 163 : i64
    %va4 = arith.constant 164 : i64
    %e1 = bf.write.u8 %e0, %va1 : !bf.cursor
    %e2 = bf.write.u8 %e1, %va2 : !bf.cursor

    // A GC point between two writes of a fused encoder (an allocating
    // value expression compiled after bf.alloc).
    llvm.call @eco_minor_gc() : () -> ()
    llvm.call @eco_minor_gc() : () -> ()
    %g1 = func.call @fill_ee() : () -> !eco.value
    %g2 = func.call @fill_ee() : () -> !eco.value
    %fn2 = func.call @fill_n(%nfill) : (i64) -> i64

    %e3 = bf.write.u8 %e2, %va3 : !bf.cursor
    %e4 = bf.write.u8 %e3, %va4 : !bf.cursor

    %d0 = bf.decoder.cursor.init %ebuf : !eco.value -> !bf.cursor
    %x1, %d1 = bf.read.u8 %d0 : i64, !bf.cursor
    %x2, %d2 = bf.read.u8 %d1 : i64, !bf.cursor
    %x3, %d3 = bf.read.u8 %d2 : i64, !bf.cursor
    %x4, %d4 = bf.read.u8 %d3 : i64, !bf.cursor
    %base4 = arith.constant 4000 : i64
    %y1 = arith.addi %base4, %x1 : i64
    %y2 = arith.addi %base4, %x2 : i64
    %y3 = arith.addi %base4, %x3 : i64
    %y4 = arith.addi %base4, %x4 : i64
    eco.dbg %y1 : i64
    eco.dbg %y2 : i64
    eco.dbg %y3 : i64
    eco.dbg %y4 : i64

    // Keep every buffer live to the end so the GCs move (not free) them.
    %l0 = bf.bytes_width %buf : !eco.value -> i32
    %l1 = bf.bytes_width %f1 : !eco.value -> i32
    %l2 = bf.bytes_width %f2 : !eco.value -> i32
    %l3 = bf.bytes_width %f3 : !eco.value -> i32
    %l4 = bf.bytes_width %f4 : !eco.value -> i32
    %l5 = bf.bytes_width %g1 : !eco.value -> i32
    %l6 = bf.bytes_width %g2 : !eco.value -> i32
    %l7 = bf.bytes_width %ebuf : !eco.value -> i32
    %s1 = arith.addi %l0, %l1 : i32
    %s2 = arith.addi %s1, %l2 : i32
    %s3 = arith.addi %s2, %l3 : i32
    %s4 = arith.addi %s3, %l4 : i32
    %s5 = arith.addi %s4, %l5 : i32
    %s6 = arith.addi %s5, %l6 : i32
    %s7 = arith.addi %s6, %l7 : i32
    %s64 = arith.extui %s7 : i32 to i64
    eco.dbg %s64 : i64
    // CHECK: [eco.dbg] 128

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
