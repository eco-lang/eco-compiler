---
status: done
updated: 2026-10-30
---

# Plan: Fix the likely bugs found by the 2026-10-30 triage of `cpp-review-bugs.md`

## Context

On 2026-10-30 the 96 "possible" entries of `cpp-review-bugs.md` were triaged against the code of
that day. 17 became likely-bug. Each verdict line in `cpp-review-bugs.md` says why, and 13 name an
expected-fail test that asserts the correct behaviour and fails today. This plan fixes all 17.
The 14 low likely-bugs from the original review that are still open (UTF-8/base64 decoders,
`eco_int_pow`, HttpService, eco_embed, the driver papercuts, ...) are not in it.

Rules:
- **The tests come first and are already written.** A fix is done when its expected-fail test passes
  and the expected-fail marker is removed, which turns it into a plain test:
  - E2E: drop the `-- XFAIL-NATIVE:` line;
  - codegen / bf-codegen: drop the `// XFAIL:` line;
  - unit: rename `[xfail RB-n]` and replace `XfailGuard::report` with plain asserts;
  - driver: pass 0 for the check's xfail argument in `test/scripts/check-driver-cli.sh`.

  Until then the marker makes a fixed test fail as XPASS, so nothing is left marked by accident.
  `ECO_TEST_XFAIL=strict` runs the unit, codegen and driver ones as plain tests.
- Change a test only where the fix legitimately changes the expected text, and say so in the commit.
- Read `design_docs/invariants.csv` before any codegen, runtime or representation change (CLAUDE.md).
- **Kernel license.** A change to a file pinned in `kernel-license-files.csv` needs re-audit rows
  dated after the pin date, then `check-kernel-license-manifest.sh --update`. The pinned files here
  are `runtime/src/platform/Scheduler.cpp` and `elm-kernel-cpp/src/core/String.cpp`.
- **TLA+ canary.** A change inside a hashed region (`ThreadLocalHeap.cpp` `TLH.majorGC`) needs an
  AUDIT.md entry, then `check-tla-manifest.sh --update` (test/tla/README.md, "The canary").
- Run tests once, output to a file; `ulimit -c 0` first. Commit messages follow `GITSTYLE.md`.

### Baseline (2026-10-30)

| Gate | Result |
|---|---|
| `full` | test/test 2,576/2,576 (13 expected-fail tests reproduce); JS E2E 221/221; node-addon 4/4; driver-cli 1 XFAIL |
| Entry ids | `RB-<n>` and the line numbers below are the entries' header lines in `cpp-review-bugs.md` at triage time |

## Order

Fixes are grouped by who can hit them:

| Phase | Steps |
|---|---|
| 1. Elm programs see them | 1a String kernels, 1b scheduler kill and double delivery |
| 2. Runtime robustness | out-of-memory, config validation, trace gating, TSan reservation |
| 3. Latent codegen defects (hand-written MLIR only today) | 3a–3e |
| 4. Developer tools | JIT error handling, JIT symbol map, eco-boot `--emit=mlir` |
| 5. Windows-only | 5a–5b, needs a Windows build |

Each step is one commit.

## Phase 1: defects ordinary Elm programs hit

### 1a. String kernels differ from elm/core (`StringOps behaviour diverges from elm/core JS`)

- **Test:** `test/elm-conformance/src/StringKernelEdgeTest.elm` (XFAIL-NATIVE; expected output
  recorded from Elm on node).
- **Fixes:**
  - **`String.indexes ""`** returns `[]`. In `StringOps.cpp`'s `indexes`, return the empty list when
    the needle is empty. JS `_String_indexes` returns no index then.
  - **`String.toInt`** accepts one leading `+` (`StringOps.hpp`, the `from_chars` path). After a sign
    there must be at least one digit, and `"+-5"`, `"++5"`, `"+"` and `"-"` stay `Nothing`.
    `std::from_chars` rejects `+`, so skip a `+` by hand.
  - **`trim`, `trimLeft`, `trimRight`** strip exactly JavaScript's `\s` set:
    - TAB, LF, VT, FF, CR, SPACE;
    - U+00A0, U+1680, U+2000–U+200A, U+2028, U+2029, U+202F, U+205F, U+3000, U+FEFF.

    Today they strip only space, tab, LF and CR. Put the set in one predicate, shared by the
    UTF-16 and UTF-8 string paths.
  - **`String.words`** (`elm-kernel-cpp/src/core/String.cpp`) is `trim` then a split on runs of the
    same set, as JS `str.trim().split(/\s+/g)`. So `words ""` and `words "   "` give `[""]`.
- **Gates:** `String.cpp` is license-pinned, so add re-audit rows for the `Elm.String.*` kernels it
  pins.
- **Also add rows** recorded from Elm to the test while fixing:
  - `trim` on a string made only of whitespace;
  - whitespace inside a rope or slice;
  - a UTF-8 (non-widened) string with NBSP at both ends.

### 1b. Scheduler: `Process.kill` of a runnable process, and duplicate self-message delivery

These two have one root cause: the run queue holds immutable Process *versions*, and every step
steps the version it was queued with. Elm's JS scheduler has one mutable process instead.

- **Tests:**
  - `test/elm-conformance/src/ProcessKillRunnableTest.elm` (XFAIL-NATIVE): a killed runnable child
    logs "survived runnable" natively.
  - `[xfail RB-448]` in `test/platform/SchedulerPidTest.cpp`: two sends before one drain deliver
    `[1,1,2]`.
- **Fix:**
  - **Step the latest version.** `stepProcess` resolves each run-queue entry to the latest version
    registered for its id (`latestProcessById`) and steps that. This matches JS, where a process
    queued twice consumes its whole mailbox in the first step, and the second step finds it empty.
    A queued id with no latest version (finished or killed) is dropped.
  - **Kill marks the id dead.** `killBindingBody` erases the target's `latestProc_` entry and
    self-handler, records the id in a `killedProc_` set, and still calls a parked Binding's kill
    handle. Any later step of that id is dropped, as JS's `proc.f = null` does, and so is a
    `rawSend` to it.
- **Hazard to resolve first:** after a *synchronous* resume inside a Binding callback,
  `stepProcess`'s `setRoot` registers the parked Binding copy as latest *after* the callback has
  already enqueued the resumed version. With "step the latest", the resumed version would be
  skipped and the Binding re-run.
  - **Fix the ordering:** record whether the callback resumed the process, and if it did, do not
    create or register the parked copy.
  - **Audit every `registerLatestProcess` caller** (`procWithRoot`, `procWithStack`,
    `procWithMailbox`, `rawSpawn`) for the same pattern.
- **Also check:**
  - SD-1's process-id wrap tests (`SchedulerPidTest.cpp`) still pass;
  - `finishedProc_` / `keepResult_` keep the finished version, not a stale one;
  - `elm-kernel-cpp/src/http/HttpExports.cpp`'s drain-after-every-tick workaround (`:431-437`) is no
    longer needed. It can stay, since it is harmless.
- **Gates:**
  - `Scheduler.cpp` is license-pinned (`Elm.Scheduler.*` rows): add re-audit rows.
  - Run the eco-system E2E (Http, ChildProcess, Stream), the stress suite and the JS runner, since
    the scheduler is shared by everything.

## Phase 2: runtime robustness

### 2a. Out of memory in large pointer-bearing allocations (`Release-build OOM paths return or dereference null`)

- **Test:** `[xfail RB-141]` in `test/allocator/ReviewBugGuardsTest.cpp` (largeBodyChurn isolated
  suite): YLOS exhaustion asserts in `allocateYoungLarge` instead of reporting out of memory.
- **Fix:**
  - Generalise `largeBodyExhausted` into a `[[noreturn]] heapExhausted(kind, size)` that prints
    "eco: out of memory: ..." with the old-generation figures and aborts.
  - Call it after the major-GC retry fails in every `ThreadLocalHeap` path that can fail:
    `allocateYoungLarge`, `allocateLargePinned`, `allocatePermanent`, `allocate`'s nursery fallback
    and `allocateSlowRaw` (behind `eco_alloc_inline_slow`).
  - Remove the `assert(obj && ...)` / `return nullptr` pairs, so release and checked builds fail
    the same way.
- **Check:** none of the paths is inside a TLA-hashed region (`allocate*` are outside `TLH.*`). If
  the helper lands inside one, follow the canary rule.

### 2b. `HeapConfig::validate` and `alloc_buffer_size` (`alloc_buffer_size is not required to be a page multiple`)

- **Test:** `[xfail RB-255]`.
- **Fix:** in `validate()` (`AllocatorCommon.hpp`, AllocBuffer constraints), also require
  `alloc_buffer_size % OS_PAGE_SIZE == 0`.
  - Fix the message, which claims 4 KiB is an x86-64 value; it applies to every target except Apple
    arm64.
  - The manifest's census line for `AllocatorCommon.hpp` does not hash `validate`. Check with
    `check-tla-manifest.sh` anyway.
- **Follow-up, not in this step:** `OS_PAGE_SIZE` is a compile-time constant, so a 16K/64K-page
  Linux arm64 host is not covered. Note it in the plan's progress notes.

### 2c. Heap-trace dumps not gated (`majorGC trace dumps are not gated by the runtime switch`)

- **No test:** this only shows in `-DECO_HEAP_TRACE=ON` builds.
- **Fix:** wrap the two `dumpHeapState` calls in `ThreadLocalHeap::majorGC` (`:832`, `:1012`) in
  `if (Allocator::heapTraceEnabled())`, as every other call site is, and delete the comment that
  admits the gap.
- **Gate:** both are inside `TLA-REGION(TLH.majorGC)`. The change is diagnostics-only, so add an
  AUDIT.md entry for M1, M5 and M8 saying no model is affected, then `--update`.
- **Verify** by building once with `-DECO_HEAP_TRACE=ON`: no dump without `ECO_HEAP_TRACE`, a dump
  with it.

### 2d. `reserveAddressSpaceBelow` under ThreadSanitizer (`POSIX reserveAddressSpaceBelow TSan loop ignores the limit`)

- **No test in the default build:** only ThreadSanitizer builds take the probing loop.
- **Fix:**
  - In `runtime/src/allocator/PlatformVirtualMemory_posix.cpp`, bound the loop by `limit` as well as 512 GB.
  - Reject a result where `got + size > limit`, releasing the reservation and returning null.
  - Drop the exception from the header comment.
- **Test:** add the agent's case to `test/allocator/AddressSpaceReservationTest.cpp`: reserve 1 GiB
  below 32 GiB, and the result is null or entirely below the limit. It passes trivially outside
  TSan. Run it in the `gc-heap-tsan` / TSan unit configuration once.

## Phase 3: latent codegen defects

Nothing the front end emits reaches these today. Each fixture is the only test, so also check that
no E2E `.mlir` changes. Wipe the E2E caches first, per CLAUDE.md and memory.

### 3a. Closure call layout for `_capture_abi` without `_fast_evaluator` (`Closure eval layout labels new args PK_Boxed ...`)

- **Test:** `test/codegen/papextend_capture_abi_layout.mlir`: the runtime un-boxes a raw Int new
  argument and asserts in `spliceArgsForSaturatedCall`.
- **Fix:** in `EcoToLLVMClosures.cpp`, the `_capture_abi`-only branch (`~:2677`, and the twin at
  `~:2898`) must build the evaluator layout's first `num_newargs` kinds from the NEW arguments'
  types, as `emitFastClosureCall` does. Today it uses `[capture kinds..., 0 x new args]`.
- **Contract:** check against `RuntimeExports.cpp` (`eco_apply_closure_eval`,
  `spliceArgsForSaturatedCall`), which reads kinds `[0, num_newargs)` as the new arguments'. Write
  that contract down in `EcoToLLVMClosures.cpp` next to the layout builder.

### 3b. Two-alternative string `case` (`Two-alternative str case lowered by constructor tag`)

- **Test:** `test/codegen/case_string_two_alt_jit.mlir`, where "world" takes the "hello" branch.
- **Defect:** EcoControlFlowToSCF has two patterns that can take a string case:
  - `CaseStringToScfIfChainPattern` lowers a `str` case to string compares, but only when the case
    is nested in an scf op. A top-level string case is left as `eco.case` for EcoToLLVM, which
    lowers it with string compares.
  - `CaseToScfIfPattern` is the generic two-alternative pattern. It has no `isStringCase` check, so
    it takes a top-level two-alternative string case and compares the string's constructor tag
    with `tags[1]`. That is meaningless for a String, so every string takes the same branch.

  The more-than-two-alternative pattern already declines string cases (`~:416`).
- **Fix:**
  - `CaseToScfIfPattern` declines string cases (`isStringCase`). A top-level two-alternative string
    case then stays `eco.case` and is lowered with string compares, as a three-alternative one is.
  - Confirm EcoToLLVM's string-case lowering (EcoToLLVMControlFlow) handles two alternatives. The
    fixture's JIT run shows it does.
- **Check:** an Int or Char two-alternative case still takes `CaseToScfIfPattern`
  (existing fixtures).
- **Front-end pin:** `test/elm/src/StringCaseTwoAltTest.elm` (E2E, passes today) checks with
  `CHECK-MLIR-NOT` that no Elm match produces a single-pattern string case. A single string pattern
  becomes `eco.value.eq` plus a Bool case. It stays after the fix, as a guard on the front end's
  shape.

### 3c. Aggregates holding GC pointers across a function or block boundary (`make.closure keeps an env aggregate ...`)

- **Test:** `test/codegen/make_closure_env_arg_fca.mlir` (ECO_FCA_SCAN): an env that arrives as a
  function argument reaches RS4GC as an aggregate holding a GC pointer.
- **The defect is general, not closure-specific.** A `!eco.tuple2<i64, !eco.value>` function
  argument fails the same scan.
  - RS4GC cannot relocate a GC pointer inside an LLVM struct. So any value aggregate (REP_AGG_001:
    tuple2, tuple3, record, custom, cons, closure_env) with a boxed field that crosses a safepoint
    as a struct leaves a stale pointer after a collection.
  - FoldExtractValuePass only removes aggregates built and consumed in one function. A function
    argument or result, or a block / region argument or result, keeps them.
  - The front end never produces such a boundary today. The 2026-10-30 census of the compiler's own
    self-compile found 2,109 aggregate constructions, and none in a function signature or a
    `case` / `scf` result.
- **This release: a hard compile error, not a dialect rule.** A check in the lowering (EcoToLLVM,
  before conversion, after every eco-level pass) rejects with a clean error, naming the function
  and the type:
  - a function argument or result,
  - or a block / region argument or result (`scf.if` / `scf.while` / `eco.case` results, `cf`
    block arguments),

  whose type is a value aggregate with a boxed field. Message: "aggregate with a GC pointer as a
  function argument / block argument is not supported yet (see
  plans/aggregate-boundary-scalarization.md)".
  - It turns a silent miscompile into a loud one and leaves the IR and the verifier open.
  - It is deleted when scalarization lands.
  - Aggregates with no boxed field (all i64 / f64 / i32) are unaffected.
- **Test changes** (legitimate, say so in the commit):
  - the fixture becomes `not %ecoc` plus the new message;
  - add a tuple2 case (function argument) and an `scf.if`-result case beside the closure_env one;
  - add a control: an all-unboxed `!eco.tuple2<i64, i64>` argument still compiles;
  - the `value_make_closure.mlir` FCA leg stays as the in-function control.
- **Gates:**
  - `full` and the bootstrap must stay green; a hit there is a real producer, so investigate it.
  - Record the restriction in `invariants.csv`, beside REP_AGG_001, as enforced by the lowering
    check.
- **The real fix**, scalarizing aggregates at these boundaries, is out of scope for this release. It
  is outlined in `plans/aggregate-boundary-scalarization.md`.

### 3d. `eco.to_heap` cons `head_kind` vs head type (`EcoToLLVMValueAgg cons head_kind vs head type`)

- **Test:** `test/codegen/to_heap_cons_head_kind_mismatch.mlir`, which today compiles with exit 0.
- **Fix:** `ToHeapOp::verify` (`EcoOps.cpp`) checks a cons's `head_kind` / `head_unboxed` against
  the head type with the same rule as `ListConstructOp::verify`: boxed head means kind 0 and not
  unboxed; i64 / f64 / i32 heads mean kinds 1 / 2 / 3. The error message must name `head_kind`.

### 3e. `__eco_sat_end` for primitive-result closure calls (`Primitive-result closure calls emit an unmatched __eco_sat_begin`)

- **Test:** `test/codegen/sat_bracket_primitive_result.mlir`.
- **Fix:** in `emitInlineClosureCall` (`EcoToLLVMClosures.cpp`, the `desiredKind != 0` branch,
  `~:2357`), emit `emitSatEnd` before returning, carrying the primitive result (or its boxed form,
  whichever the `$sat` expansion expects). Read `expandSatMarkers` (`EcoBackend.cpp`) first, and drop
  the dead inline resolve.
- **This changes generated code for ordinary programs.**
  - Run `full` and the bootstrap. Fixed points must hold, since the output of the compiler's own
    code changes.
  - Then a `benchmarks/fe-opt-loop.md` regression row. A speed-up is expected; at minimum FLAT.

## Phase 4: developer tools

### 4a. JIT backend errors abort (`JIT: cantFail on fallible paths`)

- **Test:** `test/codegen/jit_backend_error_reported.mlir`, where ecoc dies with SIGABRT.
- **Fix:** in `EcoJIT::create` (`runtime/src/jit/EcoJIT.cpp`), return the transformer's error
  (`tsm.withModuleDo(...)`) and `addIRModule`'s error instead of wrapping them in `cantFail`.
  - Callers (`ecoc.cpp`, `EcoRunner.cpp`) already print "Failed to create execution engine: ...".
  - Do the same for `registerSymbols`, which can fail when a module defines a runtime symbol name.
  - Update `EcoJIT.h`, which documents these as impossible.

### 4b. `eco_enable_list_chunks` missing from the JIT symbol map

- **Test:** `test/codegen/jit_list_chunks_enable.mlir`.
- **Fix:** register `eco_enable_list_chunks` in `buildRuntimeSymbolMap` (`RuntimeSymbols.cpp`).
- **Audit the map against `materializeAllRuntimeDecls`:** every runtime symbol generated code can
  call should be in it. Add a unit check that diffs the two lists, so the next missing symbol fails
  a test instead of only `ecoc -emit=jit`.
- **Delete** the dead `registerRuntimeSymbols(mlir::ExecutionEngine&)` overload.

### 4c. `eco-boot --emit=mlir` on a `.mlir` input (`eco-boot CLI edge cases`)

- **Test:** `test/scripts/check-driver-cli.sh` (`emit-mlir-on-mlir-input`): links an executable
  into a file named `-` and exits 0.
- **Fix:** in `eco-boot.cpp`, `--emit=mlir` on a `.mlir` input prints the (parsed, verified) module
  to the output path (`-` = stdout).
  - Alternative: refuse with "--emit=mlir needs an .elm input"; the check accepts either.
  - Whichever is chosen, no path may fall through to the executable link.
- **Same step:** clamp `-O` on `--emit=llvm` as the exe path does, and remove the empty temp files on
  the error returns.

## Phase 5: Windows-only

These need the `win-build` preset. There is no Windows host in this container, so they are written
here and verified on Windows.

### 5a. `cmd /s /c` quoting in `Spawn.cpp` (`Spawn: Windows shell quoting ...`)

- **Fix:** quote for `cmd.exe`, not with `\"` escapes. Either pass the command line to
  `cmd /s /c "<line>"` without re-escaping inner quotes, or escape cmd metacharacters with `^`.
- **Test:** a Windows block in `test/platform/SpawnTest.cpp`: `echo "a b"` through the default shell
  prints `"a b"`.
- **Same step:**
  - fix the `Eco.Process.spawn` handle leak (a handle registered by spawn and never waited stays in
    `g_handles`), by releasing it when the Process value is finished with or at exit;
  - fix `ChildProcess.run`'s unclosed `ch.process`.
- **POSIX part of the entry:** ChildProcess `killJob`'s reap race (a SIGTERM can hit a reused pid
  between the WaitService reaping and `waitDrain`) is not deterministic to test. Fix it by having
  the WaitService thread wait with `waitid(..., WEXITED | WNOWAIT)` and reap on the main thread when
  the job is completed, or record it as accepted.

### 5b. Windows exit codes (`Windows exit codes >= 0x80000000 become negative`)

- **Fix:** in `WaitService.cpp` (Windows), map an NTSTATUS exit code (`0xC0000000` and above) as
  `Spawn.cpp` does (a "signal"), not as a negative int.
  - Keep exit codes non-negative, so they never collide with `kWaitFailedExitCode` (-1). The
    consumer tells a failed wait by `Ready::error`.
  - Also fix `ChildProcess.cpp`'s `completeRun`, which on Windows always reports failure with
    code -1.
- **Test:** a Windows case in `PlatformServicesTest.cpp`: a child exiting with `0xC0000005` gives a
  non-negative code distinct from -1.

## Phase 6: gates and close-out

After the last step:
1. `full`: every former expected-fail test is now a plain test; no XFAIL, XPASS or failure.
2. `elm-tests`, JS runner, stress suite, bootstrap (4b / 8c fixed points, 9b).
3. Kernel license and TLA canary green.
4. An `fe-opt-loop.md` regression row (needed for 1b and 3e, which change runtime and codegen paths
   the self-compile uses).

Then:
- In `cpp-review-bugs.md`, mark each entry FIXED with its date and recount the summary table.
- Set this plan's status to done.

## Progress notes

- 2026-10-30: all phases implemented the same day. 5a and 5b (Windows) are code-complete but
  unbuilt and unrun here; Windows is low priority (user), and PS8d pins 5b for a Windows build.
- `Eco.Process.wait` (Process.cpp `waitServiceDrain`) first kept narrowing the exit code to `int`,
  because Process.cpp had already been re-audited that day and the license checker only took
  dates. It now takes UTC stamps (`check-kernel-license-manifest.sh`), so the widening landed the
  same day, with stamped re-audit rows for the four `Eco.Process.*` kernels.
- Gates: see plans/char-simple-case-mapping.md's progress notes (same tree): `full`, elm-tests,
  stress, bootstrap green. Benchmark: benchmarks/fe-opt-loop.md row "CharSimple", FLAT.
