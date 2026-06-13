; E-W1 statepoint smoke — input IR, pre-RewriteStatepointsForGC.
;
; Two functions using the "statepoint-example" GC strategy. run.ps1 pipes this
; through `opt -passes=rewrite-statepoints-for-gc`, which turns the
; do_safepoint() calls into gc.statepoint intrinsics with %obj recorded as a
; live GC root, then `llc -mtriple=x86_64-pc-windows-msvc` emits a COFF
; object whose `.llvm_stackmaps` section describes where %obj lives at each
; safepoint. The harness (harness.cpp) implements do_safepoint() by unwinding
; the stack with RtlVirtualUnwind and recovering %obj from the stackmap.
;
; consume_root:           plain frame — root expected in a spill slot or
;                         callee-saved register relative to rbp/rsp.
; consume_root_dynalloca: dynamic + overaligned alloca live across the
;                         safepoint — on x86_64 this typically forces rbp
;                         as the frame pointer and may park values in
;                         different anchors than the plain case. This is the
;                         frame shape the Eco StackMap consumer must handle
;                         per the build-on-windows plan.

declare void @do_safepoint()
declare void @use_buffer(ptr)
declare void @use_byte(i8)

define ptr addrspace(1) @consume_root(ptr addrspace(1) %obj) gc "statepoint-example" {
entry:
  call void @do_safepoint()
  ret ptr addrspace(1) %obj
}

define ptr addrspace(1) @consume_root_dynalloca(ptr addrspace(1) %obj, i64 %n) gc "statepoint-example" {
entry:
  %buf = alloca i8, i64 %n, align 32
  call void @use_buffer(ptr %buf)
  call void @do_safepoint()
  %v = load volatile i8, ptr %buf
  call void @use_byte(i8 %v)
  ret ptr addrspace(1) %obj
}
