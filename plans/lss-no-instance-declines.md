# `noInstance`: knowing exactly which function is called, and calling it indirectly anyway

**Status: P0 CENSUS DONE. R1 KEPT (rides `lss.stamp.flatPeel`, default-on).
R3 BUILT, MEASURED, AND REMOVED ENTIRELY 2026-09-07 — see §11, which also
corrects this plan's §1 framing.**

**The one-line summary: `g2global` — 70.6 % of the `noInstance` population — is
the SUCCESS case counted as a failure. Monomorphization already substitutes the
global into the specialized body, so those calls are ALREADY direct. R3
"converted" 10,193 of them and moved dispatch by exactly zero.**

**The census refuted this plan's own headline: G3 (the arity guard) rejects TWO
sites, not thousands, because G1/G2 reject first. The weight is in `g1absent`
(96 %), which is mostly PAP members. R3 converts 9,417 sites at flat wall.**

Successor to `plans/lss-body-mismatch-declines.md` (closed unbuilt) and
`plans/lss-instance-qualified-members.md` (LSS_038/LSS_039, shipped).
**16,224 sites — the largest remaining decline class in the compiler.**

---

## 1. What this is, from scratch

When Eco compiles a call to a function it was handed as an argument — `f x`,
where `f` is a parameter — it usually cannot know which function `f` will be at
runtime. So it emits a **generic dispatch**: follow the closure object, read the
code pointer out of it, call through that pointer. An indirect call. It is
slower than a direct one and it blocks inlining.

**Lambda-set analysis** exists to work out which function `f` actually is. When
it succeeds, the call site carries a one-element set naming exactly one
function — "the only thing that can arrive here is `increment`".

**AbiCloning** is the pass that cashes that in, rewriting the indirect call into
a direct one. To do that it needs something to point at, so it builds an index
of every closure OBJECT in the program, keyed by the identity the analysis uses.

**Here is the catch: not every function is a closure object.**

  - An anonymous lambda written inline — `\x -> x + 1` — becomes a heap closure
    object at runtime. It is in the index.
  - A **top-level named function** like `increment` is not a heap object at all.
    It is just compiled code with a symbol. Nothing allocates a closure for it
    unless some site needs to pass it around as a value.

So the analysis says "the callee is definitely `increment`", AbiCloning looks
`increment` up in its index of closure objects, and finds **nothing**. It
declines, and the counter it bumps is `declinedNoInstance`.

**We worked out the exact answer and then threw it away.**

### 1.1 The example

```elm
increment : Int -> Int
increment x =
    x + 1


applyTwice : (Int -> Int) -> Int -> Int
applyTwice f n =
    f (f n)


answer : Int
answer =
    applyTwice increment 5
```

Inside `applyTwice`, both `f (...)` calls compile to indirect dispatches. The
analysis has already proved `f` is `increment` — the annotation on `f` is a
singleton naming it. But `increment` has no closure object, the index lookup
misses, and both calls stay indirect. The generated code loads a pointer out of
a heap object to reach a function whose address was a compile-time constant.

### 1.2 There is already a pass for this, and it barely fires

`E9.5 post-settle devirt` (`lss.postSettleDevirt`, default on) exists for
exactly this case: when the named target is a plain global or constructor with
no captures, rewrite the call to a direct call on that global's compiled
specialization. It is sound for a reason worth stating — a top-level function
has **no captured variables**, so there is no capture record to get wrong, and
the representative-hijack hazard that motivates the fence elsewhere cannot arise.

**Measured on the self-compile: it converts 389 sites (`devirtPost fn=70,
ctor=319`) against 16,224 declines.**

---

## 2. Why the other 15,835 do not convert

`AbiCloning.postSettleTarget` converts only when ALL FOUR hold. Each is a
distinct sub-population:

| # | guard | rejects |
|---|---|---|
| G1 | the member's recorded ORIGIN is `OriginGlobal` or `OriginCtor` | kernels (`k|`), record accessors (`a|`), plain lambdas (`l|`) whose instance was pruned, and members with no origin recorded at all |
| G2 | the callee expression is a plain `MonoVarLocal` | a callee read out of a record field, returned from a call, or held in a data structure |
| G3 | **`arity >= 1 && arity == argCount`** | **every site whose callback takes 2+ arguments — the SAME curried-type-vs-flat-call defect LSS_039 just fixed on the sibling path** |
| G4 | a registry spec of the target matches by `eqLayout` | measured `PsNoSpec = 0`, so G4 is not rejecting anything |

### 2.1 G3 is a known, already-solved bug sitting on an unfixed copy

LSS_039 established that `Store.classifyGo` gives every arrow ONE parameter per
stage, so a callback of arity n has a callee type whose first stage is 1 while
the call applies n arguments flat. `AbiCloning.resolveRepresentative` was fixed
to peel the type to the site's own argument count.

**`postSettleTarget` has its own independent copy of that comparison
(`arity == argCount`, `AbiCloning.elm:2358`) and it was NOT fixed.** Every
noInstance site whose callback takes 2+ arguments therefore fails G3 for exactly
the reason LSS_039 documents — and `peelStages` already exists, exported, tested
by 8 unit pins.

This is the cheapest repair available in the compiler right now: reuse a tested
function at one call site.

---

## 3. Two named sub-populations, with evidence

From the `bodyMismatch` census run (`eco-bmon`, a fixed point, both flags on,
1,095,124,597 generic dispatches). Dispatch is a GENEROUS upper bound — it
counts every generic site in the host global, not only the declining ones.

**G3-blocked (callback arity 2+ — the LSS_039 defect):**

| host | sites | dispatch (UB) | % |
|---|---:|---:|---:|
| `List.foldrHelper` | 990 | 34,402,857 | 3.14 % |
| `List.foldl` | 1,119 | 5,836,726 | 0.53 % |
| `Bytes.Decode.map2` / `map3` | 1,102 | 0 | 0 % |

**G1/G2-blocked (callback arity 1 — the arity guard passes, so something else
rejects them):**

| host | sites | dispatch (UB) | % |
|---|---:|---:|---:|
| `List.any` | 96 | 19,214,302 | **1.75 %** |
| `Maybe.map` | 117 | 13,193,169 | **1.20 %** |
| `Basics.composeR` | 131 | 2,494,066 | 0.23 % |
| `Basics.composeL` | 155 | 580,947 | 0.05 % |

**Whole listed population (8,981 of 16,224 sites, top 40 hosts): 75,722,067 =
6.91 % upper bound.**

`List.any` and `Maybe.map` are the interesting rows: **96 and 117 sites carrying
1.75 % and 1.20 %** — a one-argument callback, so G3 cannot be the blocker.
Something in G1 or G2 is refusing a site where the compiler already knows the
answer. That is the highest value-per-site signal in the table and §5 must
identify which guard it is.

---

## 4. Why this plan opens with numbers

The four preceding censuses in this arc each cost a build-and-run cycle to
discover that site counts do not predict weight. This one inherits its weight
data from the `bodyMismatch` census, which measured every host. What it still
needs is the **per-guard split** — which of G1/G2/G3 rejects each site — because
that is what says whether the repair is one line (§2.1) or an analysis.

---

## 5. P0 census — the per-guard split

Add to `AbiCloningStats.instQual` a `niGuard : Dict String Int` keyed
`"<host>|<guard>"`, bumped in `postSettleTarget` at each rejection point:

  - `g1NoOrigin` — split further by what the origin IS (`kernel`, `accessor`,
    `lambda`, `absent`), since the repair differs per kind;
  - `g2Callee` — split by `calleeShape` (the helper already exists);
  - `g3Arity` — with the `<firstStage>-><argCount>` shape key, exactly as
    LSS_039's step-0 histogram did, to confirm the diagnosis and size it;
  - `g4NoSpec` — expected 0, pinned.

One build, one run, joined by host name against the dynamic profile already
collected. **Do not key on SpecId unless the binary is a verified fixed point**
(`plans/lss-body-mismatch-declines.md` §8.4).

## 6. Candidate repairs, in the order the census will probably rank them

  - **R1 — peel in `postSettleTarget`.** Replace `arity == argCount` with
    `peelStages argCount calleeType`, matching the registry spec against the
    flattened parameter list. Reuses LSS_039's tested function. If §3's G3 rows
    are the bulk, this is most of the win for a handful of lines.
  - **R2 — widen G1 to kernels and accessors.** `k|` members name a kernel
    function with a known symbol; `a|` names a record accessor. Both are
    capture-free, which is the property the soundness argument rests on.
    Requires the origin table to carry them (`lssMemberOrigins`) — check before
    promising it.
  - **R3 — widen G2 beyond `MonoVarLocal`.** A callee read from a record field
    is still capture-free if the member is a global. Riskier: the value could
    have been rebuilt; needs its own argument.

## 7. The go/no-go

Proceed if the per-guard census shows a single guard holding **> ~50 M**
dispatches, the bar the `bodyMismatch` plan was measured against and failed.
§3's upper bound of 75.7 M is above it, but upper bounds have run ~3x hot in
this arc (`foldrHelper`: 34.4 M bound, 5.3 M actual), so the honest expectation
is **20-40 M** and the decision belongs to the measurement, not to this sentence.

**R1 is worth doing on its own terms even at the low end** — it is a
known-correct fix to a known defect, reusing a tested primitive, on a path that
demonstrably has the bug.

---

## 8. P0 census, lowered to implementation

All in `compiler/src/Compiler/GlobalOpt/AbiCloning.elm` plus one report block.
Report-only: nothing consults these counters, and the stamping decisions are
byte-for-byte unchanged.

### 8.1 Make the rejection reason a return value, not a re-derivation

`postSettleTarget` (:2329) currently collapses three different rejections into
one `PsNotCandidate`. A companion "why did it fail" function would duplicate the
guard logic and drift from it, so instead carry the reason out:

```elm
type PostSettleOutcome
    = PsStamp Mono.SpecId Bool
    | PsNoSpec
    | PsNotCandidate String   -- was: PsNotCandidate
```

Three construction sites and one consumer change. The consumer becomes:

```elm
                        PsNotCandidate why ->
                            ( Mono.MonoCall region func args resultType callInfo
                            , bumpNiGuard why (bumpHost "noInstance" (bumpNoInstance ctx))
                            )
```

### 8.2 Restructure the guards so each rejects separately

Today's `case ( func, Dict.get m ctx.origins |> Maybe.andThen targetOf ) of`
tests G1 and G2 **together**, so a site failing both is indistinguishable from
one failing either. Split them, and fix the ORDER deliberately — G1, then G2,
then G3 — so that "sites that pass G1 and G2 but fail G3" is exactly the
population R1 would convert:

```elm
postSettleTarget : Int -> Mono.MonoExpr -> Int -> StampCtx -> PostSettleOutcome
postSettleTarget m func argCount ctx =
    if not ctx.postSettle then
        PsNotCandidate "off"

    else
        case Dict.get m ctx.origins of
            Nothing ->
                -- No origin recorded at all: an `l|` lambda member whose
                -- instance was pruned, or a raw signature-transported id
                -- (LSS_017 — those are never carried by an instance).
                PsNotCandidate "g1absent"

            Just origin ->
                case originTarget origin of
                    Nothing ->
                        -- A kernel or accessor member. Both name a known
                        -- symbol and both are capture-free, which is the
                        -- property E9.5's soundness argument actually rests
                        -- on — so this is R2's population, not a hard no.
                        PsNotCandidate ("g1" ++ originKindName origin)

                    Just ( target, isCtor ) ->
                        case func of
                            Mono.MonoVarLocal _ calleeType ->
                                postSettleArity target isCtor calleeType argCount ctx

                            _ ->
                                PsNotCandidate ("g2" ++ calleeShape func)
```

`originTarget` is today's inline `targetOf`; `originKindName` returns
`"kernel"` / `"accessor"`. `calleeShape` already exists (:1714) and returns
`recordAccess` / `callResult` / `global` / `closureLiteral` / … .

### 8.3 The G3 split, keyed to size R1 directly

```elm
postSettleArity : Mono.Global -> Bool -> Mono.MonoType -> Int -> StampCtx -> PostSettleOutcome
postSettleArity target isCtor calleeType argCount ctx =
    let
        firstStage =
            case calleeType of
                Mono.MFunction _ _ params _ ->
                    List.length params

                _ ->
                    0
    in
    if firstStage >= 1 && firstStage == argCount then
        matchSpec target isCtor calleeType ctx

    else if argCount > firstStage then
        -- THE LSS_039 DEFECT, ON ITS UNFIXED SECOND COPY. Key by the same
        -- shape the LSS_039 step-0 histogram used, and by whether `peelStages`
        -- would land, so this census SIZES R1 rather than merely naming it.
        PsNotCandidate
            ("g3over|"
                ++ String.fromInt firstStage
                ++ "->"
                ++ String.fromInt argCount
                ++ "|"
                ++ (case peelStages argCount calleeType of
                        Just _ ->
                            "peelable"

                        Nothing ->
                            "unpeelable"
                   )
            )

    else
        PsNotCandidate ("g3under|" ++ String.fromInt firstStage ++ "->" ++ String.fromInt argCount)
```

`matchSpec` is today's `eqLayout` registry lookup returning `PsStamp`/`PsNoSpec`,
lifted out unchanged.

**`g3over|…|peelable` IS R1's convertible set.** If it is large and hot, R1 is a
few lines; if `unpeelable` dominates, R1 is worth much less and the census has
saved a build.

### 8.4 Counter and report

`AbiCloningStats.instQual` gains `niGuard : Dict String Int`, bumped
`<hostGlobal>|<why>`; `bumpNiGuard` mirrors `bumpHost` exactly. Two report lines
in `Builder/Generate.elm`: the guard totals (`why` aggregated over hosts, ALL of
them — no `take`, the key space is small and bounded by guard kinds), and the
top 80 `<host>|<why>` pairs for the name-keyed join.

**No `take` on the guard-totals line.** The `bodyMismatch` census lost
`Dict.foldl` to a `List.take 80` ranked by site count, and that global turned
out to hold the highest weight-per-site in the table.

### 8.5 Running it

One build (`eco-ni`), one run with `ECO_MONO_LSS_REPORT=1`, joined **by global
name** against the caller-attributed dynamic profile. A per-spec join is
permitted ONLY if the binary is verified a fixed point
(`cmp` its own input against its output) — see
`plans/lss-body-mismatch-declines.md` §8.4 for why, and for the two joins that
were discarded for getting this wrong.

The `bodyMismatch` census already has the dynamic side for the same program
shape, so if `eco-ni` is built the same way (flags on, from the same source
modulo this census) the existing `bmon-bt.txt` profile can be reused for a first
read, with a fresh profile only if the numbers are close to the bar.

### 8.6 What the census must answer, in one table

| question | key | decides |
|---|---|---|
| how many sites would R1 convert, and how hot? | `g3over\|…\|peelable` | R1 |
| are kernels/accessors a real population? | `g1kernel` / `g1accessor` | R2 |
| what shapes are the non-`MonoVarLocal` callees? | `g2<shape>` | R3 |
| is `noSpec` still 0? | `g4noSpec` | pins a guard that costs nothing |
| what is `g1absent`? | `g1absent` | probably irreducible — sets the ceiling |

---

## 9. P0 census result + R3 measured (2026-09-06)

### 9.1 The guard split refutes §2.1's headline

```
g2global   11,457  (70.6%)      g1kernel     769  (4.7%)
g1absent    3,959  (24.4%)      g1accessor    37  (0.2%)
g3over          2  (0.0%)   <-- the arity guard
```

**G3 rejects TWO sites.** §2.1 claimed the unfixed `arity == argCount` copy
blocked "every noInstance site whose callback takes 2+ arguments". It does not,
because **G1 and G2 reject first** — `List.foldrHelper`'s 990 sites are 950
`g1absent` + 40 `g2global` and never reach G3.

The claim was not wrong about the DEFECT, only about its position: the guards
are a CHAIN, and each count is "rejected here first", not "would convert if
this were fixed". §6 ordered R1 first; it should have been last. **R1 is
downstream of R3, not an alternative to it — see §9.4, where it goes from 2
sites to 2,026.**

### 9.2 Weight is in `g1absent`, and it is mostly PAPs

| guard | sites | share | dispatch | share |
|---|---:|---:|---:|---:|
| **`g1absent`** | 3,302 | 31.9 % | **72,954,703** | **96.3 %** |
| `g2global` | 6,922 | 67.0 % | 2,767,363 | 3.7 % |
| `g1kernel` | 113 | 1.1 % | 0 | 0 % |

**Site-count trap, fifth confirmation**: `g2global` is 67 % of sites and 3.7 %
of weight (cold `Bytes.Decode` / `Combine` parser combinators).

Prefix split of `g1absent` (via the new report-gated `MonoGraph.lssMemberKinds`,
member id → interned-key prefix):

```
g1absentp = 2,418  (61%)   p| — PARTIAL-APPLICATION members
g1absentl = 1,436  (36%)   l| — lambda members with no instance
g1absent? =   108  ( 3%)   absent from the key table entirely
```

A `p|` member (minted in `LssInfer` per `(global, argCount)`) names a partially
applied function. There is **no `MonoClosure` for a PAP and no `OriginPap`
variant**, so it can never resolve today by construction. That is the
96 %-of-weight population and it needs a mechanism neither R1 nor R3 provides.

**A hypothesis was tested and REFUTED on the way**: LSS_017/LSS_020 suggest
signature-transported raw ids are the source. Running `sigFlow=0` makes
`g1absent` **TEN TIMES WORSE** (3,959 → 40,849; `noInstance` 16,224 → 53,089).
Signature flow is a large MITIGATION of this population, not its cause.

### 9.3 R3 measured — converts 9,417 sites at flat wall

`lss.stamp.globalCallee` (env `ECO_MONO_LSS_GLOBAL_CALLEE`, token `lssGC=`),
default OFF.

| | off | on |
|---|---:|---:|
| `declinedNoInstance` | 16,228 | **6,811 (−58 %)** |
| `devirtPost` fn / ctor / noSpec | 70 / 319 / 0 | 439 / **9,367** / **7** |
| `.mlir` | 15,488,446 | 15,488,423 (−23 B) |
| wall | 7:56.39 | 7:56.03 |

Conversions are overwhelmingly **constructors**. Wall is FLAT, which is the
honest outcome and was predicted: `g2global` is 3.7 % of the weight. **This is a
site-count win, not a performance win.**

**THE FENCE FIRED: `noSpec` 0 → 7.** Those are global callees whose type matched
no spec layout — the partially-applied-CAF class the R3 comment nominates as
the hazard, correctly DECLINED by the `eqLayout` guard rather than rewritten.
Not unsoundness; but it proves the hazard is real and non-empty, so **the G4
fence is load-bearing for R3 and must never be relaxed**. Investigate what
those 7 are before any default flip.

### 9.4 R3 unmasks R1 — 2 sites become 2,026

With R3 on, sites flow past G2 and reach G3 for the first time:

```
g3over|1->2|peelable = 1,054     g3over|1->3|peelable = 546
g3over|1->4|peelable =   322     g3over|1->5|peelable =  87
g3over|1->7 = 9 · 1->10 = 7 · 1->9 = 7 · 1->6 = 4
TOTAL 2,026 — every one PEELABLE, zero unpeelable
```

R1 is the one-line reuse of `peelStages` in `postSettleArity`. It was worth 2
sites before R3 and is worth **2,026** after — the masking effect §9.1 predicts,
measured.

### 9.5 Where the remaining work is

  - **R1** — trivial, 2,026 sites, same file. Do it with R3.
  - **`g1absent` / `p|` members — 2,418 sites, the bulk of 96 % of the weight.**
    Needs an origin for partial applications: a member that names
    `(global, appliedCount)` could resolve to the global's spec plus a
    PAP-suffix stamp, which `resolvePapSuffix` already models on the instance
    path. This is the real successor.
  - `g1absentl` (1,436) — lambda members with no instance; overlaps LSS_017's
    parked enqueue-time qualification.
  - `g1kernel` (769) / `g1accessor` (37) — R2, measured at **zero** dispatch.

---

## 10. R1 measured, and the assumption it rested on (2026-09-06)

R1: peel the curried callee type in `postSettleArity`, gated on
`lss.stamp.flatPeel` — it IS that mechanism applied to this path's independent
copy of the comparison, not a second flag for the same idea.

### 10.1 Results

All arms at `flatPeel=1` except `base`, which has it off and therefore measures
LSS_039 rather than R1.

| arm | `noInstance` | `devirtPost` fn / ctor / noSpec |
|---|---:|---|
| R3 off, R1 off | 16,228 | 70 / 319 / 0 |
| R1 only | 16,226 | 70 / 321 / 0 |
| R3 only | 6,811 | 439 / 9,367 / 7 |
| **R1 + R3** | **4,776** | **1,327 / 10,514 / 8** |

  - **R1 alone converts 2 sites** — precisely what §9.1 predicted, because G1
    and G2 reject first.
  - **R1 behind R3 converts 2,035** (6,811 -> 4,776) against a predicted 2,026.
    The masking effect, quantified.
  - **Combined: −11,452 sites, −70.6 %.**
  - Cost: `.mlir` −95 bytes, compile wall +0.08 s. Nothing.

### 10.2 The flagged assumption resolved

§10's code comment recorded an assumption that could not be settled by reading:
`matchSpec` compares the spec's type against the UNPEELED callee type, so R1
converts only if the registry stores globals CURRIED (as `classifyGo` builds
them). If it stored them flattened, `eqLayout` would fail and the sites would
land on `PsNoSpec` — converted into relabelled, with no gain.

**`noSpec` went 7 -> 8, not 7 -> ~2,000. The registry stores them curried; R1
genuinely converts.** Recorded because the same question will arise for any
future repair that compares a peeled site against a stored spec type.

### 10.3 Both target populations are now empty

Guard totals in the R1+R3 arm:

```
g1absentp=2418  g1absentl=1436  g1kernel=769  g1absent?=108  g1accessor=37
```

`g2global` and `g3over` are **gone entirely**. Every surviving `noInstance` site
is a member with no recorded origin, or a kernel/accessor.

### 10.4 What this is and is not

**It is not a performance win, and the census said so in advance.** `g2global`
was 3.7 % of the weight and `g3over` sat inside it. What it buys is a 70.6 %
reduction in the largest decline class, at no measurable cost, and a census
whose remaining rows all name one thing: **members with no origin**.

**The 96 %-of-weight population is untouched**: `g1absentp`, 2,418 `p|` PAP
members, now the largest single row. §9.5's successor stands.

### 10.5 Gates so far, and what is still owed

| gate | state |
|---|---|
| `elm-tests` | **13,446 pass / 12 fail = exact pre-existing baseline** |
| unit pins (`AbiCloningFlatPeelTest` + `PassTest`) | 12/12 |
| all three arms compile | rc=0 |
| **E2E `--target full`, globalCallee DEFAULT-ON** | **1719 / 1719 PASSED** (2026-09-07) |
| **fixed point on a `globalCallee=1` build** | NOT RUN |
| **the 8 `noSpec` sites** | NOT INVESTIGATED — this is R3's ONLY safety signal and it is non-zero |

**`lss.stamp.globalCallee` FLIPPED DEFAULT-ON 2026-09-07** after E2E passed
1719/1719. Its hash token `lssGC=` now rides the OFF arm, so the default cache
key changed once.

**STILL OWED, and the flip did not discharge them:** `noSpec` firing
means the `eqLayout` fence rejected a global callee whose type matched no spec
— the partially-applied-CAF class R3's comment nominates as its hazard. Eight
is a small number and the fence caught them, but "the guard worked" is a
different claim from "we know what they were".

---

## 11. R3 REMOVED, and §1's framing corrected (2026-09-07)

### 11.1 What the probe showed

A deliberately inline-proof shape: a RECURSIVE higher-order function called at
two sites with two RECURSIVE (hence non-inlinable) top-level functions.

```elm
slowInc x = if x < 0 then slowInc (x + 1) else x + 1
slowDbl x = if x < 0 then slowDbl (x + 1) else x * 2
applyN f n acc = if n <= 0 then acc else applyN f (n - 1) (f acc)
main = ... applyN slowInc 10 0 + applyN slowDbl 10 1
```

Emitted:

```mlir
@Main_applyN_$_4:  %4 = "eco.call"(%arg5) <{callee = @Main_slowInc_$_3}>
@Main_applyN_$_6:  %4 = "eco.call"(%arg5) <{callee = @Main_slowDbl_$_5}>
```

**Two specs, two DIRECT calls, no dispatch** — and the census for that compile
reads `declinedNoInstance=2`, both `g2global`.

Keying splits the HOF per lambda set, and **monomorphization then substitutes
the global straight into the specialized body**. The callee stops being the
parameter and becomes a `MonoVarGlobal`, which already lowers to `eco.call`.
AbiCloning is never needed. (In the easiest case it does better still: a
single-site version compiled `f acc` to `eco.int.add %arg5, 1` — the callback
inlined away entirely.)

### 11.2 §1's framing was wrong for the majority of the population

§1 said: *"we worked out the exact answer and then threw it away."* For `g|`
members reached through a parameter that is FALSE — mono consumes the answer
upstream. `g2global` is **11,457 sites, 70.6 % of `noInstance`**, and every one
of them is a call that needs no stamping.

`declinedNoInstance` therefore does NOT count indirect dispatches. It counts
sites AbiCloning could not stamp, and `stampCall` consults every call including
ones that are already direct.

### 11.3 R3's measured payoff was exactly zero

| | off | on |
|---|---:|---:|
| wall | 7:12.10 | 7:11.85 |
| `sat` | 1,081,309,623 | **1,081,309,623** |
| `gen` | 1,040,832,713 | **1,040,832,713** |
| call-kind histogram | identical | identical |

Dispatch identical **to the digit**. The `.mlir` diff across 10,193 rewrites is
**86 lines / 43 call sites**, every one of the form

```
- callee = @Compiler_AST_Source_typeEncoder_$_11610
+ callee = @Compiler_AST_Source_typeEncoder_$_11607
```

— an already-direct call retargeted at an equivalent lower-numbered spec,
because `matchSpec` takes `List.minimum`. 10,150 rewrites changed nothing.

**REMOVED**: the config field, env override, hash token, the `MonoVarGlobal`
arm, and the pass parameter. `abiCloningPass` is back to three arguments. A
comment at the former site records why, so it is not re-attempted.

### 11.4 A diagnosis I got wrong twice on the way

First I said `PsStamp` leaves `callInfo` untouched so the rewrite never reaches
codegen. Wrong: `annotateCallStaging` runs at **Phase 5, AFTER** AbiCloning and
re-derives `CallInfo` from the rewritten callee. Then I proposed setting
`callKind` to force a direct call. Also wrong, and for a better reason: **there
was no dispatch to remove.** The tell was there twice before the probe — 95
bytes of `.mlir` change across 9,417 rewrites — and I quoted that number without
following it.

### 11.5 What survives

  - **R1 KEPT** — the arity peel in `postSettleArity`, riding
    `lss.stamp.flatPeel`. A genuine defect fix (LSS_039's comparison on this
    path's independent copy). Its 2,035 sites should NOT be described as
    conversions until someone shows they were dispatches.
  - **The per-guard census KEPT** — `niGuard`, `lssMemberKinds`, `bmSites`. It
    is what exposed all of the above.
  - **The real target is unchanged and untouched**: `g1absent`, 3,959 sites —
    **2,418 `p|` PAP members** and 1,436 `l|` lambda members — carrying 96 % of
    the class's dispatch weight. Those are genuinely unresolved: there is no
    `MonoClosure` for a PAP and no `OriginPap` variant.
