# Kernel-Opt 08: Kernel gc-leaf stamping default-on + GCStats audit harness

**Status: IMPLEMENTATION-READY v3 — 2026-08-10.** (v2 deepened from OUTLINE v1; v3 is an
adversarial re-verification pass against the tree that corrected the `gcLeafEligible` call
shape, deleted a provably-dead `gcLeafKernels` mechanism, fixed the golden fixture's `eco.call`
syntax, replaced every text-`grep` check on the bytecode `.mlir`, and pre-resolved the
pilot-parity decision point). Derived from design_docs/kernel-boundary-reduction.md §6.C2/C3
(reflection points + pre-RS4GC soundness wall, :1318-1362), §6.D1/D2 (invariant + harness,
:1448-1500) and §8 A.2 (the EXECUTED 2026-08-09 census experiment, :2010-2081); audits
design_docs/kernel-boundary/audit-0*.md; static census callsite-census-self-compile.txt
(17,005 sites / 130 symbols); dynamic census kernel-census-dynamic-stage7a.txt (3.68B calls).

## Goal

Kernel externs whose kernel-opt-07 facts row says `gcAlloc == GcNone && not callsBackIntoElm`
carry `gc-leaf-function` on their LLVM declaration, driven end-to-end through the compiler's
own attribute dict (`eco.gc_leaf` on the `is_kernel` `func.func`) — no C++ name list anywhere —
plus the D2 GCStats audit harness that makes a lying facts row detectable. **Honest
expectation up front: FLAT wall.** This ships for size (−1.01% binary in the 2026-08-09
pilot) and enabling effects (allocation-group merging, longer capacity-hoist runs, CSE/DCE
prerequisites for kernel-opt-09/10/13), not direct wall.

## Files touched

| File | Change |
|---|---|
| `compiler/src/Compiler/Eco/Config.elm` | new `kernelGcLeaf : Bool` field, last in the alias (:34-48), default `False` (:292-339), hash token `kgcl=1` (appended after the `srtf=1` block, :726-731), decoder line last (:346-361) |
| `compiler/src/Builder/Eco/Config.elm` | new `applyKernelGcLeafEmitOverride` (env `ECO_KERNEL_GCLEAF_EMIT`) mirroring `applyListChunksOverride` (:486-511), plus one chain link appended after the last existing one, `ECO_BORROW_OPT` (:260-264) |
| `compiler/src/Compiler/Generate/MLIR/Context.elm` | `KernelDeclInfo` gains `gcLeaf : Bool` (:670-674); `registerKernelCall` passes `False` (:688-694); `registerKernelInstance` computes it from `KernelFacts.lookup ( key.home, key.name )` (:704-718); `insertKernelDecl` OR-merges `gcLeaf` (:724-753); import `Compiler.GlobalOpt.KernelFacts` |
| `compiler/src/Compiler/Generate/MLIR/Functions.elm` | `generateKernelDecl` attr dict (:1995-2008) conditionally inserts `("eco.gc_leaf", UnitAttr)` |
| `runtime/src/codegen/Passes/EcoToLLVMInternal.h` | new `kernelGcLeafEnabled()` env helper (next to `inlineAllocEnabled()`, :769-775); new `attachGcLeafPassthrough()` inline helper in `namespace eco::detail` (:27-1134) |
| `runtime/src/codegen/Passes/EcoToLLVMFunc.cpp` | `KernelFuncOpLowering` (:26-97) stamps on BOTH the fresh-decl path (:83-91) and the dedup early-exit (:44-47) |
| `runtime/src/codegen/Passes/EcoToLLVMRuntime.cpp` | `getOrCreateFunc`'s inline passthrough block (:143-149) refactored onto the shared `attachGcLeafPassthrough` — behaviour-identical, one implementation |
| `design_docs/invariants.csv` | CGEN_072 row (:636) amended (poison-seed clause + new clause (f) + source column); new `KERNEL_FACTS_001` row appended |
| `test/kernel/KernelFactsAuditTest.{cpp,hpp}` | **new** — D2 GCStats allocation-delta harness |
| `test/CMakeLists.txt` | add `kernel/KernelFactsAuditTest.cpp` to `add_executable(test ...)` (after :112) |
| `test/main.cpp` | `#include` (after :42), suite construction (next to :784-785), `suite.add(std::move(...))` (next to :901) |
| `test/codegen/kernel_gcleaf_stamp.mlir` | **new** — FileCheck golden for the backend reflection (auto-discovered, `discoverTests` CodegenIsolatedTest.hpp:292-308) |
| `benchmarks/kernel-opt.md` | census + wall A/B results table |

No new C++ export symbols. (For the record, the full registration list for one — verified on
`elm_array_push_int` — is: definition `elm-kernel-cpp/src/core/JsArrayExports.cpp:745`,
declaration `elm-kernel-cpp/src/KernelExports.h:281`, backend decl
`runtime/src/codegen/Passes/EcoToLLVMRuntime.cpp:1015`, JIT/AOT symbol
`runtime/src/codegen/RuntimeSymbols.cpp:767` `KERNEL_SYM(...)`. This plan adds none of these.)

## Flag & rollback

Two flags on two layers, per the repo rule (compiler emission behind Config.elm; backend
behind an env var). They are deliberately **different names** so an A/B leg can isolate which
half moved:

| Layer | Switch | Default at land | Effect |
|---|---|---|---|
| Compiler emission | `EcoConfig.kernelGcLeaf` (`eco-config.json` `"kernelGcLeaf"`, env `ECO_KERNEL_GCLEAF_EMIT=1\|0`) | **False** | emits/suppresses `eco.gc_leaf` on `func.func` kernel decls. Artifact-affecting → hash token `kgcl=1` appears only when enabled, so flag-on and flag-off `eco-stuff` caches never alias (same posture as `lchunks=1`, Config.elm:677-686) |
| Backend | `ECO_KERNEL_GCLEAF=0` (`kernelGcLeafEnabled()`, EcoToLLVMInternal.h) | **on (honour the attr)** | `=0` makes the backend ignore `eco.gc_leaf` entirely, restoring "ALL kernel externs are poison seeds" **without recompiling the .mlir** — the bisection switch for a suspected lying facts row |

Rollback story, cheapest first: (1) `ECO_KERNEL_GCLEAF=0` on an already-built `.mlir` — pure
backend, no front-end rebuild, restores today's IR exactly; (2) `ECO_KERNEL_GCLEAF_EMIT=0` /
`kernelGcLeaf: false` — the attr is not emitted, the `.mlir` reverts to today's bytes and the
hash token disappears so old caches are reused; (3) revert the commit. Phase 5's default-on
flip is a one-line change to `Config.elm:default` and is separately revertable.

There is **no `ECO_KERNEL_GCLEAF_PILOT`** to retire — see "Anchor drift" in Evidence.

## Evidence

- **Pilot (EXECUTED 2026-08-09, §A.2 / plans/kernel-call-census.md §C2):** 20 audited
  never-GC-alloc kernel decls stamped → gc-free coverage 5.27% → 5.60% of functions
  (2,372 → 2,518 of 44,967); de-statepointed sites 11,149 → 13,078 (+1,929, +17.3%); binary
  65,357,320 → 64,696,496 B (−660,824 B, −1.01%), of which −637,568 B is `.llvm_stackmaps`
  (−2.77%) and only −8,800 B is `.text` — the stackmap section at 23.0 MB is LARGER than the
  entire 22.3 MB `.text`. Wall FLAT on cold Stage 7a (330.87 s vs 330.90 s, interleaved 2×2,
  all four outputs byte-identical) DESPITE the pilot set covering **64.1% of all 3.68B dynamic
  kernel calls** (2,357,005,301, dominated by `Utils_compare`'s 1.95B). Fifth confirmation of
  the metadata-removal-is-flat lesson (preserve-cc, gc-leaf pilot, capacity-hoist, compare phases).
- **ANCHOR DRIFT (the big one): the pilot code is NOT in the tree.**
  `grep -rn KERNEL_GCLEAF /work --include=*.cpp --include=*.h --include=*.hpp --include=*.elm`
  returns **nothing**; the only hits anywhere are markdown (this plan, kernel-call-census.md:246
  which names `EcoToLLVMInternal.h:isPilotGcLeafKernel`, the design doc :2023-2025, and the
  sibling plans 03/07/09 that quote them). `EcoToLLVMInternal.h` has no `isPilotGcLeafKernel`
  and no such env parse (verified 2026-08-10: its env helpers stop at `inlineAllocEnabled()`
  :769-775). The
  design doc's "the env-gated pilot plumbing … is in-tree for the real change to reuse" and
  v1's "promote the pilot" framing are both **stale** — the experiment was reverted after
  measurement. **Consequence: Phase 1 builds the mechanism from scratch** (the design is
  unchanged and the measurement stands; only the "reuse existing code" step disappears, and
  with it the "delete the pilot env" step).
- **6.E seed set (14 declarations, ~2,866 static sites = 16.9% of 17,005):**
  `Utils_{equal,notEqual,compare,lt,le,gt,ge}`, `String_{length,startsWith,endsWith,contains}`,
  `Bytes_{getStringWidth,width,decodeFailure}`. Re-verified anchors (2026-08-10):
  `Utils::equal` Utils.cpp:470 → `eqHelp` :521 → `dictEq` :753 (C++ `std::vector` spine stacks
  at :769-772, no Eco allocation); `Utils::compare` Utils.cpp:451-457 returns one of three
  pre-allocated **rooted** singletons initialised once at :33-46 (`eco_gc_add_value_root`
  :42-44); `Bytes_getStringWidth` BytesExports.cpp:309-366, whose only non-O(1) arm
  materialises a C++ `std::u16string` at **:328-339** (declaration `std::u16string
  snapshot_storage;` :330, materialising `else` arm :335-339 — the design doc's :328-339 is
  CORRECT and has NOT drifted; v1's ":331-340" was wrong);
  `String_length` StringExports.cpp:18-27 → StringOps.hpp:239; `startsWith` StringOps.hpp:688,
  `endsWith` :719, `contains` :645; `StringOps::compare` :1544.
- **Direct effect needs no caller stamping:** `llvm::callsGCLeafFunction` (declared in
  `llvm/Transforms/Utils/Local.h`, included at EcoBackend.cpp:35) is a per-call-site predicate
  that reads the CALLEE's `gc-leaf-function` attr; RS4GC consults it internally to decide not to
  statepoint a call, and CGEN_072's own fixpoint consults the same function at EcoBackend.cpp:1658
  and :1704 (which is exactly why the invariant calls it "RS4GC's OWN per-call-site predicate, so
  the analysis cannot disagree with the pass", invariants.csv:636 clause (a)). So every site loses
  statepoint + roots the moment the declaration is stamped. The *transitive* lift is smaller — callers of
  `Utils_equal` frequently also call `List_cons` (4,158 sites) / `Utils_append` (3,465), both
  genuinely allocating (§A.2 caveat 1).
- **Mechanism precedent, all in-tree and re-verified:** `getOrCreateFunc`'s passthrough block
  (EcoToLLVMRuntime.cpp:143-149); the `Eco_Runtime_getOrderLT/EQ/GT` stamps at
  **:916-930**; `eco_int_pow` at **:904-908**; `eco_order_from_sign` :932-937;
  `eco_string_cmp3` :939-944 — while `getOrCreateUtilsEqual` at **:910-913** deliberately
  omits `gcLeaf` (defaults to `false`, EcoToLLVMInternal.h:502-506). `runEcoBackend` stamps the
  scratch decls by name at EcoBackend.cpp:2511-2515.
- **Attr precedent:** `eco.list_chunks` / `eco.caf_memo` / `eco.shadow_roots` are all emitted
  as `UnitAttr` (Functions.elm:101, :503, :554, :681) and consumed by `funcOp->hasAttr(...)`
  (EcoToLLVM.cpp:212-220). UnitAttr survives both the text writer (Mlir/Pretty.elm:399) and
  the bytecode writer (Mlir/Bytecode/AttrType.elm:484-485, :917-918 — code 7, no payload).
- **The fact actually reaches the decl — the "does this even fire?" check, done.** The saturated
  direct-kernel-call path in `Expr.elm` computes the ABI policy (`KernelAbi.kernelBackendAbiPolicy`
  :4225-4226), and that policy is **unconditionally `ElmDerived`** (`kernelBackendAbiPolicy _ _ =
  ElmDerived`, KernelAbi.elm:78-89), so the single live arm at Expr.elm:4229-4280 runs for EVERY
  saturated kernel call: it builds a `KernelInstanceKey` (:4249-4256) and calls
  `Ctx.registerKernelInstance` at **:4258-4259** — i.e. `(home, name)` IS in scope at the decl
  registration for every stampable call site. `instanceClosureResult` (Expr.elm:904-920, the
  arity>0 kernel-as-value/papCreate path) does the same at :919-920.
  **This is also why the OR-merge in Phase 1c is mandatory, not defensive:** the very next line
  (Expr.elm:4272-4273) calls `Ops.ecoCallNamed`, which re-registers the SAME symbol through the
  legacy `Ctx.registerKernelCall` shim (Ops.elm:663-665, keyed on the `Elm_Kernel_`/`Eco_Kernel_`
  prefix) with no key and therefore `gcLeaf = False`. Without the merge, the second registration
  would land on the "ABI matches ⇒ keep existing" branch and the fact would be silently kept or
  dropped depending on arrival order. With OR-merge it is order-independent. (The other
  `registerKernelCall` callers — Functions.elm:149/159/169, the three `Platform_register*` port
  hooks — legitimately have no facts row and stay unstamped.)

## Approach

### Phase 0 — census baseline (measure before touching anything)

Baseline the two numbers this plan is judged on. `ECO_GCFREE_LEAF=c` is census mode: the
analysis runs, **nothing is stamped**, the module is byte-identical to an off run (mode parse
EcoBackend.cpp:107-119; report EcoBackend.cpp:1718-1725).

```bash
cd /work
# 1. coverage + de-statepointed sites (build-time census; nothing is executed).
#    --emit=obj stops before the link: propagateGcFreeLeafAttrs runs inside
#    runEcoBackend (EcoBackend.cpp:2565-2568), well before RS4GC and codegen, so
#    object emission is enough — and it avoids handing the linker /dev/null.
#    (`--emit` values: exe|obj|llvm|mlir, `eco-boot-native --help`.)
ECO_GCFREE_LEAF=c build/runtime/src/codegen/eco-boot-native \
    build/compiler/build-kernel/bin/eco-compiler.mlir \
    --emit=obj -o /tmp/gcleaf_before.o 2>&1 \
    | tee /tmp/gcleaf_before.txt
grep '^\[gcfree\]' /tmp/gcleaf_before.txt
# expect: [gcfree] <numFree>/<numDefined> functions GC-free, <numSites> direct call sites …

# 2. binary + section sizes of the CURRENT eco-compiler
size -A build/compiler/build-kernel/bin/eco-compiler | grep -E 'llvm_stackmaps|\.text|Total'
stat -c%s build/compiler/build-kernel/bin/eco-compiler
```

Record the `[gcfree] a/b functions GC-free, c direct call sites de-statepointed (mode=census)`
line verbatim, plus `.text` / `.llvm_stackmaps` / total bytes, into `benchmarks/kernel-opt.md`.
Re-confirm the pilot baseline reproduces on current HEAD — the compare-series peephole
(CGEN_075, EcoCompareCaseRewrite) landed *after* the pilot ran and deleted 373 compare sites,
so `numDefined`/`numSites` may legitimately differ from 44,967/11,149.

**Do NOT run `cmake --build build --target full` during census work** — its first step is
`--target clean` (CMakeLists.txt:1113-1120), so `eco-compiler.mlir` is deleted and regenerated
(memory: capacity-check-hoisting outcome). Use `--target eco-compiler` when a rebuild is needed.

*Acceptance:* both numbers recorded; any divergence from 2,372/44,967/11,149 explained by a
landed change, not left unexplained.

### Phase 1 — the durable reflection path (compiler → MLIR → LLVM)

#### 1a. Config flag (compiler/src/Compiler/Eco/Config.elm)

Field, appended as the LAST field of `EcoConfig` (the alias is :34-48; today's last field is
`sretTailFuncs` at :47). Every neighbour (:42-47) puts its whole doc on ONE physical `--` line
however long — keep that shape, shown wrapped here only for readability:

```elm
    , kernelGcLeaf : Bool -- kernel-opt-08 (plans/kernel-opt-08-kernel-gcleaf-stamp.md, CGEN_072(f)/KERNEL_FACTS_001): stamp `eco.gc_leaf` on the func.func decl of every kernel whose KernelFacts row is gcLeafEligible, so the backend may attach gc-leaf-function and RS4GC skips statepointing its call sites. DEFAULT-OFF at land; env ECO_KERNEL_GCLEAF_EMIT=1 enables; artifact-affecting (hash token "kgcl=1")
```

`default` (:292-339) gets `, kernelGcLeaf = False` after `sretTailFuncs = True` (:338);
`decoder` (:346-361) gets
`|> D.apply (D.optionalField "kernelGcLeaf" D.bool default.kernelGcLeaf)` as the LAST line after
:361 (record-constructor order is positional — it must match the field order in the type alias);
`hash` (:540-…) gets the token in the same posture as `aggp=1` (:687-697), appended to the token
chain that currently ends with `srtf=1` (:726-731):

```elm
            -- gc-leaf stamping rewrites the emitted kernel decls, so flag-on artifacts must
            -- never share flag-off caches; explicitly-disabled configs hash exactly like the
            -- historical default-off caches.
            ++ (if cfg.kernelGcLeaf then
                    [ "kgcl=1" ]

                else
                    []
               )
```

#### 1b. Env override (compiler/src/Builder/Eco/Config.elm)

Copy `applyListChunksOverride` (:486-511) verbatim in shape:

```elm
{-| `ECO_KERNEL_GCLEAF_EMIT=1|0`: force kernel gc-leaf attr emission on/off
(plans/kernel-opt-08-kernel-gcleaf-stamp.md; artifact-affecting, hash token
`kgcl=1`). NOTE: this is the FRONT-END switch. The backend's independent kill
switch is `ECO_KERNEL_GCLEAF=0`, which ignores an attr that is already in the
.mlir. Unknown values are ignored.
-}
applyKernelGcLeafEmitOverride : Maybe String -> EcoConfig -> EcoConfig
applyKernelGcLeafEmitOverride maybeVal cfg =
    case maybeVal of
        Nothing -> cfg
        Just raw ->
            let t = String.toLower (String.trim raw) in
            if t == "1" || t == "true" || t == "yes" || t == "on" then
                { cfg | kernelGcLeaf = True }
            else if t == "0" || t == "off" then
                { cfg | kernelGcLeaf = False }
            else
                cfg
```

plus one link in `applyEnvOverrides`' `Task.andThen` chain. The chain is a single pipeline of
`|> Task.andThen (\cfgN -> envLookupEnv "X" |> Task.map (\v -> applyXOverride v cfgN))` links
(`ECO_LIST_CHUNKS` is the one at :220-224); **append the new link after the current last one,
`ECO_BORROW_OPT` at :260-264, with a fresh binder name** (the existing binders are not
sequential — `cfg26` appears twice, :246 and :256 — so do not try to renumber, just pick an
unused name such as `cfgKgcl`).

#### 1c. Carry the fact to the decl (compiler/src/Compiler/Generate/MLIR/Context.elm)

`KernelDeclInfo` (:670-674) today carries **only** `symbolName` — no `(home, name)`. The two
producers differ: `registerKernelCall` (:688-694) is the legacy MLIR-types-only path with no
key; `registerKernelInstance` (:704-718) holds the full
`KernelAbi.KernelInstanceKey { prefix, home, name, argTypes, resultType }` (KernelAbi.elm:113-119).
**Decision: carry a `gcLeaf : Bool` on the record, computed where the key is in scope. Never
reverse-parse the symbol name** — `kernelInstanceSymbol` (KernelAbi.elm:182-407; the suffix arms
start at :199, the unsuffixed fallback is `_ -> rootSymbol` at :406-407) appends
`_Int`/`_Float`/`_Char` suffixes, so name parsing would be wrong for exactly the migrated
kernels. (07 provides `lookupSymbol` for consumers that only hold the symbol; this one does not
need it.)

```elm
type alias KernelDeclInfo =
    { symbolName : String
    , abiArgTypes : List MlirType
    , abiResultType : MlirType
    , gcLeaf : Bool
      -- KernelFacts.gcLeafEligible of the (home, name) row, False when there
      -- is no row. False on the legacy name-only path (whitelist discipline,
      -- §6.F: unlisted ⇒ today's behaviour ⇒ poison seed).
    }
```

```elm
registerKernelCall ctx name callSiteArgTypes callSiteReturnType =
    insertKernelDecl ctx
        { symbolName = name
        , abiArgTypes = callSiteArgTypes
        , abiResultType = callSiteReturnType
        , gcLeaf = False
        }
```

```elm
        info : KernelDeclInfo
        info =
            { symbolName = abi.symbolName
            , abiArgTypes = abi.abiArgTypes
            , abiResultType = abi.abiResultType
            , gcLeaf =
                KernelFacts.lookup ( key.home, key.name )
                    |> Maybe.map KernelFacts.gcLeafEligible
                    |> Maybe.withDefault False
            }
```

`insertKernelDecl`'s ABI-match branch (:730-733) OR-merges instead of dropping the new record:

```elm
        Just existing ->
            if existing.abiArgTypes == info.abiArgTypes && existing.abiResultType == info.abiResultType then
                -- Only registerKernelInstance ever supplies evidence (the legacy shim always
                -- says False), so OR can never overwrite an audited False with a lie.
                if info.gcLeaf && not existing.gcLeaf then
                    { ctx | kernelDecls = Dict.insert info.symbolName { existing | gcLeaf = True } ctx.kernelDecls }
                else
                    ctx
            else
                crash (...)   -- unchanged CGEN_038 message
```

**Exact 07 API (do not guess the shape).** kernel-opt-07 Phase 1 pins
`gcLeafEligible : KernelFacts -> Bool` — it takes the *row*, not the key —
alongside `lookup : ( Name, Name ) -> Maybe KernelFacts`; both are in the module's `exposing`
list. So the call is `lookup key |> Maybe.map gcLeafEligible |> Maybe.withDefault False`, and
the `Nothing ⇒ False` fallback IS the whitelist discipline (an unlisted kernel keeps today's
poison-seed behaviour). Derived contract: `gcLeafEligible = not canTriggerGC` where
`canTriggerGC f = f.gcAlloc /= GcNone || f.callsBackIntoElm`, computed never stored. This plan
consumes only that function — it never reads `gcAlloc`/`callsBackIntoElm` directly and never
keeps a second list.

`Name` is `type alias Name = String` (Data/Name.elm:75-76) and `KernelInstanceKey.home/.name`
are plain `String`s (KernelAbi.elm:113-119), so the key tuple type-checks with no conversion.
The new `import Compiler.GlobalOpt.KernelFacts` into `Generate/MLIR/Context.elm` introduces no
import cycle: `KernelFacts` imports only `Compiler.Data.Name` and `Dict` (07 Phase 1).
`lookupSymbol` is deliberately NOT used here — this path has the key.

#### 1d. Emit the attribute (compiler/src/Compiler/Generate/MLIR/Functions.elm:1995-2008)

```elm
        baseAttrs =
            Dict.fromList
                [ ( "sym_name", StringAttr info.symbolName )
                , ( "sym_visibility", VisibilityAttr Private )
                , ( "is_kernel", BoolAttr True ) -- Mark as kernel for lowering
                , ( "function_type"
                  , TypeAttr (FunctionType { inputs = argMlirTypes, results = [ resultMlirType ] })
                  )
                ]

        -- kernel-opt-08 / CGEN_072(f): the ONE declaration-level gc-leaf channel.
        -- UnitAttr (presence == eligible) matching eco.caf_memo/eco.shadow_roots/
        -- eco.list_chunks, because the C++ side tests hasAttr: a BoolAttr False
        -- would read as "present". kernel-opt-09's module marking pass reads the
        -- SAME attr; there is no second one.
        attrs =
            if ctx.ecoConfig.kernelGcLeaf && info.gcLeaf then
                Dict.insert "eco.gc_leaf" UnitAttr baseAttrs

            else
                baseAttrs
```

`ctx.ecoConfig` already exists (Context.elm:236, installed by `withEcoConfig` :341-343) — no
new import in Functions.elm. This supersedes design-doc §6.C2's `BoolAttr True` sketch (:1325).

#### 1e. Backend kill switch + reflection

**Kill switch** — EcoToLLVMInternal.h, immediately after `inlineAllocEnabled()` (:769-775):

```cpp
/// Kill switch for kernel-declaration gc-leaf stamping
/// (plans/kernel-opt-08-kernel-gcleaf-stamp.md; CGEN_072(f), KERNEL_FACTS_001).
/// Default ON: the backend honours the `eco.gc_leaf` attr the front end emits under
/// config.kernelGcLeaf. `ECO_KERNEL_GCLEAF=0` ignores the attr entirely, restoring the
/// "ALL kernel externs are poison seeds" behaviour WITHOUT recompiling the .mlir — the
/// bisection switch for a suspected lying facts row.
inline bool kernelGcLeafEnabled() {
    static const bool enabled = [] {
        const char *e = ::getenv("ECO_KERNEL_GCLEAF");
        return !(e && e[0] == '0' && e[1] == '\0');
    }();
    return enabled;
}
```

**Shared attach helper** — same header, inside `namespace eco::detail` (:27-1134), so both
`EcoToLLVMFunc.cpp` and `EcoToLLVMRuntime.cpp` see it (both do `using namespace eco::detail;`):

```cpp
/// Append "gc-leaf-function" to a declaration's `passthrough` array, idempotently.
/// This is the ONLY attribute a declaration whose signature carries !eco.value may
/// receive before RS4GC (REP_LLVM_002, invariants.csv:16; policy comment at
/// EcoToLLVMRuntime.cpp:884-891 documents the bisected miscompile class). NEVER add
/// memory(*) / speculatable / willreturn here.
inline void attachGcLeafPassthrough(mlir::OpBuilder &builder,
                                    mlir::LLVM::LLVMFuncOp fn) {
    llvm::SmallVector<mlir::Attribute> attrs;
    if (auto existing = fn->getAttrOfType<mlir::ArrayAttr>("passthrough")) {
        for (mlir::Attribute a : existing) {
            if (auto s = llvm::dyn_cast<mlir::StringAttr>(a))
                if (s.getValue() == "gc-leaf-function")
                    return; // already stamped — idempotent
            attrs.push_back(a);
        }
    }
    attrs.push_back(builder.getStringAttr("gc-leaf-function"));
    fn->setAttr("passthrough", builder.getArrayAttr(attrs));
}
```

**`getOrCreateFunc`** (EcoToLLVMRuntime.cpp:122-154) — replace the hand-rolled block at :143-149
with a call to the shared helper. Behaviour-identical (the existing block does not dedup, but no
caller stamps twice); the point is a single implementation both stamping sites share:

```cpp
    if (gcLeaf)
        attachGcLeafPassthrough(builder, newFunc);
```

**`KernelFuncOpLowering`** (EcoToLLVMFunc.cpp:26-97) — the ONLY place a *kernel* decl is stamped.
Two edits; `ConversionPatternRewriter` *is* an `OpBuilder`, so it is passed straight through.
Stage 0 is **serial** (EcoToLLVM.cpp:253-268 and the conversion at :291-311), so there is no
parallel-mutation hazard here (contrast kernel-opt-09, whose consumer is a nested per-function
pass). `runtime` is a `const EcoRuntime &` (:27) — both edits only read it.

```cpp
        // (a) dedup early-exit, replacing :44-47. If an llvm.func with this name
        // already exists, the func.func stub — the ONLY carrier of eco.gc_leaf — is
        // about to be erased, so stamp the survivor first.
        if (auto existing = runtime.lookupSymbol<LLVM::LLVMFuncOp>(funcOp.getName())) {
            if (kernelGcLeafEnabled() && funcOp->hasAttr("eco.gc_leaf"))
                attachGcLeafPassthrough(rewriter, existing);
            rewriter.eraseOp(funcOp);
            return success();
        }
...
        // (b) after setLinkage at :87, before cacheSymbol at :91
        if (kernelGcLeafEnabled() && funcOp->hasAttr("eco.gc_leaf"))
            attachGcLeafPassthrough(rewriter, llvmFunc);
```

Direct `->setAttr` on a decl (rather than `rewriter.modifyOpInPlace`) matches the tree's own
idiom — the codegen tree uses `modifyOpInPlace`/`updateRootInPlace` nowhere (grepped), and
`getOrCreateFunc` mutates the same way at :148.

**Why NO `EcoRuntime` side map / `getOrCreateFunc` name consult (v2 proposed one; the staging
makes it dead code).** The tempting design — record `is_kernel && eco.gc_leaf` symbols in the
pre-scan (EcoToLLVM.cpp:210-221) and have `getOrCreateFunc` consult that set so a decl
materialized by a body pattern (`getOrCreateUtilsEqual`, EcoToLLVMRuntime.cpp:910-913) is stamped
too — cannot fire, because of the pass order, all in one linear function:

| order | EcoToLLVM.cpp | effect on a kernel symbol |
|---|---|---|
| :210-221 | pre-scan of `func::FuncOp`s | would populate the set FROM the stubs |
| :250 | `lowerAllocGroups` | only creates runtime helpers, never kernels |
| :268-311 | **Stage 0**, `populateEcoFuncPatterns` (its only call site, :295) | `KernelFuncOpLowering` creates + stamps the llvm.func from the stub |
| :322 | `symCache.clear()` | |
| :343 | `materializeAllRuntimeDecls` (EcoToLLVMRuntime.cpp:1211) → `getOrCreateUtilsEqual` (:1262) | `getOrCreateFunc` hits the cache at :133-134 and **returns before the stamp block** |
| :352 → Stage 2 | `freeze()`, then parallel body patterns (`EcoToLLVMControlFlow.cpp:412`) | same cache hit |

So: if a stub exists, Stage 0 already stamped it and every later `getOrCreateFunc` early-returns;
if no stub exists, the set would not contain the name either (it is populated from stubs), so the
consult finds nothing. Dead in both directions — do not build it.

**The residual gap, stated instead of papered over.** A module that synthesizes a kernel call
with *no* front-end stub — string-`case` lowering calling `getOrCreateUtilsEqual` in a module
whose Elm never mentions `Utils.equal` — gets an UNSTAMPED `Elm_Kernel_Utils_equal`. That is the
correct whitelist outcome (no `func.func`, no fact, no stamp) and it costs only missed
opportunity, never soundness. It is one reason the facts-driven Δsites may land below the pilot's
+1,929: the pilot stamped `getOrCreateUtilsEqual` by NAME (`gcLeaf = pilotEnabled()`,
kernel-call-census.md:145-146), which this plan forbids. If a later measurement shows the gap
matters, the fix is front-end-side (make the string-`case` lowering's kernel dependency visible as
a decl), **not** a C++ name list. Note also that EcoToLLVMFunc.cpp:40-43's comment ("created by
string case lowering's getOrCreateUtilsEqual") predates the current staging: with string-case
lowering deferred to Stage 2, the early-exit at :44-47 can now only fire for an `llvm.func`
already present in the input module (hand-written fixtures). Stamping there is cheap insurance,
not the main path.

**Ordering:** all of this happens in EcoToLLVM (MLIR→LLVM conversion), long before
`propagateGcFreeLeafAttrs` is called at EcoBackend.cpp:2565-2568, so the CGEN_072 fixpoint sees
the attrs and can promote whole callers.

**The emitted `.mlir` is BYTECODE, not text — plan your checks accordingly.** Verified on the
current tree: `build/compiler/build-kernel/bin/eco-compiler.mlir` starts with the MLIR bytecode
magic `ML\357R` (`od -c | head -1`), and `grep -ac 'is_kernel'` on it returns **1** — attribute
names live once each in the bytecode string table, so a `grep -c` counts *presence*, never
occurrences. (Bytecode is the default emission since the streaming writer landed;
design_docs/theory/mlir_bytecode_theory.md:5, :156.)

*Acceptance (Phase 1), three checks:*

1. **Presence, cheap:** with the flag on, `grep -ac 'eco.gc_leaf'
   build/compiler/build-kernel/bin/eco-compiler.mlir` is `1`; with the flag off it is `0`.
2. **Count, exact:** re-emit the same module in text form and count. `eco make` takes
   `--text-mlir` ("Output MLIR in text format instead of binary bytecode (for debugging)",
   Terminal/Main.elm:296-298; the E2E harness reaches it via `ECO_TEXT_MLIR`, test/TestSuite.hpp:20-25).
   Run the Stage-7a command with it (from `build/compiler/build-kernel`, mirroring
   compiler/CMakeLists.txt:478-491):
   ```bash
   ECO_KERNEL_GCLEAF_EMIT=1 build/compiler/build-kernel/bin/eco-compiler make --optimize \
       --text-mlir --kernel-package eco/compiler \
       --local-package eco/kernel=/work/eco-kernel-cpp \
       --output=/tmp/s7a-on.mlir /work/compiler/src/Terminal/Main.elm
   grep -c 'eco\.gc_leaf' /tmp/s7a-on.mlir      # == number of stamped kernel decls
   grep -c 'is_kernel' /tmp/s7a-on.mlir          # == total kernel decls; the ratio is the coverage
   ```
   (`ELM_ENTRY` is `compiler/src/Terminal/Main.elm`, compiler/CMakeLists.txt:122.) Cross-check
   that the stamped set equals the `gcLeafEligible` keys of kernel-opt-07's table modulo ABI
   suffixes.
3. **Inertness:** with the flag off, `cmp` the emitted `.mlir` against Phase 0's — byte-identical.

Plus: the `emit=mlir-llvm` golden (Phase 3c) passes.

### Phase 2 — invariant amendments (SAME change, per §6.F R7)

#### 2a. CGEN_072 amendment (design_docs/invariants.csv:636)

The offending text in clause (a) today reads, verbatim:

> `…indirect calls, calls to non-gc-leaf declarations (every boxed eco_alloc_*, eco_alloc_inline_slow, eco_gc_alloc_region_slow, eco_list_tail_hybrid, eco_scratch_finish, dispatch helpers and ALL kernel externs), interposable bodies and EH constructs are all poison.`

As written it forbids exactly this stamping. **Drafted replacement (verbatim, for review):**

> `…indirect calls, calls to non-gc-leaf declarations (every boxed eco_alloc_*, eco_alloc_inline_slow, eco_gc_alloc_region_slow, eco_list_tail_hybrid, eco_scratch_finish, dispatch helpers and every kernel extern that does NOT carry an audited eco.gc_leaf stamp per clause (f)), interposable bodies and EH constructs are all poison.`

plus a new clause appended before the `(e)` gate clause:

> `(f) KERNEL DECLARATION STAMP (plans/kernel-opt-08-kernel-gcleaf-stamp.md, KERNEL_FACTS_001): a kernel extern MAY carry gc-leaf-function iff its Compiler.GlobalOpt.KernelFacts row is gcLeafEligible (gcAlloc == GcNone AND not callsBackIntoElm), reflected as the UNIT attr eco.gc_leaf on the is_kernel func.func (Compiler.Generate.MLIR.Functions generateKernelDecl) and attached as the passthrough string by KernelFuncOpLowering ONLY - on both its fresh-decl path and its dedup early-exit, the two places a kernel func.func stub can die. A kernel decl created without a stub (getOrCreateFunc from a body pattern) carries no fact and is NOT stamped. This is the ONE attr; kernel-opt-09's EcoGCPrepare relaxation reads the same one via a module-level marking pass. Emission is gated by config.kernelGcLeaf (hash token kgcl=1); the backend kill switch is ECO_KERNEL_GCLEAF=0, which ignores the attr without recompiling the .mlir. NO OTHER LLVM attribute may be added to a kernel declaration before RS4GC (REP_LLVM_002). Unlike clause (c)'s stamped DEFINED functions, a stamped DECLARATION has no body and therefore no structural assert can check it - the KernelFacts audit harness (test/kernel/KernelFactsAuditTest.cpp, zero allocation-count delta over all three per-thread GCStats objects) is the enforcement, and it is not optional.`

(Written with ASCII hyphens rather than em dashes, matching every existing row.)

Source column gains `Passes/EcoToLLVMFunc.cpp|Compiler.Generate.MLIR.Functions|KERNEL_FACTS_001`.

#### 2b. KERNEL_FACTS_001 row

Append kernel-opt-07 Phase 4's reviewed draft (design doc §6.D1, :1451) **unchanged except**
for the harness sentence, which must name the real path: `test/kernel/KernelFactsAuditTest.cpp`
(the design doc's `elm-kernel-cpp/test/kernel_facts_audit.cpp` does not exist — `elm-kernel-cpp/`
has no `test/` directory at all; C++ tests live in `/work/test`). Status `enforced` once
Phase 3's harness is green; `proposed` is not acceptable for a shipping soundness claim.

*Acceptance:* both rows present and each is exactly ONE line (`grep -c '^CGEN_072;'` and
`grep -c '^KERNEL_FACTS_001;'` both `1`; `awk -F';' '/^CGEN_072;/{print NF}'` still prints a
number — it is 8 today, not 6, because clause (e) already contains two semicolons). **The file is
grep-oriented, not field-parsed** (nothing in the build reads it: the only in-tree references are
Elm doc comments), so a `;` inside the description is normal and harmless — CGEN_073/074/075 all
have them. The real integrity rules are: one physical line per row, no embedded newline, and the
LAST `;` separates the description from the `|`-separated source column. Do not "fix" the field
count. (This corrects v1, which claimed 6 columns and an unescaped `;` silently corrupts the row;
kernel-opt-07 Phase 6 records the same finding.)

### Phase 3 — D2 GCStats audit harness (SAME change)

#### 3a. Where it lives and how it registers

New `test/kernel/KernelFactsAuditTest.{cpp,hpp}`, mirroring `test/kernel/KernelExportsTest.hpp`
(:1-16 — include guard, `#include "../TestSuite.hpp"`, one `void register…(Testing::TestSuite&)`
declaration) and its `.cpp` tail (`registerKernelExportsTests`, KernelExportsTest.cpp:449-463,
one `suite.add(Testing::UnitTest("K<n> …", fn));` per case). `Testing::UnitTest(std::string,
std::function<void()>)` is TestSuite.hpp:308-311; `TestSuite::add(UnitTest)` is :377-379. Three
registration points, verified against how `KernelExports` is wired:

1. `test/CMakeLists.txt` — add `kernel/KernelFactsAuditTest.cpp` to `add_executable(test …)`
   (:82-113) right after `kernel/KernelExportsTest.cpp` (:112).
2. `test/main.cpp` — `#include "kernel/KernelFactsAuditTest.hpp"` after :42.
3. `test/main.cpp` — next to the `KernelExports` block (comment :783, construction+register
   :784-785):
   `Testing::TestSuite kernelFactsAuditTests("KernelFactsAudit");`
   `registerKernelFactsAuditTests(kernelFactsAuditTests);`
   and `suite.add(std::move(kernelFactsAuditTests));` next to :901 (the `suite.add` block is
   :883-917 — the suite is only *registered* there, so missing this line means the tests build
   and silently never run).

`TEST_FILTER=KernelFactsAudit` reaches the binary as `--filter` through both `check` (:1082) and
`full` (CMakeLists.txt:1117); the suite name string above is what it matches.

Stats availability: `ENABLE_GC_STATS` is ON for every non-Release build
(CMakeLists.txt:107-116 — `option(ECO_GC_STATS … ON)` unless `CMAKE_BUILD_TYPE STREQUAL
"Release"`), i.e. both the `build` preset (RelWithDebInfo, CMakePresets.json:33) and `dev`
(Debug, :17); only the `release` preset (:109) turns it off. So the harness runs under the
standard `--target full`, not only a special build. The macro is always *defined* (as `1` or
`0`, :113/:115), so guard the bodies with `#if ENABLE_GC_STATS` — not `#ifdef` — and register a
single skipped placeholder otherwise. `Allocator::getCombinedStats` itself only exists under
that guard (Allocator.cpp:905-934).

#### 3b. The harness itself

```cpp
// test/kernel/KernelFactsAuditTest.cpp
// D2 harness (design_docs/kernel-boundary-reduction.md §6.D2; KERNEL_FACTS_001):
// every KernelFacts row claiming gcAlloc == GcNone must allocate ZERO objects on the
// Eco heap over representative AND adversarial inputs. A lying row is silent heap
// corruption (un-statepointed call + nursery move beneath it), and no structural
// assert can catch it — a declaration has no body. This test IS the enforcement.
#include "KernelFactsAuditTest.hpp"
#include "../../runtime/src/allocator/Allocator.hpp"
#include "../../runtime/src/allocator/Heap.hpp"
#include "../../runtime/src/allocator/HeapHelpers.hpp"
#include "../../runtime/src/allocator/StringOps.hpp"
#include "../../runtime/src/allocator/ListOps.hpp"
#include "../../runtime/src/allocator/BytesOps.hpp"
#include "../../runtime/src/allocator/RuntimeExports.h"
#include "../../elm-kernel-cpp/src/KernelExports.h"
#include "../allocator/TestHelpers.hpp"   // TEST_ASSERT :13, TEST_FAIL :21, initAllocator :36
#include "../TestSuite.hpp"
#include <cstdio>
#include <string>
#include <vector>

using namespace Elm;
using namespace Elm::TestHelpers;   // TestHelpers.hpp:207 already does this globally

namespace {

#if ENABLE_GC_STATS
// THREE GCStats objects exist per thread heap, not two:
//   NurserySpace::stats        field NurserySpace.hpp:136,   getStats() :71-72,
//                              bumped via GC_STATS_MINOR_RECORD_ALLOC -> recordAllocation
//                              (GCStats.cpp:374-375) at NurserySpace.cpp:182
//   OldGenSpace::alloc_stats_  field OldGenSpace.hpp:410,    getStats() :371-372,
//                              GC_STATS_OLDGEN_DIRECT_RECORD_ALLOC at OldGenSpace.cpp:4206
//                              (+ GC_STATS_OLDGEN_RECORD_ALLOC at :619)
//   ThreadLocalHeap::stats_    field ThreadLocalHeap.hpp:212, getStats() :199-200,
//                              the large-object / direct-oldgen paths at
//                              ThreadLocalHeap.cpp:325,343,371,466
// recordOldGenDirectAllocation bumps objects_allocated at GCStats.cpp:513-514.
// Allocator::getCombinedStats (Allocator.cpp:907-933, itself #if ENABLE_GC_STATS) sums all
// three (:917-919, over accumulated_stats_ of dead thread heaps too; combine() adds
// objects_allocated at GCStats.cpp:727) — we assert on the combined delta AND on each
// object separately, so a future regression in combine() cannot hide an allocation.
struct AllocSnapshot {
    uint64_t combined = 0, nursery = 0, oldgen = 0, tlh = 0, bytes = 0;
};

AllocSnapshot snapshot(Allocator& a) {
    AllocSnapshot s;
    GCStats c = a.getCombinedStats();
    s.combined = c.objects_allocated;
    s.bytes    = c.bytes_allocated;
    // AllocatorTestAccess::getThreadHeap: Allocator.hpp:512-514, used the same way at
    // test/allocator/EnsureHeadroomTest.cpp:120. getNursery()/getOldGen():
    // ThreadLocalHeap.hpp:157/:160.
    ThreadLocalHeap* h = AllocatorTestAccess::getThreadHeap(a);
    TEST_ASSERT(h != nullptr);
    s.nursery = h->getNursery().getStats().objects_allocated;
    s.oldgen  = h->getOldGen().getStats().objects_allocated;
    s.tlh     = h->getStats().objects_allocated;
    return s;
}

void assertNoAlloc(const char* symbol, const AllocSnapshot& b, const AllocSnapshot& a) {
    if (a.combined == b.combined && a.nursery == b.nursery &&
        a.oldgen == b.oldgen && a.tlh == b.tlh && a.bytes == b.bytes)
        return;
    fprintf(stderr,
            "[kernel-facts] %s claims gcAlloc=GcNone but allocated: "
            "combined +%llu (%llu B), nursery +%llu, oldgen +%llu, tlh +%llu\n",
            symbol, (unsigned long long)(a.combined - b.combined),
            (unsigned long long)(a.bytes - b.bytes),
            (unsigned long long)(a.nursery - b.nursery),
            (unsigned long long)(a.oldgen - b.oldgen),
            (unsigned long long)(a.tlh - b.tlh));
    TEST_FAIL(std::string("GcNone kernel allocated on the GC heap: ") + symbol);
}
#endif

// ---- adversarial corpus ---------------------------------------------------
// Built ONCE per case, BEFORE the snapshot is taken — construction allocates and may GC,
// so every member is stack-rooted (StackRootGuard, HeapHelpers.hpp:111; the GCPressureTest
// idiom at GCPressureTest.cpp:304). The kernels under test are then driven against the
// already-built values, so the measured delta is the kernel's alone.
// The three UTF-8 string FORMS are selected by alloc::allocStringFromUTF8 (HeapHelpers.hpp:512):
// empty -> embedded constant (:513-515); all-ASCII -> StringOps::tryMakeAsciiString (:527),
// which yields Tag_StringUtf8Leaf for a SHORT payload and Tag_StringUtf8View (ByteBuffer +
// zero-copy view) once the payload reaches the large-object threshold; anything else falls
// through to the legacy UTF-16 transcode (Tag_String). The threshold is LOT, NOT 32 — the
// in-tree golden uses "hello world" for the leaf and std::string(9000,'a') for the view
// (Utf8StringTest.cpp:326-335). Getting this wrong silently drops the view form from the corpus.
struct Corpus {
    HPointer utf16Leaf;   // alloc::allocString(u"…")            StringOpsTest.cpp:18-21
    HPointer utf8Leaf;    // allocStringFromUTF8("hello world")  Tag_StringUtf8Leaf, Utf8StringTest.cpp:327-328
    HPointer utf8View;    // allocStringFromUTF8(std::string(9000,'a'))
                          //                                     Tag_StringUtf8View, Utf8StringTest.cpp:332-335
    HPointer nonAscii;    // allocStringFromUTF8("caf\xC3\xA9")  Tag_String, Utf8StringTest.cpp:340-341
    HPointer astral;      // surrogate pair                      KernelExportsTest.cpp:99-111
    HPointer rope;        // StringOps::append over FLATTEN_LIMIT -> Tag_StringRope
                          //                                     StringOpsTest.cpp:478-493
    HPointer slice;       // StringOps::slice(baseObj, 1000, 11000) -> Tag_StringSlice
                          // NOTE: slice/append take a RESOLVED void*, not an HPointer
                          //                                     StringOpsTest.cpp:366-372
    HPointer emptyStr;    // embedded constant (alloc::isConstant true)  Utf8StringTest.cpp:350
    HPointer chunkList;   // listBacking + consChunkView + listNil  ChunkedListTest.cpp:25-31
    HPointer mixedSpine;  // cells consed onto a chunk             ChunkedListTest.cpp:58-80
    HPointer deepDictA;   // RBNode chain, depth 12
    HPointer deepDictB;   // structurally equal twin (forces dictEq's full walk)
};

// Dict construction mirrors the in-tree precedent buildHeadersDict,
// elm-kernel-cpp/src/http/HttpExports.cpp:169-199: alloc::custom(CTOR_DICT_RBNODE, fields, 0)
// with fields = [colour(unit), key, value, left, right] (:188-195) and rbEmpty() = custom(
// CTOR_DICT_RBEMPTY, {}, 0) (:164-167). Utils.cpp's dictEq reads left at values[3]
// (Utils.cpp:769-772; the field map is documented at :747-748) and the ctor ids are
// pinned at Utils.cpp:58-59 (RBNODE 0xFFFF, RBEMPTY 0xFFFE).
HPointer buildDeepDict(int depth);

Corpus buildCorpus(Allocator& alloc);   // each step wrapped in StackRootGuard

// ---- drivers --------------------------------------------------------------
// The exports take HPtr, the corpus holds HPointer; bridge with
// HPtr::fromHPointer / ::toHPointer, the idiom used throughout KernelExportsTest.cpp
// (:33-47, :120-121). Each driver hits EVERY corpus member and every cross pair,
// because the allocation risk lives in the representation-mismatch arms.
void runUtilsEqual(const Corpus& c) {
    const HPointer all[] = {c.utf16Leaf, c.utf8Leaf, c.utf8View, c.nonAscii, c.astral,
                            c.rope, c.slice, c.emptyStr, c.chunkList, c.mixedSpine,
                            c.deepDictA, c.deepDictB};
    for (HPointer a : all)
        for (HPointer b : all) {
            HPtr r = Elm_Kernel_Utils_equal(HPtr::fromHPointer(a), HPtr::fromHPointer(b));
            (void)r;   // boxed Bool is an embedded constant — no allocation expected
        }
}
// runUtilsCompare / runUtilsLt / … are the same shape; runStringLength and the
// Bytes_* drivers take one operand. runUtilsEqualInt / runUtilsCompareFloat take
// unboxed scalars (UtilsExports.cpp:136-146, :74) and need no corpus.

// ---- the claim table ------------------------------------------------------
// One row per GcNone claim in KernelFacts.elm, hand-synced. KERNEL_FACTS_001 makes drift
// a review item; `evidence` must equal the row's evidence string so a reviewer can diff
// the two tables by eye. `run` drives the kernel over the whole corpus.
struct NoAllocClaim {
    const char* symbol;
    const char* evidence;
    void (*run)(const Corpus&);
};

const NoAllocClaim kClaims[] = {
    {"Elm_Kernel_Utils_equal",            "elm-kernel-cpp/src/core/Utils.cpp:470,521,753", runUtilsEqual},
    {"Elm_Kernel_Utils_notEqual",         "elm-kernel-cpp/src/core/UtilsExports.cpp:111",  runUtilsNotEqual},
    {"Elm_Kernel_Utils_compare",          "elm-kernel-cpp/src/core/Utils.cpp:451-457",     runUtilsCompare},
    {"Elm_Kernel_Utils_lt",               "elm-kernel-cpp/src/core/UtilsExports.cpp:115",  runUtilsLt},
    // … le / gt / ge, String_{length,startsWith,endsWith,contains},
    //   Bytes_{getStringWidth,width,decodeFailure} …
    // Per-instance suffixed variants share the (home,name) facts row and are therefore
    // stamped by the SAME row — they must appear here too:
    {"Elm_Kernel_Utils_equal_Int",        "elm-kernel-cpp/src/core/UtilsExports.cpp:136",  runUtilsEqualInt},
    {"Elm_Kernel_Utils_compare_Float",    "elm-kernel-cpp/src/core/UtilsExports.cpp:74",   runUtilsCompareFloat},
};

void test_gcnone_rows_allocate_nothing() {
#if ENABLE_GC_STATS
    for (const NoAllocClaim& c : kClaims) {
        auto& alloc = initAllocator();           // TestHelpers.hpp:36 — resets the heap
        Corpus corpus = buildCorpus(alloc);
        AllocSnapshot before = snapshot(alloc);
        c.run(corpus);
        AllocSnapshot after = snapshot(alloc);
        assertNoAlloc(c.symbol, before, after);
    }
#endif
}

}  // namespace

void registerKernelFactsAuditTests(Testing::TestSuite& suite) {
    suite.add(Testing::UnitTest("KF1 GcNone rows allocate nothing (all 3 GCStats objects)",
                                test_gcnone_rows_allocate_nothing));
}
```

Notes that are load-bearing, not decoration:

- **Allocation COUNT, not GC count.** A nursery with headroom absorbs allocations without
  collecting, so a zero `minor_gc_count` delta proves nothing; a zero `objects_allocated`
  delta does.
- **The HEAP_034 blind spot does not apply.** `tlh_alloc_count_by_tag` (GCStats.hpp:211,
  fed from `initHeaderForTag` at ThreadLocalHeap.cpp:134) and the nursery counter are bypassed
  by the *inline* bump — but that fast path is **generated-code only**. The harness calls
  kernels from C++, so every kernel-internal allocation goes through `NurserySpace::allocate`
  (:171-192) and is counted exactly. No `ECO_INLINE_ALLOC=0` needed.
- **`cppAlloc` is not a disqualifier.** `Bytes_getStringWidth` is GcNone *and* `cppAlloc`
  because its slice/rope arm materialises a `std::u16string` (BytesExports.cpp:328-339;
  the `else` arm that calls `toStdU16String` is :335-339) —
  C++-heap use is irrelevant to gc-leaf. The corpus must include exactly those forms
  (`rope`, `slice`) or the row is untested where it is least obvious.
- **The `Utils_equal` stderr trace** (Utils.cpp:557-562, deleted by kernel-opt-07 Phase 2) is a
  side effect but **not** a GC hazard. The harness must not treat stderr output as failure.
- **Coverage is input-dependent by construction.** The harness proves *presence* of
  allocation, never absence — it is the second line of defence behind the human audit, and its
  job is catching rot (someone adds an `alloc::` call to `StringOps::compare`).

#### 3c. Backend golden test

New auto-discovered `test/codegen/kernel_gcleaf_stamp.mlir` (discovery: `discoverTests`,
CodegenIsolatedTest.hpp:292-308 — `directory_iterator` over `*.mlir`, name becomes
`codegen/<filename>` at :372-376, which is what `TEST_FILTER` matches). The emit mode is read
off the `// RUN:` line by `parseEmitMode` (:88-113) and the file is run as
`ecoc <path> -emit=mlir-llvm` with **no per-test env** (`runSubprocessTest` :237-255) — so this
fixture pins the BACKEND half only, and it is valid while `EcoConfig.kernelGcLeaf` is still
default-off (hand-written input, front end not involved). `CHECK`/`CHECK-NOT` are matched by
`eco_test::verifyPatterns` (test/CheckPatterns.hpp:363-391): `{{…}}` is honoured as a regex
(:112-145) and `CHECK-NOT` is evaluated against the WHOLE output (:368-372), with `.` not
crossing newlines, so both patterns below are effectively same-line assertions on the decl.

```mlir
// RUN: %ecoc %s -emit=mlir-llvm 2>&1 | %FileCheck %s
//
// kernel-opt-08 / CGEN_072(f): a kernel decl carrying eco.gc_leaf gets
// passthrough = ["gc-leaf-function"]; one without it gets nothing. Unit-attr
// syntax matches the eco.caf_memo goldens (caf_memo_constant.mlir:15); the
// bodyless kernel decl with named args matches
// compare_case_rewrite_structural.mlir:13. eco.call has NO custom assembly
// format (Ops.td:1129 defines no assemblyFormat), so the GENERIC form is
// mandatory — every fixture in test/codegen uses it.
//
// @use exists because EcoToLLVM strips external llvm.funcs that no op uses
// (EcoToLLVM.cpp:591-604); an uncalled kernel decl would simply vanish and
// the CHECK below would fail for the wrong reason.
module {
  func.func private @Elm_Kernel_String_length(%s: !eco.value) -> i64
      attributes {is_kernel = true, eco.gc_leaf}
  func.func private @Elm_Kernel_List_cons(%h: !eco.value, %t: !eco.value) -> !eco.value
      attributes {is_kernel = true}
  func.func private @use(%s: !eco.value, %t: !eco.value) -> i64 {
    %n = "eco.call"(%s) {callee = @Elm_Kernel_String_length} : (!eco.value) -> i64
    %c = "eco.call"(%s, %t) {callee = @Elm_Kernel_List_cons}
        : (!eco.value, !eco.value) -> !eco.value
    eco.return %n : i64
  }
  // CHECK: llvm.func @Elm_Kernel_String_length{{.*}}gc-leaf-function
  // CHECK-NOT: llvm.func @Elm_Kernel_List_cons{{.*}}gc-leaf-function
}
```

Sanity-check the fixture by hand before committing it —
`build/runtime/src/codegen/ecoc test/codegen/kernel_gcleaf_stamp.mlir -emit=mlir-llvm | grep
'llvm.func @Elm_Kernel'` — and confirm the decl line really does print `passthrough =
["gc-leaf-function"]` inline; if MLIR ever wraps that dict onto its own line the `{{.*}}` join
must become a `CHECK-SAME`/`CHECK-NEXT` pair (both supported, CheckPatterns.hpp:14-21).

*Acceptance (Phase 3):* `TEST_FILTER=KernelFactsAudit cmake --build build --target full` green;
`TEST_FILTER=kernel_gcleaf cmake --build build --target full` green; deliberately flipping one
`GcNone` row to a kernel that *does* allocate (e.g. `Utils_append`) makes KF1 FAIL — run this
negative control once and record it, or the harness is unproven.

### Phase 4 — census after, and the decision point

**Getting a flag-on `.mlir` and binary (the step v2 left implicit).** Ninja is env-blind, so
setting `ECO_KERNEL_GCLEAF_EMIT=1` alone re-runs nothing: apply the delete-outputs discipline
the backend already documents for census/A-B work (EcoBackend.cpp:99-100). The `kgcl=1` hash
token keeps the flag-on `eco-stuff` cache separate from the flag-off one, so no manual cache
nuke is needed:

```bash
cd /work
rm -f build/compiler/build-kernel/bin/eco-compiler.mlir \
      build/compiler/build-kernel/bin/eco-compiler
ECO_KERNEL_GCLEAF_EMIT=1 cmake --build build --target eco-compiler 2>&1 \
  | tee /tmp/gcleaf_build_on.txt        # Stage 5 (bin/eco-compiler.mlir) + Stage 6 (ELF)
grep -ac 'eco.gc_leaf' build/compiler/build-kernel/bin/eco-compiler.mlir   # expect 1
```

`--target eco-compiler` is the right target (compiler/CMakeLists.txt:464) — **not**
`--target full`, which deletes the `.mlir` the census reads. Then re-run Phase 0's two commands
against the new `.mlir`/ELF (using `/tmp/gcleaf_after.{o,txt}`), and record:

| Metric | Source | Pilot reference |
|---|---|---|
| functions GC-free | `[gcfree] a/b` | 2,372 → 2,518 (+146) |
| de-statepointed sites | `[gcfree] … c direct call sites` | 11,149 → 13,078 (+1,929) |
| binary bytes | `stat -c%s` | −660,824 (−1.01%) |
| `.llvm_stackmaps` | `size -A` | −637,568 (−2.77%) |

Optionally dump the GC-free set for diffing: `ECO_GCFREE_LEAF_DUMP=/tmp/gcfree_after.txt`
(EcoBackend.cpp:1708-1712) on both legs, then `comm -13` the sorted files.

**Decision point — pilot parity. The answer is already known to be "no", so decide it here
rather than discovering it.** The 20-declaration pilot set (kernel-call-census.md §C2.1,
:117-132) is NOT a subset of kernel-opt-07's seed table:

| pilot symbol(s) | 07's seed table (Phase 3) | class |
|---|---|---|
| `Utils_{equal,notEqual,compare,lt,le,gt,ge}` (7) | A1, `gcAlloc = GcNone` | ✅ stamped |
| `String_{length,startsWith,endsWith,contains}` (4) | A1, `GcNone` | ✅ stamped |
| `Bytes_getStringWidth`, `Bytes_width` (2) | A1, `GcNone` | ✅ stamped |
| `JsArray_length` (1) | class **B** borrow-legacy row, built from `unaudited` ⇒ `GcUnbounded` | ❌ not eligible |
| `Char_{toCode,fromCode,toLower,toUpper,toLocaleLower,toLocaleUpper}` (6) | **no row at all** | ❌ not eligible |

and 07 adds one the pilot lacked (`Bytes_decodeFailure`, A1 — PAP-only, invisible to the static
census, kernel-call-census.md:240-241). So the facts-driven set is the **A1 14**, versus the
pilot's 20: **13 shared, 7 pilot-only, 1 facts-only.** Expect Δsites BELOW +1,929, and quantify
the gap rather than treating it as a regression.

Criterion, then, is not ⊇ but: *every pilot symbol not stamped is accounted for by one of these
four causes, and nothing else is missing.*

- **(i) Row absent → kernel-opt-07 seeding gap.** This is the `Char_*` six. Either add the six
  rows to `KernelFacts.elm` with their C++ evidence anchor (`Char.cpp:76-140` per §C2.1, to be
  re-verified) plus a harness claim each, and re-run; or record the deliberate shortfall. Adding
  them is a kernel-opt-07 table change with its own D3 review — do NOT hand-add a name here.
- **(ii) Row present but not eligible.** This is `JsArray_length`: a class-B row whose C++ body
  has not been re-read for effects, so it is `GcUnbounded` by construction, not by evidence.
  Promoting it to class A is a 07 change (evidence: `JsArrayExports.cpp:204`); until then the
  audited table wins over the pilot's hand-written list and the shortfall is recorded.
- **(iii) The symbol never reaches `registerKernelInstance`** → the fact is dropped at
  Context.elm:688-694. Phase 1's Evidence shows the saturated-call path DOES go through
  `registerKernelInstance` (Expr.elm:4258-4259) under the unconditional `ElmDerived` policy, so
  this cause should be empty; if the census says otherwise, that finding is more important than
  the number. Port the call site rather than reverse-parsing the symbol name.
- **(iv) No `func.func` stub** → the Phase-1e residual gap (`getOrCreateUtilsEqual` in a module
  whose Elm never mentions `Utils.equal`). Visible as a *site*-count shortfall with no missing
  declaration; record it, do not "fix" it with a C++ name list.

Whatever the numbers, they are shippable; what is NOT shippable is an unexplained omission.
Record the resulting set difference in this file and in kernel-call-census.md §C2.1.

### Phase 5 — default-on flip + full gate battery

Flip `Config.elm:default` to `kernelGcLeaf = True` (one line), following the CGEN_072(e) /
CGEN_074 precedent of "DEFAULT-ON since <date>, env `=0` is the escape hatch". Then run the
gates in the Gates section. **Note the bootstrap gate changes shape here:** with the flag on,
Stage 7a's own output `.mlir` legitimately gains `eco.gc_leaf` attrs, so byte-identity against
the *old* fixed point is expected to break. The gate becomes **convergence to a NEW fixed
point** (Stage 8c: `eco-compiler-boot.mlir == eco-compiler-boot-2.mlir`,
compiler/CMakeLists.txt:547-584 — note :576 compares the two `.mlir` files, :584 the two ELFs).
Byte-identity against the old fixed point is still required in the *flag-off* configuration —
that is the inertness gate.

**Inspecting the flag-on vs flag-off difference requires `--text-mlir`.** Both fixed-point
artifacts are MLIR *bytecode* (Phase 1 acceptance), so `diff` on them says only "differ". To
show the delta really is nothing but the attr, emit BOTH arms in text and diff those:

```bash
for arm in off on; do
  env $( [ $arm = on ] && echo ECO_KERNEL_GCLEAF_EMIT=1 || echo ECO_KERNEL_GCLEAF_EMIT=0 ) \
    build/compiler/build-kernel/bin/eco-compiler make --optimize --text-mlir \
      --kernel-package eco/compiler --local-package eco/kernel=/work/eco-kernel-cpp \
      --output=/tmp/s7a-$arm.mlir /work/compiler/src/Terminal/Main.elm
done
diff /tmp/s7a-off.mlir /tmp/s7a-on.mlir | grep -v 'eco\.gc_leaf' | head
# expect: EMPTY (every differing line is a kernel decl gaining the attr)
```

(Run each arm from `build/compiler/build-kernel` if relative package paths matter; the flag-on
arm must be built by a flag-on compiler binary for the *emission* to differ — the env is read by
`Builder.Eco.Config.applyEnvOverrides` in the running compiler, so one binary suffices.)

*Acceptance:* all gates green; census deltas and wall A/B recorded in `benchmarks/kernel-opt.md`.

### Phase 6 — hand-off notes for the spine

- kernel-opt-09 consumes **this same** `eco.gc_leaf` attr. Its module-level marking pass
  (`EcoMarkGCLeafCalls`, inserted immediately before `createEcoGCPreparePass()` at
  EcoPipeline.cpp:99) reads the `func.func` decls and stamps a call-local `eco.callee_gc_leaf`
  unit attr on each `eco.call`; both of 09's consumers then read only that call-local bit.
  The reason is the *mirror* consumer, not EcoGCPrepare itself: `EcoGCPreparePass` is
  `OperationPass<ModuleOp>` (EcoGCPrepare.cpp:146-147), but `EcoGCLivenessAuditPass` — which
  must agree with it exactly — is `OperationPass<func::FuncOp>` run via `addNestedPass`
  (EcoGCLivenessAudit.cpp:31-32, EcoPipeline.cpp:101) and therefore must never resolve a callee
  symbol. Nothing in 09 re-derives the fact. There is no `eco.kernel_cannot_gc`.
- kernel-opt-12's `eco.cse_safe` per-call attr is a **separate** Elm-level CSE channel with
  merge-only semantics; it is not this attr, does not replace it, and never licenses motion
  after EcoGCPrepare.
- Second-order effects unlocked, both already coded and merely starved of leaf callees:
  stamped kernels stop breaking capacity-hoist runs (EcoBackend.cpp:2153-2155 — leaf calls are
  "transparent", non-leaf calls `flushRun()`) and stop ⊤-poisoning coverability
  (EcoBackend.cpp:1889). Measure the run-length change with `ECO_ALLOC_HOIST=c` before/after
  if a follow-up wants to claim it.

## Traps & risks

- **The soundness wall (pre-RS4GC):** `gc-leaf-function` is the ONLY attribute a declaration
  touching GC values may carry (REP_LLVM_002, invariants.csv:16; policy comment
  EcoToLLVMRuntime.cpp:884-891 documents the bisected miscompile class). NEVER
  `memory(none)`/`speculatable`/`willreturn` — motion attrs let pre-RS4GC passes move calls
  across statepoint boundaries. The `eco_bump_state` full-motion-set exception
  (EcoBackend.cpp:1005-1020) applies only because its signature is `() -> ptr` addrspace(0) and
  no GC value flows through it.
- **A lying gc-leaf declaration is silent heap corruption:** un-statepointed call + nursery
  move beneath it = use-after-move, and NO structural assert catches it — CGEN_072(c)'s
  hard-fail checks stamped DEFINED functions only; a declaration has no body. This is why the
  Phase 3 harness lands in the same change and why KERNEL_FACTS_001 names it as enforcement.
- **The stub is the only carrier — two ways it can die.** (1) `KernelFuncOpLowering`'s early-exit
  (EcoToLLVMFunc.cpp:44-47) erases the stub when an LLVM decl with that name already exists,
  dropping the attr on the floor; Phase 1e stamps the survivor first. (2) A module that
  *synthesizes* a kernel call with no kernel decl (string-`case` lowering →
  `getOrCreateUtilsEqual`, EcoToLLVMRuntime.cpp:910-913) has no stub at all, so there is no fact
  and no stamp — accepted, documented in Phase 1e as the residual gap. **Do NOT "fix" (2) with an
  `EcoRuntime` name set consulted by `getOrCreateFunc`:** the Phase-1e ordering table shows it
  can never fire (a set populated from stubs plus a `getOrCreateFunc` that early-returns at
  :133-134 on any already-created decl), and the only alternative — passing `gcLeaf=true` at
  `getOrCreateUtilsEqual` — is the C++ name list this plan exists to abolish.
- **gc-leaf does NOT imply bump-state-transparent (CGEN_074):** a headroom-consuming leaf call
  still voids a hoisted run (`isHeadroomBreaker`, EcoBackend.cpp:1741-1750). Only
  zero-Eco-alloc kernels may carry the bit — the 6.E set satisfies this (never touches
  `NurseryBump{ptr,end}`); a kernel allocating via ANY fast path must never get it.
- **Per-instance suffixes share one facts row.** `Elm_Kernel_Utils_equal_Int` and friends
  (KernelAbi.elm:182-407, UtilsExports.cpp:136-146) are keyed `(home, name)` in KernelFacts, so
  the base row stamps every suffixed symbol. That is sound today (the primitive variants are
  strictly simpler than the boxed one) but it is an **audit obligation, not a theorem** — the
  harness table must list the suffixed symbols explicitly (Phase 3b), and if a future variant
  ever diverges, KernelFacts needs a suffix-aware key rather than a silent override here.
- **Harness assertion granularity:** allocation COUNT, not GC count; and **three** GCStats
  objects, not two — nursery (field NurserySpace.hpp:136, accessor :71-72), old-gen (field
  OldGenSpace.hpp:410, accessor :371-372) and ThreadLocalHeap (field ThreadLocalHeap.hpp:212,
  accessor :199-200). The design doc §D2 sketch says "check both"; that undercounts.
  `getCombinedStats` sums all three (Allocator.cpp:917-919) — assert on the sum *and* on each.
- **Corpus construction must be rooted.** Building the adversarial values allocates and can
  trigger a minor GC mid-build; every intermediate needs `StackRootGuard`
  (runtime/src/allocator/HeapHelpers.hpp:111-155, ctors for 1–4 pointers plus an
  `initializer_list` overload at :140; precedents elm-kernel-cpp/src/http/HttpExports.cpp:174-198,
  test/allocator/GCPressureTest.cpp:304 — and ChunkedListTest.cpp:68-77, which uses the raw
  `RootSet::stackRangePoint`/`pushStackRootRange`/`restoreStackRangePoint` form the guard wraps).
  An unrooted snapshot is exactly the List.mapN stale-cursor bug class.
- **Utils_equal fprintf trace** on the tag-mismatch path (Utils.cpp:557-562): a side effect but
  not a GC hazard (§A.2 table) — do not let the harness misread it as disqualifying. (Anchor
  drift confirmed: the design doc says :550-555; the HEAP_039 `eqListHybrid` insertion at
  :553-556 pushed it down.)
- **CSV row integrity (the real rule).** `invariants.csv`'s header is
  `id;phase;category;status;description;source`, but the description field ALREADY contains
  semicolons — CGEN_072 itself splits into 8 fields today, CGEN_075 into 10 — and nothing in the
  build parses the file (it is grep-oriented; the only in-tree mentions are Elm doc comments).
  So do not chase the field count. What actually breaks the file: an embedded newline (a row must
  stay on ONE line), a lost final `;` before the `|`-separated source column, or a duplicated id.
- **`.mlir` artifacts are BYTECODE.** `eco-compiler.mlir` starts with `ML\357R`; `grep -c` on it
  reports presence, not occurrences, and `diff` on two of them is useless. Any check that needs
  to count or eyeball attributes must go through `--text-mlir` (Terminal/Main.elm:296-298) /
  `ECO_TEXT_MLIR` (test/TestSuite.hpp:20-25). `cmp` for byte-identity still works fine.
- **Stale-`.mlir` consumption:** gates must use `--target full`, never `check`. But the
  *census* runs must NOT use `--target full` — it regenerates/deletes `eco-compiler.mlir`; use
  `--target eco-compiler` (compiler/CMakeLists.txt:464) and delete the outputs first, since
  ninja is env-blind (EcoBackend.cpp:99-100).
- **Config record order.** `EcoConfig`'s decoder is positional (`D.pure EcoConfig |> D.apply …`,
  Config.elm:346-361); the new `D.apply` line must be last and must match the field's position
  in the type alias, or every field after it silently shifts.

## Dependencies

- **Depends on kernel-opt-07-kernel-facts-table.md** — the stamp set is derived from
  `KernelFacts.gcLeafEligible`; no independent name list may exist anywhere. The two symbols
  this plan imports, exactly as 07 Phase 1 pins them, are
  `lookup : ( Name, Name ) -> Maybe KernelFacts` and `gcLeafEligible : KernelFacts -> Bool`
  (a derived helper over the row, **not** a stored field and **not** keyed — Phase 1c composes
  them). 07's Phase 6 must also hand over the reviewed `KERNEL_FACTS_001` draft, which lands
  here (§6.F R7: the stamp and its enforcement are one change), and 07's Phase 3 seed table
  determines the stamp set — see Phase 4's parity table for the seven pilot symbols it does not
  cover.
- **Enables kernel-opt-09-gcprepare-barrier-relaxation.md** (the 07 → 08 → 09 spine; 09 reads
  the same `eco.gc_leaf`) and strengthens kernel-opt-10/13 (CSE across de-statepointed calls)
  and capacity-check hoisting (EcoBackend.cpp:2153-2155 / :1889).
- **External:** `ECO_GCFREE_LEAF` default-on (CGEN_072(e) since 2026-08-09) and its census
  mode; `ECO_ALLOC_HOIST` default-on (CGEN_074) for the second-order measurement only.

## Expected impact

**Wall: FLAT — stated up front and expected.** The pilot was flat while covering 64.1% of
dynamic kernel calls; this is the fifth data point that statepoint/stackmap/metadata removal
does not move wall (preserve-cc, gc-leaf pilot, capacity-hoist, the compare phases). Wall moves
with retention and with deleted per-op work — inline nursery −9.6%, CAF memoization −11.7%,
`$cap`-inlining −14.5%, K6 hash-consing −5.07% — none of which this plan touches. What it buys:

- **(a) ~−1% binary**, nearly all `.llvm_stackmaps` (pilot: −637,568 B of −660,824 B).
- **(b) coverage/site lift, BELOW the pilot's** (+146 functions, +1,929 sites). The pilot's 20
  declarations included seven the audited table does not license — `JsArray_length` (class-B
  unaudited row) and the six `Char_*` (no row at all) — against one the pilot missed
  (`Bytes_decodeFailure`). 13 of 20 shared ⇒ expect a smaller Δ, in proportion to those symbols'
  static site counts. **Measure it and record the set difference** (Phase 4); the pilot number is
  a reference point, not a target, and closing the gap is a kernel-opt-07 table change.
- **(c) the enabling substrate** for 09's barrier relaxation, longer capacity-hoist runs, and
  post-RS4GC inlining of stamped callers (CGEN_072(d)).
- **(d) the audit harness as a permanent regression tripwire** for every future facts-table
  edit — the only thing standing between a wrong `GcNone` row and silent heap corruption.

## Gates

- **Census before/after** — `ECO_GCFREE_LEAF=c` (commands in Phase 0/4): `numFree/numDefined`
  coverage, de-statepointed sites, binary and `.llvm_stackmaps` sizes. **The census numbers are
  the deliverable**; record them in `benchmarks/kernel-opt.md`.
- **Full E2E:** `cmake --build build --target full 2>&1 | tee /tmp/test_output.txt`, then
  `grep -E 'FAILED|failed|Summary|[0-9]+/[0-9]+' /tmp/test_output.txt`. Run ONCE; grep the file
  for anything else. Never `check` after codegen changes.
- **Harness, both flag states:** `TEST_FILTER=KernelFactsAudit cmake --build build --target full`
  green; plus the recorded negative control (Phase 3c acceptance).
- **Codegen golden:** `TEST_FILTER=kernel_gcleaf cmake --build build --target full` green.
- **Front-end:** `cmake --build build --target elm-tests 2>&1 | tee /tmp/elm_tests.txt` —
  the Config/Context/Functions changes compile and no borrow-axis consumer moved.
- **Heap-validate suite:** configure with `-DECO_HEAP_VALIDATE=ON` (CMakeLists.txt:84-89) in a
  separate build dir (`build-val`) and run the suite; green, currently 1632/1632. This is the
  gate that would catch a lying row end-to-end rather than per-kernel.
- **Bootstrap:** `cmake --build build --target bootstrap 2>&1 | tee /tmp/bootstrap.txt` —
  Stage 8c native fixed-point check (compiler/CMakeLists.txt:547-584). Flag-OFF: byte-identical
  to today's fixed point (inertness), via `cmp`. Flag-ON (Phase 5): converges to a **NEW** fixed
  point; `eco-compiler-boot.mlir == eco-compiler-boot-2.mlir` is the gate. The "only `eco.gc_leaf`
  changed" claim must be checked on `--text-mlir` re-emissions of both arms (recipe in Phase 5) —
  the artifacts themselves are bytecode, so `diff` on them proves nothing. Inspect it, don't assume.
- **Wall A/B**, cold Stage 7a, interleaved 2×2, uninstrumented binaries, `/usr/bin/time -v`,
  **major-GC counts recorded** (the GC-trigger lottery) — expected FLAT; record it anyway,
  including RSS (the pilot showed an unexplained +0.43%).
- **Pilot-parity check:** the stamped set is the A1 14; every one of the seven pilot symbols it
  does not cover is classified per Phase 4's (i)–(iv), and the resulting set difference plus
  Δsites is written into this file and kernel-call-census.md §C2.1.
