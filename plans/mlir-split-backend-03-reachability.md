# MLIR split backend 03: reachability (internalize + GlobalDCE) on the MLIR side

**Master plan:** `plans/mlir-split-backend.md`. **Status:** IMPLEMENTED 2026-10-02 (placement A;
placement B measured and refuted; results in "Implementation results" at the end of Part II).
Part I is the feasibility analysis; Part II is the build specification.
**Research:** `design_docs/mlir-level-partitioning-whole-program-steps.md` §2.
**Loop doc:** `benchmarks/backend-opt-loop.md` (entries B3b, TL, DV1, IPO).

## 0. Verdict and headline findings

**Feasible.** Every reference to a *generated* definition that LLVM's `GlobalDCE` sees is already an
MLIR symbol use when `EcoTailConversions` finishes. No LLVM-side step adds a reference to a
generated definition. So an MLIR pass can compute the same live set, and the same internal
linkage, as `internalizeAndDCEForExecutable`. The outline needs five corrections:

1. **The unused-decl strip cannot be removed.** It is load-bearing for `EcoListCursor`, whose
   early return is "the module declares `__eco_list_tail_inline`" (`EcoListCursor.cpp:115`).
   That decl is pre-declared for every module (`EcoToLLVMRuntime.cpp:1289-1356`), and only the
   strip (`EcoToLLVM.cpp:602-664`, which runs before `EcoListCursor`) removes it from non-chunk
   modules. Without the strip, `EcoListCursor` would analyse, and possibly rewrite, loops in
   modules it skips today. The strip also serves `.o`, JIT and `test/codegen` paths, which never
   run an exe-only pass. **Keep the strip; 03 is additive.**
2. **MLIR must also internalize, not only DCE.** Nearly all generated `llvm.func`s are
   `External` in MLIR: the upstream FuncToLLVM shell pattern does not map private visibility to
   linkage. The `Internal` exceptions are typed wrappers, `$sat` entries and descriptors
   (`EcoToLLVMClosures.cpp:439,1676,1807,1970`), **sret workers** (private multi-result
   `func.func`s, `EcoToLLVMFunc.cpp:157-158`), and the data globals: `__eco_str_*` /
   `__eco_str_case_*` bytes (`EcoToLLVMTypes.cpp:201,221`, `EcoToLLVMControlFlow.cpp:1214,1235`),
   `eco.global` slots (`EcoToLLVMGlobals.cpp:38`) and `__eco_strlit$*` slots (`:835`).
   `__eco_eval_layout_*` are `Private` (`EcoToLLVMClosures.cpp:2099`); `__eco_type_graph` is
   `External` (`EcoToLLVMGlobals.cpp:372`). Every later consumer of "local" reads LLVM
   linkage:
   - IPSCCP (prologue);
   - CGEN_074's `nonLocal` (`EcoBackend.cpp:2970`);
   - AlwaysInliner's dead-body deletion;
   - `externalizeAllLocals` (`EcoBackend.cpp:884`).

   If MLIR only erases, the LLVM `internalizeModule` must stay. If MLIR also sets `Internal` on
   reached non-root definitions, translation produces today's linkage directly.
3. **The "optional" root-registration pruning is moot.** `createGlobalRootInitFunction`
   (`EcoToLLVMGlobals.cpp:466-545`) registers only internal i64 globals, and skips `__eco_caf$*`
   and `__eco_strlit$*`. `eco.global` is emitted only for CAF slots (`Functions.elm:676`). So
   `__eco_init_globals` registers the type graph and, in practice, nothing else. HEAP_035's text
   ("CAF slots ... registered by `__eco_init_globals`") is stale against the code; fix the doc.
4. **The referrer sets should not be IR attributes.** About 1–2M edges as attributes would be
   uniqued into the context and then dropped by translation anyway, since `eco.*` discardable
   attributes have no translation interface. Instead, ship a shared, recomputable
   `EcoSymbolGraph` (CSR) that the split and 01 build or reuse. The import closure from 01
   (`$cap` bodies copied into partitions as `available_externally`) adds referrers that 03
   cannot see. The split must union them in before it chooses `internal`.
5. **The standalone payoff is small until measured otherwise.** Today's serial cost here is
   0.41 s (`Internalize + GlobalDCE`, B3b banner). On top of that, translation time scales with
   the dead fraction, which is **unmeasured** (M1). Expect FLAT to a small WIN. The main value
   is the symbol graph and the closed-world facts that the split, 01 and 02 need.

## 1. Today: the exact order of everything that touches symbols

| # | Step | Location | Effect on symbols | Modes |
|---|---|---|---|---|
| 1 | `UndefinedFunction` | `EcoPipeline.cpp:74` | kernel / undefined callees → `func.func` decls | all |
| 1b | `BFToLLVM` | `EcoPipeline.cpp:162`; `BFToLLVM.cpp:100-104` | bytes-fusion runtime decls (decls only) | all |
| 2 | `EcoToLLVM` Stage 0: `materializeAllRuntimeDecls` | `EcoToLLVM.cpp:344` | ~200 runtime/marker decls, all pre-declared | all |
| 3 | Stage 2 body conversion (parallel) | `EcoToLLVM.cpp:~420-505` | `eco.call` → `llvm.call @f`; papCreate → `addressof @f`, `@f$cap`; eval descriptors and `__closure_sat_*` (initializer regions hold `addressof`); typed wrappers | all |
| 4 | String-literal slots, CAF guards, shadow roots | `EcoToLLVM.cpp:554-597` | `__eco_strlit$*`, `__eco_caf$*` (by name from the thunk, `installCafMemoGuard`), `eco_caf_promote` decl | all |
| 5 | `createGlobalRootInitFunction` | `EcoToLLVM.cpp:600` | creates `__eco_init_globals` (External): `addressof __eco_type_graph` + add-root calls | all |
| 6 | Unused-decl strip (B3b collector) | `EcoToLLVM.cpp:602-664` | erases use-less **external decls** only | all |
| 7 | `EcoListCursor` | `EcoPipeline.cpp:168`; `EcoListCursor.cpp:115,381-389` | gate on the tail-marker decl; `ensureFn` creates 7 marker decls, used or not | all |
| 8 | `EcoTailConversions` | `EcoPipeline.cpp:183` | scf/arith/cf → llvm; creates **no** symbols (`cf.assert` is deliberately not lowered, `EcoTailConversions.cpp:36-38`) | all |
| 9 | translate; rename `main`→`eco_main` | `eco-boot.cpp:393-423`; `EcoNativeDriver.cpp:113-141` | 1:1 module order; unused `addressof` produces **no** LLVM use (it is a constant) | all |
| 10 | `__eco_root_module` bake | `EcoNativeDriver.cpp:205-216` | new External global, created in LLVM, when `rootModule` is set | eco make |
| 11 | `internalizeAndDCEForExecutable` | `EcoBackend.cpp:1287-1307`; called at `eco-boot.cpp:820-823`, `EcoNativeDriver.cpp:233-241` | everything except `eco_main` / `__eco_init_globals` → internal; GlobalDCE drops defs, globals, decls | **exe only** |
| 12 | Marker expansions | `EcoBackend.cpp:3655-3678` | `getOrInsertFunction` of runtime helpers only; presence gates read `getFunction` (`eco_enable_list_chunks` additionally `!use_empty()`, `:2609-2610`; `Elm_Kernel_Utils_equal`) | all (`runEcoBackend`, incl. JIT) |
| 13 | Capacity hoisting, Phase A | `EcoBackend.cpp:2965-2973` | **reads** `hasAddressTaken`, `hasLocalLinkage`, `isInterposable` | all (incl. JIT) |
| 14 | `expandInlineAllocs`, root ranges, `$sat` | `EcoBackend.cpp:3716-3731` | runtime/TLS refs only; `$sat` loads its target at run time | all (TLS forms AOT only) |
| 15 | `$cap` prepass | `EcoBackend.cpp:3737` | AlwaysInliner; deletes dead **internal** inlined bodies | O>0 |
| 16 | gc-free propagation | `EcoBackend.cpp:3747` | reads `isInterposable` | all (incl. JIT) |
| 17 | cgu prologue IPSCCP + GlobalDCE | `EcoBackend.cpp:3814`, `:499-547` | needs internal linkage; second DCE cleans IPSCCP leftovers | cgu exe |
| 18 | `externalizeAllLocals`, serialize, lazy split | `EcoBackend.cpp:884-903`, `:911+` | locals → external + hidden | split exe |
| 19 | `emitObjectFile` census hook | `EcoBackend.cpp:456-458` | `llvm.global_ctors` (diagnostic only) | env |

**Modes.** `isExecutable` is decided in `eco-boot.cpp:795-813`, after the MLIR pipeline has run.
`--emit=llvm` (`:745`), `--emit=obj`, `-o x.o`, `.so` and `.node` never internalize.
`EcoNativeDriver.cpp:228-241` applies the same rule to `eco make` and self-host stages 6–9. The JIT
paths (`ecoc.cpp:211-214`, `EcoRunner.cpp:190`) and the 302 `.mlir` fixtures in `test/codegen`
go through `ecoc`: 227 use `-emit=jit`, 32 `-emit=mlir-llvm`, 22 `-emit=llvm` (RUN-line counts,
2026-10-02). None of them takes the exe path.
`EcoPipelineOptions` is an empty struct (`EcoPipeline.h:33`), shared by the four callers of
`buildEcoToLLVMPipeline` (eco-boot, EcoNativeDriver, ecoc, EcoRunner).

## 2. Information flow: every fact, its producer and its consumers

| Fact | Produced today | Consumed by | Produced under 03 | Reaches the consumer correctly? |
|---|---|---|---|---|
| Liveness of generated defs and globals | GlobalDCE (#11) | translation volume, every later stage | `EcoReachability`: BFS plus erase | Yes, if the edge set matches GlobalDCE's (§3). Gate: validate-mode set equality |
| Liveness of decls | strip (#6) + GlobalDCE (#11) | backend presence gates (#12) | same BFS (decls are nodes) | Yes. GlobalDCE also ran before #12 today, so the presence gates see identical modules |
| Internal linkage | `internalizeModule` (#11) | IPSCCP, CGEN_074 `nonLocal`, AlwaysInliner deletion, `externalizeAllLocals` | `setLinkage(Internal)` on reached non-root defs | Yes. Internal implies dso_local in LLVM, as internalize gives. Declarations are never internalized |
| Roots | hard-coded names (`EcoBackend.cpp:1294-1297`) | `eco_entry.cpp:78,114,124`; `eco_embed.cpp:57,193,219`; JIT lookups `ecoc.cpp:354`, `EcoRunner.cpp:245` | roots `main` (MLIR name, before the rename) and `__eco_init_globals` | Yes. `__eco_init_globals` may be absent (weak in `eco_entry.cpp:78`). If `main` is absent, the pass must be a no-op, not erase everything |
| `__eco_root_module` (exe) | baked in LLVM (#10), then internalized and DCE'd | nobody in exe; `eco_node_addon.cpp:82` in `.node` | **not visible to MLIR** | **Gap.** If LLVM DCE is retired, it survives as an exported data symbol. Fix: bake only for `.so`/`.node` |
| GC root registrations | `createGlobalRootInitFunction` (#5) | runtime start-up | unchanged | Unchanged. Nothing prunable (§0.3) |
| gc-leaf on decls | `attachGcLeafPassthrough` (`EcoToLLVMFunc.cpp:49,~96`) | RS4GC, CGEN_072 | unchanged (03 erases or keeps decls whole) | Yes. A decl erased in MLIR and later recreated by `getOrInsertFunction` was also gone before #12 today |
| Address-taken | `Function::hasAddressTaken()` at #13 | CGEN_074 eligibility; the 01 plan pass | `EcoSymbolGraph` flag (§5.2) | Must match LLVM semantics exactly (§5.2), or 01 loses byte identity |
| Callers known | `hasLocalLinkage && !addrTaken && !interposable` | CGEN_074 | `isDef && !isRoot && !addrTaken` (exe); `MLIR linkage local && !addrTaken` (non-exe) | Must be gated on output kind like today: in non-exe modes almost nothing is local |
| Referrers per symbol | (implicit) `SplitModule` / lazy split need none: everything is externalized | the MLIR split (master §4.3) | `EcoSymbolGraph` transpose | Partially. The split must add 01's import closure (§5.3) |
| `eco.*` discardable attrs | front-end / passes | MLIR passes only | n/a | **Dropped at translation** (no translation interface for `eco`). Anything meant for LLVM must be `passthrough` |

## 3. Symbol-reference forms in the final llvm-dialect module

| Form | Produced by | Collector sees it? | LLVM equivalent | Notes |
|---|---|---|---|---|
| `llvm.call @f` (FlatSymbolRefAttr property) | Stage 2, CompareCaseRewrite, ListTemplate, ListCursor | yes (properties are materialised into the attribute dictionary) | direct `CallInst` | type always matches (verifier) |
| `llvm.mlir.addressof @g` in a function body | papCreate, globals, strlit/CAF slots, descriptors | yes | `Function*`/`GlobalVariable*` constant operand | **an unused addressof has no LLVM use** (M2) |
| `addressof` in an `llvm.mlir.global` initializer region | eval descriptors (`EcoToLLVMClosures.cpp:1806-1830`), type graph | yes (nested region) | `ConstantStruct` user | counts as address-taken in LLVM |
| `llvm.call %p(...)` where `%p = addressof @f` | **emitted by design** for every fast closure call: `emitFastClosureCall` (`EcoToLLVMClosures.cpp:1330-1350`) builds the call type from the *site*, which "can differ from the callee's converted signature". Mismatches are expected, not hypothetical (01's C0 census: 3,250 `$cap`s excluded as address-taken) | edge via the addressof | direct call **iff** the call's function type == `@f`'s type; otherwise indirect **and** address-taken | key to §5.2. The comment's "E1.2/E1.3 fold in `runCapInlinePrepass`" no longer exists (`EcoBackend.cpp:3567-3647`) |
| `invoke`, `personality`, comdat, alias, ifunc, `blockaddress`, `dso_local_equivalent`, `global_ctors` | **none emitted** (grep of `runtime/src/codegen`; the only `global_ctors` is the LLVM-side census ctor, #19) | — | — | assert absence in the pass (cheap op-name check) |
| Top-level **non-symbol** ops holding symbol refs (`llvm.mlir.global_ctors`/`dtors`, `llvm.comdat`, `llvm.module_flags`, `llvm.linker_options`) | none emitted today | **no**, if the collector visits only symbol ops (§4.3 step 1) | `appending` globals / named metadata: LLVM roots | treat every symbol ref in a non-symbol top-level op as a **root**, or fail the pass loudly; never drop it |
| LLVM-created declarations (intrinsics from `llvm.intr.*`) | translation, on first use | not MLIR symbols | `Function` decls | not nodes; created only by translated (= live) bodies, so the end state matches. See §6 on their **order** |
| `eco.*`/other discardable SymbolRefAttr on llvm ops | none known; eco-level `_fast_evaluator` / `function` / group arrays are consumed with their ops | yes (a phantom edge if present) | none, so a **superset** | M3 census; one would keep a dead function alive (safe, not identical) |
| Name-derived relations (`__eco_caf$`+thunk, `$cap` suffix scans, `__eco_eval_layout_*`) | `installCafMemoGuard`, `runCapInlinePrepass`, census | by `addressof` once materialised (late placement) | same | **unsafe** for an early, Eco-level placement (§4.1 C) |
| String lookups in the backend (`getFunction("...")`) | `EcoBackend.cpp` | n/a | runtime / marker names only | checked: no lookup names a generated definition |

The B3b collector already folds "own attribute dictionary + `getSymbolUses`" per top-level op,
with a serial `SymbolUserMap` fallback (`EcoToLLVM.cpp:618-650`). 03 needs a variant that keeps
**per-op edge lists**, tags each edge (call-callee / address / initializer), and skips
`addressof` ops with no uses. So it is a custom `walk`, not raw `getSymbolUses`; it reuses the
same chunking.

## 4. Design

### 4.1 Placement

| Option | Where | Saves | Risk | Use |
|---|---|---|---|---|
| **A, late** | after `EcoTailConversions` (`EcoPipeline.cpp:172`) | LLVM internalize+DCE (0.41 s); translation and teardown × dead fraction | lowest: the IR is exactly what translation sees | **first** (exactness gate against LLVM) |
| B, strip site | `EcoToLLVM` stage 5 (`EcoToLLVM.cpp:602`), reusing that one collection | A, plus tail conversions × dead fraction, plus one collection walk | ListCursor adds decl references only and tail conversions add none, so they are safe for definitions; ListCursor's 7 `ensureFn` decls may stay unused (no ELF effect). **But** B changes ListCursor's input: a tail marker used only by dead functions is now erased, so ListCursor's module gate (`EcoListCursor.cpp:115`) can flip to "skip" — must be covered by the byte-identity gate | if M1 shows a dead fraction ≥ 5 % |
| C, Eco level | after `UndefinedFunction` (`EcoPipeline.cpp:74`) | the whole MLIR pipeline × dead fraction | **edges that are names, not symbols**: CAF `eco.global` slots (the thunk→slot relation exists only by name until `installCafMemoGuard`), `eco.type_table` (unreferenced until #5), `main`'s shadow-root attrs. Each must be rooted explicitly | only if M1 shows a large dead fraction **and** B is not enough |

The research note placed 03 "after EcoTailConversions because EcoListCursor adds marker callees".
That argument concerns **declarations** only. Neither ListCursor nor the tail conversions add a
reference to a definition, so B is sound for definitions. Note that the front end already prunes
dead specs after its inliner (`inline.pruneDead`, default on, `Builder/Generate.elm:1189`), so
the residual dead set should be dominated by codegen-time artifacts (`$cap`/wrapper/`$sat`
variants, descriptors, string slots) — M1 confirms.

### 4.2 Gating and plumbing

- Add `bool exeReachability` to `EcoPipelineOptions` (`EcoPipeline.h`), and add the pass in
  `buildEcoToLLVMPipeline` only when it is set.
- **eco-boot:** hoist the `emitObjOnly`/`isExecutable` computation (`eco-boot.cpp:795-813`) above
  Step 3 (`:702`), and pass the option through `runPipeline` (`:365`). **Trap:** today
  `isExecutable` is computed *after* the `--emit=llvm` branch returns (`:745`), so it never sees
  `EmitLLVM`; a verbatim hoist would yield `isExecutable = true` for `--emit=llvm foo.ll` and
  silently internalize the IR dump. The hoisted form must be
  `emitAction == EmitExe && !emitObjOnly && !outputIsSharedLib(output)`.
- **EcoNativeDriver:** `pipelineFromMlirModule` knows `outputPath` before `runPipeline`
  (`:176`). Thread `opts` into `runPipeline(module, stats)` (`:88`).
- **ecoc:** add `--exe-reachability` (default off), only for fixtures and censuses; reject it
  with `-emit=jit` (the JIT's `packFunctionArguments`, `EcoJIT.cpp:209-210`, skips local-linkage
  functions, so internalizing would silently change the JIT interface). JIT, `.o`,
  `.so`/`.node` and `--emit=llvm` keep today's behaviour exactly.
- `__eco_root_module`: move the bake (`EcoNativeDriver.cpp:205`) under `sharedLib`. It is dead
  in exe output today anyway.

### 4.3 The pass (`EcoReachability`, module pass)

1. **Collect** (parallel, B3b chunking, 8×threads): for each top-level symbol op, gather sorted,
   deduplicated out-edges with kind bits. Skip unused `addressof` ops. Assert that the forms in
   §3 are absent. Every top-level op that is **not** a symbol contributes its refs as roots
   (§3), never zero edges. If any op hides uses, fall back to the serial `SymbolUserMap`, without
   kinds, which means conservatively "address".
2. **Roots:** `main`, `__eco_init_globals`. If `main` is missing, return without changes.
3. **BFS** over a dense index (module order), about 100k nodes. Serial; tens of ms.
4. **Erase** the unreached ops. The bodies can be dropped in parallel (they are disjoint
   regions), then the ops are unlinked serially in module order.
5. **Internalize:** set `Internal` on every reached definition (a function with a body; a global
   with a `value` or initializer region) other than the roots. Skip `Private` and already
   `Internal`. Assert that no reached definition has weak, linkonce, common, appending or
   `available_externally` linkage (internalize skips the last; generated code emits none of
   them, and CGEN_074's `isInterposable` relies on that), and that none carries a non-default
   `visibility_` (LLVM asserts on local linkage + hidden). Translation maps the attribute 1:1
   (`setLinkage` on a local linkage implies dso_local; `dso_local` is only ever *added* from the
   op), and today's `Internal` wrappers already prove that path in validation builds.
6. **Publish** (optional): `EcoSymbolGraph` for 01 and the split (§5).
7. **Validate mode** (`ECO_REACH_VALIDATE=1`; always on in `ECO_LOWERING_VALIDATION` builds):
   - write the reached-name set (with `main` mapped to `eco_main`);
   - `internalizeAndDCEForExecutable` then checks that its GlobalDCE removes **nothing** and
     that linkage is unchanged;
   - capacity-hoist Phase A compares its `addrTaken` with the published flag, per function.

## 5. Outputs for 01 and for the split

### 5.1 `EcoSymbolGraph`

The graph has:
- `nodes`: top-level symbol ops in module order, with flags `isFunc`, `isGlobal`, `isDef`,
  `isRoot`, `isConst`, `addrTaken`;
- CSR `out` edges (uint32 targets, one kind byte each);
- `in` built on demand by transposition.

It is a C++ object with a builder function, `buildSymbolGraph(ModuleOp)`, not IR. Two ways to
hand it on:
- **(a)** passes in the same PassManager reuse it as an MLIR analysis (01 and 02 only add
  attributes, so they `markAllAnalysesPreserved()`);
- **(b)** the split, which runs in the driver after `pm.run`, rebuilds it. That costs about
  0.1–0.2 s in parallel and can never be stale.

Recommend (b) for the split and (a) for 01/02. A debug env, `ECO_REACH_STAMP=1`, can stamp
`eco.reach.*` attributes for FileCheck.

### 5.2 Address-taken, defined to match `Function::hasAddressTaken()` (default arguments)

`hasAddressTaken` is evaluated at capacity-hoist time (#13), on the post-DCE, post-expansion
module. Expansions add no use of a generated function, so the reached MLIR module at the end of
the pipeline is the right domain. `f` is **address-taken** iff some *reached* op holds an
`addressof @f` whose result has at least one use that is **not** the callee operand of an
`llvm.call` whose function type equals `f`'s. In detail:

| MLIR use of `@f` | LLVM after translation | addrTaken? | call-graph edge for 01 |
|---|---|---|---|
| `llvm.call @f` | direct call | no | direct |
| `addressof @f` → callee of `llvm.call`, same type | direct call (`getCalledFunction` = f) | no | direct |
| `addressof @f` → callee of `llvm.call`, different type | indirect call | **yes** | indirect (⊤ for the caller) |
| `addressof @f` → argument, store, `insertvalue`, GEP or select | operand use | **yes** | none |
| `addressof @f` in a global initializer | ConstantExpr / aggregate user | **yes** | none |
| `addressof @f` with no uses | nothing | no | none |
| `addressof` → only unused constant-foldable ops (constant GEP, `ptrtoint`, `insertvalue` into a constant aggregate) | dangling ConstantExpr / ConstantStruct (translation folds through `TargetFolder`). GlobalDCE's `removeDeadConstantUsers()` sweep deletes them **before #13 today**, so LLVM says not taken; MLIR says taken | mismatch (MLIR conservative) | measure (M2); expected 0. After step 5 retires GlobalDCE the sweep is gone: see §9 step 5 |

**Callers known** = `isDef ∧ ¬isRoot ∧ ¬addrTaken` under the exe gate. It is never recomputed
per partition, because externalization would make it wrong. Mirror `getCalledFunction`'s
type-equality rule exactly, or 01's call graph diverges from Phase B's: compare
`callOp.getCalleeFunctionType()` with the callee's `function_type` (void result, varargs and
literal-struct results included), never the operand list. Kind bits must keep
"`addressof` → callee, mismatched type" distinct from other address uses: it is a take for
CGEN_074 but still a *call* edge for the split's import closure (§5.3) if a later LLVM pass
ever re-directs it.

### 5.3 What the split needs beyond 03

- `owner(n)` comes from LPT over the functions. Globals need an owner rule: first referrer in
  module order, or co-location with the majority. Deterministic either way.
- `parts(n) = {owner(r) | r ∈ in(n)} ∪ importers(n)`. A symbol is **internal iff
  `parts(n) ⊆ {owner(n)}` and it is not a root**; otherwise it is external + hidden.
- **Import closure (unforeseen).** 01 copies directly called `$cap` bodies into calling
  partitions as `available_externally`. Every symbol those bodies reference gains the importing
  partition as a referrer, transitively through `$cap`→`$cap` direct calls, because AlwaysInliner
  inlines recursively. 03's call-vs-address edge kinds make the closure computable. If it is
  missed, an internal symbol is referenced from another object, and the link fails loudly.
- Rename `main`→`eco_main` in MLIR before the split, since there is no LLVM module to rename in.
- **Consequence to budget in the split's tax gate:** internal linkage inside partitions
  re-enables per-partition IPO. That includes single-caller inlining of gc-leaf bodies (the
  CGEN_072 carve-out) and IPSCCP, which today does nothing (16.2 s Σ). This changes codegen and
  partition-opt time.

## 6. Determinism

- Per-op edge lists are stored by index. BFS order does not affect the reached set. Erasure and
  internalization go in module order.
- Translation emits the surviving functions in the same relative order as today's post-DCE LLVM
  module, so **byte-identical objects are expected**, not just the same symbol set. One known
  way this can fail: intrinsic declarations are appended to the LLVM function list at their
  **first translated use**. If that first use is in a dead function today, the declaration
  sits earlier than it will under 03 (GlobalDCE keeps it because a live body also uses it).
  Declaration order is not supposed to reach the object, but this is unproven; if step 3's ELF
  diff is non-empty, check the order of `declare @llvm.*` first, before suspecting the edge set.
- Erasure must not drop bodies in parallel unless each body is `IsolatedFromAbove` and holds
  no cross-op SSA (true for `llvm.func` / `llvm.mlir.global`); unlinking stays serial.
- The fallback path (`SymbolUserMap`) is deterministic.
- Parallel `setLinkage` on distinct ops is safe; attribute uniquing is thread-safe.

## 7. Costs and expected payoff

| Item | Estimate | Basis |
|---|---|---|
| Collect | ~0.1–0.15 s wall (~1.5–3 s CPU) | B3b: the strip collection occupies the 0.10 s window 4.83–4.93 s of the TL timeline at ~1,300 % (≈1.3 s CPU); 03 also keeps per-op edge lists, so expect somewhat more |
| BFS | <0.05 s | ~100k nodes, ~1–2M edges |
| Erase | ~0.05–0.2 s | × dead count (M1) |
| Internalize | <0.05 s | parallel attribute set |
| Saved: LLVM internalize + GlobalDCE | 0.41 s | B3b banner, once retired (step 5) |
| Saved: translation and teardown | 6.7 s and ~1.2 s × dead fraction | TL; dead fraction unknown |
| Graph memory | ~10–20 MB | CSR uint32 |

Net is FLAT to small WIN until M1 is known. Under the loop rules a FLAT step that deletes a
serial LLVM pass is kept. Code size: about 300 lines for the pass and graph, 40 for plumbing, 60
for validate mode and the census, plus fixtures.

## 8. Measurements that must precede implementation

- **M1, dead census (no code).** Two `eco-boot-native` runs on the self-compile MLIR, both
  `-O0` (so there is no `$cap` prepass confound): `--emit=obj --dump-pre-rs4gc-ir=obj.ll` and
  `--emit=exe --dump-pre-rs4gc-ir=exe.ll`. Kill each run once its dump is written. Then:
  - diff the `define`/`declare`/`@global` name sets;
  - bucket the removed names by pattern: `$cap`, `__closure_sat_`, typed wrappers,
    `__eco_evaldesc_`, `__eco_caf$`, `__eco_strlit$`, plain specs, kernel decls, runtime decls.

  This decides between A and B/C, and answers §10 Q1 (a front-end fix instead?).
- **M2, unused or dangling `addressof`.** A census-only build of the pass (step 1) counts:
  - `addressof` ops with no uses, and those whose users are all unused constant-foldable ops;
  - `llvm.call %p` with `%p = addressof`, split by matching vs mismatching type (both are
    expected to be large: every fast closure call has this form, §3).

  Expect 0 for the dangling case. Anything else needs a rule.
- **M3, phantom edges.** In the same census: the (op name, attribute name) pairs that carry a
  SymbolRefAttr which is not an inherent property. Expect only `callee` and `global_name`.
- **M4, cost.** Collector, BFS and erase time, and RSS, with `ECO_LOWERING_TIMELINE=1`, N = 1.
- **M5, init roots.** Count `eco_gc_add_root` calls in `__eco_init_globals` in `exe.ll`. Expect
  0, which confirms §0.3.

## 9. Steps and acceptance criteria

1. **Census build.** Pass in census-only mode: collect, BFS, report counts, change nothing.
   Covers M2–M4. *Accept:* reports produced; the generated ELF is byte-identical to the
   reference.
2. **Plumbing.** `exeReachability` option, the eco-boot hoist, the EcoNativeDriver threading, the
   ecoc flag, the `__eco_root_module` bake moved under `sharedLib`. *Accept:* no codegen change;
   `.node` addon tests unchanged; `eco-boot --emit=llvm` and `--emit=obj` output byte-identical
   (proves the hoisted gate excludes them, §4.2).
3. **Erase + internalize (placement A) in validate mode.** LLVM internalize + DCE still runs and
   asserts that it removes nothing and changes no linkage. *Accept:*
   - the reached set equals the GlobalDCE survivors on the self-compile and on all AOT E2E
     programs;
   - byte-identical ELF against the reference;
   - bootstrap fixed point;
   - new `test/codegen` fixtures (`ecoc -emit=mlir-llvm --exe-reachability`), with CHECK-NOT for
     a dead spec, a dead global reached only from a dead initializer, and a dead CAF slot and
     its thunk; plus a CHECK for `internal` linkage and for `main` staying external.
4. **Loop step.** One lowering run, judged on wall time; record the dead fraction and the
   translation delta.
5. **Retire the LLVM side.** Delete `internalizeAndDCEForExecutable`'s work **except** a
   `removeDeadConstantUsers()` sweep over the module's functions (GlobalDCE does this for every
   global object today; without it, dangling constants left by translation's folder reach
   CGEN_074's `hasAddressTaken` at #13 and can flip eligibility; it is O(constant users), cheap).
   Drop the sweep only if M2 measured zero dangling constants *and* step 7's cross-check passes
   without it. Keep a cheap validation-build assert, a linkage scan, for one series. *Accept:*
   same ELF; step 7's per-function `addrTaken` cross-check still zero-diff; the loop step is
   FLAT or WIN.
6. **(Conditional on M1) Placement B.** Fold into the strip's collection at `EcoToLLVM.cpp:602`.
   *Accept:* as step 3, plus less tail-conversion time.
7. **Graph API for 01 and the split.** Add `addrTaken` and kinds; capacity-hoist Phase A
   cross-checks `hasAddressTaken`/`hasLocalLinkage` per function in validate mode. *Accept:*
   zero mismatches on the self-compile and on AOT E2E.

**Gates for the series:** AOT E2E (`run-aot-e2e`, 893/895 expected) is the **only** suite that
exercises the exe path. JIT `check` and `test/codegen` do not run 03 except through the new
fixtures. Also: the bootstrap fixed point and a byte-identical ELF.

## 10. Obstacles, risks and mitigations

| # | Obstacle / risk | Mitigation |
|---|---|---|
| 1 | The decl strip is load-bearing (ListCursor gate; non-exe fixtures) | Keep it. 03 is additive; at most it reuses the strip's collection (B) |
| 2 | A missed edge in **release** builds: the erased target is still referenced, so translation fails or asserts in `lookupFunction`. It is not a link error | Validate mode in step 3; the validation-build verifier checks symbol uses; the §3 absence asserts |
| 3 | Unused `addressof` gives MLIR a superset of the live set, so a symbol-set diff | Skip unused `addressof` in the collector (M2) |
| 4 | `__eco_root_module` is LLVM-created and invisible to MLIR | Bake only for `.so`/`.node` (step 2) |
| 5 | MLIR does not see LLVM-side linkage consumers if 03 only erases | 03 internalizes too (§4.3 step 5) |
| 6 | The addr-taken definition drifts from `hasAddressTaken`, so 01 is not byte-identical | §5.2 table; per-function cross-check (step 7); MLIR's answer is sound in the direction it can differ (dangling constants) |
| 7 | Eco-level placement (C) misses name-derived edges (CAF slot, type table) | Root them explicitly, or do not do C |
| 8 | Split linkage ignores the `$cap` import closure, so a link failure | §5.3 import closure; the split's own gate |
| 9 | The exe path has little test coverage (`check` is JIT-only) | AOT E2E plus the new fixtures plus the bootstrap |
| 10 | A stale graph if a pass between 03 and the consumer creates or erases symbols | Rebuild in the split; 02/03 assert "attributes only" |
| 11 | The payoff is too small to justify the code on its own | The step is judged with the "deletes a serial pass" rule; its real value is the 02/split enabler |
| 12 | `main` absent (library-shaped MLIR fed to exe) | No-op, so the link fails as today |
| 13 | The eco-boot gate hoist turns on reachability for `--emit=llvm` | Gate on `emitAction == EmitExe` (§4.2); step 2 acceptance |
| 14 | Retiring GlobalDCE also retires its `removeDeadConstantUsers` sweep, so `hasAddressTaken` at #13 can change | Keep the sweep (§9 step 5) |
| 15 | A future top-level non-symbol op (`global_ctors`, comdat) holds the only ref to a definition | Treat as roots / fail loudly (§3, §4.3 step 1) |
| 16 | Intrinsic-declaration order differs, so byte identity fails for a non-semantic reason | §6 diagnosis order; if real, accept "same symbol set + same function bodies" with a recorded rationale |

## 11. Invariants and docs to amend

- **CGEN_074:** "local" becomes "non-root definition under the exe gate (MLIR internalized)".
  Name `EcoReachability` as its producer.
- **HEAP_035:** correct the claim that CAF slots are registered by `__eco_init_globals`.
- **CGEN_068:** still references the unused-decl strip, which remains; no change.
- **New CGEN rule:** exe-mode reachability and internalization happen in MLIR, with the roots
  `main` and `__eco_init_globals`. No post-translation step may add a reference to a generated
  definition. Marker expansions may reference runtime symbols only.

## 12. Open questions

1. If M1 shows the dead set is mostly codegen-time variants, should the front-end stop emitting
   them? That saves the whole MLIR pipeline's share, not just translation. A post-inliner Mono
   prune already exists (`inline.pruneDead`, `Builder/Generate.elm:1189`); the question is
   whether the mints that run *after* it (`fastEvaluatorSpec`, post-settle devirt targets,
   CafHoist, per the comment at `:1186`) and the per-function `$cap`/wrapper variants can be
   emitted on demand.
2. Should `.so`/`.node` output get reachability with roots `eco_main`, `__eco_init_globals` and
   `__eco_root_module`? Embedding builds currently export every generated symbol.
3. What is the global-owner rule in the split, and may constant globals with identity-free use
   (string bytes) be duplicated per partition as private copies? Eval descriptors must not be
   duplicated unless descriptor identity is proven unobservable.
4. Is placement B worth giving up the exact "same IR as LLVM DCE" property? ListCursor's unused
   decls would remain in IR dumps; there is no ELF effect.

# Part II: implementation specification

Part I is the feasibility analysis. Part II is the build specification. Plan 00 (SP4) has
already answered §8:
- **M1:** the MLIR reached set equals the LLVM survivors exactly (75,775). The exe-only DCE
  removes 22,388 of 98,163 defined functions (**22.8 %**: 12,138 specs, 10,233 `$clo` variants,
  17 kernel wrappers), 1 declaration and 44 eval-layout globals.
- **M2:** 0 unused `addressof` ops.
- **M3:** 0 phantom edges; only `callee` and `global_name` reference symbols.
- **M4:** collection 0.36–0.38 s, BFS 0.009 s.
- **M5:** `__eco_init_globals` registers no roots.

With a 22.8 % dead fraction, placement A pays for translation (6.9 s serial × 0.23), and the
conditional step 6 (an earlier placement) is triggered.

## R0. Decisions taken (answers to §12 and the open choices)

| Question | Decision | Why |
|---|---|---|
| Gate | `EcoPipelineOptions::reachability`, set by every driver exactly when `capClosedWorld` is (exe, or an object with `--internalize-keep`); roots = `capRoots` | 01 already computes this gate and its roots correctly, including the `--emit=llvm` trap (`eco-boot.cpp` `capClosedWorld`) |
| How the backend knows MLIR did it | module flag `eco-reach` = `v1`, written by the pass | self-describing like 01/02; a no-op pass (no root present) leaves no flag, so the LLVM path runs as today |
| Escape hatch | `ECO_REACH_MLIR=0`: the pass is not added; LLVM internalize + DCE as today | A/B and bisection |
| Placement | **A first** (after `EcoTailConversions`, before `EcoCapHoistPlan`); placement B tried as a loop step (R7) | exactness gate first |
| `.so`/`.node` reachability (§12 Q2) | out of scope | embedding exports are a contract question |
| §12 Q1 (front end stops minting the variants) | out of scope; recorded in the results | front-end change |
| Graph | `EcoSymbolGraph` (C++ object, rebuilt per consumer) shared by `EcoReachability`, `EcoCapHoistPlan` (replacing its private collection) and the validate cross-check | one definition of "edge" and "address-taken" |
| LLVM side after 03 | `finishReachability`: strip the flag and run the `removeDeadConstantUsers` sweep (§9 step 5); under `ECO_REACH_VALIDATE=1` also run the old internalize + DCE and require that it removes nothing and changes no linkage | |

## R1. Files

| File | Change |
|---|---|
| `P/EcoSymbolGraph.h/.cpp` (new) | graph builder |
| `P/EcoReachability.cpp` (new) | the pass |
| `P/EcoCapHoistPlan.cpp` | use the graph for refs and takes |
| `Passes.h`, `EcoPipeline.h/.cpp`, `CMakeLists.txt` | option, pass, build |
| `EcoBackend.h/.cpp` | `finishReachability`, `crossCheckReachability` (validate), flag strip in `runEcoBackend` |
| `eco-boot.cpp`, `EcoNativeDriver.cpp` | set the option; call `finishReachability` instead of `internalizeAndDCE*` when the flag is present; validate cross-check; `__eco_root_module` bake only for `.so`/`.node` |
| `ecoc.cpp` | `--exe-reachability` (rejected with `-emit=jit`) |
| `test/codegen/CodegenIsolatedTest.hpp` | pass `--exe-reachability` from the RUN line through to `ecoc` |
| `test/codegen/reach_*.mlir` (new) | fixtures |
| `design_docs/invariants.csv` | CGEN_074, HEAP_035, new CGEN_081 |

## R2. `EcoSymbolGraph`

```cpp
namespace eco::symgraph {
enum EdgeKind : uint8_t { Call = 1, CallMismatch = 2, Address = 4 };
struct Node { Operation *op; StringAttr name; bool isFunc, isGlobal, isDef, interposable; };
struct Graph {
  std::vector<Node> nodes;                    // top-level symbol ops, module order
  llvm::DenseMap<StringAttr, uint32_t> index;
  std::vector<uint32_t> outBegin;             // CSR, size nodes+1
  std::vector<uint32_t> outTarget;
  std::vector<uint8_t>  outKind;              // OR of EdgeKind per (src, dst)
  std::vector<uint32_t> extraRoots;           // refs held by non-symbol top-level ops
  std::vector<std::vector<uint32_t>> extraTakes; // address-kind refs of those ops
};
Graph build(ModuleOp m);                      // parallel per top-level op
}
```

**Edge collection** for a top-level op X (a walk over X and every nested op):
- `llvm.mlir.addressof @g`:
  - no uses → **no edge** (LLVM sees no use; M2);
  - otherwise one edge X→g. Its kind is `Call` if **every** use is operand 0 of an
    `llvm.call` without a `callee` attribute and with `getCalleeFunctionType()` equal to g's
    `function_type`; `CallMismatch` if every use is such a callee operand but at least one has a
    different type; otherwise `Address` (01's rule, §5.2).
- every other op: each `SymbolRefAttr` in its attribute dictionary (properties included) →
  edge of kind `Call` for `llvm.call`'s `callee`, otherwise `Address`.

Edges are deduplicated per (X, g) with their kinds OR-ed. A function's **address-taken**
flag (as LLVM `hasAddressTaken` will see it) = some edge into it, from a reached source, has
`Address` or `CallMismatch` set. That is computed by the consumer, since "reached" is the
consumer's notion.

## R3. `EcoReachability` (`P/EcoReachability.cpp`)

`createEcoReachabilityPass(std::vector<std::string> roots)`, argument `eco-reachability`.

1. If `roots` is empty, return. Index the roots that exist; if none exists, return without
   changes (§10 #12).
2. Build the graph.
3. **BFS** from the roots and `extraRoots`.
4. **Assert:** no reached definition has linkage other than External, Internal or Private
   (weak, linkonce, linkonce_odr, weak_odr, common, appending, extern_weak and
   available_externally all fail the pass), and none has a non-default visibility.
5. **Erase** every unreached symbol op (functions, globals, declarations). Bodies are dropped
   in parallel (`Region::dropAllReferences` + clearing the blocks; each body is isolated from
   above). The ops are then erased serially in module order.
6. **Internalize** every reached definition that is not a root and has `External` linkage →
   `Internal`. Definitions = `llvm.func` with a body, and `llvm.mlir.global` that has a value
   attribute or an initializer region.
7. Write the module flag `eco-reach` = `v1`.
8. `ECO_REACH_STATS=1` prints `[reach] nodes=N reached=R erased=E internalized=I time=Ts`.

**Placement:** directly after `EcoTailConversions`, before `EcoCapHoistPlan`. It is a no-op
unless `opts.reachability` is set; with `ECO_REACH_MLIR=0` it is not added.

## R4. `EcoCapHoistPlan` on the graph

Replace steps 4–6 (index, refs, takes, closed-world BFS) with `symgraph::build`:
- `refs` = graph out-edges;
- takes = edges with `Address | CallMismatch`, plus `extraTakes`;
- the closed-world BFS is unchanged in meaning. After 03 every remaining symbol is reached.

Accept: byte-identical output, and 01's validate twin reports 0 diffs.

## R5. The backend and the drivers

- **`EcoBackend.cpp`**:
  - `Error finishReachability(Module&, ArrayRef<std::string> keep)`: requires the `eco-reach`
    flag. It strips the flag, then runs `removeDeadConstantUsers()` on every function and
    global variable (the GlobalDCE sanitizer that `hasAddressTaken` relies on, §9 step 5).
    Under `ECO_REACH_VALIDATE=1` it then counts definitions and declarations, records every
    definition's linkage, runs the old `internalizeAndDCE(m, keep)`, and fails if any count
    changed or any linkage differs.
  - `runEcoBackend` strips a leftover `eco-reach` flag (ecoc paths).
  - `bool hasReachabilityStamp(const Module&)`.
- **Drivers** (eco-boot: exe and `--internalize-keep`; EcoNativeDriver: exe): when the
  flag is present, call `finishReachability(m, keep)`; otherwise the old call. The phase banner
  becomes `Reachability finish (serial)` on that path.
- **Validate cross-check** (`ECO_REACH_VALIDATE=1`). The driver calls
  `crossCheckReachability(ModuleOp, llvm::Module&, mainRenamed)` after translation while the MLIR
  module is still alive:
  - build the graph;
  - for each MLIR definition, compute `taken` per R2;
  - compare it with `F->hasAddressTaken()` on the LLVM function of the same name, *after* the
    sweep; mismatches are fatal and the first 20 are listed;
  - print `[reach-validate] compared=N addr_mismatch=0`.
  
  The sweep must run before the comparison, so the order is: translate → `finishReachability`
  → cross-check → free MLIR.
- `__eco_root_module` bake (EcoNativeDriver) only when `sharedLib`.
- **ecoc:** `--exe-reachability` sets `reachability` and roots `{"main", "__eco_init_globals"}`.
  It does **not** set `capClosedWorld`: 01 stays open-world, and after internalization the
  open-world rule (local = Internal/Private) gives the same answer. With `-emit=jit` it is an
  error.

## R6. Fixtures and gates

**Fixtures** (`ecoc %s -emit=mlir-llvm --exe-reachability`):

| Fixture | Content | Expect |
|---|---|---|
| `reach_basic.mlir` | `main` → `@live`; `@dead` → `@deadcallee`; a global used only by `@dead`; a declaration used only by `@dead` | `@live` internal; `main` stays external (no `internal`); `@dead`, `@deadcallee`, the global and the declaration are gone; flag `eco-reach` |
| `reach_global_init.mlir` | global `@gdead` whose initializer takes `addressof @fdead`, unreferenced; `@glive` initializer takes `@flive`, referenced from `main` | `@gdead` and `@fdead` gone; `@glive` and `@flive` kept and internal |
| `reach_unused_addressof.mlir` | `main` holds an `addressof @f` with no uses | `@f` erased |
| `reach_no_main.mlir` | no `main` | nothing erased, no flag |
| `reach_jit_rejected.mlir` | `-emit=jit --exe-reachability` | `not`; error text |

**Gates** (`ulimit -c 0`):
1. **Byte-identical ELF:** the self-compile with the pre-change binary vs the new one; also an
   `--internalize-keep` object (Stage 9a form) vs the pre-change binary.
2. **Validate on the self-compile:** `ECO_REACH_VALIDATE=1 ECO_CAPHOIST_VALIDATE=1
   ECO_GCFREE_VALIDATE=1`. The LLVM DCE removes nothing, `addr_mismatch=0`, and the
   01/02 twins report 0 diffs.
3. **`check`** with the three validate variables: previous count + new fixtures.
4. **`run-aot-e2e`** with validate: 899/901 (this is the suite that exercises the exe path).
5. **`stress`** with validate.
6. **Bootstrap:** 4b/8c fixed points; 9b OK.
7. **Timing:** translation, the new pass, the 01/02 passes (now on 77 % of the functions) and
   the retired LLVM phase.

## R7. Step 6 (placement B), run as a loop step

Move the pass to directly after `EcoToLLVM` (before `EcoListCursor`). It removes no definition
edge (§4.1). **Accept** only if:
- the ELF is byte-identical (this covers ListCursor's module gate, §10 residual);
- every gate in R6 passes;
- the lowering wall time is lower than placement A by more than noise (two runs each).

Otherwise revert to A and record why.

## R8. Invariant text

- **CGEN_074:** in closed-world output, "local" = a reached non-root definition, internalized by
  `EcoReachability` in MLIR.
- **HEAP_035:** CAF slots are rooted by `eco_caf_promote` when the thunk publishes;
  `createGlobalRootInitFunction` skips `__eco_caf$*` and `__eco_strlit$*` (the previous text,
  "registered by `__eco_init_globals`", is stale).
- **CGEN_081 (new):** closed-world reachability and internalization happen in MLIR
  (`EcoReachability`, roots `main`, `__eco_init_globals` or the `--internalize-keep` list). No
  post-translation step may add a reference to a generated definition, and marker expansions
  reference runtime symbols only. The LLVM side keeps only the `removeDeadConstantUsers` sweep
  (plus the old DCE as a validate oracle). `__eco_root_module` is baked only for `.so`/`.node`.


## Implementation results (2026-10-02)

R1–R6 and R8 were built as specified, with placement A. R7 (placement B) was measured and
**refuted**. Two smaller notes:
- the `test/codegen` harness forwards a whitelisted `--exe-reachability` from the RUN line;
- `reach_global_init.mlir`'s `main` must use the loaded pointer. Otherwise the pipeline drops
  the load, and the global correctly dies.

**Census, self-compile:** 150,548 symbol nodes, 128,114 reached, **22,434 erased** (SP4's 22,388
functions + 1 declaration + 44 globals, plus one more), 33,787 internalized. The pass takes
0.49–0.55 s.

**Gates** (`ulimit -c 0`; `ECO_REACH_VALIDATE=1 ECO_CAPHOIST_VALIDATE=1 ECO_GCFREE_VALIDATE=1`
exported for 2–5):

| # | Gate | Result |
|---|---|---|
| 1 | Byte-identical vs `stats-backend-opt/eco-boot-native.pre03` | self-compile exe **identical**; Stage 9a `--internalize-keep` object **identical** |
| 2 | Validate, self-compile | `removed_by_llvm=0 linkage_changed=0`; address-taken `compared=75775 addr_mismatch=0`; 01 twin 0 diffs; 02 twin `mlir=8558 llvm=8558`; same on the 9a object |
| 3 | `check` | 2027 passed / 0 failed (2022 + 5 fixtures) |
| 4 | `run-aot-e2e` | 899 / 901; the 2 failures are the known FlagsRecordTest and PortEchoTest. Spot check: 21 erased, oracle 0, `addr_mismatch=0`. As in plan 02, the first attempt failed 865 tests with "CORRUPT CACHE": every rebuild of `eco-boot.js` invalidates the per-test `eco-stuff` caches. Moving them aside fixed it; this is a front-end issue, not this plan |
| 5 | `stress` | 101 / 101 |
| 6 | Bootstrap | 4b and 8c fixed points, 9a and 9b OK (13 min 56 s; Stage 5 6:55) |
| 7 | Timing (Stage 6 / Stage 7b single runs) | see below |

**Timing (single lowerings of `eco-compiler-boot.mlir`):**

| Phase | pre-03 | 03 |
|---|---|---|
| MLIR → LLVM translation | 6.57 s | 6.19–6.31 s |
| Internalize + GlobalDCE → Reachability finish | 0.38 s | 0.11 s |
| `EcoReachability` | — | 0.46–0.55 s |
| `EcoCapHoistPlan` + `EcoGcFreePropagation` | 0.89 s | 0.73–0.77 s |
| sum of top-level phases | 43.63 s | 43.38–43.63 s |
| Stage 7b wall (bootstrap) | 44.93 s | 44.77 s |

**Verdict: FLAT,** kept under the "deletes a serial LLVM pass" rule. The structural value is
the shared graph and the closed-world facts the split needs. Translation saved only ~0.3 s for
23 % fewer functions: the dead set is dominated by small `$clo` variants and specs.

**R7, placement B (directly after `EcoToLLVM`), REFUTED.** The ELF is byte-identical, but:
- the tail conversions are no faster (2.06 vs 2.04 s), since the dead functions are cheap to
  convert;
- the wall time is the same within noise (43.69/43.28 s against 43.38/43.63 s);
- the LLVM oracle is no longer exact: ListCursor's `ensureFn` adds 2 unused declarations after
  the pass.

**Not done (out of scope, recorded):** §12 Q1 (stop minting the dead variants in the front end)
and Q2 (`.so`/`.node` reachability).

## Adversarial review (2026-10-02)

Read-only check of every citation against the tree; nothing built or run. Fixed in place above
unless marked "residual".

| # | Issue | Evidence | Addressed |
|---|---|---|---|
| R1 | Pass-order line numbers were wrong: ListCursor is at `:168` (`:155` is `EcoMarkGCLeafCalls`), tail conversions at `:183`, UndefinedFunction at `:74`. `BFToLLVM` (`:162`, creates decls) was missing from §1 | `EcoPipeline.cpp:74,155,162,168,183` | §1 rows 1, 1b, 7, 8; §4.1 |
| R2 | "`cf.assert` may add `abort`/message globals" is false: tail conversions deliberately leave `cf.assert` unlowered and create no symbols | `EcoTailConversions.cpp:36-38` | §1 row 8; §4.1 B |
| R3 | The list of already-`Internal` symbols missed sret workers (private multi-result `func.func` → `Internal`) and all internal/private data globals | `EcoToLLVMFunc.cpp:157-158`; `EcoToLLVMTypes.cpp:201,221`; `EcoToLLVMControlFlow.cpp:1214,1235`; `EcoToLLVMGlobals.cpp:38,835`; `EcoToLLVMClosures.cpp:2099` | §0.2 |
| R4 | §3 called `addressof`+indirect `llvm.call` "possible after PAPSimplify". It is the **designed** form of every fast closure call, with a site-derived type that can mismatch the callee. So mismatched-type takes are common, and the "E1.2/E1.3 fold" the code comment promises no longer exists | `EcoToLLVMClosures.cpp:1330-1350`; `EcoBackend.cpp:3567-3647`; 01 §2.4 | §3, §5.2 (compare `getCalleeFunctionType()`; keep a distinct edge kind), M2 |
| R5 | Hoisting eco-boot's `isExecutable` verbatim would enable reachability for `--emit=llvm` (today the `EmitLLVM` branch returns before the computation) | `eco-boot.cpp:745,795-813` | §4.2, step 2 acceptance, §10 #13 |
| R6 | GlobalDCE calls `removeDeadConstantUsers()` on every global object, so today's #13 `hasAddressTaken` never sees dangling constants. Translation folds through `TargetFolder` and can leave them (e.g. intermediate `insertvalue` aggregates in initializers, an unused `ptrtoint`). Step 5 would silently remove that sanitizer | LLVM `GlobalDCE::run`; `EcoBackend.cpp:2969` | §5.2 table row; §9 step 5 keeps the sweep; §10 #14 |
| R7 | The edge collector visits only top-level **symbol** ops. Refs in a non-symbol top-level op (`global_ctors`, comdat, module flags) would be lost, and their targets erased. None are emitted today | grep of `runtime/src/codegen`: only the LLVM-side census ctor (`EcoBackend.cpp:444`) | §3 new row; §4.3 step 1; §10 #15 |
| R8 | §1 labelled #12–#16 "all AOT". They run in `runEcoBackend` for the JIT too (`JITInvokePacked`). Only the TLS forms are AOT-only | `ecoc.cpp:318-323`; `EcoRunner.cpp:209-214`; `EcoBackend.cpp:3702,3715` | §1 rows 12–16 |
| R9 | `ecoc --exe-reachability` combined with `-emit=jit` would change the JIT interface: `packFunctionArguments` skips local-linkage functions | `EcoJIT.cpp:209-210` | §4.2: reject that combination |
| R10 | Fixture counts were wrong (227/32/22, not 217/36/17), and there are four callers, not four "builders" | RUN-line grep of `test/codegen/*.mlir`; `EcoPipeline.h:33` | §1 Modes |
| R11 | §10 Q1 proposed a post-inliner Mono prune. One already ships default-on (`inline.pruneDead`) | `Builder/Generate.elm:1186-1190`; `Compiler/Eco/Config.elm:696` | §4.1 note; Q1 rewritten |
| R12 | Linkage semantics checked. MLIR `Internal` → translation `setLinkage(Internal)` gives implicit dso_local and default visibility, which matches `internalizeModule`'s `setVisibility(Default)` + `setLinkage(Internal)`. GlobalDCE treats unreached external declarations as dead, so treating decls as nodes is right. No `visibility_`, comdat, `llvm.used`, inline asm, debug info or module flags are emitted (grep). The C++ side resolves only `eco_main`, `__eco_init_globals` (weak) and `__eco_root_module` (`.node`, weak) by name; ports and kernels name no generated symbol | `eco_entry.cpp:78,114,124`; `eco_embed.cpp:57,193`; `eco_node_addon.cpp:82`; `PortRuntime.cpp:563` | §4.3 step 5 asserts widened (common/appending/available_externally, non-default visibility) |
| R13 | The cost-basis wording "ran 4.83–4.93 s" reads as a duration. It is a 0.10 s window on the TL timeline | `benchmarks/backend-opt-loop.md:1993` | §7 |

**Residual concerns.**
- **Byte identity (§6).** The order of intrinsic declarations can differ when a dead function
  held the first use. This is believed harmless but is unproven. Diagnosis order and a fallback
  acceptance are recorded (§10 #16).
- **Placement B moves ListCursor's module gate** for modules whose only tail-marker users are
  dead. It is safe in principle, but only the byte-identity gate covers it.
- **01's §2.4 claims that `_fast_evaluator` is copied onto `llvm.func`.** In the front end it sits
  on `papCreate`/`papExtend` ops (`Expr.elm:1254,2307,5949`, `Lambdas.elm:242`), not on
  `func.func`, so this plan's "consumed with their ops" looks right. M3 settles it, and 01
  should be corrected if M3 agrees.
- **M1 runs `--emit=obj` against `--emit=exe`.** The only exe-only work before the
  pre-RS4GC dump is internalize+DCE (at `-O0`), so the diff is clean. It needs two full
  self-compile lowerings (heavy), and it must not be run under a validate build.
