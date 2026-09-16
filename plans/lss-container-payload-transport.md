# LSS — container-payload identity across item boundaries

**Status (2026-09-16, latest): §12.10.3 — the F3-b + F4 series is BUILT, MEASURED (five cumulative arms) and SHIPPED DEFAULT-ON: F2.c `stamp.useInjectPap` (46 PAP-RHS uses named), E15 `flow.accessFlow` (5,785 access joins), F4-sig `flow.litFacts` (13,443 literal points; +133 k1 / +87 kN — the payer), F3-b `flow.letOverlay` (⊤ −30, var +30). Series: `var` 893 → 851, ⊤ 700 → 668, coverage 98.92 → 98.97 %, wall flat. Unit 13,568 / standing 12. The record-field book barely moved (270 → 258): a fourth root (Borrow/LssFacts context records through `Maybe`/`Dict` payloads, fold accumulators) is unnamed. Before that: F2 SHIPPED DEFAULT-ON (var 1,380 → 873, coverage 98.44 → 98.94 %); F3-a COMPLETE, default-off, inert until the flex-parameter chain is repaired. §12.6: the `papSuccWrite` fix MEASURED: `var` 12,958 → 1,380 (−89 %), coverage 90.62 % → 98.43 % (+7.81 pp), wall flat; F1 reverted (null, §11). Gates owed on the fix: bootstrap 8c, call-stats Runs 23/24 (elm-tests and E2E PASS). Earlier: §11 — F1 BUILT,
BENCHMARKED, NULL: 30,077 write-backs,
byte-identical emission, coverage identical to the digit. Root cause verified in code: edge E4
has been connected by `arrowIdentity` since 2026-08-25, and the v1/v2 instrument read the slot
BEFORE the inner call was translated. §10.3's E4/E5 rows are corrected; §10.4's prediction is
falsified; F2/F3 need a v3 (post-translation) read before sizing. Flag kept default-off as the
measured null. Earlier:** §10 edge map + fixes; OUTLINE + P0 (2026-09-15). §8 has the results. Headline:
75.4 % of var roots sit at a cell some sibling specialization knows — **and that fact turns out
to be worthless**, because the siblings disagree (1.7 % unanimous), which re-derives `varfix3`'s
`would = 7` from first principles. The real finding is a per-cell success rate that splits the
residue into two populations, one of which is a **small, sharp, tractable** class the shipped
machinery already handles 87-98 % of the time. §3's directions are re-read in §8.6. §1-§2 stand;
§4 steps 2 and 4 are still unrun.

**Read §9.0 first — a SCOPE CORRECTION.** §9's instrument measures FUNCTION-TYPED arguments
only; it is blind to container-typed arguments carrying functions inside, which is this plan's
actual subject. Its finding (`call`-result arguments deliver a member 2 times in 3,655, refuting
`lss-var-chain-roots.md` §9.5's delivery matrix) is real and answers §8.7's Population-A
question, but it does NOT answer the container-payload question. Then §8 — whose §8.1 also
invalidates every per-global `var` ranking this arc has published.

**Origin:** the `var` census of 2026-09-15 (this session). Raw artefacts, kept next to the other
run outputs:

  - `build/compiler/build-kernel/bin/varcensus-2026-09-15-summary.txt` — every census line
  - `build/compiler/build-kernel/bin/varcensus-2026-09-15-pos.log.gz` — 149,482 `pos|` rows
  - `build/compiler/build-kernel/bin/varcensus-2026-09-15.time`

Reproduce with: shipping defaults, native `bin/pmo-bench-off-census`, workload
`compiler/src/Terminal/Main.elm`, `ECO_MONO_LSS_REPORT=1 ECO_MONO_LSS_ARROW_CENSUS=1`;
8:38.6 wall / 14.57 GB peak; `rm -rf eco-stuff` first. NOTE the source drifted +5.6 KB of
artefact versus call-stats Run 20 (`Config.elm` / `InlineSimplify.elm` touched 10:56 the same
day) — these figures stand on their own and were NOT added to `benchmarks/call-stats.tsv`
(that needs the two-compiler protocol; this was a single-compiler census).

**Relationship to other plans.** Successor in spirit to `plans/lss-var-chain-roots.md` (which
closed its last row-aggregation mechanism) and `plans/lss-gap2-callarg-transport.md`. Adjacent:
`plans/lss-set-variable.md` (the paper's `ᾱ`), `plans/lss-sum-lowering.md` (GAP-6, which gates
whether any of this is worth dispatch). Does NOT overlap
`plans/saturating-pap-chain-fusion.md` — that one deletes a population, this one names one.

---

## 1. The measurement that motivates this

### 1.1 `var` is now the entire uncovered book

```
coverage: positions=149482 k1=100726 kN=34675 var=12956 top=1094 part=31 coveredBp=9058
```

Analysis coverage 90.58 %. `var` is 8.67 % of positions but **92.0 % of the 14,081 uncovered
positions**; ⊤ is down to 1,094 (0.73 %). The Aug-26 "⊤ dominates at positions" inversion is
dead — there is nothing else left to attack.

### 1.2 The split is writer-side, not representation-side

Every `Can.TLambda` gets a set slot from `Store.loadTypeC` wherever it sits, `MonoType` carries
the annotation on nested `MFunction` under `MList`/`MCustom`/`MRecord`/`MTuple`, and both
`Mono.annoCoverage` and the `pos|` walker recurse into all of them. So the slot on the arrow
inside `List (a -> b)` or `Result x (a -> b)` **already exists and is already measured**. The
question was never whether it can hold a set; it is who writes it:

| position kind | count | k1 | kN | **var** | ⊤ |
|---|---:|---:|---:|---:|---:|
| pure arrow spine (head / args / results) | 133,695 | 71.66 % | 24.92 % | **2.89 %** | 0.52 % |
| **inside a container** (list elem, ctor arg, record field, tuple slot) | 15,787 | 31.15 % | 8.58 % | **57.57 %** | 2.57 % |

Container-nested arrows are covered 39.7 % of the time — so the mechanism works — but `var` is
**20× more likely** there. Covered container positions by their last data step: `…/cN/…` 5,826,
`…/tN/…` 274, `…/l/…` 90, `…/f:*/…` 83.

### 1.3 What a WORKING container write looks like

`Terminal.Terminal.Chomp.chompArgs` takes a literal `List` of functions:

```elm
chompArgs : Suggest -> List Chunk
          -> List (Suggest -> List Chunk -> ( Suggest, Result ArgError a ))
          -> ( Task Never (List String), Result Error a )
```

and the census names its element arrow and the element's own result arrow:

```
pos|chompArgs|/r/r/a0/l  |k1:p;eco/compiler:Terminal.Terminal.Chomp.chompExactly;1
pos|chompArgs|/r/r/a0/l/r|k1:p;eco/compiler:Terminal.Terminal.Chomp.chompExactly;2
```

"Every element of that list is `chompExactly` applied to 1 argument", and LSS_013 spine
injection then continued THROUGH the list element into the element's own result (`;2`).
Same shape at ctor payloads (`pos|reverse|/a0/l/c1|kN`) and at record fields
(`pos|rebuild|/r/r/a0/f:ctorShapes|k1:l;8175`).

**Why it works there:** the list literal is built in the same item from a `VarGlobal`
reference, so `injectArgLambdaMemberGo`'s `VarGlobal` arm fires `standaloneArgMember` +
`LssInfer.injectPapSuccessors`, and ordinary unification carries the result.

### 1.4 What a FAILING container write looks like

`List.foldl` over the GLSL parser's operator table (spec 8467) — a record of lists of
constructor values whose payloads are functions:

```
pos|foldl||k1:g;elm/core:List.foldl…        head: known
pos|foldl|/r|k1:p;elm/core:List.foldl;1     PAP stage 1: known
pos|foldl|/r/r|k1:p;elm/core:List.foldl;2   PAP stage 2: known
pos|foldl|/a0|var                            the callback: unknown
pos|foldl|/a0/r/r/f:lassoc/l/c1|var          the fn inside each Operator
pos|foldl|/r/a0/f:rassoc/l/c1/r|var          …in each list, in each field
```

`foldl`'s own spine is perfect. What is `var` is the caller-supplied callback and every
function sitting at `record → list → constructor payload`. Those values were built in another
item; nothing in this item names them, and LSS_006 guarantees a fresh `loadType` shares
nothing with the construction site.

### 1.5 Shape of the residue, and what it is NOT

`var` is **not 12,956 problems — it is ~2,087**. Chain-root analysis over the `pos|` rows (a
`var` position whose nearest enclosing position is not `var`):

| | |
|---|---:|
| var positions | 12,956 |
| distinct `var@` slot ids | 6,564 |
| **chain roots** | **2,087** |
| propagated links (inherited down a result spine) | 10,869 (83.9 %) |
| ids occupying both an arg-side and a result-side path of one spec | 4,492 of 6,564 |

Roots by the last step of their path: **function-in-a-data-payload 929 (44.5 %)** (ctor arg 675,
record field 134, tuple 92, list elem 28) / callback ARGUMENT arrow 598 (28.7 %) / RESULT arrow
558 (26.7 %). 1,419 of 2,087 (68 %) reach through an `/aN`. (The per-global names in this
section are NAME-AGGREGATED across modules — see §8.1, which de-aliases them.)

Three facts bound any repair, all measured this run:

1. **Not dead code.** `liveness: varArrows=30378 varApplied=20645 liveBp=6796` — ≥ 68 % of
   `var` arrows are applied somewhere, on a positive control that loses nothing
   (`attempts=502704 hit=502704 hitBp=10000`). Supersedes the old 39.62 % lower bound. The
   COMPLEMENT is still not warranted (7,604→8,747 applied arrows in neither set, unexplained
   since `plans/lss-provenance-ratio-census.md` §7.6).
2. **The signature channel is correctly empty, not broken.** `sigfact` puts 12,874 of 12,956
   (99.4 %) at globals whose `LssSignature` is TRIVIAL: `map=3819(triv:3a/0q)`,
   `andThen=2137(triv:3a/0q)`, `apply=1977`, `Ok=1950(triv:1a/0q)`, `Decoder=1146`,
   `Err=724`, `foldl=350`. A trivial signature at `map : (a -> b) -> …` is the CORRECT
   signature for a polymorphic HOF — its sets are caller-supplied, the paper's `α` with `Q`
   empty. The loss is on the application side.
3. **Row aggregation is exhausted.** `varfix3` is exhaustive (sums to 12,956 exactly) and
   reports `would = 7` (pwould 5 + mixwould 2). Nothing is left for a
   varSucc/varCtorRows/varRowEnrich-style mechanism. Classes:
   `noHead=4846`, `contamVarShared` (all tags) `=4918`, `lshapeMiss=1704`,
   `contamVarIso` (all tags) `=1076`, `contamTop` (all tags) `=405`.

---

## 2. Levers already measured DEAD — do not re-propose

| lever | evidence | where |
|---|---|---|
| repair the destructuring ⊤ (`top@clsDestr` at the payload head) | `destranno\|top\|top = 14,232` vs `destranno\|top\|k1 = 133`; `destrBend: k1=0 kN=0 no=0` | this run. The projected root-local type is ⊤ too — per `destrAnnoCensus`'s own decision rule the destructor is innocent and the loss is upstream |
| cross-spec row aggregation (g\|/c\| row enrichment) | `would = 7` of 12,956 | this run; `lss-var-chain-roots.md` §4.5 measured `would = 0`; **§8.3 now explains WHY: only 1.7 % of knownElsewhere cells have siblings unanimous on one member, 68.7 % have 9+** |
| raw store-level flow repair (`flowConnect`) | coverage EXACTLY flat; ⊤ +703, k1 −672 | `lss-var-chain-roots.md` §9.11 — closed refuted-as-net-win |
| M2 lambda stage identities | `m2stage: stageVar=168 bodyVar=221` — the class is tiny | this run; `lss-var-chain-roots.md` §9.14 |
| `mA` successor writes | `varfix: mA\|would1=0 mA\|wouldN=0` | this run — the shipped `varSucc` has consumed its own population |

---

## 3. The question this plan exists to answer — NOT YET INVESTIGATED

**How does the identity of a function value stored inside a data structure survive the item
boundary?** Today it does not: the writers are all construction-site writers inside one item,
and the only cross-item channel is `LssSignature`, which is trivial at 99.4 % of the residue.

Candidate directions, listed so the investigation has a starting shape. **None is chosen, none
is costed, and the ordering below is alphabetical-by-accident, not a ranking.**

  - **(A) Payload facts on the signature.** Extend `LssSignature` beyond arrow ordinals on the
    def's own spine to arrows reached through container steps of the signature type. Open:
    does `Store.loadTypeC`'s ordinal numbering (LSS_006) already visit them — i.e. is this a
    numbering question or a new side table? `sigArrowCountOf` / `sigVarCountOf` in
    `Monomorphize.elm` already walk containers for the census, which suggests the walk exists.
  - **(B) Deep instantiation connection.** `lss-var-chain-roots.md` §9.4's named repair 1: when
    demand instantiation binds a type variable to an arrow-bearing type, unify the
    instantiation's fresh arrows with the arrows the CALLER holds. Note §9.11 measured the
    within-item store version flat — the open question is whether the CROSS-ITEM version
    behaves differently, and that has never been built or measured.
  - **(C) λ-set polymorphism (the paper's `ᾱ`).** Export the unknown UP as a ∀-parameter rather
    than committing to `var` at the definition, which is exactly what turns
    `map=3819(triv:3a/0q)` from "correctly empty" into a carrier. `plans/lss-set-variable.md`.
    Standing blocker: GAP-6 / `plans/lss-sum-lowering.md` — a multi-member set at a
    singleton-only consumer still lowers to a generic dispatch.
  - **(D) Accept the pass-through class as correct and re-baseline.** 4,492 of 6,564 `var` ids
    occupy both an argument-side and a result-side path of the same spec — one slot, shared by
    unification, i.e. a polymorphic function threading a function through unchanged. For those
    `var` is the RIGHT answer inside that specialization and the identity genuinely lives at
    the caller. Open: how many of the 2,087 roots are in this class, and should the coverage
    denominator exclude them? (Changing a gate's denominator is a user decision, not a
    mechanism.)

---

## 4. P0 — what to measure BEFORE any mechanism

The arc's standing rule: a census must not share a classifier with its mechanism, and
one-module fixtures cannot manufacture these classes (`lss-var-chain-roots.md` §5.1) — corpus
counters are the differentials.

Questions the existing instruments do NOT answer, in the order they gate the directions above:

  1. **Where is each root's producer?** For each of the 2,087 roots, is the inhabiting value
     constructed (a) in the same item — then it is a within-item transport bug; (b) in another
     item reachable through a signature — then (A)/(B) are live; (c) nowhere nameable (a
     genuine caller-supplied polymorphic parameter) — then only (C)/(D) apply. Nothing today
     distinguishes these; this is the single most valuable number in the plan.
     → **RUN 2026-09-15 as far as it goes offline, see §8.** The three-way split still needs an
     in-compiler instrument, but §8 narrows its target from 2,087 roots to ~270 at six named
     cells, and answers the question the split was FOR.
  2. **Does the signature walk already visit container payload arrows?** Read out of
     `Store.loadTypeC` / `LssSignature.arrows` directly, not inferred. Decides whether (A) is
     a numbering change or a format change (and therefore whether it costs an artefact rebuild,
     the 2b hazard from `lss-unknown-elimination.md`).
  3. **Pass-through share of the roots.** The `contamVarShared` split is position-weighted;
     re-run it root-weighted to size (D) honestly. → **RUN, see §8.5: 1,040 of 2,087 (49.8 %)
     root-weighted, against 68 % position-weighted.**
  4. **Dispatch weight of the roots.** Site counts have mispredicted weight repeatedly in this
     arc (`arityover-dynamic-weight-census`, the `p|` take-400 defect). Any GO must be priced
     in dispatches, not positions — and see §6.

---

## 5. Gates — pre-registered, sizes TBD after §4

Per `lss-var-chain-roots.md` §5.2 the GO bar is "any small improvement" (≥ 50-80 writes), not a
large floor. The gate that binds is SOUNDNESS, not size: no mechanism ships without its
completeness rule, its guards, and the accounting identity (**writes == var delta**, to the
digit). Plus the standing rail: E2E both arms, elm-tests, `ECO_MONO_VALIDATE`, and a verified
fixed point on any per-spec join.

---

## 6. The honest ceiling, stated up front

**A coverage win here is not automatically a dispatch win.** `var` positions lower to generic
dispatch exactly as ⊤ does, and while GAP-6 binds, an honest multi-member set buys nothing at a
singleton-only consumer. `lss-var-chain-roots.md` §8.6 already flagged this and
`lss-root-cause-arrows-have-no-identity` records three mechanisms (sigFlow, LSS_023,
callArgFlow) that regressed by adding true set information to a width-1 consumer. Before
building anything in §3, decide explicitly whether the target is the coverage gate or dispatch;
if it is dispatch, `plans/lss-sum-lowering.md` is upstream of all of it.

---

## 7. What not to do

  - Do not "put a lambda set on the arrow inside `List (a -> b)`" — it is already there
    (§1.2/§1.3). Any work item phrased that way is mis-scoped.
  - Do not re-run the destructure repair, row aggregation, or within-item flow repair (§2).
  - Do not size anything from site counts alone (§4.4).
  - Do not measure on the JS build, and do not compare against call-stats Run 20 without
    re-emitting on one source (§Origin).
  - Do not treat the `Eco.Config` decoder population as part of this item — it is 79.5 % of the
    var book, it is cold, and it belongs to `plans/saturating-pap-chain-fusion.md`. Any census
    in §4 must report with and without it or it will be swamped.

---

## 8. P0 STEPS 1 AND 3 — RUN 2026-09-15

Offline, from `varcensus-2026-09-15-pos.log.gz` alone — no compiler change, no recompile.

### 8.1 First, a correction that invalidates prior rankings

`pos|` rows carry the global's **NAME ONLY** (`Monomorphize.elm` takes `Mono.Global _ n` and
drops the home), so every per-global `var` ranking in this arc — §1.5's included, and
`sigfactg`'s — silently aggregates unrelated functions. `map` alone is:

```
List.map 906   Task.map 457   Bytes.Decode.map 425   Combine.map 221   Result.map 199
Maybe.map 187  System.TypeCheck.IO.map 127   Dict.map 101   Reporting.Result.map 100  …
```

**The qualified global IS recoverable offline**: 39,923 of 40,453 specs (98.7 %) carry a
root-path row whose member key is `k1:g;<comparableGlobal>;<layout>` (or `c;`/`k;`/`p;`).
Everything below de-aliases through that. Quote qualified globals from here on; a bare `map=3819`
row is a sum over nine unrelated combinators.

### 8.2 Root classification — the headline, which does not survive §8.3

For each of the 2,087 chain roots, does **any other specialization of the same qualified global**
cover the same path?

| class | roots | share |
|---|---:|---:|
| **`knownElsewhere`** — ≥1 sibling spec has k1/kN at that exact cell | **1,573** | **75.4 %** |
| `varEverywhere` — every sibling with that path is var too | 279 | 13.4 % |
| `onlySpec` — the global has exactly one spec, so "elsewhere" is vacuous | 107 | 5.1 % |
| `pathUniqueToThisSpec` — siblings exist but none has that path | 72 | 3.4 % |
| `topElsewhere` — no cover anywhere, some sibling has ⊤ | 56 | 2.7 % |

Read naively that says three quarters of the residue is a transport gap. It is not.

### 8.3 The agreement test kills the aggregation reading — and explains `would = 7`

Of the 1,573 `knownElsewhere` roots, what do the knowing siblings actually say?

| what the knowing siblings say | roots | share |
|---|---:|---:|
| **9+ distinct `k1` members across siblings** | **1,080** | **68.7 %** |
| mixed `k1` + `kN` | 349 | 22.2 % |
| 2-8 distinct `k1` members | 107 | 6.8 % |
| **ONE `k1` member, unanimous** | **26** | **1.7 %** |
| `kN` only (honestly multi-member) | 11 | 0.7 % |

And **no cell has 100 % of its siblings knowing it** — the best bucket is ≥75 % (547 roots).

This is not a defect, it is the definition of the position: `List.foldl`'s `/a0` is a *different
callback* in every specialization, so "spec A knows it" carries no information about spec B.
**Aggregating over a global's rows is asking the wrong question**, which is precisely
`lss-var-chain-roots.md` §8.6's "AUTHORITY BEATS AGGREGATION", and it re-derives `varfix3`'s
`would = 7` from the data instead of merely observing it. Directions **(A) and (B) in their
aggregation form are dead for the third time in this arc. Do not propose them a fourth.**

### 8.4 The cut that IS informative: per-cell success rate

Turn it round — at each cell, how often does the shipped machinery succeed? Using a
decoder-chain marker of "spec has ≥20 var positions" (237 specs, 9,633 positions = 74.4 %,
614 roots; remainder 1,044 specs, 3,323 positions, 1,473 roots), the residue splits into two
populations that want completely different answers:

**Population A — HOF callback cells. The machinery already works 87-98 % of the time.**

| cell | k1 | kN | var | ⊤ | success | roots |
|---|---:|---:|---:|---:|---:|---:|
| `elm/core:List.foldl` `/a0` | 2,583 | 0 | 64 | 3 | **97.5 %** | 63 |
| `elm/core:List.foldr` `/a0` | 900 | 0 | 30 | 0 | **96.8 %** | 29 |
| `elm/core:List.foldrHelper` `/a0` | 900 | 0 | 30 | 0 | **96.8 %** | 29 |
| `elm/core:List.map` `/a0` | 857 | 0 | 49 | 0 | **94.6 %** | 49 |
| `elm/core:Dict.foldl` `/a0` | 348 | 0 | 40 | 0 | **89.7 %** | 40 |
| `eco/compiler:Compiler.MonoSolver.Engine.andThen` `/a0/r` | 143 | 0 | 22 | 0 | **86.7 %** | 22 |
| `eco/compiler:System.TypeCheck.IO.andThen` `/a0/r` | 237 | 1 | 66 | 11 | **75.6 %** | 66 |

**Population B — the decoder chain, where var is the norm or the only answer.**

| cell | k1 | kN | var | success | roots |
|---|---:|---:|---:|---:|---:|
| `Compiler.Json.Decode.apply` `/r/r/c1` | 37 | 0 | 82 | 31.1 % | 37 |
| `elm/core:Result.andThen` `/a0/r/c1`, `/r/r/c1` | 37 | 0 | 82 | 31.1 % | 36 each |
| `elm/core:Result.map` `/a0/r` | 46 | 0 | 82 | 35.9 % | 21 |
| `Compiler.Json.Decode.apply` `/r/a0/c1` | 63 | 0 | 82 | 43.4 % | 39 |
| `elm/core:Result.Ok` `/a0`, `/r/c1` | 148 | 7 | 82 | 65.4 % | 36 each |
| `elm/core:Result.Err` `/r/c1` | 131 | 8 | 82 | 62.9 % | 75 |
| `Result.Err` `/r/c1/r×7`, `Decoder` `/r/c1/r×8` | 0 | 0 | 55 | **0.0 %** | 47, 27 |

The recurring **82** is one population of 82 specializations (registry indices 27,844-30,445,
5 gaps > 50) seen at different paths — the `Eco.Config` staircase. The ≥20-var marker catches
only 49 of those 82, so **the A/B boundary in these tables is approximate and Population B is
under-counted**; Population A's cells are unambiguous and are what matters.

### 8.5 P0 step 3 — pass-through, root-weighted

1,040 of 2,087 roots (49.8 %) have a `var` id that also occupies the other side (argument vs
result) of the same specialization — one slot, shared by unification, the identity genuinely
living at the caller. Position-weighted the same test gave 68 %, so **the position-weighted
figure overstates direction (D) by ~18 points**; quote the root-weighted one.

### 8.6 What this does to §3

  - **(A) payload facts on the signature / (B) deep instantiation connection — in their
    AGGREGATION form: DEAD** (§8.3). Nothing about a global's other rows can license a write
    into this spec.
  - **(B) in its PER-SPEC form: LIVE, and now sharply scoped.** Population A is ~270 roots
    across seven named cells where the machinery succeeds 87-98 % of the time. The question is
    no longer "can this class be transported" but **"what distinguishes the 64 failing
    `List.foldl` specs from the 2,583 that succeed at the same position?"** That is a
    differential on a small named set, not a survey — and it is the cheapest remaining lever
    in the whole arc.
  - **(C) λ-set polymorphism / (D) accept and re-baseline** own Population B and the 514 roots
    that are never known anywhere (`varEverywhere` 279 + `onlySpec` 107 + `pathUnique` 72 +
    `topElsewhere` 56), including the 0 %-success deep-spine cells.

### 8.7 What P0 step 1 still needs an instrument for

The three-way producer split (same item / another item via a signature / nowhere nameable) is
**not** decidable from `pos|` rows — that was the plan's own claim and it holds. But its target
has shrunk from 2,087 roots to **~270 at seven named cells**, and its question has sharpened
from "where is the producer" to "**why did THIS spec miss what its siblings got**". Build the
instrument against Population A only, and gate it on that differential.

### 8.8 Reproduction

Everything above is four short Python passes over `pos.log` (restore with
`gunzip -c build/compiler/build-kernel/bin/varcensus-2026-09-15-pos.log.gz`): de-alias specs via
the root-row member key; recompute chain roots by longest-existing-prefix; build a
`(qualifiedGlobal, path) → Counter(class)` index; then classify. No compiler change was made and
no flag was added.

---

## 9. THE PRODUCER INSTRUMENT — BUILT AND RUN 2026-09-15. One form accounts for the hole.

### 9.0 SCOPE CORRECTION — what this instrument does NOT see

**It only fires for arguments whose own type is a function.** The gate is
`LssInfer.canTypeArrowDepth (TOpt.typeOf arg) == 0 → skip`, and `canTypeArrowDepth` counts
LEADING arrows only (`Can.TLambda _ _ res -> 1 + …`, everything else 0). So:

  - `List.map f xs` — the argument `f : a -> b` IS counted.
  - `Decode.apply d1 d2` — the arguments `Decoder x a` and `Decoder x (a -> b)` are NOT
    counted. They are `Can.TType`, depth 0, even though the second one carries a function in
    its payload. `Compiler.Json.Decode.apply` produces **zero** `prodform|` rows.

**Consequence: §9 answers §8.7's question about Population A (whose cells are `/a0` and `/a0/r`
argument ARROWS) and nothing about container payloads.** The container-payload class — a
function inside a list element, a constructor payload, a record field, a tuple slot — has no
producer-level measurement yet. What is known about it remains §1.2's end-state split
(15,787 positions, 39.7 % covered, 57.6 % var) and §1.3/§1.4's two worked examples.

A v2 of this instrument that walked the argument type for arrows at ANY depth (the `pos|`
walker's recursion, not `canTypeArrowDepth`) would close that gap. It was not built.

### 9.1 What was built

`prodform|` in `Translate.elm` (`prodFormOf` / `prodFormKey` / `prodFormCensusPure` /
`prodFormCensusStep`, plus `unifyParamsCollectAt` threading a callee label and an argument
ordinal). One row per FUNCTION-TYPED call-argument position:

```
prodform|<callee>|a<i>|<branch>|<form>|<slot>
```

`branch` = `inj` (through `argUnifyVar` → `injectArgLambdaMember`) / `lm` (a local-multi
function arg: GAP-9b fresh-instantiates and skips the injection) / `noslot`.
`form` = the argument's syntactic form. **`slot` = the outcome** — the content of the argument
var's own head set slot: `mem` / `edge` / `top` / `flex` (nothing written).

Two design points that are load-bearing:

  - **It reads the slot BEFORE `unifyStepBestEffort pParam argVar`.** Reading after would show
    the union with whatever the callee's param slot already carries from its own spine
    injection and from every other call site, and every row would say `mem`. That confound is
    why `argdeep|` (the predecessor instrument) could only record the form, never the outcome.
  - **`report` AND `arrowCensus` gated.** The protocol mandates `report`, so a report-only gate
    would bill every timed run — the `qCensus` rule.

Analysis-neutral, as required: `coverage:` reads `var=12957` against the baseline run's
`var=12956` (positions 150,166 vs 149,482 — the instrument's own source grew the corpus, the
documented same-day drift). Run: 8:20.0 wall, 14.53 GB peak. Artefacts:
`build/compiler/build-kernel/bin/prodform-2026-09-15.txt` (1,128 keys, 29,762 events) and
`…-context.txt`.

### 9.2 THE RESULT: `call`-result arguments deliver nothing, and the plan of record says they do

| argument form | events | `mem` | `top` | `flex` |
|---|---:|---:|---:|---:|
| `fn` (lambda literal) | 8,962 | **8,962 (100 %)** | 0 | 0 |
| `ref` (`VarGlobal`/`VarBox`/`VarCycle`) | 6,301 | **6,301 (100 %)** | 0 | 0 |
| `accessor` | 41 | 41 (100 %) | 0 | 0 |
| `local` | 10,310 | 8,430 (82 %) | 1,301 (13 %) | 579 (6 %) |
| **`call` (a call result)** | **3,655** | **2 (0.05 %)** | 3 | **3,650 (99.9 %)** |
| `other` | 27 | 0 | 0 | 27 |
| `lm` (GAP-9b skip, by design) | 466 | — | — | — |

Module-wide, 79.8 % of function-typed argument positions receive a member. **Of the 5,000-odd
that do not, `call` is 73 %.**

**This refutes `plans/lss-var-chain-roots.md` §9.5's delivery matrix, which records the call-arg
row as having no hole:** *"call result | DEEP — the inner call's own instantiation carries its
sig facts into the value (§9.1 test 1: `{1},{2}` arrive) | —"*. Measured on the corpus it
delivers 2 times in 3,655. The §9.1 probe that established "DEEP" was a one-module fixture, and
§5.1's standing rule — one-module fixtures cannot manufacture these classes — applies to it.

**Mechanism, read off the code:** `argUnifyVar` does `Store.loadType (TOpt.typeOf arg)`, a FRESH
load (LSS_006: only leaf MVarIds are memo-shared, arrow structure is minted per load), then
`enrichFromEnv` (which enriches at LOCAL leaves only), then `injectArgLambdaMemberGo` — whose
case has arms for `Function`/`TrackedFunction`/`VarGlobal`/`VarBox`/`VarCycle` and nothing else.
A `TOpt.Call` argument matches no arm, so no member is ever written, and the inner call's own
result variable is never unified with this load.

**Measurement caveat, stated precisely.** The read happens immediately after the injection;
`unifyParamsCollect` runs BEFORE the arguments are translated (`translateGlobalCall`'s explicit
ordering), so for a `call` argument the inner call has not been translated yet. The claim that
nothing fills the slot LATER rests on LSS_006 (the fresh load's arrow slots are disjoint from
the inner call's) plus `StashNone` for non-lambda args with `flowConnect` off — not on a second
probe. It is corroborated independently by the end-state `pos|` census: the same cells read
`var` in the emitted artefact, and the counts track (`List.map` `/a0`: 177 call-flex events,
49 `var` specs).

### 9.3 Population A, cell by cell — and the misses are NOT one class

| cell | events | no member | dominant miss |
|---|---:|---:|---|
| `List.foldrHelper` `/a0` | 2,793 | 90 (3.2 %) | **`local`/flex 90 — zero `call` args at this cell** |
| `Compiler.MonoSolver.Engine.andThen` `/a0` | 175 | 5 (2.9 %) | `call` 5 (100 %) |
| `List.foldl` `/a0` | 3,780 | 168 (4.4 %) | `local`/flex 81, `call` 61, `lm` 26 |
| `Dict.foldl` `/a0` | 825 | 85 (10.3 %) | `lm` 42, `local`/flex 40, `call` 3 |
| `List.foldr` `/a0` | 1,334 | 149 (11.2 %) | `call` 114, `lm` 35 |
| `System.TypeCheck.IO.andThen` `/a0` | 375 | 45 (12.0 %) | `call` 45 (100 %) |
| `List.map` `/a0` | 1,408 | 255 (18.1 %) | `call` 177, `lm` 73, `local`/flex 5 |

So §8.4's "why did THIS spec miss what its siblings got" has three answers, not one, and their
mix differs per cell: **`call` args** (the big one, and the one recorded as closed), **`local`
args that arrive un-enriched** (`foldrHelper` is 100 % this, `Elm.JsArray.foldl` 113), and the
**GAP-9b local-multi skip** (466 events corpus-wide, `Elm.JsArray.foldl` 109).

### 9.4 The `call` hole is bigger OUTSIDE Population A than inside it

Top cells losing a call-result argument:

```
Compiler.Parse.Primitives.Cerr   /a2  278     System.TypeCheck.IO.andThen  /a1  247
elm/core:Task.andThen            /a0  246     elm/core:List.map            /a0  177
Compiler.MonoSolver.Engine.andThen /a1 159    System.TypeCheck.IO.map      /a1  127
elm/core:Basics.composeR    /a1 125 /a0 116   elm/bytes:Bytes.Decode.loop  /a1  121
Utils.Bytes.Encode.list          /a0  119     elm/core:List.foldr          /a0  114
Combine.map /a0 113   List.any /a0 106   Maybe.map /a0 87   Task.onError /a0 83
```

The `/a1` rows at `IO.andThen` (247), `Engine.andThen` (159) and `IO.map` (127) are the MONADIC
argument — the `IO a` being bound, which is overwhelmingly itself a call result. Those are not
Population A cells, but they are the same hole, and together with `composeR`/`composeL` (241)
they say the class is "a combinator applied to the result of another combinator" — the shape
this corpus is built out of.

### 9.5 What this changes

  - **A named, measured, previously-closed producer hole: 3,650 events, one argument form, one
    missing case arm.** The repair shape is `enrichFromEnv`'s (a store-level unify of the
    argument's load with the inner call's result var), applied to a form it was never applied
    to. That is a much smaller and better-aimed change than anything in §3.
  - **It is NOT a licence to predict a coverage win.** §9.11 measured raw store-level flow
    (`flowConnect`) as EXACTLY coverage-flat because ⊤ rides along (⊤ +703, k1 −672), and this
    repair feeds the same joins. The honest position: the hole is real and its size is known;
    whether closing it converts `var` into `k1` rather than into `⊤` is the next measurement,
    and this arc's record says predict nothing.
  - **§8.7's target is superseded FOR POPULATION A.** The differential it asked for is
    answered there: the failing specs differ from their siblings by the FORM of the argument at
    that position. §8.7's question for the container-payload class is untouched (§9.0).
  - **Two smaller classes are now also sized**: `local`-args arriving un-enriched (579 flex +
    1,301 ⊤) and the GAP-9b local-multi skip (466). `List.foldrHelper` `/a0` is 100 % the
    first of these and has no `call` args at all, so it is a clean single-cause probe.

### 9.6 Status of the instrument

Built, type-checked, run, and **left in the tree default-off** (it cannot fire without
`ECO_MONO_LSS_ARROW_CENSUS=1`, which is default-off and required alongside `report`). It has NOT
been through E2E, elm-tests, or a fixed-point check — it is a census, it is gated, and
`coverage:` is neutral, but a gate run is owed before anything else lands on top of it.

---

## 10. v2 INSTRUMENT — BUILT AND RUN 2026-09-15 — and THE COMPLETE MAP of where identity is lost

**Decision context (user, 2026-09-15): the target is COMPLETENESS.** The paper's analysis is
complete by theorem; the aim is to close Eco's gap to it, and only then price the cost. Every
"is it worth it" caveat in §1-§9 is therefore recorded but no longer gates the work.

### 10.1 What v2 measures

`prodFormCensusStep` now walks the argument's whole store variable after the injection and
emits one row per arrow at ANY depth, with a `pos|`-style path (`/a` `/r` `/l` `/tN` `/cN`
`/f:name`; the store is curried so an arrow's parameter is always `/a`). Gate is
`canTypeHasArrowDeep`, not `canTypeArrowDepth`, so `Decoder x (a -> b)` arguments are now seen.
Run: 8:27.7 wall, 14.72 GB; analysis-neutral (`var=12958` vs 12,956 baseline; positions grew by
the instrument's own source). Artefacts:
`build/compiler/build-kernel/bin/prodform2-2026-09-15.txt` (3,489 keys, **56,589 arrow
positions** over 29,785 call-argument events) + `-context.txt` + `.time`. Depth cap 16 → 1,272
positions report `fuel`; every one is inside the `Eco.Config` record staircase and would read
`flex`.

### 10.2 The result, by where the arrow sits

| arrow position | events | member landed | ⊤ | **nothing written** |
|---|---:|---:|---:|---:|
| head of a function-typed argument | 29,785 | 80 % | 4 % | 14 % (+2 % lm-skip) |
| interior of an argument's own arrow spine (`…/r`, `…/a`) | 21,105 | 72 % | 6 % | **21 %** |
| **inside a container** (`/cN` `/l` `/f:` `/tN`) | 5,699 | **8 %** | 7 % | **63 %** (+22 % fuel) |

So the container class is far worse than the two the v1 instrument could see, and it is worse
for every argument form:

| form | container events | member | ⊤ | **nothing** |
|---|---:|---:|---:|---:|
| `call` | 3,067 | 4 % | 0 | **78 %** (rest fuel) |
| `fn` (lambda literal) | 1,667 | 6 % | 0 | **52 %** (rest fuel) |
| `local` | 788 | 25 % | **44 %** | 31 % |
| `ref` | 103 | 26 % | 23 % | 50 % |
| `other` (if/case/let/access) | 73 | 0 | 3 % | **97 %** |

And the arrow-interior class shows the same two holes one level in:

| form | interior events | member | ⊤ | **nothing** |
|---|---:|---:|---:|---:|
| `local` | 9,321 | 80 % | 13 % | 6 % |
| `ref` | 3,753 | 78 % | 0 | 22 % |
| `fn` | 7,093 | 67 % | 0 | **31 %** |
| `call` | 922 | 7 % | 0 | **92 %** |

The `fn` interior figure is the interesting one: `flowConnect` (default-on) writes a lambda
literal's translated type back, so its interior SHOULD be delivered — and it is, for lambdas
whose body builds the result. At `System.TypeCheck.IO.andThen` `/a0`: head `mem` 329/329, `/r`
`mem` 131 vs `flex` 198. The 198 are lambdas whose body RETURNS A CALL (`\x -> andThen … m`,
`\x -> someIO x`): the write-back is only as good as the body's result type, and the body's
result is a call result. That is the same hole as the `call` row, one level inside a lambda.

The decoder staircase reads exactly as predicted: `Compiler.Json.Decode.apply` `a1` is `call`
at `/c1`, `/c1/r`, `/c1/r/r` … `/c1/r×15` — **145, 119, 100, 85, 76, 68, 63, 59, 55, 52, 49,
46, 43, 40, 37 — all `flex`**, one row per stage of the 30-ary constructor PAP.

### 10.3 The complete map: every edge a function value crosses, and whether its identity survives

A function's identity is established at exactly ONE kind of place — where a lambda is written
(`l|`), or where a global is named (`g|`/`c|`/`k|`, with `p|` successors) — and from there it
must survive every edge it crosses. The paper never loses it because the set variable travels
INSIDE the expression's type. Eco's `Can.Type` carries no set, so every edge must re-tie the
slot by hand (LSS_006: each `loadType` mints fresh arrow slots; only leaf MVarIds are shared).
This is the audit of every such edge, with the measurement that shows its state:

| # | edge | connected today? | mechanism | evidence |
|---|---|---|---|---|
| E1 | lambda literal → call argument (head) | **yes** | `injectLambdaMemberQualified` | `fn` head 8,962/8,962 mem |
| E2 | lambda literal → call argument (interior) | **partial** | `flowConnect` write-back of the translated type | `fn` interior 67 % mem, 31 % flex — flex = body returns a call (E4) |
| E3 | global reference → call argument | **yes, within declared arity** | `standaloneArgMember` + `injectPapSuccessors` | `ref` head 6,301/6,301; interior 78 % (22 % flex = beyond-arity result, the referent's body → E4/E9) |
| E4 | **call result → call argument** | **YES since 2026-08-25 (`arrowIdentity`) — §11 CORRECTS §9/§10** | the argument's load and the inner call's `unifyResultWithExpected` load are the SAME stamped `Can.Type` object (`TOpt.Call … meta -> translateCall … meta.tipe`), and `arrowMemo` is item-scoped by `ArrowId`, so every arrow slot is shared | the v1/v2 `flex` reads were taken BEFORE the inner call was translated (§9.2's caveat was the truth); F1's write-back is byte-neutral (§11) |
| E5 | **if / case / let / field-access expression → call argument** | **same as E4 — connected by identity** | the expression's `Meta.tipe` is one object; its translation unifies against a load of it | see §11 |
| E6 | enriched local → call argument | **mostly** | `enrichFromEnv` unifies the varEnv-bound MonoType | `local` head 82 % mem, 13 % ⊤, 6 % flex |
| E7 | **local-multi function instance → call argument** | **NO, by design** (GAP-9b) | `StashLocalMulti` fresh-instantiates and skips injection; identity overlaid at the AST level only | `lm` 476 |
| E8 | argument → callee parameter slot | yes | `unifyStepBestEffort pParam argVar` | — |
| E9 | callee body → signature result ordinal | yes | `zonkSigGo` reads the scratch store | `ref` interior 78 % |
| E10 | signature → caller instantiation | yes | `schemeTie`/`schemeFacts`/`schemeResidual` | — |
| E11 | callee type variable instantiated to an arrow | **yes** | ordinary unification binds the var to the caller's `FunL`, slot included | `Ok` `/a0` k1 148 of 238 — the 82 var are E4/E6 at the caller (considered as a root cause and SET ASIDE: `trivial\|extra` is expected, not lost) |
| E12 | **let RHS → let-bound local** | **partial** | storeless `classifyAs tkClassLet` stamps ⊤ at every arrow | `top@clsLet` 307; `local` container args 44 % ⊤ |
| E13 | **destructure → pattern-bound local** | **partial, mostly downstream** | storeless `tkClassDestr` ⊤; the projected root type is ALSO ⊤ 14,232/14,365 (§2) | `top@clsDestr` 281; `destranno\|top\|k1` 133 recoverable |
| E14 | record / tuple / list literal field → payload | **untested** (E4-shaped when the field expr is a call) | field exprs are translated; `enrichFromEnv` recurses tuple literals of locals only | `local\|/f:compileExpr\|flex`, `BytesFusion.Emit` rows |
| E15 | branch join (case/if result) | yes | `unionAnno` + LPartial | `top@conflict` 3 |
| E16 | **kernel boundary** | **no unless licensed** (LSS_004/021/022) | `KernelSetFacts` rows | `top@poison` 208, `top@abi` 249 |
| E17 | cross-item: value built in module A, consumed in B | yes IF A's def has a non-trivial signature at that ordinal (E9+E10 — `loadTypeC` DOES mint ordinals for container-nested arrows: `TType`/`TRecord`/`TTuple` all recurse) | — | `chompArgs` `/r/r/a0/l` = `p\|chompExactly\|1` (§1.3) |

**Everything else observed in this plan is a CONSEQUENCE of one of the unconnected edges
at an earlier hop**, not a separate cause: bare locals (§9: 6 % flex + 13 % ⊤) are parameters
whose members were lost at E4/E5/E7 in the caller; destructure ⊤ (E13) is E12/E4 upstream;
pass-through positions (§8.5, 49.8 % of roots) are correct-by-design once both callers deliver
and become honest `kN`; the `Eco.Config` staircase (79.5 % of var) is an E4 chain — each
stage's second argument is the previous stage's call result; the GLSL operator table (§1.4) is
E13 over an E12-bound local.

### 10.4 Why the decoder staircase resolves ONCE E4 is connected — the acceptance test

Stage 0: `D.pure LssConfig` — the argument is a `ref` (E3): `c|LssConfig` at the head and
`p|LssConfig|k` spine-injected down all 32 result arrows (LSS_013, bounded by the ctor's
declared arity 32). `pure : a -> Decoder x a` binds `a := (Bool -> … -> LssConfig)` by ordinary
unification (E11), so `pure`'s result payload slot IS the argument's slot: known.
Stage 1: `D.apply f1 (pure LssConfig)` — argument 2 is a CALL (E4): today, nothing. With E4
connected, the call's translated type (`callResultType` = `peelResult` of the zonked inner
`funcVar`, which carries the sets) is unified into `apply`'s param 2; the annotation
`Decoder x (a -> b)` ties that arrow's result var to `b`, which IS the result's `Decoder x b`
payload — so stage 1's result payload carries `p|LssConfig|1`, spine-injected. Induction.
**Prediction, pre-registered: connecting E4 alone should convert the staircase's ~10,300 var
positions to `k1` singletons naming `p|LssConfig|k`** (and its `Outline`/`Docs` siblings), plus
`List.map` `/a0` 177, `List.foldr` 114, `Task.andThen` 246, `composeR` 241, `IO.andThen` `/a0`
45 and part of the 198 at `/r`. If the staircase does NOT flip, the E11 reasoning above is
wrong and that is the first thing to re-check.

### 10.5 THE COMPLETENESS FIXES — one per unconnected edge

**F1 — Universal argument write-back (E4, E5; and E2's residue).** **IMPLEMENTED 2026-09-15**
as `lss.flow.all` (env `ECO_MONO_LSS_FLOW_ALL`, JSON `flowAll`, hash token `lssFA=1`,
DEFAULT-OFF, requires `flow.connect`). `flowConnect` moved unchanged into the new `flow`
sub-record (`LssFlowConfig { connect, all }`) because `LssConfig` sits AT the 32-field cap;
its JSON key, env var and `lssFC` token are untouched. Producer: `unifyParamsCollect` stashes
`StashParam` when `isLambdaLiteral arg || (flow.all && canTypeHasArrowDeep (typeOf arg))`.
Consumer: `translateArgsWith`'s `StashParam` arm calls `connectParamArg` for ANY translated
type under `flow.all` (census `flow|connAll`; lambda literals keep `flow|connLam`). Audit
counter `flow|callTopFallback` added in `callResultType` (report-gated). Unit gate: 13,543
passed, the standing 12 POST_010 failures only. Benchmark: `benchmarks/call-stats.md`
Runs 21 (control) / 22 (F1). Generalize `flowConnect`:
in `unifyParamsCollect`, stash `StashParam pParam` for EVERY argument whose type has an arrow
at any depth (`canTypeHasArrowDeep`), not only `isLambdaLiteral`; in `translateArgsWith`'s
consumer, drop the `MFunction`-only guard and call `connectParamArg` on whatever type the
translation returns. `connectParamArg` already does the right thing (`deTopAnnos` → fresh vars
for ⊤, `monoTypeToVar`, store-level `unifyStepBestEffort`), and the ordering is already right
(args are translated AFTER `unifyResultThenInjectPap` and BEFORE `zonkToMono funcVar` /
`enqueueSpecStamped`, so the stored demand includes the write-back). One predicate change and
one guard removal. Two audits ride with it: (a) `callResultType`'s fallback
`classifyAs Mono.tkClassCall callCanType` fires when the peeled result `containsAnyMVar` and
stamps ⊤ storelessly — count it; if it fires on arrow-bearing results it is a ⊤ manufacturer
sitting exactly on the path F1 opens; (b) `flow|topCarried`.
*Prior art, stated plainly:* this is `plans/lss-gap2-callarg-transport.md` D1/D2, which was
BUILT, MEASURED and DELETED on 2026-08-24 — it worked (2,480 connections, singleton sets
+10.7 %) and was removed for +2.68 % wall and −0.51 pp fast dispatch under the DISPATCH metric,
with the note "do not re-add a transport layer before fixing arrow identity". Since then arrow
identity shipped (08-25), LPartial shipped (09-01), and the SAME write-back for lambda literals
(`flowConnect`) shipped default-on under the COVERAGE metric (09-01, var −80). The premise has
changed three times and the metric has changed; this is a re-proposal, not a repeat.

**F2 — Local-multi instance write-back (E7).** Keep the fresh param var in the `localMulti`
entry's instance record (`{freshName, monoType}` gains the store var), and when the instance's
RHS type is settled (`flushLocalMultiEnrich` / the E4a `pendingEnrich` walk, which already
carries `instance -> typeOf rhs`), `connectParamArg` it into that var. Store-level, same shape
as F1. Design risk: the use-site spec may already be enqueued by then — LSS_010 re-translation
(the drain-flush) is the existing answer; measure `retranslations`.

**F3 — Store-aware let binding (E12).** Bind a let-bound local's varEnv type to the RHS's
TRANSLATED MonoType (which carries sets) rather than `classifyAs tkClassLet`'s storeless ⊤ —
the same repair GAP-A applied to `translateVarRef`. Then E13's projection
(`Mono.getMonoPathType`) reads real members from the root local, and the 14,232 `destranno`
top/top cells shrink to whatever E4/E5 still leave. Size the `clsLet` class first (307 ⊤
positions, but the `local` container 44 % ⊤ suggests more reach the census as `var` after
joins).

**F4 — Literal field write-back (E14). MEASURED OUT 2026-09-16 (§12.10): 129 arrow-typed literal elements corpus-wide, 120 already carried by the literal's store type; re-scoped to E15 / F2.c / F4-sig.** Record, tuple and list LITERALS: unify each field/
element var of the literal's loaded type with the translated field expression's type
(`enrichFromEnv` already recurses TUPLE literals of LOCALS; extend to all three literal forms
and all expression forms). Instrument first — the v2 census sees literals only when they are
call arguments.

**F5 — Kernel licences for function-carrying containers (E16).** `Dict`/`Array`/`Set` of
functions cross a kernel boundary and poison. The LSS_022 `TypeFaithful` licence discipline is
the fix, per kernel, with the audit checklist and the sha-pinned manifest. Independent of
F1-F4; sized by `top@poison` 208 + `top@abi` 249 = 3.2 % of the uncovered book — last.

**F6 — (instrument only) raise the walk's depth cap** so the 1,272 `fuel` rows read
correctly; the staircase's deep positions are `flex`.

**Order: F1 → re-census → F3 → F2 → F4 → F5.** F1 is one predicate + one guard and carries the
pre-registered staircase prediction; everything after it must be re-measured on the post-F1
book, because F3/F4's populations are partly F1's consequences.

### 10.6 Gates (completeness metric) — pre-registered

  - Accounting: `var` delta == positions flipped to `k1`/`kN` at the named cells, to the digit
    (`writes == var delta`, the settle-pass rule).
  - The §10.4 staircase prediction, checked by name (`p|LssConfig|k` at the `Result.map` /
    `Decode.apply` cells).
  - E2E both arms, elm-tests, `ECO_MONO_VALIDATE`, bootstrap fixed point (Stage 8c
    byte-identical) — F1 changes stored demand types and therefore spec keys.
  - RECORD, do not gate on: wall, RSS, `fast %`, `sat`, spec count, `retranslations`,
    `flow|topCarried`. The GAP-2 deletion happened on these; the user has moved the metric.
  - `topCarried` and `conflict` are the two counters that would say the join lattice is still
    the blocker; if either moves by more than noise, stop and look before F2.

### 10.7 Considered and set aside

  - **"Instantiation-born arrows have no signature ordinal"** (`sigfact trivial|extra` 11,814).
    Considered as a root cause; it is not one. Ordinary unification at the call binds the
    callee's type variable to the caller's arrow WITH its slot (E11), so the position gets
    whatever the caller's argument carried. The class is large because the callers lose at
    E4/E5/E7, not because the signature cannot name the position.
  - **Set variables in spec keys / the paper's `ᾱ`** (`plans/lss-set-variable.md` §2): still
    blocked on sum lowering for the DISPATCH payoff; not needed for any fix above.
  - **Row aggregation across a global's specs**: dead three times (§8.3).

---

## 11. F1 BUILT AND MEASURED 2026-09-15 — NULL, and the reason corrects §9/§10

### 11.1 What happened

`lss.flow.all` implemented as §10.5 describes (flag details in the F1 entry above; unit gate
13,543 passed / the standing 12 POST_010). `benchmarks/call-stats.md` protocol, two arms on one
subst-emitted reference compiler (`f1-eco-std-census`, current tree):

| arm | `flow\|connLam` | `flow\|connAll` | `flow\|topCarried` | `coverage:` | emission |
|---|---:|---:|---:|---|---|
| `ECO_MONO_LSS_FLOW_ALL=0` | 8,970 | — | 10 | `positions=150259 k1=101296 kN=34873 var=12958 top=1101 part=31` | 13,403,612 B |
| `ECO_MONO_LSS_FLOW_ALL=1` | **29,289** | **788** | **2,001** | **identical to the digit** | **byte-identical** |

**30,077 write-backs fire and the artefact does not move by one byte.** Cost on the reference
arm: wall 10:22.6 → 10:30.9 (+1.3 %), RSS +0.6 %, minor GC 2,276 → 2,296, promoted +85 MiB.
The §10.4 prediction (staircase flips to `p|LssConfig|k`) is **FALSIFIED**; per §10.4's own
instruction, the E11 step was re-checked — and it is not E11 that is wrong.

### 11.2 The mechanism — verified in code, and it invalidates the E4 verdict

`connectParamArg` unifies `monoTypeToVar (typeOf monoArg)` into `pParam`. For a call-result
argument, `typeOf monoArg` is the zonk of the inner call's result var. But that var was
ALREADY unified with the outer argument's load before F1 touched it:

  - `translate (TOpt.Call region func args meta)` calls `translateCall … meta.tipe`
    (Translate.elm:681), so the inner call's `callCanType` IS the `Can.Type` object that
    `argUnifyVar` loads for the outer argument (`TOpt.typeOf arg = (metaOf arg).tipe`).
  - `unifyResultWithExpected` does `Store.loadType callCanType` and unifies it with the inner
    call's result var.
  - `Store.loadTypeC`'s `TLambda` arm memoises set slots by `ArrowId` in `itemAux.arrowMemo` —
    item-scoped, ACROSS loads (Store.elm:125/201/418-433). Under `arrowIdentity` (default-on
    since 2026-08-25) two loads of one stamped type object share every arrow slot.

So the argument's slots, at every depth, are the inner call's result slots. F1 writes back a
zonk of a class into itself. **Edge E4 (and E5, the same shape) has been connected by
identity since 2026-08-25.** §10.3's "NO" was true of the tree the GAP-2 plan measured
(2026-08-24, the day before arrow identity shipped) and false of this one.

### 11.3 What the v1/v2 instrument actually measured

`prodform|` read the argument's slots in `unifyParamsCollect` — BEFORE `translateArgsWith`
translates the argument, i.e. before the inner call exists in the store. §9.2 recorded exactly
this caveat and then argued it away with LSS_006 ("the fresh load's arrow slots are disjoint");
that argument is pre-`arrowIdentity` and wrong. The `call | flex` rows (head 3,650, container
2,389, interior 851) are true statements about a moment, not about the end state: they say
"nothing has written this slot YET", which for a call-result argument is tautological at that
moment. The corroboration I offered — "the same cells read `var` in the emitted artefact" — is
real but its cause is not E4.

**Consequence for the edge map:** the var at `List.map` `/a0` (49 specs), `IO.andThen` `/a0`
(66) and the staircase is produced UPSTREAM of the argument edge — by whatever the inner call's
result carries, which is E9/E10 (the inner callee's signature result ordinal) and, recursively,
the forms at ITS arguments, bottoming out at a bare parameter (E6), a local-multi instance (E7),
a storeless-⊤ local (E12/E13) or a kernel (E16). The staircase induction in §10.4 fails at a
link this plan has not located; candidates are `injectPapSuccessors`' spine depth for a record
CONSTRUCTOR reference (`spineDepthForGlobal` on `LssConfig`) and the ⊤ at `/a0/a0` (`clsDestr`,
E13 on `apply`'s destructured parameter). Neither is decidable from the existing censuses.

### 11.4 What a correct producer instrument looks like (v3 — NOT built)

Same deep walk as v2, but read in `translateArgsWith` AFTER `translate arg` (and after
`connectParamArg`), on `pParam` rather than on the pre-translation load. That reads the slot at
the moment the callee's demand is about to be zonked and enqueued — the end-state the `pos|`
census sees — and it attributes each still-`flex` position to the FORM of the sub-expression
that produced it. The user removed v1/v2 from the tree (2026-09-15); v3 would be a temporary
instrument, run once and removed.

### 11.5 Disposition of F1

**Keep the flag, DEFAULT-OFF, as a measured null** (the arc's convention for refuted mechanisms
with clean flags): it is one predicate and one guard, it is byte-neutral, and its census
counters (`flow|connAll`, `flow|callTopFallback` = 32) are the record. Do not flip it. F2 (E7)
and F3 (E12) are NOT invalidated by this — they connect edges identity does not reach (a fresh
instantiation and a storeless classify respectively) — but their sizing in §10.5 inherited the
E4 misattribution and must be re-derived from a v3 read before either is built.

---

## 12. THE CORRECT PRODUCER CENSUS (v3, 2026-09-15) — and the bug it found

F1 was reverted from the tree in full (`flow` sub-record, flag, guard, helper, test literal) at
the user's direction. The census was rebuilt to read the CALLEE'S PARAM variable in
`translateArgsWith` AFTER `translate arg` — after the inner call / lambda / local has been
translated and after `flowConnect`'s write-back — via a census-only `StashCensus` wrapper in
`ArgStash` (`Translate.elm`, TEMPORARY, report+arrowCensus gated). Rows:
`prodform|<callee>|a<i>|<path>|<form>|<slot>`. Run 8:19.9 wall / 14.64 GB; analysis-neutral
(`var=12958`). Artefacts: `build/compiler/build-kernel/bin/prodform3-2026-09-15.{txt,-context.txt,.time}`.

### 12.1 End state at call-argument positions (56,735 arrow positions)

| where | events | member | ⊤ | **nothing written** |
|---|---:|---:|---:|---:|
| head | 29,750 | **91 %** | 5 % | 4 % (1,128) |
| interior of the argument's arrow spine | 21,815 | 73 % | 6 % | 21 % (4,612) |
| inside a container | 5,170 | 20 % | 9 % | **71 % (3,678)** |
| **all** | 56,735 | 78 % | 6 % | **16.6 % (9,418)** |

Head, by argument form — the row that overturns §9:

| form | events | member | ⊤ | nothing |
|---|---:|---:|---:|---:|
| `fn` (lambda literal) | 8,959 | 100 % | 0 | 0 |
| `ref` (global) | 6,300 | 100 % | 0 | 0 |
| **`call` (call result)** | 3,647 | **94 %** | 4 % | **2 % (67)** |
| `local` | 10,301 | 82 % | 13 % | 6 % (579) |
| **`localMulti`** | 474 | **1 %** | 0 | **99 % (468)** |
| `if` / `case` / `let` | 14 | 79 % | 21 % | 0 |
| `access` | 14 | 0 | 0 | 100 % |

§9's "call results deliver 2 in 3,655" was the pre-translation read. Post-translation they
deliver 94 %. Edge E4 is connected (§11.2). **The only head-level form that fails
systematically is the local-multi function argument** — GAP-9b, 99 % nothing, 468 + 378
interior + 20 container = **866 positions**.

### 12.2 Where the 9,418 unwritten positions are

| class | positions | share | cause |
|---|---:|---:|---|
| **the `Eco.Config` decoder staircase** (`Decode.apply`/`map`/`andThen`/`pure`/`Decoder`, `Result.map`/`andThen`/`Ok`/`Err`) | **5,584** | **59.3 %** | §12.3 — ONE BUG |
| `local` (non-staircase) | 1,422 | 15.1 % | bare locals: E6/E12/E13 (binding kind unmeasured) |
| `localMulti` | 863 | 9.2 % | E7, GAP-9b |
| `ref` interior (`…/r/r` and deeper) | 743 | 7.9 % | §12.3 — THE SAME BUG |
| `call` (non-staircase) | 517 | 5.5 % | inner callee's result genuinely unknown (E9 upstream) |
| `fn` interior (non-staircase) | 237 | 2.5 % | lambda body returns something unknown |
| `access` / `record` / `tuple` | 52 | 0.6 % | — |

Top non-staircase cells: `Elm.JsArray.foldl` 444 (113 `local` + 109 `localMulti` at head and at
`/r`), `Dict.foldl` 329, `List.foldl` 319, `Parse.Primitives.Cerr` 283, `List.foldrHelper` 243,
`Bytes.Decode.map3` 196 (`a0 /r/r` `ref`), `IO.andThen` 173.

### 12.3 THE BUG — every PAP-successor walk writes depth 1 and stops

The decisive row is `Compiler.Json.Decode.pure` `a0`, whose argument is the record CONSTRUCTOR
itself. Read on `pure`'s param after translation:

```
ref  (head)      mem 11        fn (head)        mem 6
ref  /r          mem  9        fn /r … /r×7     mem 6,6,3,3,2,1,1   (full spine)
ref  /r/r        flex 7   ← every reference constructor of arity ≥ 3
ref  /r/r/r …    flex 5,4,3,3,3,3 … 3 (to depth 19), 2 (to 26), 1 (to 31)
```

The three `flex` lines running to depths 19/26/31 are `EcoConfig`/`InlineConfig`/`LssConfig`
(arity 20/27/32). Yet the end state MINTS `p|LssConfig|1..31`, `p|InlineConfig|1..26`,
`p|EcoConfig|1..19` (registration self-identity) — the ids exist; the reference-spine walk
never writes them past depth 1. And `papInject|deep|d2 433, d3 40, d4 1, d5 1`: the producer-side
residual walk (`injectPapSuccessorsFrom`, `injTotal`) also writes exactly its FIRST depth.

Read off the code (`LssInfer.elm`, `papSuccGoC` / `papSuccWrite`): `papSuccGoC` checks `seen`
for `v`, inserts `v`, descends to `res` via `papSuccWrite`; `papSuccWrite` checks `seen` for
`res`, **inserts `res` into `seen1`**, writes the member into `res`'s slot, then calls
`papSuccGoC rest seen1 res` — whose first line finds `res` in `seen1` and returns. The walk is
dead after one write. The sibling `spineGoC` (lambda spines, LSS_013) inserts each variable
once and descends — which is why lambda-literal constructors get their full spine (`fn` rows
above) and reference constructors do not. No cap, no arity error: `declaredArityOf` is right,
`mintPapSuccessorIds` mints all depths, one `seen` insertion too many discards them.

**Consequences, all previously misattributed:**
  - the entire decoder staircase (5,584 end-state flex here; ~10,300 of the 12,958 `var`
    positions in the artefact census) — `D.pure LssConfig` names depth 0-1, stage 2 onward has
    nothing to inherit;
  - the `ref` interior class (743): a global passed as a callback to `map3`/`chompAndCheckIndent`
    /`specialize` gets `p|g|1` and never `p|g|2` — exactly `/r/r`;
  - `injTotal`'s "deep residual" has been one level deep since it shipped.

**Fix (applied 2026-09-15, one line):** `papSuccWrite`'s `FunL` arm recurses
`papSuccGoC rest seen res …` — `seen` unchanged — so `papSuccGoC` records the variable it is
entered on, mirroring `spineGoC`. The `Alias` arm keeps `seen1` (aliases are chased, not
written). Type-checks; A/B census against `prod3` in §12.6.

### 12.4 The edge map, corrected for the third time

| edge | state | evidence (v3) |
|---|---|---|
| E1 lambda → argument head | connected | `fn` head 100 % |
| E2 lambda interior | mostly; residue = body returns an unknown | `fn` interior 67 % mem |
| E3 global reference → argument, head + depth 1 | connected | `ref` head 100 %, `/r` mem |
| **E3′ global reference → argument, depth ≥ 2** | **BROKEN — the §12.3 bug** | `ref` `/r/r` flex 743; `pure` rows |
| E4 call result → argument | connected (identity, §11.2) | `call` head 94 % |
| E5 if/case/let/access → argument | connected | 79-100 % (tiny) |
| E6 enriched local → argument | mostly | `local` head 82 % |
| **E7 local-multi instance → argument** | **NOT connected (GAP-9b)** | `localMulti` 99 % flex, 866 |
| E12/E13 let / destructure | partial (storeless ⊤) | `local` ⊤ 13 % head, 44 % container |
| E16 kernel boundary | licence-gated | ⊤ |
| **E18 producer PAP residual, depth ≥ 2** | **BROKEN — the same bug** | `papInject|deep|d2..d5` |

§10.5's F1 and §11 are superseded: there was no missing argument edge; there was a walk that
stopped after one step, on both sides of the reference/PAP identity.

### 12.5 Reconsidered fixes, in order

  1. **The `papSuccWrite` seen-guard fix (§12.3)** — applied; measured in §12.6. Predicted to
     resolve the staircase (`/c1/r…` down the whole spine) and the `ref` interior class.
     Artefact-affecting; owes E2E / elm-tests / bootstrap fixed point before it stays.
  2. **F2 — local-multi use-site member injection (E7)**, sized at **866 positions, 99 % flex**, the
     only systematically failing argument form. Design (i) of §12.8, lowered in §12.9.4: at the
     `StashLocalMulti` consumer mint the instance's own id and write it into the stashed var's spine
     before the callee is zonked; plus the self-reference sub-class (258). §10.5's store write-back
     design is withdrawn (translation order, §12.8).
  3. **F3 — (a) row-deferred payload sets at destructures, (b) store overlay at let/tail-fn
     bindings (E12/E13)**, sized in §12.9.1: the local ⊤ are 87 % destructures of SYNTACTIC payload
     arrows (`Parse.Primitives` re-wraps), 250 `clsDestr` + 180 `clsLet` artefact positions. Lowered
     in §12.9.5. The bare-local FLEX (1,292) are 79 % parameters — a chain from F2, not F3's target.
  4. **E2 residue (2,452 `fn` interior flex, mostly staircase)** — re-read after fix 1; whatever
     remains is a lambda body returning an unknown, i.e. one of the above one hop in.
  5. **F1 (universal argument write-back): CLOSED** — measured null, mechanism explained, code
     reverted.
  6. **F5 kernel licences** — unchanged, last.

### 12.6 A/B — the `papSuccWrite` fix, measured (2026-09-15)

Same v3 instrument, same seed, same workload; `prod3` = tree with the bug, `prod4` = tree with
the one-line fix. Artefacts `build/compiler/build-kernel/bin/prodform4-2026-09-15.*`.

| | bug (`prod3`) | **fix (`prod4`)** | Δ |
|---|---:|---:|---:|
| `positions` | 150,219 | 150,222 | +3 (source drift: the comment) |
| `k1` | 101,245 | **114,125** | **+12,880** |
| `kN` | 34,884 | 33,748 | −1,136 |
| **`var`** | **12,958** | **1,380** | **−11,578 (−89.3 %)** |
| `⊤` | 1,101 | 937 | −164 |
| `part` | 31 | 32 | +1 |
| **analysis coverage** | **90.62 %** | **98.43 %** | **+7.81 pp** |
| `sigfact trivial\|extra` | 11,815 | 261 | −11,554 |
| `varfix3 noHead` | 4,846 | 1,062 | −3,784 |
| `varfix3 contamVarShared` (all tags) | 4,918 | 54 | −4,864 |
| `liveness controlBp` | 9.11 % | 13.63 % | more concrete arrows are now applied ones |
| unwritten arg positions (v3 census) | 9,418 | **2,725** | −71 % |
| wall / RSS | 8:19.9 / 14.64 GB | 8:27.0 / 14.61 GB | flat |
| emission | 13,404,356 B | 13,403,803 B | differs (expected: stored types moved) |

`Decode.pure`'s constructor reference now reads `mem` at every depth 0..31. The `var` book fell
by more than the whole decoder staircase (~10,300), because the same walk feeds every
reference-to-a-HOF callback (`map3`, `chompAndCheckIndent`, `Dict.foldl`…) and every producer
PAP residual.

**The residual (2,725 end-state unwritten argument positions), by cause:**

| class | positions | share | cause / next fix |
|---|---:|---:|---|
| `local` — a bare local reference | 1,292 | 47 % | **measured in §12.9.1:** 1,024 parameters (whose demands are 92 % `mem` — a chain from the rows below), 258 local-multi self-references (F2.b), 10 noise. NOT a class of its own |
| **`localMulti`** | **866** | **32 %** | E7, GAP-9b — **F2, unchanged and now the largest single mechanism** |
| `fn` interior — a lambda whose body returns an unknown | 349 | 13 % | one hop in: the body's result is one of the classes above (`IO.andThen a0 /r` 106, `Result.map a0 /a` 145 = the callback's PARAMETER arrow, filled by `Result.map`'s body, not the caller) |
| `call` | 107 | 4 % | inner callee's result genuinely unknown |
| `ref` | 59 | 2 % | beyond declared arity (LSS_013 boundary) |
| `access` / `record` / `tuple` | 52 | 2 % | E14 literal fields |
| staircase family | 148 | 5 % | (the `Result.map a0 /a` 145 above — a lambda-param arrow, not a spine) |

Cells: `Elm.JsArray.foldl` 444, `List.foldl` 319, `Dict.foldl` 246, `List.foldrHelper` 243,
`Result.map` 145, `IO.andThen` 123, `List.foldr` 100, `List.map` 80.

**Gates for keeping the fix (artefact-affecting, default-on mechanism):** elm-tests
**13,543 passed / the standing 12 POST_010 only (PASS)**; E2E `--target full` **PASS
(`Tests failed: 0`, exit 0)**; bootstrap fixed point (Stage 8c) — NOT YET RUN; and a
`benchmarks/call-stats.md` pair (Runs 23/24) to record dispatch/wall, since `p|g|d` members now
reach every HOF callback site the `papFast` stamp consults.

### 12.7 What the fix did NOT do — the consumer side (2026-09-15)

Static call-kind census of the emitted artefact (`ecoc --emit=mlir`, `_call_kind` on
`eco.papExtend`), before → after the fix:

| kind | `prod3` | `prod4` |
|---|---:|---:|
| `singleton_fast` | 15,405 | 15,410 (+5) |
| `segmentation_unknown` | 11,686 | **11,674 (−12)** |
| `direct_known_segmentation` | 5,906 | 5,905 |
| `generic_apply` | 326 | 326 |

AbiCloning's line: `stampedPapGlobal` 3,356 → 3,361, `dispatchUpgraded` 16,795 → 16,791,
`declinedNoInstance` 9,606 → 9,602, `devirtPost ctor` 310 → 319. **Coverage +7.81 pp, emitted
code essentially unchanged.** The decoder staircase is NOT fused and NOT devirtualized.

Why, from `AbiCloning.papResolve` (the ONLY consumer of a `p|g|k` singleton, LSS_040): it
matches the site against `g`'s spec rows with `List.length params == k + List.length fargs` —
i.e. it stamps a `papExtend` only when the extension SATURATES the global, turning it into a
direct fast call of the spec with `k` captured + the new args. A non-saturating extension has no
evaluator to call; it is an allocation of a bigger PAP, and `papResolve` returns `papShapeMiss`
for it by construction. The staircase supplies ONE argument per stage to a 32-ary constructor:
31 of its 32 extensions are non-saturating, so they stay `segmentation_unknown` (a runtime
"does this saturate?" check followed by a PAP build) no matter how well the analysis names them.
The +5 `stampedPapGlobal` are the saturating final stages.

Two consumer-side changes would use what the analysis now knows, neither built:

  1. **`direct_known_segmentation` from a `p|g|k` singleton at a non-saturating site**: the
     member's declared arity gives the remaining arity exactly, so the runtime segmentation
     check is redundant — emit the plain PAP build. Removes a dynamic check per stage, not the
     allocation. Small.
  2. **Applicative fusion** (`plans/saturating-pap-chain-fusion.md` §8.5, the `mapN` synthesis
     through the `Decoder`/`Ok` boxes) — the only thing that deletes the 32 intermediate PAPs,
     32 stage closures and 32 `Result` boxes. It was unjustifiable while the stage functions
     were unknown; every stage is now a named singleton, so the precondition holds. Still cold on
     this workload (§1.3 of that plan) — the value is on decoder-heavy programs, and the
     `Outline`/`Docs` chains that DO run here.

This is the GAP-6 lesson in its purest form: completeness is now near the paper's; the
consumers were designed around what the analysis used to deliver.

### 12.8 F2 and F3 are NOT implementation-ready — what each still needs

**SUPERSEDED by §12.9 (same day): the v4 census answered both P0s; F2 and F3 are lowered there.**

Asked directly (user, 2026-09-15) whether §12.5's next two fixes are ready to build. They are
not, for different reasons, and §12.6's `local` row overstated what was measured (corrected
above).

**F2 — local-multi instance write-back (E7). Size solid, design probably INFEASIBLE as written.**
The 866 positions are a real measurement: `localMulti` is its own census form, 99 % unwritten,
no ambiguity. But §10.5's mechanism — "keep the fresh param var and `connectParamArg` the
instance's settled RHS type into it" — does not fit the order of translation, verified in
`Translate.elm:7079-7130`:

1. `pushLocalMulti name`; `classifyAs tkClassLet` gives the declared (storeless-⊤) type;
2. `insertVar name declType`; **`translate body`** — every use site that passes the local as an
   argument runs here, takes the `StashLocalMulti` path, records its instance, and
   `enqueueSpecStamped`s the callee with a param slot that is empty;
3. `popLocalMulti`; **`buildLocalDefs`** re-translates each instance RHS via `retranslateAt`,
   **in a FRESH solver store** (deliberately: "so the demand's concretization doesn't contaminate
   the surrounding item");
4. `flushLocalMultiEnrich` overlays the instance types onto the already-emitted use sites — at
   the ANNOTATION level (`overlayLocalMultiUses`), not in the store.

So the RHS type does not exist until after the callee's demand was zonked and keyed, and when it
does exist it lives in a different store. That the existing machinery does an AST-level overlay
here is evidence the store route was already found closed, not an oversight to reuse.

Two candidate designs, neither worked out:
  - **(i) use-site member injection.** The local's RHS is a `TOpt.Function` with a
    `SrcLambdaId`, so `injectLambdaMemberQualified` could fire at the use exactly as
    `injectArgLambdaMemberGo` does for a lambda literal — no ordering problem, the id is a
    function of the source. Blocked on LSS_038's hazard: local-multi instance keying is
    annotation-SENSITIVE while member qualification was instance-blind, which already produced
    one member id indexing two bodies (the `declinedBodyMismatch` class,
    `plans/lss-instance-qualified-members.md`). Needs the instance ordinal at the use site.
  - **(ii) re-key on overlay.** Make `flushLocalMultiEnrich`'s overlay move the callee's demand,
    i.e. drive an LSS_010 re-translation. Bigger, and it reopens the drain-flush.

**P0 before either:** is the RHS's `SrcLambdaId` reachable from the use site, and is the instance
ordinal known there (or only after `recordLocalInstance` returns)? Both are one census pass.

**F3 — store-aware let binding (E12/E13). Target population NOT MEASURED, and mis-stated.**
Two separate errors in §12.6:

  - The census's `local` form comes from `prodFormOf` matching `TOpt.VarLocal` /
    `TrackedVarLocal`. It says the argument is a local reference and nothing else; a function
    PARAMETER, a `let` binding and a destructured pattern binding are indistinguishable, and
    `Engine.varEnv` is `name -> MonoType` with no kind tag. The §12.6 row asserted "a callback
    arriving as a PARAMETER" — an inference, not a measurement, now corrected.
  - **F3 repairs a ⊤, not a flex.** `classifyAs tkClassLet`/`tkClassDestr` stamp ⊤ at every
    arrow; the positions that reach the census as `top` at `local` arguments are 2,865 events
    (head 1,290 + interior 1,233 + container 342), a DIFFERENT and larger population than the
    1,292 flex the §12.6 table attached to it. (Event counts, multiplicity across call sites —
    not artefact positions, where total ⊤ is 937. Never divide one into the other.)

And a floor to establish first: if a large share of the 1,292 flex are function parameters, their
members come from the enclosing spec's own demand, and for a genuinely polymorphic HOF that is
CORRECTLY unknown — part of the class is a floor, not a defect. §8.5's pass-through finding says
the same thing from the other side.

**P0 before F3:** tag `varEnv` insertions with their binding kind (param / let / destructure /
case-binding) and re-read, splitting both the 1,292 flex and the 2,865 ⊤ by kind. Until that
runs, F3's target is unknown and could be near-empty.

**Recommendation.** One combined v4 census pass answers both (binding-kind tag + the F2
reachability question) in a single emit/lower/run cycle. Build neither fix before it.

### 12.9 v4 census (2026-09-15): binding kinds and the local-multi join — F2 and F3 LOWERED TO IMPLEMENTATION-READY

The combined pass §12.8 asked for. Same instrument as v3 plus: every `Engine.insertVar` site
tagged with its binding kind (`param` / `let` / `letMulti` / `tailFn` / `destr` / `destrRoot`), the
`local` census form split by that kind; and the local-multi JOIN — at every `StashLocalMulti` use
`lm|use|<rhs shape>|ord=<k>` + `lmjoin|use|<global>.<def>|ord=k`, at every `buildLocalDefs`
re-translation `lmjoin|rhs|<global>.<def>|ord=k|<head member>`. Artefacts
`build/compiler/build-kernel/bin/prodform5-2026-09-15.*`. **Instrument neutral:** `var` 1,380 /
`⊤` 937 / `part` 32 identical to `prod4`; `positions` +42 are the instrument's own source (the
self-compile compiles it). Wall 8:39, RSS 14.8 GB.

#### 12.9.1 The `local` argument form by binding kind (event counts, all depths)

| kind | events | `mem` | `flex` | `⊤` | reading |
|---|---:|---:|---:|---:|---|
| `param` | 17,428 | 16,120 (92 %) | 1,024 | 284 | heads 95 % `mem`: the demand DOES deliver parameters' sets. Flex heads 435 (`foldrHelper a0` 90, `List.foldl a0` 78, `Dict.foldl a0` 40 …) are the enclosing spec's `f` handed on to a fold — a CHAIN whose roots are the rows below, not a class of their own |
| **`destr`** | **2,580** | 99 | 0 | **2,481 (96 %)** | **F3's real target.** Head 1,259 + interior 1,198 + container 24. 1,198 of the 1,259 heads (95 %) are ONE shape in ONE module: `Compiler.Parse.Primitives` — `Cerr a2` 580, `Eerr a2` 574, `toErr a2` 40 |
| `letMulti` | 260 | 2 | 258 | 0 | a local-multi function referenced INSIDE ITS OWN instance re-translation (`Array.foldl.helper` passing `helper` to `JsArray.foldl`): the stack is already popped, `varEnv` no longer binds it (`enrich\|unbound` 257 ≈ 258) — F2's second sub-class |
| `let` | 75 | 15 | 0 | 60 | all 60 at container depth (E12 on a literal RHS — F4's domain) |
| `tailFn` | 40 | 0 | 0 | 40 | local tail-def bound from `classifyAs tkClassLet` (Translate.elm:6283) |
| `unk` | 10 | 0 | 10 | 0 | pattern var of an unmatched kind (noise) |

The §12.6/§12.8 worry is settled: **the 1,292 bare-local flex are 79 % parameters (1,024), and
parameters are 92 % `mem`** — the flex ones are downstream of the local-multi and lambda-interior
classes, to be re-read after F2, not repaired. And **the 2,865 local ⊤ are 87 % destructures**
(2,481), 258 param-container, 60 let-container, 40 tail-fn, 11+15 param head/interior.

The artefact-position ⊤ book (937), by provenance kind, for the same run: `clsDestr` **250**,
`abi` 250, `poison` 208, `clsLet` **180**, `clsMisc` 38, `clsLocal` 8, `conflict` 3. F3 addresses
the two bold kinds — 430 positions, 46 % of all ⊤.

#### 12.9.2 What the destructure class IS (read at the source)

`Compiler/Parse/Primitives.elm`: `type PStep x a = Cok a State | Eok a State | Cerr Row Col
(Row -> Col -> x) | Eerr Row Col (Row -> Col -> x)`, and the combinators re-wrap a step:

    case parseA s of                                   -- root = a CALL result of type PStep x a
        Cerr r c t -> Cerr r c t                       -- lines 157-161, 278-282, 405-409
        Eerr r c t -> Eerr r c t

`t : Row -> Col -> x` is a SYNTACTIC PAYLOAD ARROW: the arrow is a constructor field, not a type
argument, so the scrutinee's type `PStep x a` has no slot for it and the destrAnno projection
(`getMonoPathType`, Fix A) returns ⊤ — `destranno|top|top` 14,135, the same number as before. It
then flows into the re-wrapping CONSTRUCTION's payload slot as `LTop clsDestr`, which (a) is the
⊤ contributor that closes `settleVarCtorRows`' gate on every `Cerr`/`Eerr` cell, and (b) lands in
non-ctor demands (`toErr a2`, `composeL a1`) that the post-drain ⊤-heal (`settleCtorRows`, ctor
entries only) never touches — the 250 `top@clsDestr` artefact positions. Consumer weight: the
value is called once per parse FAILURE (`Err (toError row col)`, `inContext`) — cold. This is a
completeness fix, not a dispatch fix; it is also exactly the container-payload identity this plan
was opened for, at the one edge (E13) where the paper's `PStep[l] x a` set variable has no Eco
counterpart.

#### 12.9.3 The local-multi join (F2's two P0 questions)

RHS shapes at the let (1,036 `pushLocalMulti`): `fnWithId` 654 (arity 1: 264, 2: 297, 3: 73,
4: 17, 5: 3), `tailDef` 122 (no `SrcLambdaId` — `TOpt.TailDef` has none), other 96 (`call` 82 =
a PAP `f = g x`, plus access/if/let/record/case/ref). **Use sites** (a local-multi passed as an
argument, 476 events): `fnWithId` 370 (78 %), `noId` 106; **ordinal 0: 473 (99.4 %)**, ordinal
1: 3. RHS head member at the re-translation: `mid` 739, `top` 16, multi-member 6, non-fn 2.

Join over (def, ordinal): 516 pairs; 203 seen on BOTH sides; 178 of those (88 %) have exactly
ONE head id across every re-translation of that (def, ord). The 19 defs with several ids are
all per-SPEC qualification (`Array.foldl.helper`: 83 uses, 75 ids, and `prod5-out.mlir` has 85
`Array_foldl` specs) — the census key lacks the spec id, the mint does not. The 16 defs where
one id serves several ordinals are all non-lambda heads (PAP/reference members, instance-blind
by design; `copyExpr.withMeta` ord 0-15 = one `p|` id), none of which F2 injects.

So both P0 answers are YES: the RHS `SrcLambdaId` is reachable at the use (`entry.rhsLam`, in the
`localMulti` stack entry the use already consults), and the ordinal is known at the use
(`recordLocalInstance` assigns it from `specMapSize`; `buildLocalDefs` indexes the same `SpecMap`
in insertion order — the join confirms they agree: 203 both-sided pairs, 1 use-only).

#### 12.9.4 F2 — IMPLEMENTATION-READY: use-site member injection (design (i))

**Mechanism.** At a `StashLocalMulti` use, after the instance is recorded, mint the id the RHS
re-translation WILL mint for that instance and write it into the spine of the stashed var. The
var is already unified with the callee's param slot (`freshVar0`/`pParam`, Translate.elm:3892),
and the write lands BEFORE the callee is zonked and enqueued (`translateArgsWith` at 2063/3394
precedes `Store.zonkToMono funcVar` at 2078/3413), so the callee's DEMAND carries the singleton.
No ordering problem, no fresh-store problem, no drain-flush: the RHS type is never needed — only
its identity, which is a function of the source.

**Why the id agrees.** `LssInfer.injectLambdaMemberQualified` → `Engine.lambdaInstanceMemberId
raw` is deterministic in (raw lambda id, `itemAux.currentLocalInstance`, `currentSpecId`,
`lssMemberTable.specWidenedKeys`, `itemAux.demandQualified`, `rootLamOf`) — the last four are
item-static; interning is get-or-create by key (`lambdaMemberLayoutQualified`: "mint and lookup
cannot disagree"). The RHS mint runs under `retranslateWithTag (localInstanceTagFor ord)` with
the same spec id (`clearedAux` keeps it). Reproducing the tag at the use site reproduces the id.
Ordinal 0 (99.4 % of uses) is never tagged (`localInstanceTagFor 0` = the enclosing tag).

**Code, exactly.**
1. `Engine.NumberMultiEntry` KEEPS the v4 field `rhsLam : Maybe ( TypeIds.SrcLambdaId, Int )`
   (lambda id, arity); `pushLocalMulti` keeps its `Maybe` argument;
   `translateLocalMultiLet` (Translate.elm:7248) passes `rhsLamOf defBody` (keep `rhsLamOf`,
   drop `rhsShape`/`bumpLm`).
2. `Engine.recordLocalInstance` returns the ordinal: `Step ( String, Mono.MonoType, Int )` — from
   `recordMultiInstance`'s `idx` (existing instance: its index in `specMapValues`), dropping the
   `$`-suffix parse the instrument used.
3. `translateArgsWith`, `StashLocalMulti v` arm (Translate.elm:4031-4045): after
   `recordLocalInstance` yields `( freshName, instType, ord )`, when `stamp.enabled &&
   stamp.useInject` and the stack entry for `localName` has `rhsLam = Just ( lam, arity )`:
   `tag ← Engine.localInstanceTagFor ord`; set `itemAux.currentLocalInstance = tag`;
   `LssInfer.injectLambdaMemberQualified arity (Just lam) v`; restore
   `currentLocalInstance`. Return `MonoVarLocal freshName instType` unchanged (the AST overlay
   `flushLocalMultiEnrich` later replaces the annotation with `typeOf rhs`, which carries the same
   id from `classifyLambdaHead`'s own injection). Record FIRST, inject SECOND: the instance key
   stays the demand-side type, so two uses at one type get one ordinal and one id; injecting
   first would make the key depend on the ordinal for ord ≥ 1.
4. `injectSpineMemberId` is bounded by `arity` (LSS_013) — for `\a b -> \c -> …` only the two
   own arrows are written; the returned closure's arrow stays whatever its flow says.
5. **F2.b, the self-reference sub-class (258 flex):** during `retranslateAtInstance`, a
   `VarLocal` reference to the def being re-translated has no `varEnv` binding
   (`enrich|unbound`). Set `itemAux.retranslating = Just ( name, lam, arity )` for the duration
   of `retranslateWithTag` (`ItemAux` has a free slot once `varKind` goes) and, in
   `argUnifyVar`'s `injectArgLambdaMember` path, when `accessedLocalName arg == Just name`, inject
   `injectLambdaMemberQualified arity (Just lam) canVar` — the tag is ALREADY the instance's own
   (that is what `retranslateWithTag` sets), so the id is the same one.
6. Flag: `LssConfig` is at the 32-field cap — add `useInject : Bool` to `LssStampConfig` (5
   fields), env `ECO_MONO_LSS_INSTANCE_QUAL_USE_INJECT`, JSON `instanceQualUseInject`, hash
   token `lssIU=1`, default OFF for the A/B, then ON.

**Hazards, each with its answer.** LSS_038 (one id, two bodies): only lambda-RHS defs are
injected, and for those the id is instance-qualified for ord ≥ 1 and shared for ord 0 exactly as
today's re-translation makes it — F2 adds no id the RHS would not mint; the existing
`declinedBodyMismatch` fence stays. The cap (`maxInstances` 8): `localInstanceTagFor` returns
the enclosing tag past it for BOTH sides — still equal. μ-tie: `recordMuTied` at the use
precedes the RHS's; recording is idempotent. Conflict manufacture: the write is a total join into
a slot that is flex in 866/874 cases; a ⊤ there stays ⊤.

**Pre-registered predictions (A/B on the v3 instrument, flag off vs on).** `localMulti` unwritten
positions 866 → ≤ 250: 370 fnWithId heads become `mem` plus their within-arity spines (213×1 +
14×2 + 2×2 + 1×3 = 248 interior positions) ≈ 618; F2.b adds the 258 `local:letMulti`. Residual
= the 106 `noId` heads (tail-defs and PAP RHSs) and beyond-arity `/r` positions. Second order:
`local:param` flex (1,024) falls where its chain root was one of these (the `JsArray.foldl` /
`List.foldl` / `Dict.foldl` cells); `var` 1,380 drops by a few hundred POSITIONS (events ≠
positions — do not equate). Emission changes (stored demands gain members).

**Gates.** (1) flag-off byte-identical `out.mlir` and identical `coverage:`; (2) new unit test
`LssLocalMultiUseInjectTest`: a let-bound lambda used as a callback at two instance types →
both callee specs' param annotations are `k1` and EQUAL to the two instance closures'
`lssMember` ids (the join, pinned); (3) `elm-tests`; (4) E2E `--target full` both arms; (5)
bootstrap fixed point (Stage 8c); (6) `benchmarks/call-stats.md` pair — the fold callbacks this
names are the hot `arityOver` family, so dispatch may move.

**BUILT (2026-09-15) — and the unit pin found a second defect.** `LssLocalMultiUseInjectTest`
(5 pins: flag-off no set / flag-on join at two instances / distinct ids / F2.b self-reference /
its flag-off) first FAILED the join: use-site ids 3 and 6, both instance closures' `lssMember`
**9 = the ENCLOSING GLOBAL's ground id**. Cause: `retranslateWithTag` re-translates the instance
RHS through `demandUnifyRoot`, which stashes `lssRootAnn` for a lambda RHS; `classifyLambdaHead`
then treats the LOCAL lambda as the def's root and `rootFold` (a) folds its key onto
`g|<enclosing global>` — an id that names a DIFFERENT value (`SourceGlobal` registered for a
CAF/tuple) — and (b) `instanceQualTagFor` drops the instance tag for root-folded lambdas, so
every instance of a lambda-RHS let-function shares one id. That is the LSS_038 collapse, LIVE
for the common shape (654 of 1,036 RHSs are lambdas), and it is what the v4 join's "16 defs, one
id, several ordinals" (`copyExpr.withMeta` ord 0-15) actually were — misread in §12.9.3 as PAP
heads. Fix, gated with `useInject` for the A/B: `classifyLambdaHead` skips the fold when
`itemAux.retranslating /= Nothing` (`rootFold|localSkip`). With it: 24/24 (this suite +
`LssInstanceQualTest`, `LssLocalMultiEnrichTest`, `LssRootFoldTest`). Shipped pieces:
`LssStampConfig.useInject` (env `ECO_MONO_LSS_INSTANCE_QUAL_USE_INJECT`, JSON
`instanceQualUseInject`, token `lssIU=`, default OFF pending the A/B); `NumberInstance.ordinal`;
`recordLocalInstance` returns the ordinal; `ItemAux.retranslating`;
`Translate.injectLocalMultiUseMember` (the use-site write), `injectRetranslatingSelf` (F2.b, a
`VarLocal` arm in `injectArgLambdaMemberGo`); `retranslateAtInstance` takes the def name.

**A/B MEASURED (2026-09-15, self-compile, one emit of the F2 tree, two arms of the lowered
compiler under the v3 census; artefacts `bin/f2ab-2026-09-15-{off,on}.*`). The pre-registered
predictions held to the number.**

| | `useInject=0` | **`useInject=1`** | Δ | predicted |
|---|---:|---:|---:|---|
| `lmInject\|use` / `\|self` / `\|noLam` | — | **370 / 132 / 106** | | 370 / 132 (258 positions) / 106 |
| `localMulti` unwritten positions | 866 | **254** | −612 (−71 %) | ≤ 250 |
| `local:letMulti` (self-reference) flex | 258 | **0** | −258 | 258 → 0 |
| `local:param` flex (the chain) | 1,024 | **454** | −570 | "falls, unquantified" |
| ALL unwritten argument positions (v3) | 2,726 | **1,281** | **−53 %** | |
| `var` (artefact positions) | 1,380 | **873** | **−507 (−36.7 %)** | "a few hundred" |
| `⊤` | 938 | **697** | −241 (`abi` 250 → 6) | not predicted |
| `k1` / `kN` | 114,257 / 33,790 | 115,112 / 33,845 | +855 / +55 | |
| positions | 150,397 | 150,559 | +162 (keyed specs gained) | |
| **analysis coverage** | 98.44 % | **98.94 %** | **+0.50 pp** | |
| `rootFold\|folded` / `\|localSkip` | 49,378 / — | 48,010 / 712 | | |
| wall / RSS | 8:55.6 / 15.01 GB | 9:01.7 / 15.04 GB | flat | |

The ⊤ drop was not predicted and is the root-fold misfire's other cost: 244 of the 250 `abi` ⊤
were manufactured by folded local ids (a `g|<enclosing>` id whose layout is the enclosing def's,
joined against the instance's) — gone with the skip. Residual `localMulti` 254 = the 106 `noLam`
heads (tail-def and PAP RHSs: `Dict.foldl a0` 38×3 positions, `List.map a0` 17) plus their
spines and 20 container positions. **Default flipped ON** (`stamp = { … useInject = True }`).
Gates (2026-09-16, with F3-b/F3-a in the tree flag-off): full `elm-tests` 13,556 pass / the standing 12
POST_010 only; E2E `--target full` **PASS (1727/1727, exit 0)**. Still owed: bootstrap 8c and the
call-stats pair (deferred by the user).

#### 12.9.5 F3 — IMPLEMENTATION-READY: (a) row-deferred payload sets at destructures, (b) store overlay for let/tail-fn bindings

**F3-a — the destructure class (`clsDestr` 250 positions / 2,481 events).** A translation-time
read of the ctor row is UNSOUND (the fixture that moved Fix B to the settle: a set stamped from
a partial union excludes later constructions), and ⊤ is what closes the settle's own gate. The
paper's answer is a set VARIABLE in the scrutinee's type; Eco's MonoType cannot carry one for a
syntactic payload arrow, so carry a DEFERRED REFERENCE to the row instead — the LPartial
precedent (§ "paper's Q-accumulation", one producer, resolved by the post-drain settle):

- **Annotation:** `LambdaSetAnno` gains `LRow Int Int (List Int)` = (ctor global key, payload
  index, members so far) meaning "⊇ members ∪ row(ctor, index, this sub-path)". In-store
  twin `LambdaSet.LsRow` with the same payload; `zonkSetSlot` maps one to the other;
  `Store.unifySlotWithSet` join rules and `Mono.unionAnno` rules (LSS_010 law: `annoCovers a b
  ⇔ unionAnno a b == a` — extend both together, pin in `LssLPartialTest`, which holds the law today):
  `LRow c i m ⊔ LSet n = LRow c i (m ∪ n)`; `LRow c i m ⊔ LRow c i n = LRow c i (m ∪ n)`;
  `LRow c i _ ⊔ LRow c' i' _` (different rows) `= LTop tkRow` (counted); `LRow ⊔ LTop k = LTop k`;
  `LRow ⊔ LVar = LPartial` (same rule as `LSet ⊔ LVar`; the var half is unevidenced). `LRow` is
  NOT ⊤ (`isTopAnno`/`hasTopAnno` false) and NOT covered (`annoCoverage` counts it in a new
  `row` bucket until resolved); it is never a singleton; `headAnno` reports it as multi.
  Spec keys are annotation-sensitive already — `LRow` keys as itself.
- **Producer (one site):** `specializeDestructor` (Translate.elm:8305-8350). After Fix A's
  projection enrich, for every arrow of the binding type still `LTop clsDestr` whose path is a
  syntactic payload (the innermost `MonoIndex i (CustomContainer ctor) …` / `MonoUnbox` segment
  of `monoPath`), replace it with `LRow ctorKey i []`. Type-argument-borne arrows (a `Maybe (a ->
  b)` payload) are NOT payload-syntactic and keep Fix A's answer. `Mono.enrichAnnotations` must
  treat `LRow` as a set-like operand (sets union into it; it never absorbs ⊤).
- **Resolver (post-drain):** extend `Monomorphize.settleCtorRows`. It already builds per-ctor
  cells; use `settleVarCtorRows`' PATH-keyed cells (ctor global, `/a<i>` ++ sub-path) over ALL
  sibling specs. Iterate to a fixpoint (rows reference rows through re-wraps — finite lattice,
  unions monotone, ⊤ absorbing): a cell whose contributors are sets / `LRow`s of the SAME cell
  (self-reference contributes nothing) / vars resolves to `LSet (m ∪ cell)`; a cell with a ⊤
  contributor or an `LRow` of another cell that resolved ⊤ resolves to `LTop tkRow`. Rewrite
  every registry position carrying `LRow` (ctor AND non-ctor entries — `toErr a2`,
  `composeL a1`) with `Registry.updateRegistryType`, exactly as the heal does. Order: this
  resolution runs BEFORE `settleVarCtorRows` (the ⊤ contributors it removes are the ones that
  gate closes on), which keeps "var writes read ⊤ contamination HONESTLY" true.
- **Consumers:** none change. AbiCloning reads registry types; an `LRow` that survives (a
  resolver miss) is neither ⊤ nor a set at every reader — add it to the `never-singleton` guards
  next to `LPartial` (`papResolve`, `matchSpec`, `devirt`) so an unresolved one can never stamp.

**F3-b — the let / tail-fn class (`clsLet` 180 positions; `leak|letAnno` 58, `local:let` 60,
`tailFn` 40 events).** The top-level `TailDef` already does the right thing
(Translate.elm:1467-1500: zonk the demand-seeded var, `overlayAnnotations classified zonked`,
peel params). Apply the same two-line overlay at the local sites: plain let (6221: `defType =
Mono.overlayAnnotations defMonoType0 bodyType` whenever `eqLayout` holds, replacing the
`useBodyType` either/or that leaks the annotation — `leak|letAnno`), the number-multi eager path
(6404) and the local tail-def (6283: overlay the classify with the zonk of its `demandUnify`'d
var, as 1486 does). Structure stays the classify's (the ABI guard in the 1486 comment applies).

**Pre-registered predictions.** F3-a: `top@clsDestr` 250 → ≤ 30; `destranno|top|top` 14,135 →
≤ 1,000 (the projection still misses; the producer now converts the miss); the `Cerr`/`Eerr`
field-2 cells resolve to `kN` (every error constructor ever wrapped — coarse, honest; the
paper's per-value precision needs the set variable in the type). Second order: with the ⊤
contributor gone, `settleVarCtorRows` opens on the Parse ctor cells — some of the remaining
`var` is there (unquantified). F3-b: `top@clsLet` 180 → ≤ 100; `leak|letAnno` 58 → 0. Coverage:
F3 is ~430 of 150,264 positions, ≤ +0.3 pp — build it for completeness, not for the number.

**Gates.** (1) `LssLPartialTest` extended for `LRow` (LSS_010 law, every pair of variants); (2)
unit fixture: a `Parser`-shaped re-wrap in one module with two constructions of the ctor →
the destructured payload resolves to the 2-set, and a fixture with a ⊤ construction → resolves
⊤ (the `destrAnno` fixture pattern: "ctorExpr not varExpr; tVar; multi-ctor + phantom var");
(3) flag-off byte-identical; (4) `elm-tests`; (5) E2E; (6) bootstrap 8c.

**F3-b BUILT (2026-09-15).** `LssFlowConfig { connect, letOverlay }` — `flowConnect` moved into
the sub-record (JSON key, env and `lssFC` token unchanged; `LssConfig` is at cap); `letOverlay`
env `ECO_MONO_LSS_FLOW_LET_OVERLAY`, JSON `flowLetOverlay`, token `lssFLO=`, default OFF pending
the A/B. Plain let: `defType = overlayAnnotations defMonoType0 bodyType` when the classify wins
(`leak|letAnno` reads 0 by construction flag-on). Local tail-def: the single-instance
`demandUnify` now hands its seeded var on and `tailDefBindingTypes` zonks it — classify for
structure, zonk for annotations, params peeled from the overlaid function type (the top-level
`TailDef` recipe). Pins `LssLetOverlayTest` (4): the tail-def differential is clean (⊤ off, set
on); the plain-let differential is `clsLet` ⊤ → the RHS's annotation, because **a one-module
fixture cannot put a SET on a tuple payload arrow at all** — a tuple LITERAL types its arrow
`LVar` and takes the body type in both arms, and a CALL RHS reads the callee's registered result,
whose payload arrow is a `declZonk` ⊤ manufactured inside the callee (`mkPair n = ( \x -> x + n,
n )` registers `Int -> ( Int ->⊤declZonk Int, Int )`). Both are E14 (F4, unbuilt): the
literal-field edge is the upstream of F3-b's let half and caps what it can yield on the corpus.
Unit: 7/7 with `LssFlowEdgeLossTest`. A/B: `$SP/f3b-ab.sh` → `bin/f3b-{off,on}-out.mlir`.

**F3-b A/B MEASURED (2026-09-15; artefacts `bin/f3bab-2026-09-15-{off,on}.*`; F2 default-on in
both arms).** `leak|letAnno` 58 → **0**; `letOverlay|tailFn` 122; `clsLet` ⊤ 180 → **70**; total ⊤
697 → **664** (−33; `clsDestr` 250 → 327 is a RELABEL — a let bound to a destructured local now
carries the RHS's `clsDestr` ⊤ instead of its own `clsLet` one, same position); `var` 873 → **932**
(+59: the RHS annotations the overlay copies are mostly never-written vars — `local:tailFn` ⊤ 40 →
flex 40, `local:param` flex 454 → 528); k1 +14, kN +36; **coverage 98.94 % → 98.92 % (flat)**;
wall 9:06 → 8:59, RSS flat. Verdict: F3-b removes a ⊤ MANUFACTURER (110 `clsLet` positions no
longer stamp ⊤ where the RHS knew better or knew nothing) but converts most of them to honest
vars, which coverage counts the same. It earns its place as the precondition for F4 (a literal
field written later can fill a var, never a ⊤) and for F3-a's let-bound destructures, not on the
number. **Left DEFAULT-OFF** pending the user's call; flip = one literal in `defaultLss.flow`.

**F3-a BUILT (2026-09-15).** `LambdaSetAnno.LRow (List Int) (List Int)` (row ids, members) with
its in-store twin `Vars.LambdaSet.LsRow`; row id = the interned member-table key
`r|<ctor>|<path>` (path in the constructor's CURRIED shape: payload i at `/r`×i ++ `/a0`, then
`settleVarCtorRows`' grammar inside — the resolver's cell key). Producer `Translate.rowifyPayload`
at `specializeDestructor`, after Fix A's projection: every ⊤ arrow of a binding whose path's last
step is `MonoIndex i (CustomContainer ctor)` or the single-ctor `MonoUnbox` becomes
`LRow [row] []`. Lattice: `unionAnno`/`annoCovers` (exact, LSS_010), `enrichAnno`, `annoHash`,
`annoKeyEq`, `toComparableFragments` (`Ar[rows|members](`, keys as itself), `collectAnnoGo`,
`hasVarAnno` (var-like for the gates), `annoCoverage.row`; store: `Unify` two-slot join (rows ∪,
members ∪; row × edge → ⊤ edge), `unifySlotWithSetC`, `zonkSetSlot`, `monoTypeToVarC`. Resolver
`Monomorphize.settleRowRefs`, FIRST in the settle chain: path-keyed cells over every ctor-global
registry entry (⊤/partial/marked-var contaminate; sets union; `LRow` contributes members and
DEPENDENCIES), least fixpoint over the row graph, then every registry `LRow` → `LSet` or `topRow`
(`tkRow` 21; `rowDefer|resolved/top/empty/noCell` counters). Guards: AbiCloning devirt,
MapTemplate ×3, Borrow `LssFacts` — `LRow` declines like `LPartial`. Flag `flow.rowDefer` (env
`ECO_MONO_LSS_FLOW_ROW_DEFER`, JSON `flowRowDefer`, token `lssFRD=`, default OFF pending the A/B).
Pins `LssRowDeferTest` (4): flag-off the HOF fed the destructured payload reads ⊤; flag-on it reads
the COMPLETE 2-member union of the constructor's row; no `LRow` survives in the registry; the
re-wrap construction's payload is a set. 29/29 with the six neighbouring LSS suites (every
test's exhaustive annotation match gained an `LRow` arm). A/B: `$SP/f3a-ab.sh` →
`bin/f3a-{off,on}-out.mlir`.

**F3-a A/B MEASURED (2026-09-15; artefacts `bin/f3aab-2026-09-15-{off,on}.*`; F2 on, F3-b off in
both arms).** Producer: `rowDefer|minted` **13,984** row references; the `local:destr` argument
class ⊤ 2,481 → **24** (2,457 now `row`); `rowDefer|notPayload` 103 (tuple/list/record paths —
Fix A's domain). Resolver: **57 rows**; `resolved` 25, `top` **646**, `empty` 0, `noCell` 0.
Artefact: `clsDestr` ⊤ 250 → 141, new `row` ⊤ **118**, total ⊤ 699 → 708; k1 +21, kN +55; `var`
873 unchanged; coverage 98.937 % → 98.939 % (**flat**); wall 9:00 both, RSS flat. Verdict: the
mechanism is complete and correct (the unit pin resolves a clean row to the exact 2-set; on the
corpus every mint reaches the resolver and no row is missing a cell), but the `Cerr`/`Eerr`
cells it resolves are CONTAMINATED — the same constructors are also built at sites whose payload
argument is a still-flex parameter (`local:param` flex 454, the chain F2 left: lambda bodies
returning unknowns 356, tail-def/PAP local-multi RHSs 254) and a marked-var contributor makes
the complete union unknowable (AR-D2, the `settleVarCtorRows` rule). The rows will flip to sets
by themselves as those roots are repaired — the resolver reads the complete union each time.
**Left DEFAULT-OFF** (coverage-flat); flip = one literal. Next diagnostic when wanted: a per-row
`rowDefer|why|<ctor>|<path>|top/markedVar/dep` counter names the contaminating construction
sites (57 rows — one census run).

**PER-ROW DIAGNOSTIC (2026-09-16, `rowDefer|why`, one arm; artefact `bin/rowwhy-2026-09-16.txt`).**
One census key per row naming what blocked it. Analysis-neutral (`var` 873, `top` 708, `row` 0 as
before). **46 of the 57 rows RESOLVE**, several to large honest unions — `Parser;/a0` 1,036 members,
`RResult;/a0` 324, `Tracker;/a0` 144, `Chomper;/a0` 77, `Extractor;/a0` 37. The 11 that do not:

| row | blocked by | contributors: known / var / ⊤ |
|---|---|---|
| `Cerr;/r/r/a0` (+`/r`) | `markedVar` | 308 / **8** / 0 |
| `Eerr;/r/r/a0` (+`/r`) | `markedVar` | 363 / **11** / 0 |
| `Decoder;/a0` (+`/r`) | `top:poison` | 2,009 / 3 / kernel ⊤ (F5) |
| `Ok;/a0` | `top:clsDestr` | 241 / 0 / **1** |
| `Parser;/a0/r/r/t2/c1` (+`/r`) | `top:clsDestr,clsLet` | 101 / 0 / **6** |
| `ChomperOk;/r/r/a0` | `markedVar` | 31 / **2** / 0 |
| `Ok;/a0/l/t1` | `markedVar` | 0 / 1 / 0 |

**Every blocked row is blocked by under 4 % of its own contributors** — 38 contaminating specs out
of ~5,500. AR-D2 is doing exactly what it promises (one unknown inhabitant voids a completeness
claim), and the census now names the 38. By class: 6 rows on flex-parameter constructions
(`markedVar` — the `local:param` 454 chain, e.g. `Eerr s.row s.col toError` where `toError` is the
enclosing function's parameter), 3 on `clsDestr` ⊤ from destructure paths `rowifyPayload` does not
reach (`rowDefer|notPayload` 103 — tuple/list/record projections INSIDE a payload), 1 on a `clsLet`
⊤ (**F3-b's target — flipping `letOverlay` on should unblock `Parser;/a0/r/r/t2/c1`**), 2 on kernel
poison (F5, out of scope here).

**And the prize is small, which the diagnostic also settles.** Of the 646 positions that resolve ⊤,
only **118** survive as `top@row` in the final registry — `settleCtorRows`' ⊤-heal (which is not
gated on var contamination) fills the rest afterwards. So finishing F3-a is worth ~118 positions
plus the ~141 `clsDestr` that `rowifyPayload` never reaches: **≈ 0.17 pp**, against §12.9.5's ≈ 0.3 pp
estimate. The mechanism is sound and the rows self-heal as their roots are repaired; it does not
justify chasing the 38 specs on its own.

*Design note, unbuilt:* a contaminated row could resolve to `LPartial (known union)` instead of
`topRow` — sound (a lower bound is exactly what a var contributor leaves), strictly more
information than ⊤, and every consumer already declines `LPartial`. It moves positions from `top`
to `part`, so it buys nothing under the coverage metric, but it is the honest answer and the
paper's Q-accumulation shape.

*Gate gap:* E2E has only been run with `rowDefer` OFF. The flag-on self-compile produces a sane
artefact (`bin/why-out.mlir`, 13,499,532 B) and no `LRow` reaches emission, but `settleRowRefs`
rewrites REGISTRY types only — an `LRow` left on an AST expression/destructor type stays `LRow`
(guarded identically to ⊤ at every consumer, hence sound). Flipping the default on needs an E2E
arm and, for the mints to pay off at call sites rather than only at the 671 registry positions,
an AST-side rewrite.

**F3-a COMPLETED (2026-09-16), and it is measurably INERT on this corpus.** The three gaps §12.9.5
listed are closed; artefacts `bin/f3c-2026-09-16-{off,on}.*`.

  - **AST-side resolution (the big one).** `settleRowRefs` now rewrites the NODE array as well as
    the registry: one linear `Array.foldl`, each node guarded by the allocation-free
    `Traverse.anyNodeType` probe and rebuilt through `Traverse.mapNodeTypes` only when it carries a
    row (deliberately NOT a per-item `traverseExpr` — that shape is the Sep-4 regression).
    **3,778 nodes rewritten**, so the destructor and expression types that hold the other ~13,300
    of the 13,997 mints now resolve instead of surviving as inert-but-sound `LRow`.
  - **Nested payload anchors.** `payloadRowPrefix` walks down to the NEAREST enclosing constructor
    payload, accumulating the projections it passes as path segments (`/t<i>`, `/l`, `/f:<name>`),
    so `Mk (a, f)` anchors at `Mk|/r/r/a0/t1`. `rowDefer|notPayload` 103 -> **90**; the 90 that
    remain have no enclosing constructor payload at all (tuple/record/list roots), an unnameable
    `CustomContainer ""` array index, or a multi-constructor `MonoUnbox` — by construction, not by
    omission.
  - **Contaminated rows keep resolving to `topRow`, not `LPartial`** (§12.9.5's design note,
    now DECIDED and recorded at the code): `settleCtorRows`' ⊤-heal runs after this pass and is
    gated on `hasTopAnno`, so a lower bound would FORFEIT the heal that currently fills 528 of the
    646 ⊤-resolutions. Partial would cost 528 positions to buy nothing the metric counts.

**The A/B (same run, `rowDefer` off vs on).** `var` 893 both arms; `⊤` 699 -> 708; `clsDestr` 250 ->
141 with `row` 118; **coverage 98.92 % both arms (`coveredBp` 9892 = 9892)**; `devirtDirect` 4,560 and
`devirtKernel` 1,138 IDENTICAL, `stampwalk` identical to the field; emission +105 B; wall 9:11 vs
9:10, RSS flat. So the completed mechanism changes neither the coverage book nor a single
devirtualization decision.

**And the §12.9.5 diagnostic's own hypothesis is refuted.** I attributed 3 of the 11 blocked rows to
`clsDestr` ⊤ arriving from the 103 non-payload destructure paths; anchoring those (13 of the 103 had
an enclosing payload) left the blocked set BIT-IDENTICAL — same 11 rows, same reasons, `resolved` 25
and `top` 646 unchanged. Those `clsDestr` contributors come from somewhere else, unmeasured. What
remains true is the shape of the result: 46 of 57 rows resolve, and the 11 that do not are blocked
by <4 % of their contributors, which belong to the flex-parameter chain (6 rows), an unlocated
`clsDestr` source (3), and kernel poison (2, F5).

**Verdict.** F3-a is complete, sound, pinned (`LssRowDeferTest` 6/6 — the AST sweep and the nested
anchor each have a differential pin), unit-green (13,558 / standing 12) and DEFAULT-OFF, where it
costs nothing. It buys nothing today either: its rows resolve to unions the ⊤-heal already
produces, and the positions it could uniquely recover are gated behind roots it does not own. It
stays in the tree as the mechanism that converts those roots into coverage the moment they are
repaired — not as a fix that pays now.

#### 12.9.6 Order, and what §12.5 now reads

**F2 → re-read (v3/v4 census) → F3-b → F3-a → F4 → F5.** F2 first: it is the largest
mechanism (32 % of the residual), one site, a keep-what-v4-built change, and its A/B doubles as
the re-read that sizes the `local:param` chain. F3-b is two overlays with a precedent. F3-a is
the one real design (new annotation variant + resolver) and is deliberately last of the three:
its population is cold and its yield is ~250 positions. §12.8's "build neither" is lifted for
both; its "F2 design infeasible" applied to §10.5's store write-back, which is now replaced by
(i). The v4 instrument's `rhsLam` / ordinal plumbing is F2's production code; everything else in
the v3/v4 instrument (`StashCensus`, `varKind`, `lm*` counters) is census-only and comes out.


### 12.10 F3-b + F4 PREPARED TOGETHER (2026-09-16) — F4 re-scoped by measurement

**F4 as §10.5 wrote it — "literal field write-back (E14)" — measures out.** Two census runs
(`bin/f4census-2026-09-16-{f4c,f4d}.txt`; instrument: `Translate.litCensus` at every
record/tuple/list literal, `LssInfer.walkFunction`'s result-join census, `enrichFromEnv`'s
access-argument counter — all report-gated, TEMPORARY) and one unit probe
(`$SP/LssRecordChainProbe.elm`, parked outside the test tree because it reports by failing):

| literal elements whose translated type is an arrow | events | element knows | literal's OWN store type knows |
|---|---:|---|---|
| record fields | 77 | k1 70, kN 1, ⊤ 4, var 2 | k1 70, kN 1, var 6 |
| tuple slots | 39 | k1 37, kN 1, var 1 | k1 37, kN 1, var 1 |
| list elements | 13 | k1 13 | k1 13 |

129 arrow-typed literal elements in the whole self-compile, and the literal's loaded store type
already carries 120 of them as sets (`connectRecordFields`/`connectSlots` + per-`ArrowId` memo do
the within-item transport). The literal edge itself is worth ~7 var + 4 ⊤ positions. **Closed as a
fix.** What survives of it is one soundness note (F4-lit-list below).

**Where the container-interior positions actually come from — three located losses.** The
artefact's container-interior book (current defaults, F2 on): `var` 388 of 893 inside containers
(`/f:` 270, `/c` 63, `/l` 39, `/t` 16); ⊤ `clsLet` 160 of 181 and `clsDestr` 152 of 250 inside
containers; `clsMisc` 40. The probe splits the record-field class cleanly: a callback delivered
to a parameter and passed on directly reads `k1` at every hop (`build.a0`, `useF.a0`,
`cbDirect.a0` = `LSet[11]`); the SAME callback read through a record field reads `LVar` at the
consumer in every arm. Chasing the corpus chain (`emitFusedEncoder|a0 …|localMulti|flex`,
`exprCompiler = bfExprCompiler (…)`, `emitWidthExpr state.compileExpr …`) lands on:

  1. **E15 — a record-field ACCESS as CALLEE or ARGUMENT transports nothing.** `enrichFromEnv`
     handles `VarLocal` and tuple literals of locals; for `TOpt.Access` it enriches nothing, so
     `state.compileExpr expr ctx` (the callee path, `translateIndirectCall`:2225 — 16 such sites
     in `BytesFusion/Emit.elm` alone) dispatches generically and `emitWidthExpr state.compileExpr`
     (the argument path) hands the callee a var. Census: **885 arrow-carrying access events**
     (`ofExpr` 785 — the record is itself an access/call, `ofLocal` 100), of which 30 are
     argument positions (`access` form, all flex); the rest are callees. The probe pins it:
     `apply.a0 = LVar` for `apply r.f n` in every arm.
  2. **F2.c — a local-multi whose RHS is a PARTIAL APPLICATION of a global.** F2's `noLam`
     residual (`lm|rhs|other:call` **82 lets**, 106 use events, `localMulti` unwritten 254 after
     F2). This is the ROOT of the compileExpr chain (`exprCompiler = bfExprCompiler
     (fusedLetsFromChain …)`, arity 3 applied to 1) and of the `Dict.foldl a0` 38×3 residual.
  3. **F4-sig — the signature walk returns `WpNone` for every literal.** `LssInfer.walkExpr` has
     no `Record`/`TrackedRecord`/`Tuple`/`List`/`Update` arm ("containers, literals … the value's
     inhabitants are untracked"), so `walkFunction` never joins a literal body into the def's
     result slot and the `Let` arm's `sigFlowJoinInto rhsVar Nothing` skips a let-bound literal.
     Callers then read var at every container-interior result arrow. Census: `walk|noJoin|*|arrow`
     **20 def bodies** (update 14, tuple 4, if 1 …; `join` 5,820, `noJoin|plain` 5,905) plus the
     let-bound chains the counter cannot see. The probe pins it: `mk cb = { f = cb, n = 1 }` →
     `mk.result.f = LPartial[7]` in the registry (the body's set ⊔ the caller's var) and
     `useRec.f = LVar`.

Two small ones from the same reading: **F4-acc-node** — `refineAccessType` keeps the storeless
`clsMisc` ⊤ of an access node unless the classified type has an MVar or is a narrowed record
(`top@clsMisc` 40 positions, 39 spine); **F4-lit-list** — a list literal's type is
`classifyAs tkClassMisc` (⊤) for a ground element type and `mList (typeOf FIRST)` otherwise — a
first-element-only set is a completeness claim the other elements can falsify (the If arm's
`joinBranchTypes` is the precedent). The probe's own let-bound shape (a record literal carrying a
generalized `number` var routes to local-multi, RHS form `record`) is `lm|rhs|other:record` = 2
lets on the corpus — noted, not fixed.

#### 12.10.1 Lowerings

**F2.c — use-site PAP member (extends `injectLocalMultiUseMember`).** `NumberMultiEntry.rhsLam`
becomes `rhsIdentity : RhsIdentity = RhsLambda SrcLambdaId Int | RhsPap TOpt.Global Int |
RhsOther`, filled by `rhsLamOf` from the RHS syntax: `TOpt.Call _ (TOpt.VarGlobal _ g _) args _`
with `List.length args < LssInfer.declaredArityOf g 8 s` is `RhsPap g (List.length args)`. At the
`StashLocalMulti` consumer, `RhsPap g k` → `Engine.papMemberIdFor g k` →
`LssInfer.injectSpineMemberId 1 mid v` — HEAD-ONLY, the `p|` law ("one arrow deeper is a
DIFFERENT PAP"). Id agreement is by key: the RHS re-translation's `injectPapMember` mints
`papMemberKey g k` = `p|<g>|<k>`, instance-blind by design, so ordinal and tag play no part.
Consumers: `papResolve` already stamps `p|g|k` singletons (saturating extensions) and
`papFast` fast-stamps the rest. Flag `stamp.useInjectPap` (own A/B; `useInject` stays on).
Predictions: `lmInject|pap` ≈ 82-site share of the 106 `noId` uses; `localMulti` unwritten 254 →
≤ 130 (tail-def RHSs remain); `emitFusedEncoder/Decoder|a0` → `k1:p`; the `local:param` chain
below them falls; `Dict.foldl a0` 38 → 0. Pin: `let g = apply2 cb in useF g` — `useF.a0` is the
`p|apply2|1` singleton flag-on, var flag-off.

**E15 — access-form callee and argument write-back (`flow.accessFlow`).**
  - `enrichFromEnv` gains an `Access record _ field _` arm for `ofLocal`: `lookupVar` the record
    local, project the field from its `MRecord`, `monoTypeToVar` it, `unifyStepBestEffort` into
    the arg/callee var (exactly the `VarLocal` arm one projection deeper).
  - `ofExpr` cannot be read before translation; it takes the flowConnect shape: the `StashParam`
    trigger `isLambdaLiteral arg` becomes `isLambdaLiteral arg || isAccessForm arg`, so
    `connectParamArg` unifies the TRANSLATED access node's type (`refineAccessType` already
    prefers the record's field type) into the param slot; the callee path adds the same
    write-back in `translateIndirectCallBody` after `translate func` and BEFORE the call result
    is zonked (`unifyStepBestEffort funcUseVar (monoTypeToVar (typeOf monoFunc))`).
  - Predictions: `access` 30 → 0 flex; the `state.compileExpr` callee sites become
    singleton-typed calls — **the first dispatch-relevant move since F2** (a call-stats pair is
    owed for this one). Pins: the probe's `apply r.f 2` → `apply.a0` k1; a callee-form fixture
    `useRec r = r.f 2` → the indirect call's callee type k1.

**F4-sig — literal arms in `walkExpr` (`flow.litFacts`).** For `Record`/`TrackedRecord`/`Tuple`/
`List`: walk the children collecting their `WalkPoint`s (this is what the default arm does today
via `walkChildren`, so member injection inside literals is unchanged); `Store.loadType meta.tipe`
→ `litVar`; for each element with a point, locate its slot (`UF.get litVar` → `Record1` field /
`Tuple1` position / `App1 "List" [elem]`) and `joinArrowSetsSig slot point` (structural, as the
result join already is); return `WpHonest litVar` iff every arrow-bearing element handed an
honest point, else `WpOpaque litVar` (the hub rule: a partially visible container must not be
mixed with member-bearing mates). `Update`: join the base's point into `litVar` first, then the
field points (union over-approximates the override — sound). The `Let` arm then joins a let-bound
literal through `sigFlowJoinInto rhsVar (Just litVar)` with no further change. Predictions: the
20 `noJoin|arrow` bodies' result arrows go k1/kN; `mk.result.f` LPartial → k1; the returned-record
consumers' var falls (unsized — the let-chain share is invisible to the counter). Pin: the probe's
`returned` shape.

**F4-acc-node / F4-lit-list (small, same flag as E15).** `refineAccessType`: when
`Mono.eqLayout classified fieldType`, return `Mono.overlayAnnotations classified fieldType`
(never worse than ⊤). List literal: `mList (List.foldl joinBranchTypes first rest)` and, for the
ground-element case, `overlayAnnotations classified (mList joined)`.

**F3-b** is unchanged (§12.9.5). Its role here: it CARRIES whatever a let RHS knows into the
binding, and the census shows a literal RHS knows its sets (`litstore` k1 120/129) — so once the
three roots above stop feeding vars into let-bound containers, the overlay converts `clsLet`
positions (160 of 181 inside containers) into sets instead of into vars. Flip it in the same
series, LAST, so its arm measures what the roots left.

#### 12.10.2 Order, arms, gates

Order: **F2.c → E15 → F4-sig → F4-acc/F4-lit → F3-b flip.** One flag per mechanism (F2.c under
`stamp.useInjectPap`; E15 + the two small ones under `flow.accessFlow`; F4-sig under
`flow.litFacts`; F3-b under `flow.letOverlay`), measured as per-mechanism arms on one emitted tree
— the settle-order lesson (§8.4/§8.5): a combined arm hides which mechanism paid. Gates per arm:
the pins above (+ `LssRecordChainProbe` converted from a report into expectations), full
`elm-tests`, E2E `--target full` flag-on, flag-off byte-identity; a bootstrap fixed point before any
default flip; a `benchmarks/call-stats.md` pair for E15 (callee-form dispatch). Expected on the
coverage book, conservatively: `var` 893 → ~650, ⊤ 699 → ~620, and the first measurable
dispatch change since F2 at the `state.compileExpr` callee sites.

*Instrument in the tree (TEMPORARY, gated):* `litCensus` (Translate), `walk|noJoin`/`walk|join`
(LssInfer), `enrich|accessArg` (Translate) — remove with the v3/v4 instrument.

#### 12.10.3 The series BUILT and MEASURED (2026-09-16) — five cumulative arms, one emitted tree

Artefacts `bin/f5arms-2026-09-16-{base,iup,faf,flf,flo}.*`. Each arm adds one mechanism to the
previous (env flags on the lowered census compiler; F2 on in all arms).

| arm (adds) | `var` | `⊤` | k1 | kN | coverage | wall | mechanism counter |
|---|---:|---:|---:|---:|---:|---:|---|
| base | 893 | 700 | 115,949 | 34,068 | 98.92 % | 9:18 | — |
| +F2.c `stamp.useInjectPap` | **852** | 700 | +39 | −1 | 98.95 % | 9:27 | `lmInject\|pap` **46** (the 107 `noId` uses split 46 PAP / 61 tail-def & other); `localMulti` unwritten 255 → 209 |
| +E15 `flow.accessFlow` | **837** | 702 | +26 | +6 | 98.96 % | 9:23 | `enrich\|access\|ofLocal` **5,785** joins; `ofExpr` 1,355 left to the post-translation write-back |
| +F4-sig `flow.litFacts` | **821** | 698 | **+133** | **+87** | 98.97 % | 9:12 | literal points: tuple 6,858 / list 5,341 / record 1,244 honest, update 1,541 opaque; `walk\|noJoin\|*\|arrow` 20 → 1 |
| +F3-b `flow.letOverlay` | 851 | **668** | 0 | 0 | 98.97 % | 9:17 | `leak\|letAnno` → 0; `clsLet` 161 → 92; ⊤ → var conversion, coverage-flat |

Series total: `var` 893 → 851, `⊤` 700 → 668, k1 +198, kN +92, **coverage 98.92 % → 98.97 %**
(+0.05 pp), wall and RSS flat, `devirtDirect` 4,567 / `devirtKernel` 1,140 → 1,139 in every arm.
Emission moves in every arm (stored demands gain members). **All four flipped DEFAULT-ON** with the
measured rationale on each flag.

What the arms say beyond the totals:

  - F2.c did what its pin says and no more: 46 of the 107 `noId` uses were PAPs of globals; the
    other 61 are tail-def RHSs (`TOpt.TailDef` carries no lambda id — a `t\|` member kind is the
    unbuilt repair). The parameter chain below the PAP sites barely moved (`local:param` flex 520
    → 507): the compileExpr record's field positions are not reached by naming `exprCompiler`.
  - E15's within-item joins are numerous (5,785) but the demand positions they could fill were
    mostly already `mem`; the 30 `access`-form argument positions and the callee-form sites are
    the yield, and the callee-form effect is on DISPATCH, which this series does not measure — the
    call-stats pair is owed.
  - F4-sig is the one that pays on the completeness book: +133 k1 / +87 kN. It also raised
    `clsDestr` ⊤ 250 → 270 (`f` 6 → 20, `t` 11 → 17): a literal whose element is a
    pattern-bound local (`WpNone`) now hands its parent an OPAQUE point carrying that ⊤ instead of
    nothing — honest (the element IS unknown), and uncovered either way.
  - The record-field book the section opened on — `var` `/f:` 270 → 258, `clsLet` `/f:` 110 → 98 —
    barely moved. Its remaining positions (`List.foldl\|/a0/a0/f:bind`, `bindParamsRtys\|
    /r/a0/f:lssFacts/c0/f:sigs`, the `emit*` results) are NOT the compileExpr chain; they are the
    Borrow/LssFacts context records reached through `Maybe`/`Dict` payloads and fold accumulators —
    a fourth root this census did not name. Next diagnostic: the v3 cells for those callees.

Gates: `LssLocalMultiUseInjectTest` 8/8 (F2.c pins 7-8), `LssAccessAndLitFactsTest` 8/8 (E15 arg
+ callee, F4-sig, F4-lit-list — each a flag-off/flag-on differential), full `elm-tests` 13,568 /
standing 12; **E2E `--target full` with the four new defaults: PASS (1727/1727, exit 0)** — a first run showed 935 failures, all `SyntaxError` from a `guida.js` truncated by a CONCURRENT `elm-tests` build sharing `build-xhr` (not a flag; rerun alone was clean). **`benchmarks/call-stats.md` Runs 23/24 (control: the four forced OFF / treatment: ON together, 2026-09-16): coverage 98.93 → 98.98 %, `dispatchUpgraded` +17, benchmark dispatch `sat` +1.10 % (fast share 54.23 → 54.47 %), wall reference +4.2 % / benchmark −1.6 %, RSS flat; BOTH arms at their bootstrap fixed point (benchmark emission byte-identical to reference emission). E15's callee-form sites do not show as a dispatch move. Verdict: completeness-only, dispatch-neutral, ~4 % analysis cost on the unoptimized binary; flags stay default-on.**

#### 12.10.4 Census instruments REMOVED (2026-09-16) — and a recovery note

Removed from the tree: the v3 producer census (`StashCensus`, `censusWrap`, `unifyParamsCollectAt`'s
labels, `prodForm*`, `canTypeHasArrowDeep`), the v4 binding-kind/local-multi-join census
(`insertVarK`, `ItemAux.varKind`, `bumpLm`/`lmUseCensus`/`lmRhsCensus`, `rhsShape`,
`ordOfFreshName`), and the F4 census (`litCensus` at the three literal arms, the `walk|join`/
`walk|noJoin` bumps + `bodyFormCensus`, the `enrich|accessArg` bumps). Kept: the mechanism counters
every shipped fix reports under `lss.report` (`lmInject|*`, `enrich|access|*`, `litFacts|*`,
`rowDefer|*` incl. the per-row `why`, `rootFold|localSkip`, `letOverlay|tailFn`) and the older
LSS_026 instruments that predate this plan (`censusStashMiss`, `argDeepCensus`, `destranno`).

**Recovery note.** The final tidy — a regex meant to delete doc comments orphaned by the function
removals — matched from the first doc comment of each module to the orphan, deleting ~5,000 lines of
`Translate.elm` and ~1,770 of `LssInfer.elm`; git is not reachable from this sandbox. Both were
rebuilt from the newest surviving base (`Translate.elm.bak`, 2026-09-15 14:55, taken before the v3
instrument; a 2026-09-10 copy of `LssInfer.elm`) plus the intact tails, and every session edit in
the lost regions re-applied from the transcript. Audit: the rebuilt `Translate.elm` differs from its
base in 43 hunks, each identified as a known change (F2/F2.b/F2.c, the root-fold skip, F3-a, F3-b,
E15, the `flow` renames, `LRow` arms); `LssInfer.elm` differs from its base in exactly 3 (the
literal arms, `walkLiteral`'s helpers, the `papSuccWrite` fix). Gates after the rebuild: 132/132 LSS
unit tests, full `elm-tests` 13,568 / standing 12 (identical to before the removal), E2E
`--target full` 1727/1727, plus the check below. Backups of the rebuilt modules are in the session
scratchpad (`recon/`). Lesson recorded in memory: never delete by a multi-line non-greedy regex
anchored on a comment opener; delete by named declaration only.

**Rebuild verified three ways (2026-09-16, `$SP/recon-check.log`).** (1) A census-lowered binary of the
rebuilt tree self-compiles to `coverage: positions=151,650 k1=116,010 kN=34,089 var=851 top=668 part=32
coveredBp=9897` — `var`/`⊤`/coverage identical to Run 24's benchmark row; every mechanism counter agrees
(`lmInject|pap` 46 = 46, `self` 138 = 138, `noLam` 61 = 61, `litFacts|record|honest` 1,244 = 1,244,
`letOverlay|tailFn` 128 = 128) and the rest differ by ≤ 20 because the removed census functions are no
longer part of the source being compiled (`positions` −208). (2) 62 fixed external programs (the 60
largest E2E tests + `LssGapLambdaStages` + `PapStampTest`) compiled by the PRE-removal binary
(`f6-bench-on-census`, Run 24's) and by the rebuilt tree's binary: **62/62 byte-identical emissions**
— the removal was report-gated and the rebuild preserved semantics. (3) Unit 13,568 / standing 12 and
E2E 1727/1727 as above.
