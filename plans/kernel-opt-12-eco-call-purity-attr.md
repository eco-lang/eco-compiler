# Kernel-Opt 12: eco.call purity channel (attr + MemoryEffectOpInterface)

**Status: IMPLEMENTATION-READY v3 — 2026-08-10.** (v1 outline → v2 deepening → v3
adversarial verification pass: every load-bearing anchor re-checked against the tree, four
claims discharged by *running* the built `ecoc`, the KernelFacts duplication removed in
favour of kernel-opt-07's pinned `lookupSymbol`, and the Phase-4 fixtures rewritten after
reading the actual test harness — the v2 fixtures would have been silently vacuous.)
Derived from design_docs/kernel-boundary-reduction.md
section 9 H6 (:2181-2190), the 6.C2 single-source policy, and the Stage-7a censuses
(dynamic: `design_docs/kernel-boundary/kernel-census-dynamic-stage7a.txt`, header line
`total=3676097627 distinct=98`; static: `design_docs/kernel-boundary/callsite-census-self-compile.txt`,
133 lines / 17,005 sites — `awk '{s+=$1} END {print s}'`, re-counted 2026-08-10; the
"130 symbols" figure quoted in kernel-opt-07 and in the design doc is stale by three).

## Goal

Give `eco.call` a purity channel: ONE optional attr `eco.cse_safe`, mirrored at emission
from the kernel-opt-07 KernelFacts table, plus a `MemoryEffectOpInterface` implementation
on `Eco_CallOp` that turns that attr into MLIR effects. Every purity-aware MLIR consumer —
kernel-opt-10's CSE, any future folder/motion pass — reads one place instead of growing a
private kernel name list.

## Files touched

| File | Change |
|---|---|
| `compiler/src/Compiler/GlobalOpt/KernelFacts.elm` | **UNCHANGED.** This plan consumes kernel-opt-07's pinned `lookupSymbol` + `droppable` and adds no export (07 cross-plan contract pt 3; KERNEL_FACTS_001: "a consumer holding only the emitted C symbol MUST go through KernelFacts.lookupSymbol"). No new `.elm` file ⇒ no `cmake --preset build` reconfigure needed for this item |
| `compiler/src/Compiler/Eco/Config.elm` | new `callPurityAttrs : Bool` field (after `sretTailFuncs`, :47), `default` (after :338), `decoder` (after :361), `hash` token `cpur=1` (append after the `bopt=1` block, :738-743) |
| `compiler/src/Builder/Eco/Config.elm` | `ECO_CALL_PURITY` env override: chain link (after the `ECO_BORROW_OPT` link, :260-264) + `applyCallPurityOverride` (verbatim copy of `applyCtorInlineOverride`, :298-316) |
| `compiler/src/Compiler/Generate/MLIR/Ops.elm` | `ecoCallNamed` (:657-707) and `ecoCallNamedMulti` (:747-784): stamp `eco.cse_safe` when flag ∧ `KernelFacts.lookupSymbol`→`droppable`; new `import Compiler.GlobalOpt.KernelFacts as KernelFacts` (import block :73-85) |
| `runtime/src/codegen/Ops.td` | `Eco_CallOp` (:1129-1132): add `DeclareOpInterfaceMethods<MemoryEffectsOpInterface>`; normative attr semantics into the description (:1134-1156) |
| `runtime/src/codegen/EcoOps.h` | `kCseSafeAttrName` string constant in `namespace eco` (after :30, before `#endif` at :32) |
| `runtime/src/codegen/EcoOps.cpp` | new `CallOp::getEffects` (~:911, immediately before the "GCRootCarrier Interface Implementations" banner at :911-913); verifier arm in `CallOp::verify` (:862-909, inserted at :870) |
| `runtime/src/codegen/Passes/EcoGCPrepare.cpp` | strip `eco.cse_safe` at the head of the Step-4 loop (`for (auto &op : block)` :328, `if (!isCallSafepoint(&op)) continue;` :329) |
| `runtime/src/codegen/Passes/EcoGCLivenessAudit.cpp` | debug-only assert: no `eco.cse_safe` survives EcoGCPrepare (existing carrier walk :51-132; `emitError` + `hadError = true` idiom :129-131; `if (hadError) signalPassFailure();` :134) |
| `test/codegen/call_purity_attr_roundtrip.mlir` | NEW fixture F1 (auto-discovered, no CMake edit) |
| `test/codegen/call_purity_attr_conservative.mlir` | NEW fixture F2 (Trap-D negative, `-emit=mlir-llvm`) |
| `test/codegen/call_purity_attr_survives_eco.mlir` | NEW fixture F3a (attr alive after `buildEcoToEcoPipeline`) |
| `test/codegen/call_purity_attr_stripped.mlir` | NEW fixture F3b (strip proven via the verifier arm at `-emit=mlir-llvm`) |
| `test/codegen/call_purity_attr_indirect.mlir` | NEW fixture F4 (verifier negative, `not %ecoc`) |
| `test/codegen/call_purity_cse_merge.mlir` | NEW fixture F5, **DEFERRED** — lands with kernel-opt-10's `createCSEPass()` and only runs with that item's `ECO_MLIR_CSE` gate on |

No new runtime C symbol is introduced, so the `elm_array_push_int`-style registration
triad (`.cpp` definition + `KernelExports.h` decl + `RuntimeSymbols.cpp` `KERNEL_SYM`
entry) does **not** apply to this plan. The registration checklists that DO apply are
listed per phase below.

## Flag & rollback

- **Flag:** `callPurityAttrs : Bool` in `EcoConfig`, **default `False`**; env
  `ECO_CALL_PURITY=1|true|yes|on` enables, `0|off` disables. Artifact-affecting →
  hash token `cpur=1` appears only when enabled, so default-off builds hash exactly as
  today and share all pre-feature caches (same posture as `aggp`/`ctori`,
  Compiler/Eco/Config.elm:687-707, and as the most recent token `bopt=1`, :732-743).
- **Kill switch semantics:** flag off ⇒ the attr is never emitted ⇒ `CallOp::getEffects`
  always takes the conservative branch. The C++ side (interface + strip + assert) is inert
  without the attr, so it can stay landed while the flag is off. **Caveat, stated honestly:
  "flag-off is bit-identical" is exactly the conservative-equivalence claim of 3.3 — it is
  an argument from the header contract plus fixture F2, not a theorem.** The flag-off
  `--target full` + flag-off bootstrap byte-identity gates ARE the proof; if either moves,
  the read+write report is not equivalent to "no interface" for some consumer in this
  pipeline and 3.3's four-effect fallback applies.
- **Revert story:** three independent revert points, in increasing size —
  (1) set `ECO_CALL_PURITY=0` (no rebuild of the C++ needed, front-end cache key changes);
  (2) revert the Ops.elm hunk (attr never emitted, everything else stays);
  (3) revert the `DeclareOpInterfaceMethods<MemoryEffectsOpInterface>` line in Ops.td +
  `CallOp::getEffects` (returns `eco.call` to "no effect interface = unknown effects").
  The EcoGCPrepare strip and the audit assert are safe to leave in place under any revert.

## Evidence

- **`Eco_CallOp` carries no purity information today.** Its trait list is exactly
  `[DeclareOpInterfaceMethods<SymbolUserOpInterface>,
  DeclareOpInterfaceMethods<Eco_GCRootCarrierOpInterface>]` (Ops.td:1129-1132, re-verified
  2026-08-10). Declared arguments are `operands`, `callee`, `musttail`, `remaining_arity`
  (Ops.td:1158-1163); `hasVerifier = 1` (:1166).
- **Discardable dialect attrs on `eco.call` are established practice.**
  `eco.gc_roots_count` is set/read via `Operation::setAttr` / `getAttrOfType`
  (EcoOps.cpp:22-25 helper; written in `CallOp::setGCRoots`, :1003-1004) and is **not**
  declared in `let arguments`. So `eco.cse_safe` needs no ODS argument entry, no builder
  change, and no parser work; it round-trips text and bytecode for free.
- **The attr round-trip and the exact printed form are EMPIRICALLY VERIFIED against the
  built `ecoc` (2026-08-10), not assumed.** Feeding

  ```mlir
  %n = "eco.call"(%v) {callee = @Elm_Kernel_String_length, eco.cse_safe} : (!eco.value) -> !eco.value
  ```

  to `build/runtime/src/codegen/ecoc <file> -emit=mlir` prints

  ```mlir
  %1 = "eco.call"(%0) <{callee = @Elm_Kernel_String_length}> {eco.cse_safe} : (!eco.value) -> !eco.value
  ```

  Three load-bearing consequences: (a) an undeclared discardable attr parses and prints
  today, before any Ops.td change; (b) **inherent** attrs (`callee`, `musttail`,
  `remaining_arity`) print in the properties dict `<{…}>` while discardables print in the
  trailing `{…}` dict, so on a printed line `callee` always comes BEFORE `eco.cse_safe` —
  every `CHECK-SAME` chain in Phase 4 must be written in that order; (c) a
  declaration-only `func.func private @f(%s: !eco.value) -> !eco.value` parses fine and
  re-prints types-only, so the fixtures may use the named-argument spelling.
- **The conservative baseline is EMPIRICALLY VERIFIED too.** An `eco.call` with an unused
  result survives the whole pipeline in the CURRENT tree: a module whose `main` does
  `%unused = "eco.call"(%v) {callee = @sideEffecting} : (!eco.value) -> !eco.value` and
  never uses `%unused` still shows `llvm.call @sideEffecting(%3)` at `-emit=mlir-llvm`.
  That is the exact behaviour fixture F2 must preserve after the interface is declared,
  and it confirms the "no effect interface ⇒ `isMemoryEffectFree` false ⇒ not trivially
  dead" reading of the header contract below.
- **THE HINT QUESTION IS ANSWERED — `eco.call` carries NO safepoint-hint operands today.**
  `Ctx.liveEcoValueVars` is a stub returning `[]` (Context.elm:647-649; the doc comment at
  :619-646 preserves the conservative Phase-1 body as commented code at :627-642), and
  `emitSafepointHints ctx = Ctx.liveEcoValueVars ctx` (Expr.elm:113-115). Every
  `Ops.ecoCallNamed … (emitSafepointHints ctx) …` site therefore passes an empty hint
  list, `gcRootsCountAttr` is `Dict.empty` (Ops.elm:690-695), and two structurally
  identical calls are textually identical. **Consequence: CSE of pure calls is NOT gutted
  by hint divergence — the value of this channel survives.** Contingency if the Phase-1
  hint set is ever restored: see Phase 1, step 1.4.
- **`eco.call` operands are mutated in place after EcoGCPrepare.** `CallOp::setGCRoots`
  rebuilds the operand vector, appends roots, and resets `eco.gc_roots_count`
  (EcoOps.cpp:995-1005, re-verified). Any merge/motion after that point corrupts root
  bookkeeping — hence the Phase 3 strip.
- **Emission hook points:** `Ops.ecoCallNamed` (Ops.elm:657-707, op built at :703) and
  `Ops.ecoCallNamedMulti` (:747-784, op built at :780). These two functions are the ONLY
  producers of `"eco.call"` in the compiler (`grep -rn '"eco.call"' compiler/src/Compiler/Generate`
  → Ops.elm:703, Ops.elm:780). Exactly 30 `Ops.ecoCallNamed` + 3 `Ops.ecoCallNamedMulti`
  call sites, all in Expr.elm / Functions.elm / Patterns.elm, funnel through them
  (`grep -rn 'Ops.ecoCallNamed\b' compiler/src | wc -l` → 30), so ONE edit per function
  covers all of them. `ctx.ecoConfig : Config.EcoConfig` is already a `Ctx.Context` field
  (Context.elm:236, `import Compiler.Eco.Config as Config` at :63), so the flag is
  readable at both sites with no plumbing.
- **The front-end never emits `musttail` and never emits an indirect `eco.call` through
  these helpers.** `grep -rn musttail compiler/src/Compiler/Generate` → zero hits, and both
  helpers unconditionally set `callee`. The Phase-3.4 verifier arms for musttail/indirect
  are therefore purely defensive against C++-side producers, not reachable from emission.
- **There is no in-tree `getEffects` override to copy.** `grep -rn 'getEffects' runtime/src`
  → zero hits (verified 2026-08-10); every effect declaration in the tree is trait-based —
  the `Pure` token appears 107× in `runtime/src/codegen/Ops.td`, of which 5 are prose
  inside `let description` blocks, so **102 trait uses across the 134 `Eco_Op<…>` defs**;
  `MemoryEffects<[MemWrite]>` at `runtime/src/codegen/BF/BFOps.td:94` and `:146` (and
  `MemoryEffects<[MemRead]>` at :249/:264/:279, `[MemRead, MemWrite]` at :215/:229/:303);
  `RecursiveMemoryEffects` at Ops.td:269/:409. This plan writes the first `getEffects`
  override, so the sketch below is written straight against the upstream declarations
  rather than a neighbour.
- **Upstream contract (read from the installed MLIR headers, /opt/llvm-mlir):**
  - `MemoryEffectsOpInterface` (TableGen name) generates the C++ class
    `MemoryEffectOpInterface` (SideEffectInterfaces.td:26-34).
  - `Pure = TraitList<[AlwaysSpeculatable, NoMemoryEffect]>` (SideEffectInterfaces.td:147)
    — declaring only the effect interface with an empty report gives NoMemoryEffect
    **without** speculatability. `isSpeculatable` needs `ConditionallySpeculatable`
    (SideEffectInterfaces.h:448-452), which this plan deliberately does not implement.
  - `getEffectsRecursively`'s doc is the load-bearing sentence for the conservative
    branch: "*std::nullopt indicates that an option did not have a memory effect interface
    and so no result could be obtained*" (SideEffectInterfaces.h:436-445) — i.e. no
    interface ⇒ unknown ⇒ conservative. `isMemoryEffectFree` requires the interface to
    report no effects (:424-434).
  - Exact method signature to implement (SideEffectInterfaces.h.inc:52):
    `void getEffects(::llvm::SmallVectorImpl<::mlir::SideEffects::EffectInstance<::mlir::MemoryEffects::Effect>> &effects);`
  - `EffectInstance(EffectT *effect, Resource *resource = DefaultResource::get())`
    (SideEffectInterfaces.h:141-143) — the no-value ctor is the "unspecified value on the
    default resource" form the conservative branch needs.
- **An accidental consumer already exists (correction to v1's "no pass consumes them
  yet").** `EcoControlFlowToSCF` runs `applyPatternsGreedily` over the whole module
  (EcoControlFlowToSCF.cpp:1159-1167) at EcoPipeline.cpp:81 — **before** EcoGCPrepare
  (:99). The in-tree comment at :1159 says "with folding disabled to prevent DCE", but
  that is wrong: `applyPatternsGreedily`'s own doc contract is "*Also performs simple
  dead-code elimination before attempting to match any of the provided patterns*"
  (GreedyPatternRewriteDriver.h:164 for the `Region&` overload, :199 for the
  `Operation*` overload — the one used here), and `config.enableFolding(false)` (:1161)
  only turns off *folding*. `GreedyRewriteConfig` exposes no DCE switch at all: its whole
  public surface is scope / top-down / region-simplification / max-iterations /
  max-rewrites / strictness / listener / `enableFolding` / `enableConstantCSE`
  (GreedyPatternRewriteDriver.h:125-138 for the last two, private members :139-150).
  So the moment the interface is declared and the attr is present, unused `eco.cse_safe`
  calls become erasable there. This is *within* the license we are granting, but it means
  Phase 3 is NOT output-neutral — see Gates.
- **Fragmentation risk is concrete:** without this channel, kernel-opt-10 needs its own
  kernel purity list and kernel-opt-13 a third — the exact per-pass drift the facts table
  (design doc 6.C2) exists to end.

## Approach

### Phase 0 — lock the effect contract (design, no code)

**Decision D1 (PINNED): v1 ships exactly ONE attr level, `eco.cse_safe`.** The read-only
level (`eco.readonly`, "no observable writes but may allocate") is **deferred to the
post-RS4GC track**: no v1 consumer needs it, and stock MLIR CSE's only special case for
read-only ops is a limited "no intervening write" merge that buys nothing while there is
no writer taxonomy in the Eco dialect. Reopen only when a consumer demands it.

**Decision D2 (PINNED): the emission predicate is KernelFacts' derived `droppable`
(`cseSafe && totality == Total`), not bare `cseSafe`.** Rationale, and it is the single
most important finding of this deepening: MLIR has **no "mergeable but not erasable"
effect level**. An op whose `getEffects` reports nothing is `isMemoryEffectFree`, hence
`wouldOpBeTriviallyDead` (SideEffectInterfaces.h:417-434), hence erasable-if-unused by
every DCE-capable driver. Merge and drop arrive bundled. Emitting on bare `cseSafe`
would therefore let an unused `Throws`/`MayDiverge` kernel call be deleted, changing
program semantics. The attr NAME stays `eco.cse_safe` per the series contract; Ops.td
states the exact license.

**Decision D3 (PINNED): no speculation, ever, in v1.** Do not add `ConditionallySpeculatable`
or `AlwaysSpeculatable`. `hoistable = cseSafe` in the facts table is an *Elm-level*
derived fact for kernel-opt-13; it is deliberately NOT reflected into MLIR, because
hoisting a GC-triggering call across a branch interacts with EcoGCPrepare's grouping.

**Decision D4 (PINNED): `eco.cse_safe` is a separate channel from `eco.gc_leaf`.**
`eco.gc_leaf` is a **declaration** attr on the `is_kernel` `func.func` stub — the
`attrs` dict at Functions.elm:1994-2007, with `( "is_kernel", BoolAttr True )` at
**:1998** (kernel-opt-07/09 both quote `:1999`; the tree says :1998) — derived from
`gcLeafEligible`, consumed by kernel-opt-08
(LLVM stamp) and kernel-opt-09 (via the module-level marking pass that stamps the
call-local `eco.callee_gc_leaf`). `eco.cse_safe` is a **per-call** attr derived from
`droppable`, consumed only by Elm-level-purity-aware MLIR passes, and it dies at
EcoGCPrepare. The two are orthogonal by construction: `List_cons` is `droppable` yet
allocates (not gc-leaf); `Bytes_getStringWidth` is gc-leaf yet `cppAlloc`.

Write D1-D4 as normative text into `Eco_CallOp`'s `let description` (Ops.td:1134-1156),
appended after the musttail paragraph:

```tablegen
    Purity channel (kernel-opt-12). The discardable unit attribute
    `eco.cse_safe` is stamped at emission for direct calls whose
    Compiler.GlobalOpt.KernelFacts row derives `droppable`
    (cseSafe && totality == Total). It licenses exactly two transforms:

      * MERGE two identical calls that are in the same dominance scope;
      * ERASE a call whose results are unused.

    It does NOT license speculation or motion (eco.call implements no
    ConditionallySpeculatable), and it is INVALID after EcoGCPrepare, which
    appends GC roots to the operand list and strips the attribute. A call
    WITHOUT the attribute reports conservative read+write on the default
    resource — identical in practice to having no effect interface at all.
    Never valid on an indirect call or a musttail call.
```

**Acceptance:** the four decisions and the Ops.td text are reviewed against
kernel-opt-07's derived-facts list and kernel-opt-09's `eco.gc_leaf` /
`eco.callee_gc_leaf` design before any code lands.

### Phase 1 — Elm side: flag, facts lookup, emission (INERT; no C++ change)

**1.1 Config flag.** Registration checklist, verified against how `ctorInline` is wired
(`grep -rn 'ctorInline' compiler/ --include=*.elm` → exactly these 6 points):

1. `compiler/src/Compiler/Eco/Config.elm` — field on the `EcoConfig` alias, after
   `sretTailFuncs` (:47), with the full doc-comment convention:
   ```elm
   , callPurityAttrs : Bool -- kernel-opt-12 (plans/kernel-opt-12-eco-call-purity-attr.md): stamp `eco.cse_safe` on direct eco.call ops whose KernelFacts row derives `droppable` (cseSafe && totality == Total); licenses MLIR merge+DCE of those calls before EcoGCPrepare. DEFAULT-OFF; env ECO_CALL_PURITY=1 enables; artifact-affecting (hash token "cpur")
   ```
2. same file — `default` record: the tier-1 boolean block is `aggPromote` :333 →
   `sretTailFuncs` :338, closing `}` at :339. Append `, callPurityAttrs = False` as a new
   :339.
3. same file — `decoder`: the boolean chain is `aggPromote` :356 → `sretTailFuncs` :361.
   Append as a new :362:
   `|> D.apply (D.optionalField "callPurityAttrs" D.bool default.callPurityAttrs)`.
   **Field order in the record alias, in `default`, and in the `decoder` chain must
   match** — `D.pure EcoConfig |> D.apply …` is positional, so a mis-ordered chain is a
   type error at best and a silently swapped flag at worst.
4. same file — `hash`: the token chain ends with the `bopt=1` block at :738-743 (the
   whole chain is inside a `String.join` list that closes at :744). Append a new block
   after :743, token only when ON:
   ```elm
            ++ (if cfg.callPurityAttrs then
                    [ "cpur=1" ]

                else
                    []
               )
   ```
5. `compiler/src/Builder/Eco/Config.elm` — new link on the `Task.andThen` chain (append
   after the `ECO_BORROW_OPT` link, :260-264) and `applyCallPurityOverride`, a verbatim
   copy of `applyCtorInlineOverride` (:298-316) with the field renamed.
6. No `clamp` entry (:512-533 handles numeric ranges only).

**1.2 Reading the facts table from a mangled symbol — NO new KernelFacts export.**
kernel-opt-07 owns `compiler/src/Compiler/GlobalOpt/KernelFacts.elm` and has already
pinned the symbol-only entry point: `lookupSymbol : String -> Maybe KernelFacts`, which
strips the `Elm_Kernel_`/`Eco_Kernel_` prefix (both are 11 chars, `String.dropLeft 11`),
splits at the first `_` into `(home, name)`, and drops any trailing `_Int`/`_Float`/`_Char`
ABI suffix (07's `splitSymbol` / `dropAbiSuffix`). Its cross-plan contract point 3 and
`KERNEL_FACTS_001` both say a consumer holding only the emitted C symbol **MUST** go
through `lookupSymbol`; contract point 2 says consumers must call the derived helpers
(`droppable`) rather than re-derive from raw fields.

This item therefore adds **nothing** to KernelFacts. The whole symbol view is a three-line
private helper next to the emission site in `Ops.elm`:

```elm
{-| kernel-opt-12: is this callee symbol safe to merge AND to erase?
Whitelist discipline — anything the table does not list (every non-kernel
symbol included) answers False and the emitter stamps nothing, which is
exactly today's behaviour. `lookupSymbol` owns prefix + ABI-suffix
normalisation (kernel-opt-07 cross-plan contract pt 3).
-}
calleeIsDroppable : String -> Bool
calleeIsDroppable funcName =
    KernelFacts.lookupSymbol funcName
        |> Maybe.map KernelFacts.droppable
        |> Maybe.withDefault False
```

Placement: a top-level (unexposed) definition in `Compiler.Generate.MLIR.Ops`, immediately
above `ecoCallNamed` (:655). Do NOT add it to the module's `exposing` list (:1-14) — it is
private to the two emission helpers. The mangled symbols it sees are exactly the ones
`KernelAbi.kernelInstanceSymbol` mints (`<prefix>_Kernel_<home>_<name>` + an optional
`_Int`/`_Float`/`_Char`; KernelAbi.elm:182-250 — verified 2026-08-10 that those three are
the ONLY suffixes) plus the legacy direct spelling `"Elm_Kernel_" ++ moduleName ++ "_" ++ name`
(Expr.elm:3765-3767). Both forms are `lookupSymbol`-shaped.

**1.3 Emission.** In `Ops.ecoCallNamed` (Ops.elm:657-707), add to the `let` block next to
`gcRootsCountAttr` (:690-695) and fold into `attrs` (:697-701). No type annotation on the
new binding — `Ops.elm` imports `Dict` unqualified (`import Dict`, :75), so the type would
have to be spelled `Dict.Dict String MlirAttr`; the neighbouring `gcRootsCountAttr` /
`operandTypesAttr` carry no annotation either:

```elm
        -- kernel-opt-12: purity channel. Stamped ONLY for direct calls whose
        -- KernelFacts row derives `droppable`. Unlisted callee => no attr =>
        -- CallOp::getEffects reports conservative read+write (today's
        -- behaviour). Never stamped when the flag is off.
        csePurityAttr =
            if ctx.ecoConfig.callPurityAttrs && calleeIsDroppable funcName then
                Dict.singleton "eco.cse_safe" UnitAttr

            else
                Dict.empty

        attrs =
            Dict.union csePurityAttr
                (Dict.union operandTypesAttr
                    (Dict.union gcRootsCountAttr
                        (Dict.singleton "callee" (SymbolRefAttr funcName))
                    )
                )
```

Apply the identical hunk to `ecoCallNamedMulti` (:747-784) — the `$sret` worker path can
also target a kernel. Add `import Compiler.GlobalOpt.KernelFacts as KernelFacts` to
Ops.elm's import block (:73-85) — alphabetically it goes **after**
`Compiler.Generate.MLIR.Types as Types` (:74, since `Generate` < `GlobalOpt`) and before
`import Dict` (:75); no cycle (KernelFacts imports only `Compiler.Data.Name` + `Dict`, mirroring today's
`Borrow/KernelSigs.elm`:31-32, and `Compiler.Generate.MLIR.*` already imports
`Compiler.GlobalOpt.*` — Backend.elm:25-27, Context.elm:65).
`UnitAttr` is already a constructor of `MlirAttr` (Mlir/Mlir.elm:64) and is handled by
both writers (Pretty.elm:399,615; Bytecode AttrType.elm:484-485 → code 7 at :917-918;
StringTable.elm:167), so no serializer work.

**1.4 Hint contingency (record, do not implement).** If `Ctx.liveEcoValueVars`
(Context.elm:647-649) is ever restored to its Phase-1 conservative body (the commented
implementation at :627-642), every `eco.call` gains a live-set-dependent operand tail and
two identical pure calls stop being structurally equal — the CSE value collapses to
near-zero. The fix, mirroring kernel-opt-01's option-1 analysis, is to pass `[]` for
`gcRootHints` at exactly the sites where `csePurityAttr` is non-empty (hint-free emission,
relying on EcoGCPrepare's own liveness, which unions the op's own operands anyway —
Step 4's rationale comment at EcoGCPrepare.cpp:315-327 and the union loop at :328-345).
Add this as a one-line guard in `ecoCallNamed` at that time;
today it would be dead code, so it is NOT written now.

**Acceptance for Phase 1:** `cmake --build build --target elm-tests` green;
`ECO_CALL_PURITY=0` (default) self-compile produces byte-identical `.mlir` to the
pre-change tree; then run the Phase-2 census command twice, once with
`ECO_CALL_PURITY=0` and once with `=1`, and `diff` the two text dumps — the diff must show
**only** added `eco.cse_safe` tokens and nothing else. Note the flag spelling: the
compiler's text-MLIR switch is the CLI flag `--text-mlir` (Terminal/Main.elm:296, :337).
`ECO_TEXT_MLIR` is a **test-harness** variable only — `getTextMlirFlag()`
(test/TestSuite.hpp:20-26) appends `--text-mlir` to the harness's own compiler invocation;
it does nothing when you run `eco-compiler` by hand. Nothing in the C++ reads the attr yet,
so even flag-on is behaviourally inert at this phase.

### Phase 2 — coverage census + go/no-go

**Mechanism:** no counter code. The census is a text-MLIR grep, made possible by the
`--text-mlir` CLI flag (registered `Terminal/Main.elm:296` / `:337`; threaded through
`Make.Flags` at :326 and consumed in `Terminal/Make.elm`'s `handleMlirOutput` :325-357 —
`if ctx.textMlir then Generate.writeMonoMlirStreaming … else …Bytecode…` at :334-357) and
the flag-on build from Phase 1. Text form matters because `Mlir.Pretty.ppOp` prints the
generic form with the op name quoted (`"\"" ++ op.name ++ "\""`, Pretty.elm:222-223) and
`ppAttrs` renders a `UnitAttr` as the bare key (:390-403), so `eco.cse_safe` and
`callee = @Sym` land on the same line and are greppable.

**Commands** (run once; tee, then grep the file — repo rule):

```bash
cd /work/build/compiler/build-kernel
ECO_CALL_PURITY=1 ./bin/eco-compiler make --optimize --text-mlir \
    --kernel-package eco/compiler \
    --local-package eco/kernel=/work/eco-kernel-cpp \
    --output=bin/eco-compiler-purity.mlir \
    /work/compiler/src/Terminal/Main.elm 2>&1 | tee /tmp/purity_census.txt
# Mirrors the Stage-7a custom command at compiler/CMakeLists.txt:477-490 (which resolves
# ECO_COMPILER_ELF=<build>/compiler/build-kernel/bin/eco-compiler :453,
# BUILD_KERNEL_DIR=<build>/compiler/build-kernel :191,
# ELM_ENTRY=<repo>/compiler/src/Terminal/Main.elm :122), plus --text-mlir.
# NOTE: the text dump of the self-compile module is ~80 MB (13 MB of bytecode);
# have the disk space, and grep it rather than opening it.

# total eco.call ops, and the stamped subset:
grep -c '"eco.call"' bin/eco-compiler-purity.mlir
grep -c 'eco.cse_safe'  bin/eco-compiler-purity.mlir
# per-symbol breakdown (output format: "<count> @<symbol>", one line per symbol,
# sorted desc — same shape as callsite-census-self-compile.txt):
grep 'eco.cse_safe' bin/eco-compiler-purity.mlir \
  | grep -o 'callee = @[A-Za-z0-9_$]*' | sed 's/callee = //' \
  | sort | uniq -c | sort -rn | tee /tmp/purity_by_symbol.txt
```

**Read the result:** compare `/tmp/purity_by_symbol.txt` against the KernelFacts rows
whose `droppable` holds. Every stamped symbol must have a row; every droppable row with
static sites in `design_docs/kernel-boundary/callsite-census-self-compile.txt` must appear.
A mismatch is a mirroring bug — the likeliest cause is kernel-opt-07's `splitSymbol`
mis-normalising a symbol, so cross-check with:

```bash
grep -E '_(Int|Float|Char)$' design_docs/kernel-boundary/callsite-census-self-compile.txt
# 2026-08-10: exactly six lines —
#   118 @Elm_Kernel_JsArray_initializeFromList_Int
#    97 @Elm_Kernel_JsArray_initialize_Int
#    92 @Elm_Kernel_List_cons_Int
#    56 @Elm_Kernel_List_cons_Char
#    22 @Elm_Kernel_JsArray_indexedMap_Int
#     3 @Elm_Kernel_Json_wrap_Int
# — all six genuine ABI variants of a listed base kernel (Trap I).
```

Fix before Phase 3. This doubles as the **mirroring audit** in the Gates section.

**Predicted result, so a wildly different `S` is itself a signal.** Summing the static
census over kernel-opt-07's seeded droppable set (A1 :700-717 + A2 :719-730, minus the
rows whose `cseSafe` starts `False`) gives **≈ 11,845 stamped sites** — dominated by
`List_cons` 4,158, `Utils_append` 3,465, `Utils_equal` 1,357, `Bytes_getStringWidth` 697,
`List_reverse` 469, `Bytes_read_u32` 411, `Utils_compare` 296. Two caveats: `(Utils, equal)`
and `(Utils, notEqual)` (1,357 + 63 = 1,420 sites) carry `cseSafe = False` until 07's
Phase 5 flips them, and the static census counts *kernel-symbol* call sites only, so
`S ≤ 11,845` and `S ≈ 10,400` if 07 Phase 5 has not landed.

**Decision point / criterion:** let `S` = stamped sites, `T` = total `eco.call` sites
(baseline: 17,005 *kernel-symbol* sites inside a much larger `eco.call` population, so
`T ≫ 17,005`).
- **If `S ≥ 500`:** proceed to Phase 3 as written. 500 is the floor at which kernel-opt-10
  can plausibly measure a CSE delta at all (its own folder pool is 2,965 sites). The
  prediction above says this is the expected branch by a wide margin; if `S` lands far
  below ~10,000, suspect the mirroring rather than the table.
- **If `S < 500`:** do NOT abandon — proceed to Phase 3 anyway but **descope Phase 5's
  consumer coordination to documentation only**, and record in this file that the channel
  is infrastructure whose payoff waits on the facts table growing more `Total` rows. The
  Phase-3 code is ~60 lines and is the thing that prevents plan 10/13 from each inventing
  a name list; that value does not depend on `S`.
- **If `S == 0`** (no droppable row survives kernel-opt-07's audit): STOP and record a
  documented NO-GO in this file; do not land Phase 3.

**Acceptance:** `/tmp/purity_by_symbol.txt` exists, is reconciled row-by-row against the
facts table, and the branch above is recorded in this file with the actual `S`/`T`.

### Phase 3 — MemoryEffectOpInterface, verifier, strip, assert (C++)

**3.1 Ops.td.** `Eco_CallOp`'s trait list becomes:

```tablegen
def Eco_CallOp : Eco_Op<"call", [
    DeclareOpInterfaceMethods<SymbolUserOpInterface>,
    DeclareOpInterfaceMethods<Eco_GCRootCarrierOpInterface>,
    DeclareOpInterfaceMethods<MemoryEffectsOpInterface>
]> {
```

`include "mlir/Interfaces/SideEffectInterfaces.td"` is already present (Ops.td:15) and
`#include "mlir/Interfaces/SideEffectInterfaces.h"` is already in EcoOps.h:17 and
EcoOps.cpp:15 — no include, CMake, or dialect-registration work. **Do not add
`eco.cse_safe` to `let arguments`**: it stays discardable, exactly like
`eco.gc_roots_count` (EcoOps.cpp:22-25), so no builder signature changes and **all 11 C++
sites that build an `eco.call`** compile untouched and produce unstamped — i.e.
conservative — calls. Exhaustive list (`grep -rn 'create<CallOp>\|create<eco::CallOp>' runtime/src/codegen/Passes/*.cpp`,
verified 2026-08-10): `EcoPAPSimplify.cpp:141` and `:258` (`rewriter.create<CallOp>`, the
saturated-PAP→direct-call rewrites); `EcoCompareCaseRewrite.cpp:175`
(`b.create<eco::CallOp>` for `Elm_Kernel_Utils_cmp3`); `EcoListTemplate.cpp:568, 578, 590,
603, 821, 833, 847, 853` (the chunk-template marker/finish runtime calls). See Trap H.

**3.2 Attr-name constant** in `runtime/src/codegen/EcoOps.h`, after the generated
op-class include (`#define GET_OP_CLASSES` :29 / `#include "eco/EcoOps.h.inc"` :30) and
before `#endif` (:32), so the pass files share one spelling (`llvm::StringLiteral` comes
in transitively via `mlir/IR/Builders.h`, :10). Both consumers already include this
header — `EcoGCPrepare.cpp:17` and `EcoGCLivenessAudit.cpp:16` (`#include "../EcoOps.h"`),
so no new include anywhere. Neither pass file has `using namespace eco;`, hence the
`eco::` qualifier in the 3.5 / 3.6 sketches:

```cpp
namespace eco {
/// kernel-opt-12 purity channel: discardable unit attr on eco.call. Present
/// iff the callee's KernelFacts row derives `droppable`. Stripped by
/// EcoGCPrepare — see Ops.td's Eco_CallOp description for the license.
inline constexpr llvm::StringLiteral kCseSafeAttrName{"eco.cse_safe"};
} // namespace eco
```

**3.3 `CallOp::getEffects`** in EcoOps.cpp, placed immediately before the
"GCRootCarrier Interface Implementations" banner (:911-913):

```cpp
//===----------------------------------------------------------------------===//
// MemoryEffectOpInterface: CallOp
//===----------------------------------------------------------------------===//

// kernel-opt-12. `eco.cse_safe` present => report NO effects, which licenses
// exactly {merge duplicates, erase if unused}. It does NOT license
// speculation: we implement no ConditionallySpeculatable, so isSpeculatable()
// stays false and LICM-style motion is impossible.
//
// Attr ABSENT => conservative read+write on the default resource. This is the
// correctness-critical branch: declaring the interface at all removes the
// "no interface => unknown effects" default (see getEffectsRecursively's
// std::nullopt contract, SideEffectInterfaces.h:436-445), so every unstamped
// call must claim effects explicitly or the whole program's calls become
// erasable.
void CallOp::getEffects(
    SmallVectorImpl<MemoryEffects::EffectInstance> &effects) {
    if ((*this)->hasAttr(kCseSafeAttrName))
        return; // no effects

    effects.emplace_back(MemoryEffects::Read::get());
    effects.emplace_back(MemoryEffects::Write::get());
}
```

Every name in that sketch is verified against the installed headers (2026-08-10):
`namespace MemoryEffects` at SideEffectInterfaces.h:348, `using EffectInstance =
SideEffects::EffectInstance<Effect>` at :359, `struct Allocate/Free/Read/Write` at
:364/:369/:374/:379; the single-argument `emplace_back` selects
`EffectInstance(EffectT *, Resource * = DefaultResource::get())` (:141-143); the method
shape `DeclareOpInterfaceMethods` will generate into `EcoOps.h.inc` is the one at
SideEffectInterfaces.h.inc:52 (non-const, by-reference `SmallVectorImpl`). `using namespace
mlir;` / `using namespace eco;` are already at EcoOps.cpp:18-19, so the unqualified
spellings above resolve.

**REQUIRED IMPLEMENTATION-TIME TEST — the conservative-equivalence claim.** The claim is:
*"read+write on the default resource with an unspecified value is at least as conservative,
for every consumer in this pipeline, as having no effect interface."* The argument is:
(a) `isMemoryEffectFree` is false in both worlds (:424-434); (b) `wouldOpBeTriviallyDead`
is false with a Write effect (:417-422); (c) MLIR CSE's read-only special case cannot fire
because a Write is reported; (d) `isSpeculatable` is false in both worlds (no
`ConditionallySpeculatable`). MLIR's `CSE.cpp` / `SideEffectInterfaces.cpp` sources are
NOT present in this environment (`/opt/llvm-mlir` ships headers + libs only), so the
argument is not source-verified. It MUST be discharged empirically by fixture **F2
`call_purity_attr_conservative.mlir`** (spec in Phase 4 — and note it is already green
against the pre-change tree, so a red F2 after this hunk is unambiguous) plus the
flag-off `--target full` and bootstrap byte-identity gates. **If F2 goes red, the branch
is wrong** — the fallback is to report all four effect kinds:

```cpp
    effects.emplace_back(MemoryEffects::Read::get());
    effects.emplace_back(MemoryEffects::Write::get());
    effects.emplace_back(MemoryEffects::Allocate::get());
    effects.emplace_back(MemoryEffects::Free::get());
```

and re-run. If *that* still differs from the pre-change tree, the equivalence is
unreachable and the whole item reverts to revert point (3) in Flag & rollback.

**3.4 Verifier arm** in `CallOp::verify` (EcoOps.cpp:862-909), inserted at :870 — after
`rootCount` / `realOperandCount` are computed (:868-869) and before the
`// Case 1: Direct call` comment (:871) / `if (calleeAttr)` (:872). `calleeAttr` is already
bound at :864 and `rootCount` at :868 (via the file-static `getGCRootsCountAttr` helper,
:22-25); `getMusttail()` is NOT pre-bound in `verify` (:865 binds `remainingArityAttr`),
so the sketch calls it directly, using the same
`auto musttail = …; if (musttail && *musttail)` idiom as `isCallSafepoint`
(EcoGCPrepare.cpp:128-130). Note this arm is the only place the
"attr + roots" combination is caught, and the PassManager runs the module verifier after
every pass by default, so it fires immediately after EcoGCPrepare if the Phase-3.5 strip
is ever removed — that is what makes fixture F3b a real test:

```cpp
  if ((*this)->hasAttr(kCseSafeAttrName)) {
    if (!calleeAttr)
      return emitOpError("'eco.cse_safe' is only valid on a direct call "
                         "(requires the 'callee' attribute)");
    auto musttail = getMusttail();
    if (musttail && *musttail)
      return emitOpError("'eco.cse_safe' must not be set on a musttail call");
    if (rootCount != 0)
      return emitOpError("'eco.cse_safe' must not survive GC root attachment "
                         "(a purity consumer is running after EcoGCPrepare)");
  }
```

**3.5 Strip at EcoGCPrepare.** In `processBlock`'s Step-4 loop — `for (auto &op : block) {`
at EcoGCPrepare.cpp:328, `if (!isCallSafepoint(&op)) continue;` at :329 — insert *before*
the early-continue, so that musttail calls are covered too (`isCallSafepoint`,
EcoGCPrepare.cpp:125-140, returns false for them at :127-130 — and kernel-opt-09's
relaxation will make it return false for gc-leaf calls as well):

```cpp
        for (auto &op : block) {
            // kernel-opt-12: the Elm-level purity channel dies HERE. From the
            // next statement on, calls carry appended root operands
            // (CallOp::setGCRoots, EcoOps.cpp:995-1005) and any merge/motion
            // would corrupt root bookkeeping. Stripping also reverts
            // CallOp::getEffects to its conservative branch for all
            // downstream passes.
            if (isa<eco::CallOp>(&op))
                op.removeAttr(eco::kCseSafeAttrName);

            if (!isCallSafepoint(&op)) continue;
```

`processBlock` is invoked for every block in the function including nested SCF regions
(`func.walk([&](Block *block) { processBlock(*block, liveness); });`, EcoGCPrepare.cpp:179-181,
inside `processFunction` :165-182), so coverage is total. `Operation::removeAttr(StringRef)`
is a no-op when the attr is absent, so the guard is one dictionary probe per call op inside
an already-existing walk — no new traversal, which matters because this pipeline already
economises around EcoGCPrepare (the M4 canonicalizer removal, EcoPipeline.cpp:88-96).

**Thread-safety note (mirrors the pinned kernel-opt-09 design):** the strip touches only
the op being visited, reads no sibling `func.func`, and adds no cross-function state.
EcoGCPrepare stays a `PassWrapper<…, OperationPass<ModuleOp>>` (:145-146) whose
`runOnOperation` just walks its own functions (:155-162).

**3.6 Pipeline-position assert (debug builds).** In `EcoGCLivenessAudit` — the pass that
already runs immediately after EcoGCPrepare under `ECO_LOWERING_VALIDATION`
(EcoPipeline.cpp:100-102) — append at :133, after the existing carrier walk
(`func.walk([&](Operation *op) { … });` :51-132, whose failure idiom is `op->emitError(…)`
+ `hadError = true` at :129-131) and before `if (hadError) signalPassFailure();` at :134.
The whole body sits inside the `#else` arm of `#ifndef ECO_LOWERING_VALIDATION` (:43-45),
and `func` is a `func::FuncOp` (`OperationPass<func::FuncOp>`, :32; `auto func = getOperation();`
:46), so the typed walk below compiles as written:

```cpp
        // kernel-opt-12: purity attrs must not survive EcoGCPrepare. If one
        // does, a purity consumer has been ordered after the root append and
        // is one merge away from a miscompile.
        func.walk([&](eco::CallOp call) {
            if (call->hasAttr(eco::kCseSafeAttrName)) {
                call->emitError("[gc-purity] 'eco.cse_safe' survived "
                                "EcoGCPrepare — a purity consumer is "
                                "mis-ordered in the pipeline");
                hadError = true;
            }
        });
```

**Where purity consumers MAY run:** anywhere in `buildEcoToEcoPipeline`
(EcoPipeline.cpp:49-73) or in `buildEcoToLLVMPipeline` up to and including the M4 slot
(the dead `// pm.addNestedPass<func::FuncOp>(createCanonicalizerPass());` line at :96) —
i.e. strictly before `pm.addPass(eco::createEcoGCPreparePass())` at :99. This sentence
belongs verbatim in a comment at the M4 slot, so whoever lands kernel-opt-10's
`if (ecoMlirCseEnabled()) pm.addNestedPass<func::FuncOp>(createCSEPass());` reads it.
kernel-opt-10 already writes exactly this constraint into its 1.1 insertion comment; the
comment this item adds is the one-line pointer back here, not a duplicate.

**Acceptance for Phase 3:** `cmake --build build --target full` green (see Gates);
Phase-4 fixtures F1-F4 green; and the deliberate-misorder check: in a scratch `dev`-preset
build, move `pm.addPass(eco::createEcoGCPreparePass())` (EcoPipeline.cpp:99) *above* the
M4 slot, rebuild, and confirm (a) `CallOp::verify`'s `rootCount != 0` arm and/or (b) the
3.6 audit error fires on the codegen subset. Revert the scratch edit.

### Phase 4 — fixtures

Fixtures live in `/work/test/codegen/` and are **auto-discovered** — `discoverTests`
(test/codegen/CodegenIsolatedTest.hpp:292-306) walks the directory with
`std::filesystem::directory_iterator` and takes every `*.mlir` (:298-302), so there is no
CMake edit and no list to register in. `test/codegen/invalid_to_heap_closure_env.mlir` is
the `not %ecoc` negative model.

**READ THIS BEFORE WRITING A FIXTURE — three hard constraints of this harness that make
lit-style fixtures silently vacuous.** All verified in the tree 2026-08-10:

1. **Only ONE `-emit=` mode runs per file.** `parseEmitMode`
   (test/codegen/CodegenIsolatedTest.hpp:88-112) scans for the first `// RUN:` line and
   *returns* on the first `-emit=` token it recognises; `runCodegenTest` (:263-283) then
   executes the file exactly once, via `runSubprocessTest` (:237-255) as
   `ecoc "<file>" -emit=<mode>` — **no shell, no pipe, no extra flags, no per-fixture
   env**. A second `// RUN:` line is dead text. So every distinct emit mode needs its own
   `.mlir` file.
2. **`--check-prefix` does not exist here.** `extractCheckPatterns` is always called with
   the defaults `"// CHECK:"` / `"// CHECK-NOT:"` (test/CheckPatterns.hpp:189-284, the
   signature's default arguments at :191-192). Lines
   beginning `// GUARD:`, `// JIT:`, `// ECO:`, `// LOW-NOT:` match no prefix and are
   **discarded silently** — a fixture written that way asserts nothing and passes. (This
   is why `test/codegen/caf_memo_basic.mlir`'s `GUARD:`/`JIT:` blocks are not a convention
   to copy: they are inert.) Supported directives are exactly CHECK, CHECK-NOT, CHECK-DAG,
   CHECK-SAME, CHECK-NEXT, CHECK-LABEL (enumerated in the header comment at
   CheckPatterns.hpp:4-23).
3. **Any other `CHECK-*` variant is a hard parse error.** `CHECK-COUNT-1:` throws
   `"CheckPatterns: unsupported CHECK variant in test file"` (CheckPatterns.hpp:260-281).
   There is no way to assert an exact occurrence count directly; use the
   CHECK + CHECK-NEXT sandwich (F5) instead.

Also: `runSubprocessTest` **ignores the exit code** — the `not ` in a RUN line is
decorative, and a negative fixture is only a real test because its `CHECK` matches the
diagnostic text (stderr is folded in: `executeCommand` appends `2>&1`, :45).

**F1 `call_purity_attr_roundtrip.mlir`** — the attr parses and prints on `eco.call`. The
expected output line was produced by running the built `ecoc` on this exact input
(see Evidence), so the CHECK-SAME order below is the *printed* order — `callee` lives in
the properties dict `<{…}>` and therefore precedes the discardable `{eco.cse_safe}`:

```mlir
// RUN: %ecoc %s -emit=mlir 2>&1 | %FileCheck %s
//
// kernel-opt-12: `eco.cse_safe` is a discardable dialect attribute on
// eco.call (like eco.gc_roots_count) — it needs no ODS argument entry and
// must round-trip through the parser/printer unchanged. Printed form:
//   %1 = "eco.call"(%0) <{callee = @Elm_Kernel_String_length}> {eco.cse_safe}
//        : (!eco.value) -> !eco.value

module {
  func.func private @Elm_Kernel_String_length(%s: !eco.value) -> !eco.value

  func.func @main() -> i64 {
    %c = arith.constant 3 : i64
    %v = eco.box %c : i64 -> !eco.value
    %n = "eco.call"(%v) {callee = @Elm_Kernel_String_length, eco.cse_safe}
       : (!eco.value) -> !eco.value
    %z = arith.constant 0 : i64
    return %z : i64
  }
}

// CHECK: "eco.call"
// CHECK-SAME: callee = @Elm_Kernel_String_length
// CHECK-SAME: eco.cse_safe
```

**F2 `call_purity_attr_conservative.mlir`** — Trap-D negative; discharges the
conservative-equivalence claim of 3.3. An UNSTAMPED call whose result is unused must
survive the whole lowering (the DCE-capable pass it must survive is the greedy driver at
EcoControlFlowToSCF.cpp:1159-1167). **This body was run against the current `ecoc` and
already emits `llvm.call @sideEffecting(%3) : (!llvm.ptr<1>) -> !llvm.ptr<1>` at
`-emit=mlir-llvm`** — i.e. the fixture is green *before* the Ops.td change and must stay
green after it:

```mlir
// RUN: %ecoc %s -emit=mlir-llvm 2>&1 | %FileCheck %s
//
// kernel-opt-12 Trap D: declaring MemoryEffectOpInterface on Eco_CallOp
// flips the default. A call WITHOUT `eco.cse_safe` reports conservative
// read+write and must NEVER be erased, even with its result unused.

module {
  func.func private @sideEffecting(%v: !eco.value) -> !eco.value {
    eco.dbg %v : !eco.value
    eco.return %v : !eco.value
  }

  func.func @main() -> i64 {
    %c = arith.constant 7 : i64
    %v = eco.box %c : i64 -> !eco.value
    %unused = "eco.call"(%v) {callee = @sideEffecting} : (!eco.value) -> !eco.value
    %z = arith.constant 0 : i64
    return %z : i64
  }
}

// CHECK: llvm.call @sideEffecting
```

The semantic (rather than structural) companion is a SEPARATE file
`call_purity_attr_conservative_jit.mlir` with the same body but
`// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s` and a `CHECK` on the `eco.dbg` output —
it cannot share F2's file (constraint 1). Optional; F2 alone discharges the claim.

**F3a `call_purity_attr_survives_eco.mlir`** — nothing in the eco-to-eco stage eats the
attr. `-emit=mlir-eco` runs `buildEcoToEcoPipeline` only (ecoc.cpp `runPipeline` :186-210,
`else` branch :199-205 calling `buildEcoToEcoPipeline` at :204; the `lowerToLLVM` branch
calls `buildEcoToLLVMPipeline` at :198). Verified against today's `ecoc`: the attr is
still printed after that stage.

```mlir
// RUN: %ecoc %s -emit=mlir-eco 2>&1 | %FileCheck %s
//
// kernel-opt-12: the purity channel must survive RCElimination / PAPSimplify /
// CompareCaseRewrite / UndefinedFunction unchanged — it only dies at EcoGCPrepare,
// which is in the LLVM-lowering pipeline (EcoPipeline.cpp:99), not this one.

module {
  func.func private @sideEffecting(%v: !eco.value) -> !eco.value {
    eco.dbg %v : !eco.value
    eco.return %v : !eco.value
  }

  func.func @main() -> i64 {
    %c = arith.constant 5 : i64
    %v = eco.box %c : i64 -> !eco.value
    %r = "eco.call"(%v) {callee = @sideEffecting, eco.cse_safe} : (!eco.value) -> !eco.value
    eco.dbg %r : !eco.value
    %z = arith.constant 0 : i64
    return %z : i64
  }
}

// CHECK: "eco.call"
// CHECK-SAME: eco.cse_safe
```

**F3b `call_purity_attr_stripped.mlir`** — the strip actually happens.
**Do NOT write this as `-emit=mlir-llvm` + `CHECK-NOT: eco.cse_safe`: that assertion is
vacuous.** Verified 2026-08-10 on the current tree: `eco.call` is rewritten to `llvm.call`
by EcoToLLVM and discardable Eco attrs do not travel across the conversion, so
`eco.cse_safe` is already absent at `-emit=mlir-llvm` *today*, with no strip implemented.
The strip is instead proven by the Phase-3.4 verifier arm: a stamped call **with an
`!eco.value` operand** necessarily gets `eco.gc_roots_count >= 1` from EcoGCPrepare's Step-4
union (EcoGCPrepare.cpp:328-345), so if the strip were removed the module verifier the
PassManager runs after EcoGCPrepare would fail with `'eco.cse_safe' must not survive GC
root attachment`. The fixture therefore asserts that lowering **succeeds**:

```mlir
// RUN: %ecoc %s -emit=mlir-llvm 2>&1 | %FileCheck %s
//
// kernel-opt-12: EcoGCPrepare strips `eco.cse_safe` before appending GC roots
// (EcoGCPrepare.cpp Step 4, :328). If that strip is ever removed, CallOp::verify's
// rootCount arm fails this module immediately after EcoGCPrepare and this CHECK
// never matches. Do NOT "improve" this into a CHECK-NOT on eco.cse_safe: the attr
// is absent from the LLVM-dialect dump for an unrelated reason (op conversion),
// so a CHECK-NOT would pass even with the strip deleted.

module {
  func.func private @sideEffecting(%v: !eco.value) -> !eco.value {
    eco.dbg %v : !eco.value
    eco.return %v : !eco.value
  }

  func.func @main() -> i64 {
    %c = arith.constant 9 : i64
    %v = eco.box %c : i64 -> !eco.value
    %r = "eco.call"(%v) {callee = @sideEffecting, eco.cse_safe} : (!eco.value) -> !eco.value
    eco.dbg %r : !eco.value
    %z = arith.constant 0 : i64
    return %z : i64
  }
}

// CHECK: llvm.call @sideEffecting
```

**F4 `call_purity_attr_indirect.mlir`** — the verifier rejects the attr on an indirect
call. `-emit=mlir` is the input dump, no passes (`clEnumValN(DumpMLIR, "mlir", "Dump input
MLIR (no lowering)")`, ecoc.cpp:137), but parsing still runs `CallOp::verify`, so the
diagnostic appears. `not %ecoc` also flips `isExpectedCrash`
(CodegenIsolatedTest.hpp:189-192) so the file runs out-of-process. The body below was
checked against the current `ecoc`: it parses and verifies cleanly today, so the only
thing that can make it fail is the new arm.

```mlir
// RUN: not %ecoc %s -emit=mlir 2>&1 | %FileCheck %s

module {
  func.func @main(%clo: !eco.value, %a: !eco.value) -> i64 {
    %r = "eco.call"(%clo, %a) {remaining_arity = 1 : i64, eco.cse_safe}
       : (!eco.value, !eco.value) -> !eco.value
    %z = arith.constant 0 : i64
    return %z : i64
  }
}

// CHECK: only valid on a direct call
```

A second file `call_purity_attr_musttail.mlir` covers the musttail arm the same way
(`{callee = @f, musttail = true, eco.cse_safe}`, `// CHECK: must not be set on a musttail
call`). A third, `call_purity_attr_roots.mlir`, covers the `rootCount` arm
(`{callee = @f, eco.cse_safe, eco.gc_roots_count = 1 : i64}` with two operands,
`// CHECK: must not survive GC root attachment`). All three are `not %ecoc … -emit=mlir`.

**F5 `call_purity_cse_merge.mlir` — DEFERRED; lands with kernel-opt-10.** Two constraints
make the obvious spelling impossible, so pin the shape now:
- `CHECK-COUNT-1` **throws** in this harness (constraint 3 above). Assert "exactly one"
  with a CHECK + CHECK-NEXT sandwich against JIT output instead: give the callee an
  `eco.dbg` marker `111`, call it twice with identical arguments, then `eco.dbg` a
  sentinel `222`; `// CHECK: 111` + `// CHECK-NEXT: 222` is satisfiable only if the
  duplicate call was merged. (Stamping `eco.cse_safe` on a dbg-ing callee is a deliberate
  fixture lie — the same device `caf_memo_basic.mlir` uses to observe single evaluation.)
- kernel-opt-10 adds CSE behind `ecoMlirCseEnabled()` → `ECO_MLIR_CSE`, **default OFF**,
  read when the pipeline is built. The harness passes no per-fixture env, so this fixture
  only runs meaningfully once `ECO_MLIR_CSE` defaults on, or under
  `ECO_MLIR_CSE=1 TEST_FILTER=codegen cmake --build build --target full`. State that in
  the fixture's header comment.
- The M4 slot (EcoPipeline.cpp:96) is inside `buildEcoToLLVMPipeline`, so `-emit=mlir-eco`
  never shows the merge; use `-emit=jit` (per the sandwich above) or `-emit=mlir-llvm`.

**Acceptance:** F1, F2, F3a, F3b, F4 (+ its two siblings) green in
`TEST_FILTER=codegen cmake --build build --target full 2>&1 | tee /tmp/test_codegen.txt`.
Sanity-check that they are not vacuous: temporarily corrupt one CHECK string in each and
confirm the fixture goes red (the harness's historical failure mode was silently skipped
directives — CheckPatterns.hpp:25-30 records ~30 fixtures that "passed" while asserting
nothing).

### Phase 5 — consumer coordination

Land Phases 1-4 **before** kernel-opt-09's and kernel-opt-10's consuming phases. Review
both plans for parallel name lists and fix on sight. Status as of 2026-08-10 (all three
sibling plans re-read):
- **kernel-opt-10 — already compatible, no edit needed.** Its Phase 1.1 adds
  `if (ecoMlirCseEnabled()) pm.addNestedPass<func::FuncOp>(createCSEPass());` at the M4
  slot (EcoPipeline.cpp:96) and introduces no kernel-name switch; its Dependencies section
  already states that `eco.cse_safe` is "a *different* channel … nothing here reads it".
  That is exactly right: stock `createCSEPass()` consults `MemoryEffectOpInterface`, so it
  picks up stamped calls **automatically** once this item lands — 10 needs no code that
  mentions the attr. The only coordination owed is F5 (above), which lands in 10's tree.
- **kernel-opt-09 — already compatible, no edit needed.** Its v2 text consumes
  `eco.gc_leaf` (decl) / `eco.callee_gc_leaf` (call-local, stamped by the module-level
  `EcoMarkGCLeafCalls` pass) and explicitly records at :657-659 that
  `eco.kernel_cannot_gc` was v1's name and is **deleted**. (v1 of THIS plan claimed 09
  still carried that name — that claim is stale and has been removed.) The one live
  interaction to keep in view: 09's relaxation makes `isCallSafepoint` return false for
  gc-leaf calls, which is why this item's strip sits *before* the early-continue (3.5).
- **kernel-opt-13 (Mono CSE)** reads the facts table directly in Elm; it must use
  `droppable` for deletion and `hoistable` for motion, and must not consult MLIR attrs.

**Acceptance:** a one-paragraph note in each of 09/10/13 recording which channel it reads,
plus this section updated with the actual state at landing time.

## Traps & risks

- **Trap A — GCRootCarrier operand mutation (EcoOps.cpp:995-1005).** The attr must never
  license motion or merging after EcoGCPrepare has appended roots. Enforced three ways:
  the Phase-3.5 strip, the Phase-3.4 verifier `rootCount != 0` arm, and the Phase-3.6
  debug assert.
- **Trap B — never blanket-mark `eco.call` Pure (design doc :2189-2190).** Most calls
  allocate, HOF kernels run arbitrary closures, Task builders capture
  (KERNEL_TASK_IO_001). Purity is strictly per-callee, table-derived, whitelist-only.
- **Trap C — `cseSafe` ≠ Pure.** Elm has no reference identity, so sharing one Cons cell
  between two `x :: xs` occurrences is unobservable: `List_cons` is `cseSafe` **despite
  allocating**. That is why this channel is orthogonal to `eco.gc_leaf` (D4) and why the
  Phase-3.5 strip is what keeps it sound: while the attr is alive, a GC-triggering call
  has no root operands yet, so merging or dropping it is a pure IR-level rewrite.
- **Trap D — declaring the interface flips the default.** Verified from the upstream
  header contract (SideEffectInterfaces.h:424-445): no interface ⇒ unknown ⇒ conservative;
  interface with empty report ⇒ effect-free ⇒ erasable. F2 is the dedicated negative
  fixture and 3.3 carries the fallback (report all four effect kinds).
- **Trap E — merge and drop arrive BUNDLED (new in v2).** Stock MLIR has no
  "mergeable but not erasable" level, so the attr necessarily licenses DCE. Hence D2:
  emit on `droppable`, not on bare `cseSafe`. If a future consumer genuinely needs
  merge-without-drop, it needs a *custom* CSE pass keyed on the attr, not the stock one.
- **Trap F — the first consumer arrives by accident (new in v2).**
  `EcoControlFlowToSCF`'s `applyPatternsGreedily` (EcoControlFlowToSCF.cpp:1159-1167,
  EcoPipeline.cpp:81) DCEs trivially-dead ops — the driver's documented contract, not an
  inference (GreedyPatternRewriteDriver.h:199) — and runs before EcoGCPrepare. Note the
  in-tree comment at EcoControlFlowToSCF.cpp:1159 ("with folding disabled to prevent DCE")
  is misleading: `enableFolding(false)` disables folding, not DCE. So Phase 3 +
  flag-on can change generated code with no CSE pass in the pipeline at all. This is
  licensed behaviour, but it is why the flag is default-off and why the bootstrap gate is
  stated as "byte-identity flag-OFF; new fixed point flag-ON".
- **Trap G — attr survives serialization into cached `.mlir`.** Stale `.mlir` with old
  attrs + new consumer = confusion. Standing rule: `--target full`, never `check`. The
  hash token `cpur=1` additionally prevents flag-on artifacts sharing flag-off caches.
- **Trap H — C++-created calls are never stamped.** All 11 in-tree sites build `eco.call`
  through the ODS builder with no discardable attrs: `EcoPAPSimplify.cpp:141` / `:258`
  (which do copy `eco.gc_roots_count` forward, :148-151 / :265-268, but nothing else),
  `EcoCompareCaseRewrite.cpp:175`, and `EcoListTemplate.cpp:568/578/590/603/821/833/847/853`.
  So a saturated-PAP-to-direct-call conversion of a droppable kernel loses the attr.
  Conservative (= today's behaviour), so it is a *missed opportunity*, not a bug. Record
  it; do not fix in v1. If it is ever fixed, the natural place is EcoPAPSimplify's two
  sites only — the other nine build runtime helper calls that are not KernelFacts rows.
- **Trap I — the ABI-suffix normalisation is a heuristic, and it is kernel-opt-07's.**
  `lookupSymbol`/`splitSymbol` strip a trailing `_Int`/`_Float`/`_Char` and inherit the
  base row's facts (07's soundness argument: the primitive-specialised C variants are
  strictly weaker in effect than their boxed base). `KernelAbi.kernelInstanceSymbol`
  (KernelAbi.elm:182-250) mints exactly those three suffixes and no others, and the
  2026-08-10 static census contains exactly six such symbols, all genuine variants (see
  Phase 2). If a future kernel is genuinely *named* `foo_Int`, the normalisation silently
  inherits an unrelated row. Re-run the Phase-2 audit grep whenever kernel names change;
  the fix, if it is ever needed, belongs in kernel-opt-07's module, not here.

## Dependencies

- **Hard: kernel-opt-07-kernel-facts-table.md** — sole source of `cseSafe` / `totality`
  and therefore of the derived `droppable`. Phase 1.2/1.3 consume exactly three names from
  it, all in 07's `exposing` list and all pinned by its cross-plan contract:
  `KernelFacts.lookupSymbol : String -> Maybe KernelFacts`, `KernelFacts.droppable :
  KernelFacts -> Bool`, and the opaque `KernelFacts` type. **This item adds nothing to that
  module** (contract pt 3: symbol-only consumers MUST go through `lookupSymbol`; pt 2:
  consumers must call the derived helpers, never re-derive from raw fields). Blocked until
  07 lands. (07 also owns the `Borrow/KernelSigs.elm` shim that keeps Constrain.elm /
  LssFacts.elm untouched, and the `cmake --preset build` reconfigure its new `.elm` files
  require — this item adds no new `.elm` file and needs no reconfigure of its own.)
- **Consumers: kernel-opt-10-mlir-cse-and-folders.md** — its stock `createCSEPass()` reads
  purity through `MemoryEffectOpInterface` automatically, so it needs no code that mentions
  the attr; **kernel-opt-09-gcprepare-barrier-relaxation.md** reads the separate
  `eco.gc_leaf` / `eco.callee_gc_leaf` channel. Both were re-read 2026-08-10 and neither
  grows a name list; see Phase 5 for the current state.
- **Adjacent, not a dependency:** kernel-opt-13 (Mono CSE) is Elm-level and reads the
  facts table directly; kernel-opt-08's LLVM `gc-leaf-function` stamp is a parallel
  channel from the same table (design doc :2176-2179).

## Expected impact

**Honest expectation: FLAT wall — this plan makes no direct wall claim.** It is enabling
infrastructure, and the repo's measured lesson (preserve-cc, the gc-leaf pilot at 64.1%
dynamic call coverage, capacity-check hoisting, the compare phases — four consecutive
metadata-shaped changes measured wall-FLAT) says only consumers that delete per-op work or
retention move wall (inline nursery −9.6%, CAF memoization −11.7%, `$cap`-inlining −14.5%,
K6 hash-consing −5.07%). What this buys:

- One source of truth for per-callee purity across all MLIR passes, ending per-pass
  name-list fragmentation before it starts.
- The effect-model documentation (merge+drop vs read-only vs speculatable) that keeps
  future consumers from miscompiling via Trap C / Trap E.
- A *small* incidental win is possible even without kernel-opt-10, via Trap F: unused
  droppable kernel calls DCE'd by the existing greedy driver. Measure it (Phase 2 gives
  the site count); expect it to be tiny and to show up as deleted `.text`, not wall.

## Gates

Run tests ONCE, tee, then grep the file.

- **Full E2E (mandatory, both flag states):**
  ```bash
  cmake --build build --target full 2>&1 | tee /tmp/test_output.txt
  grep -iE 'FAIL|error:|Falsifiable' /tmp/test_output.txt | head -50
  tail -20 /tmp/test_output.txt
  ```
  then the flag-on run:
  ```bash
  ECO_CALL_PURITY=1 cmake --build build --target full 2>&1 | tee /tmp/test_output_purity.txt
  grep -iE 'FAIL|error:|Falsifiable' /tmp/test_output_purity.txt | head -50
  ```
  Never `--target check` — this changes codegen and would consume stale `.mlir`.
- **Fixture subset while iterating:**
  `TEST_FILTER=codegen cmake --build build --target full 2>&1 | tee /tmp/test_codegen.txt`.
- **Compiler front-end:** `cmake --build build --target elm-tests 2>&1 | tee /tmp/elm_tests.txt`
  (target defined at compiler/CMakeLists.txt:178). Checks that the Config flag and the
  `calleeIsDroppable` helper compile and that no borrow-axis consumer is perturbed. This
  item adds no new `.elm` file, so **no `cmake --preset build` reconfigure is needed**
  (contrast kernel-opt-07, which does add files and therefore does).
- **heap-validate suite:** `ECO_HEAP_VALIDATE=1 cmake --build build --target full 2>&1 | tee /tmp/test_validate.txt`
  — the strip + verifier arms interact with root attachment; expect the suite's current
  full-green count (1632/1632 as of the 2026-08-09 nursery work; re-baseline from the
  flag-off run in the same session rather than hard-coding the number).
- **Bootstrap self-host:**
  - **flag OFF (default): byte-identity at the fixed point must HOLD.** No attr is emitted,
    `getEffects` always takes the conservative branch. `cmake --build build --target bootstrap`
    (target at compiler/CMakeLists.txt:1026; Stage 4b JS + Stage 8c native fixed points).
  - **flag ON: expect a NEW fixed point, not byte-identity** — Trap F means the greedy
    driver may delete unused droppable calls. Run bootstrap flag-on and record that it
    reaches a fixed point; do not treat a diff vs the flag-off binary as a failure.
- **Debug-build assert:** configure `cmake --preset dev` (defines `ECO_LOWERING_VALIDATION`)
  and re-run the codegen subset so `EcoGCLivenessAudit`'s new check actually executes.
- **Wall A/B with major-GC counts recorded** (GC-trigger lottery): flag-off vs flag-on
  Stage 7a, 2×2 interleaved, recording wall, RSS, minor/major GC counts. Expect FLAT;
  record it either way.
- **Mirroring audit:** `/tmp/purity_by_symbol.txt` from Phase 2, reconciled row-by-row
  against the KernelFacts rows where `droppable` holds. Zero unexplained entries in either
  direction.

---

## Outcome — 2026-08-13: SHIPPED DEFAULT-ON (Run R)

All five phases landed as planned; benchmarked as the 2×2 the loop requested
(attr × MLIR CSE). `callPurityAttrs = True` since 2026-08-13; kill switch
`ECO_CALL_PURITY=0`. Full numbers in `benchmarks/kernel-opt.md` Run R.

**Phase 2 census: S = 4,330 of T = 85,437 → GO branch.** The plan predicted
~10,400; the gap is items 01/03/05 having deleted the predicted top rows
(`List_cons`, `Utils_equal`, most of `Utils_append`) before this item arrived.
The mirroring audit passed — including `MVar_put` and `Scheduler_*`, which look
effectful but CONSTRUCT task descriptions (closure + `taskBinding`) and are
correctly `auditedPure` with evidence anchors.

**The headline measurement: the attr is FREE, and buys ~nothing today.**
CSE off ⇒ the lowered binary is BYTE-IDENTICAL (this tree has no unused
droppable kernel calls left for Trap-F DCE). CSE on ⇒ exe −16,384 B and
bit-identical GC counters. The value that remains is exactly what the plan's
expected-impact section claimed and no more: one purity channel instead of
per-pass name lists, the effect-model contract, and readiness for the day CSE
returns. On the PRE-series corpus the attr alone deleted 1.1 MB of exe via
greedy-driver DCE, so the mechanism is real — this series just already ate its
food.

**Side-finding recorded for whoever revisits ECO_MLIR_CSE:** CSE's retention
effect swings SIGN across compiler artifacts — +5.6M promoted (Run Q, item-11
artifact, with folder) vs −3.64M (current tree, same workload). Do not license
CSE on a single favourable measurement.

**A discarded invalid race:** the first 3-arm benchmark lowered the attr arms
from a pristine-corpus compile — the PRE-series compiler — so it raced
different compiler versions (out.mlir at the pre-series 12,943,401 B). Redone
from one current-tree Stage-5 artifact. The frozen corpus is for racing
WORKLOADS; the compiler's own next-stage artifact must come from the live tree.

**Item-09 hand-off discharged:** the strip sits BEFORE Step 4's
`isCallSafepoint` early-continue, so musttail and gc-leaf-relaxed calls are
stripped too; fixture `call_purity_attr_roots.mlir` + the validator-build audit
pin the ordering. Phase 5 notes: 10 reads `MemoryEffectOpInterface` via stock
CSE (no attr-specific code, as designed); 09 reads `eco.gc_leaf` /
`eco.callee_gc_leaf` only; 13 reads KernelFacts directly in Elm (`droppable` /
`hoistable`) and never consults MLIR attrs.

**Gates:** E2E **1656/1656** flag-on, flag-off, and after the flip; 8 new
`call_purity_*` fixtures including the three verifier negatives and F5 (whose
merge leg is meaningful only under `ECO_MLIR_CSE=1`, stated in its header);
flag-off frozen-corpus output byte-identical. **Not run** (loop policy):
heap-validate, bootstrap.

### Amendment — 2026-08-13: `ECO_MLIR_CSE` flipped DEFAULT-ON

Following this item's 2×2, the user applied the loop's keep-if-wall-flat rule
to CSE itself: both artifacts measure wall FLAT, so it ships ON despite the
sign-unstable retention effect (Run Q +5.6M promoted / Run R −3.64M). The
shipping configuration is folder + CSE + purity attrs, and F5
(`call_purity_cse_merge.mlir`) was upgraded from its flag-independent form to
the CHECK/CHECK-NEXT sandwich pinning the kernel-call merge on the default
path — it now fails under `ECO_MLIR_CSE=0` by design (slot_cast_barriers
precedent).

### Amendment 2 — 2026-08-13, same day: `ECO_MLIR_CSE` flip REVERTED

The default-on gate failed three Float container-equality tests — CSE merged
NaN-containing allocations and the pointer-eq fast path made the sharing
observable (details in kernel-opt-10 Amendment 2 and Run R's addendum). CSE is
dark again on correctness grounds. Consequence for THIS item: the merge half of
`eco.cse_safe`'s licence is unsound as stated for kernels whose result can
contain a Float (`List_reverse`, `Utils_append`) — the attr itself stays (it is
inert without a consumer, and the DCE half is unaffected: deleting an unused
call never creates sharing), but any future merge consumer must add a
no-Float-reachable-in-result restriction. F5 reverted to its flag-independent
form. `callPurityAttrs` remains DEFAULT-ON: measured free, and its Trap-F DCE
value is real on corpora with unused droppable calls.
