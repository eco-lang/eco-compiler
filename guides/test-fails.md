# SpawnGCChurn — Root Cause Investigation Report

Date: 2026-04-23

## Session scoreboard
- elm-test: 12799/12799 passing
- E2E `check`: 1123/1123 passing
- stress-test: **95/97 passing** (baseline 84/97). Still failing:
  SpawnGCChurn, BytesRoundtripMixedRecord.

## Executive summary

`SpawnGCChurn` aborts with a "bad closure" diagnostic inside
`eco_apply_segmentation_unknown` — a closure `HPointer` resolves to
**all-zero memory in main's nursery**. Instrumentation proves the stale
HPointer lands in the post-GC cleared region of what used to be main's
from-space. After extensive investigation covering five hypotheses,
exactly one — H4, a pre-existing stale-`Cons*` bug in
`taskOnEffectsEvaluator` — has been fixed in this session. H1, H2 and
H5 were drafted as defensive correctness fixes, then rolled back because
they did not change the SpawnGCChurn symptom and a properly-scoped
cross-thread GC fix (the natural home for H1/H5) is not in the session
budget. H3 is partially investigated and remains the most likely
culprit.

## Evidence trail

The stale HP is consistently in **main's own nursery** (`inNursery=1`
via main's thread-local bounds). Without `clearToSpaceFreeRegion`'s
post-GC zero-fill, the memory at that address holds a sequence of
evacuated `ElmInt` cells — proof that the location has been reused as
to-space fill by a later evacuation of `List.range`-style data.
`objdump` pins the crash to **stepProcess +0x260**, the first
`callClosure1` site in stepProcess, i.e. the `Task_Succeed`/`Task_Fail`
stack-pop path. So the outer callback is one of the `Task.andThen`
lambdas. The *inner* bad closure — the one handed to
`eco_apply_segmentation_unknown` — is whatever recursive call the
callback body performs (e.g. `go (k+1)` in `spawnAll` or
`loop (y-1)` in `worker`).

## Fix landed this cycle

### H4 — stale `Cons* cell` in `taskOnEffectsEvaluator` *(FIXED)*

Pre-existing bug in `elm-kernel-cpp/src/core/TaskEffectManager.cpp`.
The cmd-dispatch loop cached `Cons* cell = resolveHP(current)` and
then read `cell->tail` *after* `taskAndThen` + `rawSpawn`
allocations, both of which can GC. Post-GC the old Cons location has
a Forward header plus original field bytes, which
`clearToSpaceFreeRegion` zeroes on the next cycle — at that point
`cell->tail` returns junk. Also, the loop cursor `current` and the
router closure `sendToAppCl` are long-lived across those allocations
but were not rooted on the C++ stack.

**Change:**
- Wrap the loop body in `Elm::StackRootGuard(&current, &sendToAppCl)`
  so GC updates both HPs in place.
- Snapshot `cell->head.p` and `cell->tail` into local HPs *before*
  any allocation; drive the loop with the snapshots instead of
  dereferencing the cached `cell` after the allocs.
- Remove a misleading no-op "re-resolve" (`decodeHP(encodeHP(x))`).

Independent from SpawnGCChurn — the `Cons`-walk corruption would
break earlier in the cmd-dispatch loop, not at `stepProcess+0x260`.
Kept because it is a clear correctness bug.

## Investigated but rolled back

### H1 — race on `Scheduler::runQueue_` / `latestProc_` accessors *(rolled back)*

`registerLatestProcess`, `latestProcessById`, and the external
scanner touched `std::unordered_map` / `std::deque` without a mutex,
despite multiple threads (main + timer threads via
`resumeEvaluator → procWithRoot`) writing them. A draft fix added
`mutex_` locking on all access paths; rolled back in this cycle
because it did not change the SpawnGCChurn symptom and risks
masking subtler bugs if applied without a full cross-thread GC
design. The underlying UB is still present.

### H2 — sleep resume-closure race against main GC *(rolled back)*

`sleepBindingEvaluator` captures a raw `resumeEnc` uint64_t into the
timer thread's std::thread lambda that goes stale after main GC.
A draft fix introduced `Scheduler::invokeResumeAndRelease(token, arg)`
holding a recursive `resumeMutex_` across the JIT call; rolled back
in this cycle. The code currently uses the older
`takePendingResume(token) → callClosure1(...)` split which has the
original race — no regression vs. the pre-session baseline, but
also no improvement.

### H3 — RS4GC missed closure HPointer in JIT stackmap *(partially investigated, unconfirmed)*

Dumped the post-RS4GC LLVM IR for `SpawnGCChurn`
(`/work/build/runtime/src/codegen/ecoc --emit=llvm --dump-rs4gc-ir=... SpawnGCChurn.mlir`).
Walked `SpawnGCChurn_lambda_17$cap` (the `\_ -> go (k+1)` body) and
its closure wrapper. Both appear correct at the IR level:

- `lambda_17$cap`'s two statepoints both include `%1` (the `go`
  param) in gc-live and relocate it to `%12` before
  `eco_apply_segmentation_unknown`.
- The wrapper `__closure_wrapper_lambda_17$cap` loads `go` via
  `inttoptr i64 %11 to ptr addrspace(1)` and passes it to
  `lambda_17$cap`; the wrapper has no intervening statepoints so
  the value cannot be invalidated in the wrapper body itself.
- `EcoGCPrepare` attaches both block-wide `computeLiveRoots` **and**
  the op's own `!eco.value` operands to each call-safepoint, which is
  the same pattern that works for every other function in the test.

What I did not get to: reading the compiled assembly for the
statepoint stackmaps to verify that the gc-live values end up in
**stack slots** rather than caller-saved registers that get clobbered
across the call. Closure-wrapper codegen (in
`EcoToLLVMClosures.cpp:431-439`) deliberately routes each gc-live arg
through a stack alloca to avoid this exact class of issue — but only
for the wrapper, not for the `$cap` body. If the `$cap` body keeps
`%1` in a register that gets trampled by the inner call, the
relocate would see a poisoned value. That would exactly match the
observed symptom.

**Recommended next diagnostic:**
`llvm-objdump -d` on the JIT memory range for `SpawnGCChurn_lambda_17$cap`
(needs JIT symbol export plumbing — currently the JIT addresses in
the crash backtrace are unresolved) and correlate with the generated
stackmap (`.llvm_stackmaps` section, parsed via `StackMap.cpp`).

### H5 — external root scanners are thread-local *(rolled back)*

Instrumenting `addExternalRootScanner`'s callback with a thread-ID
print, the Scheduler's scanner was **only ever invoked from the main
thread's GCs**, even after 10+ timer threads had run and exited. Root
cause: `Allocator::instance().getRootSet()` returns the *thread-local*
root set, so a scanner registered on the thread that first calls
`Scheduler::instance()` (always main) never runs on any timer
thread's GC. Any object reachable only via runQueue/latestProc/
pendingResumes that lives in a timer's nursery would be collected.

A draft fix added `RootSet::addGlobalExternalRootScanner` (global
vector protected by a mutex, read by every thread's GC in addition to
its thread-local scanners) and migrated the Scheduler scanner to it.
Rolled back in this cycle. This is a real latent bug: it means
cross-thread runtime state (`pendingResumes_`, etc.) is not visible
to timer-thread GCs. It didn't change the specific SpawnGCChurn
symptom — the stale HP there is in main's *own* nursery — so the fix
was not retained. Still a concern for any test with long-running
timer closures.

### Also tried (rolled back)

- A full refactor of `Process.sleep` so that timer threads only
  *signal* and main's `drain()` fires the resume (eliminating
  cross-thread JIT calls entirely). Introduced 60-second timeouts in
  8 other tests, suggesting a missed wake-up in the
  `readyResumes_`/`pendingAsync_` interaction. Reverted.
- A `millis == 0` fast path that runs the resume synchronously on the
  caller's thread (bypassing the timer thread entirely). Did fix
  SpawnGCChurn in isolation — confirming the bug is thread-related —
  but relies on `invokeResumeAndRelease`/recursive `resumeMutex_` from
  H2, which is rolled back. Not retained.

## Current code state

Only the H4 change is in the tree for this session. All other listed
items (H1 mutexes, H2 `invokeResumeAndRelease`, H5 global scanners,
`millis == 0` fast path, signal-based refactor) are rolled back; the
Scheduler uses the pre-session `takePendingResume`/`callClosure1`
split and the thread-local external scanner.

## Remaining work

1. **H3 follow-up** — inspect generated assembly / stackmaps for
   `lambda_17$cap` to confirm or refute RS4GC missing a register spill.
   This is the top candidate for the actual SpawnGCChurn root cause.
2. **H5 properly** — thread-aware external-scanner design so
   cross-thread Scheduler data structures don't get collected by timer
   GCs. Needs a discussion of whether to go global-scanner or
   stop-the-world-synchronized.
3. **H1/H2** — either reinstate with the H5 design above, or leave
   the current non-locked accessors documented as intentional. The
   current state is racy per the C++ memory model but the races
   haven't (yet) been observed to produce a visible failure after
   other fixes from earlier cycles.

## Other failure — BytesRoundtripMixedRecord

Unchanged from prior report: `[eq] tag mismatch: 0 vs 3` in a bytes
roundtrip. Unrelated to the async/scheduler path. Independent
investigation required.
