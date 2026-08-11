# Kernel-Opt 06: String lt/le/gt/ge -> eco.string.cmp3 + integer sign test

**Status: IMPLEMENTATION-READY v2.1 — 2026-08-10.** (deepened from OUTLINE v1;
every load-bearing anchor re-verified against the tree, and the Phase-0 census
re-executed end-to-end — all counts reproduced exactly. v2.1 fixed: the
`eco-config.json` fallback needed an unstated `test/CMakeLists.txt` staging
edit; the fixture pre-check pointed at the source-tree package cache instead of
the build shadow; the Phase-0 awk did not collapse `_tail_stepState_NNNNN`;
gate 2 demanded a byte-identity that this item's own source growth makes
impossible on the self-compile.) Derived from
`design_docs/kernel-boundary-reduction.md`, the Stage-7a dynamic census
(`design_docs/kernel-boundary/kernel-census-dynamic-stage7a.txt`), and riding
the string-cmp plumbing shipped Aug 10 2026
(`plans/string-cmp-order-intrinsic-and-postmono-compare-rewrite.md`).

> **Gating idiom (settled 2026-08-11, kernel-opt-01/04).** Do NOT add a new
> config-gating mechanism to `Intrinsics.elm`. That module classifies
> unconditionally and stays config-free; the flag check lives in
> `Expr.gateIntrinsic`, which already handles `ConstructList` (01) and
> `StringLength` (04). Add an arm there rather than a `kernelIntrinsicCfg` /
> per-plan `gateIntrinsic` of your own.

## Files touched

| File | Change |
|---|---|
| `compiler/src/Compiler/Generate/MLIR/Intrinsics.elm` | new `StringOrderCompare` variant (after :53); 4 `utilsIntrinsic` arms (after :641); result/operand-type arms (after :150, :253); dead-but-total arm in `generateIntrinsicOp` (after :981); new `generateIntrinsicOps` + `gateIntrinsic`; exposing list (:1) + `@docs` (:8) |
| `compiler/src/Compiler/Generate/MLIR/Expr.elm` | 2 emission sites (:3725-3747, :4199-4220) route through `gateIntrinsic` and take a **list** of ops |
| `compiler/src/Compiler/Eco/Config.elm` | `stringOrderIntrinsic : Bool` — alias field (after :47), `default` (after :338), decoder `D.apply` (after :361), hash token `strord=1` (after :743) |
| `compiler/src/Builder/Eco/Config.elm` | `ECO_STRING_ORDER_INTRINSIC` chain entry (after :264) + `applyStringOrderIntrinsicOverride` (mirror of :272-290) |
| `test/elm/src/StringOrderIntrinsicTest.elm` | NEW — rewrite-case fixture |
| `test/elm/src/StringOrderBailTest.elm` | NEW — bail-case fixture (separate file: `CHECK-NOT` is whole-output) |
| `design_docs/invariants.csv` | CGEN_075 (:639) gains clause (f): the front-end ordering intrinsic is a cmp3 consumer, signed `<0/<=0/>0/>=0` only |

**No runtime, kernel, TableGen or pass changes; zero new symbols.**
`eco.string.cmp3` (`Ops.td:2775-2793`), its lowering
(`EcoToLLVMArith.cpp:1134-1149`, added to the pattern set at
`EcoToLLVMArith.cpp:1257`), its declaration helper
(`EcoToLLVMRuntime.cpp:939-943`, `gcLeaf=true`), its **pre-materialization**
(`EcoToLLVMRuntime.cpp:1264`, inside `materializeAllRuntimeDecls` — the
mandatory point: a create after `freeze()` is an assert, not a clean error),
its C++ definition (`elm-kernel-cpp/src/core/UtilsExports.cpp:40-47`), its
header decl (`KernelExports.h:192`) and its JIT registration
(`RuntimeSymbols.cpp:743 KERNEL_SYM(eco_string_cmp3)`) all exist and are wired
— each read and confirmed. The registration checklist for this item is empty.

## Goal

Close the comparison family: `lt`/`le`/`gt`/`ge` on `[MString, MString]` get the
treatment `compare` already got. Each site becomes `eco.string.cmp3` (UNCLAMPED
sign, `!eco.value × !eco.value → i64`) plus one signed test against `0`,
replacing a boxed kernel call whose `HPtr` Bool is immediately
`eco.unbox`-ed to `i1`.

## Evidence

**Dynamic** (census total 3,676,097,627 calls; the Aug-10 compare series
rewrote `compare`→case sites, not `lt`/`gt`, so these rows stand):
`Elm_Kernel_Utils_lt` = 30,447,459 (0.83%, dyn rank **#12** — v1 said #10,
corrected against the file); `Elm_Kernel_Utils_gt` = 5,496,282 (0.15%);
`_le`/`_ge` do not appear (0 dynamic calls). Combined ≈ 0.98% of kernel traffic.

**Static** — measured 2026-08-10 on the current self-compiled front-end MLIR
(`build/compiler/build-kernel/bin/eco-compiler.mlir`; commands in Phase 0):

| callee | sites | enclosing families |
|---|---:|---|
| `@Elm_Kernel_Utils_lt` | **79** | `Dict_removeHelp` 38, `_tail_stepState` (`Dict.merge`) 38, `Basics_lt` wrappers 2, `Compiler_Graph_binarySearch` 1 |
| `@Elm_Kernel_Utils_gt` | **40** | `_tail_stepState` 38, `Basics_gt` 2 |
| `@Elm_Kernel_Utils_ge` | **2** | `Terminal_Repl_attemptDeclOrExpr` 1, `Basics_ge` 1 |
| `@Elm_Kernel_Utils_le` | **0** | — (v1's open count, answered) |

Bucketed by the enclosing function's first `eco.logical_param_types` entry (a
key-type proxy: String *and* every other boxed key render as `"value"`, only
`tuple2:*`/`custom:*` are *visibly* non-String) — lt: 73 candidates + 6 definite
bails (5 `tuple2:v:v`, 1 `custom:0:4:i:i:v:v`); gt: 39 + 1 `tuple2:v:v`;
ge: **0 candidates** (1 `tuple2:i:i`, 1 `custom:0:2:v:v`). ~112 of 121 sites are
String candidates.

**Prior on the String share**, from the same Dict spec population measured on
`compare` in the same file: 258 `eco.string.cmp_order` (155 `Dict_insertHelp`,
95 `Dict_get`, 8 misc) vs 38 residual `@Elm_Kernel_Utils_compare` (21/12/5) =
**87% String**. Expect ~95-100 of the 121 sites to convert.

**The mono types are right — the decisive fact.** `Dict_removeHelp_$_1383` has
ABI `(!eco.value, !eco.value)` because `monoTypeToAbi MString = !eco.value`
(REP_ABI_001), but the *mono* type at the call is `MString`; the arm matches on
mono types, and the 258 already-firing `("compare", [MString, MString])` sites
prove monomorphization delivers `MString` at exactly these specs.

**Every site is a call + a Bool decode:** 77/79 lt, 38/40 gt, 1/2 ge sites are
immediately followed by `eco.unbox %N : !eco.value -> i1`; the exceptions are
the `Basics_*` wrapper bodies which return the boxed Bool. That wrapper path is
already proven for the intrinsic shape — `Basics_lt_$_168` (Int) emits
`eco.int.lt` + `eco.box %0 : i1 -> !eco.value` + `eco.return`.

**Semantic equivalence is provable, not assumed.** `Utils::lt` is
`cmp(a,b) < 0` (`Utils.cpp:809-811`); `Utils::cmp` handles `!a&&!b→0`, `!a→-1`,
`!b→1` (`:304-306`) then routes String×String to `StringOps::compare`
(`:315-317`). `eco_string_cmp3` (`UtilsExports.cpp:40-47`) is the same function:
`pa==pb→0` (covers both-Empty), `!pa→-1`, `!pb→1`, else `StringOps::compare`.
Identical for every String×String input including `""`/`Const_EmptyString`.

**Predicates lower signed.** `eco.int.{lt,le,gt,ge}` are
`(Eco_Int, Eco_Int) -> Eco_Bool` (`Ops.td:2217-2271`) lowered to
`arith::CmpIPredicate::{slt,sle,sgt,sge}` (`EcoToLLVMArith.cpp:538-582`) — the
right family for an UNCLAMPED signed sign. `Eco_Int = I<64>` and
`Eco_Bool = I<1>` (`Ops.td:239,242`), which is why the emitter below passes
`Types.ecoInt` (= `I64`, `Types.elm:82-84`) for the sign/zero operands and the
bare `I1` for the result — matching the shipped `IntComparison` arm
(`Intrinsics.elm:835-841`).

## Outcome — SHIPPED 2026-08-11 (benchmarks/kernel-opt.md Run J)

DEFAULT-ON, `ECO_STRING_ORDER_INTRINSIC=0` escapes. Phase-0 baseline reproduced the recorded
counts **exactly** (lt 79 / le 0 / gt 40 / ge 2). Emission delta: **lt 79 -> 14, gt 40 -> 10,
ge 2 -> 2, le 0 -> 0**, against `eco.string.cmp3` **1 -> 96**. That is **95 conversions and 95
new cmp3 ops**, an exact 1:1, and it lands inside the plan's predicted 95-100 range. Wall
**-0.34% => FLAT**, as §Expected impact predicted; counters identical, `-out.mlir`
byte-identical both rounds. Gates: E2E **1639/1639 in BOTH flag states** and again default-on;
elm-tests 13,085 / 12 pre-existing.

### Numbers owed to kernel-opt-03 (its Phase 5 is gated on these)

kernel-opt-03's Phase 5 ("residual boxed compare/lt/gt/ge") may execute **only if** more than
200 boxed `Utils_{compare,lt,le,gt,ge}` sites survive AND the Stage-7a dynamic `Utils_lt` row
is still live. Measured after this item:

| survivor | sites |
|---|---:|
| `Elm_Kernel_Utils_lt` | 14 |
| `Elm_Kernel_Utils_le` | 0 |
| `Elm_Kernel_Utils_gt` | 10 |
| `Elm_Kernel_Utils_ge` | 2 |
| `Elm_Kernel_Utils_compare` (residual, from the Aug-10 series) | 38 |
| **total** | **64** |

**64 < 200, so kernel-opt-03's Phase 5 MUST NOT execute.** The dynamic clause was not
measured (the per-symbol census is not in the tree), so per 06's own wording 03 must treat
that clause as unmet as well. Both conditions fail; the gate is closed, not deferred.

Deviation: gating goes through `Expr.gateIntrinsic` rather than a new `Intrinsics.gateIntrinsic`
(see the note at the head of this file). The multi-op emitter `generateIntrinsicOps` DID land in
`Intrinsics.elm` as specified, since it needs the `Intrinsic` type and `Ops`; both `Expr.elm`
emission sites now call it, and single-op intrinsics are delegated and wrapped in a singleton.

## Approach

### Phase 0 — attribution census (executed; re-run to refresh)

Mechanism: render the front end's own emitted MLIR to text, grep it.
Two mechanics that bite:

- **`ecoc --emit=mlir` writes the module to STDERR** (found 2026-08-10 —
  `module->dump()` at `ecoc.cpp:448` goes to `llvm::errs()`; redirecting only
  stdout yields a 0-byte file).
- **`--emit=mlir` is `DumpMLIR` = "Dump input MLIR (no lowering)"**
  (`ecoc.cpp:137`, dispatched at `ecoc.cpp:446-450` *before* `runPipeline`).
  So this render is the raw front-end emission with **zero** eco→eco passes
  run — which is exactly what we want, and why `eco.string.cmp3` is absent
  today (`EcoCompareCaseRewrite`, `EcoPipeline.cpp:69`, never ran). Use
  `--emit=mlir-eco` (`ecoc.cpp:138`) if you ever want the post-rewrite form.

```bash
S=/tmp/claude-scratch; mkdir -p $S
cp /work/build/compiler/build-kernel/bin/eco-compiler.mlir $S/eco-compiler.mlir  # `--target full` deletes it
/work/build/runtime/src/codegen/ecoc --emit=mlir $S/eco-compiler.mlir > $S/off.txt.mlir 2>&1

for s in lt le gt ge; do printf "%-3s %s\n" "$s" \
  "$(grep -c "callee = @Elm_Kernel_Utils_${s}}" $S/off.txt.mlir)"; done

# family histogram (repeat per predicate). THREE suffix strippers are needed,
# not two: `Basics_lt_$_168` carries `_$_NNN`, `Dict_get_$_9$cap` carries
# `$cap`, and the loopified tail funcs carry a BARE `_NNNNN`
# (`_tail_stepState_50478`). Without the third sub the 38 Dict.merge sites
# print as 38 singleton rows instead of one bucket.
awk '/^  func\.func/{fn=$0} index($0,"callee = @Elm_Kernel_Utils_lt}"){
  match(fn,/@[A-Za-z0-9_$]+/); n=substr(fn,RSTART,RLENGTH);
  sub(/_\$_[0-9]+$/,"",n); sub(/\$cap$/,"",n); sub(/_[0-9]+$/,"",n);
  print n}' $S/off.txt.mlir | sort | uniq -c | sort -rn

# key-type proxy histogram
awk '/^  func\.func/{fn=$0} index($0,"callee = @Elm_Kernel_Utils_lt}"){
  if (match(fn,/eco\.logical_param_types = \["[^"]*"/)) {t=substr(fn,RSTART,RLENGTH);
  sub(/.*\["/,"",t); sub(/"$/,"",t); print t} else print "(none)"}' $S/off.txt.mlir | sort | uniq -c | sort -rn
```

Output: one count per predicate + two histograms. Baseline recorded above
(79/0/40/2), and **re-reproduced byte-for-byte on 2026-08-10** against
`build/compiler/build-kernel/bin/eco-compiler.mlir` (13,398,102 B, 966,687
rendered lines): lt 79 / le 0 / gt 40 / ge 2, `cmp_order` 258 (155/95/8),
residual `compare` 38 (21/12/5), key-type buckets lt 73+5+1, gt 39+1,
ge 0+1+1. **Acceptance:** counts reproduced within ±2 (spec ids drift when the
compiler's own sources change; counts should not). The *exact* String bucket is
not statically decidable from the text — it is measured in Phase 3 as the flag
delta, which is exact and free.

### Phase 1 — Config flag (default OFF)

`Compiler/Eco/Config.elm`, **appended as the LAST alias field**: the decoder is
positional (`D.pure EcoConfig |> D.apply …`), so alias declaration order and
`D.apply` order must stay in lockstep — verified for the existing 13 fields.

```elm
    -- alias, after :47 (sretTailFuncs)
    , stringOrderIntrinsic : Bool -- kernel-opt-06 (plans/kernel-opt-06-string-ordering-cmp3.md): lower Utils.lt/le/gt/ge on [MString,MString] to eco.string.cmp3 + a SIGNED sign test against 0 instead of the boxed kernel call + eco.unbox; DEFAULT-OFF at landing (flip after gates); env ECO_STRING_ORDER_INTRINSIC=1 enables, =0 disables; artifact-affecting (hash token "strord=1")

    -- default, after :338
    , stringOrderIntrinsic = False

    -- decoder, LAST D.apply after :361
        |> D.apply (D.optionalField "stringOrderIntrinsic" D.bool default.stringOrderIntrinsic)

    -- hash, appended LAST — after the borrow `bopt=1` block (:738-743),
    -- not after the srtf block, so the token list stays append-only
            ++ (if cfg.stringOrderIntrinsic then [ "strord=1" ] else [])
```

`Builder/Eco/Config.elm`: chain entry after the `ECO_BORROW_OPT` step
(:260-264), plus `applyStringOrderIntrinsicOverride` copied verbatim from
`applyAggPromoteOverride` (:272-290) with the field renamed.

```elm
        |> Task.andThen
            (\cfg30 ->
                (Utils.envLookupEnv "ECO_STRING_ORDER_INTRINSIC" |> Task.mapError never)
                    |> Task.map (\soVal -> applyStringOrderIntrinsicOverride soVal cfg30)
            )
```

**Acceptance:** `cmake --build build --target elm-tests` green; `Config.hash`
gains `strord=1` only when on, so flag-on builds never share flag-off caches.

### Phase 2 — intrinsic arms (Intrinsics.elm)

1. **Variant** (after `CompareToOrder` at :53) — `op` is the `eco.int.*`
   comparison op name; the cmp3 sign is UNCLAMPED (`Ops.td:2779-2781`), so the
   test is always against `0`, never `±1`:

```elm
    | StringOrderCompare { op : String }
```

2. **`intrinsicResultMlirType`** (after :149-150): `StringOrderCompare _ -> I1`.

3. **`intrinsicOperandTypes`** (after the `CompareStringKind` case, :252-253):

```elm
        StringOrderCompare _ ->
            -- REP_ABI_001: String crosses every ABI as !eco.value; never unbox.
            -- unboxArgsForIntrinsic no-ops on boxed-expected slots (:294).
            [ Types.ecoValue, Types.ecoValue ]
```

4. **`utilsIntrinsic` arms**, immediately after the `compare`/String arm
   (:640-641); the `_ -> Nothing` fallthrough (:643-644) keeps every other
   operand shape on today's kernel call:

```elm
        -- kernel-opt-06: String ordering joins `compare` at the intrinsic
        -- boundary. Structural orderings (lists, tuples, records, user
        -- comparables) still fall through to Elm_Kernel_Utils_{lt,le,gt,ge}.
        ( "lt", [ Mono.MString, Mono.MString ] ) ->
            Just (StringOrderCompare { op = "eco.int.lt" })

        ( "le", [ Mono.MString, Mono.MString ] ) ->
            Just (StringOrderCompare { op = "eco.int.le" })

        ( "gt", [ Mono.MString, Mono.MString ] ) ->
            Just (StringOrderCompare { op = "eco.int.gt" })

        ( "ge", [ Mono.MString, Mono.MString ] ) ->
            Just (StringOrderCompare { op = "eco.int.ge" })
```

**Pinned: do NOT touch `basicsIntrinsic` (:343-532).** It has no Char arms
either — Char/String ordering canonicalizes to the Utils kernel, and the
self-compiled module contains **zero** `@Elm_Kernel_Basics_*` calls (verified by
grep). Basics arms would be dead code.

5. **Emission.** `generateIntrinsicOp` (:773) returns ONE `MlirOp`; this
   intrinsic needs three. Add a list-returning sibling rather than churning the
   25 existing arms:

```elm
generateIntrinsicOps : Ctx.Context -> Intrinsic -> String -> List String -> ( Ctx.Context, List MlirOp )
generateIntrinsicOps ctx intrinsic resultVar argVars =
    case intrinsic of
        StringOrderCompare { op } ->
            let
                ( lhs, rhs ) =
                    case argVars of
                        [ a, b ] -> ( a, b )
                        _ -> ( "%error", "%error" )

                ( signVar, ctx1 ) = Ctx.freshVar ctx

                ( ctx2, cmp3Op ) =
                    Ops.ecoBinaryOp ctx1 "eco.string.cmp3" signVar
                        ( lhs, Types.ecoValue ) ( rhs, Types.ecoValue ) Types.ecoInt

                ( zeroVar, ctx3 ) = Ctx.freshVar ctx2
                ( ctx4, zeroOp ) = Ops.arithConstantInt ctx3 zeroVar 0

                ( ctx5, testOp ) =
                    Ops.ecoBinaryOp ctx4 op resultVar
                        ( signVar, Types.ecoInt ) ( zeroVar, Types.ecoInt ) I1
            in
            ( ctx5, [ cmp3Op, zeroOp, testOp ] )

        _ ->
            generateIntrinsicOp ctx intrinsic resultVar argVars
                |> Tuple.mapSecond List.singleton
```

APIs used, all verified: `Ops.ecoBinaryOp ctx opName resultVar (lhs,lhsTy)
(rhs,rhsTy) resultTy -> ( Context, MlirOp )` (`Ops.elm:997-1007`, sets
`_operand_types`, which `Mlir/Pretty.elm:255-291` renders as the generic form
`"eco.string.cmp3"(%a, %b) : (!eco.value, !eco.value) -> i64`);
`Ops.arithConstantInt ctx resultVar value` (`Ops.elm:870-875`);
`Types.ecoInt = I64`, `Types.ecoValue = NamedStruct "eco.value"`
(`Types.elm:75-84`); `Ctx.freshVar ctx -> ( String, Context )`.

Elm exhaustiveness forces a `StringOrderCompare` arm in `generateIntrinsicOp`
too — add it after the `CompareToOrder` arm (:960-981), using the file's
existing `"%error"` convention:

```elm
        StringOrderCompare { op } ->
            -- Multi-op intrinsic: both emission sites route through
            -- generateIntrinsicOps. Kept only for case totality.
            Ops.ecoBinaryOp ctx op resultVar ( "%error", Types.ecoInt ) ( "%error", Types.ecoInt ) I1
```

6. **Gate** — reads the config already on the context (`Context.elm:236
   ecoConfig`, installed by `withEcoConfig` :341-343), so no new import:

```elm
gateIntrinsic : Ctx.Context -> Intrinsic -> Maybe Intrinsic
gateIntrinsic ctx intrinsic =
    case intrinsic of
        StringOrderCompare _ ->
            if ctx.ecoConfig.stringOrderIntrinsic then Just intrinsic else Nothing

        _ ->
            Just intrinsic
```

7. **Registration checklist for the new Elm exports** (module-local; no C++
   side): `exposing (…)` at `:1` gains `gateIntrinsic` and
   `generateIntrinsicOps`; the `@docs` line at `:8` gains both.

**Acceptance:** `elm-tests` green; flag-off emission inert — no extra
`Ctx.freshVar` is consumed and no op is emitted when `gateIntrinsic` returns
`Nothing`, so the fixed-corpus byte-identity of gate 2 must hold exactly.

### Phase 3 — call sites (Expr.elm) + emission delta

Both emission sites take the identical shape change. Site A `:3725-3747`
(core-module path, `moduleName`), site B `:4199-4220` (kernel path, `home`):

```elm
                    -- Site A uses `moduleName` here, site B uses `home`; the
                    -- rest is character-identical. `ctx1` and `argsWithTypes`
                    -- are already in scope at both `case` scrutinees (bound by
                    -- the enclosing `( argOps, argsWithTypes, ctx1 ) = …` lets
                    -- at Expr.elm:3494 and :3870).
                    case
                        Intrinsics.kernelIntrinsic home name argTypes resultType
                            |> Maybe.andThen (Intrinsics.gateIntrinsic ctx1)
                    of
                        Just intrinsic ->
                            let
                                ( unboxOps, unboxedArgVars, ctx1b ) =
                                    Intrinsics.unboxArgsForIntrinsic ctx1 argsWithTypes intrinsic

                                ( resVar, ctx2 ) = Ctx.freshVar ctx1b

                                ( ctx3, intrinsicOps ) =
                                    Intrinsics.generateIntrinsicOps ctx2 intrinsic resVar unboxedArgVars

                                intrinsicResType =
                                    Intrinsics.intrinsicResultMlirType intrinsic
                            in
                            { ops = argOps ++ unboxOps ++ intrinsicOps   -- was ++ [ intrinsicOp ]
                            , resultVar = resVar
                            , resultType = intrinsicResType
                            , ctx = ctx3
                            , isTerminated = False
                            }
```

`Expr.elm:775` also calls `kernelIntrinsic`, but only to match `ConstantFloat`
— leave it alone.

**Emission-delta measurement** (this *is* the exact String bucket):

```bash
S=/tmp/claude-scratch                       # $S/off.txt.mlir from Phase 0
ECO_STRING_ORDER_INTRINSIC=1 cmake --build build --target full 2>&1 | tee /tmp/test_output.txt
cp /work/build/compiler/build-kernel/bin/eco-compiler.mlir $S/on.mlir
/work/build/runtime/src/codegen/ecoc --emit=mlir $S/on.mlir > $S/on.txt.mlir 2>&1

for s in lt le gt ge; do printf "%-3s off=%s on=%s\n" "$s" \
  "$(grep -c "callee = @Elm_Kernel_Utils_${s}}" $S/off.txt.mlir)" \
  "$(grep -c "callee = @Elm_Kernel_Utils_${s}}" $S/on.txt.mlir)"; done
grep -c 'eco\.string\.cmp3' $S/on.txt.mlir    # == summed delta
grep -c 'eco\.string\.cmp3' $S/off.txt.mlir   # == 0 today (measured)
```

The env var reaches the guida compile because every stage is spawned as a
subprocess of `cmake --build` and inherits the environment; and the flip is
*seen* because `--target full` runs `--target clean` first
(`CMakeLists.txt:1113-1120`), which wipes the per-package `eco-stuff` caches
(`test/CMakeLists.txt:38-42`) and the whole bootstrap tree. **Never A/B the two
flag states with `--target check`** — see the harness-cache trap below.

**Acceptance:** cmp3 count == summed delta; residual `Utils_lt/gt/ge` sites are
exactly the visibly non-String ones (≥6 lt, ≥1 gt, 2 ge) plus any
List/Maybe-keyed specs.

**Decision point — how big is the String bucket?**
- **≥60% of candidates convert** (expected, given the 87% prior): proceed to
  Phase 4 and flip the default.
- **<60%**: the residue is List/Maybe/user-comparable keys, not String. Keep the
  flag default-OFF, record the measured split here, and hand the residue to
  kernel-opt-07 (`KernelFacts`). Do **not** widen the arm to other mono shapes
  in this item — a `[MList MString, …]` ordering has no cmp3 and would need a
  new op, which is out of scope for an S.

### Phase 4 — fixtures, default flip, gates

**Sequencing (pinned).** The E2E harness has no per-test env or compile-flag
hook: `extraCompileFlags` is a per-*suite* constructor argument
(`ElmE2ETestBase.hpp:1140-1143`, threaded to `compileAllElmTests` at :1202 and
appended to the shell command at :469-471), and the suites are one-per-package
(`test/elm/ElmTest.hpp:9` → `buildTestSuite("elm", "Elm E2E", "elm/")`). So a
`CHECK-MLIR` fixture asserting the intrinsic is only green once the flag is
default-on. Two commits:

- **Commit 1** (default OFF): Phases 1-3 + both fixtures carrying
  **behavioural `-- CHECK:` only** — they pass identically flag-on or flag-off.
- **Commit 2** (after all gates + the wall A/B): flip
  `default.stringOrderIntrinsic = True`, update the field comment to
  `DEFAULT-ON since 2026-08-XX`, and add the `-- CHECK-MLIR:` /
  `-- CHECK-MLIR-NOT:` directives.
  *Alternative branch,* only if commit 2 slips past a week: turn the flag on
  for the whole Elm suite via an `eco-config.json` holding
  `{"stringOrderIntrinsic": true}`. **This needs a CMake edit, not just a
  file** — the compiler reads `<root>/eco-config.json` where `<root>` is the
  build-tree shadow it `findRoot`s into (`Builder/Eco/Config.elm:26,49`;
  `ElmE2ETestBase.hpp:1277-1279` `findTestDir` → `${BUILD_DIR}/test/elm`), and
  `test/CMakeLists.txt` currently stages **only** `elm.json` plus a `src`
  symlink into that shadow (`:29-43` for the JIT shadow, `:49-61` for the AOT
  shadow). Dropping `test/elm/eco-config.json` in the source tree alone is a
  silent no-op. The edit is one `file(COPY ${CMAKE_CURRENT_SOURCE_DIR}/${pkg}/
  eco-config.json DESTINATION ${_shadow})` guarded by `if(EXISTS …)` in **both**
  loops, followed by `cmake --preset build` (a new file needs a reconfigure).
  Cost: silently changes config for every other test in the suite.

**Fixture 1 — `test/elm/src/StringOrderIntrinsicTest.elm`** (rewrite cases).
Conventions from `test/elm/src/CompareStringTest.elm` /
`CompareEmptyStringTest.elm` (module doc, `-- CHECK:` block above the imports,
one `Debug.log` per case, `text "done"`) plus `-- CHECK-MLIR:` as in
`HofFoldlLoopifyTest.elm:19-20`. Auto-discovered — `discoverTests`
(`ElmE2ETestBase.hpp:1089-1106`) scans `<shadow>/src/*.elm` (a symlink back to
`test/elm/src`) and keeps every file with a top-level `main`; no CMake edit.
Literal operands are safe: nothing constant-folds them — `CompareStringTest`'s
`compare "apple" "banana"` still emits `eco.string.cmp_order %1, %2` in the
front-end dump (checked 2026-08-10).

```elm
module StringOrderIntrinsicTest exposing (main)

{-| kernel-opt-06: `<`/`<=`/`>`/`>=` on String lower to ONE eco.string.cmp3
plus a signed sign test against 0 — no Elm_Kernel_Utils_{lt,le,gt,ge} call and
no boxed-Bool round trip. "" is Const_EmptyString (nullptr at the kernel
boundary), handled by eco_string_cmp3's !pa/!pb arms (UtilsExports.cpp:40-47).
-}

-- CHECK: lt1: True
-- CHECK: lt2: False
-- CHECK: le1: True
-- CHECK: le2: True
-- CHECK: gt1: True
-- CHECK: ge1: True
-- CHECK: elt: True
-- CHECK: ege: True
-- (commit 2 only)
-- CHECK-MLIR: eco.string.cmp3
-- CHECK-MLIR: eco.int.lt
-- CHECK-MLIR: eco.int.le
-- CHECK-MLIR: eco.int.gt
-- CHECK-MLIR: eco.int.ge
-- CHECK-MLIR-NOT: callee = @Elm_Kernel_Utils_lt}
-- CHECK-MLIR-NOT: callee = @Elm_Kernel_Utils_le}
-- CHECK-MLIR-NOT: callee = @Elm_Kernel_Utils_gt}
-- CHECK-MLIR-NOT: callee = @Elm_Kernel_Utils_ge}

import Html exposing (text)

lt : String -> String -> Bool
lt a b = a < b

main =
    let
        _ = Debug.log "lt1" (lt "apple" "banana")
        _ = Debug.log "lt2" (lt "banana" "apple")
        _ = Debug.log "le1" ("apple" <= "banana")
        _ = Debug.log "le2" ("apple" <= "apple")
        _ = Debug.log "gt1" ("zebra" > "ant")
        _ = Debug.log "ge1" ("ant" >= "ant")
        _ = Debug.log "elt" ("" < "a")
        _ = Debug.log "ege" ("a" >= "")
    in
    text "done"
```

The named `lt` helper is deliberate: it forces a `Basics_lt_$_N` wrapper spec so
the i1→`eco.box` return path (proven by `Basics_lt_$_168`) is exercised, not
just the inline-then-unbox path.

**Fixture 2 — `test/elm/src/StringOrderBailTest.elm`** (bail cases; MUST be a
separate file — `CHECK-NOT`/`CHECK-MLIR-NOT` are evaluated against the WHOLE
output, `CheckPatterns.hpp:6-12`). Conventions from
`test/elm/src/OrderingTupleWithEmptyListTest.elm` (the existing relational-
operator-on-tuples fixture).

```elm
module StringOrderBailTest exposing (main)

{-| kernel-opt-06 bail case. Only the literal `[MString, MString]` operand
shape is rewritten; structural comparables (tuples, lists) keep today's boxed
`Elm_Kernel_Utils_lt` call — there is no cmp3 for them and this item
deliberately does not widen the arm (see the Phase-3 decision point). Separate
file from StringOrderIntrinsicTest because CHECK-NOT is whole-output
(CheckPatterns.hpp:6-12).
-}

-- CHECK: tup1: True
-- CHECK: tup2: False
-- CHECK: lst1: True
-- CHECK: lst2: False
-- (commit 2 only)
-- CHECK-MLIR: callee = @Elm_Kernel_Utils_lt}
-- CHECK-MLIR-NOT: eco.string.cmp3

import Html exposing (text)

tupLt : ( String, Int ) -> ( String, Int ) -> Bool
tupLt a b = a < b

lstLt : List String -> List String -> Bool
lstLt a b = a < b

main =
    let
        _ = Debug.log "tup1" (tupLt ( "a", 1 ) ( "a", 2 ))
        _ = Debug.log "tup2" (tupLt ( "b", 1 ) ( "a", 2 ))
        _ = Debug.log "lst1" (lstLt [ "a" ] [ "b" ])
        _ = Debug.log "lst2" (lstLt [ "b" ] [ "a" ])
    in
    text "done"
```

The named helpers are deliberate (same reason as fixture 1): they mint
`Basics_lt_$_N` wrapper specs with non-String logical param types — the shape
already present in the self-compile as `Basics_lt_$_26014`
(`eco.logical_param_types = ["tuple2:v:v", …]`), i.e. one of the 6 lt sites
Phase 0 classified as a *definite* bail.

**Whole-output-`NOT` risk — pre-checked, not deferred.** Both `NOT` sets assert
over the entire program's MLIR, which includes every reachable elm/core spec.
Measured 2026-08-10 on two existing small tests, so the risk is quantified
*before* the fixtures are written:

```bash
M=/work/build/test/elm/eco-stuff/mlir        # NOT test/elm/eco-stuff — that is
                                             # the source-tree package cache.
                                             # getMlirPath = testDir + "/eco-stuff/mlir"
                                             # (ElmE2ETestBase.hpp:441-443) and
                                             # testDir = ${BUILD_DIR}/test/elm
                                             # (findTestDir, :1277-1279).
for t in CompareStringTest AddTest; do
  printf "%-20s lt/le/gt/ge=%s cmp3=%s\n" "$t" \
    "$(/work/build/runtime/src/codegen/ecoc --emit=mlir $M/$t.mlir 2>&1 \
        | grep -cE 'callee = @Elm_Kernel_Utils_(lt|le|gt|ge)\}')" \
    "$(/work/build/runtime/src/codegen/ecoc --emit=mlir $M/$t.mlir 2>&1 \
        | grep -c 'eco\.string\.cmp3')"
done
# measured: both tests → 0 and 0.
```

A small Elm program's reachable library surface contains **zero**
`Utils_{lt,le,gt,ge}` sites and zero `cmp3`, so both fixtures' `NOT` sets are
viable as written. Re-run this exact command against the two new fixtures'
`.mlir` after the first flag-on build. **Criteria if a stray site appears:**

- *Fixture 1 (`StringOrderIntrinsicTest`)* — a surviving library
  `Utils_{lt,le,gt,ge}` site means the `NOT` set is unprovable at whole-output
  granularity: drop to the positive `CHECK-MLIR:` set only and let Phase 3's
  whole-module count carry the negative claim. Do not delete the fixture.
- *Fixture 2 (`StringOrderBailTest`)* — a stray `eco.string.cmp3` means some
  library spec ordered Strings. Delete the offending construct from the fixture
  (it orders tuples and lists; a String `<` has no business being reachable);
  only if it comes from elm/core itself, drop `CHECK-MLIR-NOT: eco.string.cmp3`
  and keep the positive `CHECK-MLIR: callee = @Elm_Kernel_Utils_lt}` — that
  positive alone still proves the bail, which is this file's whole job.

**Acceptance:** `TEST_FILTER=elm cmake --build build --target full 2>&1 | tee
/tmp/test_output.txt`, then `grep -E "StringOrder|FAILED|failed"
/tmp/test_output.txt` shows both fixtures green. (`--target full`, not `check`
— the harness's `.mlir` cache is env-blind; see Traps.)

## Flag & rollback

- **Flag:** `stringOrderIntrinsic` (`Compiler/Eco/Config.elm`); env
  `ECO_STRING_ORDER_INTRINSIC=1|true|yes|on` / `0|off`; JSON
  `"stringOrderIntrinsic": true`. **Default `False` at landing**, flipped in
  commit 2 after gates.
- **Kill switch:** `ECO_STRING_ORDER_INTRINSIC=0` restores the boxed kernel call
  at every site; only the front end rebuilds.
- **Cache safety:** hash token `strord=1` appears only when enabled, so flag-off
  artifacts hash exactly like today's and the two configs never share `~/.eco`.
- **Revert:** 4 `utilsIntrinsic` arms + one variant + one emitter + a two-line
  shape change at two call sites. Revert commit 2 → default-off; revert commit 1
  → gone. No runtime/kernel/pass code is touched, so a revert cannot desync the
  C++ side.

## Traps & risks

- **cmp3 convention (v1's open question — CONFIRMED).** `Eco_StringCmp3Op`
  (`Ops.td:2775-2793`): `Eco_Value × Eco_Value -> Eco_Int` (i64), **UNCLAMPED**
  sign — "consumers must test `<0` / `==0` / `>0` and never compare against ±1"
  (`:2779-2781`). Cross-checked against the lowering, the runtime decl
  (`gcLeaf=true`) and the C++ body; also pinned by CGEN_075(b)
  (`invariants.csv:639`).
- **Return-width trap (inherited).** `eco_string_cmp3` must stay `int64_t`
  (`KernelExports.h:186-192`; the trap comment is `UtilsExports.cpp:23-26`,
  re-invoked for cmp3 at `:39`). We don't touch it — but any drive-by edit
  there breaks every consumer.
- **`generateIntrinsicOp` is single-op** — use `generateIntrinsicOps`, and don't
  forget the dead-but-total arm.
- **No inferred-result-type builder** (banked A-D trap): pass `I1` explicitly.
- **`CHECK-NOT` is whole-output** (`CheckPatterns.hpp:6-12`); confirmed for the
  `-- CHECK-MLIR-NOT:` variant too (same `extractCheckPatterns`, prefix-
  parameterised at `ElmE2ETestBase.hpp:355-372`) — hence two fixture files.
- **`eco.call` generic form / SymbolUserOpInterface parse-time verification**
  (banked A-D traps) apply to `test/codegen/*.mlir` fixtures. **Decision: this
  item adds none** — no new op, no new pass, nothing such a fixture would pin
  that the Elm `CHECK-MLIR` fixtures don't. Re-read them only if the Phase 3
  decision point sends us to a new op.
- **`[Pure]` rider.** `eco.string.cmp3` reads string contents; `[Pure]` is sound
  only under string immutability (`Ops.td:2751-2757`). We emit an existing op
  and claim no new traits — do not adjust them as a drive-by.
- **Mono-type fragility.** The arm fires only on literal `[MString, MString]`.
  The Number-taint history (memory: deep-branch solver REP regression) shows
  compare-family mono types can be subtler than they look; a miss bails to
  today's kernel call, and Phase 3's delta makes any miss visible.
- **Front-end emission of `eco.string.cmp3` is new** (today it only appears
  post-`EcoCompareCaseRewrite`) and must survive the Elm bytecode writer →
  `ecoc` parse round trip. Op names are collected automatically
  (`Mlir/Bytecode/DialectSection.elm:78-95` `collect`, no registration table),
  and the textual path renders the generic quoted form
  (`Mlir/Pretty.elm:223-224` `"\"" ++ op.name ++ "\""` + the `_operand_types`
  signature at :255-291), which parses unconditionally regardless of the op's
  `assemblyFormat`. The `CHECK-MLIR` fixture is the proof, since it renders the
  bytecode back through `ecoc --emit=mlir`.
- **New eco→eco exposure** (the *other* half of "emission is new"): the op is
  now visible to the passes that run BEFORE `EcoCompareCaseRewrite`
  (`EcoPipeline.cpp:69`) — `RCElimination` (:53), `EcoPAPSimplify` (:63) and,
  in `ECO_LOWERING_VALIDATION` builds, `CheckEcoClosureCaptures` (:59).
  **Verified safe:** `grep -rn "StringCmp3Op" runtime/src/codegen/ | grep -v
  '\.td\|\.inc'` returns exactly two non-creator sites —
  `EcoCompareCaseRewrite.cpp:172` (the creator) and
  `EcoToLLVMArith.cpp:1134/1142/1257` (the lowering). No eco→eco pass matches
  it and none has an exhaustive op switch. Re-run that grep if the pipeline
  gains a pass.
- **The E2E harness `.mlir` cache is mtime-only and ENV-BLIND.**
  `needsRecompile` (`ElmE2ETestBase.hpp:432-439`) compares `.elm` mtime against
  `.mlir` mtime and nothing else, so flipping `ECO_STRING_ORDER_INTRINSIC` does
  **not** invalidate a single cached fixture — a "flag-on" run would silently
  re-use flag-off MLIR and measure nothing. `--target full` neutralizes it
  (`--target clean` first, `CMakeLists.txt:1113-1120`, wiping
  `${shadow}/eco-stuff` via `test/CMakeLists.txt:38-42`) — this is the concrete
  reason "never `check`" is load-bearing for THIS item, not boilerplate. For an
  ad-hoc single-fixture rerun: `rm -rf /work/build/test/elm/eco-stuff/mlir`
  (or `touch` the `.elm`) before the run.
- **`--target full` deletes/regenerates `eco-compiler.mlir`** (memory:
  capacity-check-hoisting) — copy it to scratch right after each build.
- **`ecoc --emit=mlir` prints to STDERR** — always `2>&1`, or you get a 0-byte
  file and a confusing "no sites found".
- **Stale-.mlir consumption:** always `--target full`, never `check`.

## Dependencies

- **None blocking.** Items 01, 02, 04, 05, 06 are mutually independent; 06 rides
  plumbing shipped Aug 10 2026.
- Soft synergy: **kernel-opt-07** (`KernelFacts`) — every converted site is one
  fewer opaque kernel root, and 07 owns any decision to delete the
  `Utils_{lt,le,gt,ge}` wrappers (`Utils.cpp:809-823`); a unilateral `rm` is
  wrong because non-String comparables still reach them in other programs.
  **kernel-opt-10** (CSE/folders) — `eco.string.cmp3` is `[Pure]`, so duplicate
  orderings become CSE-able the day an MLIR CSE pass exists.
- **kernel-opt-03 depends on THIS item (reciprocal, must not be dropped).** Its
  Phase 5 ("residual boxed compare/lt/gt/ge") is explicitly gated on 06's
  residue analysis: *execute only if >200 boxed `Utils_{compare,lt,le,gt,ge}`
  sites survive AND the Stage-7a dynamic `Utils_lt` row (30,447,459) is still
  live after 06 lands.* So Phase 3 of this plan **must publish two numbers
  here** when it executes: (1) the post-flip residual site counts per predicate
  from the emission-delta table, added to the residual `Utils_compare` count
  (38 today, measured in Phase 0's render); (2) the post-land `Utils_lt`
  dynamic count from gate 8, or an explicit "not measured" if gate 8 is
  skipped — in which case 03's Phase 5 must treat the dynamic clause as unmet.
  Code-wise the two items are adjacent in the kernel (`Utils.cpp:805-807` vs
  `:809-823`) and **overlap heavily in the front end**: 03 adds `equal`/
  `notEqual` arms where 06 adds `lt`/`le`/`gt`/`ge` arms, so a **rebase conflict
  is expected in `utilsIntrinsic`, `intrinsicOperandTypes`,
  `intrinsicResultMlirType`, `generateIntrinsicOp`, `Compiler/Eco/Config.elm`
  (both append a LAST alias field + a LAST `D.apply` — the positional decoder
  makes order load-bearing, so the second lander must re-check lockstep) and
  both `Expr.elm` sites.** Whichever lands second merges. The two emission
  channels are compatible by construction: 03's `intrinsicPostOps` returns ops
  spliced AFTER the intrinsic, 06's `generateIntrinsicOps` returns the
  intrinsic's own op list, so the merged shape is
  `argOps ++ unboxOps ++ intrinsicOps ++ postOps`.

## Expected impact

**Honest expectation: FLAT wall.** Three consecutive compare-machinery
deletions measured wall-FLAT (memory: kernel-boundary census); this is a fourth
in the same family. Two structural reasons it won't move wall:

1. **Zero retention change.** `Elm_Kernel_Utils_lt` returns
   `Export::encodeBoxedBool(...)` (`UtilsExports.cpp:115-117`) — True/False are
   embedded HPointer constants, so the boxed Bool never allocated. Wall here
   tracks retention + deleted per-op work (inline nursery −9.6%, CAF memoization
   −11.7%, `$cap`-inlining −14.5%, K6 hash-consing −5.07%).
2. **The string walk itself is preserved verbatim** (same `StringOps::compare`).

What it does buy, all verifiable:

- ~36M fewer boxed kernel calls/run (30.4M lt + 5.5M gt, String share per
  Phase 3) and the matching `eco.unbox → i1` decodes.
- ~95-112 fewer statepointed call sites (112 = the candidate count, ~95-100 the
  expected conversions at the 87% String prior): `Elm_Kernel_Utils_lt` is a kernel extern
  (poison for gc-free propagation, CGEN_072) whereas `eco_string_cmp3` is
  declared `gcLeaf=true` (`EcoToLLVMRuntime.cpp:943`). Statepoint/metadata-only
  removal has measured wall-FLAT **four** consecutive times — expect binary size
  (stackmap metadata), not time.
- Surface closure: the comparison family is DONE — `lt`/`le`/`gt`/`ge` join
  `compare` as String-intrinsic, leaving only genuinely structural orderings on
  the kernel.
- Cleaner ground for 07/10/12: fewer opaque calls, more `[Pure]` ops.

Effort **S**; risk near zero (the bail path is the status-quo kernel call; the
flag is a one-env-var kill switch).

## Gates

1. **Compiler unit tests:** `cmake --build build --target elm-tests 2>&1 | tee
   /tmp/test_output.txt`, then `grep -E "TEST RUN|FAILED|Falsifiable"
   /tmp/test_output.txt`.
2. **Flag-off inertness — measured on a FIXED corpus, not on the self-compile.**
   `eco-compiler.mlir` is the compiler compiling *itself*, and this item adds
   Elm source to the compiler, so its self-compiled MLIR legitimately gains
   functions and shifts spec ids even flag-off; a byte-compare there would fail
   for the wrong reason. The right corpus is the Elm test suite, whose inputs
   are unchanged:
   ```bash
   S=/tmp/claude-scratch; mkdir -p $S
   # BEFORE landing (after a clean `--target full`):
   cp -r /work/build/test/elm/eco-stuff/mlir $S/mlir-pre
   # AFTER landing, env var UNSET, `--target full` again:
   diff -r $S/mlir-pre /work/build/test/elm/eco-stuff/mlir   # must print nothing
   ```
   If a byte diff ever trips on bytecode nondeterminism, re-render both sides
   through `ecoc --emit=mlir … 2>&1` and diff the text. On the self-compile,
   the flag-off check is the *count* form instead: Phase 0's four callee counts
   reproduce (79/0/40/2) and `grep -c 'eco\.string\.cmp3'` is 0.
3. **Full E2E (never `check`):** `cmake --build build --target full 2>&1 | tee
   /tmp/test_output.txt`, then `grep -E "FAILED|failed|Assertion"
   /tmp/test_output.txt | head -40`. Run ONCE; grep the file for anything else.
   Existing pins that must stay green — the String-ordering blast radius first:
   `OrderingEmptyStringTest`, `OrderingEmptyStringPapTest`,
   `CompareTupleWithEmptyStringTest`, `SortWithCompareEmptyStringTest`,
   `CompareStringTest`, `CompareEmptyStringTest`, `ContainerCompareStringTest`,
   `DictDiffFoldlStringKeysTest`; then the bail-side pins `DictTupleListKeyTest`,
   `CaseOrderTest`, `OrderingEmptyListTest` / `OrderingEmptyListPapTest`.
4. **Heap-validate:** separate `-DECO_HEAP_VALIDATE=ON` build
   (`/work/CMakeLists.txt:84-89`), baseline 1632/1632. cmp3 is gc-leaf and
   allocation-free, so this is a formality — run it anyway.
5. **Self-host bootstrap:** output changes legitimately (new op in the emitted
   MLIR), so the requirement is **bootstrap to a NEW fixed point** — Stage 8c
   must close (`compiler/CMakeLists.txt:547-586`: byte-compare of the linked
   `eco-compiler-boot` vs `eco-compiler-boot-2` ELFs on Linux, `.mlir`
   byte-compare on Darwin/Windows); the first flag-on build legitimately differs
   from the flag-off binary. Record both fixed-point hashes.
6. **Emission delta:** Phase 3 commands; String bucket > 0, cmp3 count ==
   summed delta, residual sites all non-String.
7. **Wall A/B:** cold Stage 7a, interleaved 2×2 minimum, outputs byte-compared,
   `/usr/bin/time -v`, **major-GC counts recorded** (GC-trigger lottery), ±0.3%
   noise floor stated (protocol: `plans/kernel-call-census.md` §C2.4). On
   record: FLAT — the gate catches regression, it does not claim a win. Record
   the binary-size delta too (stackmap shrink is the expected axis).
8. **Optional dynamic confirmation:** re-apply the reverted
   `ECO_KERNEL_CALL_CENSUS` patch (`plans/kernel-call-census.md` §C1 — confirmed
   2026-08-10 that the symbol appears **nowhere** in the tree, so this really is
   a re-apply, not a flag flip) and confirm `Elm_Kernel_Utils_lt` drops from
   30.4M toward the non-String residue. Not required — gate 6 × the census rows
   bounds it — but if it IS skipped, say so explicitly, because kernel-opt-03's
   Phase-5 trigger reads this number (see Dependencies).
