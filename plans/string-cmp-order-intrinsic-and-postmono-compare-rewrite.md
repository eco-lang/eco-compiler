# Plan: `eco.string.cmp_order` intrinsic + post-mono compare→branch rewrite

**Status: IMPLEMENTED 2026-08-10 — Phases A, B, D landed; C not needed (see
below). Gates + benchmark: `benchmarks/kernel-opt.md` Run B. Invariant:
CGEN_075.**

Landed surface:
- **A** — `CompareStringKind` in `Generate/MLIR/Intrinsics.elm` (4 edits);
  `eco.string.cmp_order` + `eco.string.cmp3` ops (`Ops.td`, both `[Pure]`);
  lowerings in `EcoToLLVMArith.cpp` (one gc-leaf call each, *not*
  `emitOrderSelect`); `eco_string_cmp3` / `eco_string_cmp_order` /
  `Elm_Kernel_Utils_cmp3` in `UtilsExports.cpp` (all `int64_t`-returning,
  full `Export::toPtr` resolution); `Utils::cmp3` in `Utils.{hpp,cpp}`;
  decls + `materializeAllRuntimeDecls` + `RuntimeSymbols.cpp` registration.
- **B** — `runtime/src/codegen/Passes/EcoCompareCaseRewrite.cpp`, registered in
  `buildEcoToEcoPipeline` between `EcoPAPSimplify` and `UndefinedFunction`.
  `ECO_CMPCASE=0` disables; naming it prints `[cmpcase] rewritten=N skipped=M`.
- **D** — the dead pre-mono rewrite deleted (−242 lines from
  `LocalOpt/Typed/Expression.elm`, incl. the two now-dead `optimizeAsExpr` /
  `optimizeArgExpr` let-bindings; `boolType` kept).
- **C** — implemented as **C-v1**: `emitOrderSelect` now folds the sign in SSA
  (two selects over i64 constants) and makes **one** gc-leaf
  `eco_order_from_sign(i64) -> hptr` call instead of calling all three
  `Eco_Runtime_getOrder*` getters unconditionally. 3 calls + 2 ptr-selects → 1
  call + 2 i64-selects per execution; also stops materializing three GC
  pointers on every compare. `ECO_ORDER_FROM_SIGN=0` restores the old shape.
  C-v2 (exported singleton array + typed `ptr addrspace(1)` load) and C-v3
  (PermanentSpace) remain unbuilt — C-v1 removes the calls without touching
  REP_LLVM_002 territory. Note this only reaches the sites B did *not* rewrite
  (the escapes, `[cmpcase] skipped=16`) plus `eco.string.cmp_order`, so expect
  a small effect; fixture `test/codegen/order_from_sign.mlir`.

Fixtures added: `test/codegen/compare_case_rewrite_{structural,bails,jit}.mlir`
(the jit one pins LT/EQ/GT per producer kind plus NaN-each-side/both→EQ,
−0.0 vs 0.0→EQ, Char u16 extremes, and the Empty-string ordering; rewrite-on
vs rewrite-off was diffed for equivalence).

---

**Original status: NEW 2026-08-10. Grounded (3-agent recon, all anchors
verified); sized; ready to execute phase-by-phase.**

**Provenance:** the dynamic kernel census (`plans/kernel-call-census.md`
§Results, 2026-08-09; raw data
`design_docs/kernel-boundary/kernel-census-dynamic-stage7a.txt`) and
`design_docs/kernel-boundary-reduction.md` §3/§5. **Supersedes the Option-1
(case-rewrite) half of `plans/compare-to-order-intrinsic-and-case-rewrite.md`**
— that rewrite shipped dead (§1.3); its Phase A (Order singletons + primitive
`cmp_order` intrinsics) shipped live and is the foundation here. Update that
plan's header to point here when this lands.

---

## 1. The problem, quantified

### 1.1 Comparison machinery is 77% of all dynamic kernel traffic

Stage 7a (self-compile) executes **3,676,097,627 kernel calls**; of these:

| Symbol | Calls | Share |
|---|---:|---:|
| `Elm_Kernel_Utils_compare` (boxed root) | 1,954,920,276 | **53.2%** |
| `Eco_Runtime_getOrder{LT,EQ,GT}` (3 per `cmp_order` intrinsic) | 881,158,482 | **24.0%** |

The drivers are 283 monomorphic specializations of `Dict.insertHelp` (176)
and `Dict.get` (107) — elm/core's red-black tree performs one `compare` per
tree level, and the compiler's Dict keys are overwhelmingly `String` (`Name`,
`ModuleName.Raw`, `Pkg.Name` are all `type alias … = String`; ~900
String-keyed Dict declarations vs 165 Int-keyed). Primitive-keyed specs (86)
already use the `eco.{int,float,char}.cmp_order` intrinsics; String and
structured keys fall through to the boxed kernel — paying runtime tag
dispatch in `Utils::cmp`, a statepoint, and gc-free/borrow poison per call.

### 1.2 Calibration: what we measured about the fix space

The gc-leaf pilot (reverted; `plans/kernel-call-census.md` §C2.4) stamped
`Utils_compare` + 19 others gc-leaf — covering **64.1% of dynamic kernel
calls** — and was **wall-FLAT** on Stage 7a (330.87s vs 330.90s, 2×2
interleaved). Load-bearing conclusion: **removing statepoints around these
calls does not move wall; only deleting executed work can.** The deletable
work per comparison is:

1. the 3 `getOrder` gc-leaf calls per intrinsic `cmp_order` —
   `emitOrderSelect` emits all three unconditionally plus two `llvm.select`s
   (`EcoToLLVMArith.cpp:1008-1019`, block comment `:994-1004`) — 881M
   calls/run;
2. the `Order` round-trip: materialize an Order HPointer, then immediately
   `eco.case` on its ctor tag (≈2.25B case dispatches/run);
3. the boxed kernel's per-call form/tag dispatch before it reaches
   `StringOps::compare` (`Utils.cpp:302-317`);
4. *(out of scope: the O(log n)·O(prefix) string walks themselves — that is
   Dict-structure work; see §8 cross-references.)*

### 1.3 The existing rewrite is dead code

`plans/compare-to-order-intrinsic-and-case-rewrite.md` Option 1 — rewrite
`case compare a b of LT/EQ/GT` into an if-chain at TypedOptimized — is
implemented and ungated (`applyCompareToOrderRewrite`,
`compiler/src/Compiler/LocalOpt/Typed/Expression.elm:181-297`, invoked at
`:850-855` and `:1182-1187`) but **fires nowhere**: its matcher
(`matchCompareCall`, `:95-123`) accepts `Can.VarTopLevel` (`:105`) and
`Can.VarKernel` (`:112`) callee heads only, while `compare` is always an
*import* and canonicalizes to `Can.VarForeign`
(`Canonicalize/Expression.elm:1392-1398` unqualified, `:1408-1419` qualified;
`VarTopLevel` is same-module-only, `:1389-1390`). Repo-wide grep: no other
references, no test exercises it. Proof it never fired:
`Compiler_Elm_Package_compareName` — the exact target shape in source —
retains `eco.case` + two `Utils_compare` calls in the self-compiled module.

Fixing the matcher pre-mono is the wrong repair: at TypedOptimized the Dict
key is still polymorphic `comparable`, so a primitive-only gate cannot fire
on the sites that matter, and the ungated rewrite **regresses String keys**
(right-descent = `lt` then `eq` = two full string walks where one `compare`
sufficed — and String keys are the 53.2%). The rewrite must happen **after
monomorphization**, where every site has a concrete key type — and the
cleanest post-mono representation is the MLIR itself.

### 1.4 The shape is already peephole-perfect in MLIR

The front-end emits, inside every Dict spec (self-compiled module;
String-keyed `Dict_insertHelp` at `eco-compiler.txt.mlir:11634-11636`,
Int-keyed twin at `:47724-47727`):

```mlir
%o   = "eco.call"(%key, %nKey) <{callee = @Elm_Kernel_Utils_compare}>
       : (!eco.value, !eco.value) -> !eco.value      // or %o = eco.int.cmp_order …
%r:4 = eco.case %o : !eco.value [0, 1, 2] {case_kind = "ctor"}
       { LT-region }, { EQ-region }, { GT-region }
```

Ctor tags are pinned on both sides: `ORDER_LT=0 / ORDER_EQ=1 / ORDER_GT=2`
(`Utils.cpp:20-23`) and Order is *not* in the embedded-constant set
(`CtorTag.elm:68-70`), so compiler-assigned tags are declaration-order 0/1/2.
Measured coverage of the exact pattern (producer's **only** use is the
3-region `[0,1,2]` ctor case; false-positive string literals subtracted):

| Producer | sites | feeds case | escapes (returned / yielded / multi-use) |
|---|---:|---:|---|
| `eco.call @Elm_Kernel_Utils_compare` | 295 | **287 (97.3%)** | 7 wrapper-returns + 1 multi-use |
| `eco.int.cmp_order` (float/char: 0 in corpus) | 94 | **86 (91.5%)** | 5 returns + 1 yield + 2 get_tag chains (`:22371`, `:22376`) |

The 16 escaping sites keep today's semantics untouched (the peephole is
single-use-gated).

## 2. Design overview

Four phases, independently landable, ordered by evidence × risk:

| Phase | What | Sites (static) | Dynamic weight |
|---|---|---:|---|
| **A** | `eco.string.cmp_order` op + intrinsic selection on `[MString,MString]`; gc-leaf runtime helpers | ~200 of the 287 (String-keyed) + 7 wrappers | most of the 1.95B |
| **B** | Eco→Eco peephole: compare-producer + `eco.case [0,1,2]` → sign tests + nested bool cases; `Elm_Kernel_Utils_cmp3` sibling for residual boxed keys | 287 + 86 | ≈all of 1.95B compares + 881M getOrder + 2.25B Order-case dispatches |
| **C** | Cheaper Order materialization for residual escapes (3 calls → 1) | ≤16 | negligible after B — **optional** |
| **D** | Delete the dead pre-mono rewrite | −235 lines | 0 (never fired) |

**Expectation-setting** (honest, per §1.2): Phase B on primitive keys deletes
881M calls + case dispatches — the "delete executed work" bet with the best
mechanism evidence. Phases A+B on String keys delete the kernel tag dispatch
and the entire Order round-trip but keep the one string walk; that constant
executes 1.95B times/run. No wall number promised; protocol in §7.

## 3. Phase A — `eco.string.cmp_order`

### A.1 Front-end (4 edits, all in `Generate/MLIR/Intrinsics.elm`)

1. `type CompareKind` (`:58`): add `CompareStringKind`.
2. `utilsIntrinsic` (`:619-629`): add
   `( "compare", [ Mono.MString, Mono.MString ] ) -> Just (CompareToOrder { kind = CompareStringKind })`.
3. `intrinsicOperandTypes` `CompareToOrder` arm (`:238-247`): String →
   `[ Types.ecoValue, Types.ecoValue ]`. **REP_ABI_001** (invariants.csv:9):
   String crosses every ABI as `!eco.value`; never unbox. (`unboxArgsForIntrinsic`
   already no-ops when the expected type is boxed — `:288`.)
4. `generateIntrinsicOp` `CompareToOrder` arm (`:948-966`): String →
   `( "eco.string.cmp_order", Types.ecoValue, Types.ecoValue )`.
   `intrinsicResultMlirType` needs no change (wildcard on kind, `:148-149`).

Verified call path: saturated String compares reach
`Intrinsics.kernelIntrinsic` with `home="Utils"`, `argTypes=[MString,MString]`
at `Expr.elm:4199` (via `generateSaturatedCallNoFusion`'s `MonoVarKernel` arm
`:3867-3875`; no special-case diverts Utils.compare). Mono-side type
preservation already holds: `("Utils","compare")` is in
`suffixSelectingKernels` (`Monomorphize/KernelAbi.elm:152`) — **no
Monomorphize change needed**. Bonus: the escape-as-closure wrapper bodies
(`Basics_compare_$N` for String, e.g. `eco-compiler.txt.mlir:11665-11667`)
contain the direct kernel form and upgrade automatically, exactly as the Int
wrappers already inline `eco.int.cmp_order` (`:7280-7281`).

### A.2 Ops.td + lowering

New defs next to the cmp_order block (`Ops.td:2707-2749`), both `[Pure]`
(the established trait for these ops; the CSE/hoist rationale is documented
at `EcoToLLVMArith.cpp:1000-1004`):

```tablegen
def Eco_StringCmpOrderOp : Eco_Op<"string.cmp_order", [Pure]>  // (ins Eco_Value, Eco_Value) -> (outs Eco_Value)
def Eco_StringCmp3Op    : Eco_Op<"string.cmp3",      [Pure]>  // (ins Eco_Value, Eco_Value) -> (outs Eco_Int)
```

**`[Pure]` soundness caveat (pin in the op descriptions):** unlike the
primitive cmp_order ops (which read no heap), these two read string *contents*
through their operands. `[Pure]` (CSE/hoist/DCE-able) is sound only because
Eco strings are immutable after construction — every `chars[]`/byte write in
`StringOps.hpp` targets a freshly-allocated, not-yet-published `out` object —
and SSA dominance already prevents motion above the operands' defs. If a
mutable string form (in-place builder, etc.) is ever added, revisit these
traits before anything else.

`string.cmp_order` is what the front-end emits (drop-in Order producer);
`string.cmp3` is Phase B's rewrite target (sign-returning; no Order at all).

Lowering (`EcoToLLVMArith.cpp`, model on `IntCmpOrderOpLowering:1023-1041`,
register at `:1188-1190`):

- `string.cmp3` → one gc-leaf call `@eco_string_cmp3(hptr, hptr) -> i64`.
- `string.cmp_order` v1 → one gc-leaf call
  `@eco_string_cmp_order(hptr, hptr) -> ptr addrspace(1)` (C++ side: cmp3 +
  singleton pick — **one** call total; same safe shape as today's `getOrder`
  calls: an addrspace(1) call result is a first-class GC pointer RS4GC
  tracks; gc-leaf only elides the statepoint, `EcoToLLVMArith.cpp:1002-1003`).

### A.3 Runtime helpers

In `runtime/src/allocator/RuntimeExports.{h,cpp}` (StringOps lives in
allocator/, precedent `eco_int_pow` decl `:694`):

```cpp
extern "C" int64_t  eco_string_cmp3(HPtr a, HPtr b);      // sign of StringOps::compare
extern "C" HPtr     eco_string_cmp_order(HPtr a, HPtr b); // cmp3 + ORDER_* singleton
```

- **gc-leaf soundness re-verified**: `StringOps::compare`
  (`StringOps.hpp:1544-1608`) is GC-allocation-free on all four paths — leaf
  `charCompare`, both-UTF-8 `memcmp`, single-segment view, and the general
  lockstep whose only allocations are C++-heap `std::vector` scratch
  (`:1593-1607`, `:276-364` — "No allocator calls inside the walk"). (The
  doc comment `:1539-1542` describing a `toStdU16String` snapshot is stale —
  ignore it.)
- **Sign is UNCLAMPED** (memcmp/size-difference values) — consumers test
  `<0 / ==0 / >0`, never `==±1`. Pin this in the op descriptions.
- **Return-width trap (mandatory):** `StringOps::compare` returns C `int`;
  the extern definition MUST be declared `int64_t` so the widening is the
  C++ `int→int64_t` return conversion (sign-extending, value-preserving —
  `int` range can never hit `INT64_MIN`, so no negation/overflow hazard).
  Never define the symbol as returning `int` while the MLIR/LLVM decl says
  `i64`: on SysV x86-64 an `int`-returning callee leaves RAX's upper 32 bits
  undefined, and the i64 sign tests then read garbage (e.g. `-1` with zeroed
  upper bits reads as a huge *positive* i64 → LT misroutes to GT). Same rule
  for `Elm_Kernel_Utils_cmp3` (§4.4).
- **Empty-string semantics**: `Empty` is the embedded constant 0x6;
  `Export::toPtr` collapses it to `nullptr` and `compare`'s null arms
  (`:1545-1547`) give empty < non-empty, both-empty EQ. The wrappers must
  resolve exactly as `Elm_Kernel_Utils_compare` does (`UtilsExports.cpp:12-15`).
- **Resolution-parity trap:** "resolve exactly as the kernel" means the FULL
  `Export::toPtr` logic (`ExportHelpers.hpp:47-69`): embedded-constant check →
  `nullptr`, **`isInHeap` → `resolveFast` (forwarding-aware), else return the
  word as a raw non-heap pointer** (rodata literals). The nearest local helper
  in RuntimeExports (`hpointerToPtr`, `RuntimeExports.cpp:55-63`) is NOT
  equivalent — it unconditionally `resolve()`s every non-constant and has no
  raw/out-of-heap branch — do not reuse it. This tilts the layering decision
  below: implementing BOTH wrappers in `UtilsExports.cpp` (where `Export::toPtr`
  is already in scope) is both layering-clean and resolution-correct; if
  `eco_string_cmp3` stays in RuntimeExports it must replicate toPtr verbatim.
- `eco_string_cmp_order` needs the singleton getters — reuse
  `Utils::getOrderLT/EQ/GT`... **no**: those live in `elm-kernel-cpp` (layering).
  Simplest layering-clean option: implement `eco_string_cmp_order` in
  `UtilsExports.cpp` (it already owns the singletons) and only `eco_string_cmp3`
  in RuntimeExports; the lowering doesn't care which archive the symbol comes
  from. Decide at implementation time; both symbols must be registered.
- **Mandatory plumbing** (assert-enforced): `EcoRuntime::getOrCreate*` decls
  with `gcLeaf=true` (`EcoToLLVMRuntime.cpp:916-930` pattern) **plus** entries
  in `materializeAllRuntimeDecls` (`:1183+`; a miss after `freeze()` asserts,
  `:133-137`), **plus** JIT registration in `RuntimeSymbols.cpp`
  (`eco_int_pow` pattern `:441-444`).

### A.4 Rejected alternative: per-instance `Elm_Kernel_Utils_compare_String`

Fully viable (one arm in `Generate/MLIR/KernelAbi.elm:206` + ~10 lines C++;
`kernelBackendAbiPolicy` is uniformly `ElmDerived` since Phase F, `:67-89`,
so no policy interaction) but strictly weaker: still an attribute-free
`is_kernel` extern (statepoint + CGEN_072 poison), invisible to Phase B's
uniform matcher, and it **breaks pinned tests**
(`compiler/tests/.../KernelAbiTest.elm:66-73` asserts `[MString,MString]` →
root symbol). The intrinsic route pre-empts `registerKernelInstance` at
`Expr.elm:4199`, so `KernelAbiTest` stays green untouched.

### A.5 Deferred: pointer-equality inline fast path

`StringOps::compare` has **no** `a == b` short-circuit today
(`:1544-1567`), and string literals are *not* content-deduped (one interned
object per `StringLiteralOp` site, keyed by rodata address —
`EcoToLLVMTypes.cpp:145-202`, `RuntimeExports.cpp:584-723`), so Dict-key
pointer-equality hit rate is unproven. Add a cheap `if (a==b) return 0;` in
the C++ helper (free), but do **not** build an inline MLIR fast path until a
census shows the hit rate justifies it.

## 4. Phase B — the compare→branch peephole (the post-mono rewrite)

### B.1 Pass and placement

New pass `EcoCompareCaseRewrite` (`runtime/src/codegen/Passes/
EcoCompareCaseRewrite.cpp`), registered in `buildEcoToEcoPipeline`
**after `createEcoPAPSimplifyPass` (`EcoPipeline.cpp:63`) and before
`createUndefinedFunctionPass` (`:66`)**:

- after PAPSimplify ⇒ closure-mediated compares are already direct calls;
- before UndefinedFunction ⇒ CGEN_011 validation covers anything we emit
  (note the stale comment at `EcoPipeline.cpp:65` — the pass *fails* on
  undefined callees, `UndefinedFunction.cpp:73-82`);
- automatically before JoinpointNormalization / EcoControlFlowToSCF /
  EcoGCPrepare, so `eco.case` is still present (it survives the whole
  Eco→Eco stage; SCF conversion consumes it later) and root-set liveness is
  computed on the *final* shape.

Registration surface: `Passes.h:25-48` decl; `EcoPipeline.cpp` addPass;
`runtime/src/codegen/CMakeLists.txt:353-389` source list **and** the
`OBJECT_DEPENDS` guard at `:276-304`. Skeleton template: `UndefinedFunction.cpp:29-88`; driver
template: **seeded** `applyOpPatternsGreedily` over collected roots
(`EcoPAPSimplify.cpp:594-642` — the whole-module greedy driver cost ~1s of
self-host build; do not repeat that).

### B.2 The match (v1, deliberately narrow)

Root = any producer in {`eco.int.cmp_order`, `eco.float.cmp_order`,
`eco.char.cmp_order`, `eco.string.cmp_order`,
`eco.call @Elm_Kernel_Utils_compare`} such that:

1. the result has **exactly one use**;
2. that use is `eco.case %o : !eco.value [t0, t1, t2] {case_kind = "ctor"}`
   scrutinizing it, whose tag list is a **permutation of [0, 1, 2]**
   (region *i* handles `tags[i]` — never assume region order equals tag
   order);
3. the case's results are **not aggregate-typed** (CGEN_064 territory —
   `CaseToScfIfPattern` itself bails on aggregates,
   `EcoControlFlowToSCF.cpp:184-185`).

Everything else — partial tag lists (`[0,1]`, `[2,0]` from wildcard
collapses), multi-use results, `eco.return`/`eco.yield` consumers — is left
untouched and counted (`[cmpcase] rewritten=N skipped=M` census line, gated
on env naming per the `[gcfree]` convention). The measured corpus says v1
already covers 287 + 86 sites; generalizing to 2-arm cases is a v2 decision
to take on evidence.

### B.3 The rewrite

Compute a lt/gt test pair from the producer, then re-nest the existing
regions under two bool-kind cases, **EQ as the final else** (this exact
structure is what makes Float NaN semantics fall out correctly):

```
producer                 isLt                    isGt
eco.int.cmp_order a b  → eco.int.lt a b        , eco.int.gt a b
eco.float.cmp_order    → eco.float.lt a b (OLT), eco.float.gt a b (OGT)
eco.char.cmp_order     → eco.char.lt a b (ult) , eco.char.gt a b (ugt)
eco.string.cmp_order   → %s = eco.string.cmp3 a b ; eco.int.lt %s, %c0 ; eco.int.gt %s, %c0
eco.call @…_compare    → %s = eco.call @Elm_Kernel_Utils_cmp3 a b ; sign tests as above
```

```mlir
%r:N = eco.case %isLt : i1 [1, 0] {case_kind = "bool"} {
         <LT region, moved verbatim>
       }, {
         %isGt = …
         %q:N = eco.case %isGt : i1 [1, 0] {case_kind = "bool"} {
                  <GT region, moved>
                }, {
                  <EQ region, moved>
                }
         eco.yield %q#0, … : …
       }
```

- **NaN→EQ preserved**: today's lowering routes NaN to EQ via ordered
  OLT/OGT (`EcoToLLVMArith.cpp:1054-1059`; op doc `Ops.td:2724-2725`). With
  lt-then-gt-else-EQ, NaN fails both ordered tests and lands in EQ — bit-for-
  bit the same routing. Never use an `isEq` (OEQ) second test — that sends
  NaN to GT.
- Bool-kind convention: tags-array-driven; front-end always emits `[1, 0]`
  (region0 = tag 1 = True — `Expr.elm:4620` et al.; the SCF lowering accepts
  either order, `EcoControlFlowToSCF.cpp:227-239`). Match the front-end.
- **Verifier contract** (CGEN_010/028/029/037/042/043; `EcoOps.cpp:130-288`):
  regions move whole (single block, `eco.yield`-terminated — moved yields
  re-bind to the *nearest* enclosing case, and inner/outer result types are
  identical to the original's, so `YieldOp::verify` (`:290-325`) is satisfied
  without rebuilding yields); `|tags| == |regions|`; i1 scrutinee with
  case_kind `"bool"`; ≥1 result. Nested cases are explicitly supported by the
  SCF conversion (`EcoControlFlowToSCF.cpp:212-215`).
- Region mechanics precedent: `rewriter.inlineRegionBefore`
  (`EcoToLLVM.cpp:100-105`), `Region::takeBody`
  (`EcoListCursor.cpp:307-317`). No pass builds `eco.case` in C++ today
  (front-end emits it textually) — use the TableGen-generated builder.
- **Insertion point / no-adjacency assumption:** single-use does NOT imply
  the producer sits immediately before the case, or even in the same
  block/region — the producer may be in an *ancestor* region of the case
  (`eco.case` is not IsolatedFromAbove). Never key the match on
  `getNextNode()` adjacency. Insert all new ops (cmp3/sign tests, `%c0`)
  immediately before the case: the producer's operands dominate the producer,
  the producer dominates the case (its result reaches it), and dominance is
  transitive — so the operands are legal there. For the String/boxed rows
  this *sinks* the one compare call from the producer's position to the
  case's position; that is safe (pure, total, allocation-free on the string
  path; GCPrepare runs later and roots/statepoints the moved boxed call at
  its new position) and can only reduce execution count. Also note: the
  single-use gate automatically excludes cases whose regions reference the
  Order value itself (a region use would be a second use), so moved regions
  can never contain dangling references to the erased producer.
- Tail-call safety: nothing produces `musttail` (repo-wide zero),
  self-tail-recursion is front-end `scf.while` (`TailRec.elm`), and
  `EcoTailConversions` is parked out of the pipeline
  (`EcoTailConversions.cpp:3-12`) — re-nesting regions cannot break any
  tail-call discovery.

### B.4 `Elm_Kernel_Utils_cmp3` (residual boxed keys: lists, tuples, …)

`Utils::compare` is literally `int n = cmp(a,b)` + 3-way singleton select
(`Utils.cpp:451-457`); the internal `cmp` already returns a sign int and
routes cross-form strings before tag dispatch (`:302-317`). Expose:

- `int Utils::cmp3(void*, void*)` in `Utils.hpp` (~decl next to `:39`);
- `extern "C" int64_t Elm_Kernel_Utils_cmp3(HPtr, HPtr)` in
  `UtilsExports.cpp` + `KernelExports.h:180-185` block + `KERNEL_SYM`
  (`RuntimeSymbols.cpp:704` block). The wrapper must `Export::toPtr` both
  args (exactly as `Elm_Kernel_Utils_compare` does) and must be *defined*
  returning `int64_t`, widening `Utils::cmp3`'s `int` via the C++ return
  conversion — see the return-width trap in §3.3.
- **Not gc-leaf** — generic `cmp` recurses over arbitrary heap shapes; all
  kernel externs stay poison by policy (CGEN_072, invariants.csv:636). It
  remains a statepointed `eco.call`; the win at these sites is the deleted
  Order round-trip only.
- The peephole must insert the `func.func` `is_kernel` declaration itself
  (`ensureDecl` precedent, `EcoListTemplate.cpp:282-294`) or
  UndefinedFunction fails the build. KERN_006 applies: the decl's types are
  authored here and reflected verbatim (`(!eco.value,!eco.value) -> i64`).

### B.5 Secondary-effects checklist

- **JoinpointNormalization sensitivity**: `hasSimpleCaseDispatch` keys on a
  joinpoint body's top-level case (`JoinpointNormalization.cpp:94-148`);
  restructuring one can demote it from `scf_candidate` (perf, not
  correctness). Gate: compare `scf_candidate` counts on the self-host module
  before/after.
- **EcoListTemplate** (CGEN_071): chain matching crosses `eco.case` yields
  in chunk-compiled modules; attr-gated and combinator-only, low risk —
  verify scratch-site counts unchanged (same gate as the design doc §4 R1).
- **String-case / joinpoint-nested cases** lower via the CF path rather than
  SCF (`EcoControlFlowToSCF.cpp:204-210`); the rewrite is local to
  compare-on-Order cases, so path changes only apply to the rewritten case
  itself — fixtures cover both.

## 5. Phase C — cheaper Order materialization (OPTIONAL after B)

After B, Order values survive only at the ≤16 escape sites (+ any v1 bails)
— dynamically negligible (the two hot get_tag chains at
`eco-compiler.txt.mlir:22371/:22376` are lexicographic tuple-compares worth
checking in the census rerun). If residual `getOrder` traffic still shows:

- **C-v1 (recommended):** one gc-leaf call `eco_order_from_sign(i64) -> hptr`
  replacing the three-call `emitOrderSelect` — ⅓ the calls, no new invariant
  surface.
- **C-v2:** export `extern "C" uint64_t eco_order_singletons[3]` + one typed
  `load ptr addrspace(1)` indexed by `1+sign`. **REP_LLVM_002 constraint**
  (invariants.csv:16): the load must be the typed-ptr form — a
  `load i64` + `inttoptr` is the forbidden fold-unstable shape; and the load
  must never be `invariant` (slots are nursery-born and GC rewrites them in
  place, `Utils.cpp:33-45`).
- **C-v3:** allocate the singletons in PermanentSpace (HEAP_036 pattern) so
  they never move. Largest change; only if C-v2's mutability constraint
  proves annoying.

## 6. Phase D — delete the dead pre-mono rewrite

After B is green through the gates: delete
`LocalOpt/Typed/Expression.elm:95-123` (`matchCompareCall`), `:126-178`
(`matchOrderBranches`), `:181-297` (`applyCompareToOrderRewrite`), and
collapse both use sites (`:850-855`, `:1182-1187`) to the generic path.
**Keep `boolType` (`:88-92`)** — used at `:306`. Check for newly-unused
imports. Deletion cannot change output (the matcher never fired — §1.3).
Update `plans/compare-to-order-intrinsic-and-case-rewrite.md`'s status header:
Option 1 superseded by this plan's Phase B.

## 7. Gates and measurement

Per phase, in order:

1. **Structural fixtures** (`test/codegen/*.mlir`, `-emit=mlir-eco` runs
   exactly `buildEcoToEcoPipeline` — `ecoc.cpp:199-205`): (a) String
   compare emits `eco.string.cmp_order` (Phase A); (b) cmp_order + case
   rewrites to nested bool cases, `CHECK-NOT: [0, 1, 2]` (Phase B); (c) an
   escaping cmp_order is NOT rewritten; (d) a `[0,1]` partial case is NOT
   rewritten (v1 bail); (e) jit-mode behavior fixtures for LT/EQ/GT × each
   producer kind, including a Float NaN case pinning NaN→EQ (each side and
   both), a `-0.0` vs `0.0` case pinning EQ (falls out of OLT/OGT, not a bit
   compare — pin it anyway), and a Char pair at the u16 extremes
   (`0x0000`/`0xFFFF`, pinning unsigned ult/ugt routing).
2. **E2E** (`cmake --build build --target full`, never `check`;
   `TEST_FILTER=codegen` then `TEST_FILTER=elm`; run ONCE, tee to
   `/tmp/test_output.txt`). Existing pins that must stay green:
   `CaseOrderTest.elm` (exactly the Phase-B shape), `CompareStringTest.elm`,
   `ContainerCompareStringTest.elm`, `DictDiffFoldlStringKeysTest.elm`,
   `DictTupleListKeyTest.elm`, `ListSortWithFloatCompareTest.elm` /
   `ListSortByFloatIdentityTest.elm` (NaN routing),
   `OrderingEmptyListTest.elm` / `OrderingEmptyListPapTest.elm`
   (empty-string constant semantics). `ConsNumberTaintTest` is a known
   pre-existing solver gate, unrelated.
3. **Heap-validate tree**: separate `-DECO_HEAP_VALIDATE=ON` build
   (`/work/CMakeLists.txt:84-89`), baseline 1623/1623.
4. **Bootstrap fixed point** (Stage 8c, binary byte-compare on Linux,
   `compiler/CMakeLists.txt:547-588`): the first build legitimately differs
   (codegen change); the fixed point must still close.
5. **Wall A/B**: cold Stage 7a, interleaved 2×2 minimum, outputs
   byte-compared, ±0.3% noise floor stated, majors-unavailable caveat noted
   (`plans/kernel-call-census.md` §C2.4 protocol).
6. **Dynamic census rerun** (re-apply the reverted `ECO_KERNEL_CALL_CENSUS`
   patch per `plans/kernel-call-census.md` §C1): expected shape —
   `Eco_Runtime_getOrder*` ≈ 0; `Elm_Kernel_Utils_compare` ≈ 0, replaced by
   `eco_string_cmp3` (not a counted kernel prefix — extend the census prefix
   list with `eco_string_cmp3`/`Elm_Kernel_Utils_cmp3` to keep it visible);
   total kernel-call count down by ≈2.8B (76%).
7. **Census lines**: the pass prints `[cmpcase] rewritten=N skipped=M` when
   its env var is named, mirroring `[gcfree]`.

## 8. Invariants and cross-references

- **Add an invariant row** (none covers cmp_order or the Order singletons —
  verified): proposed `CGEN_0XX;MLIR_Codegen;CompareLowering;enforced;`
  "Order ctor tags are pinned LT=0/EQ=1/GT=2 on both sides (Utils.cpp:20-23,
  compiler declaration order); eco.*.cmp3 ops return UNCLAMPED sign ints
  consumed only via <0/==0/>0; the compare-case rewrite must route Float NaN
  to the EQ branch (ordered lt/gt tests, EQ-as-else); rewritten cases
  preserve region semantics tags-array-driven."
- Related but **not** this plan: Dict-structure work (§7.3 of the design doc
  — the O(log n) string walks themselves; `plans/hash-prefix-comparable-keys.md`
  attacks the same cost at the key-representation level for the JS-side
  registry and is complementary), `plans/cse-pure-calls.md` (a `[Pure]`
  `eco.string.cmp_order` becomes CSE-able the day an MLIR CSE pass exists —
  design doc §9 H2).

## 9. Sizing and sequencing

| Phase | Effort | Risk | Deliverable |
|---|---|---|---|
| A | **M** (4 Elm edits + 2 ops + 2 lowerings + 2 runtime syms + plumbing ×3) | Low — additive; intrinsic miss = status quo | String compares stop entering the boxed kernel |
| B | **M–L** (new pass ~300 lines; region surgery; census line; cmp3 sibling) | Medium — verifier traps enumerated in §4.3; v1 narrowness bounds it | Order round-trip deleted at 373 sites; getOrder ≈ 0 |
| C | **S** | Low | optional cleanup, evidence-gated |
| D | **S** | ~0 | −235 lines dead code |

Sequence: A → B (A's `string.cmp3` op is B's rewrite target for String;
B's fixtures assume A's producer exists) → census rerun → C only if the
census demands it → D. A alone is landable and useful; B is where the
measured 77% of dynamic kernel traffic actually gets deleted.
