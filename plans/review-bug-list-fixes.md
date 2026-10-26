# Plan: Fix the Defects Confirmed in `review-bug-list.md`

**Status: DONE 2026-10-24.** All phases implemented; every phase-0 test passes. Gates: elm-tests
918/0 + 14,436/0; `full` rc 0 (test/test 2,492/2,492, JS E2E 208/0, 4 skip); stress 114/0; bootstrap
4b and 8c fixed points and 9b OK; kernel license manifest, ctor-tag and kernel-home checks clean.
Closed by the maintainer: SD-11 (behaviour unchanged) and SD-15 (browser check not needed).
`global_uninitialized_read.mlir` deleted. SD-16's native side (kernel tables keyed by home and name only)
was fixed on 2026-10-26 by plans/kernel-table-prefix-keys.md. Progress notes per phase are at the
end.

## Context

`review-bug-list.md` lists 27 suspected defects (SD-1 to SD-27) found while writing the program
theory. On 2026-10-24 each one was re-traced in the code and given a verdict. Every real or latent
defect now has a test that fails against the current code and passes once the defect is fixed. One
more defect turned up during the triage (MIN_INT divided by -1) and is included here.

Rules for this plan:
- **The tests come first and stay as written.** A fix is done when its listed tests pass. Change a
  test only when the fix legitimately changes the expected text (for example an error message
  chosen during the fix). Say so in the commit message.
- **Read `design_docs/invariants.csv` before any codegen, runtime or representation change**
  (CLAUDE.md). Several fixes below add the checks that invariants already describe.
- **After any compiler change, wipe the E2E caches** before trusting E2E: `build/test/*/eco-stuff` and
  the `~/.eco/0.1.3` package `*artifacts.dat` and `eco/kernel` copy.
- Commit messages follow `GITSTYLE.md`, with no tool attribution trailers.

### Baseline at the start (2026-10-24)

| Gate | Result |
|---|---|
| elm-tests | 14,417 passed, 17 failed. All 17 are the new SD tests below. |
| New C++ unit, harness and fixture tests | 6 pass (guards), 25 fail as intended. |
| E2E `BytesFusedEncodeCursorSurvivesGCTest` | fails: `mismatches=3672 width=4004` |
| SD-20 fixtures (phase 0) | 4/4 pass |
| `check-ctor-tags.sh` | OK |
| Previous full gates (2026-10-23) | JIT E2E 2,455/0, stress 114/0 |

### Verdicts that need no fix

| SD | Verdict |
|---|---|
| 3 | Already fixed; `CafHoistTest.elm:130` covers it. |
| 10 | Harmless: `Borrow.run` returns the graph unchanged and nothing reads its facts. |
| 11 | Documented design (one serial HTTP worker). See the decision in phase 6. |
| 15 | Probably not a bug: within the inline script, 2 lines precede the JS. `HtmlLeadingLinesTest.elm` pins the current value. The reasoning about browser line numbering was not checked in a browser; check it in phase 6. |
| 17 | Not a bug: the fallback is reachable only by pairs Elm's types forbid. The four SD-17 unit tests pass and guard it. |
| 18 | Tags match today; `test/scripts/check-ctor-tags.sh` now guards them (in `check` and `full`). |
| 24 | Already removed (2026-10-23). |
| 13, 14, 19, 27 | Comments or invariant text only; see phase 6. |

## Phase 0: Tests (done)

Exposing tests, all failing today unless marked:

| SD | Test | Failure today |
|---|---|---|
| 1 | `test/platform/SchedulerPidTest.cpp` (3 cases) | kill hits C, self-process not `Task_Receive`, finished process still in `latestProc_` |
| 2 | `compiler/tests/Compiler/Eco/ConfigTest.elm` | 3 of 5: `Ok EngineSubst` vs `Ok EngineSolver` |
| 4 | `test/codegen/sd4_{tuple2,tuple3}_unboxed_bitmap_mismatch.mlir`, `sd4_list_head_kind_mismatch.mlir` | no verifier error |
| 5, 21, CHECK order/DAG | `test/codegen/CodegenHarnessSelfTest.hpp` (6 cases, in `test/main.cpp`) | harness accepts each bad fixture |
| 6 | `test/codegen/sd6_direct_call_arg_{type,count}_mismatch.mlir` | no verifier error |
| 7 | `test/codegen/sd7_pap_extend_newarg_via_{block_arg,param_fast_evaluator}.mlir` | no verifier error |
| 8 | `compiler/tests/TestLogic/Generate/CodeGen/PapExtendResultCheckerTest.elm` | typed-mode `i1` result accepted |
| 9 | `compiler/tests/Mlir/PrettyTextRoundTripTest.elm` | 9 of 12 |
| 12 | `compiler/tests/Compiler/Generate/MLIR/UnscopedTailJumpTest.elm` | unscoped `eco.jump` emitted |
| 16 | `compiler/tests/Compiler/Generate/KernelHomeCollisionTest.elm` | eco/kernel `File` chunk lost |
| 22 | `test/elm-bytes/src/BytesFusedEncodeCursorSurvivesGCTest.elm`, `test/bf-codegen/bf_cursor_survives_minor_gc.mlir` | corrupt bytes after minor GC |
| 23 | `compiler/tests/Compiler/Generate/MLIR/BytesFusion/EmitReadUtf8OkTest.elm` | `ok` result unused |
| 25 | `test/codegen/typetable_polymorphic_constraint.mlir` | constraint byte `\00` |
| 26 | `test/kernel/UtilsAppendEqualityTest.cpp` (6 `[latent]` cases; 2 controls and 4 SD-17 guards pass) | `""` not equal to a zero-length heap String |
| new | `test/codegen/int_div_rem_min_by_neg1.mlir` | garbage value for MIN_INT // -1 |
| 20 | `test/codegen/rc_placeholder_ops_roundtrip.mlir` (new pin) and `refcount_rejected.mlir`, `free_rejected.mlir`, `reset_rejected.mlir` (the three old XFAIL `*_noop.mlir` fixtures, renamed and rewritten) | **pass**: they pin today's behaviour, see below |

**SD-20 (done).** The six reference-counting ops (`incref`, `decref`, `decref_shallow`, `free`,
`reset`, `reset_ref`) are kept for future Perceus-style memory management. The old fixtures were
XFAIL (so never run), expected the ops to be no-ops (the pipeline rejects them), and did not parse
(the ops have no custom assembly form; `reset`/`reset_ref` also return a value). Now:
- `rc_placeholder_ops_roundtrip.mlir` keeps the op definitions from rotting: each op parses,
  verifies and prints back (`-emit=mlir`).
- The three `*_rejected.mlir` fixtures pin that `RCElimination` rejects each op by name.
- When reference counting is implemented, replace those CHECKs with the real lowering. Also consider
  renaming `RCElimination`, which eliminates nothing.

## Phase 1: Make the codegen harness honest (SD-21, SD-5, CHECK order)

Do this first. Every fixture-based fix later in the plan relies on the harness reporting failures.

1. **SD-21:** `runSubprocessTest` (`test/codegen/CodegenIsolatedTest.hpp:286`) must check `exitCode`:
   non-zero fails unless the RUN line has `not %ecoc`, and `not %ecoc` with exit 0 fails. Apply the
   same rule to JIT-mode `not %ecoc` fixtures.
   - Collateral: add `not` to the 7 fixtures that expect an error without it:
     `eco-case-missing-case-kind`, `eco-case-missing-result-types`,
     `eco-case-scrutinee-invalid{,-chr,-i32}`, `eco-case-type-mismatch`, `verify_construct`.
   - Collateral: `kernel_gcleaf_stamp.mlir` does not parse (`custom op 'eco.call' has no custom
     assembly form`); rewrite it with the generic `"eco.call"` form.
   - `gcfree_plan_local_check.mlir` gets its non-zero exit from SIGABRT. Decide whether an abort is the
     intended way to fail; if not, make it a clean error.
2. **SD-5:** run every RUN line, and honour `--check-prefix`/`--check-prefixes` (or convert the 14
   fixtures to plain `CHECK` with one RUN line each). The 14 fixtures: `caf_memo_basic`,
   `caf_memo_caller_fast`, `inline_alloc_tuple`, `fast_dispatch_direct_call`, `gc_group_split_inline`,
   `kernel_gcleaf_stamp`, `list_map_template_statepoint_free`, `string_code_unit_at`,
   `string_list_append`, `value_eq_fastpath`, `list_map_template_expand`, `list_map_template_kinds`,
   `null_cons_constant`, `string_length_structural`.
   Eight legs fail once they are checked. Fix each one; do not delete it:
   - `kernel_gcleaf_stamp` STAMP: the parse failure above.
   - `caf_memo_basic` GUARD: expects `@__eco_init_globals`/`eco_gc_add_root`; CAF slots are now rooted
     via `eco_caf_promote` (`EcoToLLVMGlobals.cpp:471`). Update the expectation.
   - `caf_memo_basic` JIT, `caf_memo_caller_fast` JIT: `Symbols not found: [ eco_caf_promote ]` under
     standalone `ecoc -emit=jit`. `eco_caf_promote` (`PermanentSpace.hpp:85`) is missing from
     `RuntimeSymbols.cpp`. Register it, which is a real fix. `caf_memo_constant` and `caf_memo_gc` hit
     the same error under standalone `ecoc`.
   - `inline_alloc_tuple` EXP: the slow-path call is now inside a statepoint; update the expectation.
   - `null_cons_constant` EXP: `get_tag` is constant-folded, so the pin no longer tests anything.
     Rewrite it so the value reaches the output.
   - `string_code_unit_at` JIT: `eco.dbg` of i16 prints `'a'`, not `97`. Update the expectation.
   - `fast_dispatch_direct_call` JIT: line 19 is prose that FileCheck reads as a directive; reword it.
3. **CHECK order:** make `CHECK` ordered, `CHECK-DAG` unordered within its block, and `CHECK-LABEL`
   a block boundary, as in FileCheck (`test/CheckPatterns.hpp:9-16,245-250`). Simplest route: shell
   out to the real FileCheck, which the RUN lines already name.
   - Collateral: 7 fixtures list checks out of output order and must be reordered:
     `compare_case_rewrite_structural`, `eval_desc_sat_sizes`, `fast_dispatch_pap_prefix`,
     `gcfree_plan_covered`, `papextend_70_args_root_chunks`, `reach_global_init`, `reach_no_main`.
   - `arithmetic_int_minmax.mlir` will turn red: that is the MIN_INT bug (phase 2, item 3).
4. **XFAIL**: list the remaining XFAIL fixtures and decide for each one: fix, pin as in SD-20, or delete.
5. **Byte-fusion harness** (test gap): give `BFCodegenTest.hpp` the eco harness's
   `requireRegionNursery()` and expected-crash routing (`CodegenIsolatedTest.hpp:198-245`).

**Done when:** the 6 `CodegenHarnessSelfTest` cases pass, and the whole codegen and bf-codegen suites
pass apart from the fixtures listed under later phases.

## Phase 2: High-severity runtime and codegen bugs

1. **SD-22 Bytes fusion cursor vs. GC.**
   - Facts: buffers under 8 KiB are nursery objects (`allocByteBufferBlank`,
     `HeapHelpers.hpp:1667`). The BF cursor is a raw `{i8*, i8*}` pair that is set once and never
     re-derived (`BFToLLVM.cpp` cursor init, around lines 202 and 1016). The encoder compiles each
     written value after `bf.alloc` (`Emit.elm` `emitInitCursor`/`emitOp`), so allocating calls run
     while the cursor is live. `ReadBytesOpLowering` (`BFToLLVM.cpp:940-977`) and `elm_utf8_decode`
     (`ElmBytesRuntime.cpp:265-268`) allocate between taking a source pointer and copying from it.
   - Fix options, to decide at design time:
     (a) evaluate all written values before `bf.alloc` (encoder only, cheapest);
     (b) allocate fused buffers outside the nursery (old generation or large-object space);
     (c) root the buffer and re-derive the cursor after every op that can collect.
     Option (a) plus fixing the two allocate-then-copy sites covers today's reachable paths. Check that
     the decoder's off-heap list rewrite (`eco_scratch_push_scalar`) remains the only reason the
     decoder loop has no GC point, and record that as an invariant.
   - Also fix the `elm_utf8_decode` comment that claims the source "is not Elm GC heap".
   - Fix `BytesLoopFusionGcStressTest.elm`: it claims ~700 minor GCs under an `ECO_HEAP_CONFIG` that
     no harness sets, and neither of its halves fuses in a way that could trip a GC. Make it test what
     it claims, or merge it into the new test.
   - Tests: `BytesFusedEncodeCursorSurvivesGCTest`, `bf_cursor_survives_minor_gc.mlir`.
2. **SD-1 Process ids wrap at 16 bits.**
   - Facts: `Process::id` is 16 bits (`Heap.hpp:69,875`). `nextProcId_` (`Scheduler.hpp:290`) only
     counts up and is truncated at `Scheduler.cpp:231,245,262,432`. `latestProc_` and
     `selfMsgHandlers_` are keyed by it, and `latestProc_` is a GC root that is never erased
     (`Scheduler.cpp:64-81`). One process is spawned per manager per update
     (`PlatformRuntime.cpp:~389`), so three managers wrap after about 21,845 updates.
   - The fix must cover both: no two live processes ever share an id, and a finished process is
     dropped from `latestProc_`. Options: recycle ids through a free list and erase on finish, or widen
     the id (a heap-layout change; check HEAP_* and REP_HEAP_* first).
   - Erasing on finish breaks `PlatformRuntime`'s read of a finished process's result by id after
     `drain` (`PlatformRuntime.cpp:253,396,616`). Hand the result over another way, or erase after
     reading it.
   - `SD-1 finished process not rooted` assumes erase-on-finish. If the chosen fix differs, adapt that
     test, keeping its intent: a finished process must not stay rooted.
   - Tests: the three `platform-services/SD-1 …` cases.
3. **MIN_INT // -1, `remainderBy -1 MIN_INT`, `modBy -1 MIN_INT` (new).**
   - `IntDivOpLowering` (`EcoToLLVMArith.cpp:57-80`) and the remainder/mod lowerings guard only
     `rhs == 0`. `sdiv`/`srem` of MIN_INT by -1 is LLVM UB: garbage once folded, SIGFPE on x86 with
     runtime operands.
   - Expected results (wrapping two's complement): `MIN_INT // -1 = MIN_INT`, and both remainders are
     0. Guard `rhs == -1` (result `0 - lhs` for division, 0 for the remainder ops). Check the kernel
     C++ division paths too, and the `Basics` kernel if division can reach it.
   - Add an invariant row for the division semantics.
   - Tests: `int_div_rem_min_by_neg1.mlir`, plus `arithmetic_int_minmax.mlir` once the harness
     enforces order.

## Phase 3: Compiler front-end bugs

1. **SD-2:** `monoDecoder` (`compiler/src/Compiler/Eco/Config.elm:777`) defaults a missing `engine`
   to `"subst"`. Default it to `default.mono.engine`. Update the doc comments that describe the old
   behaviour (lines 41-42, 567-569, 760-761). Test: `ConfigTest.elm`.
2. **SD-16:** kernel graph keys drop the package (`Details.elm:1602`, `GraphAssembly.elm:103-105`),
   so `Elm.Kernel.File` and `Eco.Kernel.File` collide in JavaScript output. Key kernels by package and
   home. Both kernels' JavaScript also define `_File_size`, so the emitted JS names need the package
   too. Extend `test/scripts/check-kernel-homes.sh` beyond eco/system, and correct
   `plans/eco-system-library.md:105`. Tests: `KernelHomeCollisionTest.elm`. Also rerun the JS
   reproduction (`File.decoder` plus `Eco.File.readString`, built with `--output=x.js`).
3. **SD-9:** in the text MLIR printer (`compiler/src/Mlir/Pretty.elm`), `ppAttr` (715-735) must print
   NaN/±Inf as hex float literals and print floats with round-trip precision.
   `escapeForMlir`/`convertUnicodeEscapesToUtf8` (594) must escape control characters, NUL and a
   decoded backslash. The default bytecode output is unaffected. Test: `PrettyTextRoundTripTest.elm`.
4. **SD-8:** `isValidPapExtendResultType` in `compiler/tests/TestLogic/Generate/CodeGen/PapExtendResult.elm`
   (test-side checker) must reject `I1` in typed mode (REP_ABI_001, CGEN_009, CGEN_056). Also add the
   typed-mode result check to the C++ verifier (`EcoOps.cpp:673-678`), which CGEN_056 notes is
   missing. Test: `PapExtendResultCheckerTest.elm`.
5. **SD-12 (latent):** `generateTailCall` (`Expr.elm:4669-4733`) emits `eco.jump` to target 0 with no
   enclosing join point, breaking CGEN_030. No program reaches it today; `TailRec` handles every tail
   position. Make it fail loudly (crash with a clear message), or delete the branch if the type can
   rule it out. The test expects no `eco.jump`; if the fix crashes instead, change the test to expect
   the crash. Test: `UnscopedTailJumpTest.elm`.
6. **SD-23 (latent):** `emitReadUtf8Nested`/`emitReadUtf8VarNested` (`Emit.elm`, around 1321-1335
   and 1553) drop the `ok` result of `bf.read.utf8`. Fold it into the failure condition, as is
   already done for `bf.require`. Needed before `Decode.string` is ever allowed to fuse. Test:
   `EmitReadUtf8OkTest.elm`.

## Phase 4: Dialect verifiers (SD-4, SD-6, SD-7)

New verifiers can reject IR the compiler already emits, so this phase needs the full gates, including
bootstrap.

1. **SD-4:** add verifiers to `eco.construct.tuple2`/`tuple3` (check `unboxed_bitmap` against the
   operand types) and `eco.construct.list` (check `head_kind` against the head type) in `Ops.td`/
   `EcoOps.cpp`. Collateral: fix the wrong bitmaps in `construct_tuple2_char.mlir:11` (3 → 13),
   `from_heap_jit_contract.mlir:12` (0 → 5), `value_sret_result_llvm.mlir:41,47` (0 → 1),
   `value_sroa_statepoint_llvm.mlir:23` (0 → 1). Tests: the three `sd4_*` fixtures.
2. **SD-6:** `CallOp::verify` (`EcoOps.cpp:866-875`) must check a direct call's operands and results
   against the callee's signature. Tests: the two `sd6_*` fixtures.
3. **SD-7:** the CGEN_003 newarg check (`EcoOps.cpp:101-122`) must also use `_fast_evaluator`'s
   parameter types when the closure's creation cannot be traced, and follow block arguments whose
   incoming values all share a creation. Tests: the two `sd7_*` fixtures.

## Phase 5: Latent runtime defects

1. **SD-25:** `TypeTableOpLowering` (`EcoToLLVMGlobals.cpp:325-357`) has no `case 6` (Polymorphic),
   so the constraint byte is 0, which means `Number`. The printer does read it
   (`RuntimeExports.cpp:3835-3836`). Encode the real constraint, and check that the printer's
   unboxed-element branch handles every constraint value without `assert(false)`.
   Test: `typetable_polymorphic_constraint.mlir`.
2. **SD-26:** HEAP_071 says a zero-length String is never allocated. Enforce it at the remaining
   unguarded producers (`eco_alloc_string_fast`/`_slow`, `eco_init_string_at`), for example by
   asserting `length > 0`, so that the five comparison paths' assumption holds. Alternatively make
   every comparison path treat the two as equal. Pick one and state it in HEAP_071. If producers are
   guarded instead, rewrite the six `[latent]` tests to check that the producers refuse length 0.

## Phase 6: Comments, invariant rows and decisions

- SD-13: CGEN_072 says the fallback fixpoint runs "pre-partitioning". With `ECO_GCFREE_MLIR=0` and the
  MLIR split, it actually runs per partition. Fix the row.
- SD-14: correct the "32-slot record cap" comments in `MonoSolver/Engine.elm` (and
  `AbiCloning.elm:162`, `Borrow/Constrain.elm:19`). They describe the compiler's own state records,
  not a limit on user records.
- SD-19: fix the return-type comments in `eco-kernel-cpp/src/eco-kernel/KernelExports.h` for the
  Task-returning functions (File, Console, Env, Process, MVar, Runtime). Also fix `MVar_new`, whose
  two comment lines contradict each other.
- SD-27: comments in `ExportHelpers.hpp:36-46,62-65` and `UtilsExports.cpp:38` say literals live in
  rodata; they live in PermanentSpace. Fix the `Expr.elm:1927` "boxes all primitives" comment. The
  `True` branch of `boxArgsForClosureBoundary` (`Expr.elm:2783-2800`) is dead (every caller passes
  `False`); remove it. CGEN_059 is already correct.
- SD-15: fix the `Html.elm:27-29` comment that says `leadingLines` "does not match the page", after
  confirming in a browser (Chrome DevTools) that inline-script source maps count from the script's
  own text.
- Invariant rows: TOPT_004 should cite its partial checker (`TestLogic/LocalOpt/TypePreservation.elm`).
  MONO_019 is fine; XPHASE_011 is already "documented".
- **Decision, SD-11:** HTTP requests run one at a time by design, and the timeout
  (`CURLOPT_TIMEOUT_MS`, `HttpService.cpp:230`) starts only when a request starts running. Decide
  whether queue time should count toward `Http` timeouts. That differs from browser elm/http, where
  requests run concurrently.
- Update `review-bug-list.md` with the verdicts and point it at this plan.

## Gates

After each phase, run the tests once and redirect output to a file (CLAUDE.md):
- `cmake --build build --target elm-tests`
- `cmake --build build --target full` (JIT E2E plus codegen; wipe E2E caches first after compiler changes)
- `build/test/test` codegen, bf-codegen, platform-services and kernel suites
- stress suite (`stress-test` is not in `all`; build it by name)
- for phases 3 and 4: bootstrap 4b and 8c fixed points and 9b

Final target: every phase-0 test passes, there are no new failures elsewhere, and elm-tests,
JIT E2E and stress are at least at the 2026-10-23 counts plus the new tests.

## Progress

- **Phase 1 (done).** The harness rules live in `test/CheckPatterns.hpp`, not in an external FileCheck
  (there is no FileCheck on the Windows presets). Exit codes: `not`, and `not --crash` for a fatal
  signal. Every RUN line runs, `--check-prefix(es)` work, and CHECK/DAG/LABEL follow FileCheck order.
  CHECK-NOT is still matched against the whole output; the Elm E2E hosts keep unordered matching.
  `BFCodegenTest.hpp` shares the runner. Also fixed: `eco_crash` with an empty message printed no
  "Elm runtime error:" prefix (XFAIL `crash_empty_message`); `eco_caf_promote` registered in
  `RuntimeSymbols.cpp`; six bf XFAILs revived (stale `bf.write.utf8` syntax). `global_uninitialized_read.mlir`
  was deleted: it read a global before it was written, which compiled code never does.
- **Phase 2 (done).**
  - SD-1: `Process.id` widened to u64 inside the existing 40-byte layout (it took the padding; a
    `static_assert` pins the size). Ids are never reused, finished processes leave `latestProc_`, and
    `PlatformRuntime` reads results through `keepResultOnFinish`/`takeFinishedProcess`. Row SCHED_001.
  - MIN_INT // -1: fixed in the lowering and in kernel `Basics.cpp`. Row CGEN_084. Kernel `modBy 0`
    still throws (as elm/core's JS does) while the inline lowering returns 0; the row records this.
  - New, found in phase 1: shifts by 64 or more were LLVM poison. The count is now taken mod 64 in
    the lowering and in kernel `Bitwise.cpp`. Row CGEN_085.
  - The kernel license rows pinned to `Basics.cpp`, `Bitwise.cpp`, `Scheduler.cpp`, `UtilsExports.cpp`
    and `ExportHelpers.hpp` were re-audited (47 rows), and the manifest was regenerated.
  - SD-22: option (c) in the lowering (`CursorGCSafety` in `BFToLLVM.cpp` inserts
    `bf.cursor.offsets`/`bf.cursor.rebase` around GC points, and marks a buffer that is written
    after a GC point as a builder), plus option (a) in `Emit.elm`. A second defect showed up: writes
    into a buffer that had already survived a GC were lost to the concurrent tenure copy
    (HEAP_SNAPSHOT_001). Hence the builder marking. `ReadBytesOpLowering` and `elm_utf8_decode`
    re-derive their pointers. Row BFOPS_039; BFOPS_004/028 amended. `BytesLoopFusionGcStressTest`
    rewritten: no heap config needed, 14 real minor GCs.
- **Phase 3 (done).** SD-16 is fixed for JavaScript output. Eco kernels are keyed by
  `Eco.Kernel.<Home>` and named `_Eco_<Home>_<name>`, and output for elm/*-only programs is
  byte-identical. The native side, where kernel typing, `KernelFacts` and `KernelSetFacts` keyed by
  home alone, was fixed on 2026-10-26 by plans/kernel-table-prefix-keys.md. SD-12 became an explicit crash, and its
  test was restructured because Elm tests cannot catch a crash.
- **Phase 6 (done, except the SD-11 decision).** CGEN_072 and TOPT_004 rows corrected; comments fixed
  for SD-14, SD-15 (no headless browser here, so the comment states the reasoning is unverified),
  SD-19 and SD-27; dead `True` branch of `boxArgsForClosureBoundary` removed. SD-11 is left as a
  decision for the maintainer: the serial worker is unchanged.
- **Phases 4-5 (done).** SD-4: verifiers on `eco.construct.tuple2/tuple3/list` recompute the slot
  kinds; 4 fixtures had wrong bitmaps and none were emitted by the compiler. SD-6: direct
  `eco.call` checks operand and result types against the callee `func.func`. SD-7 and the C++ half
  of SD-8: `traceClosureOrigin` follows partial extends and block arguments, saturated stamped
  sites are checked against the fast clone, and typed results are never i1 (CGEN_056). SD-25: the
  kind-6 constraint byte is written, and the printer prints Polymorphic unboxed elements by slot
  kind. SD-26: every comparison path treats Empty and a zero-length heap String as equal (HEAP_071).
  That exposed a real bug, fixed: `spawnProcessBody` (`eco-kernel-cpp/.../Process.cpp`) returned a
  Record where `Eco.Process.spawnProcess` reads a tuple.
