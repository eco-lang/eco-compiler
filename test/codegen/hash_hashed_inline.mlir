// RUN: %ecoc %s -emit=mlir-llvm 2>&1 | %FileCheck %s
//
// A Hash.Hashed (HEAP_089) is read inline (plans/hashed-values-and-hash-consing.md F4): eco.hash and
// eco.hash.mix of kind "hashed" load the stored u32 hash at byte 8, eco.hashed.value loads the value
// slot at byte 16, each through the forwarding check (__eco_resolve_fwd), and none calls the runtime
// walker. The mix is the walker's step for a nested Hashed: the marker kHashed (18), then the hash.

// CHECK-NOT: llvm.call @eco_hash_value
// CHECK-NOT: llvm.call @eco_hash_walk
// CHECK-NOT: Eco_Kernel_FNV

// CHECK-LABEL: llvm.func @hash_of
// CHECK: llvm.call @__eco_resolve_fwd
// CHECK: llvm.mlir.constant(8 : i64)
// CHECK: llvm.load {{.*}} <alignment = 4> : !llvm.ptr<1> -> i32
// CHECK: llvm.zext
// CHECK: llvm.return

// CHECK-LABEL: llvm.func @mix_hashed
// CHECK: llvm.call @__eco_resolve_fwd
// CHECK: llvm.load {{.*}} -> i32
// CHECK: llvm.mlir.constant(18 : i32)
// CHECK: llvm.xor
// CHECK: llvm.mul
// CHECK: llvm.xor
// CHECK: llvm.mul
// CHECK: llvm.return

// CHECK-LABEL: llvm.func @value_of
// CHECK: llvm.call @__eco_resolve_fwd
// CHECK: llvm.mlir.constant(16 : i64)
// CHECK: llvm.load {{.*}} <alignment = 8> : !llvm.ptr<1> -> i64
// CHECK: llvm.return

module {
  func.func @hash_of(%h: !eco.value) -> i64 {
    %r = eco.hash %h <{kind = "hashed"}> : !eco.value -> i64
    eco.return %r : i64
  }

  func.func @mix_hashed(%s: i64, %h: !eco.value) -> i64 {
    %r = eco.hash.mix %s, %h <{kind = "hashed"}> : !eco.value -> i64
    eco.return %r : i64
  }

  func.func @value_of(%h: !eco.value) -> !eco.value {
    %v = eco.hashed.value %h : !eco.value -> !eco.value
    eco.return %v : !eco.value
  }

  func.func @main() -> i64 {
    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
