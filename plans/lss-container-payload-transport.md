# LSS — container-payload identity across item boundaries

**Status (2026-09-15, latest): §12.6 — the `papSuccWrite` seen-guard fix MEASURED: `var`
12,958 → 1,380 (−89 %), coverage 90.62 % → 98.43 % (+7.81 pp), wall flat. F1 reverted (null,
§11); the v3 post-translation census (§12) found the bug: every PAP-successor walk wrote depth 1
and stopped. Residual 2,725: bare-parameter locals 47 %, local-multi 866 (32 %, F2 next), lambda
bodies returning unknowns 13 %. Gates owed: elm-tests (running), E2E, bootstrap 8c, call-stats
Runs 23/24. Earlier: §11 — F1 BUILT,
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

**F4 — Literal field write-back (E14).** Record, tuple and list LITERALS: unify each field/
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
  2. **F2 — local-multi instance write-back (E7)**, now correctly sized at **866 positions,
     99 % flex**, the only systematically failing argument form. Design as §10.5 F2: keep the
     fresh var per instance, `connectParamArg` it when the instance RHS type settles.
  3. **F3 — store-aware let binding (E12/E13)**: `local` positions arrive ⊤ 13 % at head and
     44 % inside containers (storeless `clsLet`/`clsDestr`); and 1,422 bare-local flex whose
     binding kind (parameter / let / destructure) a v4 read should split before building.
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
| `local` — a callback arriving as a PARAMETER of the enclosing function, bare | 1,292 | 47 % | E6: its members come from the enclosing spec's demand; needs the binding-kind split (parameter / let / destructure) — **F3's target, re-sized** |
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
