# Kernel-Opt 01: List.cons -> eco.construct.list intrinsic

**Status: IMPLEMENTATION-READY v2 — 2026-08-10.** (deepened from OUTLINE v1; anchors
re-verified against the tree). Derived from design_docs/kernel-boundary-reduction.md
"CONVERT-EXISTING #1" (:356-414) and recommendation R1 (:533-547); dynamic census
design_docs/kernel-boundary/kernel-census-dynamic-stage7a.txt; static census
design_docs/kernel-boundary/callsite-census-self-compile.txt.

## Goal

Replace the `Elm_Kernel_List_cons` extern call (and its `_Int`/`_Float`/`_Char`
variants) with the existing `eco.construct.list` op at every saturated `x :: xs` site,
so each cons pays the HEAP_034 inline nursery bump instead of a statepointed runtime
call — the largest single kernel conversion remaining, and the highest-confidence wall
bet in the series (deleted-per-op-work family, not metadata-only).

## Files touched

| File | Change |
|---|---|
| `compiler/src/Compiler/Generate/MLIR/Intrinsics.elm` | new `ConstructList { headMlirType : MlirType }` ctor (:27-53); `listIntrinsic` classifier; arms in `intrinsicResultMlirType` (:71), `intrinsicOperandTypes` (:155), `kernelIntrinsic` dispatch (:318-340), `generateIntrinsicOp` (:773) |
| `compiler/src/Compiler/Generate/MLIR/Expr.elm` | `consIntrinsicFor` gate helper + `coerceIntrinsicArgs` (new top-level helpers next to `boxToEcoValue` :1263-1295; both internal — Expr.elm's `exposing` list is untouched); consult-site rewrites at :3725/:3731 and :4199/:4204 (`Maybe.andThen` filter, no new branches) |
| `compiler/src/Compiler/Eco/Config.elm` | `ListConfig.consIntrinsic : Bool` (:61-64) + its doc comment (:51-59), `default.list` record literal (:324), `listDecoder` (:367-370), `hash` token `lcons=1` (new block after :686) |
| `compiler/src/Builder/Eco/Config.elm` | new `applyListConsIntrinsicOverride` (copy of `applyListChunksOverride` :486-511, placed after :511) + a `Task.andThen` link in `applyEnvOverrides`' chain (insert after the `ECO_LIST_REPORT` link :225-229; binder name is cosmetic — the chain already reuses `cfg26` twice at :246/:256) |
| `test/elm/src/ListConsIntrinsicTest.elm` | NEW — behaviour + `-- CHECK-MLIR` conversion fixture (boxed / Int / Float / Char heads, devirt path, accumulator loop). Auto-discovered by `discoverTests` (ElmE2ETestBase.hpp:1089-1105) — no registration |
| `test/elm/src/ListConsIntrinsicBailTest.elm` | NEW **only if §3.2's discovery step finds a reachable decline shape** — `-- CHECK-MLIR: @Elm_Kernel_List_cons` |
| `compiler/tests/Compiler/Generate/MLIR/IntrinsicsListConsTest.elm` | NEW — table unit test driven through the EXPOSED `Intrinsics.kernelIntrinsic "List" "cons" …` (`listIntrinsic` is internal; do not widen the `exposing` list). Mirrors `KernelAbiTest.elm`; `exposing (suite)`, `suite : Test` |
| `runtime/src/codegen/Passes/EcoListTemplate.cpp` | ONLY under contingency B (§Phase 1 decision) — relax `getLiveRoots().empty()` at :148-150 / :659-661 |

No runtime/kernel C++ change on the primary path, and **no symbol deletion**.
`Elm_Kernel_List_cons{,_Int,_Float,_Char}` (definitions
elm-kernel-cpp/src/core/ListExports.cpp:276-304, declarations
elm-kernel-cpp/src/KernelExports.h:153-157, JIT/AOT symbol registration
runtime/src/codegen/RuntimeSymbols.cpp:689-693) all **stay**: the unapplied-`cons`
closure/PAP path (`generateVarKernel` Expr.elm:764-775 → `instanceClosureResult` :876) can
still reach them, they remain the flag-off encoding, and kernel-opt-07 keeps a facts row for
them. (Measured: that path emits **0** references in today's self-compile module — see
Evidence — so retention is about reachability-in-principle and rollback, not about a live
site count. Deleting kernel symbols is out of scope here; see kernel-opt-14's deletion policy.)

## Flag & rollback

- **Flag:** `list.consIntrinsic : Bool`, **default `False`**. JSON `{"list":{"consIntrinsic":true}}`;
  env `ECO_LIST_CONS_INTRINSIC=1|true|yes|on` / `=0|off`. Artifact-affecting → hash token
  `lcons=1` emitted only when enabled (same posture as `lchunks=1`, Config.elm:677-686), so
  flag-on artifacts never share flag-off caches and every existing config hashes byte-identically.
- **Rollback:** unset the env var / drop the JSON key ⇒ `consIntrinsicFor` returns `Nothing`
  ⇒ the `Nothing` branch at Expr.elm:4222 runs unchanged ⇒ **byte-identical MLIR to today**.
  Full revert = delete the `ConstructList` ctor + arms and the 2 consult-site `Maybe.andThen`
  lines; nothing else depends on them.
- **Default flip is a SEPARATE commit** after all gates in §Gates, with the measured numbers
  in the Config.elm field comment (the `aggPromote`/`ctorInline` convention, Config.elm:42-47).

## Evidence

- **Dynamic:** `Elm_Kernel_List_cons` = 191,877,556 calls (5.2% of 3.68B; rank #6 in
  kernel-census-dynamic-stage7a.txt), plus cons_Int 1,184,775 and cons_Char 52,675.
- **Static (design-doc snapshot):** raw grep hits 4,158 / 92 / 56 in
  callsite-census-self-compile.txt; each symbol contributes one `func.func private`
  `is_kernel` stub line, so **4,157 + 91 + 55 = 4,303 call sites = 25.5%** of all kernel call
  forms.
- **Static (RE-MEASURED 2026-08-10 on this tree**, rendered from
  `build/compiler/build-kernel/bin/eco-compiler.mlir`; counting method identical to
  kernel-opt-14 §Evidence so the two plans reconcile — `direct = "callee = @Sym"`,
  `pap = "function = @Sym"`, `direct + pap + 1 stub = total occurrences`)**:**

  | symbol | direct | pap | stub | total |
  |---|---:|---:|---:|---:|
  | `Elm_Kernel_List_cons` | 4155 | 0 | 1 | 4156 |
  | `Elm_Kernel_List_cons_Int` | 91 | 0 | 1 | 92 |
  | `Elm_Kernel_List_cons_Char` | 55 | 0 | 1 | 56 |
  | `Elm_Kernel_List_cons_Float` | 0 | 0 | 0 | **0 (no stub — never instantiated)** |

  **4,301 convertible direct sites today; `pap = 0` everywhere** — i.e. the *unapplied*-`cons`
  closure path (Expr.elm:775 → `instanceClosureResult` :826/:876) mints **nothing** in this
  module, so it contributes no decline residue here (LSS devirt already collapses the
  HOF-argument uses). Same run: **13,446 `eco.construct.list`** ops (see Phase 0.1 for why the
  naive grep says 13,447).
- **Why the gap exists:** `::` is imported from `List`
  (compiler/src/Compiler/Elm/Compiler/Imports.elm:34); `kernelIntrinsic`
  (Intrinsics.elm:318-340) dispatches on `Basics`/`Bitwise`/`Utils`/`JsArray`/`Char`/`String`
  — **no `"List"` arm**. `eco.construct.list` is emitted only for list *literals*
  (`generateList`, Expr.elm:961-1043; the two `Ops.ecoConstructList` sites at :1017/:1031).
- **The op already does the work:** `Eco_ListConstructOp` (runtime/src/codegen/Ops.td:614-646)
  is `[Pure]` + `GCRootCarrier`, carries `head_unboxed` + 2-bit `head_kind` matching the
  kernel's `_Int`/`_Float`/`_Char` axis, with an optional `live_roots` variadic;
  `ListConstructOpLowering` (runtime/src/codegen/Passes/EcoToLLVMHeap.cpp:418-456) emits the
  HEAP_034 inline bump (`composeHeader` :446 + two `emitFreshFieldStore`s :450/:452,
  **zero runtime calls**) when `inlineAllocEnabled()` (:445).
- **Semantic parity is exact, not assumed:** `Elm_Kernel_List_cons` is a two-line forwarder —
  `List::cons` (elm-kernel-cpp/src/core/List.cpp:18-20) is literally
  `return alloc::cons(head, tail, headIsBoxed);`, and the `bool` overload
  (HeapHelpers.hpp:650-652) maps `true → head_kind 0`. So the boxed kernel builds exactly the
  `Tag_Cons` cell `eco.construct.list {head_kind = 0}` builds. **No chunk-awareness lives in
  the kernel** — hybrid chunk spines are a backend/`EcoListTemplate` construct, never
  something `Elm_Kernel_List_cons` does per call.
- **What the C++ path pays per cell:** HPtr encode/decode, the `eco_g_cons_sites` tally
  branch, a roots array + `eco_alloc_with_roots` statepointed call, and post-GC readback
  (HeapHelpers.hpp:629-646; `Elm_Kernel_List_cons` itself at ListExports.cpp:276-283).
- **Barrier removal (new, verified):** `eco.call` is an unconditional allocation-group
  barrier and a call safepoint (EcoGCPrepare.cpp:110-121, :125-140), while
  `ListConstructOp` is `isMayAllocOp` + `hasFixedAllocSize` = 24 B (:44, :63, :85). Converting
  a cons therefore also lets adjacent allocations **coalesce into one group** with a single
  root set (:249-305) — work deleted, not merely metadata moved.
- **Poison lines removed:** the attribute-free extern poisons gc-freeness of every transitive
  caller (CGEN_072, invariants.csv:636) and is the borrow census's largest poison line
  (`List.cons=4151`, design_docs/borrow-inf-census.md:864, out of the 26,988
  `poisonedByKernel` total at :503 — a pre-B3-KernelSigs snapshot).

## Approach

### Phase 0 — baselines (no code change)

All four baselines are recorded **before** any edit, on the current tree.

**0.1 Op counts in the self-compile module.** Stage-5/7a `.mlir` outputs are MLIR
**bytecode** (`ML\357R` magic), so they must be rendered first — and `ecoc --emit=mlir`
writes the text to **stderr**, not stdout (verified):

```bash
M=build/compiler/build-kernel/bin/eco-compiler.mlir     # or a Stage-7a -out.mlir
build/runtime/src/codegen/ecoc --emit=mlir "$M" > /dev/null 2> /tmp/base.mlir.txt

# Op count. MUST anchor on the SSA-result form: a bare `grep -c
# 'eco.construct.list'` over the SELF-COMPILE module also matches the
# compiler's own source string (`eco.string_literal "eco.construct.list"`,
# 1 occurrence) and reports 13,447 instead of 13,446. An off-by-one here
# silently corrupts the Phase-4.1 reconciliation gate.
grep -c '= eco.construct.list ' /tmp/base.mlir.txt          # 13446 today

# Cons sites, split by form (same method as kernel-opt-14 §Evidence, so the
# two plans' numbers reconcile). direct + pap + 1 stub = total occurrences.
for s in cons cons_Int cons_Float cons_Char; do
  printf '%-11s direct=%s pap=%s total=%s\n' "$s" \
    "$(grep -c "callee = @Elm_Kernel_List_$s\\b"   /tmp/base.mlir.txt)" \
    "$(grep -c "function = @Elm_Kernel_List_$s\\b" /tmp/base.mlir.txt)" \
    "$(grep -o "@Elm_Kernel_List_$s\\b" /tmp/base.mlir.txt | wc -l)"
done
# today: cons 4155/0/4156 · cons_Int 91/0/92 · cons_Char 55/0/56 · cons_Float 0/0/0

# hinted construct.list ops (roots group renders as " ... (%a, %b : ...)"):
grep -c '= eco.construct.list %[0-9]*, %[0-9]* (' /tmp/base.mlir.txt    # 0 today
```

**Measured 2026-08-10 on the current tree** (`eco-compiler.mlir`, Stage-5 self-compile):
`13,446` construct.list · `4,301` convertible direct cons sites · `0` hinted ops.
Re-measure before editing; these are the Phase-4 reconciliation targets.

Also snapshot the *bytecode* module itself — §Gates 3 diffs against it:

```bash
cp -p build/compiler/build-kernel/bin/eco-compiler.mlir /tmp/base-eco-compiler.mlir
```

**0.2 EcoListTemplate scratch sites** (the hard gate's baseline). The pass is a no-op
unless a func carries `eco.list_chunks` (EcoListTemplate.cpp:315-322), which the front end
stamps on `@main` under `list.chunks` (default **True**, Config.elm:324; Functions.elm:99-104).
Read both the emitted call counts and the pass's own bail histogram:

**PRIMARY counter — the pass's own statistics** (`ECO_LIST_TEMPLATE_DEBUG`,
EcoListTemplate.cpp:326; `unwind rewritten` printed at :346-348, `BailStats::dump` :75-87
called at :351):

```bash
ECO_LIST_TEMPLATE_DEBUG=1 build/runtime/src/codegen/eco-boot-native \
    build/compiler/build-kernel/bin/eco-compiler.mlir -o /tmp/base-elf \
    2> /tmp/base-listtemplate.txt
grep '^\[eco-list-template\]' /tmp/base-listtemplate.txt | head -3
```
**Measured baseline (2026-08-10, current tree — identical to kernel-opt-14 §0.2):**
`whiles=4792 valueArgs=15457 bail{beforeFwd=0 beforeUses=0 chainFail=11214 chainEmpty=549
baseUses=3251 kinds=0} rewritten=443`, `walkChain{blockArg=85 consUses=32 consRoots=0
headTy=0 regionShape=0 multiUse=3 otherOp=11094}`, `unwind rewritten=38`.
**Record `rewritten`, `unwind rewritten`, `consRoots`, `headTy`.**

**SECONDARY census — scratch-call sites in the linked binary** (~2 min; the scratch calls are
inserted by a BACKEND pass, so they never appear in the front-end `.mlir` — do NOT grep
`/tmp/base.mlir.txt` for them):

```bash
objdump -d --no-show-raw-insn build/compiler/build-kernel/bin/eco-compiler \
  | grep -oE 'eco_scratch_(mark|push_boxed|push_scalar|finish|finish_fwd)' | sort | uniq -c
```
**Measured baseline:** `finish=70 finish_fwd=90 mark=53 push_boxed=71 push_scalar=16`.
*(Reconciliation, per kernel-opt-14 §0.2: the design doc's "582 `eco_scratch_push_boxed` +
491 `eco_scratch_mark`" — kernel-boundary-reduction.md:400-401 — comes from a different
extraction and is NOT comparable to these numbers. Quote `rewritten=`/`unwind rewritten=` as
the parity counter and this objdump census as the secondary; never the doc's figures.)*

**0.3 Dynamic cons counts.** `ECO_CONS_SITES=1` is in-tree
(runtime/src/allocator/RuntimeExports.cpp:291-370; `ConsSiteInit` :345-364, dump format
`[cons-sites] base=%#zx total=%llu sites=%zu` at :325-330). It tallies `eco_alloc_cons`
(:374-376) and `alloc::cons` (HeapHelpers.hpp:631-632) callers by return address and dumps at
exit via the `std::atexit` handler installed in `ConsSiteInit`. The per-symbol kernel-call census
(`ECO_KERNEL_CALL_CENSUS=1`) is **not** in the tree — it was a temporary patch; re-apply
per plans/kernel-call-census.md §C1.1-C1.4 if per-symbol dynamic counts are wanted.

**0.4 Wall/RSS/GC baseline.** Exactly `benchmarks/kernel-opt.md` §Methodology (BK sandbox,
`rm -rf $BK/eco-stuff` before every run, workload engine `subst`, 2 rounds, arms reversed
in round 2). Record wall, Max RSS, `Objects/Bytes allocated`, `Minor/Major GC cycles`,
`Objects promoted`, output `.mlir` size.

**Acceptance:** all four baselines written into `benchmarks/kernel-opt.md` as "Run <X>
baseline" before Phase 1 starts.

### Phase 1 — the hint question: RESOLVED to option (1), hint-free

**Finding (v1's "verify at implementation time" — now verified):**
`Expr.emitSafepointHints ctx = Ctx.liveEcoValueVars ctx` (Expr.elm:113-115) and
`liveEcoValueVars _ = []` — **unconditionally empty** since the "Phase 2 probe"
(Context.elm:619-649; the conservative Phase-1 body survives commented out at :627-642).
Confirmed empirically (2026-08-10): the rendered Stage-5 self-compile module
(`build/compiler/build-kernel/bin/eco-compiler.mlir`, 13,446 `eco.construct.list` ops)
contains **zero** ops with a roots group — Phase 0.1's last command returns 0. Independently
corroborated by kernel-opt-10 §Evidence (`eco.construct.list` / `eco.construct.tuple2` /
`eco.box` root groups = 0; `eco.gc_roots_count` present 10× in 587,765 ops).

Consequences, all load-bearing for this plan:

1. The design doc's claim that "today's literal-only construct.list ops are emitted *with*
   hints" (kernel-boundary-reduction.md:396-399) is **stale**. The `wcConsRoots` bail
   (EcoListTemplate.cpp:176-181, and the `getLiveRoots().empty()` guards at :148-150 and
   :659-661) is currently **unreachable from front-end output**.
2. `kernelConsKind` (EcoListTemplate.cpp:98-112) requires `getNumOperands() == 2`, so it
   matches kernel cons calls only while they are hint-free — which is exactly today. A
   converted, hint-free `eco.construct.list` is matched by the *other* arm (:148-150) with
   identical `head_kind`/head-type checks (:160-169). **Parity is exact: every link form the
   template absorbs today it still absorbs after conversion.**
3. Ordering is safe: `EcoListTemplate` runs at EcoPipeline.cpp:87, **before** `EcoGCPrepare`
   at :99 — so the roots that EcoGCPrepare later attaches (Step 2, :282-284) cannot retro-blind
   the template.

**Decision: emit with an explicitly empty hint list** (`Ops.ecoConstructList ctx [] …`),
not by calling `emitSafepointHints`. Rationale: (a) it is what the op carries today anyway,
(b) it is immune to a future restoration of `liveEcoValueVars`, and (c) EcoGCPrepare computes
the real root set itself for allocation-group leaders — Step 2, EcoGCPrepare.cpp:249-305:
`computeLiveRoots` (:254) **unioned** with the leader's own `!eco.value` operands (:266-273,
a union that exists precisely for construct ops whose field stores outlive the alloc
safepoint), then written via `carrier.setGCRoots` (:283-284). Step 4 (:315-340) does the same
union for call safepoints.

*Precision that matters if hints are ever restored:* `ListConstructOp::setGCRoots`
(runtime/src/codegen/EcoOps.cpp:943-945) is `clear(); append(newRoots)` — it **replaces**,
it does not merge front-end hints. So on group *leaders* a front-end hint would be discarded
anyway, while on group *members* (never passed to `setGCRoots`) it would survive and blind
`EcoListTemplate`. Emitting hint-free is therefore the only form with uniform behaviour.

**Decision experiment (run it anyway, it is cheap):** after Phase 2 lands, build with the
flag on and run the heap-validate leg (§Gates 2). Any hint-liveness bug surfaces there, not
in the plain E2E suite.

**Contingency B (only if `liveEcoValueVars` is ever restored to non-empty):** relax the
template to absorb hinted conses by stripping the hints. Diff shape against the real code:

```cpp
// EcoListTemplate.cpp:147-153 (walkChain) — and the identical shape at :658-664 (walkUnwind)
     int64_t consKind = -1;
     if (auto c = dyn_cast<eco::ListConstructOp>(def)) {
-        if (c.getLiveRoots().empty())
-            consKind = c.getHeadKind();
+        // Front-end root HINTS are advisory: EcoGCPrepare (which runs after
+        // this pass, EcoPipeline.cpp:87 vs :99) recomputes the real set and
+        // unions. Absorbing the link deletes the op entirely, so its hints
+        // die with it — drop them instead of bailing.
+        consKind = c.getHeadKind();
     } else {
         consKind = kernelConsKind(def);
     }
```
plus deleting the now-dead `wcConsRoots` bail at :176-181 (keep the counter field so the
debug dump format is unchanged). Under contingency B the `kernelConsKind` operand-count
check at :103 must also be relaxed to "first two operands are (head, tail)".

**Acceptance:** Phase 0.1's hinted-op count is 0; the decision is recorded in this file
(done); no EcoListTemplate edit lands on the primary path.

### Phase 2 — the `"List"` arm (Intrinsics.elm)

**Where the intrinsic is consulted, and with what name (pinned).** In the saturated
kernel-call path, `home`/`name`/`funcType` are bound by the `Mono.MonoVarKernel` pattern at
**Expr.elm:3867**; `argTypes = List.map Mono.typeOf args` at :3873-3875; the generic consult
is **Expr.elm:4199** (`Intrinsics.kernelIntrinsic home name argTypes resultType`). The
`_Int`/`_Float`/`_Char` suffix is chosen **only in the `Nothing` branch**, at :4249-4266, via
`Ctx.registerKernelInstance` → `KernelAbi.deriveKernelInstanceAbi` →
`kernelInstanceSymbol` (Generate/MLIR/KernelAbi.elm:182-407; the cons arms at **:310-317**).
**Answer: `kernelIntrinsic` sees the BASE name `"cons"`, pre-suffix** — the arm must derive
the head kind itself, mirroring KernelAbi.elm:310-317.
*(v1 anchor drift: those cons arms are in `Generate/MLIR/KernelAbi.elm`, not
`Monomorphize/KernelAbi.elm`; the latter's :145-192 is `suffixSelectingKernels`, which lists
`("List","cons")` and is what keeps the concrete head MonoType alive through mono.)*

**LSS devirt (pinned).** `kernelDevirtArity` (Translate.elm:1860-1866) whitelists exactly
`List.cons/2`; when both guards pass (`kernelDevirtShapeOk` :1881-1892,
`kernelDevirtEmissionOk` :1922-1945) the rewrite emits
`Mono.MonoCall region (Mono.MonoVarKernel region kernelPrefix home name funcMonoType) monoArgs
resultMonoType Mono.defaultCallInfo` (**Translate.elm:1824-1828**) — an ordinary saturated
MonoVarKernel call. **So devirted conses flow through Expr.elm:3867 → the `case ( home, name,
argsWithTypes )` dispatch at :3877 → its catch-all `_ ->` at :4198 → the consult at :4199, and
DO get intrinsified.** When a guard declines, the site falls back to `indirectCallFallback`
(:1810/:1818) — an *indirect* call, never a kernel call, so declines are **not** extern
residue for this plan (v1 said otherwise; corrected).

**2.1 New ctor** (Intrinsics.elm:27-53, after `ArrayAppendN` :52, before `CompareToOrder` :53):

```elm
    | ArrayAppendN
    | ConstructList { headMlirType : MlirType }
    | CompareToOrder { kind : CompareKind }
```
Naming/shape follows `ArrayPush { elementMlirType : MlirType }` (:50) — a payload MLIR type
carried from classification to emission. **No export change:** the module header already
exposes `Intrinsic(..)` (Intrinsics.elm:1), so the new ctor is visible to Expr.elm and to the
unit test with no edit to the `exposing` list or the `@docs` line.

**2.2 Type arms.** All three of `intrinsicResultMlirType`, `intrinsicOperandTypes` and
`generateIntrinsicOp` are wildcard-free `case`s over `Intrinsic`, so **each needs an arm or
the module does not compile** — including `intrinsicOperandTypes`, whose ConstructList arm is
never actually consulted once §2.5's `coerceIntrinsicArgs` intercepts this ctor (its only
caller is `unboxArgsForIntrinsic`, and both consult sites route ConstructList around it). Add
it anyway, as documentation and for exhaustiveness.

```elm
-- intrinsicResultMlirType (:71-150), after the ArrayAppendN arm
        ConstructList _ ->
            Types.ecoValue

-- intrinsicOperandTypes (:155-253), after the ArrayAppendN arm
        ConstructList { headMlirType } ->
            -- Elm arg order: cons head tail. Tail is ALWAYS boxed (Ops.td:636-642).
            [ headMlirType, Types.ecoValue ]
```

**2.3 Dispatch + classifier.**

```elm
-- kernelIntrinsic (:318-340) — the `case home of` arms are Basics / Bitwise / Utils /
-- JsArray / Char / String then `_ -> Nothing`. Order is free; put "List" next to
-- "JsArray" (:330-331) so the container kernels stay together.
        "List" ->
            listIntrinsic name argTypes resultType

-- new classifier, placed beside jsArrayIntrinsic (:683-771); internal, NOT added
-- to the module's `exposing` list (see §3.3)
{-| `List.cons` (`::`) -> `eco.construct.list`. The head slot's 2-bit kind is a
HEAP layout decision (REP_BOUNDARY_002, invariants.csv:24) and must reproduce the
axis `kernelInstanceSymbol` uses for the `_Int`/`_Float`/`_Char` C variants
(Generate/MLIR/KernelAbi.elm:310-317). Anything outside that axis — an unsettled
`CNumber` head, a scalar tail/result (the `kernelDevirtShapeOk` hazard,
MonoSolver/Translate.elm:1869-1892), a non-binary application — DECLINES and keeps
today's kernel call (whitelist discipline).
-}
listIntrinsic : Name.Name -> List Mono.MonoType -> Mono.MonoType -> Maybe Intrinsic
listIntrinsic name argTypes resultType =
    case ( name, argTypes ) of
        ( "cons", [ headTy, tailTy ] ) ->
            case consHeadAbi headTy of
                Just headMlirType ->
                    if boxedSlot tailTy && boxedSlot resultType then
                        Just (ConstructList { headMlirType = headMlirType })

                    else
                        Nothing

                Nothing ->
                    Nothing

        _ ->
            Nothing


{-| The head's ABI type, or `Nothing` when the numeric axis is not settled.
`MVar _ CNumber` maps to `i64` under `monoTypeToAbi` (Types.elm:170-172) but does
NOT match the `_Int` suffix arm, so today's site calls the BOXED root symbol with an
i64 head — an unsettled shape this intrinsic must not freeze into a heap layout.
-}
consHeadAbi : Mono.MonoType -> Maybe MlirType
consHeadAbi headTy =
    case headTy of
        Mono.MInt ->
            Just Types.ecoInt

        Mono.MFloat ->
            Just Types.ecoFloat

        Mono.MChar ->
            Just Types.ecoChar

        Mono.MVar _ Mono.CNumber ->
            Nothing

        _ ->
            if Types.isEcoValueType (Types.monoTypeToAbi headTy) then
                Just Types.ecoValue

            else
                Nothing


boxedSlot : Mono.MonoType -> Bool
boxedSlot t =
    Types.isEcoValueType (Types.monoTypeToAbi t)
```

**2.4 Emission arm** (`generateIntrinsicOp`, :773-981; add before `CompareToOrder`):

```elm
        ConstructList { headMlirType } ->
            -- Elm arg order: cons head tail. HINT-FREE by construction (Phase 1):
            -- EcoGCPrepare recomputes and UNIONS roots at this carrier
            -- (EcoGCPrepare.cpp:249-305), and EcoListTemplate only absorbs
            -- hint-free links (EcoListTemplate.cpp:148-150).
            case argVars of
                [ headVar, tailVar ] ->
                    Ops.ecoConstructList ctx [] resultVar
                        ( headVar, headMlirType )
                        ( tailVar, Types.ecoValue )
                        (Types.isUnboxable headMlirType)

                _ ->
                    Ops.ecoConstructList ctx [] resultVar
                        ( "%error", headMlirType )
                        ( "%error", Types.ecoValue )
                        (Types.isUnboxable headMlirType)
```
`Ops.ecoConstructList` (Ops.elm:194-224) derives `head_kind = Types.mlirTypeToKind headType`
when `headUnboxed`, else 0 — i.e. **from the SSA operand type**, satisfying REP_BOUNDARY_002
automatically provided Phase 2.5 coerces the operand to `headMlirType`.

**2.5 Operand coercion + the flag gate** (Expr.elm, beside `boxToEcoValue` :1263-1295):

`unboxArgsForIntrinsic` (:285-309) only ever **unboxes**; a boxed head slot fed by a
primitive/aggregate SSA value needs the **box** direction, which only Expr.elm has
(`boxToEcoValue` handles `eco.box` for scalars and `eco.to_heap` for U-T1.3.1 aggregates).
Add two small helpers and touch nothing else:

```elm
{-| kernel-opt-01: gate + SSA-type admissibility for the cons intrinsic.
Declines (⇒ today's kernel call) when the flag is off, or when a primitive head
slot is fed by a DIFFERENT primitive SSA type (a layout disagreement we must never
freeze). Aggregate heads are admitted only into a BOXED slot, where
`boxToEcoValue` emits `eco.to_heap`.
-}
consIntrinsicFor : Ctx.Context -> List ( String, MlirType ) -> Intrinsics.Intrinsic -> Maybe Intrinsics.Intrinsic
consIntrinsicFor ctx argsWithTypes intrinsic =
    case intrinsic of
        Intrinsics.ConstructList { headMlirType } ->
            case ( ctx.ecoConfig.list.consIntrinsic, argsWithTypes ) of
                ( True, [ ( _, headSsaTy ), _ ] ) ->
                    if Types.isEcoValueType headMlirType then
                        Just intrinsic

                    else if Types.isEcoValueType headSsaTy || headSsaTy == headMlirType then
                        Just intrinsic

                    else
                        Nothing

                _ ->
                    Nothing

        _ ->
            Just intrinsic


{-| Coerce actual SSA args to an intrinsic's expected operand types. Only
`ConstructList` needs the box direction; every other intrinsic keeps exactly
today's `unboxArgsForIntrinsic` behaviour (byte-identical output when the flag
is off, and for all non-cons intrinsics when it is on).
-}
coerceIntrinsicArgs : Ctx.Context -> List ( String, MlirType ) -> Intrinsics.Intrinsic -> ( List MlirOp, List String, Ctx.Context )
coerceIntrinsicArgs ctx argsWithTypes intrinsic =
    case ( intrinsic, argsWithTypes ) of
        ( Intrinsics.ConstructList { headMlirType }, [ ( headVar, headSsaTy ), ( tailVar, tailSsaTy ) ] ) ->
            let
                ( headOps, headVar1, ctxH ) =
                    if Types.isEcoValueType headMlirType then
                        boxToEcoValue ctx headVar headSsaTy

                    else if Types.isEcoValueType headSsaTy then
                        Intrinsics.unboxToType ctx headVar headMlirType

                    else
                        ( [], headVar, ctx )

                ( tailOps, tailVar1, ctxT ) =
                    boxToEcoValue ctxH tailVar tailSsaTy
            in
            ( headOps ++ tailOps, [ headVar1, tailVar1 ], ctxT )

        _ ->
            Intrinsics.unboxArgsForIntrinsic ctx argsWithTypes intrinsic
```

**Coercion parity with today, proven (not assumed).** The kernel path this replaces runs
`boxToMatchSignatureTyped ctx1 argsWithTypes elmSig.paramTypes` (Expr.elm:4247, helper
:1301-1346). For the boxed cons its `helper` takes the `expectedMlirTy` = `!eco.value`,
`actualTy` = primitive branch (:1320-1329) and calls **`boxToEcoValue ctxAcc var actualTy`**
— literally the call `coerceIntrinsicArgs` makes. So every head/tail coercion the converted
site emits is the one emitted today, including the `MBool` head case (SSA `i1` under
`monoTypeToOperand`, boxed by `eco.box` in both worlds). One deliberate divergence: today's
`else` arm (:1342-1344) *silently passes a mismatched primitive through* (its own comment:
"No boxing solution (e.g. i64 vs f64) — use actual type for now"); `consIntrinsicFor`
**declines** that case instead, so the site keeps the kernel call rather than freezing a
disagreeing `head_kind` into the heap layout.

**2.6 Consult-site rewrites** — two lines each, no new branches, both fall through to the
existing `Nothing` arms:

```elm
-- Expr.elm:4199 (saturated MonoVarKernel path)
-                    case Intrinsics.kernelIntrinsic home name argTypes resultType of
+                    case Intrinsics.kernelIntrinsic home name argTypes resultType
+                            |> Maybe.andThen (consIntrinsicFor ctx1 argsWithTypes) of
                         Just intrinsic ->
                             let
                                 ( unboxOps, unboxedArgVars, ctx1b ) =
-                                    Intrinsics.unboxArgsForIntrinsic ctx1 argsWithTypes intrinsic
+                                    coerceIntrinsicArgs ctx1 argsWithTypes intrinsic
```
The same two edits at **Expr.elm:3725/3731**. That is the **core-global** path, not a
separate kernel path: `generateSaturatedCallNoFusion`'s `Mono.MonoVarGlobal _ specId funcType`
arm (:3491) binds `argOps/argsWithTypes/ctx1` at :3494-3495 and `argTypes` at :3497-3499,
`maybeCoreInfo` (:3502-3517) recovers `( moduleName, name )` for a callee whose registry spec
key is a `Mono.Global` in `Pkg.core`, and :3725 consults
`kernelIntrinsic moduleName name argTypes resultType`. `List.cons` reaches it whenever the
elm/core binding `cons = Elm.Kernel.List.cons` (elm/core `List.elm:106-108`) survives as a
compiled global instead of being collapsed to a `MonoVarKernel`. Same names are in scope, so
the patch is textually identical.

`Expr.elm:775` (`generateVarKernel`, the *unapplied* `List.cons` value) calls
`kernelIntrinsic home name [] monoType`; `listIntrinsic` returns `Nothing` for `[]`, so the
`Nothing` arm (:844) runs and `instanceClosureResult` (:876) keeps minting the kernel closure
— by design. (Even if it *had* matched, the `Just _` arm at :788 funnels function-typed
kernels into the same `instanceClosureResult` :826, so this path cannot mis-lower.)

**2.7 Flag registration — all five points, in dependency order.** `ListConfig` is a record
alias, so every literal that builds one must be updated or the module will not compile.

```elm
-- (1) Compiler/Eco/Config.elm:61-64 — the field (and extend the doc comment at :51-59)
type alias ListConfig =
    { chunks : Bool
    , consIntrinsic : Bool  -- kernel-opt-01: lower saturated `x :: xs` to
                            -- eco.construct.list instead of Elm_Kernel_List_cons*.
                            -- DEFAULT FALSE until the §Gates battery is green;
                            -- env ECO_LIST_CONS_INTRINSIC=1|0; hash token "lcons=1".
    , report : Bool
    }

-- (2) Config.elm:324 — the `default` record literal
    , list = { chunks = True, consIntrinsic = False, report = False }

-- (3) Config.elm:367-370 — listDecoder. NOTE the existing body is a LAMBDA that
--     hardcodes the env-only `report`; add a parameter, do not use `D.pure ListConfig`.
listDecoder : D.Decoder x ListConfig
listDecoder =
    D.pure (\chunks consIntrinsic -> { chunks = chunks, consIntrinsic = consIntrinsic, report = default.list.report })
        |> D.apply (D.optionalField "chunks" D.bool default.list.chunks)
        |> D.apply (D.optionalField "consIntrinsic" D.bool default.list.consIntrinsic)

-- (4) Config.elm — new `hash` block immediately after the lchunks block (:677-686)
            ++ (if cfg.list.consIntrinsic then
                    [ "lcons=1" ]

                else
                    []
               )
```

```elm
-- (5) Builder/Eco/Config.elm — new override fn after applyListChunksOverride (:511),
--     a verbatim copy of :490-511 with the field swapped:
applyListConsIntrinsicOverride : Maybe String -> EcoConfig -> EcoConfig
applyListConsIntrinsicOverride maybeVal cfg =
    case maybeVal of
        Nothing ->
            cfg

        Just raw ->
            let
                t = String.toLower (String.trim raw)

                listCfg = cfg.list
            in
            if t == "1" || t == "true" || t == "yes" || t == "on" then
                { cfg | list = { listCfg | consIntrinsic = True } }

            else if t == "0" || t == "off" then
                { cfg | list = { listCfg | consIntrinsic = False } }

            else
                cfg

-- …and the chain link, inserted after the ECO_LIST_REPORT link (:225-229):
        |> Task.andThen
            (\cfgLc ->
                (Utils.envLookupEnv "ECO_LIST_CONS_INTRINSIC" |> Task.mapError never)
                    |> Task.map (\lciVal -> applyListConsIntrinsicOverride lciVal cfgLc)
            )
```

`Ctx.Context` already carries `ecoConfig : Config.EcoConfig` (Context.elm:236) so
`ctx.ecoConfig.list.consIntrinsic` needs no plumbing — same access shape as
`ctx.ecoConfig.aggPromote` (Expr.elm:5148, :7218).

**Acceptance (Phase 2):** `cmake --build build --target eco-compiler-mlir` succeeds (no
`cmake --preset build` needed — no `.elm` file is added under `compiler/src`, and
`ELM_SOURCES` is a configure-time `GLOB_RECURSE` over `src/` + `src-xhr/` only,
compiler/CMakeLists.txt:126-129); with the flag OFF the Stage-5 `eco-compiler.mlir` is
**byte-identical** to the Phase-0 baseline (`cmp`); with the flag ON,
`grep -c '= eco.construct.list '` rises and the direct `@Elm_Kernel_List_cons*` counts fall by
a matching amount (Phase 4 quantifies).

### Phase 3 — tests

**3.1 `test/elm/src/ListConsIntrinsicTest.elm`** (NEW). Conventions from
`AggPromoteTupleTest.elm` (behaviour pinned in BOTH flavours) and `HofFoldlLoopifyTest.elm`
(`-- CHECK-MLIR`). **Registration: none** — `discoverTests` (ElmE2ETestBase.hpp:1089-1105)
`directory_iterator`s `test/elm/src` and takes every `.elm` with a top-level `main`
(`hasTopLevelMain`), so the file is picked up by existing filename. Harness mechanics:
directives extracted by `extractCheckPatterns`/`extractCheckMlirPatterns`
(ElmE2ETestBase.hpp:355-372); the fixture's `.mlir` (bytecode unless `ECO_TEXT_MLIR=1`,
TestSuite.hpp:23-26) is re-rendered via `readMlirAsText` (:409-419) which shells `ecoc
--emit=mlir` through `executeCommand` (:261-274) — the latter appends `2>&1`, which is what
captures ecoc's stderr-only text output. `-- CHECK:` lines match the program's stdout, and
the fixture convention is `Debug.log "label" value` (prints `label: value`) with `main`
ending in `text "done"` — copy `AggPromoteTupleTest.elm`'s shape verbatim. Content:

```elm
module ListConsIntrinsicTest exposing (main)

{-| kernel-opt-01: `x :: xs` lowers to `eco.construct.list` under
`ECO_LIST_CONS_INTRINSIC=1` (flag-off it is `Elm_Kernel_List_cons*`). Behaviour is
identical in both flavours — this test pins the behaviour and, when run flag-on,
the encoding.
-}

-- CHECK: boxed: ["a","b","c"]
-- CHECK: ints: 6
-- CHECK: floats: 6.5
-- CHECK: chars: "abc"
-- CHECK: viaFoldl: 55
-- CHECK: devirt: 15
-- CHECK-MLIR: eco.construct.list
-- CHECK-MLIR: head_kind = 1 : i64
-- CHECK-MLIR: head_kind = 3 : i64
```
Bodies: (a) boxed heads (`String`), (b) `Int` heads (`head_kind = 1`), (c) `Float` heads
(`head_kind = 2`), (d) `Char` heads (`head_kind = 3`), (e) a `List.foldl (\x acc -> x :: acc)`
accumulator loop (the EcoListTemplate shape), (f) a cons passed as a function value to a HOF
(`List.foldr cons`) so the LSS devirt path (Translate.elm:1782-1830) is exercised. The
`head_kind = N : i64` spelling is the verified MLIR print form — e.g.
`%4 = eco.construct.list %3, %2 {head_kind = 3 : i64, head_unboxed = true} : i16, !eco.value
-> !eco.value` in today's self-compile dump. **Note `head_kind = 2` (Float) is NOT asserted:**
no `Elm_Kernel_List_cons_Float` instance exists anywhere in the self-compile module today, so
add that directive only after confirming body (c) actually produces it (same discovery
command as §3.2).

**3.2 `test/elm/src/ListConsIntrinsicBailTest.elm`** (NEW, **discovery-gated**). The
*authoritative* decline coverage is the unit test in §3.3; this fixture only proves the
decline survives end-to-end, and it is worth landing **only if a decline shape is reachable
from Elm source**. Do not guess — run the discovery loop:

```bash
# Compile ONE candidate fixture exactly the way the harness does (compileElmToMlir,
# ElmE2ETestBase.hpp:451-497 → `node compiler/bin/index.js make <elm> --output=<mlir>`),
# so no test target and no stale-.mlir hazard is involved.
cd /work/test/elm
rm -f eco-stuff/mlir/ListConsIntrinsicBailTest.mlir
ECO_LIST_CONS_INTRINSIC=1 node /work/compiler/bin/index.js make \
    src/ListConsIntrinsicBailTest.elm \
    --output=eco-stuff/mlir/ListConsIntrinsicBailTest.mlir --text-mlir
grep -c '@Elm_Kernel_List_cons' eco-stuff/mlir/ListConsIntrinsicBailTest.mlir
```

Candidates in preference order, each with why it might decline:
1. an unsettled-`number` head reaching a shared polymorphic combinator (the
   `containsCNumber` shape Translate.elm:1929-1939 documents as *observed live*) — `consHeadAbi`
   returns `Nothing` for `MVar _ CNumber`;
2. `(::)` as a **non-singleton** lambda-set member (e.g. `if flag then (::) else myCons`), so
   `devirtDirectTarget` yields no `DevirtKernel`, the site stays an indirect call and the
   closure value goes through `generateVarKernel` → `instanceClosureResult` (Expr.elm:876),
   which emits `function = @Elm_Kernel_List_cons`.

**Criterion:** if the grep returns ≥ 1, land the fixture with
`-- CHECK-MLIR: @Elm_Kernel_List_cons` and document the shape in the docstring. If it returns
0 for **both** candidates, **do not land a fixture** — record in this plan that no decline
shape is reachable from Elm source in the E2E corpus (which is itself a useful fact: it means
conversion is total for source-level cons) and rely on §3.3. Measured context that makes
candidate 2 uncertain: LSS is default-ON (`defaultLss.enabled = True`, `devirtFnGlobals =
True`, Config.elm:169-178) and `function = @Elm_Kernel_List_cons` occurs **0 times** in the
whole self-compile module today.

**3.3 `compiler/tests/Compiler/Generate/MLIR/IntrinsicsListConsTest.elm`** (NEW) — the
authoritative classifier gate. Mirrors `KernelAbiTest.elm`: module header
`module Compiler.Generate.MLIR.IntrinsicsListConsTest exposing (suite)` (the module name must
match the path under `compiler/tests/`, exactly as
`Compiler.Generate.MLIR.KernelAbiTest` does), `suite : Test` built with
`Test exposing (Test, describe, test)`, hand-built inputs, `Expect.equal` on the returned value.

**Call the EXPOSED entry point, not the new helper.** Intrinsics.elm's `exposing` list
(:1) is `Intrinsic(..), CompareKind(..), kernelIntrinsic, intrinsicResultMlirType,
unboxArgsForIntrinsic, unboxToType, generateIntrinsicOp` — `listIntrinsic` is **internal**.
Drive the table through `Intrinsics.kernelIntrinsic "List" "cons" argTypes resultType`
(which reaches the new arm) and compare against `Just (Intrinsics.ConstructList { headMlirType
= … })` / `Nothing`; `Intrinsic(..)` is already exposed so the ctor is constructible. Do **not**
widen the `exposing` list just for the test.

Imports and value construction (verified): `import Compiler.AST.Monomorphized as Mono`,
`import Compiler.AST.TypeIds as TypeIds` (`MVarId = Id MVarPh`, with `TypeIds.firstMVarId`
as a ready-made value, TypeIds.elm:20-27), `import Compiler.Generate.MLIR.Types as Types`.
`MList` takes a layout id: `Mono.MList 0 Mono.MInt` (Monomorphized.elm:234).

Table:

| head | tail | result | expected |
|---|---|---|---|
| `MInt` | `MList 0 MInt` | `MList 0 MInt` | `Just (ConstructList { headMlirType = Types.ecoInt })` |
| `MFloat` | `MList 0 MFloat` | `MList 0 MFloat` | `… Types.ecoFloat` |
| `MChar` | `MList 0 MChar` | `MList 0 MChar` | `… Types.ecoChar` |
| `MString` | `MList 0 MString` | `MList 0 MString` | `… Types.ecoValue` |
| `MVar firstMVarId CEcoValue` | `MList 0 (MVar … CEcoValue)` | same | `… Types.ecoValue` |
| `MVar firstMVarId CNumber` | `MList 0 MInt` | `MList 0 MInt` | `Nothing` (unsettled numeric axis) |
| `MInt` | `MInt` | `MList 0 MInt` | `Nothing` (scalar tail) |
| `MInt` | `MList 0 MInt` | `MInt` | `Nothing` (scalar result) |
| `[MInt]` (arity 1) | – | `MList 0 MInt` | `Nothing` |
| `[]` (arity 0, the `generateVarKernel` shape) | – | any | `Nothing` |

Run with `cmake --build build --target elm-tests`. **No `cmake --preset build` is required for
a new file under `compiler/tests/`**: that directory is symlinked into the build-xhr shadow
root (`eco_create_dir_link`, compiler/CMakeLists.txt:119 + cmake/EcoCreateDirLink.cmake) and
elm-test-rs discovers modules at run time. (`ELM_SOURCES`'s configure-time `GLOB_RECURSE`
covers only `compiler/src/` and `compiler/src-xhr/`, :126-129 — it would matter only if this
plan added a file *there*, which it does not.)

**Acceptance:** §3.1 green flag-off (extern form) and flag-on (op form); §3.3 green
(`elm-tests`); §3.2 either green or explicitly recorded as not-landed with the discovery
output pasted into this plan.

### Phase 4 — attribution

Re-run every Phase-0 measurement on the flag-ON tree and reconcile:

1. **`Δ(= eco.construct.list) == −Δ(direct cons calls)`**, using Phase 0.1's two commands
   verbatim (the `= ` anchor and the `callee = @Sym` split — a bare `eco.construct.list` grep
   is off by one on the self-compile module). **Concrete target from the measured baseline:**
   13,446 → ≈17,747 construct.list and 4,301 → ≈0 direct cons, plus up to 3 `func.func private`
   stubs disappearing when a symbol's last call site converts. Any shortfall is the decline
   residue — enumerate it before believing any wall number. Expected residue sources, in order:
   LSS-declined sites (indirect calls — invisible to both counts, and the dominant term),
   `CNumber` heads, scalar tail/result, unapplied `cons` values (Expr.elm:775 path — measured
   `pap = 0` today, so expected to contribute nothing).
2. **EcoListTemplate: `rewritten` and `unwind rewritten` must be >= baseline** (Phase 0.2)
   and `walkChain{consRoots}` must stay **0**. This is the hard gate; nothing else detects
   the regression.
3. **`ECO_CONS_SITES=1` continuity note:** converted sites no longer pass through
   `alloc::cons`/`eco_alloc_cons`, so the `[cons-sites] total` DROPS by roughly the converted
   dynamic volume — record the flag state next to every future cons census so later readers
   do not misread it as an allocation reduction. Same caveat for GC-stats `Objects allocated`
   (census §18.3: the HEAP_034 inline path bypasses the per-tag counter, so converted conses
   vanish from that counter too — an ECO_INLINE_ALLOC=0 leg is required for a true count).

**Acceptance:** a table in `benchmarks/kernel-opt.md` with baseline vs converted for
(construct.list, cons calls by symbol, template rewritten/unwind/consRoots, cons-sites total).

### Phase 5 — measure

`benchmarks/kernel-opt.md` protocol, **with one deliberate deviation stated in the entry**:
the two knobs are independent, so measure the *binary*, not the workload —

- `BK=build/compiler/build-kernel` (as in the methodology's command block).
- **Build arm A (baseline):** `ECO_MONO_ENGINE=solver ECO_MONO_LSS=1 ECO_BORROW=1 ECO_AGG_PROMOTE=1
  cmake --build build --target eco-compiler`, then `cp -p "$BK/bin/eco-compiler" "$BK/bin/eco-cons-off"`.
- **Build arm B (converted):** identical plus `ECO_LIST_CONS_INTRINSIC=1`, then
  `cp -p "$BK/bin/eco-compiler" "$BK/bin/eco-cons-on"`. (Ninja is env-blind:
  `rm -f "$BK/bin/eco-compiler.mlir" "$BK/bin/eco-compiler"` and `rm -rf "$BK/eco-stuff"`
  before **each** build, or arm B silently reuses arm A's Stage-5 output.)
- **Workload:** `ECO_MONO_ENGINE=subst` and **`ECO_LIST_CONS_INTRINSIC` unset**, so both arms
  emit byte-identical `-out.mlir` (`cmp` them — the standard workload-constancy check still
  applies here, which it would NOT if the flag were also set at the make step).
- 2 rounds × 2 arms, arms reversed in round 2, `rm -rf "$BK/eco-stuff"` before each run.
  Record wall, Max RSS, Objects/Bytes allocated, Minor/Major GC cycles, Objects promoted,
  output size. **Never quote a wall without its majors.**

**Acceptance:** entry appended to `benchmarks/kernel-opt.md` + summary-table row. Per that
file's own rule: ≳3% is signal, below is FLAT — write "no regression detected", not "a −1% gain".

### Phase 6 — default-on decision (separate commit)

Flip `default.list.consIntrinsic = True` **only** if Phases 4-5 show (a) op-count
reconciliation with an enumerated residue, (b) template counters >= baseline, (c) all §Gates
green, (d) no wall regression. Record the measured numbers in the Config.elm field comment
(the `aggPromote` convention, Config.elm:42-47) and add an `HEAP_*`/`CGEN_*` row only if the
reviewer asks — this change introduces no new invariant, it moves sites onto HEAP_034 and
REP_BOUNDARY_002, both already enforced.

## Traps & risks

- **EcoListTemplate silent disable (THE named trap, now de-fanged but not gone):** the
  Tier-B rewrite absorbs a `construct.list` link only when hint-free
  (EcoListTemplate.cpp:148-150, :659-661). Hints are empty today (Phase 1), so hint-free
  emission is free — but the trap resurrects the moment `Ctx.liveEcoValueVars` is restored
  (Context.elm:627-642 keeps the body ready to uncomment). **Gate: `rewritten` +
  `unwind rewritten` >= baseline and `consRoots == 0`.** No test catches this.
- **Head-kind vs heap layout:** `head_kind` must come from the SSA operand type
  (REP_BOUNDARY_002, invariants.csv:24) and must agree with what the projection side expects.
  The classifier's `consHeadAbi` axis is deliberately identical to
  `kernelInstanceSymbol`'s (KernelAbi.elm:310-317); the `CNumber` decline exists because that
  case maps to `i64` under `monoTypeToAbi` (Types.elm:170-172) yet calls the **boxed** root
  symbol today (`MVar _ CNumber` matches none of the `( "List", "cons", [ MInt|MFloat|MChar, _ ] )`
  arms, so `kernelInstanceSymbol` falls through to `rootSymbol` :406-407) — freezing it as
  `head_kind = 1` would be a silent layout change. Note `ensurePrimitiveAbi` does **not** catch
  this pairing: its `_ ->` arm (KernelAbi.elm:455-459) explicitly permits a non-primitive Mono
  type against a primitive MLIR type, despite what its own docstring (:410-414) says. Declining
  is the only guard.
- **Boxing direction:** `unboxArgsForIntrinsic` cannot box; a primitive or U-T1.3.1 aggregate
  SSA head feeding a boxed slot needs `boxToEcoValue` (`eco.box` / `eco.to_heap`).
  Phase 2.5 handles it; skipping it produces an MLIR type mismatch at the op, not a silent bug.
- **`[Pure]` + a future MLIR CSE (kernel-opt-10):** conversion makes cons cells CSE-able where
  the opaque calls were not. Sharing a cons cell is unobservable in Elm, **but** EcoListTemplate
  requires `def->getResult(0).hasOneUse()` (:155-158, :666-669), so a CSE'd cons would bail the
  chunk rewrite. There is no CSE/canonicalizer between the front end and EcoListTemplate today
  (EcoPipeline.cpp:88-96 documents the removal) — flag this to kernel-opt-10 before it adds one.
- **Census continuity:** see Phase 4.3 — both `ECO_CONS_SITES` and GC-stats `Objects allocated`
  under-report converted conses.
- **Harness cache is env-blind:** `needsRecompile` compares `.elm` vs `.mlir` mtimes
  (ElmE2ETestBase.hpp:432-439), so a flag flip does not invalidate `test/elm/eco-stuff/mlir`.
  **`rm -rf /work/test/elm/eco-stuff/mlir` before every flag-flipped E2E run.**
- **Stale `.mlir`:** always `--target full`, never `check` — this changes codegen (CLAUDE.md).
- **GC-trigger lottery:** record major-GC counts with every wall number.
- **Honest expectation:** statepoint/metadata-only removal has been wall-FLAT four consecutive
  times. This change is not in that family (it deletes a call, a roots array, an encode/decode
  round trip and a group barrier per cell), but *no number is promised* — measure.

## Dependencies

- **None of the 14 siblings block this** — item 01 is in the unblocked independent set
  {01, 02, 04, 05, 06}.
- Interacts with: **kernel-opt-08** (`eco.gc_leaf` decl stamp) and **kernel-opt-09**
  (EcoGCPrepare barrier relaxation via the call-local `eco.callee_gc_leaf` attr) — each
  converted site is one fewer extern for them to stamp and one fewer barrier to relax;
  **kernel-opt-10** (MLIR CSE/folders) — see the `[Pure]` trap above; **kernel-opt-07**
  (KernelFacts) — `List.cons` keeps its row **unchanged**: `{ auditedPure | gcAlloc =
  GcFixed 1 }`, i.e. `cppAlloc = False`, `cseSafe = True`, `totality = Total`
  (kernel-opt-07:675-680). `GcFixed n` is an **object budget** ("≤ N objects per call",
  07:215, validator `n > 0` at 07:411-413) — **not** a byte count; the cons cell's 24 B lives
  in `getFixedAllocSizeForGrouping` (EcoGCPrepare.cpp:85), which is a different axis. The row
  survives because the closure/PAP path (Expr.elm:775) still calls the extern.
- External preconditions (both shipped): HEAP_034 inline nursery allocation default-on, and
  the Aug 9 contiguous-nursery HEAP_042/043 work — the bump fast path this rides on.

## Expected impact

This is the deleted-per-op-work family that HAS moved wall (inline-nursery HEAP_034 −9.6%;
$cap-inlining −14.5%; Run M/C2 −1.74% from de-statepointing alone on identical allocation)
applied to ~193M dynamic calls, each replaced by an inline bump plus a now-groupable
allocation — unlike the four consecutive metadata-only FLAT results (preserve-cc, gc-leaf
pilot, capacity-check hoisting, the compare phases). **No number promised; measure.**
Secondary wins that accrue even if wall disappoints: ~4,300 fewer opaque extern **call sites**
(the three symbols themselves stay) shrink CGEN_072 gc-freeness poison and delete the borrow
census's largest poison line (`List.cons=4151`, borrow-inf-census.md:864);
statepoint/stackmap metadata shrink (expect a binary-size delta à la capacity-hoisting's
−5.32 MB, which is **not** a wall claim). Effort M — the intrinsic is ~120 lines; the trap
analysis, attribution and gating are the work.

## Gates

1. **Full E2E:** `cmake --build build --target full 2>&1 | tee /tmp/test_output.txt`, then
   `grep -E "FAILED|PASSED|[0-9]+/[0-9]+" /tmp/test_output.txt | tail -20`. Run ONCE per
   flavour; grep the file, never re-run. Both flavours must be green:
   flag-off, and flag-on via
   `rm -rf /work/test/elm/eco-stuff/mlir && ECO_LIST_CONS_INTRINSIC=1 cmake --build build --target full 2>&1 | tee /tmp/test_output_on.txt`.
   Iterate with `TEST_FILTER=elm` / `TEST_FILTER=codegen`.
2. **Heap-validate leg** (the only detector for a root/liveness bug):
   `cmake --preset build -B /work/build-val -DECO_HEAP_VALIDATE=ON` then
   `ECO_LIST_CONS_INTRINSIC=1 cmake --build /work/build-val --target full 2>&1 | tee /tmp/test_val.txt`;
   suite count must match the main tree's.
3. **Flag-off byte-identity:** requires the Phase-0 snapshot, so **take it before editing**
   (add to Phase 0.1): `cp -p build/compiler/build-kernel/bin/eco-compiler.mlir
   /tmp/base-eco-compiler.mlir`. Then, with the patch applied and the flag unset,
   `rm -f build/compiler/build-kernel/bin/eco-compiler.mlir` (ninja is env-blind — see Phase 5),
   `cmake --build build --target eco-compiler-mlir`, and
   `cmp build/compiler/build-kernel/bin/eco-compiler.mlir /tmp/base-eco-compiler.mlir` — must be
   identical.
4. **Bootstrap to a NEW fixed point (flag-on):** `ECO_LIST_CONS_INTRINSIC=1 cmake --build build
   --target bootstrap 2>&1 | tee /tmp/bootstrap.txt`. On Linux, Stage 8c compares
   `eco-compiler-boot` ≡ `eco-compiler-boot-2` byte-for-byte on the linked **ELF**
   (compiler/CMakeLists.txt:547-586; on Darwin/Windows the same target compares the two `.mlir`
   files instead — :568-577). The FIRST build's Stage-5/7a output legitimately differs from the
   flag-off tree (that is the point); the fixed point itself must hold. The `bootstrap` target
   (:1026-1032) already pulls in the Stage-4b JS fixed point (`ECO_BOOT_VERIFY_STAMP`) and the
   Stage-9b unified-`eco` self-compile (`eco-2`, :963-994) — no separate `eco-verify` run is
   needed, and note Stage 9b has **no** `eco == eco-2` equality check by design (:969-975):
   completing the self-compile IS the criterion.
5. **EcoListTemplate scratch counters >= baseline** (Phase 0.2 vs Phase 4.2) with
   `consRoots == 0` — **hard gate**.
6. **Op-count reconciliation:** `Δ(= eco.construct.list) == −Δ(callee = @Elm_Kernel_List_cons*)`
   up to the enumerated decline residue, using Phase 0.1's commands verbatim (Phase 4.1).
7. **Wall/RSS A/B with major-GC counts recorded**, 2 rounds per arm, arms reversed in round 2,
   `-out.mlir` byte-identical between arms (Phase 5).
