# Fast-stamping partial applications of globals (`p|` members)

**Status: P0 CENSUS RUN 2026-09-07 — §9. The MECHANISM question came back a
strong yes (84.1 % of `p|` sites are convertible, all four review guards sized
and none fatal). The WEIGHT question came back where §8 predicted: ≤ 33 M
upper bound, ~3 % of generic dispatch, realistically well under that. §3.1's
origin plumbing is BUILT (it was needed to run the census); §3.2's resolver is
not.**

Successor to `plans/lss-no-instance-declines.md` §9–§11. Sibling invariants:
LSS_011 (E2 PAP-prefix stamp — the mechanism this plan extends), LSS_013
(spine injection), LSS_025 (E9.5 post-settle devirt — the path this plan adds an
arm to), LSS_031 (dangling `_fast_evaluator` = the one failure that blocks
regardless of coverage).

---

## 1. The problem, and the distinction that makes it solvable

### 1.1 Plain terms

When the compiler emits a call to a function it was handed — `f acc`, where `f`
is a parameter — it cannot normally know which function `f` is, so it emits an
**indirect call**: follow the value to a heap object, read the code pointer out
of it, jump through it. Lambda-set analysis exists to prove which function it
is; when it succeeds the call site carries a one-element set naming it, and
**stamping** cashes that in by rewriting the call to reach the code without the
pointer read.

There are two ways to cash it in, and the difference is the whole plan:

  - a **direct** stamp rewrites the callee to a reference to the function's
    compiled specialization — `eco.call @Main_add_$_3(args)`. The heap object
    is not consulted at all.
  - a **fast** stamp keeps the heap object and keeps loading values out of it,
    but calls the code by name instead of through the pointer — the C++
    lowering `emitFastClosureCall` loads the object's filled slots at typed
    offsets and calls the named symbol with `[loaded slots…, site args…]`.

### 1.2 A partial application is a heap object with arguments in it

```elm
add : Int -> Int -> Int
add x y = x + y

applyN f n acc = ... f acc ...

answer = applyN (add 5) 10 0
```

`add 5` is a **partial application** (a PAP): `add` with one of its two
arguments already supplied. The probe (`scratchpad/gprobe`, 2026-09-07) shows
exactly what it becomes:

```mlir
%0 = "eco.papCreate"() <{arity = 2, function = @Main_add_$_3, num_captured = 0}>
%1 = "eco.papExtend"(%0, %c5_i64) <{remaining_arity = 2}>      ; slot[0] = 5
%2 = "eco.call"(%1, %c10_i64, %c0_i64) <{callee = @Main_applyN_$_4}>
```

and inside `applyN`, the call on it stays indirect:

```mlir
%4 = "eco.papExtend"(%arg3, %arg5) {_call_kind = "generic_apply"}
```

The census for that compile: `declinedNoInstance=1, g1absentp=1`. On the
self-compile this population is **2,418 sites** (`g1absentp`), and — unlike the
`g2global` population the previous plan chased — these are **genuine indirect
dispatches**, which is why they carry weight (§2.2).

### 1.3 Why they are unstampable today, on purpose

A PAP gets its own member identity, `p|<global>|<supplied>`, minted
deliberately WITHOUT the registration that would put it in the stampable class.
`Translate.injectPapMember`'s doc records why — the first implementation gave a
PAP its callee's `g|` id, devirt read that as "this value IS `add`", rewrote the
site to a **direct** call of `add`'s 2-arity spec, and passed ONE argument:

> `IO.traverseList (IO.traverseTuple f) args` made devirt call `traverseTuple`'s
> 2-arity spec with one argument, and monomorphization died on `demandUnify`
> with an arity mismatch.

The bound argument was dropped on the floor. So `p|` is a **fence**: it lets a
PAP occupy a set honestly (a one-sided join becomes a truthful 2-set instead of
a false singleton) while ensuring no direct-call arm can act on it.

**That fence forbids DIRECT stamps. It says nothing against FAST stamps.** A
fast stamp on `add 5` loads `5` out of the object — exactly as it loads a
capture — and calls `Main_add_$_3(5, acc)`. The arity is right. The bound
argument is never dropped, because it is never *reconstructed*; it is read from
the same object the indirect call would have read it from.

### 1.4 The machinery exists; only the lookup is missing

`AbiCloning.resolvePapSuffix` / `StampPap` already does precisely this — for
PAPs of **closures** (LSS_011). Its stamp is `captureAbi = captures ++ take k
params`, `paramTypes = drop k params`, `fastPapPrefix = Just k`; emission's
`generateFastDispatchCall` picks the bare symbol when
`|captureTypes| − papPrefix ≤ 0` and the lowering loads exactly the filled
prefix. `stampedPapPrefix = 3` on the self-compile shows it working end to end.

It does not fire for `p|` because it runs on the **instance path** — it scans
`memberInfo.buckets`, the index of `MonoClosure` objects — and a PAP built from
a top-level global has no `MonoClosure`. `Dict.get m index` misses, the site
falls to the `noInstance` path, and that path's only resolver
(`postSettleTarget`) knows only the direct rewrite that `p|` exists to forbid.

**The fix is a second resolver on the `noInstance` path that produces a `StampPap`-shaped
fast stamp whose target is a registry spec instead of a closure instance.**

---

## 2. P0 — what must be measured before building

### 2.1 What is already measured

Name-keyed join of the per-guard census (`gc-off` arm) against the fixed-point
dynamic profile (`eco-bmon`, 1,095,124,597 generic dispatches):

| guard | sites | dispatch (host-proportional UPPER BOUND) | share |
|---|---:|---:|---:|
| `g1absentl` | 1,373 | 37,599,813 | 3.43 % |
| **`g1absentp`** | **1,777** | **35,354,889** | **3.23 %** |
| `g2global` | 6,894 | 2,767,363 | 0.25 % |

`p|` by host: `List.foldrHelper` **950 sites / 34.4 M UB**, `List.foldl` 121 /
5.8 M, `Basics.composeR` 73 / 2.5 M, `composeL` 70 / 0.6 M; every other host
measures **0**. (The 1,777 is the top-80 visible subset of the 2,418.)

**This is a generous bound.** It attributes a host's whole generic dispatch to
its `p|` sites in proportion to site count. The one precise measurement of a
comparable bound in this arc (`bodyMismatch` at `foldrHelper`, fixed-point
per-spec join) came in at **15 %** of its UB. Honest expectation for `p|`:
**5–10 M dispatches, ~0.5–1 %.** That is below the ~50 M bar §7 of the
`bodyMismatch` plan was measured against. See §8.

### 2.2 What P0 must add

  1. **Per-spec weight for the `p|` sites**, valid only on a fixed-point binary
     (`plans/lss-body-mismatch-declines.md` §8.4 — the per-spec join is a
     recorded trap otherwise). The current tree compiles to a fixed point
     (`eco-ni`, `eco-bmon`), so this is one census build + one profiled run.
  2. **The shape distribution**: for each `p|` decline record
     `k`, `declaredArity`, `argCount`, the site callee type's first-stage
     arity, and whether `peelStages argCount calleeType` lands — keyed
     `"<host>|k=<k>|decl=<n>|site=<fs>-><argCount>|<peel>"`. This sizes the
     §3.4 over-applying branch and answers whether the 83 %-depth-1 figure
     from `injectPapMember`'s census still holds.
  3. **Target-node kind** per `p|` member: `MonoDefine(MonoClosure)`,
     `MonoTailFunc`, `MonoCtor`, other. §3.5's restriction to function nodes
     is sized by this; a large `MonoCtor` share means ctor PAPs (`Just`-style)
     dominate and need their own arm.
  4. **Ambiguity count**: how many `p|` sites have 2+ specs of the global
     whose k-dropped suffix matches (§3.3). If most sites are ambiguous the
     plan's ceiling collapses before it starts.

All four ride the existing `niGuard` machinery (`plans/lss-no-instance-declines.md`
§8) — the key just gets richer for the `g1absentp` arm.

---

## 3. Design

### 3.1 Give `p|` an origin the graph can read

`MemberOrigin` gains a variant; `MemberSource` gains its twin:

```elm
-- Compiler/AST/Monomorphized.elm
type MemberOrigin
    = OriginGlobal Global
    | OriginKernel Name Name
    | OriginCtor Global
    | OriginAccessor Name
    | OriginPap Global Int          -- NEW: the partially-applied global and k

-- Compiler/MonoSolver/Engine.elm
type MemberSource
    = SourceGlobal TOpt.Global
    | SourceKernel ( String, String, String )
    | SourcePap TOpt.Global Int     -- NEW
```

`buildMemberOrigins` (Monomorphize.elm:4947) gets a `"p|"` arm reading
`SourcePap` → `OriginPap`. **Both** mint sites — `Translate.injectPapMember` and
`LssInfer.injectPapMemberInfer` — record the source, through ONE shared
`Engine.papMemberIdFor : TOpt.Global -> Int -> Step Int` so they cannot drift
(the LSS_017 raw/qualified split was exactly a two-site drift).

**`memberClassOf` gains an explicit `SourcePap` arm returning `"l"`.** Today
`p|` falls to the `_ -> "l"` default and the whole point of §1.3 is that it
stays in the declining class for every DIRECT consumer. Registering a source
must not silently promote it: the arm is explicit so a future reader cannot
"tidy" it into `"gc"`.

Exhaustive `MemberOrigin` matches that must gain an arm (the compiler enforces
this — they have no wildcard): `Borrow/LssFacts.elm:290` → `Poison PUnresolved`;
`MapTemplate.standaloneVerdict` :1331 → `PoisonUnresolved UnresolvedGlobal`.
`AbiCloning.originTarget` already falls to `Nothing`.

### 3.2 The resolver, on the `noInstance` path

In `postSettleTarget`, G1 gains an arm before the `originTarget` case:

```elm
        case Dict.get m ctx.origins of
            Just (Mono.OriginPap g k) ->
                if ctx.papFast then
                    resolvePapGlobal g k func argCount ctx

                else
                    PsNotCandidate "g1absentp"
```

`resolvePapGlobal` returns a new outcome `PsStampPap PapTarget`, with

```elm
type alias PapTarget =
    { specId : Mono.SpecId
    , k : Int
    , captureTypes : List Mono.MonoType   -- take k specParams
    , paramTypes : List Mono.MonoType     -- drop k specParams
    , returnType : Mono.MonoType
    }
```

consumed in `stampCall` exactly as `StampPap` is, except
`fastEvaluatorSpec = Just target.specId` and `fastEvaluator` carries the §3.6
sentinel.

### 3.3 The guards, in order — every one load-bearing

Given the site's callee expression `func`, its type `calleeType`, `argCount`,
and the member's `(g, k)`:

**P1 — callee shape.** `func` must be a `MonoVarLocal`. Same clause as LSS_025
(a var read is effect-and-bottom-free). A `MonoVarGlobal` holding a PAP CAF is
the class R3 was removed over; it stays declined.

**P2 — flat residual.** `peelStages argCount calleeType` must land (LSS_039).
The site's callee type is the PAP's *residual* — for `add 5` it is `Int -> Int`,
one stage — and a residual of two or more remaining parameters applied flat hits
the same curried-type-vs-flat-call defect LSS_039 fixed. `fargs` below is the
peeled list, `fret` the peeled return.

**P3 — a function target.** `nodes[specId]` must be `MonoDefine (MonoClosure
info body _)` or `MonoTailFunc params body _`. **A `MonoCtor` node is not
callable code** — `emitFastClosureCall @ctorSpec` would jump into a layout
descriptor. Constructor PAPs (`Just`-style) are DECLINED in v1 as
`papNonFn` and counted; P0 item 3 says whether they need their own arm.
`specParams` is `info.params` / `params`; `specRet` is `Mono.typeOf body` (the
same derivation `insertInstance` uses).

**P4 — shape.** `List.length specParams == k + List.length fargs`, and
`eqLayoutLists (List.drop k specParams) fargs`, and `eqLayout specRet fret`. This
is `papScan`'s test with `k` supplied by the member instead of inferred from
`paramCount − argCount` — strictly more information than LSS_011 has.

**P5 — UNIQUENESS, not minimum.** Among ALL specs of `g` in `specsByGlobal`,
**exactly one** must pass P3+P4. `p|<g>|<k>` is layout-blind — it names the
global and the count, not which specialization built the object. Two specs
`foo : Int -> Int -> Int` and `foo : String -> Int -> Int` both have residual
`Int -> Int`; a `p|foo|1` site with callee type `Int -> Int` matches both, and
their PAP objects hold an `Int` and a `String` respectively in slot 0 under
different unboxed bitmaps. Stamping either would load slot 0 with the wrong kind
and call the wrong code. **Two or more matches ⇒ decline `papAmbiguous`.**
`matchSpec`'s `List.minimum` is the wrong tool here and is not reused.

**P6 — Char gate.** No `MChar` in `take k specParams` (the k prefix is loaded by
the capture-load path, whose i16 load is unexercised — LSS_011's own gate).

**P7 — no captures to disagree.** A global has no captures, so LSS_009's
capture-layout unanimity is vacuous — and this is what makes the stamp sound
where instance PAPs need a unanimity check: two `p|add|1` objects differ only in
the VALUE in slot 0, which is loaded from the object, never assumed.

### 3.4 Why the stamp is sound

Premises, and where each comes from:

  1. The runtime value is a k-applied PAP of some spec of `g`. — The annotation
     is a singleton `{p|g|k}`; `p|` encodes both the global and the count by
     construction (`injectPapMember`: "one arrow deeper is a DIFFERENT PAP and
     therefore a different element"), and LSS_013/LSS_011 supply the
     singleton-means-that-value premise on this path already.
  2. It is a PAP of the UNIQUE spec P5 found. — P5.
  3. Its filled slots are `[bound args…]` in order, with that spec's declared
     kinds. — LSS_011's soundness text: `papCreate` packs `arity = TOTAL
     slots`, `eco_pap_extend` fills `n_values` slots in order with declared
     kinds. For a global, captures = 0, so the slots ARE the bound args.
  4. `_capture_abi = take k specParams` therefore names those slots' exact
     types, and `emitFastClosureCall` loads them and calls the bare spec symbol
     with `[slots…, site args…]` = the spec's full parameter row. — P4 + the
     bare-symbol rule in `generateFastDispatchCall`.
  5. `remaining_arity = |site args|` is truthful (CGEN_052): the site saturates
     the residual. — P2 + P4.

The recorded miscompile (§1.3) is impossible by construction: nothing here
rewrites the callee; the object is consulted for every bound argument.

### 3.5 Emission needs no change — with one unverified ABI point

`fastDispatchStamp` sees `|args| == |captureAbi.paramTypes|` and takes
`generateFastDispatchCall`; `|captureTypes| − papPrefix = 0` selects the bare
symbol; `fastRefBaseName` resolves `(sentinel, Just specId)` to
`specIdToFuncName registry specId` — the spec's real `func.func`.

**UNVERIFIED (review R4): a `MonoTailFunc` spec has never been a fast-dispatch
target.** Today `Instance.topLevelSpec` is set only for `MonoDefine` closures.
Whether `emitFastClosureCall @Global_$_N(loaded…, args…)` matches the calling
convention `eco.call @Global_$_N(row)` uses — return ABI, `_result_kind`,
multi-value / `$sret` returns — is the one thing this plan cannot settle by
reading. §5's runtime fixture covers Int, boxed, and tuple returns for exactly
this reason, and LSS_031's "zero undefined `_fast_evaluator`" lowering gate is
the backstop.

### 3.6 The `fastEvaluator` sentinel

`CallInfo.fastEvaluator : Maybe LambdaId` is required non-`Nothing` for the
emission path to engage, and `LambdaId` has one constructor,
`AnonymousLambda IO.Canonical Int`. A spec-targeted stamp has no lambda. v1
uses a sentinel: `AnonymousLambda <spec's home> (negate specId - 1)` — a uid no
mint produces (uids are ≥ 0), so it can never alias a real lambda.

Every reader audited:

| reader | effect of the sentinel |
|---|---|
| `Expr.fastRefBaseName` | ignored — `Just specId` wins |
| `Expr.fastDispatchStamp` / `…Staged` | shape only; LambdaId not read |
| `MapTemplate.elm:810` | already declines on `fastEvaluatorSpec /= Nothing` AND `fastPapPrefix /= Nothing` (LSS_031 clause) — doubly excluded |
| `AbiCloning.elm:2862` fingerprint `\|fe=` | text of the enclosing closure's fingerprint; per-run consistent; behaves like every other stamp field (`ck=`, `ca=`) |
| `MonoGlobalOptimize.elm:1213` | preserves it verbatim — required |
| `Ops.elm:1495` `fast_evaluators` | `ecoPapCreateGroup` siblings — a different field, not call stamps |

The tidier v2 is `type FastTarget = FastLambda LambdaId | FastSpec SpecId`
replacing the pair of fields; it touches all six readers and is deferred until
the mechanism is measured.

---

## 4. Adversarial review

Corrections are already applied above; recorded so the reasoning is not
re-derived.

| # | objection | disposition |
|---|---|---|
| R1 | `p\|` is layout-blind; two specs of `g` with equal k-suffix are indistinguishable and stamping either can load slot 0 with the wrong kind and call the wrong code | **UPHELD, plan changed — P5.** Exactly-one match, never `List.minimum`. Counted as `papAmbiguous`; P0 item 4 sizes how much this costs. |
| R2 | A ctor PAP (`Just`-style, `p\|c…`) resolves to a `MonoCtor` node, which is a layout descriptor, not code — a fast call into it is a jump to garbage | **UPHELD, plan changed — P3.** Function nodes only in v1; ctors declined and counted. |
| R3 | The residual callee type is curried too (one stage per param), so a 2-remaining-param PAP applied flat fails the same arity comparison LSS_039 fixed | **UPHELD — P2.** `peelStages` is reused; the shape key in P0 item 2 measures how often it matters. |
| R4 | `MonoTailFunc` specs have never been fast-dispatch targets; return-ABI parity with `eco.call` (sret, `_result_kind`) is asserted, not shown | **UPHELD, unresolvable by reading.** §3.5 states it; §5's fixture covers Int/boxed/tuple returns; LSS_031's lowering gate backstops. |
| R5 | The bound slots' kinds come from the object's bitmap (set at `papCreate` from ONE spec), while `_capture_abi` comes from the spec P5 chose — they agree only if it is the same spec | **ANSWERED by P5.** Uniqueness is what makes them the same spec. |
| R6 | The sentinel `LambdaId` could be emitted as a symbol somewhere and dangle (the LSS_031 class) | **ANSWERED — §3.6 audit.** Every reader either prefers the spec or already excludes spec-targeted stamps. Plus the lowering gate. |
| R7 | Two mint sites (`Translate`, `LssInfer`) registering `SourcePap` independently will drift — the LSS_017 raw-vs-qualified split was exactly that | **UPHELD, plan changed — §3.1.** One shared `Engine.papMemberIdFor`. |
| R8 | Registering a source for `p\|` could promote it into the stampable class for the DIRECT arms `p\|` exists to fence | **UPHELD — §3.1.** `memberClassOf` gets an EXPLICIT `SourcePap -> "l"` arm; `originTarget` stays `Nothing` for it; both pinned. |
| R9 | The measured bound (≤ 35 M, realistically 5–10 M) is below the bar every earlier plan in this arc was held to | **UPHELD as a fact; not a design change.** §8 states it plainly. The user has decided to pursue this as a mechanism completion. |
| R10 | `emitFastClosureCall`'s i16 capture-load path is unexercised — a `Char` bound arg would go through it | **UPHELD — P6**, inherited verbatim from LSS_011. |
| R11 | `p\|` PAPs of KERNEL functions (`p\|k…`) have no spec | **ANSWERED.** `specsByGlobal` miss ⇒ decline `papNoSpec`, counted. |
| R12 | Is `p\|` ever rewritten by LSS_019 grounding into something this resolver will not see? | **ANSWERED.** Grounding only rewrites members in `provisionalStandalone`; `p\|` is minted without that registration. |
| R13 | `postSettleTarget` is gated on `lss.postSettleDevirt`; coupling a new mechanism to an old flag muddles arms | **UPHELD — its own flag** (`lss.stamp.papFast`), checked inside the `OriginPap` arm. |
| R14 | Site count has mispredicted weight five times in this arc; 2,418 sites says nothing | **UPHELD, and it is why §2.1 leads with the dispatch bound and §2.2 demands the per-spec join.** |

---

## 5. Tests

**Unit — `compiler/tests/TestLogic/Monomorphize/AbiCloningPapGlobalTest.elm`**,
hand-built graphs in the `AbiCloningFenceTest` mould, with a registry holding
real spec nodes:

  1. A `MonoTailFunc` spec of arity 2, member `OriginPap g 1`, site
     `MonoVarLocal` of residual type `Int -> Int` applying 1 arg → `PsStampPap`
     with `captureTypes = [Int]`, `paramTypes = [Int]`, `fastPapPrefix = Just 1`,
     `fastEvaluatorSpec = Just specId`.
  2. **Ambiguity (R1)**: two specs of `g` whose k-dropped suffixes both match →
     decline `papAmbiguous`, no stamp.
  3. **Ctor target (R2)**: `MonoCtor` node → decline `papNonFn`.
  4. **Over-applying residual (R3)**: arity-3 spec, `k = 1`, site applies 2 flat
     to a curried residual → peel lands → stamp; with `flatPeel` off → decline.
  5. **Char gate (P6)**: `take k specParams` contains `MChar` → decline `char`.
  6. **Direct arm untouched (R8)**: an `OriginPap` member never reaches
     `PsStamp`; `memberClassOf` on a `SourcePap` member is `"l"`.
  7. **Flag-off**: identical stats to today (`g1absentp` count unchanged).

**Runtime — `test/elm/src/PapFastStampTest.elm`**, the R4 fixture, in the
`LssMixedSigHonestyTest` mould (non-inlinable recursive HOF, non-inlinable
callees so the inliner cannot pre-empt the question):

  - `add 5` (Int return), `pairWith "x"` (boxed return), `both 1` returning a
    tuple — each partially applied and threaded through the same HOF.
  - CHECK lines assert the VALUES. A dropped bound argument, a wrong-kind slot
    load, or a return-ABI mismatch all change the printed number; a dispatch
    counter cannot see any of them.
  - Must print identically in both flag arms.

---

## 6. Implementation, lowered

| file | change |
|---|---|
| `Compiler/AST/Monomorphized.elm` | `OriginPap Global Int` |
| `Compiler/MonoSolver/Engine.elm` | `SourcePap TOpt.Global Int`; `papMemberIdFor g k` (interns `"p\|" ++ toComparableGlobal g ++ "\|" ++ k`, records `SourcePap`); explicit `memberClassOf` arm → `"l"` |
| `Compiler/MonoSolver/Translate.elm` :4588, `LssInfer.elm` :1947 | both mints call `Engine.papMemberIdFor` |
| `Compiler/MonoSolver/Monomorphize.elm` :4947 | `buildMemberOrigins` `"p\|"` arm |
| `Compiler/GlobalOpt/Borrow/LssFacts.elm` :290, `MapTemplate.elm` :1331 | the forced arms (§3.1) |
| `Compiler/GlobalOpt/AbiCloning.elm` | `PsStampPap PapTarget`; `resolvePapGlobal`; `specFunctionRow : SpecId -> Maybe (List MonoType, MonoType)` reading `record.nodes`; the `OriginPap` arm in `postSettleTarget`; the consumer in `stampCall`; `StampCtx.papFast`; census keys `papAmbiguous` / `papNonFn` / `papNoSpec` / `papShape` and a `stampedPapGlobal` counter |
| `Compiler/Eco/Config.elm`, `Builder/Eco/Config.elm` | `LssStampConfig.papFast : Bool` (default OFF), env `ECO_MONO_LSS_PAP_FAST`, hash token `lssPF=` on the non-default arm; decoder field; `setStampPapFast` (record UPDATE, never a literal — the `globalCallee` build broke on exactly that) |
| `Compiler/GlobalOpt/MonoGlobalOptimize.elm`, `Builder/Generate.elm`, `TestLogic/TestPipeline.elm` | thread the flag to `abiCloningPass` (4th parameter again — the test call sites in `AbiCloningFenceTest`, `PostSettleDevirtTest`, `AbiCloningFlatPeelPassTest` follow) |
| `design_docs/invariants.csv` | new `LSS_040`; amend LSS_011 (spec targets) and the `injectPapMember` doc's "no devirt arm can act on it" to "no DIRECT arm" |

`resolvePapGlobal`, in full:

```elm
resolvePapGlobal : Mono.Global -> Int -> Mono.MonoExpr -> Int -> StampCtx -> PostSettleOutcome
resolvePapGlobal g k func argCount ctx =
    case func of
        Mono.MonoVarLocal _ calleeType ->
            case peelStages argCount calleeType of                        -- P2
                Nothing ->
                    PsNotCandidate "papShape|unpeelable"

                Just ( fargs, fret ) ->
                    let
                        candidates =
                            Dict.get (Mono.toComparableGlobal g) ctx.specsByGlobal
                                |> Maybe.withDefault []
                                |> List.filterMap
                                    (\( specId, _ ) ->
                                        specFunctionRow specId ctx                    -- P3
                                            |> Maybe.andThen
                                                (\( params, ret ) ->
                                                    if List.length params == k + List.length fargs
                                                        && eqLayoutLists (List.drop k params) fargs
                                                        && Mono.eqLayout ret fret                 -- P4
                                                    then
                                                        Just ( specId, params, ret )

                                                    else
                                                        Nothing
                                                )
                                    )
                    in
                    case candidates of
                        [ ( specId, params, ret ) ] ->                                -- P5
                            if List.any ((==) Mono.MChar) (List.take k params) then    -- P6
                                PsNotCandidate "papChar"

                            else
                                PsStampPap
                                    { specId = specId
                                    , k = k
                                    , captureTypes = List.take k params
                                    , paramTypes = List.drop k params
                                    , returnType = ret
                                    }

                        [] ->
                            PsNotCandidate "papNoSpec"

                        _ ->
                            PsNotCandidate "papAmbiguous"

        _ ->
            PsNotCandidate ("papCallee|" ++ calleeShape func)                        -- P1
```

`specFunctionRow` returns `Just (info.params, typeOf body)` for
`MonoDefine (MonoClosure info body _)`, `Just (params, typeOf body)` for
`MonoTailFunc params body _`, and `Nothing` for everything else (a `MonoCtor`,
a CAF, an extern) — P3 is the `Nothing`.

The `PsStampPap` consumer mirrors the `StampPap` arm at `stampCall`:1571 field
for field, with `fastEvaluator = Just (sentinel specId)`,
`fastEvaluatorSpec = Just specId`, `fastPapPrefix = Just k`, and bumps
`stampedPapGlobal` + `bumpHost "stampedPapGlobal"`.

---

## 7. Gates and measurement

| gate | requirement |
|---|---|
| flag-off byte-identity | `.mlir` identical to HEAD on the SAME source (re-run the older binary on the current tree — `plans/lss-body-mismatch-declines.md` §8.4) |
| unit | §5 pins 1–7; `elm-tests` at the 12-failure baseline |
| **lowering** | self-compile lowers with **zero undefined `_fast_evaluator`** — the LSS_031 class, and R4's backstop |
| runtime | `PapFastStampTest` prints the right values in both arms |
| E2E | `--target full`, both arms |
| bootstrap | fixed point on a `papFast=1` build (`cmp` own input vs output) |
| payoff | each arm's `.mlir` lowered and run on identical input: `sat`/`gen`, wall N≥3, `stampedPapGlobal` vs `g1absentp` |

The three measurements that decide the default flip: `stampedPapGlobal`
against 2,418; `papAmbiguous` + `papNonFn` (the ceiling, if large); and the
lowered-binary dispatch delta. `.mlir` size and Stage-6 lowering time are the
cost side.

---

## 8. The go/no-go, stated honestly

**The measured upper bound is ≤ 35.4 M dispatches (3.23 %), and the arc's one
calibration of such a bound came in at 15 % of it. Realistic expectation:
5–10 M, under 1 % of generic dispatch, under 1 % of wall.** Every earlier plan
in this arc was closed unbuilt below ~50 M.

This plan proceeds anyway, at the user's decision, on two grounds that are
different in kind from dispatch weight: it **completes a mechanism** (LSS_011's
PAP stamp exists for closures and not for globals, with no principled reason
for the asymmetry), and it does so **inside the fence** `p|` was built to be —
the direct arm stays forbidden and every soundness premise is inherited from
LSS_011 rather than invented.

**Stop conditions:** P0 item 4 showing most sites ambiguous; R4's fixture
failing on tuple/boxed returns without a small fix; or `papNonFn` dominating
(ctor PAPs), which is a different plan.

---

## 9. P0 census result (2026-09-07)

Run on `eco-pap` — census built on top of §3.1's real origin plumbing, running
`resolvePapGlobal`'s guard chain decision-for-decision and recording the
verdict instead of stamping. **The binary reproduces its own input byte for
byte**, so its SpecIds are its own and the joins are legitimate.
16:28.65 wall probed; `declinedNoInstance = 16,236` (unmoved — the census is
verdict-only, so the flag-off rail holds by construction).

### 9.1 The mechanism question: YES

```
VERDICT DISTRIBUTION  (2,429 p| sites)
   WOULDSTAMP     2,042   84.1%   <-- convertible
   papAmbiguous     175    7.2%
   papNonFn         131    5.4%
   papShapeMiss      77    3.2%
   papChar            4    0.2%
```

**84.1 % of `p|` sites pass every guard in §3.3.** All four review objections
are sized, and none is fatal:

  - **R1 (uniqueness, P5)** — `papAmbiguous` **175 sites, 7.2 %**. Real, so P5
    is load-bearing, but it does not collapse the ceiling. Stamping by
    `List.minimum` would have silently mis-stamped these.
  - **R2 (ctor targets, P3)** — `papNonFn` **131 sites, 5.4 %**. A minority;
    ctor PAPs stay a separate plan as scoped.
  - **R3 (residual peel, P2)** — vindicated: `site=1->2` is **1,192 sites,
    49 %** of the population. Half of these need the peel to be eligible at
    all; without P2 the convertible set would roughly halve.
  - **R10 (Char, P6)** — 4 sites. Negligible, guard retained.

Shape: `k=1` dominates (**1,995 / 82 %**), tailing to k=16. Site first stage is
**always 1** — consistent with `classifyGo` making every arrow one parameter
per stage, so the residual is curried exactly as LSS_039 found elsewhere.

### 9.2 The weight question: ~3 %, as predicted

| host | dispatch (UB) | % | WOULDSTAMP | all noInstance | share |
|---|---:|---:|---:|---:|---:|
| `List.foldrHelper` | 34,570,495 | 3.15 % | 870 | 970 | 89.7 % |
| `List.foldl` | 5,843,767 | 0.53 % | 106 | 1,081 | 9.8 % |
| `Basics.composeR` | 2,497,147 | 0.23 % | 46 | 100 | 46.0 % |
| `Basics.composeL` | 581,970 | 0.05 % | 50 | 134 | 37.3 % |
| every other host | **0** | 0 % | ~900 | — | — |

**Convertible dispatch, weighted by each host's WOULDSTAMP share of its
noInstance sites: 32,945,391 = 3.00 %** of 1,096,765,101.

**Still an upper bound**, and the denominator is why: it is a host's
*noInstance* sites, not its *generic-dispatching* sites, and those hosts also
carry stamped and already-direct calls that hold none of this weight. The one
calibration of such a bound in this arc (`bodyMismatch` at `foldrHelper`,
precise per-spec join) came in at **15 % of UB**. §8's stated expectation of
**5–10 M, under 1 %** stands, unrefuted.

**It is one host.** `List.foldrHelper` is 870 of the ~1,072 weighted sites and
essentially all of the measurable dispatch; every host below `composeL`
measures zero.

### 9.3 A P0 item I failed to deliver

§2.2 item 1 asked for **per-spec weight**, and `bumpNiGuard` keys on
`<host>|<why>` — I did not put `ctx.hostSpecId` in the key, so the per-spec
join could not be run even though the binary is a fixed point and the join
would have been valid. The §9.2 numbers are host-proportional in consequence.
One line in `bumpNiGuard` and a rebuild would settle it; recorded rather than
papered over, because the difference between 33 M and 5 M is the difference
between building this and closing it.

### 9.4 Verdict

  - **Build-worthiness on mechanism grounds: confirmed.** The guard chain
    admits 84 % of the population, the three declines are all small and
    principled, and P2/P5 are demonstrably load-bearing rather than defensive.
  - **Build-worthiness on weight grounds: not established, and the census did
    not change §8.** ~3 % upper bound on one host, expected 5–10 M realised.
  - **§3.1 is already built and is independently worth keeping**: it fixed a
    live two-site drift (`LssInfer`'s inference twin built the `p|` key inline
    instead of via `papMemberKey` — R7's hazard, already in the tree), and it
    gives every future census a way to name a PAP member.

The honest next step before §3.2 is the one-line `hostSpecId` fix and a
re-measure, so the decision rests on a precise number rather than a bound that
has run 6-7x hot every time it has been checked.
