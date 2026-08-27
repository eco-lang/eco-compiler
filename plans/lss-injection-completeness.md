# LSS injection completeness: total member injection over the producer forms

**Status: PLANNED (2026-08-26), lowered to implementation detail the same day.
All code anchors below were verified against HEAD on 2026-08-26 — function
names, signatures, and line regions are real, not sketched.** Supersedes the
deleted `plans/lss-pap-argument-members.md` outline (argument-scoped, never
implemented).

**One sentence.** Make every arrow-typed PRODUCER inject a lambda-set member —
the paper's own soundness mechanism — starting with the one known-missing form
(partial applications of known globals, expression-level), plus the census
that turns "totality" into a number whose zero-modulo-kernel licenses
solver-root sharing with no widening guard.

---

## §0 Why (compressed — full argument in `lss-solver-root-signature-identity.md` §3 P0)

The `arrowSolverRoots` miscompile: in `\flg -> if flg then (::) x else
identity`, bare `identity` injects `g|Basics.identity` (position-independent
since `refIdentity`) while the `(::) x` PARTIAL APPLICATION injects nothing;
the one-sided set `{identity}` is quarantined at defaults only by slot
fragmentation, and root sharing delivered it to a consumer where devirt
compiled `Task.map f` into the identity map. The paper cannot express the bug:
L^src has no currying, `(::) x` is necessarily a λ, and 𝒬 injects every λ
(Fig. 6) — **totality, not widening, is the paper's soundness mechanism**.
The `readPointCell` objection is retracted (its inner lambda IS the element
and already travels: GAP-2 row 11, `ord0: m=1,l`).

## §1 The invariant and the producer enumeration

**INVARIANT: a lambda-set class is devirt-complete iff every producer position
whose value can flow into it injected a member.**

| producer form | Eco status | this plan |
|---|---|---|
| lambda literal | ✓ `l|` | — |
| bare `VarGlobal/VarEnum/VarBox/VarCycle` | ✓ `g|`/`c|`/`k|` via `classifyRef` + arg path | — |
| **partial application, KNOWN callee** | ✗ | **Phase 1** |
| partial application, UNKNOWN callee | ✗ | census-counted; deferred (transport, not injection) |
| full call returning a function | signature facts at residual ordinals; totality unproven | census `carried/carriedTrivial` buckets |
| branch/case joins | ✓ `joinCfHub` — honest iff branches injected | inherits |
| container/field reads | ✓ sets ride the element type | inherits |
| kernel/FFI-produced closures | permanent ⊤ boundary (§3.6 of the parent register) | excluded from the target |

---

## §2 Implementation

### §2.0 Code anchors (all verified 2026-08-26)

| thing | where | shape |
|---|---|---|
| slow-path global call | `Translate.translateGlobalCallSlow` (`Translate.elm:2990`) | `instantiateLss → Ok (funcVar, s1)` → `unifyParamsCollect funcVar args → argStash` → `unifyResultWithExpected funcVar argCount callCanType` → `translateArgsWith` → `censusArgs` → **`Store.zonkToMono funcVar` (line 3036)** → `callResultType` → `enqueueSpec` |
| fast-path router | `Translate.translateGlobalCall` (`:2551`) — `lssFastOk` (`:2593`) gates M2a/M2b fast paths; NOTE `lssFastOk` checks the ARGS for arrows but **not the result**, so a partial call with ground args (e.g. `(::) x`) takes the FAST path today |
| the residual-Point walker — **already exists** | `Translate.resultVarAfter : IO.Variable -> Int -> Step (Maybe IO.Variable)` (`:4262`) — descends `n` arrows via `UF.get`/`arrowParts` |
| the injector — already exists | `LssInfer.injectSpineMemberId : Int -> Int -> IO.Variable -> Step ()` (`LssInfer.elm:2340`) — writes `mid` into the slot of EACH of the first `arity` arrows from the given Point (`spineGoC`; alias-transparent; cycle-safe via `seen`) |
| arity | `LssInfer.declaredArityOf : TOpt.Global -> Int -> Engine.S -> Int` (`:2144`) — node-table walk, fuel-bounded, `TrackedFunction` arm fixed 2026-08-23; floors at 1 on fuel exhaustion (sound: floor ⇒ classified saturated ⇒ no injection) |
| member-id mint + kernel-alias dispatch (the template) | `Translate.injectArgLambdaMember` `VarGlobal` arm (`:1611-1631`): `LssInfer.kernelAliasOf g` → `standaloneArgKernelMember ("k\|" ++ home ++ "." ++ name) …` else `standaloneArgMember ("g\|" ++ TOpt.toComparableGlobal g) g …` |
| `standaloneArgMember` (`:3724`) | `Engine.standaloneMemberIdFor key g` `andThen` `injectSpineMemberId (spineDepthForGlobal g s) mid canVar` |
| `standaloneArgKernelMember` (`:3737`) | `Engine.kernelMemberIdFor key k` `andThen` `injectSpineMemberId 1 mid canVar` — **kernels are HEAD-ONLY** ("`kernelToSig` misaligns at inner arrows") |
| the load→inject→zonk template | `Translate.classifyRef` (`:1595-1618`) — every fallback arm degrades to the storeless answer, never fails the build |
| inference-side residual | `LssInfer.applyCalleeAt` (`:1640`) — both branches call `unifyCallShape funcVar args meta → Ok (callVar, s2)`; **`callVar` IS the loaded `meta.tipe` Point = the partial call's residual type**, unified with the instantiation's rest via `unifyParamsBestEffort` |
| census plumbing | `Engine.bumpArgFlowCensus` (`Engine.elm:949`) — gated on `s.env.lss.report`, keys render as `ARGF\t<key>\t<count>` |
| existing saturation census (reuse its classification) | `Translate.censusOneArg` region `:3133-3203` — computes `supplied`, `maybeDeclared = declaredArityOf g 8`, tags `partial/exact/over/unknown` |
| translate main dispatch (P0 hook) | `Translate.translate` (`:320`) — the single `case expr of` |

### §2.1 Phase 0 — the injection-totality census (build FIRST, instrument-only)

**Hook**: a report-gated tail call in `Translate.translate`'s wrapper — wrap
the existing dispatch:

```elm
translate : TOpt.Expr TypeIds.MVarId -> Step Mono.MonoExpr
translate expr s0 =
    case translateDispatch expr s0 of          -- the current body, renamed
        Err e ->
            Err e

        Ok ( monoExpr, s1 ) ->
            Ok ( monoExpr, censusProducer expr s1 )
```

```elm
-- Injection-totality census (plans/lss-injection-completeness.md §2.1).
-- REPORT-GATED; one head-arrow test per node when on, nothing when off.
-- Reads triviality via Engine.memoizedSignatureTrivial ONLY — forcing a
-- signature here would move member-id allocation order, and `report` is
-- excluded from the config hash (the censusArgs lesson, Translate.elm:3022).
censusProducer : TOpt.Expr TypeIds.MVarId -> Engine.S -> Engine.S
censusProducer expr s =
    if not (s.env.lss.report && headIsArrow (TOpt.typeOf expr)) then
        s
    else
        Engine.bumpArgFlowCensus ("inj|" ++ producerKey expr s) s
```

`headIsArrow` follows filled aliases to a `Can.TLambda` head (mirror
`canTypeHasArrow`'s alias arms, but head-position only). `producerKey`
classifies:

| expr form | key |
|---|---|
| `Function`/`TrackedFunction` | `lambda` |
| `VarGlobal/VarEnum/VarBox/VarCycle` | `ref` |
| `VarKernel` | `kernel` |
| `Call (VarGlobal g) args` etc., `declaredArityOf g 8 s > length args` | **`papKnown`** — the headline; split `papKnown|d<depth>` |
| same, `<=` | `callResult|trivial` / `callResult|nontrivial` via `Engine.memoizedSignatureTrivial` (`Nothing` ⇒ `callResult|unmemoized`) |
| `Call` with any other func | `callUnknownCallee` |
| `If`/`Case` | `branch` (a join, not a producer — counted for the denominator) |
| everything else | `other|<ctor>` for the top few, `other` for the rest |

**P0 makes no injected/none claim it cannot decide locally** — `papKnown` IS
the none-population today by construction (nothing injects there), and
`callResult|trivial` is the "totality unproven" bucket for follow-up. That is
the honest v1 of the instrument; per-form write-provenance refinement is a
follow-up if a form's number demands it.

**Gates (P0):** census-on vs census-off `out.mlir` **byte-identical** (the
§5.1-Q precedent: inertness proven, not asserted); the `inj|` table renders in
the report. **Deliverable:** the HEAD totality table — expect `papKnown` in
the low thousands (the old census's 2,475 argument sites are a floor; this
instrument is the first that sees branch/store positions too).

#### P0 MEASURED 2026-08-26 — ALL GATES PASS; the totality gap is 6.5–7.4 % of producer positions and Phase 1 closes ≥84 % of it

Self-compile, cold, census-on vs census-off: `out.mlir` **byte-identical**
(`cmp` clean), walls 6:48.97 / 6:33.10 (in the recent census-leg band —
the per-node hook is free), ledger `RECONCILES=yes`, and the ledger matches
the refIdentity-flip confirmation leg to within corpus noise (k1=195,028
kN=3,387 top=20,824 var=274,349 — the tree-consistency check).

163,535 arrow-headed nodes classified:

| form | count | reading |
|---|---:|---|
| `local` | 102,564 | propagation, not production (64 % of arrow-headed nodes) |
| `lambda` | 37,013 | injected ✓ |
| `ref` | 12,201 | injected ✓ (refIdentity) |
| **`papKnown` d1..d5** | **3,624** | **THE GAP — none inject** (d1=3,020 / d2=552 / d3=46 / d4=1 / d5=5) |
| `kernel` + `callKernel` | 3,097 | the permanent ⊤ boundary |
| `callResult\|nontrivial` | 1,625 | carried by fact-bearing signatures ✓ |
| `let` / `read` / `branch` / `accessor` | 2,773 | joins/propagation |
| `callUnknownCallee` | 533 | contains the deferred unknown-callee partials (≤533) |
| `callResult\|trivial` | **137** | the "totality unproven" bucket — tiny |
| `callResult\|unmemoized` | 0 | every consulted callee was memoized |
| `other` | 8 | negligible; no split needed |

**Readings that size the programme:**

1. **`papKnown` = 3,624** — 46 % larger than the old argument-scoped census
   (2,475): the expression-level view sees branch results, stored values and
   returned PAPs the argument view never could. Depth-1 dominates at 83.3 %
   (vs 87.7 % argument-only). This is Phase 1's exact target population, and
   its post-P1 acceptance is `papKnown|* = 0`.
2. **The unproven-carried bucket is nearly empty**: `callResult|trivial` = 137
   against 1,625 nontrivial — 92 % of call-result function values flow through
   fact-carrying signatures. The §1 "totality unproven" worry prices out at
   ~0.24 % of producer positions.
3. **Totality gap modulo kernel** = 3,624 (papKnown) + ≤533 (unknown-callee
   partial subset) + 137 (trivial-carried) ≈ **3,761–4,294 of ~57,700 producer
   positions (6.5–7.4 %)**. Phase 1 alone closes ≥84 % of the gap; with the
   trivial-carried bucket measured separately, the residue after P1 is the
   unknown-callee partial subset (≤533, transport-class) + 137.
4. `other` = 8 — the enumeration was effectively total; no constructor split
   needed.

**Commands** (house methodology, from `/work`):

```bash
BK=build/compiler/build-kernel
rm -f "$BK/bin/eco-compiler.mlir" "$BK/bin/eco-compiler"; rm -rf "$BK/eco-stuff"
ECO_MONO_ENGINE=solver ECO_MONO_LSS=1 ECO_BORROW=1 ECO_AGG_PROMOTE=1 \
    cmake --build build --target eco-compiler
# census leg (cold):
rm -rf "$BK/eco-stuff"
( cd "$BK" && ECO_MONO_ENGINE=solver ECO_MONO_LSS=1 ECO_MONO_LSS_REPORT=1 \
    ./bin/eco-compiler make --optimize --kernel-package eco/compiler \
      --local-package eco/kernel=/work/eco-kernel-cpp \
      --output=bin/p0-out.mlir /work/compiler/src/Terminal/Main.elm \
      2> p0.stderr )
grep -a $'^ARGF\tinj|' "$BK/p0.stderr" | sort
# byte-identity: repeat WITHOUT REPORT → cmp the two out.mlir
```

### §2.2 Phase 1a — flag plumbing (`lss.papMembers`)

Mirror `refIdentity`'s five sites exactly:

1. `Compiler/Eco/Config.elm` `LssConfig`: add `papMembers : Bool` with a doc
   comment (cite this plan; DEFAULT-OFF; env `ECO_MONO_LSS_PAP_MEMBERS`;
   token `lssPM=` — verified free against the existing token set).
2. `defaultLss`: `papMembers = False`.
3. `lssDecoder` (`Config.elm:830-845`): **append at the END of the apply
   chain** — the chain is POSITIONAL and the file itself warns: *"APPEND
   ONLY, and LAST: … an insertion anywhere above silently swaps two flags'
   values and still type-checks."*
4. The hash-token block (pattern at `Config.elm:1216`): emit `lssPM=1|0` when
   `/= defaultLss.papMembers`.
5. `Builder/Eco/Config.elm`: `applyLssPapMembersOverride` — copy
   `applyLssRefIdentityOverride` (`:1773-1787`) verbatim with the field
   swapped, plus one `Utils.envLookupEnv "ECO_MONO_LSS_PAP_MEMBERS"` row in
   the override Task chain (pattern at `:182-192`).

Also: `TestLogic/TestPipeline.elm` consumes `Config.defaultLss` positionally
in two places (`:409`, `:527`) — record-update syntax there is unaffected by
a new field, but rebuild elm-tests to confirm.

### §2.3 Phase 1b — translate-side injection

**Routing first.** Partial calls with ground args currently take the M2a/M2b
FAST paths (`lssFastOk` never looks at the result type), and the fast paths
never touch the store — no slot exists to inject into. Flag-on, partials must
take the slow path. In `translateGlobalCall` (`:2560`), extend the gate:

```elm
-- lss.papMembers: a PARTIAL application's residual arrows must carry the
-- callee's member (plans/lss-injection-completeness.md §2.3), and only the
-- slow path has the store in hand. Pre-filter on the RESULT mentioning an
-- arrow (a saturated ground call cannot be partial), so the arity walk only
-- runs on candidate sites.
needsPapSlow =
    s.env.lss.enabled
        && s.env.lss.papMembers
        && canTypeHasArrow callCanType
        && LssInfer.declaredArityOf global 8 s > List.length args
```

and route `needsPapSlow → translateGlobalCallSlow` alongside `not fastOk`.
(Cost: one node-table lookup + fuel-8 walk, only at calls whose result
mentions an arrow, only flag-on.)

**The injection.** In `translateGlobalCallSlow`, insert between
`unifyResultWithExpected`'s `Ok` (`:3016`) and `translateArgsWith` — i.e.
**strictly before `Store.zonkToMono funcVar` (`:3036`)**, so the member is in
the store when the demand type is read (it must reach `funcMonoType`'s
annotations, the spec key, and `resultMonoType`):

```elm
case injectPapMember global funcVar argCount s3 of
    Err e ->
        Err e

    Ok ( _, s3a ) ->
        case translateArgsWith argStash args s3a of
            ...
```

**MEMBER IDENTITY — THE DRAFTED SKETCH BELOW WAS WRONG AND MISCOMPILED; READ
THIS FIRST (corrected 2026-08-26 from the first flag-on self-compile).**

The sketch said to reuse the bare-reference mint family, so `(::) x` would
yield `k|List.cons`. That conflates two different values. A `g|X` / `k|X`
member is registered `SourceGlobal`/`SourceKernel`
(`Engine.standaloneMemberIdFor`), which places it in the STAMPABLE class:
devirt reads it as *"this value IS X"* and rewrites the site to a direct call
of X's spec. **A partial application is not X — it is X with `k` arguments
already bound — so that rewrite silently drops the captured arguments.**

Measured: `IO.traverseList (IO.traverseTuple f) args`
(`Compiler/Type/Type.elm:519` plus five sibling sites) made devirt call
`traverseTuple`'s 2-arity spec with ONE argument, and monomorphization aborted
with `MonoSolver.unify-mismatch: demandUnify` — annotation
`(b -> IO c) -> (a,b) -> IO (a,c)` against a demand one arrow short. **The
repair for a false-singleton miscompile had reproduced the same class of
miscompile by a different route.**

**The faithful identity is a DISTINCT element, `p|<global>|<supplied>`**, minted
via `Engine.memberIdFor` with NO source registration — `memberClassOf` then
reports the declining class `l`, no devirt arm can act on it, and it still
occupies the set, which is the entire point (an honest >=2 set is what kills
the false singleton). This is the paper's own reading: L^src is curry-free, so
`(::) x` is its own λ with its OWN element, distinct from `cons`'s. Exploiting
PAP members (staged direct calls) needs prefix-aware machinery — out of scope
(§6).

**Depth is HEAD-ONLY for the same reason**: one arrow deeper the value is a
different PAP (`supplied + 1` bound) and therefore a different element that
`p|<global>|<supplied>` would misname. Injecting one id down a spine is what
`g|` may do (every residual of an *unapplied* global is still that global —
LSS_013) and what a PAP may not. Deeper arrows are counted
(`papInject|deep|dN`), not injected; 83 % of sites are depth 1, and the clean
generalization mints `p|<global>|<supplied+i>` per arrow.

```elm
{-| SUPERSEDED SKETCH — kept to show what was corrected. The shipped version
uses `papMemberKey` + `Engine.memberIdFor` at depth 1; see the note above and
the as-built docs on `Translate.injectPapMember`.

plans/lss-injection-completeness.md §2.3: a PARTIAL application of a known
global is a PAP of that global, and LSS_013's arity bound licenses the
callee's member on the residual arrows ("a PAP of member m is m", design OQ4).
Inject into the residual spine only — `resultVarAfter` descends the consumed
arrows; depth `declared − supplied` covers every residual arrow for `g|`/`c|`;
kernels stay HEAD-ONLY (depth 1 — the `standaloneArgKernelMember` hazard:
`kernelToSig` misaligns at inner arrows). Same mint family as the bare-ref
path (`kernelAliasOf` fold), so `(::)` yields ONE identity, `k|List.cons` —
a split `g|`/`k|` identity would join to a 2-set and kill singleton consumers
(the E9.2 lesson). No-ops when lss or the flag is off, or the call is not
partial, or the residual Point is opaque (sound: uninjected = today).
-}
injectPapMember : TOpt.Global -> IO.Variable -> Int -> Step ()
injectPapMember global funcVar argCount s0 =
    let
        declared =
            LssInfer.declaredArityOf global 8 s0
    in
    if not (s0.env.lss.enabled && s0.env.lss.papMembers) || declared <= argCount then
        Ok ( (), s0 )

    else
        case resultVarAfter funcVar argCount s0 of
            Err e ->
                Err e

            Ok ( Nothing, s1 ) ->
                Ok ( (), s1 )

            Ok ( Just residualVar, s1 ) ->
                let
                    residualDepth =
                        declared - argCount
                in
                case LssInfer.kernelAliasOf global s1 of
                    Just (( _, home, name ) as k) ->
                        Engine.andThen
                            (\mid -> LssInfer.injectSpineMemberId 1 mid residualVar)
                            (Engine.kernelMemberIdFor ("k|" ++ home ++ "." ++ name) k)
                            s1

                    Nothing ->
                        Engine.andThen
                            (\mid -> LssInfer.injectSpineMemberId residualDepth mid residualVar)
                            (Engine.standaloneMemberIdFor ("g|" ++ TOpt.toComparableGlobal global) global)
                            s1
```

(Adjust the signature to take `funcVar`; `VarEnum`/`VarBox`/`VarCycle`
callees arrive here as their own `translateGlobalCall`-equivalent paths — the
ctor partial (`c|`) shares this helper with the key prefix chosen the way
`injectArgLambdaMember`'s arms do. The provisional `g|` id grounds at zonk
per LSS_019 with no extra work.)

**Expected artifact effect (flag-on): analysis change by design.** The member
reaches the demand type → spec keys split per callee identity (budget-512
backstop; the old census bounds the population). `out.mlir` moves; the
flag-off arm must be byte-identical (two-binary rail).

### §2.4 Phase 1c — inference-side twin

In `LssInfer.applyCalleeAt` (`:1640`), both branches end
`unifyCallShape funcVar args meta → Ok ( callVar, s2 )`. `callVar` is the
loaded `meta.tipe` — for a partial call, the residual type itself, already
unified with the instantiation's rest. Insert after each:

```elm
Ok ( callVar, s2 ) ->
    case injectPapMemberInfer g (List.length args) callVar s2 of
        Err e ->
            Err e

        Ok ( _, s3 ) ->
            Ok ( WpOpaque callVar, s3 )
```

`injectPapMemberInfer` is the same body as §2.3's helper with `residualVar =
callVar` (no descent needed — `meta.tipe` IS the residual) and the depth
computed the same way. This makes producer SIGNATURES that return partial
applications carry the member at the residual ordinal (the
`spineDepthForGlobal` two-sided lockstep discipline). Signature-side ids are
raw/provisional by design here — grounding and qualification happen exactly as
they do for the existing standalone channel.

**Scratch-store discipline**: both helpers only touch Points handed to them
inside the current store — nothing is retained across `withScratchStore`
(no new `ItemAux` state), so the recorded store-scoping hazards do not apply.

#### P1 MEASURED 2026-08-26 — injection is TOTAL over the form population, and analysis coverage rises +4.20 pp

Self-compile, cold, one binary, `ECO_MONO_LSS_PAP_MEMBERS` the only variable:

| | flag-off | flag-on | Δ |
|---|---:|---:|---:|
| **analysis coverage** | **23.69 %** | **27.89 %** | **+4.20 pp** |
| positions | 132,431 | 133,562 | +1,131 |
| `k1` positions | 29,097 | 32,417 | **+3,320** |
| `kN` positions | 2,277 | 4,837 | **+2,560** |
| `var` positions | 39,277 | 36,779 | **−2,498** |
| `top` positions | 61,780 | 59,529 | **−2,251** |
| ledger `k1` / `kN` | 195,109 / 3,387 | 208,579 / 5,992 | +13,470 / +2,605 |
| ledger `var` / `top` | 275,594 / 20,855 | 269,896 / 19,087 | −5,698 / −1,768 |
| wall | 6:50.90 | 7:00.82 | +2.4 % |
| `out.mlir` | 15,247,034 B | 15,305,795 B | +0.39 % |

**Injection totality: `papInject|pap = 3,604` against the form census's
`papKnown = 3,604` — EXACT, with `papInject|opaque = 0`.** Every syntactic
partial application of a known global received its member; not one residual
Point was opaque at its depth. The head-only residue is explicit and small:
`papInject|deep|d2 = 549`, `d3 = 45`, `d4 = 1`, `d5 = 5` — 600 positions
(16.6 %) have deeper residual arrows still uninjected, exactly the population
the per-arrow `p|<global>|<supplied+i>` generalization would close.

**Both uncovered buckets fall together, which is the signature of an injection
rather than a widening.** `var` −2,498 (positions that had no answer now have
one) AND `top` −2,251 (positions that had been widened are now honest sets).
A ⊤-guard repair (R2) would have moved these in OPPOSITE directions. `kN`
more than doubling is the honest-set effect: one-sided joins that used to
publish a false singleton now publish a true 2-set.

Gates: flag-off leg reproduces the pre-change flag-off leg to 4 positions in
132,431 (the identity correction is entirely inside the flag guard); ledger
`RECONCILES=yes` both arms; flag-on **lowers clean** (exit 0, 0 undefined fast
evaluators) and **the lowered binary RUNS** — 29/29 dependencies, reached
`Compiling (153)`, stopped only by the deliberate 200 s timeout (gate 5b);
**E2E `--target full` flag-off 1,691 / 1,691** (the flag-off inertness gate,
on 1,691 programs — this is what stands in for the byte-identity rail the
corpus change made unsatisfiable).

#### P2 FIRST RUN FAILED (2026-08-26) — root cause: `declaredArityGo` floors KERNEL-ALIAS globals at 1, so `(::) x` was never classified partial

The `+arrowSolverRoots +papMembers` arm still crashed identically (25/29,
`badInside`), and the artifact still carried the identity-map defect — three
`Utils_Task_Extra_apply → Task_map` instantiations with capture-less
`\a -> succeed a` wrappers. Root cause: `(::)`'s node is
`Define (TOpt.VarKernel …)` (the E9.2 kernel-alias shape), which
`declaredArityGo` had NO arm for — the wildcard floored it at 1, so
`(::) x` read declared=1 = supplied ⇒ "saturated" ⇒ `needsPapSlow` never
routed it and `injectPapMember` never fired ON THE EXACT SHAPE THAT MOTIVATED
THE PLAN. This is the SECOND missing-arm defect in the same walk
(TrackedFunction, 2026-08-23, was the first).

**And the totality census inherited the blindness**: `inj|papKnown` uses the
same `declaredArityOf`, so kernel-alias partials were excluded from BOTH the
counter and the injector — `papInject|pap == papKnown` held exactly while
both undercounted. A totality instrument that shares a classifier with the
mechanism it audits can only prove self-consistency, not totality.

Fix: `declaredArityGo` arms for `Define/TrackedDefine (VarKernel …)` returning
`canTypeArrowSpine kernelMeta.tipe` — a kernel's declared arity IS its type's
arrow spine (kernels are uncurried at their C++ ABI arity, so the spine count
is exact for them; general non-Function defs keep the sound floor, since a
returned lambda would overcount there).

#### P2 PASSES with the arity fix (2026-08-26) — the miscompile class is DEAD at its origin

With the kernel-alias arm in place: `papKnown` d1 grows 3,020 → 3,081 (the
`(::) x` class ENTERS the classification, +77 sites total) and
`papInject|pap = 3,681` matches the new population exactly. The
`+arrowSolverRoots +papMembers` arm then: **emits clean, lowers clean
(0 undefined fast evaluators), and RUNS — `Verifying dependencies (29/29)` →
`Compiling (162)`, stopped only by the deliberate 200 s timeout.** The crash
that died at 25/29 in 0.92 s across three reproductions and two binaries runs
past its crash point with roots ON. The false singleton that compiled
`Task.map f` into the identity map cannot form: the one-sided join now reads
`{g|identity, p|List.cons|1}`.

This is the exit criterion `plans/lss-solver-root-signature-identity.md` §3 P0
names — R1-as-totality delivered it, with no widening guard involved.

**Diagnostic trap (2nd occurrence of a false artifact reading):** the first
artifact query for capture-less `Task_map` wrappers reported 0/424 because the
regex demanded `num_captured` BEFORE `function` — MLIR prints attributes
alphabetically, `function` first. Never encode attribute order in an artifact
grep; match per-attribute.

**TRAP hit while running this battery, worth the line: `--target full` DELETES
`bin/eco-compiler`.** Any gate sequence that runs E2E before a census or probe
leg must rebuild in between, or those legs die with exit 127 and look like
failures of the change. (Recorded previously for the `.mlir` in
`capacity-check-hoisting`; it takes the binary too.)

### §2.5 What P1 must move (predictions, written before running)

- `inj|papKnown*` → **0** flag-on (gate).
- Analysis coverage (`coverage:` line): UP — residual arrows that read `var`
  gain members (gate 0).
- `kN` up at joins that were one-sided (`{identity}` → `{k|List.cons,
  g|identity}` at the crash shape); some `stampedStaged` decline — RECORDED,
  not gated.
- `Q-infer` stays `REPRODUCES=yes` — both helpers write through
  `unifySlotWithSetC` (via `spineGoC`), so recording is automatic.

---

## §3 Phases and batteries

**P0** census → gates: census-on/off byte-identity; table renders. One build +
two cold legs (~35 min).

**P1a** flag plumbing → gate: flag-off byte-identity trivially (dead code);
elm-tests compile.

**P1b+P1c** injection → gates, in order:
1. Two-binary flag-off byte-identity rail (env vars are not ninja inputs —
   delete `bin/eco-compiler{,.mlir}` per arm, the Run-AC trap). **AS BUILT the
   corpus moved (this plan adds compiler source), so the rail is unsatisfiable
   in its byte form — the substitutes actually run are: flag-off census
   equality against the P0 baseline (`papKnown` 3,624, `coverage:` and
   `ledger:` line-for-line), plus flag-off E2E/elm-tests at the pre-existing
   set. Recorded because the plan asked for a rail that the change itself
   invalidates.**
2. Flag-on self-compile **lowers AND the lowered binary RUNS a `make`**
   (gate 5b — born from this bug class; a clean lower proved insufficient).
3. Flag-on census; ledger `RECONCILES=yes`; `coverage:` up vs the P0 leg.

   **GATE CORRECTED during P1 (2026-08-26):** the drafted gate
   "`inj|papKnown|* = 0` flag-on" is WRONG and would never pass. The P0 census
   classifies producer positions by SYNTACTIC FORM, and a partial application
   is still a partial application after it starts injecting — the count cannot
   fall. `papKnown` was the none-population only as of P0, by the accident that
   nothing injected there yet. The correct instrument is an
   INJECTION-FIRED counter emitted from `injectPapMember` itself
   (`papInject|g` / `papInject|k` / `papInject|opaque`), and the gate is
   **`papInject|g + papInject|k ≈ papKnown`, with `papInject|opaque` the
   explicitly-reported residue** (sites whose residual Point was not an arrow
   spine at that depth — sound, uninjected, but they must be COUNTED rather
   than silently absorbed). A form census can never answer "did the write
   happen"; only the write site can.
4. `ECO_MONO_LSS_QCENSUS=1` leg: `Q-infer REPRODUCES=yes, diverge=0`.
5. elm-tests at the pre-existing 12; E2E `--target full` flag-on (touch
   `test/elm/src/*.elm` first — the harness cache is env-blind).
6. Wall/GC row per `benchmarks/lss-opt.md` (expect analysis-change corpus
   movement; attribute per the census, no cross-corpus wall claims).

**P2 — the end-to-end soundness probe (the sharpest acceptance test):**
rebuild the crash arm WITH the flag —

```bash
# Stage 5 with roots+papMembers (workload env), then lower, then RUN:
ECO_MONO_LSS_ARROW_ROOTS=1 ECO_MONO_LSS_PAP_MEMBERS=1  # + the standard leg env
# → bin/probe-out.mlir → eco-boot-native → binary → ECO_HOME-isolated `make`
```

Acceptance: the `Task_map` wrapper keeps `num_captured = 1` (check via
`/opt/llvm-mlir/bin/mlir-cat` + the extraction recipe in the solver-root
plan), and the binary completes a `make` past `Verifying dependencies` into
`Compiling (N)`. The `Tiny.elm` reproducer recipe and `ECO_HOME` isolation
are recorded in `lss-solver-root-signature-identity.md` §3 P0. This does NOT
flip `arrowSolverRoots`.

**P3 — flip decision** for `lss.papMembers` on the battery, under gate 0.

---

## §4 Unit pins (new test files, pattern: `TestLogic/Monomorphize/LssHonestSourcesPipelineTest.elm` — drive `Pipeline.runSolverMonoWithReport` with a custom `lssConfig`)

1. **`declaredArityOf` pins** (first soundness-bearing consumer of the
   TrackedFunction fix): `composeL` reads 3, `always` reads 2, a `Link`ed
   cycle member reads its group arity.
2. **The crash shape**: `step flg = if flg then (::) 7 else identity` +
   `run g = g []` — flag-on, assert the joined arrow's set is the 2-set
   (MSET/report row), NOT `{identity}`; flag-off, assert byte-identical
   behavior to today.
3. **Stamp-correct direction**: a partial app flowing to a call site with NO
   other inhabitant → singleton `{k|List.cons}` → devirt fires and the
   E2E-style probe computes the right value (guards the representative-hijack
   class both ways).
4. **Depth**: a depth-2 partial (`composeL g` — 3 declared, 1 supplied)
   carries the member on BOTH residual arrows (`injectSpineMemberId`
   depth 2); kernel-aliased callee carries it HEAD-ONLY.

---

## §5 Risks / traps (all previously recorded, collected)

- **Decoder apply-chain is positional** — append last (`Config.elm:833`'s own
  warning).
- **`report` is excluded from the config hash** ⇒ the census must never FORCE
  a signature or mint a member id (`memoizedSignatureTrivial` reads only) —
  the `censusArgs` lesson at `Translate.elm:3022-3030`.
- **Member-id allocation order is artifact-relevant** — injection must be
  flag-gated at the MINT (`injectPapMember`'s guard), not merely at
  consumption.
- **Env vars are not ninja inputs** — delete `bin/eco-compiler{,.mlir}` per
  build arm.
- **Kernels head-only** — `kernelToSig` misalignment hazard.
- **A wrong `g|`/`k|` is the representative-hijack miscompile class** — pins
  cover both stamp and decline directions (§4.2/§4.3).
- **`declaredArityOf` fuel floor** ⇒ classified saturated ⇒ no injection —
  sound (uninjected = today), but keep the fuel at 8 to match the existing
  census so the two never disagree.

## §6 Non-goals

Flipping `arrowSolverRoots` (stays with its own plan; P2 here feeds its P0
exit criteria). R2-as-semantics (the class-level guard remains a verifier-era
tripwire there; this plan is what retires it). Kernel/FFI ⊤ removal.
`callResult|trivial` repair (measured here, fixed elsewhere). Sum lowering.
Unknown-callee partial transport (census-counted; residual set = callee's
set; own plan if the number justifies it).

## §7 Relationship

`lss-solver-root-signature-identity.md` — BLOCKED on its P0; this plan is the
repair path (R1-as-totality) and P2 is the shared acceptance probe.
`lss-gap2-callarg-transport.md` — supplies ArgStash/census plumbing and the
`declaredArityOf` fix. The deleted PAP outline's sizing stands: 2,475 argument
sites, combinator head 100 % partial, 87.7 % at residual depth 1.
