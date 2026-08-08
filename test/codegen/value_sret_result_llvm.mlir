// RUN: %ecoc %s -emit=llvm 2>&1 | %FileCheck %s
//
// U-T1.3.3 result promotion mechanism probe (tier-1 plan): a MULTI-RESULT
// func.func is an sret worker. The lowering must produce
//   (slot: ptr addrspace(0), args...) -> void
// with the callee storing each field immediately before its return
// (CGEN_067's store-before-return discipline, structural by construction)
// and the caller allocating the slot, passing it, and reloading the
// fields. No literal struct carrying ptr addrspace(1) may cross the call
// boundary in either direction (REP_AGG_001 / CGEN_064 — RS4GC cannot
// relocate FCAs and SelectionDAG asserts on wide statepoint struct
// returns).
//
// The reloaded pointer field is then fed into a construct (an allocating
// op ⇒ statepoint) so the probe also proves the loaded field behaves as
// an ordinary relocatable SSA pointer afterwards.

module {
  // Public so neither internalization nor DCE removes the definition.
  //
  // The worker CONSTRUCTS before returning, so it allocates. That is
  // load-bearing, not incidental: a call-free worker body is provably GC-free,
  // so under ECO_GCFREE_LEAF=1 (CGEN_072) it is stamped gc-leaf-function and
  // RS4GC correctly stops statepointing the call in the caller below — which
  // would silently void this probe's caller-side statepoint check. Keeping the
  // worker allocating pins the sret ABI under a statepointed call, which is the
  // scenario sret exists for (REP_AGG_001/CGEN_064: an FCA carrying
  // ptr addrspace(1) cannot cross a statepoint). Do NOT simplify this body back
  // to a bare `eco.return %p, %a`.
  func.func @sret_pair_worker(%a: i64, %p: !eco.value) -> (!eco.value, i64) {
    %t = eco.construct.tuple2 %a, %p : i64, !eco.value -> !eco.value
    eco.return %t, %a : !eco.value, i64
  }

  func.func @sret_pair_caller(%n: i64, %v: !eco.value) -> !eco.value {
    %r0, %r1 = "eco.call"(%n, %v) {callee = @sret_pair_worker} : (i64, !eco.value) -> (!eco.value, i64)
    %c = eco.construct.tuple2 %r1, %r0 : i64, !eco.value -> !eco.value
    return %c : !eco.value
  }
}

// The worker's ABI: leading addrspace-0 slot pointer, void return —
// never a struct return:
// CHECK: define {{.*}}void @sret_pair_worker(ptr {{.*}}, i64 {{.*}}, ptr addrspace(1) {{.*}})
//
// Field stores feed the slot right before the terminator:
// CHECK: store ptr addrspace(1) {{.*}}, ptr
// CHECK: store i64 {{.*}}, ptr
// CHECK: ret void
//
// Caller side: stack slot; the worker call is statepoint-wrapped with the
// slot as the LEADING actual argument (after the statepoint's own
// [id, flags, callee, numargs, cc] prelude); fields reload after:
// CHECK: define {{.*}}@sret_pair_caller(
// CHECK: alloca { ptr addrspace(1), i64 }
// CHECK: gc.statepoint{{.*}}@sret_pair_worker, i32 3, i32 0, ptr
// CHECK: load ptr addrspace(1), ptr
//
// No struct-packed return values anywhere in this probe:
// CHECK-NOT: insertvalue { ptr addrspace(1), i64 }
// CHECK-NOT: extractvalue { ptr addrspace(1), i64 }
