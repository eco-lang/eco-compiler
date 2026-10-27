---
status: done
updated: 2026-10-27
---

# Plan: Bring the Invariant Catalog Back in Line with the Code

**Status: DONE 2026-10-23.** Phases 1-3 implemented. The pinned rows were settled on 2026-10-26
(see "Pinned"); only an optional HEAP_018 follow-up is left. Gates: elm-tests 918/0 + 14,409/0, JIT E2E 2,455/0, JS E2E 208/0 (4 skip),
stress 114/0, bootstrap 4b + 8c fixed points and 9b OK, TLA canary and kernel-license checks clean.
No new test revealed a compiler or runtime bug. Not done: collapsing the one-constructor
`KernelBackendAbiPolicy` (KERN_006), judged too wide for this plan.

## Context

`stale-invariants.md` (deleted 2026-10-26) listed rows of `design_docs/invariants.csv` that disagreed
with the code, and `stale-invariants-review.md` (since deleted) explained each one: why it is stale, which tests exist, and whether code
enforces it. On 2026-10-23 we walked the list together and chose one action per item. This plan
records those decisions and orders the work.

The code is the reference in every case. Rows keep their numbers. A rule we drop is removed from the
catalog, and every place that cites it is re-pointed or cleaned in the same change.

Actions:
- **Update**: amend the row text, status or source column to match the code.
- **Update + test**: amend the row, then add the named check or test.
- **Remove**: delete the row, and fix everything that cites it.
- **Pin**: leave it for now; the trigger for coming back is given.

## Phase 1: Catalog text updates (no code changes)

One change to `invariants.csv`. Each row's entry in `design_docs/invariant-test-logic.md` is fixed in
the same change: correct its oracle and its `tests:` line, and add entries that are missing.

| Row | Change |
|---|---|
| HEAP_014 | Constant test is the `ptr_ind` bit, not `constant != 0`. Cite `test/allocator/HPointerLayoutTest.cpp`. |
| REP_HEAP_001 | Layouts are computed in codegen (`Types.compute*Layout`) from mono's `ctorShapes`. Cite CtorLayoutConsistency, ProjectionHeapLayoutConsistency, MonoLayoutIntegrity. |
| REP_SSA_001 | Add Bool → `i1` to the immediate types. Cite BoxingValidation, CaseScrutineeType, BooleanConstants. |
| CGEN_009 | Every Bool SSA value in a body is `i1`; it is boxed only at heap, closure and call boundaries. BooleanConstantsTest already checks this. |
| CGEN_025 | `make.tuple2`/`tuple3`/`custom` are produced by the front end (aggPromote); `make.record`/`cons`/`closure_env` have no producer. |
| REP_AGG_001 | Rewrite the producer and sret clauses (sret is on by default; the front end emits sret workers). Repoint the source to the front end, `SretFuncOpLowering` and the SROA lowering. Drop the amendments about the deleted passes. |
| CGEN_058 | Generic apply lowers to `eco_apply_closure_eval`. Cite `papextend_no_realloc.mlir`. Fix the two stale `lowerGenericApply` docstrings in `EcoToLLVMClosures.cpp`. |
| CGEN_059 | Name eval. Add the two front-end boxing cases: Bool (`i1`) arguments, and arguments to a known callee whose parameter is `!eco.value`. |
| CGEN_060 | Fix the backwards clause: `eco_apply_closure_eval` handles exact calls, recurses for over-saturation and calls `eco_pap_extend_l` when under-saturated. `_typed` only calls eval. |
| HEAP_033 | Replace the old packed-word layout with a pointer to HEAP_078. `eco_pap_extend` becomes `eco_pap_extend_l`. Cite the `wrapper_*` and `make_closure_packed_word.mlir` fixtures. |
| CGEN_014 | Codegen computes ctor layouts from `ctorShapes` without GlobalTypeEnv. Fix the source column. |
| CGEN_039, CGEN_079(b) | Drop `eco.allocate_ctor`. CGEN_039 becomes "no pass or front end emits `eco.allocate*`; they appear only in fixtures". Remove `allocate_ctor` from `NoAllocateOps.elm`. |
| CGEN_072 | Opening clause: `EcoGcFreePropagation` (MLIR) is the default producer; `propagateGcFreeLeafAttrs` is the fallback (`ECO_GCFREE_MLIR=0`, flagless input, census) and the validate twin. Cite the `gcfree_plan_*.mlir` fixtures. |
| REP_001 | Name the LLVM-level form as a fifth form. Source: `design_docs/theory/value-representation.md`. Status: `documented`. |
| REP_LLVM_001 | The verifier runs under `ECO_LOWERING_VALIDATION`, not `ECO_GC_DEBUG_LIVENESS`. Fix the same mistake in `value-representation.md:135`. |
| HEAP_036 | `ECO_CAF_PERMANENT` is on by default; `=0` disables it. |
| HEAP_069 | Drop "promotion_age must be 1"; the range is 1 to 3. |
| BFUSE_001 | Encoders may fuse with opaque parts (a single-node opaque encoder is not fused); decoders are all-or-nothing. Cite FusionPartialOpaqueTest. |
| BFOPS_037 | Allow the kernel walker calls for opaque encoder parts and the `List.reverse` call in decoders; everything else is inlined. Cite FusionPartialOpaqueTest. |
| LSS_001 | The four constructors `LTop \| LVar \| LSet \| LPartial`. Drop `LUnknown` and its retirement amendment. Remove the stale `LUnknown` code comments (`Functions.elm`, `Store.elm`, `Monomorphize.elm`). |
| LSS_010 | Drop the `keyed=False` and flag-off wording; the join applies to every keyed spec. |
| TOPT_001 | Each node carries `Meta { tipe, tvar }`; `typeOf = (metaOf e).tipe`. |
| KERN_006 | Drop `AllBoxed` and fix the source column. Clean the stale doc comments in `KernelAbi.elm` and `Context.elm`. Consider collapsing the one-constructor `KernelBackendAbiPolicy` type. |
| KERNEL_TASK_IO_001 | Add `system-kernel-cpp/`, and cite SYS_001. |
| HEAP_005, HEAP_007 | Status becomes `enforced`; cite the validate checks, the P1 census, the TLA model and ConcurrencyRegisterTest. Audit the statuses of the other HEAP_* rows the same way. |
| Source columns | Repoint every row in section 4 of `stale-invariants.md` (since deleted): the mono rows to `Compiler.Monomorphize.*` plus `Compiler.MonoSolver.*`; the codegen rows to their specific `Generate/MLIR` module; CGEN_041 to 044 to their own checkers; CGEN_064 and 067 to `SretFuncOpLowering` and the multi-operand `eco.return` lowering; TYPE, TOPT, POST, BFOPS_021, VDOM and the THEORY.md rows to their current modules or theory docs. |
| Text fixes found with section 4 | CGEN_007 `boxToMatchSignature` becomes `...Typed`; TYPE_001 now has a single pathway; VDOM_005 names `Html.Dom` and `toString`/`htmlToString`. Reconcile HEAP_006 with the tenure forwarding table, and HEAP_008's test-logic entry (no 40-bit offsets). |
| CGEN_066 | Retire (a record of a deleted pass). |

Also in this phase:
- Rewrite the `EcoTypeConverter` comment at `runtime/src/codegen/Passes/EcoToLLVMInternal.h:40` to the real conversion: i64/f64/i16 primitives, `i1` Bool in SSA only, everything else `ptr addrspace(1)`. Cite REP_ABI_001 and REP_SSA_001.
- Add `invariant-test-logic.md` entries for CGEN_058, CGEN_059, HEAP_033, CGEN_072 and RUNTIME_CLOSURE_004.
- Delete the GOPT_002 tombstone from `invariant-test-logic.md`. MONO_016 has no row; leave the plans that mention it alone.

## Phase 2: Removals

| Row | Re-point or clean |
|---|---|
| REP_CONSTANT_003 | HEAP_071 already says the Empty constant is the only empty string. Drop the comments in `Patterns.elm` that cite REP_CONSTANT_003, or re-point them to HEAP_071. |
| GC_MODEL_001 | The canary rule lives in `test/tla/README.md`. Re-point every citation there: the CLAUDE.md canary paragraph, the canary messages and comments in `CMakeLists.txt`, `test/tla/` AUDIT and README files, `docs/testing.md`, `docs/build-targets.md`, and the theory docs (`verification.md`, `concurrency-models.md`, `runtime-tests.md`, `runtime.md`, `garbage-collector.md`, `invariants.md`, `invariants-and-design.md`, `build-system.md`). Leave historical plans alone. Check that no TLA-canary pin hashes a file whose text changes, or follow GC_MODEL's re-audit rule for any that do. |
| LSS_009 | Remove the citations in `AbiCloning.elm` and `LssVerbatimCopiesFastDispatchTest.elm`, or re-point them to LSS_018 where the μ-tied clause is meant. |
| LSS_024 | Re-point or remove the citations in `AbiCloning.elm`, `AbiCloningFenceTest.elm`, `LayoutQualTest.elm`, `BorrowFenceTest.elm`, `AbiCloningFlatPeelPassTest.elm`, `LssLayoutQualMemberTest.elm`, `LssInstanceQualTest.elm`, and the BORROW_006 amendment. The fence code and tests stay; only the ID goes. |
| CGEN_012 | Covered by REP_ABI_001 and REP_SSA_001. Drop it from the section 4 source row. Re-point the `EcoToLLVMInternal.h:40` comment (Phase 1). |
| GOPT_002 tombstone | Deleted in Phase 1. |

## Phase 3: Code and test work

Each item is its own commit, with the row amended in the same commit.

1. **CGEN_034, CGEN_056, CGEN_058 (generic `papExtend` result).** Restate all three to match the verifier (`!eco.value`, `i64`, `f64` or `i16`, with `_result_kind`). Set CGEN_034's status to `tested`. Make `PapExtendResult.elm` reject `i1`, which is bug SD-8. Point CGEN_056 at `PapExtendSaturatedResultTypeTest`, and at `HofResidualPartialTest` for E2E.
2. **RUNTIME_CLOSURE_004.** Name `eco_apply_closure_eval`. Say the callee roots the intermediate with `ecoRoot1Push`. Add a `test/allocator` unit test of over-saturated eval across two stages, with mixed kinds and a GC forced between the stages.
3. **CGEN_CLOSURE_005.** Cite the `fast_dispatch_*.mlir` fixtures. Add a verifier check that the `_capture_abi` types equal the `$cap` parameter prefix, and a negative fixture.
4. **HEAP_025.** Rewrite it for the six string forms, the UTF-8 literal leaves, equality and compare that never flatten, and `large_object_threshold`. Add a unit test of equality and compare across all six forms.
5. **MONO_005.** Drop `LambdaId`. Extend `MonoGraphIntegrity` to check every node has a registry entry, `mapping` and `reverseMapping` agree, and SpecIds are unique per key, so that `enforced` is true.
6. **MONO_028.** Make the wording engine-neutral: number residuals survive until Prune closes them to Int. Name `Prune.elm`, `Zonk.elm`, and `TypeSubst` for the subst engine. Run `FullyMonomorphicNoCEcoValue` under both engines.
7. **MONO_019, XPHASE_011.** Keep the text. Re-add a MONO_019 checker for unique lambdaIds after GlobalOpt. Make `Generate/MLIR/Lambdas.elm` crash on a repeated lambda name, instead of silently dropping it. Set MONO_019's status back to `tested`.
8. **OPT_DEBUG_ORDER_001 (bug SD-3).** Make `CafHoist` use `CsePurity`'s transitive Debug check instead of the direct-kernel `hasDebug`. Add a test with hoisting on and an indirect `Debug.log` that is not hoisted. This must land before CAF hoisting is ever turned on by default.

## Pinned

These three rows were left for later on 2026-10-23. They were settled on 2026-10-26.

| Row | Outcome |
|---|---|
| HEAP_018 | **Kept.** The row already has the closure-cycle exception. Optional follow-up, with no trigger: state what stops GC traversal from looping (forwarding words and mark bits), and consider a closure-cycle GC test. |
| CGEN_030, CGEN_031 | **Kept.** SD-12 was settled by deleting the `eco.jump` fallback (`plans/review-bug-list-fixes.md`). Both rows are accurate rules of the dialect, checked by the verifier and `JoinpointNormalization.cpp`. Code generation never emits `eco.joinpoint`, so `JumpTargetTest` and `JoinpointUniqueIdTest` pass trivially on generated code. A tail call outside a loop now stops the compiler with a message citing CGEN_030 (`UnscopedTailJumpTest`). |
| BFOPS_036 | **Removed.** It said fused code allocates nothing but the result, which was false for decoders and for encoders with allocating arguments. SD-22 is fixed, and BFOPS_039 now says what fused code may allocate and how cursors survive it. |

## Already done (2026-10-23)

CGEN_061 and CGEN_062 (code citations corrected), CGEN_CLOSURE_007 and 008 (retired), and the
`_dispatch_mode` part of CGEN_CLOSURE_005.

## Verification

- After each catalog change, parse `invariants.csv` with Python's `csv` module (delimiter `;`) and
  check every row has the same field count as before.
- grep for every removed ID across `compiler/`, `runtime/`, `test/`, `*-kernel-cpp/`, `design_docs/`,
  `docs/` and `CLAUDE.md`. Only `plans/` may still mention them.
- Run the TLA canary in check mode (`sh test/scripts/check-tla-manifest.sh /work`), plus
  `test/scripts/check-kernel-license-manifest.sh`, since comment edits in pinned files move hashes.
- For Phases 1 and 2: `cmake --build build` and `--target elm-tests`.
- For each Phase 3 item: also `--target full`, plus `--target stress` for items 2 and 4. Run
  `--target bootstrap` once, at the end.
- When all of this is done, delete `stale-invariants.md` and `stale-invariants-review.md`. Done:
  both are gone (the first on 2026-10-26).
