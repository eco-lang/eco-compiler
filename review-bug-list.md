# Eco: bugs and potential bugs found while writing the program theory

These items were found between 2026-10-21 and 2026-10-23 while investigating and writing the program theory, which is now in `THEORY.md` and `design_docs/theory/`. The original evidence file, `icm-agents/workspaces/program-theory-writer/theory/review/source-drift.md`, is not in the tree; on 2026-10-24 every item was re-traced from the code instead. The `SD-n` numbers come from that file.

## Status as of 2026-10-24

Every item has been re-checked against the code. Each defect got a test that failed against the old code, and then a fix that makes it pass. The work, with file references, is in `plans/review-bug-list-fixes.md`. Gates after the fixes: elm-tests 918/0 and 14,436/0; `full` (unit and codegen binary 2,492/2,492, JavaScript E2E 208/0, 4 skipped); stress 114/0; bootstrap 4b and 8c fixed points and 9b OK.

| Status | SD items |
|---|---|
| **Fixed** (real bug) | 1, 2, 4, 5, 6, 7, 8, 9, 21, 22 |
| **Fixed** (latent bug: no current path reached it) | 12, 23, 25, 26 |
| **Partly fixed, still open** | 16: fixed for JavaScript output; the native side is open |
| **Not a bug** | 3, 10, 17, 18, 24 |
| **Comment or invariant text corrected** | 13, 14, 19, 27 |
| **Closed by the maintainer** | 11 (no change), 15 (comment corrected; browser check not needed), 20 (ops kept and pinned by tests) |

Severity in the tables below is the original judgment:
- **High**: wrong behavior in real programs, or a test that passes when it should fail.
- **Medium**: a missing check or a fragile coupling.
- **Low**: harmless today, or a comment or documentation fault.

## High

| SD | Area | Description | Current status |
|---|---|---|---|
| 22 | Bytes fusion, GC | Fused `Bytes` encode and decode keep a cursor of raw pointers that the collector never relocates. Buffers under 8 KiB live in the nursery, and fused code allocates while the cursor is live. For example, `bf.read.bytes` allocates and then copies from the old pointer, and decode loops allocate list cells. A minor collection mid-decode leaves the cursor reading moved memory. Encoder fusion is on by default. | **Fixed.** Reproduced on the encoder: 3,672 of 4,004 bytes wrong. A second cause was found as well: writes into a buffer that had survived a GC were lost to the background tenure copy. The lowering now rebuilds the cursor after every point where a collection can happen and marks a buffer still being written as under construction. The compiler computes written values before allocating. A compile-time check rejects any cursor that could still be stale. Invariant BFOPS_039. Tests: `BytesFusedEncodeCursorSurvivesGCTest.elm`, `bf_cursor_survives_minor_gc.mlir`, and two rejection fixtures. |
| 1 | Scheduler | Process ids are truncated to 16 bits, are never recycled, and key the scheduler's tables. A program with three effect managers wraps after about 22,000 updates. After that, self-messages can go to the wrong process and be dropped, `Process.kill` can run another process's kill handle, and finished processes stay rooted. | **Fixed.** Ids are 64 bits, using the header's padding so the heap layout is unchanged, and are never reused. Finished processes leave the scheduler's tables, and killing a finished process does nothing. Invariant SCHED_001. Tests: the three `SD-1` cases in `test/platform/SchedulerPidTest.cpp`. |
| 2 | Compiler config | When a project config has a `mono` section without an `engine` key, the decoder defaults to the old `subst` engine, but `Config.default` uses the solver. Setting only `mono.lss` or `mono.limits` therefore silently switches engines and loses lambda-set specialization. | **Fixed.** A missing `engine` takes the default engine. Test: `compiler/tests/Compiler/Eco/ConfigTest.elm`. |
| 21 | Codegen tests | In subprocess mode the codegen test harness reads the compiler's exit code and never checks it (`runSubprocessTest`). A fixture whose patterns are all `CHECK-NOT` passes even when the compiler crashes or rejects the input. | **Fixed.** A non-zero exit fails unless the RUN line says `not`; `not --crash` expects a fatal signal. Fixtures that expect errors were marked. One hidden failure surfaced: `kernel_gcleaf_stamp.mlir` did not parse, and it was rewritten. Tests: `test/codegen/CodegenHarnessSelfTest.hpp`. |
| 5 | Codegen tests | 14 fixtures in `test/codegen/` assert only through custom check prefixes (`// FWD:`, `// COLLAPSE:`). The harness reads only `// CHECK*` lines and only the first RUN line, so these fixtures check nothing and their second RUN lines never execute. | **Fixed.** Confirmed at exactly 14 fixtures. The harness runs every RUN line and honours `--check-prefix(es)`. The 8 checks that then failed were corrected. Tests: `CodegenHarnessSelfTest.hpp`. |

## Medium

| SD | Area | Description | Current status |
|---|---|---|---|
| 4 | Dialect / lowering | The lowering reads tuple `unboxed_bitmap` and list `head_kind` directly into heap layout, and no verifier checks them. A wrong value from the front end corrupts the layout silently. | **Fixed.** Verifiers on `eco.construct.tuple2`, `tuple3` and `list` recompute the layout from the operand types. The compiler emitted no bad layouts; four fixtures had wrong bitmaps and were corrected. Tests: `sd4_*.mlir`. |
| 6 | Dialect | In the default build nothing checks direct `eco.call` signatures. The verifier defers to a pass that runs only in validation builds and checks something else. A mismatch shows up only in LLVM. | **Fixed.** A direct call's operands and results are checked against the callee's `func.func`. Tests: `sd6_*.mlir`. |
| 11 | HTTP service | One worker runs HTTP requests serially, so a slow request blocks every queued request behind it. | **Closed, no change.** This is the documented design. Time spent in the queue doesn't count toward a request's timeout; the maintainer judged that acceptable. |
| 8 | Tests vs verifier | The Elm-side checker accepts an `i1` result of `papExtend`, but the dialect verifier rejects it. The two checks disagree on the same rule. | **Fixed.** In generic mode both already rejected `i1`. In typed mode the Elm checker was the wrong side, against REP_ABI_001, CGEN_009 and CGEN_056, and now rejects `i1`. The C++ verifier now checks typed-mode results too. Test: `PapExtendResultCheckerTest.elm`. |
| 3 | Global optimization | Constant hoisting checks only direct `Debug` references, not ones reached through called functions, so it could reorder `Debug` output. | **Not a bug.** Already fixed before triage; `CafHoistTest.elm` covers it. |
| 23 | Bytes fusion | Fused decoding discards the validity flag of UTF-8 and bytes reads, so invalid UTF-8 would decode to `Just` instead of `Nothing`. | **Fixed (latent).** The UTF-8 validity flag now guards the rest of the decoder. The bytes read was already harmless (its flag is always 1). Test: `EmitReadUtf8OkTest.elm`. |
| 24 | Closure lowering | The `_closure_kind` branch of `emitClosureCall` calls the evaluator descriptor's address as if it were code. Nothing sets that attribute today, but a comment calls the branch "NOT dead", inviting someone to revive it. | **Not a bug.** The branch was already removed on 2026-10-23. |
| 12 | MLIR generation | `generateTailCall` can still emit `eco.jump` to target 0 without any enclosing join point. Whether any program reaches it was not established. | **Fixed (latent).** No program reaches it. The branch is removed, and such a tail call now stops the compiler with a message naming the function. Test: `UnscopedTailJumpTest.elm`, restructured because Elm tests cannot catch a crash. |
| 15 | JavaScript output | HTML source maps are likely off by 12 lines: `leadingLines` is documented as 2, but the page puts 14 lines before the script. | **Closed.** Probably not a bug: within the inline script, 2 lines come before the JS. The comment was corrected and says this is unverified in a browser. `HtmlLeadingLinesTest.elm` pins the value. |
| 16 | Kernels | Kernel homes are keyed without their `Elm`/`Eco` package prefix, and `Elm.Kernel.File` and `Eco.Kernel.File` already share the name `File`. | **JavaScript: fixed. Native: open.** In JavaScript output the two `File` kernels replaced each other, so a program using both crashed on load. Eco kernels are now keyed by `Eco.Kernel.<Home>` and named `_Eco_<Home>_<name>`. Output for programs using only elm/* packages is byte-identical. Test: `KernelHomeCollisionTest.elm`. On the native side, `KernelTypes`, `KernelFacts` and `KernelSetFacts` still key by home and name. Only `File.size` exists in both kernels, with different types (`File -> Int` and `Handle -> Task IOError Int`). `KernelTypes` keeps the first type recorded, so a native program using both would likely give one call the wrong type. Not yet reproduced; no test yet. |
| 17 | Elm kernel | `Utils_append` silently returns its first argument for argument pairs it doesn't recognize, on the polymorphic path. | **Not a bug.** The fallback is reachable only by pairs Elm's types forbid. Four `SD-17` unit tests in `test/kernel/UtilsAppendEqualityTest.cpp` guard every string and list form. |
| 18 | Front end / runtime | Constructor tag numbers in `Data/CtorTag.elm` must match `Heap.hpp` by hand, and nothing checks that they do. | **Not a bug.** The values match. `test/scripts/check-ctor-tags.sh`, run by `check` and `full`, now guards them. |

## Low

| SD | Area | Description | Current status |
|---|---|---|---|
| 26 | Strings, equality | Only one comparison path treats the empty constant as equal to a zero-length heap string, as REP_CONSTANT_003 says. Every other path treats them as different. This is harmless while no code builds a zero-length string. | **Fixed (latent).** Every equality and comparison path now treats them as equal, and HEAP_071 states the rule; REP_CONSTANT_003 no longer exists. Tests: the `SD-26` cases in `UtilsAppendEqualityTest.cpp`, plus `value_eq_fastpath.mlir`. |
| 25 | Debug type table | The type-table lowering has no case for kind 6 (Polymorphic) and writes zero bytes for its constraint. This is harmless because the printer ignores that field. | **Fixed (latent).** The claim that the printer ignores the field was wrong: it reads it for unboxed list elements. The real constraint is now written, and the printer uses the element's slot kind, so its `assert(false)` can't be reached. Test: `typetable_polymorphic_constraint.mlir`. |
| 7 | Dialect | The typed `papExtend` argument check gives up silently unless it can trace the closure back to its creation. | **Fixed.** The verifier follows block arguments and partial extends. It also checks against the stamped fast clone. Tests: `sd7_*.mlir`. |
| 13 | Lowering | Invariant CGEN_072 names two different producers of the "cannot collect" attribute. Which one runs in every mode was not checked. | **Text corrected.** Each mode has exactly one producer and none disagree. CGEN_072 and a code comment wrongly said the fallback runs "pre-partitioning"; under the MLIR split it runs once per partition. |
| 10 | Global optimization | Borrow inference is not the last step, contrary to its design note. This is harmless because the pass does not change the graph. | **Not a bug.** It returns the graph unchanged, and nothing reads its facts. |
| 9 | MLIR text output | The debug text form of MLIR is lossy: it drops source locations, prints NaN and infinities as nothing, rounds some floats and drops some escapes. The default bytecode output is unaffected. | **Fixed.** NaN and ±Inf are printed as hex bit patterns, and other floats round-trip exactly. Control characters, DEL and backslash are escaped. Test: `compiler/tests/Mlir/PrettyTextRoundTripTest.elm`. Source locations are still not printed. |
| 20 | Dialect | The six reference-counting placeholder operations are reported as errors rather than eliminated. Nothing emits them, and their fixture is marked XFAIL. | **Closed: ops kept for future reference counting.** The three XFAIL fixtures never ran, expected the wrong behavior and didn't parse. They were replaced by `refcount_rejected.mlir`, `free_rejected.mlir` and `reset_rejected.mlir`, which pin the rejection message for each op. `rc_placeholder_ops_roundtrip.mlir` checks that the ops still parse. |
| 14 | Monomorphization | Comments in `Engine.elm` treat 32 record fields as a hard cap, but records allow 2047 fields. Only the comments are wrong. | **Text corrected.** No code assumed the cap. |
| 19 | Kernel exports | Comments in eco-kernel's `KernelExports.h` give raw return types for functions that return Tasks. | **Text corrected.** About 20 comments now give the Task type. |
| 27 | Comments, invariants | Several comments and one invariant are stale:<br>• `Export::toPtr` comments say literals live in read-only data; they are interned in a permanent space.<br>• `Expr.elm` comments say all generic-call primitives are boxed; only Bool is.<br>• CGEN_059 names the wrong runtime entry point. | **Text corrected.** `toPtr` and `Expr.elm` comments fixed; the dead `True` branch of `boxArgsForClosureBoundary` was removed. CGEN_059 had already been corrected. |

## Bugs found during the fixes

| Bug | Current status | Test coverage |
|---|---|---|
| MIN_INT // -1, `remainderBy -1 MIN_INT` and `modBy -1 MIN_INT` gave garbage (undefined behaviour in LLVM) | **Fixed** in the lowering and the kernel C++. Division by -1 wraps, and both remainders give 0. Invariant CGEN_084. | `int_div_rem_min_by_neg1.mlir` failed before the fix. The tightened checks in `arithmetic_int_minmax`, `arithmetic_remainderby_edge` and `int_div_minint`, and kernel test K14, were written with the fix and not run against the old code. |
| Shifts by 64 or more gave garbage (LLVM poison; undefined behaviour in the kernel C++) | **Fixed.** The count is taken mod 64 in both. Invariant CGEN_085. | `shift_by_64.mlir` and `shift_by_large.mlir` were written with the fix and not run against the old code. Kernel test K15 probably cannot fail on x86, because the hardware already masks the count. |
| `eco_crash` with an empty message dropped its "Elm runtime error:" prefix | **Fixed.** | `crash_empty_message.mlir` was XFAIL because it failed, and now passes. |
| `eco_caf_promote` missing from the JIT symbol table: standalone `ecoc -emit=jit` failed on programs with cached top-level values | **Fixed.** | **Gap:** no test fails without the fix. The CAF fixtures' JIT checks run inside the test binary, where the symbol resolves anyway. |
| `Eco.Kernel.Process.spawnProcess` returned a record where the Elm code reads a tuple, so `stdinHandle` read a garbage word | **Fixed.** | **Partial:** `ProcessSpawnWaitTest.elm` now crashes if the bug returns, but only via the SD-26 comparison code. Nothing checks the stdin handle directly. |

## Test gaps that could hide bugs

These came from the same file. They are gaps in coverage, not defects themselves.

- **Process-id wrap:** closed. `SchedulerPidTest.cpp` covers it (SD-1).
- **Byte-fusion GC stress test:** closed. `BytesLoopFusionGcStressTest.elm` was rewritten and needs no heap config; at the default config it runs 14 real minor GCs.
- **Byte-fusion test harness:** closed. `BFCodegenTest.hpp` uses the shared codegen runner, with the region-nursery requirement and crash routing.
- **`CHECK-DAG`:** closed. CHECK, CHECK-DAG and CHECK-LABEL now follow FileCheck's ordering. The Elm E2E hosts still match CHECKs in any order.
- **Invariants marked tested:** partly stale. MONO_019's checker exists. XPHASE_011 is already marked documented. The TOPT_004 row now names its partial checker, which covers variables, kernel refs, case branches and non-Int literals, but not calls, lets or functions.
- **CI coverage:** open, not addressed. CI does not run ThreadSanitizer, the GenMC or TLA+ model checks, or the register-guard checks. The TLA+ canary only warns unless `ECO_TLA_CANARY_STRICT` is set, and no preset sets it.
- **New end-to-end package directories:** open, not addressed. They must be registered in two places, or they silently never run.
- **Windows:** open, not addressed. The stress, AOT and equivalence runners are not built there.
