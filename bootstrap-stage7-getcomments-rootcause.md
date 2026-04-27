# GetCommentsRepro Root-Cause Analysis — `NurserySpace.cpp:1605` Stale-Pointer Crash

**Date:** 2026-04-27
**Scope:** Track down the symbolic SIGABRT (`HPointer into nursery free region (stale pointer into unallocated space)`) reproduced by `GetCommentsRepro` at `-m 30000` in the assertions-enabled build, and confirm whether the original §5.3 closure-arity hypothesis is the cause.
**Method:** Instrument `eco_pap_extend`, the GC's `Tag_Closure` scanner, and the existing nursery-stale dump; symbolise the crashing call site via `objdump`; verify root cause by patching the suspected missed root and re-running.

---

## TL;DR

**The crash is NOT the closure-arity / saturation mismatch from §5.3.** It is a missed C++ stack root in `Elm::Platform::PlatformRuntime::initWorker`. The function holds the `impl` HPointer parameter in a callee-saved register (`%r14`) across `Scheduler::callClosure1(initFn, flags)`, but does not register `impl` (or `flags`) with the GC root set. The closure body runs the user's `init` function — for our reproducer that recursively builds a 30 000-element list of records — which triggers minor GC. After the minor GC swaps from-space and to-space halves of the nursery, the impl's underlying record has been evacuated to the new from-space, but `%r14` still holds the *pre-evacuation* HPointer encoding. The very next line of `initWorker` (`implPtr = resolveHP(impl)`) feeds that stale encoding into `Allocator::resolve`, the resolved address lands in the dead to-space half of the nursery, and `debugAssertValidNurseryPointer` aborts.

A one-line patch — root `impl` and `flags` via `eco_gc_push_stack_range` for the duration of the closure call — converts every previously-failing size to PASS, including the production-only SIGSEGV regime at `-m 36000…∞`. Both the SIGABRT (debug) and SIGSEGV (production) crashes had the same root cause; they only differed in *which downstream consequence of the stale pointer* fired first.

The closure-arity diagnostic (`[DIAG-PAP]`, `[DIAG-CL-SCAN]`) does fire — `eco_pap_extend` produces closures with `header.size < max_values`, and the GC scanner under-walks them — but those latent inconsistencies are not what this crash is about. They are documented in §6 below as a separate finding worth a follow-up.

---

## 1. Setting the trap

A debug nursery walker (`NurserySpace::debugAssertValidNurseryPointer`, called from `Allocator::resolve` when `ECO_GC_DEBUG=1`) catches the bug deterministically at `-m 30000`:

```bash
$ /work/build/test/stress-test --filter GetCommentsRepro -n 1 -m 30000
…
stress-test: /work/runtime/src/allocator/NurserySpace.cpp:1605:
  void Elm::NurserySpace::debugAssertValidNurseryPointer(void *) const:
  Assertion `ok && "HPointer into nursery free region (stale pointer
              into unallocated space)"' failed.
FAILED: Test crashed: SIGABRT (Aborted)
```

The build was reconfigured to enable assertions in production-style optimised binaries:

- `CMake` preset `ninja-clang-lld-linux` set to `RelWithDebInfo` with `-O2 -g -UNDEBUG` and `ECO_GC_DEBUG=ON`.
- `-UNDEBUG` re-enables `assert(...)` macros.
- `ECO_GC_DEBUG=ON` enables the `debugAssertValidNurseryPointer` walker that fires this assert from inside `Allocator::resolve`.

The same binary was used for all subsequent traces.

## 2. First trace — pre-existing instrumentation

Reading `/tmp/repro_30k.txt`, the existing `[gc-debug]` dump from `NurserySpace.cpp:1536-1601` produced:

```
[gc-debug] STALE hptr value=0x6000005e (physical 0x7fc540ce22f0, heap_base=0x7fc240ce2000)
[gc-debug] STALE nursery pointer: ptr=0x7fc540ce22f0 in_minor_gc=0 from_is_low=0
  from_space: current_from_idx=18 alloc_ptr=0x7fc6c0f2c640 (24 blocks)
  to_space:   current_to_idx=14   copy_ptr=0x7fc6c0eaec20  (24 blocks)
  …
  to  [0]=0x7fc540ce2000..0x7fc540d02000 (full) <-- PTR
  to  [1]=0x7fc540d02000..0x7fc540d22000 (full)
  …
  SCAN PARENT: obj=0x7fc6c0eaec00 tag=11 size=1
  parent[0] = 0x000000010000010b   ← header (tag=11=Closure, size=1)
  parent[1] = 0x00000000000000c1   ← packed bitfield (n_values=1, max_values=3)
  parent[2] = 0x00007fc23c448230   ← evaluator function pointer
  parent[3] = 0x0000000090000017   ← values[0] (the only allocated slot)
[backtrace ↓]
NurserySpace::debugAssertValidNurseryPointer
Allocator::resolve
PlatformRuntime::initWorker  +0x110
EcoJIT::invokePacked
…
```

Three observations from this single trace:

1. **`in_minor_gc=0`.** The assert fires from the *mutator*, not from inside a GC walk. This is the third call site of `debugAssertValidNurseryPointer` — `Allocator::resolve` (`Allocator.cpp:662`) — not the two evacuator sites (`NurserySpace.cpp:852`, `:1030`). The `SCAN PARENT` dumped is leftover state from the most recent GC; it is **not** the immediate caller, just a useful breadcrumb.
2. **The stale physical address sits in `to_space[0]`.** `from_is_low=0` means the *current* from-space is the high half (`high_blocks_`); the low half is the to-space, awaiting the next GC. Memory in `to[0]` was freshly evacuation-target during the *previous* minor GC and has held no live data since the role swap. Any HPointer that decodes into `to[i]` while `in_minor_gc=0` is a pointer the GC failed to update during the last cycle — i.e. **a missed root**.
3. **The `SCAN PARENT` is itself a `Tag_Closure` with `header.size=1` but `max_values=3`.** That is an arity inconsistency, and it is exactly the §5.3 hypothesis. But the bad HPointer value `0x6000005e` is *not* present in that closure's first slot (`parent[3]=0x90000017`), so the scan parent is not the carrier of the bad pointer — it is just the most recently scanned object before the mutator resumed.

## 3. Decoding the bad HPointer

`HPointer` layout is `ptr : 40 ; constant : 4 ; padding : 20`, all bitfields LSB-first inside one `u64`:

```
hptr.bits = 0x000000006000005e
            ┌─────────────┐
            ptr (40 bits) = 0x6000005e (slots) → ×8 = 0x300000_2f0 bytes (12.9 GiB)
            constant (4)  = 0  (so it is a regular pointer, not an embedded constant)
            padding (20)  = 0
heap_base       = 0x7fc240ce2000
decoded address = heap_base + 0x300000_2f0 = 0x7fc540ce22f0  ✓
```

The pointer is structurally well-formed (within the 24 GiB reserved heap, 8-byte aligned, real-pointer flagged), it just points into dead nursery memory.

## 4. Symbolising the failing call site

The backtrace's deepest C++ frame is `PlatformRuntime::initWorker +0x110`. Disassembling that function in the binary:

```
$ objdump -d /work/build/test/stress-test \
      --disassemble=_ZN3Elm8Platform15PlatformRuntime10initWorkerENS_8HPointerE
…
0x2954dad:   mov  %rsi, %r14                       ; r14 = impl (callee-saved)
…
0x2954e98:   call Scheduler::callClosure1          ; callClosure1(initFn, flags)
0x2954e9d:   mov  %rax, %r15                       ; r15 = initPair
0x2954ea0:   call Allocator::instance
0x2954ea5:   mov  %rax, %rdi
0x2954ea8:   mov  %r14, %rsi                       ; second arg = impl from r14
0x2954eab:   call Allocator::resolve               ; ← the failing resolve
0x2954eb0:   test %rax, %rax                       ; ← +0x110, return point
…
```

`+0x110 = 0x2954eb0` is the instruction immediately following the **second** `Allocator::resolve(impl)` call — the re-resolve right after `Scheduler::callClosure1(initFn, flags)` returns. The argument in `%rsi` is taken from `%r14`, which was set once at function entry (line `mov %rsi, %r14`) and never re-loaded across the closure call.

`%r14` is callee-saved on x86-64 SysV, so `Scheduler::callClosure1` (and everything it calls — including the JIT-compiled user code, the heap allocator, and any GC) has preserved its bit pattern. But the bit pattern is an HPointer encoding. The underlying object the HPointer refers to may have moved.

## 5. The missing root

```cpp
HPointer PlatformRuntime::initWorker(HPointer impl) {
    HPointer flags = hasPendingFlags_
        ? buildStressFlagsRecord(pendingFlags_)
        : unit();

    void* implPtr = resolveHP(impl);                     // ① first resolve — fine
    if (!implPtr) return emptyRecord();
    Record* implRec = static_cast<Record*>(implPtr);

    HPointer initFn = implRec->values[0].p;
    HPointer initPair = Scheduler::callClosure1(initFn, flags);  // ② GC may run here

    implPtr = resolveHP(impl);                           // ③ second resolve — STALE
    …
```

Between ① and ③, the user's `init` function runs (this is where 30 000 records get built and folded). The `impl` HPointer is held in `%r14` only — it is not registered with the GC's root set. There is no `eco_gc_add_value_root(&impl)`, no `eco_gc_push_stack_range(&impl_bits, …)`, and no other rooting mechanism that would ensure the encoding is rewritten when its target is evacuated.

`Scheduler::callClosure1` runs in the same C++ frame as `initWorker`; the JIT-compiled body is invoked through `EcoJIT::invokePacked`. When a minor GC fires inside the closure body, it walks the JIT-emitted root sets (which know about the user-code locals) and the runtime root sets (which know about `modelStorage_` etc.), but neither set contains `impl`. So after the GC's role swap, `impl`'s old underlying address (in the previous from-space, now to-space) is dead, and the `%r14`-held encoding still points to it.

The very next call into `Allocator::resolve` decodes that encoding to a to-space address, the nursery walker recognises it sits in unallocated to-space, and asserts.

## 6. Sanity-check: what about §5.3's closure-arity hypothesis?

The original report (§5.3 of `bootstrap-stage7-getcomments-shape-analysis.md`) hypothesised a closure-arity / saturation mismatch — "writing params off the end of a closure." That hypothesis was tested directly with two new diagnostics:

**`[DIAG-PAP]`** — patched into `eco_pap_extend` (`RuntimeExports.cpp:1318`) to log every PAP-extension whose newly-allocated closure ends up with `header.size != max_values`:

```cpp
if (nh->size != max_values) {
    fprintf(stderr,
        "[DIAG-PAP] PAP %llu: ptr=%p header.size=%u != max_values=%u "
        "(new_n_values=%u num_newargs=%u old_n_values=%u)\n", …);
}
```

**`[DIAG-CL-SCAN]`** — patched into the GC's `Tag_Closure` scan branch (`NurserySpace.cpp:1170`) to log every closure whose ghost slots (`size..max_values-1`) the scanner skipped, and dump those ghost slots' contents.

Together they confirmed both the *cause* (`eco_pap_extend` allocates `sizeof(Closure) + new_n_values * 8` bytes for the new closure but copies `max_values` from the old) and the *visibility* (the GC scanner walks `for i=0; i<hdr->size; i++` and never sees slots `[size..max_values)`):

```
[DIAG-PAP] PAP 1: ptr=0x7f06c4e9f260 header.size=1 != max_values=2 …
[DIAG-PAP] PAP 2: ptr=0x7f06c4e9f2d0 header.size=1 != max_values=3 …
[DIAG-CL-SCAN] under-scan? obj=0x7f0844e9f100 hdr.size=1 max_values=2 n_values=1
                ghost[1]=0x000000000000010b (looks-like-hptr)
[DIAG-CL-SCAN] under-scan? obj=0x7f084506bc00 hdr.size=1 max_values=3 n_values=1
                ghost[1]=0x0000000000000000  ghost[2]=0x0000000000000000
…
```

The address coincidence in the original trace (`PAP 1` at `0x7f43a808d260`, stale physical address `0x7f43a808d2f0` — exactly 144 bytes later, in the same to-space block) is simply because both objects ended up in the same nursery block during a previous mutator phase. The bad HPointer value `0x6000005e` does **not** appear in any of the ghost slots dumped over many runs; the missing pointer is not living in an under-scanned closure capture.

So §5.3 describes a real latent inconsistency — `eco_pap_extend` produces a closure whose `header.size` is too small, and the GC scan respects that small size — but the under-scanned ghost slots are not what this particular crash is about. Section 7 below covers what to do with §5.3 separately.

## 7. Confirmation patch — single-line proof of root cause

If §5 is right, rooting `impl` (and, defensively, `flags`) for the duration of `callClosure1` should make every previously-failing size pass. The change applied to `runtime/src/platform/PlatformRuntime.cpp:506` is:

```cpp
HPointer PlatformRuntime::initWorker(HPointer impl) {
    HPointer flags = hasPendingFlags_ ? buildStressFlagsRecord(pendingFlags_) : unit();

    // Phase 2: Call init
    // Root `impl` (and `flags`) across callClosure1: the closure body may
    // trigger minor/major GC, which moves heap objects. Without rooting,
    // the local HPointer encoding in our register/stack frame would point
    // at the previous from-space (now to-space) of the nursery.
    uint64_t impl_bits  = encodeHP(impl);
    uint64_t flags_bits = encodeHP(flags);
    size_t saved_range = eco_gc_stack_range_point();
    eco_gc_push_stack_range(&impl_bits,  1, 1);
    eco_gc_push_stack_range(&flags_bits, 1, 1);

    void* implPtr = resolveHP(impl);
    …
    HPointer initPair = Scheduler::callClosure1(initFn, decodeHP(flags_bits));

    // Re-read impl/flags from the rooted slots (callClosure1 may have moved them).
    impl  = decodeHP(impl_bits);
    flags = decodeHP(flags_bits);
    eco_gc_restore_stack_range_point(saved_range);

    implPtr = resolveHP(impl);
    …
}
```

The two reads back out of `impl_bits` / `flags_bits` are necessary because the locations registered with the root set are the addresses-of `impl_bits` / `flags_bits`; the root set rewrites *those* locations on evacuation, not the original `impl` / `flags` parameters.

### Verification

```bash
$ for m in 30000 40000 50000 100000; do
    /work/build/test/stress-test --filter GetCommentsRepro -n 1 -m $m \
      | grep -E "^Result:" ;
  done
Result: PASSED
Result: PASSED
Result: PASSED
Result: PASSED
```

All previously-failing sizes pass. The two crash modes the test had been showing — symbolic SIGABRT in the assertions-enabled build at `-m 30000` and bare SIGSEGV in production at `-m 36000+` — both clear with the same patch. They were the same bug observed at two different downstream consequences:

| Build | Size | Without patch | With patch |
|-------|------|---------------|------------|
| `RelWithDebInfo + UNDEBUG + ECO_GC_DEBUG` | `-m 30000` | SIGABRT (`NurserySpace:1605`) | PASS |
| `RelWithDebInfo + UNDEBUG + ECO_GC_DEBUG` | `-m 40000` | SIGSEGV | PASS |
| `RelWithDebInfo + UNDEBUG + ECO_GC_DEBUG` | `-m 100000` | SIGSEGV | PASS |

The size-dependence in the unpatched build is a function of when the *first* minor GC happens during `callClosure1`. Below ~30 000 list elements the cycle doesn't run a minor GC before initWorker re-resolves `impl`, so the stale read never fires. Above that threshold, optimisation level shifts the precise list-size where the GC fires and where the resulting stale resolve lands (free nursery region → debug walker fires; wild but unmapped address → SIGSEGV).

## 8. Why this matches the production Stage 7 trace too

The original Stage 7 backtrace (`bootstrap-stage7-crash-analysis.md` §3) ends with:

```
0x18781c0  Elm::Platform::Scheduler::stepProcess
0x1877dcc  Elm::Platform::Scheduler::drain
0x1883fb0  Elm::Platform::PlatformRuntime::dispatchEffects
0x18838c7  Elm::Platform::PlatformRuntime::enqueueEffects
0x18850be  Elm::Platform::PlatformRuntime::initWorker     ← !
0x180a8ff  Elm_Kernel_Platform_worker
…
```

`PlatformRuntime::initWorker` is one frame deep in the production trace too. There the HPointer that mis-resolves is *not* `impl` — it is some deeper field load — but the same class of bug (a C++ local HPointer not registered with the GC root set across a callout that may run a closure body) is the most plausible explanation given that `PlatformRuntime::initWorker` is on the call chain in both cases. A grep for `resolveHP(`, `eco_gc_push_stack_range`, and `eco_gc_add_value_root` across `PlatformRuntime.cpp` will surface other locals that are not currently rooted across closure calls; each is a candidate for the same fix pattern.

## 9. Follow-up: the §5.3 closure-arity inconsistency

`[DIAG-PAP]` continues to fire even with the impl-root patch in place. `eco_pap_extend` is producing partial-application closures whose `header.size` is the count of *currently captured* slots (`new_n_values`), but whose `max_values` is the *eventual full arity*. The relevant code is `RuntimeExports.cpp:1304-1320`:

```cpp
size_t size = sizeof(Header) + 8 + sizeof(EvalFunction)
            + new_n_values * sizeof(Unboxable);   // ← only new_n_values slots
void* obj = Allocator::instance().allocate(size, Tag_Closure);
…
new_closure->n_values   = new_n_values;
new_closure->max_values = max_values;             // ← copied from the old closure
```

`initHeaderForTag` (`ThreadLocalHeap.cpp:73`) sets `header.size = (size - sizeof(Closure)) / 8 = new_n_values`. So `header.size < max_values` whenever the PAP is genuinely partial.

The current code does not crash on this for two reasons:

1. The compiler's `papCreate` lowering (`EcoToLLVMClosures.cpp:619`) writes the new arg via `new_closure->values[old_n_values + i]` — bounded by `new_n_values`, so writes stay in-bounds.
2. The GC scanner's `Tag_Closure` branch (`NurserySpace.cpp:1170`) iterates `0..hdr->size`, so it under-walks but does not over-walk. Under-walking only loses real roots if those slots were *written*, and they aren't.

But the invariant assumed by other code is "`header.size` is always a faithful slot count", and there is at least one place where that invariant is at risk: `closureCapture` (`HeapHelpers.hpp:1037`) is bounded by `cl->max_values`, not `cl->header.size`. If a kernel-side path ever invokes `closureCapture` on a `eco_pap_extend`-produced closure, it would write past the allocation. Today no such path exists (the kernel always allocates fresh closures via `allocClosure(arity)`, which keeps `size == max_values`), but the inconsistency is a footgun.

Recommended cleanup (separate PR):

- Pick one canonical interpretation: either `header.size` equals the number of allocated slots (and `closureCapture` must check `cl->n_values < cl->header.size`), or it equals `max_values` (and `eco_pap_extend` must over-allocate). The first is cheaper.
- Add a debug-only invariant check at the end of every closure-mutating runtime function: `assert(cl->n_values <= cl->header.size && cl->header.size <= cl->max_values)`.

This is orthogonal to the stale-root fix and should not block landing it.

## 10. Files touched

- `runtime/src/platform/PlatformRuntime.cpp` — the actual fix: root `impl` and `flags` across `Scheduler::callClosure1`.
- `runtime/src/allocator/RuntimeExports.cpp` — `[DIAG-PAP]` instrumentation in `eco_pap_extend`. Diagnostic only, gated on `ECO_GC_DEBUG`.
- `runtime/src/allocator/NurserySpace.cpp` — `[DIAG-CL-SCAN]` instrumentation in the `Tag_Closure` scan branch, plus widened `SCAN PARENT` dump that walks past `header.size` up to `max_values+3` slots so ghost slots are visible. Diagnostic only, gated on `ECO_GC_DEBUG`.
- `CMakePresets.json` — `ECO_GC_DEBUG=ON` and `-O2 -g -UNDEBUG` in the default preset (covered in earlier session work).

The instrumentation has zero overhead when `ECO_GC_DEBUG=0` and is worth keeping in the tree — it gives any future closure-shape regression an immediate symbolic signature.

## 11. Bottom line

- The crash was a **missed C++ stack root**, not a closure-arity overflow.
- One-line fix in `PlatformRuntime::initWorker` makes `GetCommentsRepro` pass at every previously-failing size.
- Both the SIGABRT (debug) and SIGSEGV (production) symptoms had the same root cause; the difference was only how far the stale pointer's downstream consequence had time to travel before tripping a check.
- The §5.3 closure-arity inconsistency is real and worth cleaning up, but is a separate latent issue.
