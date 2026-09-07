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
info body _)` or `MonoTailFunc params body _`. ~~**A `MonoCtor` node is not
callable code** — `emitFastClosureCall @ctorSpec` would jump into a layout
descriptor.~~ **CORRECTED 2026-09-07 (§11.1): a ctor spec with fields IS
emitted as a real `func.func` whose body is one `eco.construct.custom`
(`Functions.generateCtor`).** v1 still declines constructor PAPs as `papNonFn`
only because `specFunctionRow` cannot read a row off a `MonoCtor` node; §11.1
is the one-arm fix.
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

---

## 11. Follow-ups: the two residual classes (2026-09-07)

With `papFast` on, 2,041 of 2,418 `p|` sites stamp. The 387 that still decline:

| reason | sites | by k |
|---|---|---|
| `papAmbiguous` | 175 (45.2 %) | k=1: 123, k=2: 46, k=3: 2, k=4: 4 |
| `papNonFn` | 131 (33.9 %) | k=1: 111, k=2: 16, k=3: 3, k=4: 1 |
| `papShapeMiss` | 77 (19.9 %) | k=1: 59, k=2: 12, k=3: 3, k=4: 3 |
| `papChar` | 4 (1.0 %) | k=1: 4 |

Both of the big two are fixable, and both fixes are smaller than this plan
first assumed. Neither is built.

### 11.1 `papNonFn` — constructor PAPs are a one-arm fix

**The premise in §3.3 P3 was wrong.** A constructor spec with fields is
emitted as callable code: `Functions.generateCtor` produces
`func.func @Rect_$_N(%arg0, %arg1) -> !eco.value` whose entire body is one
`eco.construct.custom` and a return. It is `specFunctionRow` that cannot see
this — a `MonoCtor` node carries no `params`/`body`, so the row lookup
returns `Nothing` and P3 declines. The PAP object of a constructor is built by
the same `papCreate @Ctor_$_N` + `papExtend` path as a function's, so its
evaluator IS that function and its slots ARE the bound fields.

The "special kind of call that compiles down to allocating the shape" already
exists for the saturated DIRECT case (`Expr.elm:3646`, `generateCustomCreateHeap`
— an inline allocation, no call). For the PAP case the fast stamp is the
right tool unchanged: `emitFastClosureCall @Rect_$_N(slot0, w)` is exactly the
call the object would make anyway minus the dispatch, and the E1.2/E1.3 fold
rebuilds it as a direct LLVM call that the AlwaysInliner can fold into the
caller — the allocation lands inline through existing machinery.

**Fix:**

```elm
specFunctionRow specId ctx =
    case Array.get specId ctx.specNodes of
        ...
        Just (Just (Mono.MonoCtor _ ty)) ->
            -- the same derivation generateCtor uses
            Just (Mono.decomposeFunctionType ty)
```

**Guard, found by reading `computeCtorLayout`:** a ctor field is unboxed only
when `canUnbox ty && idx < 24` (`maxTypedSlots`), while the fast call passes
every `Int`/`Float`/`Char` at `monoTypeToAbi` (always unboxed). A constructor
with more than 24 fields would mismatch on the tail. The arm must decline
those — or, cleaner, compute the ctor layout and require every field's ABI to
equal `monoTypeToAbi` of its type. Nullary constructors are constants and can
never be a PAP; enum constructors are `MonoEnum`, not `MonoCtor`, and are not
reached.

**Gate:** a ctor-PAP fixture in `PapFastStampTest.elm` with an `Int`, a `Bool`
and a boxed field, k = 1 and k = 2, both arms identical; `papNonFn` on the
self-compile 131 → 0 (the >24-field residue is expected to be 0). Rides
`papFast` — it is a completion of the same mechanism, not a new one.

### 11.2 `papAmbiguous` — qualify the `p|` member by the bound arguments' layout

**What the mint site has in hand.** `Translate.injectPapMember global funcVar
argCount` (and its twin in `LssInfer`, both through the shared
`Engine.papMemberIdFor`) holds the global, `k`, and `funcVar` — the callee's
union-find variable, from which the FULL monomorphic callee type is readable
(`resultVarAfter` already walks that spine). So the types of the `k` bound
arguments are available at the moment the id is minted. What is NOT
available is a SpecId: specs are enqueued by `(global, full type)` elsewhere
and numbered in enqueue order.

**Fix v1 — LSS_024's move applied to `p|`:** extend the key with the LAYOUT
of the bound arguments,

```
p|<global>|<k>|<shallowLayoutKey of bound arg 1>,…,<bound arg k>
```

and carry the same layouts on the origin (`OriginPap g k boundLayouts`) so
`papResolve` adds one clause to P4: `eqLayoutLists (take k params)
boundLayouts`. `describe 3` and `describe 1.5` then mint DIFFERENT members
(`…|I` vs `…|F`) and each resolves to exactly one spec. This closes the
slot-KIND hazard — reading a float's bits as an integer, or misleading the GC
about a pointer — which is the dangerous half of the ambiguity.

The key stays free of member ids and SpecIds, so it cannot reopen LSS_018's
type-in-key spiral; `shallowLayoutKey` is annotation-blind, so the layout read
at translate time is already final even though lambda-set annotations settle
later.

**What v1 deliberately does not fix, and must not:** two copies of the global
whose bound-argument layouts are EQUAL — `List Int` vs `List String` in slot
0 — stay ambiguous and stay declined. Same-layout copies are not
interchangeable when the bound value is or contains a function: copy 1's
inner call site may be direct-stamped for lambda A while the object holds
lambda B. That is the E11 hijack class. Only qualifying by the copy itself
resolves it, which needs the SpecId at mint time — v2, and only if the residue
justifies it.

**P0 for v1 (one census line, flag-on binary):** split `papAmbiguous` into
`kindDiffers` (the matching specs' `take k params` differ in layout — v1
converts these) and `sameLayout` (v1 cannot). That sizes v1 before it is
built; the 175 are worth converting only if `kindDiffers` dominates.

**Cost and gating:** the key change happens in Translate/LssInfer, UPSTREAM of
AbiCloning — it alters member identity, hence set contents, hence potentially
stamps elsewhere and LSS analysis volume (more members). It therefore needs
its OWN flag (`lss.stamp.papLayoutKey`, hash token, default off) with the
flag-off byte-identity rail, not a ride on `papFast`. Both mint sites must
compute the identical key — the shared `papMemberIdFor` takes the layouts as
an argument so neither can drift (the LSS_017 two-site lesson). Every consumer
that parses `p|` keys by splitting on `|` and reading segment 3 as `k` keeps
working; nothing reads past it today.

---

## 10. Built and measured (2026-09-07)

Everything in §6 is built, under `lss.stamp.papFast` (`ECO_MONO_LSS_PAP_FAST`,
hash token `lssPF=`), **DEFAULT-ON since 2026-09-07** (§10.4; E2E re-run on
the flipped tree, §10.6).
`papResolve` is ONE function returning both the stamp target and the census
key, so the guard chain that was measured in §9 is the guard chain that ships.

### 10.1 Gates

| gate | result |
|---|---|
| flag-off byte-identity | pre-papFast binary and papFast binary emit **byte-identical** `.mlir` on the same source; bootstrap fixed point |
| unit | `AbiCloningPapFastPassTest` 7/7 (differential, P5 ambiguity, P3 non-function, P6 Char, P2 residual peel, P4 shape miss, k=2); suite 13,453 / 12 = baseline + 7 |
| lowering (LSS_031) | flag-on self-compile lowers, **zero undefined `_fast_evaluator`** (the one `undefined` grep hit is the `UndefinedFunctionPass` timing line, present identically flag-off) |
| runtime fixture | `PapFastStampTest`: k=1, k=2, boxed return, tuple return — all four sites stamp (`stampedPapGlobal=4`), all four values correct and **identical across arms**. R4's return-ABI question is answered by execution, and by reading: the bare spec symbol keeps its un-promoted signature (`$sret`/`$psplit` are separate workers behind a shim) and `generateTailFunc` emits the same params→return shape |
| bootstrap, flag on | the flag-on compiler reproduces its own input: **fixed point** |
| E2E, both arms | **1,720 / 1,720** flag-off and flag-on (1,719 + `PapFastStampTest`). The flag-on arm is proven live: the fixture's harness artifact carries a `_pap_prefix` stamp, which only the new code under the flag can produce |

### 10.2 Payoff

Self-compile, `stampedPapGlobal = 2,041` of 2,418 `p|` sites (84.4 % — the P0
census said 84.1 % `WOULDSTAMP`). `declinedNoInstance` 16,236 → 14,203. `.mlir`
+0.13 % (15,501,076 → 15,521,029 bytes). Residual 387 sites, all four classes
counted (§11).

Dispatch A/B: the unstamped and stamped compilers, **same input, same flags,
byte-identical output** (semantic equivalence), under the caller-attributed
`eco_apply_closure_eval` uprobe:

| | generic dispatch | wall (under probe) | peak RSS |
|---|---|---|---|
| unstamped (`eco-pf`) | 1,098,197,360 | 16:29.80 | 13.46 GB |
| stamped (`eco-pfon`) | 933,960,160 | 15:13.56 | 13.45 GB |
| delta | **−164,237,200 (−14.96 %)** | −7.7 % (N=1, PROBE-INFLATED — retracted, see below) | flat |

**Protocol benchmark (`benchmarks/lss-opt.md` Run AP, no probe, census flags
off, one cold run per arm):** wall 7:47.85 → 7:45.69 (467.9 → 465.7 s) =
**FLAT** by the protocol's 3 % bar; minors 2,096 = 2,096, majors 8 = 8,
promoted +0.07 %; every LSS analysis counter identical to the digit. The
−7.7 % above was measured under the `eco_apply_closure_eval` uprobe, which
taxes each of the 1.1 G dispatches and so exaggerates the benefit of removing
them — it is retracted as a wall figure. By the repo's wall model
(47.7 ns/dispatch, `memory: dispatch-source-census-io-monad`), −164 M
dispatches is ~7.8 s of 468 s, ~1.7 % — sub-noise by construction. The
dispatch count is exact; the wall on this workload is not a signal.

Where it came from (name-keyed — the two binaries are different programs):

| host | unstamped | stamped | delta |
|---|---|---|---|
| `System.TypeCheck.IO.map` | 152,199,040 | 99,907,468 | −52,291,572 |
| `System.TypeCheck.IO.andThen` | 285,373,734 | 234,749,067 | −50,624,667 |
| `List.any` | 19,259,305 | 3,279,488 | −15,979,817 |
| `Maybe.map` | 13,259,522 | 182 | −13,259,340 |
| `List.foldrHelper` | 31,993,377 | 23,749,195 | −8,244,182 |
| `List.maybeCons` | 6,137,762 | 43,832 | −6,093,930 |

No host got worse (the tail of the join is +0). The IO monad's callbacks are
PAPs of globals — `IO.map (f x)`, `andThen (k a)` — which is why the two
monad hosts carry 63 % of the win, and why `List.any` and `Maybe.map`, noted
earlier as "take 1-arg callbacks so something else blocks them", were blocked
by exactly this. By class: elm-spec rows −148.4 M, elm-lambda rows −11.5 M,
runtime rows −4.3 M; `eco_apply_closure_eval`'s self-attributed 91.98 M is
identical in both arms.

### 10.3 The "upper bound" was not one — the take defect, fourth occurrence

§9.2's per-spec bound of 111,283,652 (10.14 %) was read off the
`pap WOULDSTAMP by host+spec top400` line — a `List.take 400` **ranked by site
count**. The 2,041 sites fragment across far more than 400 `(host, spec)`
keys, and the dropped tail held hot single-site specs. The realized −164 M
exceeds the "bound" by 48 %. This is the defect that hid `IO.andThen` from
two censuses and understated `bodyMismatch` by 2×; here it ran the other
way. The `papSites` line is still `List.take 400` — now census-gated
(§10.5) but NOT yet untruncated; that is a one-constant change for the next
census pass, and the memory entry records the rule: a weight-joined report
line must never be truncated.

§8's honest expectation was 5–10 M. The measured win is ~20× that, and the
plan proceeded "as a mechanism completion" on the user's decision against the
weight argument. The weight argument was wrong because its census was
wrong, not because the reasoning from a correct census would have been.

### 10.4 The flip

§7's three deciders: `stampedPapGlobal` 2,041 / 2,418 ✓; `papAmbiguous +
papNonFn` = 306, not a ceiling ✓; lowered-binary dispatch −14.96 % ✓. Cost
side: `.mlir` +0.13 %, Stage-6 lowering time unchanged to the second, RSS
flat, protocol wall FLAT (Run AP). The flip to DEFAULT-ON is recommended on
the dispatch counter — the same basis as LSS_025's flip, which was also
dispatch-positive and wall-neutral; it is the user's call, as it was for
LSS_038/LSS_039.

### 10.5 Housekeeping in the same change

`lss.stamp.census` (`ECO_MONO_LSS_CENSUS`) gates every per-site census Dict —
`byHost`, `niGuard`, `shape`, `papSites` — split from `lss.report` for the
`qCensus` reason. The bodyMismatch census was deleted (its plan is closed
twice, §9 of that plan). `LssConfig` is at the 32-slot GC-scan cap: both new
flags live in `LssStampConfig`, and a 33rd top-level field fails at Stage-6
lowering, not at typecheck.

### 10.6 Flipped DEFAULT-ON (2026-09-07)

`defaultLss.stamp.papFast = True`; `ECO_MONO_LSS_PAP_FAST=0` is the escape
hatch and rides `lssPF=0` in the config hash. Gates re-run on the flipped tree
with NO env var set (the harness cache is env/mtime-blind, so `test/elm/src`
was touched and every `eco-stuff` cache deleted first):

| gate | result |
|---|---|
| E2E, default flags | **1,720 / 1,720**; the fixture's harness artifact carries a `_pap_prefix` stamp with nothing in the environment — the default is live |
| elm-tests, flipped tree | 13,453 / 12 = baseline (39 test sites consume `Config.default*` as a constant, which an env-flag arm cannot reach — this run reaches them) |
| protocol benchmark | Run AP, `benchmarks/lss-opt.md`: wall FLAT, minors/majors identical, analysis counters identical |

### 11.1.1 Built (2026-09-07)

`specFunctionRow` gains the `MonoCtor shape ty` arm: row = `shape.fieldTypes`
(the same list `generateCtor` builds the `func.func` parameters from — source
order, `computeCtorLayout` does not reorder), return = the decomposed result
of `ty`; declines constructors wider than `ctorTypedSlotCap = 24`. Rides
`papFast`; no new flag.

| self-compile | before | after |
|---|---|---|
| `stampedPapGlobal` | 2,041 | **2,135** (+94) |
| `papNonFn` | 131 | **0** |
| `papAmbiguous` | 175 | 201 (+26) |
| `papShapeMiss` | 77 | 88 (+11) |
| `declinedNoInstance` | 14,203 | 14,109 |

The 131 redistribute exactly: 94 stamp, 26 become ambiguous (two ctor specs
of one constructor with the same residual layout — `Json.Decode.Field` has
three live specs), 11 shape-miss. So P5 does its job on constructors too.

The 94 new stamps in the compiler's own code, read off the text diff of the
pre-fix and post-fix compilers' outputs on the same source: **88 hunks, every
one a `segmentation_unknown` papExtend becoming `singleton_fast` with a
constructor spec as `_fast_evaluator`** — `Json.Decode.Field_$_30649` ×15,
`Field_$_28507` ×10, `Field_$_2138` ×9, `Failure`, `DecodeProblem`,
`IO.App1`, `JavaScript.Builder.ExprInfix`, and twelve `Language.GLSL.Syntax`
constructors. Nothing else in the artifact moved.

Gates: flag-off (`ECO_MONO_LSS_PAP_FAST=0`) byte-identical between the
pre-fix and post-fix binaries on the same source; post-fix compiler is a
bootstrap fixed point; zero undefined `_fast_evaluator`; `PapFastStampTest`
gains `Rect Int Bool (List Int)` at k=1 and k=2 (an unboxed Int, a Bool that
is `!eco.value` in a heap field, a boxed list) — identical across arms, all
six CHECK lines pass, seven sites stamped. Pins 8 (ctor stamps) and 9 (25
fields declines) in `AbiCloningPapFastPassTest`. E2E on the post-fix tree at
default flags **1,720 / 1,720**; elm-tests **13,455 / 12** (baseline + the two
pins).

**Payoff, honestly cold.** Dispatch A/B (pre-fix vs post-fix compiler,
identical input and flags, under the caller-attributed uprobe): 933,925,039 →
933,006,001 = **−919,038 (−0.10 %)**, essentially all at `IO.map`
(−897,742 — constructor callbacks in the JSON decoders, `IO.map (Field name)`
and kin); the remaining rows are `$psplit`/`$sret` renumbering noise that nets
to zero. The two arms' outputs are byte-identical to `ctA`/`ctB` respectively,
so the artifact delta IS the 88 stamps and nothing else. Protocol run: Run AQ
in `benchmarks/lss-opt.md`. This was a mechanism completion; the plan said so
before it was built, and the number agrees.

A trap recorded for the next person: the first "fixed point" check compared
the OLD binary's output with the NEW binary's output on the same source and
"failed" by exactly the 88 new stamps. A new stamping arm needs one more
generation before the fixed-point comparison is between two compilers that
both carry it.

### 11.2.1 P0 result — v1 is a NO-GO (2026-09-07)

`papAmbiguous` split on the flag-on self-compile (census-only change in
`papResolve`, key `papAmbiguous-kindDiffers` / `-sameLayout`):

| class | sites | v1 (layout-qualified key) |
|---|---|---|
| `kindDiffers` — matching specs' k-prefix layouts differ | **24** | converts |
| `sameLayout` — identical prefix layouts, copies differ only in annotations | **177** | cannot; must stay declined (E11) |

§11.2's own gate said "worth converting only if `kindDiffers` dominates". It is
12 % of the class. Against that, the mint-side change is wider than §11.2
counted: seven sites mint or re-derive `p|<g>|<d>` — `injectPapMember` and
its successor walk, `injectPapMemberInfer` and its walk, `stampSpineGo`
(registration self-identity), `injectPapSuccessors` (reference spine), and
`settleVarSuccessors`, which parses the predecessor's key string and would
have to append the layouts of the params consumed at that arrow. And the
inference-time twin mints BEFORE the types Translate sees are resolved: a key
that differs between the two (flex at inference, `Int` at translate) puts a
phantom second member into every `p|` set, and every currently-stamping site
— the −164 M — stops stamping. Twenty-four sites do not buy that. **v1 is
closed unbuilt; the census split stays (it is `lss.stamp.census`-gated).**

What the 177 are: same-layout copies of one global — LSS_024 layout-qualified
specs that differ only in lambda-set annotations somewhere in their type. If
the difference sits in the RESIDUAL positions (site args or return), the site
already knows its own annotated residual and could pick the unique candidate
whose annotated `(drop k params, ret)` equals it — a consumer-side refinement
that touches no mint. If the difference sits in the BOUND-argument positions,
nothing short of the SpecId separates them. Sizing that split is the next
census (§11.2.2); it is one more line in `papResolve`.

### 11.2.2 The consumer-side route converts nothing — §11.2 CLOSED UNBUILT

Second census, same binary class, splitting the 177 `sameLayout` sites by
whether the site's own ANNOTATED residual `(fargs, fret)` equals exactly one
candidate's annotated `(drop k params, ret)`:

| class | sites |
|---|---|
| `residualUnique` — the residual picks one copy | **0** |
| `residualNone` | 0 |
| `residualMany` — every copy's residual equals the site's | **177** |

So the copies differ ONLY in the bound-argument positions: the bound value is,
or contains, a function whose lambda set differs between the copies. That is
the E11 hijack class by definition — copy A's inner call sites may be
direct-stamped for lambda A while the object holds lambda B — and the correct
verdict for those sites is the one P5 already gives. Nothing short of the
SpecId at mint time separates them, and that is the same seven-site
identity change as v1, carrying the same phantom-member hazard, for the same
177 sites.

**Verdict.** v1 converts 24 sites at a seven-site identity risk; the
consumer-side refinement converts 0; v2 would convert the 177 at the same
risk. `papAmbiguous` is the guard doing its job. Closed unbuilt on two
censuses. The two census sub-splits were removed again once they had
answered their question (the rule from the bodyMismatch cleanup);
`papAmbiguous` is a single counter.

Final `p|` residual after this plan: 201 ambiguous (correctly declined), 88
`papShapeMiss`, 4 `papChar`; 2,135 of 2,418 stamped.
