# Stale invariants

These rows of `design_docs/invariants.csv` disagree with the code. They were found while writing the program theory (`THEORY.md`, `design_docs/theory/`). No build step reads the catalog, so rows drift when code moves. In every case below the code is the reference, and the fix is to amend the row in place, keeping its number. A rule whose design was removed should be retired, not deleted.

The evidence for each item is in `icm-agents/workspaces/program-theory-writer/theory/review/source-drift.md`, section 3, and in the Discrepancies sections of the theory notes. The status says how sure each item is:
- **Verified**: confirmed by reading the code.
- **Unverified**: reported by an investigation and not re-checked.

## 1. Rules that state something false

| Row | What it says | What is true | Status |
|---|---|---|---|
| HEAP_018 | Elm values are always acyclic, because Elm has "no recursive let bindings". | Recursive local functions form cycles. A self-capturing closure stores its own address, and a mutually recursive group is allocated together and cross-wired. Plain data values stay acyclic. The row should say so, and should name forward words and mark bits as what makes traversal terminate. | Verified |
| HEAP_014 | Embedded constants are pointers whose constant field is not zero. | False is constant 0, so that test misclassifies it. The real test is the pointer-indicator bit (REP_CONSTANT_001, REP_CONSTANT_002). | Verified |
| REP_HEAP_001 | Field representation comes from layout metadata produced during monomorphization. | Monomorphization supplies only constructor shapes. Code generation computes every layout (`Types.computeRecordLayout` etc.). | Verified |
| REP_SSA_001 | Immediate operand types (`i64`, `f64`, `i16`, `i1`) are used "only for Int, Float, and Char". | Its own type list includes `i1`, which is Bool. Every Bool in a function body is `i1` in SSA. | Verified |
| CGEN_009 | Bool may be `i1` only in control-flow contexts such as case scrutinees. | Every Bool SSA value inside a body is `i1`. It is boxed only at boundaries, which agrees with REP_SSA_001. | Verified |
| CGEN_025 | The `eco.make.*` aggregate operations have no producer. | The front end emits `eco.make.tuple2`, `eco.make.tuple3` and `eco.make.custom` by default. Only `make.record`, `make.cons` and `make.closure_env` have no producer. | Verified |
| REP_AGG_001 | The aggregate operations have "NO producer pass". Its source names three deleted passes (removed in 5ab78669), and its amendments describe them in the present tense. | The producers are as in CGEN_025. The type, lowering and SROA rules in the row still hold. | Verified |
| CGEN_034, CGEN_056, CGEN_058 | A generic-mode `papExtend` always has an `!eco.value` result. | It can carry a primitive result, marked by `_result_kind`, and the verifier accepts `i64`, `f64` and `i16`. CGEN_034's status `documented` also understates it, because `PapExtendResult.elm` checks it. | Verified |
| CGEN_058 | Generic apply is lowered to `eco_apply_closure`. | Both generic call kinds call `eco_apply_closure_eval`. | Verified |
| CGEN_059 | Generic apply calls `eco_apply_closure_typed`. | The lowering calls `eco_apply_closure_eval`. The row is right that LLVM adds no boxing and that the runtime re-boxes. It doesn't say that the front end boxes Bool, and also boxes a primitive when a known callee's parameter is `!eco.value`. | Verified |
| CGEN_060 | Segmentation-unknown calls go to `eco_apply_segmentation_unknown`, with bitmap-based extension. | Nothing emits that entry point. These calls use `eco_apply_closure_eval`, and partial calls use `eco_pap_extend_l` with a layout. | Verified |
| RUNTIME_CLOSURE_004 | Over-application is chained in `eco_apply_closure`. | The chaining is in `eco_apply_closure_eval`. | Verified |
| CGEN_CLOSURE_005, 007, 008 | Every closure call carries `_dispatch_mode`. | Nothing sets that attribute. Dispatch uses `_call_kind`, `remaining_arity` and `_fast_evaluator`. Retire these rows. | Verified |
| HEAP_033 | The main text gives the closure's packed word as `n_values \| max_values<<6 \| result_kind<<12 \| unboxed<<14`. | The code, and the row's own amendment, use HEAP_078's 11/11/2/40 layout. | Verified |
| CGEN_014 | Relies on `MonoGraph.ctorLayouts`. | That field does not exist. The graph has `ctorShapes`, and code generation computes layouts in `Types.computeCtorLayout`. | Verified |
| CGEN_039, CGEN_079(b) | Mention `eco.allocate_ctor`. | It was deleted in 6637803b. | Verified |
| CGEN_030, CGEN_031 | Describe join points in generated code. | Code generation never emits `eco.joinpoint` (see bug SD-12). | Unverified |
| CGEN_072 | Names two different producers of the "cannot collect" call attribute, one in its opening clause and another in its amendment. | Which producer runs in every mode was not established. | Unverified |
| REP_001 | There are four representation models. | The catalog has rows (REP_LLVM_001, REP_LLVM_002) for a fifth, LLVM-level form. Either name it, or say why it is not a model. | Verified |
| REP_LLVM_001 | `EcoPtrIntVerify` runs under `ECO_GC_DEBUG_LIVENESS`. | It runs under `ECO_LOWERING_VALIDATION`. | Verified |
| REP_CONSTANT_003 | Empty compares equal to any zero-length heap string, in any string form. | Only the kernel's boxed-slot compare (`compareUnboxableSlot`) does that. Top-level equality, `StringOps` equality and every ordering path treat them as different. It holds only because no code builds a zero-length string. Either make the paths agree, or make the row say the constant is the only empty form. | Verified |
| HEAP_025 | Strings have four forms, compiled code allocates only UTF-16 leaves, equality and comparison flatten below the flatten limit, and the key is named `large_header_split_threshold`. | There are six forms. ASCII literals become UTF-8 leaves. Equality and comparison never flatten. The key is `large_object_threshold`. | Verified |
| HEAP_036 | `ECO_CAF_PERMANENT=1` is off by default. | It is on by default, and `=0` disables it. | Verified |
| HEAP_069 | Says "promotion_age must be 1", then allows 1 to 3. | The code accepts 1 to 3. | Verified |
| GC_MODEL_001 | The canary check "fails", and the models are M1 to M7. | By default it only warns (`ECO_TLA_CANARY_STRICT` is off), and `test/tla/models.txt` includes M8. | Verified |
| BFUSE_001 | Reification is all-or-nothing. | An encoder may fuse with an opaque part that is handed to the kernel's own walker. Decoders are still all-or-nothing. | Verified |
| BFOPS_036 | Fused encode and decode allocate nothing but the final result. | Decoders allocate list cells and nested values while the cursor is live, which is bug SD-22. Encoders evaluate allocating arguments. | Verified |
| BFOPS_037 | Fused code makes no interpreter calls, and everything is inlined. | An opaque encoder part calls the kernel's size and write walkers. | Verified |
| LSS_001 | Allows `LUnknown`. | `LambdaSetAnno` is `LTop \| LVar \| LSet \| LPartial`. | Verified |
| LSS_009 | Names staging wrappers and `Staging/Rewriter.elm wrapperHome`. | Both were deleted in 16763952. The blockers are adopted synthetic closures and μ-tied members. | Verified |
| LSS_010 | Applies "under widened (keyed=False) spec keys". | Keying is always on. | Verified |
| LSS_024 | The fingerprint fence is behind `lss.layoutQualMembers`. | The fence is unconditional, and the flag is gone. | Verified |
| MONO_005 | Its text names an "optional LambdaId". | That field no longer exists. Also, its checker `expectSpecRegistryComplete` checks only the registry-to-node direction, so `enforced` covers half the rule. | Verified |
| MONO_028 | Names `applySubst` and `resolveMonoVars` from the substitution engine. | The solver engine's equivalent is zonk. | Verified |
| TOPT_001 | Each expression carries a `Can.Type`. | Each carries `Meta { tipe, tvar }`. | Unverified |
| KERN_006 | Still speaks of `AllBoxed` kernels. | The policy is a single `ElmDerived` mode. | Unverified |
| KERNEL_TASK_IO_001 | Names only `eco-kernel-cpp/` and `elm-kernel-cpp/`. | `system-kernel-cpp/` follows the same rule through SYS_001. | Unverified |
| CGEN_012 | Names the function `monoTypeToMlir`, and has a stale source. | Its claim that every type variable is `!eco.value` holds: a `number` variable never reaches code generation, because the prune step closes it to Int. Only the name and source need fixing. REP_ABI_001 needs no change on this point. | Verified |

## 2. Status that does not match how the rule is checked

| Row | Problem | Status |
|---|---|---|
| MONO_019, XPHASE_011 | Marked `tested`, but their checkers (`LambdaIdUniqueness`, `CrossPhase.TypeConsistency`) were deleted in e94365d5, and no test cites them. | Verified |
| MONO_005 | `enforced` covers only half the rule (see section 1). | Verified |
| CGEN_034 | `documented`, though `PapExtendResult.elm` checks it. | Verified |
| HEAP_005, HEAP_007 | `documented`, though the validators and the census enforce them. Not every heap row was checked for this. | Unverified |
| TOPT_004 | `documented`, and nothing enforces type preservation. That is honest, but it is a gap. | Unverified |

## 3. Broken cross-references

| Row | Problem | Status |
|---|---|---|
| GOPT_002, MONO_016 | No such rows exist, but `design_docs/invariant-test-logic.md` refers to GOPT_002. | Verified |
| BORROW_006 | Cites BORROW_005, which has no row. | Verified |
| CGEN_061 | Code cites the wrong number for it: `Ops.td:3293` (`eco.make.closure`) cites CGEN_028 for the `make.*` exception, which is CGEN_061. | Verified |
| CGEN_062 | Code cites the wrong number for it: `EcoOps.cpp:1338,1343,1377`, `Ops.td:3213` and `test/codegen/invalid_to_heap_closure_env.mlir:4` cite CGEN_029 for the `to_heap` `closure_env` rejection, which is CGEN_062. No code cites CGEN_062 itself. | Verified |
| OPT_DEBUG_ORDER_001 | The row is right, but constant hoisting violates it (bug SD-3). | Verified |

## 4. Source column names something that no longer exists

These rows are right in substance. Only the last column, which says where the rule lives, is out of date.

| Rows | Source given | Correct source | Status |
|---|---|---|---|
| MONO_004, 007, 008, 009, 010, 012, 015, 025, TOPT_005, CGEN_014, CGEN_020 | `Compiler.Generate.Monomorphize[.*]` | `Compiler.Monomorphize.*` (moved in 85cf2451) | Verified |
| CGEN_001, 002, 004 to 008, 011, 013, XPHASE_001, XPHASE_002 | `Compiler.Generate.MLIRMono` | That module never existed. Use `Compiler.Generate.MLIR.*`. | Verified |
| CGEN_012, 014, 035, 036 | `Compiler.Generate.CodeGen.MLIR` | `Compiler.Generate.MLIR.*` (the old module was deleted in 08c0cf47) | Verified |
| CGEN_040 to 044 | `tests/Compiler/Generate/CodeGen/Invariants.elm` | `compiler/tests/TestLogic/Generate/CodeGen/Invariants.elm` | Verified |
| CGEN_064, 066, 067 | Deleted unboxed-aggregate passes | Retire, or repoint. 064 and 066 already label themselves as records of retired passes. | Verified |
| MONO_017 | `Compiler.Generate.Monomorphize` | `Compiler.Monomorphize.*` | Verified |
| REP_BOUNDARY_003 | `TestLogic.ProjectionHeapLayoutConsistency` | `TestLogic.Generate.CodeGen.ProjectionHeapLayoutConsistency` | Verified |
| TYPE_001, TYPE_006 | `Compiler.Type.Constrain.Erased.Expression/Pattern` | Deleted in e0405d71. Repoint to the current constraint modules. | Verified |
| TOPT_002 to 005, POST_009 | `Compiler.Optimize.Typed.*` | `Compiler.LocalOpt.Typed.*` (moved in 85cf2451) | Verified |
| POST_002 | `Compiler.Optimize.Typed.KernelTypes` | `Compiler.Type.KernelTypes` | Verified |
| BFOPS_021 | `BF/BFTypes.td` | That file never existed. `bf.cursor` is defined in `BF/BFOps.td`. | Verified |
| VDOM_001, VDOM_005 | `system-kernel-cpp/src/Http/Dom.elm` | `Html/Dom.elm` (moved in b3b21995) | Verified |
| SYS_006 | `Http1Protocol`, `Http2Protocol` | `HttpServer/Http1.hpp`, `Http2.hpp` | Unverified |
| REP_001, REP_ABI_002, HEAP_004 to 008, HEAP_011, XPHASE_002 | `THEORY.md` | The old `THEORY.md`, a garbage-collector narrative, has been replaced by the new theory. Repoint each row to the theory document that now covers it: `design_docs/theory/value-representation.md` for REP_* and XPHASE_002, and `design_docs/theory/runtime/garbage-collector.md` for the HEAP_* rows. | Verified |
| LSS_035 | `plans/lss-post-mono-architecture.md` | That plan does not exist. Repoint the row, or drop the reference. | Verified |
