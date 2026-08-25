# Eliminating "unknown = ⊤" from the LSS analysis

**Status: PHASES 1a, 1b AND 2a IMPLEMENTED AND MEASURED (2026-08-24) — see
§10 RESULTS at the bottom for the numbers and the verdicts. 1a and 1b ship
unconditionally; 2a ships behind `lss.arrowIdentity`, DEFAULT-OFF. Phase 2b
remains designed-not-lowered (§4.9) and Phase 3 remains an outline (§5).**

**Headline: resolution completeness 24.10 % → 37.05 % on the self-compile.
`top` collapses −80.7 % (Phase 1b), Phase 2a then turns `unknown` around
(−4.8 %) while raising BOTH `k = 1` and `k ≥ 2`, and `|set| ≥ 2` reaches a
dispatch site for the first time ever (`multiSetSiteHist 2->2`).**

**And the one measurement that redirects the arc: EXP-2a (§10.4) says a def's
annotation and its body node type are structurally-equal DISTINCT objects
97.5 % of the time. Per-occurrence arrow ids therefore CANNOT close artifacts
#1/#2/#4a/#6/#8/#9/#10 — Phase 2b's solver-root ids are required, not
optional. Only #7 retired, and structurally: there is no edit to make.**

Original status line, kept for the record: *PROPOSED (v2, 2026-08-24). §3
(Phase 1) and §4 (Phase 2a) are implementation-ready work orders — numbered
tasks, exact sites, exact code. §4.8 (Phase 2b) is designed but not lowered;
§5 (Phase 3) is an outline with its open questions named. See §4.0 for the
v1→v2 correction that split Phase 2.*

**The acceptance metric is the §2.5 resolution ledger, NOT dispatch coverage.**
Sum lowering does not exist yet and every devirt arm needs `|set| = 1`, so
this arc is judged on how much of the analysis becomes *knowable* —
`unknown` ↓, `concrete` ↑, `|set| ≥ 2` ↑ — which needs no consumer. Coverage
is kept as a regression guard only. Baseline today: **24.09% concrete,
39.84% unknown, 544 multi-member sets, 0 of them at a call site.**

Diagnosis this plan acts on:
`design_docs/auto-borrow-inference/lss-why-the-fidelity-program-failed.md`.
Do not start here; start there. The short version:

- The GAP-1…GAP-9 fidelity programme (≈10 plans, 14 months) netted **+0.02 pp**
  dispatch coverage. Changing one integer (`maxSpecsPerGlobal` 64 → 512) netted
  **+13.4 pp and −3.6% wall**.
- Every flow/transport repair regressed the metric it targeted: sigFlow
  symmetric −26.7% rel, LSS_023 directed −12.6% rel, LSS_026 callArgFlow
  −0.51 pp (built, measured, deleted 2026-08-24).
- The deficit is at the two ENDS of the pipeline. Producer end: 62.6% of
  signatures are `allflex`, 2.8% carry anything, `allflex : hasTop` = **100 : 1**.
  Consumer end: `maxSetSize` 8/16/32 gives a **byte-identical compiler**.

**The thesis of this plan, in one line.** The paper's set grammar is
`σ ::= {ℓ₁…ℓₙ} | α | µa.σ | a` — a set, **a variable**, a µ; **no top**. Eco's
is `LambdaSetAnno = LTop | LSet (List Int)` — a set and a top, **no variable**.
Eco substituted ⊤ for the paper's variable, and every symptom in the register
follows from that one substitution.

**Scope decision, taken by the user 2026-08-24:** kernel poison and budget
caps are KEPT. They are honest ⊤ — an opaque boundary and a deliberate
resource limit. What must go is ⊤-as-unknown.

---

## §0 The measured position

All figures: self-compile of `compiler/src/Terminal/Main.elm`, solver engine,
budget 512, `sigFlow`/`layoutQualMembers`/`postSettleDevirt` on. Source
artifacts `/work/lss-gap2-d2-argflow-{on,off}.census`,
`/work/lss-unresolved-dispatch-attribution.txt`.

**Readback composition** — 422,403 classified set readbacks:

| cause | count | share |
|---|---:|---:|
| `causeFlex` — slot NEVER WRITTEN, reads ⊤ | 167,967 | **39.8%** |
| `causePoison` — an explicit `LsTop` was in the slot | 152,890 | 36.2% |
| `causeSet` — a real answer | 101,546 | 24.0% |

**52.3% of everything that reads ⊤ was never written at all.** 78.5% of all
minted arrow slots are never written by anything, ever.

**And the poison bucket is contaminated.** Every *attributed* ⊤ writer sums to
≈ **7,881** events (`widenedByKernel 1,858` + `widenedByCf 5,344` +
`poisonBoth 672` + `widenedBySize 7` + `widenedBySigSize 0` + `lenGuard 0` +
`topMixedFlex 0/0`) against **152,890** `causePoison` readbacks — a **19 : 1**
gap. The difference is one uncounted site, §0.1.

**⊤ almost never destroys knowledge.** `setWriteTopJoin = 2` and
`setWriteUnion = 0` on the entire self-compile: exactly TWO ⊤ writes landed on
a slot that already held members. ⊤ here is absence, not loss.

### §0.1 The laundering site — `Store.monoTypeToVarC`, MFunction arm

`compiler/src/Compiler/MonoSolver/Store.elm:531-567`. The code, and its own
comment, state the mechanism:

```elm
setContent =
    case anno of
        Mono.LTop     -> IO.LambdaSet1 IO.LsTop      -- <-- HERE
        Mono.LSet ms  -> IO.LambdaSet1 (IO.LsMembers ms)
```
> *"Deliberate asymmetry with zonkSetSlot: a DEMAND's LTop encodes as
> top=True (poison — 'some caller was widened, this arrow must stay dynamic'),
> while an unconstrained slot merely READS BACK as LTop without ever having
> poisoned anything."*

The four-hop chain (plan `lss-gap2-callarg-transport.md` §"What is actually
broken"):

1. an unconstrained param slot reads back `LTop` (`causeFlex`);
2. the all-⊤ demand keys onto one shared key per type shape;
3. **the spec seed re-encodes that stored `LTop` as an explicit `LsTop`** —
   this site;
4. the body reads poison, its own call demands inherit it, recurse.

`IO.andThen` is the witness: `zc|…IO andThen|poison = 2,102`, `|set = 987`,
**`|flex` absent (= 0)** — every annotation slot demand-written, with zero
local poison writers. That is HOP 3 in isolation.

**This site has no counter.** It bypasses `unifySlotWithSetC` entirely, which
is why `setWriteTopJoin = 2` while `causePoison = 152,890`. The exact split of
`causePoison` into {laundered-unknown | kernel | soundness | cap} is, at HEAD,
**unmeasurable**. Phase 1 exists to fix that.

### §0.2 The prize

Generic dispatch is not a long tail: **top 10 function pointers = 33.7%** of
all generic dispatch, top 50 = 66.0%, top 200 = 91.8%. And of the top 12
hottest unresolved closures, **every one has exactly one `papCreate` site**
(one has two) — 620 M dispatches, 27% of all dispatch, **zero aliasing
ambiguity**. `Terminal_Main_lambda_14760` alone is 179.7 M, created once
inside `System_TypeCheck_IO_andThen`, whose signature ALREADY carries
`ordinal 3: m=1,l` naming it. The fact is computed and the dispatch is still
generic.

---

## §1 Why this order

1. **`LUnknown` first** because it is the *instrument*. Today we cannot say
   what share of ⊤ is acceptable, so we cannot tell whether Phase 2 worked.
   It is also cheap and can land behaviour-neutral (§3.3), and its second half
   (§3.6) stops the laundering at source, which is a candidate win on its own.
2. **Arrow identity second** because it is what actually closes the unknown
   population — 11 hand-written transport artifacts exist solely to re-tie
   slots that a shared representation would never have split, and each is a
   place a leak hides.
3. **The set variable last** because it needs shared identity to mean
   anything (a variable minted per-load would be exactly as fragmented as a
   slot minted per-load), and because it touches the demand → registry →
   spec-key path, which is the highest-risk surface in the monomorphizer.

**A note on Phase 1 alone.** It is not merely instrumentation. Removing HOP 3
means an unconstrained slot stays *flex* rather than becoming *poison* — and
flex is recoverable: a later LSS_010 join or retranslation can still fill it,
where poison is terminal and absorbing. That is a testable precision
hypothesis, and §3.8 names the interaction that could make it a regression
instead.

---

## §2 Invariants this plan must not break

Carried forward, all currently enforced:

- **LSS_001** — never `LSet []`. ⊤ (or, after Phase 1, `LUnknown`) is the
  fallback; an empty set claims a position has no inhabitants, which is the one
  reading that is always wrong.
- **LSS_004 / LSS_021 / LSS_022** — kernel/FFI boundaries poison. **KEPT
  DELIBERATELY** (§0's scope decision). 16 sites, `widenedByKernel = 1,858`.
- **LSS_005** — graceful degradation: widening is always sound; annotations
  and spec counts may move, observable behaviour may not.
- **LSS_006** — `loadTypeWithArrows`'s minting order DEFINES arrow ordinals.
  **Phase 2a amends this**; see §4.3.
- **LSS_007** — a `FunL` slot holds only `FlexVar` or
  `Structure (LambdaSet1 …)`; `LambdaSet1` appears nowhere else. **Phase 1b
  relies on this** — it mints a bare `FlexVar` where a `Structure` was.
- **LSS_026(a)** — honest ∅-as-source, unconditional. A members-carrying
  resolution that crossed a terminal FlexVar source resolves ⊤. **Interacts
  with Phase 1b — see §3.8.**
- **The 32-slot record cap** — `Engine.S` and `Engine.LssStats` are both AT
  the compiled-Record GC-scan limit. Every new field goes in an existing
  sub-record (`itemAux`, `lssStats.sigStats`), never top-level
  (`Engine.elm:960-964`). `LssStats` is at 31 of 32; `AbiCloningStats` at 27
  of 32; `LssZonkAcc` at 18 (it is a `ZonkCtx` field, not `S`, and is not
  near the cap).

House rails (all previously hit, all recorded):

- **Two-binary byte-identity.** Flag-off/neutral must be byte-identical, and
  the rail is a binary built WITHOUT the change vs one built WITH it, both
  compiling the SAME final source. Compare `eco-compiler.mlir` md5. Never
  HEAD-source vs changed-source: every compiler edit moves the corpus.
- **Env vars are not ninja inputs** — delete `bin/eco-compiler{,.mlir}`
  between arms; a stale artifact shows `fast=0` in the census (the tell).
- **`eco-config.json` must carry `"engine":"solver"`** or every LSS counter
  reads zero.
- **Suites run serially** (`~/.eco` typed-artifacts race); purge
  `build/test/*/eco-stuff` between E2E legs and touch a fixture (the harness
  cache is env-blind).
- **Census tsvs compare as multisets**, matched by SYMBOL and never by index;
  `lambda_N` numbering is corpus-specific.
- **Site counts are not event counts.** The register's own recorded error, made
  repeatedly: `declinedNoInstance +133` judged "not material" was one
  artifact-decode loop worth 44 M events; `byKernel −61%` moved dispatch by
  nothing; `declinedBlocked 156 → 0` moved coverage 0.000 pp. **Every gate in
  this plan is an event count.**

---

## §2.5 THE ACCEPTANCE METRIC — the resolution ledger

**Decided 2026-08-24.** This arc is **not** gated on dispatch coverage. Sum
lowering does not exist, every devirt arm requires `|set| = 1`, and a
perfectly resolved 2-set is therefore worth nothing at runtime today. Gating
on coverage would measure the consumer, not the analysis.

The arc is gated instead on **resolution completeness**: what fraction of
arrow positions the analysis can give a concrete answer for, and how many of
those answers are genuinely multi-member.

### §2.5.1 The ledger reconciles EXACTLY from counters that already exist

**Verified 2026-08-24 against the HEAD self-compile.** No new counter is
required to produce the ledger — only an extraction formula:

```
concrete k=1   = sizeHist[1]
concrete k≥2   = Σ_{k≥2} sizeHist[k]
over-cap       = widenedBySize                       (resolved, then discarded by maxSetSize)
top            = causePoison + causeEdgeTop
unknown        = causeFlex   + causeEdgeEmpty
                 ─────────────────────────────
total          = setsZonked
```

and the identity `Σ sizeHist = causeSet + causeEdgeSet` closes it. On the
HEAD self-compile this reconciles to the digit:

```
101,552 (Σ sizeHist) + 7 (widenedBySize) + 167,924 (causeFlex)
      + 0 (causeEdgeEmpty) + 152,017 (causePoison) + 0 (causeEdgeTop)
    = 421,500 = "sets zonked"
```

**Where each number is read.** `ECO_MONO_LSS_REPORT=1`, stderr:

| term | line | format |
|---|---|---|
| `setsZonked`, `sizeHist` | `Monomorphize.renderLssReport` | `sets zonked: N; size histogram: 1->a 2->b …` |
| `widenedBySize` | same | `widened: bySize=W byKernel=… byBudget=… bySigSize=…` |
| `causePoison` etc. | `argFlowCensusBlock` | `ARGF\tzc\|all\|poison\tN` — keys `zc\|all\|{set,poison,flex,edgeSet,edgeEmpty,edgeTop}` (`Store.elm:1380-1391`) |

**Per-consumer** rows use the same six suffixes under `zc|<comparableGlobal>|…`.

**MANDATORY — emit the ledger, do not hand-grep it.** Task **T-LEDGER**
(land it FIRST, before any Phase-1 code): add one line to
`renderLssReport`'s `String.join "\n"` list, immediately after the
`sets zonked:` line at `MonoSolver/Monomorphize.elm:216`:

```elm
, "ledger: k1=" ++ … ++ " kN=" ++ … ++ " overcap=" ++ … ++ " top=" ++ … ++ " unknown=" ++ … ++ " total=" ++ … ++ " RECONCILES=" ++ (if lhs == stats.setsZonked then "yes" else "NO(" ++ String.fromInt lhs ++ ")")
```

computed from `stats.sizeHist`, `stats.widenedBySize` and
`stats.sigStats.argFlowCensus` (`Dict.get "zc|all|poison"` &c.). The
`RECONCILES` field is the point: it is a self-check that fires the moment a
new cause arm is added without being wired into the ledger, which is exactly
the mistake Phase 1 is able to make. This lands at HEAD, is report-gated
(`renderLssReport` only runs under `lssConfig.report`), and is therefore
byte-neutral by construction.

> **Caveat that must ride with every quote of these numbers.** `causePoison`
> and friends are gated by `censusOn = s.env.lss.report` (`Store.elm:1276`,
> `bumpCauseC:1256`) and read **0** without `ECO_MONO_LSS_REPORT=1`.
> `widenedBySize` and `sizeHist` are unconditional. Never mix an arm measured
> with the flag against one measured without it.

### §2.5.2 Today's baseline

Self-compile, budget 512, HEAD after the D1/D2 deletion — 421,500 readbacks:

| bucket | today | share | target |
|---|---:|---:|---|
| `set` k = 1 | 101,002 | 23.96% | ↑ |
| **`set` k ≥ 2** | **544** | **0.13%** | **↑ — the completeness signal** |
| over-cap (resolved, discarded by `maxSetSize`) | 7 | — | true sizes 9, 11, 21; ↑ is fine (budget, KEPT) |
| `top` — kernel / budget / soundness | 152,017 | 36.07% | ≈ flat (deliberately kept) |
| **`unknown` — never written** | **167,924** | **39.84%** | **↓ toward 0 — the target** |
| **resolution completeness** | **101,553** | **24.09%** | **↑** |

Size distribution of the concrete answers today:
`1→101,002  2→300  3→158  4→46  5→10..14  6→10  7→7  8→9`, plus the three
over-cap sets at 9, 11 and 21. Multi-member sets are **0.54% of all concrete
answers**.

### §2.5.3 The second row: does a multi-answer ever reach a consumer?

`AbiCloningStats.multiSetSiteHist` (`AbiCloning.elm:139`) counts **consulted
call sites carrying a multi-member set**. Today:

```
lss census multiSetSites |set|->sites: (none)
```

**544 multi-member sets exist in annotations; ZERO reach a dispatch site.**
They live on arrow positions that are never consulted as a callee. Two
distinct populations, two distinct questions:

- `sizeHist` k ≥ 2 → *is the analysis producing real multi-answers?*
  (completeness — this plan's gate)
- `multiSetSiteHist` → *would sum lowering have anything to consume?*
  (consumer readiness — sum lowering's gate, tracked but not gated here)

**This also corrects the record.** GAP-6's NO-GO was argued as "multi-member
sets don't form". They do form — 544 of them. What is zero is multi-member
sets *at call sites*. Conflating those two is the circularity the register
flagged and never resolved. Report both rows in every arm from now on.

### §2.5.4 The disambiguator — k ≥ 2 rising is AMBIGUOUS

`|set| ≥ 2` can grow for one good reason and one bad one, and this register
has already been burned by the bad one:

- **COMPLETENESS (good):** a position that had no answer now resolves to an
  honest k-set. Signature: **k ≥ 2 ↑ while `unknown` ↓**, with k = 1 held or
  rising.
- **POLLUTION (bad):** honest singletons unioned at a hub into 2-sets, which
  every current consumer then declines. Signature: **k ≥ 2 ↑ while k = 1 ↓ by
  a comparable amount and `unknown` is flat.** This is what sigFlow did
  (−26.7% rel coverage).

**So no phase may be judged on `k ≥ 2` alone.** The gate is the JOINT
movement of the five ledger buckets: a phase passes when `unknown` falls and
`concrete` rises; `k ≥ 2` rising is the confirmation that the new answers are
real analysis rather than re-labelled singletons.

### §2.5.5 Caveat — readbacks, not positions

`sizeHist` and the cause counters are bumped per **zonk readback**, not per
distinct arrow position: a hot slot read 50 times counts 50 times
(`bumpZonkAcc`, `Store.elm:1890`). Across arms of the SAME corpus this is a
sound relative signal, which is all the gates need. It is **not** an answer to
"how many positions did we resolve", and must not be quoted as one.

A per-position variant (dedup by slot identity at zonk) is a possible
refinement if a phase's ledger movement is ambiguous. It is not a
prerequisite — record the caveat rather than building the instrument
speculatively.

---

## §3 PHASE 1 — split `LUnknown` off `LTop`

### §3.0 The change

```elm
type LambdaSetAnno
    = LTop              -- GENUINE: kernel/FFI boundary, budget cap, soundness fallback
    | LUnknown          -- NEW: nothing was ever written here
    | LSet (List Int)
```

`compiler/src/Compiler/AST/Monomorphized.elm:858-860`. Already exported as
`LambdaSetAnno(..)` (`:10`) — no export edit. The doc block at `:850-857` and
**invariant LSS_001** (`design_docs/invariants.csv:609`) both state the
two-constructor law and must be amended in the same commit.

### §3.1 THE LATTICE — decide this before writing any code

`Monomorphized.joinAnnotationsChanged:1178-1254` carries a soundness law in
its own docstring:

> *SOUNDNESS LAW: the flag must NEVER be falsely False … the two directions
> are kept exact by `annoCovers annoA annoB` deciding precisely
> `unionAnno annoA annoB == annoA`.*

Break that and the LSS_010 registry join either miscompiles (falsely-False —
a stored singleton lies about a later caller, which a fast-dispatch stamp
turns into a wrong call) or never converges (falsely-True). **The lattice
differs between 1a and 1b, deliberately, and the change of lattice is part of
the 1b commit.**

#### 1a — `LUnknown` is a *labelled* ⊤. Join keeps the receiver's label.

```elm
unionAnno a b =
    case ( a, b ) of
        ( LTop, _ )          -> LTop
        ( LUnknown, _ )      -> LUnknown          -- receiver's label wins
        ( _, LTop )          -> LTop
        ( _, LUnknown )      -> LUnknown
        ( LSet xs, LSet ys ) -> LSet (unionSortedInts xs ys)

annoCovers a b =
    case ( a, b ) of
        ( LTop, _ )          -> True
        ( LUnknown, _ )      -> True
        ( LSet _, LTop )     -> False
        ( LSet _, LUnknown ) -> False
        ( LSet xs, LSet ys ) -> sortedSubsetOf ys xs
```

Exactness, all nine pairs: `(LTop,LUnknown)→LTop==a` ✓T; `(LUnknown,LTop)→
LUnknown==a` ✓T; `(LUnknown,LUnknown)` ✓T; `(LUnknown,LSet)→LUnknown==a` ✓T;
`(LSet,LUnknown)→LUnknown≠LSet` ✓F; `(LSet,LTop)→LTop≠LSet` ✓F; the three
pre-existing pairs unchanged.

**Why keep-first, and why it is the whole byte-identity story.** With a
collapsing join (`LUnknown ∪ LTop = LTop`) every stored spec type whose label
differs from a later demand reports `changed = True`, which
`Registry.getOrCreateSpecIdKeyed:160` turns into `HitChangedJoin`, which
`Engine.enqueueSpecKeyed:1737` turns into `storedChanged` → a forced
re-translation of an already-translated spec. It converges (height 1), so it
is not a hang — but it perturbs dirty-flush order, which perturbs SpecIds,
which perturbs MLIR symbol names. **1a would not be byte-identical.**
Keep-first makes the pair join to `changed = False`, i.e. `HitNoopJoin`, and
**`enqueueSpecKeyed` treats `HitNoopJoin` exactly as `HitIdentical`** — the
only difference is `bumpKeyedHit`, a census counter (verified
`Engine.elm:1728-1740`). Non-commutativity on a pair that is semantically one
lattice point is harmless: the join stays idempotent, monotone and height-1,
and the receiver's label never oscillates.

**Measurement caveat this creates:** a stored type's label is whoever got
there first, so registry-resident labels are not a clean unknown/top census.
All three consumers that will be censused (`AbiCloning.stampCall`,
`MapTemplate.classifyBody`, `LssFacts.query`) read **node/graph** types, which
are freshly zonked per item — so the consumer split is clean. Do not census
labels off `registry.reverseMapping`.

#### 1b — `LUnknown` becomes semantically distinct. Join must LOWER.

The moment `monoTypeToVarC` stops encoding `LUnknown` as `LsTop` (§3.6), the
labels carry different *encodings*, and keep-first becomes **unsound**: a
stored `LUnknown` that absorbed a genuinely-poisoned `LTop` demand would seed
a bare flex slot where a caller demanded poison, losing the poison and
admitting a false singleton. Likewise `LUnknown ∪ LSet ms` must not keep
`ms` — "no answer" is not "no inhabitants", so a caller outside `ms` would be
mis-stamped.

```elm
-- 1b: proper height-2 lattice  LSet ⊑ LTop,  LUnknown ⊑ LTop,  LSet ⋈ LUnknown
unionAnno a b =
    case ( a, b ) of
        ( LTop, _ )              -> LTop
        ( _, LTop )              -> LTop
        ( LUnknown, LUnknown )   -> LUnknown
        ( LUnknown, LSet _ )     -> LTop
        ( LSet _, LUnknown )     -> LTop
        ( LSet xs, LSet ys )     -> LSet (unionSortedInts xs ys)

annoCovers a b =
    case ( a, b ) of
        ( LTop, _ )              -> True
        ( LUnknown, LUnknown )   -> True
        ( LUnknown, _ )          -> False
        ( LSet _, LTop )         -> False
        ( LSet _, LUnknown )     -> False
        ( LSet xs, LSet ys )     -> sortedSubsetOf ys xs
```

Exactness verified over all nine pairs as above. Height 2 ⇒ at most two forced
re-translations per position; `joinRounds`/`retranslations` in the census are
the watch. **This flip is task 1b-T2 and must land in the SAME commit as the
`monoTypeToVarC` flip** — never separately, in either order.

*(Phase 3 note: `LUnknown ∪ LSet = LTop` is the honest answer only because
`LUnknown` is a commitment. The paper's variable is not joined — it is
**grounded**, which is why the paper needs no join operator at all. This arm
is expected to disappear in Phase 3, not to be optimised in Phase 1.)*

### §3.2 SCOPE CORRECTION — `LUnknown` is solver/zonk-only in Phase 1

**v1 of this plan listed six `LUnknown` producers. Four of them are wrong and
are withdrawn.** The classification rule "the position was never written"
technically covers the storeless stampers too, but flipping them buys nothing
and costs three real hazards:

| withdrawn site | why it stays `LTop` |
|---|---|
| `Store.classifyGo` `Can.TLambda` (`:2095`), `Zonk.lambdaChain` (`:224`), `TypeSubst` ×4, `KernelAbi:354`, `Specialize:5287` | **These annotations never survive.** In the solver path the classifier's output is the FIRST argument of `Mono.overlayAnnotations`, which takes the SECOND (zonked) argument's annotations wholesale — `Translate.elm:1213, 1227, 1484, 2409`. Flipping a placeholder that is unconditionally discarded relabels nothing. In the subst path it is the *entire* population (`Monomorphize.elm:298`: `lssMemberOrigins = Dict.empty -- subst engine: all-LTop`), so flipping it silently zeroes `MapTemplate.declinedEngine`, whose whole purpose is to separate the subst population from real widening (`MapTemplate.elm:464-472`). |
| `Mono.headAnno` non-function default (`:1095`) | "Not an arrow" ≠ "unwritten arrow". Every decline ladder (`LssFacts.query`, `MapTemplate.classifyBody`, `AbiCloning.stampCall`) would silently reclassify non-arrows as unknown. |
| `MapTemplate.arrowAnnos` `MVar` arm (`:1217`) | Deliberate **poison**, per its own doc at `:1194`: *"MVar answers LTop: erased polymorphism can hide an arrow"*. It is consumed as `PoisonArgTaint ArgLTop`. Relabelling it grows the licence pool with no analysis behind it. |
| `Translate.translateGlobalCallGroundMemo:2730` + `Engine.groundSetMembers:1380` | Both are **key construction**, annotation-neutral by construction (the doc at `Translate.elm:2724` says so). A partial flip here makes the M2b ground-call memo miss 100% of the time. |

**So Phase 1's `LUnknown` producers are exactly TWO**, both inside
`Store.zonkSetSlot`:

| line | arm | today | Phase 1 |
|---|---|---|---|
| `Store.elm:1684` | wildcard `_ ->` "FlexVar residual: no information" | `LTop` + `causeFlex` | **`LUnknown`** + `causeFlex` + `causeUnknown` |
| `Store.elm:1655` | `LsFrom` resolved to `Just []` | `LTop` + `causeEdgeEmpty` | **`LUnknown`** + `causeEdgeEmpty` + `causeUnknown` |

and everything else in `zonkSetSlot` stays `LTop`:

| line | arm | verdict |
|---|---|---|
| 1606 | explicit `LsTop` in the slot | `LTop` — genuine (kernel poison / demand-encoded / ⊤-absorb) |
| 1623 | `LsMembers` over `maxSetSize` | `LTop` — the budget cap, KEPT |
| 1633 | `Nothing` (no `lss` accumulator) | `LTop` — the slot HAS content, only the policy record is absent; asserted unreachable in production |
| 1647 | `LsFrom` hit a reachable ⊤ | `LTop` — soundness absorption (also the LSS_026(a) `resolveSlotMembers → Nothing` landing) |
| 1674 | `LsFrom` over-cap | `LTop` — budget cap |
| 1680 | `Nothing` on the `LsFrom` arm | `LTop` — as 1633 |
| 1628, 1677 | `LSet` | unchanged |

**Keep bumping the OLD counters as well as the new one.** `causeFlex` and
`causeEdgeEmpty` stay so the `zc|` rows remain joinable against the §0
baseline and against `plans/lss-gap2-callarg-transport.md`; `causeUnknown` is
a strict superset for the ledger. Drop them only after Phase 2 lands.

> **Sub-hazard not to lose:** `resolveSlotMembers` (`Store.elm:1727-1745`)
> returns `Nothing` under LSS_026(a) and lands on line **1647**
> (`causeEdgeTop`), where it is indistinguishable from a real reachable-⊤
> absorb. That is a *genuine* soundness widening, so `LTop` is right — but it
> means `top` in the ledger silently contains the honest-∅ population. If
> §3.8's measurement is ambiguous, split it with its own cause counter; that
> is independent of `LUnknown` and can be done at any time.

### §3.3 PHASE 1a — work order (behaviour-NEUTRAL, byte-identical)

Land **T-LEDGER (§2.5.1) first**, at HEAD, and record the baseline ledger
line. Then:

**1a-T1 — the constructor.** `Monomorphized.elm:858-860`. Add `LUnknown`
between `LTop` and `LSet`. Amend the doc block `:850-857`.
*Everything below is the fallout; the Elm compiler will name most of it.*

**1a-T2 — `annoHash` (`:412-419`) → `LUnknown -> 3`.** The **same integer
literal** as `LTop`, not a fresh constant.
*This is the highest-probability silent failure in the phase.* `annoHash`
feeds `mFunction`'s `specSeed` (`:500-517`) → `specHashOf` → the HashMap
bucket in `Mono.specKeyMapGet` (`Registry.elm:107`). A distinct hash puts an
`LUnknown` demand in a different bucket, `eqKeySpec` is never consulted, and
the registry mints a duplicate SpecId per position — silent spec fan-out until
`MONO_030`'s `specBreadth = 50000` trips (`Config.elm:113`). **Compiles
cleanly if you get it wrong.**

**1a-T3 — `toComparableFragments` (`:2231-2252`) → `LUnknown -> "A("`.**
Byte-identical to the `LTop` fragment. (The `else` layout branch already emits
`"A("` unconditionally.) Elm's exhaustiveness check catches an omission here.

**1a-T4 — `eqKeyWith` (`:566-584`).** Replace the raw
`(not annoSensitive || annoA == annoB)` with a key-equality helper in which
the two ⊤ labels compare equal:

```elm
annoKeyEq : LambdaSetAnno -> LambdaSetAnno -> Bool
annoKeyEq a b =
    case ( a, b ) of
        ( LSet xs, LSet ys ) -> xs == ys
        ( LSet _, _ )        -> False
        ( _, LSet _ )        -> False
        _                    -> True    -- LTop/LUnknown, any combination
```
Without it, `eqKeySpec` violates its own documented contract at `:523-525`
(`eqKeySpec a b == (toComparableMonoType a == toComparableMonoType b)`) and
the same duplicate-spec symptom appears by a different mechanism — same
bucket (T2 agrees), rejected confirm. `identicalOr`'s `a == b` fast path
(`:563`) stays sound: it is strictly stronger than `annoKeyEq`.

**1a-T5 — `unionAnno` (`:1442-1452`) and `annoCovers` (`:1328-1337`)** to the
**1a keep-first** tables of §3.1. Note both are TUPLE cases: `annoCovers`
needs three new patterns, not one.

**1a-T6 — `collectAnnoGo` (`:924-936`) → `LUnknown -> acc`.** Contributes no
members to the LSS_018 μ-tie; identical to `LTop`.

**1a-T7 — leave `widenSets` (`:958-977`) and `Intern.widenSets`
(`Intern.elm:272`) stamping `LTop`.** They are the normalisers that keep the
three string-key derivations byte-identical: LSS_024 `specWidenedKeys`
(`Engine.elm:1771`), LSS_019 ground member ids (`Engine.elm:1380`), the
LSS_024 F-fence fingerprint (`AbiCloning.elm:1949`), plus the `keyed = False`
widened registry key (`Engine.elm:1522`) and the budget-widened key
(`:1718`). `Intern.elm:243` already warns about exactly this drift class:
*"A divergence produces a different widened structure and therefore a
different registry key … with no compile error; the bootstrap is the gate."*
`joinWidened` (`:1261`) is correct unchanged — an `LUnknown` tree widens to an
`LTop` tree, so `widened /= a` reports `True`, and it terminates in one step.

**1a-T8 — the consumer arms, each treating `LUnknown` EXACTLY as `LTop`.**
Every one is an Elm exhaustiveness error, so this list is a checklist, not a
search:

| site | arm to add |
|---|---|
| `Store.monoTypeToVarC:531-567` | `Mono.LUnknown -> IO.LambdaSet1 IO.LsTop` — **identical to `LTop` in 1a. The flip is 1b.** |
| `Borrow/LssFacts.query:234-242` | `Mono.LUnknown -> Poison PTop` |
| `MapTemplate.classifyBody:464-493` | duplicate the `LTop` body verbatim (factor it into a `let` to keep them in step) |
| `MapTemplate.calleeVerdict:1081-1087` | `Mono.LUnknown -> poison (PoisonHigherOrder HOLocalLTop)` |
| `MapTemplate.argProvenance:1162-1180` | `Mono.LUnknown -> ( PoisonArgTaint ArgLTop, Tuple.second acc )` |
| `AbiCloning.stampCall:1201-1416` | duplicate the `Mono.LTop ->` body at `:1408` (no stamp, bump `topSiteShapes`) — see 1a-T10 for the census split |

**Does NOT break and needs NO edit** (verified): `Mono.eqLayout` (`:991-1011`
— the `MFunction` arm discards both annotations by design, `:979-984`; the
`a == b` fallback is leaf-only), `shallowLayoutKey` (`:1039`), `headAnno`
(`:1088`), `joinAnnotations` (`:1109`), `overlayAnnotations` (`:1379` — takes
the second type's annotation wholesale; its docstring's "all LTop
placeholders" wording goes stale, fix the comment), `singletonHeadMember`
(`:1429`), `AbiCloning.isSingletonHead:871`, `AbiCloning.instanceMember:573`,
`Translate.devirtDirectTarget:2101` (falls to `_ -> no devirt`, correct per
LSS_015/016), `LayoutMap` and everything keyed on it (`layoutHashOf` excludes
`annoHash` by construction, `:507`), and **all of `Generate/MLIR/*`** — every
codegen match binds the annotation with `_` or threads it; there is nothing to
do in the backend.

**1a-T9 — `Registry.getOrCreateSpecIdKeyed:150`.** No code change; **verify**
that the `storedType == storeType` fast path missing on a label difference is
harmless. It falls to `Mono.joinAnnotationsChanged`, which under 1a keep-first
returns `( False, _ )` → `HitNoopJoin` → `storedChanged = False`
(`Engine.elm:1737`). Confirmed by reading, but re-confirm after T5 lands: a
mistake here is the byte-identity gate failing with no other symptom.

**1a-T10 — the census split (report-gated, cheap).**
- `Store.elm:1245-1250` — add `causeUnknown : Int` to `LssZonkAcc` (18 → 19
  fields; not near the cap). Extend the semantics comment at `:1236-1241`.
- `Store.elm:1276` — add `causeUnknown = 0` to the seed literal. **It is one
  very long line inside `zonkToMono`; this is the easiest omission in the
  phase and Elm will catch it.**
- `Store.elm:1655, 1684` — bump `causeUnknown` alongside the existing counter.
- `Store.elm:1347` — add `+ acc.causeUnknown` to `causesTotal`. **If you skip
  this and later stop bumping the old counters, an item whose only readbacks
  were unknowns is skipped entirely and its whole `zc|<gkey>|…` block
  vanishes.**
- `Store.elm:1380-1391` — add `bumpCensusKey "zc|all|unknown"` and
  `bumpCensusKey ("zc|" ++ gkey ++ "|unknown")`. **This is the zero-cost
  route: it needs no new `LssStats` field** (which is at 31/32 —
  `Engine.elm:164`). Do not add a top-level field.
- **`AbiCloningStats`**: add `unknownSiteShapes : Dict String Int` beside
  `topSiteShapes` (`:141`; record is at 27/32), init in `emptyStats`, bump it
  from the new `LUnknown` arm of `stampCall` instead of `topSiteShapes`, and
  render it in `Builder/Generate.abiCensusLines:1184-1272` mirroring the
  `:1266` row. **Trap, previously recorded:** `stampCall` consults EVERY call,
  so these are *site* censuses, not dispatch weight.
- No `unknownHist`. `LUnknown` carries no members and both producing arms call
  `bumpZonkAcc Nothing`; a count is the whole story.

**1a-T11 — no serialisation work. Confirmed NO.** `Mono.MonoType` /
`LambdaSetAnno` is **never** encoded to bytes. `Monomorphized.elm` imports no
codec (`:176-186`) and defines no `encode`/`decode`; the on-disk typed
artifact carries `Can.Type Name` (`Details.elm:1068-1074`,
`TypedOptimized.elm:619+`); `.eco` is untyped `Opt.GlobalGraph`;
monomorphization is strictly downstream of every cache and the only artifact
written after it is MLIR. **Hazard P1-B is closed: no schema bump, no `~/.eco`
invalidation.** (The six grep hits that look like codecs near `MonoType` are
all about compiling *user programs'* `elm/bytes` calls, plus one doc comment.)

**1a-T12 — tests.** These break on exhaustiveness and are mechanical:
`LssHonestSourcesPipelineTest.elm:301-323`, `KernelLicenseTest.elm:682-704`,
`LssSigFlowTest.elm:547-569` (`annoHasSize -> False`, `describeAnnos ->
"LUnknown"`), `LambdaSetIntegrity.elm:120-124` (`LUnknown -> acc`; it
satisfies LSS_002 exactly as `LTop` does — it claims nothing),
`E92ConsDevirtTest.elm:194-200`, `ComparableKeyEncodingTest.elm:662-671`
(`referenceHelper -> "A("`).

These are **assertions**, not fixtures, and need real thought:
`LssSigFlowTest.elm:190, 209, 255, 380` (`anno == Mono.LTop`,
`Expect.equal [ Mono.LTop, Mono.LTop ] …`) and
`LssHonestSourcesPipelineTest.elm:72, 95` (`List.all ((==) Mono.LTop)`). Under
1a the zonk emits `LUnknown` at flex arrows, so these fail. **Do not
"fix" them by widening to `isTopLike`** — first check *which* label the
fixture's arrow gets, because that is free information about whether the
position is poisoned or unwritten, and it belongs in the test's name.

**1a-T13 — extend `ComparableKeyEncodingTest` or T2/T4 are untested.** The two
K4 differential tests are drawn from `pairs`, built from `corpus`, whose
annotations come from `annoAt:553-566` — a **constructor** site that will not
fail to compile and will never emit `LUnknown`. **As written the suite passes
vacuously with a broken `annoHash` or a broken `eqKeyWith`.** Required, in the
same commit:
- `:553-566` `annoAt` → `modBy 5` with an `LUnknown` arm;
- `:352-356` `goldens` → add `( Mono.mFunction LUnknown [ MInt ] MString,
  "A(I->S)" )` — deliberately the *same* golden string as the `LTop` row; that
  literal equality IS the assertion;
- `:373-379` `handwritten` → at least one nested `LUnknown` shape, so the
  `handwritten × handwritten` near-miss block at `:291` contains
  `LUnknown`-vs-`LTop` and `LUnknown`-vs-`LSet` pairs.
- Note the arm-coverage guard at `:~250` will **not** notice a missing arm:
  `LUnknown` emits `"A("`, already present from `LTop`.
- `LayoutQualTest.elm:68-102` — add an `arrowWith Mono.LUnknown` row asserting
  its widened key equals `arrowWith Mono.LTop`'s. Cheap direct pin for T7.

**Gate (1a): BYTE-IDENTICAL.** Two-binary rail on `eco-compiler.mlir` md5,
plus elm-tests (pre-existing-12 only) and E2E 1,687/1,687, plus the ledger
line's `RECONCILES=yes`. Nothing else is admissible — 1a is a pure
representation split. **The ledger's `unknown` bucket must be UNCHANGED from
the T-LEDGER baseline**: 1a relabels a readback, it does not reclassify one.

**Expected non-neutral side effects that are acceptable and must be noted in
the run record:** `Intern.eqExact` (`Intern.elm:225`) is deliberately `==`, so
`LTop`- and `LUnknown`-labelled twins of one structure become two intern
entries **in the same hash bucket** (they share `annoHash`) — table growth and
slightly longer bucket scans, no artifact change. `bumpKeyedHit`'s
identical/noop split moves. Both are census/perf, not output.

### §3.4 PHASE 1b — stop the laundering

**1b-T1 — `Store.monoTypeToVarC:531-567`.** Today the `MFunction` arm builds
`setContent` and mints the slot with `freshVarS (IO.Structure setContent)`
(`:566`). Split it: `LTop` and `LSet` keep that path; `LUnknown` mints
`freshVarS (IO.FlexVar Nothing)` — i.e. **the slot `loadTypeC` mints**
(`Store.elm:195-201`), unwritten. HOP 3 disappears: an unconstrained slot
stays recoverable instead of becoming terminal and absorbing.

Check LSS_007 while here: a `FunL` slot holding a bare `FlexVar` is already
the normal case (`loadTypeC` mints exactly that), so the invariant holds
unchanged — but say so in the commit, because this is the first time the
*demand* path produces one.

**1b-T2 — flip `unionAnno`/`annoCovers` to the 1b lattice of §3.1, IN THE SAME
COMMIT.** Not before (unsound the other way round), not after (unsound in the
window).

**Gates (1b), in this order:**

1. **The §2.5 ledger, all five buckets.** For 1b specifically the expected
   movement is a **RE-LABELLING, not a resolution gain**: `top` falls,
   `unknown` rises by a comparable amount, `concrete` and `k ≥ 2` roughly
   flat. The size of that transfer is **the number this plan exists to
   learn** — predicted from §0's 19:1 gap to be most of the 152,017. A
   `concrete` FALL blocks the phase.
2. `honestSources: topMixedFlex=<sig>/<demand>` — see §3.8. Report both.
3. `joinRounds` / `retranslations` — the height-2 lattice can add one round
   per position. A large rise is a cost to weigh, not a failure.
4. Dispatch census A/B with the `sat + fast` invariance rail. **Gate: no
   fast-coverage regression** against the 22.105% baseline. Coverage is a
   REGRESSION GUARD for this arc, not its objective (§2.5); gains are upside.
5. lss-opt wall A/B: ±1.1% noise floor, ≥3% action band. Majors exact at n=1.
6. elm-tests, E2E both, determinism ×2.

### §3.5 PHASE 1c — the ⊤-writer provenance census (OPTIONAL)

With the split landed, the remaining question is which writers produce the
`top` bucket: {kernel | budget | soundness | honest-∅}. Cheapest shape is to
tag the write at its source, which means `IO.LsTop` gains a provenance byte
(`LsTop Provenance`) and `Unify.elm:751-804`'s absorb arms need a join rule
(e.g. `Poison ∪ Unknown = Poison`, or keep-first).

**Decide after 1b's numbers, not before.** If 1b's `causePoison` collapses to
roughly the attributed ≈7,881 writers, the question is already answered and 1c
is unnecessary. The cheaper partial — a separate cause counter for
`resolveSlotMembers`' honest-∅ landing at `Store.elm:1647` — is independent
and worth doing either way if §3.8 is ambiguous.

### §3.6 RISK — Phase 1b vs LSS_026(a)

**Named because it is exactly the interaction class that has bitten this
register three times.**

LSS_026(a) widens a members-carrying resolution to ⊤ when the edge walk
crossed a *terminal FlexVar* source. Today, HOP-3 poison means many would-be
dangling sources are instead explicit `LsTop`, which `resolveSources` treats
as an absorbing ⊤ (`Store.elm:1811-1812`), NOT as a flex crossing. After 1b
those same sources are flex, so **`topMixedFlex` may rise from its current
0/0**, and each rise is a members-carrying fact widened to ⊤ that previously
resolved.

Both readings are sound. But it means 1b could trade "poison at HOP 3" for
"honest-∅ widening at the resolver" and net nothing — or worse, since the
honest-∅ widening discards *members* where HOP-3 poison merely occupied an
empty slot.

**Measurement, mandatory, before judging 1b:** report `topMixedFlex` (sig and
demand) alongside the ledger. If it rises materially, the finding is that 1b
must be sequenced AFTER Phase 2 — which removes the dangling sources at
source, by connecting them — rather than before. **That would reorder this
plan, and that is an acceptable outcome of Phase 1.** In that case land 1a
(neutral, instrument-only) and hold 1b.

---

## §4 PHASE 2 — arrow identity, and the 11 artifacts

### §4.0 v2 CORRECTION — Phase 2 splits in two, and only 2a is cheap

v1 treated "give `Can.TLambda` an id" as one change. It is two, with very
different cost and very different reach, and conflating them would have
produced a green build that retired two artifacts while the plan claimed
eleven.

| | **2a — occurrence ids** | **2b — solver-root ids** |
|---|---|---|
| id minted | one per syntactic `TLambda` node, in `AssignMVarIds.rewriteCanType` | one per **solver arrow**, keyed `(moduleKey, rootIdx)` like `ensureMVarIdForRoot` |
| shares slots between | **repeated loads of the SAME stamped type object** | **any two type objects the type-checker unified** |
| serialisation | **NONE** — encoder drops the field, decoder supplies `noArrowId` (§4.1). `.elmi` / `typed-artifacts.dat` / `.eco` / `.ecot` byte-compatible, no `~/.eco` invalidation | **artifact format bump required** — `TOpt.GlobalGraph` must carry arrow roots, and they are serialised (`globalSchemeRootsEncoderS` is the precedent) |
| plumbing | `TypeIds` + `Canonical` + one `rewriteCanType` arm + `LoadCtx.arrowMemo` + `ItemAux` | all of 2a **plus** a new lockstep `Can.Type`×solver-`Pt` walk in `SolverRoots`, a new `GlobalGraph` field, and node solver vars plumbed through `Compile.elm` |
| retires | artifacts **#7, #3a** — and **#1, #2, #4a** *iff* EXP-2a passes | **#1, #2, #4a, #6, #8, #9, #10, #11** |

**Why 2a cannot reach the cross-object artifacts.** Eco's existing type
identity is entirely **name-based**: `ensureBinder` (`AssignMVarIds.elm:252`)
resolves `TVar name` through `schemeRootsForDef` → `ensureMVarIdForRoot` →
`rootEnv`, keyed `(moduleKey, rootIdx)`. A def's annotation and its body nodes
share leaf MVarIds because they share binder *names*. **Arrows have no name.**
Under 2a, an annotation's `a -> b` and a node's `a -> b` are two syntactic
occurrences and get two ids — which is precisely the split that
`demandUnifyRoot`/`lssRootAnn` (#1), `bindParamsFromSpine` (#6),
`enrichFromEnv` (#8) and `connectTypes` (#10) exist to bridge.

**Why 2b is the paper's α.** `ℱ(t₁→t₂) = ℱ(t₁) --α--> ℱ(t₂)` assigns α once
per *type*, and the paper's types are already unified when it runs. Eco's
equivalent of "already unified" is the solver's union-find root. Keying arrow
ids on the arrow's own rooted `Pt` index gives exactly the paper's identity —
and the lockstep walker to find it **already exists in skeleton**:
`SolverRoots.walkTypeForBinders:136-163` walks a `Can.Type` against solver
Points and *already destructures the arrow*:

```elm
        Can.TLambda argType resType ->
            case lookupFlatType state rootIdx of
                Just (IO.Fun1 argVar resVar) ->
                    acc |> walkTypeForBinders state argType argVar
                        |> walkTypeForBinders state resType resVar
```

It records leaves only (`:151-153`). 2b is: also record the arrow's own
`rootIdx`, carry it to the mono phase, and consume it in `rewriteCanType`.

**Land 2a first regardless.** It is the type change, the memo, and the
`ItemAux` plumbing — all of which 2b needs anyway — and it is format-safe, so
it can be gated and reverted without a cache rebuild.

### §4.1 The type change

**`TypeIds.elm`** (today ends at `:51`; mirror `LamPh`/`SrcLambdaId` at
`:31-50`):

```elm
type ArrowPh = ArrowPh
type alias ArrowId = Id ArrowPh

firstArrowId : ArrowId
firstArrowId = Id.succ Id.first      -- 1; 0 is reserved

noArrowId : ArrowId
noArrowId = Id.first                 -- 0 = unstamped (pre-AssignMVarIds / non-graph)
```

`Compiler.Data.Id` exposes only `Id, toComparable, first, succ` (`Id.elm:1-44`)
— no `fromInt`, so `noArrowId` must be built from `Id.first`. Reserving 0
avoids a `Maybe` allocation on every arrow node; the AST is walked on the hot
path (`Store.loadTypeC`, `classifyGo`, `zonkToMono`).

**`Canonical.elm:305-312`:**

```elm
type Type id
    = TLambda TypeIds.ArrowId (Type id) (Type id)
    | TVar id
    ...
```

**The id must NOT ride the `id` parameter.** In the `Can.Type Name` phase it
would be a `Name`, and `AssignMVarIds.rewriteCanType` resolves names through
`ensureBinder`, which **interns by name** — every arrow named `"a"` in
`(a -> b) -> a -> b` would collapse into one lambda set. Structural keying is
unsound for the same reason at a different level (two distinct `Int -> Int`
would collapse). Identity is per-occurrence, minted once at creation.

**Serialisation — nothing changes on the wire.** `typeEncoderS`/`typeDecoderS`
are `Type Name` only (`Canonical.elm:613-621`, `:667-677`), and arrow ids are
stamped *after* deserialization, so:

```elm
        TLambda _ a b -> …bytes unchanged…                       -- encoder: emit nothing
        0 -> Bytes.Decode.map2 (TLambda Can.noArrowId) …          -- decoder: supply the sentinel
```

`collectStringsFromType` (`:1533-1539`) needs only a `_` pattern change.
**Hazard D5/H7 is closed for 2a.**

**Blast radius.** 89 `Can.TLambda` sites in `compiler/src`, ~119 in
`compiler/tests` (36 in `tests/Compiler/Elm/Interface/Basic.elm`, 29
`Bytes.elm`, 21 `List.elm`, 21 `Monomorphize/TypeSubst.elm`, 15 each
`Tuple.elm`/`JsArray.elm`, 13 `LocalOpt/Typed/Port.elm`). Provide a smart
constructor and route every *construction* site through it, so a future id
policy is one edit rather than 200:

```elm
tLambda : Type id -> Type id -> Type id
tLambda = TLambda noArrowId
```

Pattern sites take a `_`. Test fixtures already have local helpers to route
through (`tests/Compiler/AST/CanonicalBuilder.elm:346, 392`). `Src.TLambda` is
a different constructor and is unaffected.

**The MonoSolver never CONSTRUCTS `Can.TLambda`** — all 21 occurrences across
`Translate`/`LssInfer`/`Store`/`Zonk`/`KernelSetFacts` are pattern matches.
**Therefore no `S`-resident arrow-id supply is needed, and none should be
added** (`S` is at the 32-slot cap). Do not speculatively add `Id.fromInt`.

### §4.2 PHASE 2a — work order

**2a-T1 — `TypeIds.elm`**: `ArrowPh`, `ArrowId`, `firstArrowId`, `noArrowId`;
export them.

**2a-T2 — `Canonical.elm`**: the constructor, the `tLambda` smart
constructor, encoder `_`, decoder `Can.noArrowId`, `collectStringsFromType`.
Then fix the ~200 mechanical sites; `Utils/Type.dealiasHelp`/`deepDealias`
(`:63-92`, `:105-119`) rebuild `Type Name` and must **preserve** the id.

**2a-T3 — `AssignMVarIds.GlobalMVarState` (`:29-35`)**: add
`nextArrow : TypeIds.ArrowId`. **Two record literals must be extended** — Elm
requires completeness and neither is near the other:
`assignIds:114-123` and the inline one-liner in `assignIdsToType:145`.

**2a-T4 — `freshArrowId`**, inserted after `freshLamId` at `:88`, keeping the
`Ctx`-in/`Ctx`-out shape so the consuming arm stays a plain state thread.
There is **no label side table**: `lamLabels` exists only for census rendering
and has no arrow analogue.

```elm
freshArrowId : Ctx -> ( TypeIds.ArrowId, Ctx )
freshArrowId ctx =
    let st = ctx.state
        arrowId = st.nextArrow
    in
    ( arrowId, { ctx | state = { st | nextArrow = Id.succ arrowId } } )
```

**2a-T5 — `rewriteCanType`'s `TLambda` arm (`:1052-1060`)**:

```elm
        Can.TLambda _ from to ->
            let ( arrowId, ctx0 ) = freshArrowId ctx
                ( newFrom, ctx1 ) = rewriteCanType ctx0 from
                ( newTo,   ctx2 ) = rewriteCanType ctx1 to
            in
            ( Can.TLambda arrowId newFrom newTo, ctx2 )
```

**Mint PRE-order (before descending) and document it.** `loadTypeC` mints its
slots *post*-order (`Store.elm:186-201`). The two orders are independent —
the ordinal contract is defined by `arrowSlots`, not by id order — but pick
one deliberately, because a future id-keyed `ArrowFact` (§4.7-#11) wants a
stable walkable order.

**No seed into `S`.** `MonoSolver/Monomorphize.initState:303-317` reads
`mvarState.nextId` and `mvarState.nextLam`; `nextArrow` needs no analogue
(§4.1).

**2a-T6 — `Store.LoadCtx` (`:69-76`)**: add

```elm
    , arrowMemo : Dict.Dict Int IO.Variable   -- Id.toComparable arrowId -> that arrow's FunL SET SLOT Point
```

**Memoise the SET SLOT ONLY, never the `FunL` node.** The structure point must
still be minted per load: `from`/`to` can resolve to different Points on
different loads (leaf-memo differences, alias binding in the `TAlias Holey`
arm at `:242-274`). Sharing the node would union unrelated argument types.
*(This settles v1's D3: slot-only. GAP-2's arg flow is a Phase-2b/#8 question,
not a reason to share the node.)*

**2a-T7 — the `Can.TLambda` arm of `loadTypeC` (`:186-204`)**:

```elm
        Can.TLambda arrowId from to ->
            let ( pFrom, c1 ) = loadTypeC superStatic from c0
                ( pTo,   c2 ) = loadTypeC superStatic to c1
            in
            if c2.lssOn then
                let akey = Id.toComparable arrowId in
                if akey == 0 then
                    -- noArrowId: unstamped. ALWAYS miss, NEVER record —
                    -- otherwise every unstamped arrow in a type collapses
                    -- into one slot.
                    mintFresh c2
                else
                    case Dict.get akey c2.arrowMemo of
                        Just pSet ->
                            structC (IO.FunL pFrom pTo pSet)
                                { c2 | arrowSlots = pSet :: c2.arrowSlots }
                        Nothing ->
                            let ( pSet, c3 ) = freshVarC (IO.FlexVar Nothing) c2 in
                            structC (IO.FunL pFrom pTo pSet)
                                { c3 | arrowSlots  = pSet :: c3.arrowSlots
                                     , slotsMinted = c3.slotsMinted + 1
                                     , arrowMemo   = Dict.insert akey pSet c3.arrowMemo }
            else
                structC (IO.Fun1 pFrom pTo) c2      -- lss off: byte-identical
```

`Store.elm` already imports `Compiler.Data.Id as Id` (`:43`).

### §4.3 The memo contract — the subtle part, and LSS_006's amendment

| event | `arrowSlots` | `slotsMinted` | `arrowMemo` |
|---|---|---|---|
| miss (lss on) | **push** | **+1** | **insert** |
| **hit (lss on)** | **push** | **unchanged** | unchanged |
| `noArrowId` (lss on) | push | +1 | **never insert** |
| lss off | untouched | untouched | untouched |

`arrowSlots` is reversed minting order and becomes the ordinal array at
`Store.elm:114` and `:139`; `LssInfer.applyFacts:209-218` pairs
`Array.get i facts` with `Array.get i slots` and poisons the whole
instantiation on a length mismatch (`Store.poisonArrowSets`, `:1080`) —
**silently**, since `censusLenGuard:226-231` is report-gated.

- A hit that **skipped** `arrowSlots` shortens the array → whole
  instantiations poisoned.
- A hit that **bumped** `slotsMinted` corrupts `lssStats.slotsMinted`, which
  is a *mint* counter feeding the dead-slot census.

**New, and expected:** the ordinal array can now contain the **same Point
twice**. Nothing in `applyFactsGo` or `repOrdinal` (`LssInfer.elm:1087-1106`)
breaks — `repOrdinal` already reports the smallest UF-equivalent ordinal — but
`LssSignature.trivial` goes false more often (two ordinals share a rep),
reducing the `trivial` short-circuit rate at `:211`. **Expect a small
compile-time cost and do not misread it as a precision change.**

**LSS_006 amendment text:** *arrow ordinals are still defined by position in
`loadTypeWithArrows`'s array; what changes is that a position may reuse a slot
minted by an earlier position of the same load. Ordinals count POSITIONS, not
MINTS.*

### §4.4 Entry-point asymmetry — the single most dangerous mistake available

`arrowMemo` must persist across loads *within one item*, so it lives in
`ItemAux` (§4.5). The four entry points differ exactly as they already do for
`memo`:

| entry point | line | `memo` | `arrowMemo` seed | write back? |
|---|---|---|---|---|
| `loadType` | `:79` | `s.memo` | `s.itemAux.arrowMemo` | **yes** |
| `loadTypeWithArrows` | `:106` | `s.memo` | `s.itemAux.arrowMemo` | **yes** |
| `loadTypeIsolatedWithArrows` | `:131` | `Dict.empty` | **`Dict.empty`** | **NO** |
| `loadTypeIsolated` | `:159` | `Dict.empty` | **`Dict.empty`** | **NO** |

The two isolated entries are *fresh per-call-site instantiations*
(`:127-130`, `:152-157`), and they already omit `memo` from their write-back
(`:141`, `:148`). **H1, the collapse hazard:** `sigSourceTypeFor`
(`LssInfer.elm:188-195`) and the call path read the **same annotation value**
out of `s.env.annotations`. Threading the arrow memo into the isolated loads
would make **every call site of an annotated `f` unify into one lambda set** —
monomorphic set analysis, maximal imprecision, and `applyFacts` degenerates to
self-unification. Put the asymmetry in the doc comment, not just the code.

`loadType`'s write-back becomes (both branches):

```elm
    { s | store = c.store, memo = c.memo, revMemo = c.revMemo
        , itemAux = let aux = s.itemAux in { aux | arrowMemo = c.arrowMemo } }
```

`classifyDirect`/`classifyGo` (`:2040-2043`, `TLambda` at `:2080`) is
storeless and mints no slots — `_` pattern only.

### §4.5 `ItemAux` plumbing — H3, a silent miscompile if missed

`Engine.ItemAux:988-995` gains

```elm
    , arrowMemo : CoreDict.Dict Int IO.Variable
      -- ArrowId -> that arrow's set slot Point IN THIS ITEM'S STORE.
      -- Store-scoped: MUST be cleared on every store swap.
```

Four edits, and the two middle ones are the load-bearing pair:

1. **`emptyItemAux:998`** — `arrowMemo = CoreDict.empty`. This is also what
   makes `resetItem:1822` correct (it assigns `itemAux = emptyItemAux`), but
   verify it: a per-item store is a fresh `IO.State`, and stale entries would
   name Points in a destroyed store.
2. **`clearedAux:1007-1009`** — must clear it:
   `{ aux | ecoResidualReads = [], ecoResidualKeyReads = [], arrowMemo = CoreDict.empty }`.
   **Without this**, `LssInfer.inferUnit`'s
   `Engine.withScratchStore (inferUnitInScratch members)` (`LssInfer.elm:348`)
   enters the scratch store carrying the item's arrow→Point map;
   `loadMemberSlots:561-573` then hits and returns **item-store Points inside
   the scratch store**. Point indices are dense from 0 in *both* stores
   (`Engine.elm:954`; the identical hazard is recorded verbatim at
   `Translate.elm:4612-4615`: *"leaking them aliases low outer point indices
   and livelocks the saturation loop"*). `zonkSigGo:724-839` then bakes
   garbage `LambdaSet1` content into a memoised `LssSignature` that survives
   the whole run (`S.lssSignatures` is GLOBAL, `Engine.elm:929`). **Silent
   miscompile, not a crash.**
3. **`restoredAux:1016-1018`** — must restore the outer map:
   `{ inner | …, arrowMemo = outer.arrowMemo }`. Symmetric hazard outward.
4. **`clearResidualReads:1021-1030` must NOT clear it** — the saturation pass
   re-translates against the *same* store, so the Points are still valid;
   clearing would silently re-mint and lose sharing mid-item.

`withScratchStore:1462-1483` itself needs no change — it routes through the
two helpers. **But there is a second, hand-rolled scratch boundary:**
`Translate.retranslateAt:4608-4626` inlines the same stash/restore and also
calls `Engine.clearedAux`/`Engine.restoredAux`. It is fixed by the same two
edits **only if you edit the helpers rather than inlining the clear at the
`withScratchStore` call site. Do not inline.**

`S` gains no top-level field, so H2 (the 32-slot cap) is respected.

### §4.6 The structural comparators — the silent-regression surface

**D10/H4/H5/H6.** Four sites; three are mechanical and one is a real decision.

**(a) `Translate.classifyLambdaHead:1436` — `if annCanType == canType`.**
A whole-tree Elm `==` over `Can.Type MVarId`. Under per-occurrence arrow ids
the annotation and the node type carry different ids, so **this equality can
silently become always-false, `lssRootAnn` switches off, and the change
regresses exactly the case it exists to fix.** This is the likeliest way to
land a green build with a large precision loss.

Preferred fix: **delete the mechanism** (artifact #1, §4.7). Interim fix if #1
is staged later: an id-blind comparator — and **there is no such helper
today**. Write one modelled on `LssInfer.canTypeMentionsArrow:2603-2634`,
which already enumerates all seven arms including both `TAlias` forms. A
two-arm version with an `_ -> a == b` fallback is **wrong**: arrows hide under
`TType`/`TRecord`/`TTuple`/`TAlias`.

**(b) `KernelSetFacts.sameType:551-567` — mechanical `_`,** but say why out
loud in review. The function is already structural (destructure and recurse,
never `==` on a node), so binding ids to `_` preserves behaviour exactly. It
is called from `matchShapeGo:490` with `id = MVarId` in production, where
occurrence types **do** carry distinct arrow ids. Anyone who "fixes" the
compile error by *comparing* the ids silently kills the `TsVar` consistency
check for every function-typed binding and un-licenses `TypeFaithful` kernel
rows. The strict-identity rule at `:537-549` is about `TVar` (solver
identity); it does **not** transfer to arrows (occurrence identity).

**(c) `PostSolve.unifyHelp:990` — mechanical `_`.** Structural, no node `==`.
The whole-tree `==` at `:976-981` (`if existing == t`) is over
`Can.Type Name`, which under 2a always carries `noArrowId`, so it is
unaffected. **Record this as an invariant** — *arrow ids are minted only in
`AssignMVarIds`; every `Can.Type Name` carries `noArrowId`* — because if 2b
ever stamps earlier, `:977` becomes a real bug needing the (a) treatment.

**(d) `PostSolve.applySubst:1105-1106` — PRESERVE the id**
(`Can.TLambda aid arg res -> Can.TLambda aid …`), don't re-mint: there is no
supply threaded here, and preservation is what stays correct if ids are ever
stamped earlier. The `TVar` arm at `:1098-1100` is the one to watch under
earlier stamping — `Dict.get v subst` splices one substituted type object into
multiple positions, cloning its arrow ids. Third `TLambda` in the file at
`:1144` is mechanical.

### §4.7 The four post-`AssignMVarIds` construction sites

| site | fresh id from | verdict |
|---|---|---|
| `Analysis.convertCanTypeNameToMVarId:477-489` | **`Can.noArrowId`** | Provably safe: three callers, all subst-engine (`Analysis:462`, `Specialize:4922, 4989`) except `Translate.instantiateUnionType:5812-5833`, whose output goes to `Zonk.canTypeToMonoWithI` (storeless) and **never reaches `Store.loadType`**. Record that as an invariant; §4.2's `akey == 0` guard keeps it sound if violated. Also update the alias arms at `:529-538`. |
| `TypeSubst.buildCurriedCanType:1592-1602` | **`Can.noArrowId`** | New arrow spine (partial-application residual, sole caller `:1498`); no original id exists. Subst engine only. |
| `Specialize.buildFuncType:5321-5328` | **`Can.noArrowId`** | New spine, subst engine only (sole caller `:4643`). |
| **`TypeSubst.renameMVarIdsInCanType:1262-1283`** | ⚠️ **CLONES — see below** | |

**The clone hazard, stated precisely.** `renameMVarIdsInCanType` exists to
*freshen* (`buildSchemeInfo:1124-1153`, `refreshSchemeInfo:1160-1189`, whose
doc says it "prevents stale MVar bindings … from leaking into a new call site
that reuses the cached scheme"). Cloning arrow ids into the "fresh" copy is
the same defect one level up: an `arrowMemo` load would resolve the original
and the instantiation to **one slot**, i.e. every call site of a cached scheme
shares one lambda set.

**It is inert today**, because `Compiler/Monomorphize/TypeSubst.elm` is the
**subst engine**: nothing under `compiler/src/Compiler/MonoSolver/` imports
it, and the subst engine has no `Store` and no `arrowMemo`. **So ship it as a
preserve/`_` change with a loud comment and an invariant row:**

> `renameMVarIdsInCanType` CLONES arrow ids. Sound only while its output never
> reaches `Store.loadType*`. The moment the solver routes through it — or this
> helper is reused for solver-side instantiation — it must thread an `ArrowId`
> supply and mint fresh ids per `TLambda`, or every "fresh" instantiation
> aliases its arrow set slots to the original's.

If it ever must freshen: the supply's natural home is `MVarEnv`
(`Monomorphize/State.elm:90-93`), which is already threaded through both
callers and already carries the MVarId supply — add `nextArrow`, mirror
`State.freshMVar:108-126`, seed from `GlobalMVarState.nextArrow` in
`initMVarEnv:98-102`, and change the signature to return `( Can.Type MVarId,
MVarEnv )`. That touches `buildSchemeInfo`, `refreshSchemeInfo` (three call
sites `:1173, 1176, 1179`), and `Monomorphize.elm:1302` / `Translate.elm:4124`.

Pre-mono constructors (`Canonicalize/*`, `LocalOpt/*`,
`Type/KernelTypes.elm:89`, `Type/KernelIntrinsics.elm:166-198`,
`Elm/Docs.elm:843`, `AST/Utils/Type.elm:67, 109`) all build `Can.Type Name`
before `AssignMVarIds` and take `tLambda`.

### §4.8 EXP-2a — the experiment that decides the artifact schedule

**Run this immediately after 2a is green, before removing anything but #7 and
#3a.**

The question is whether a def's stashed `defType` and its body `Function`'s
`meta.tipe` are structurally-equal *distinct objects* or literally the same
value. Elm has no reference equality, so the code cannot tell you; the
measurement can.

**Method.** Add a temporary report-gated counter at
`Translate.classifyLambdaHead:1436` counting how often the
`annCanType == canType` guard **fires**. Measure at HEAD, then under 2a
flag-on. If it collapses to ~0, the two are distinct objects, 2a does not
reach them, and **#1/#2/#4a require 2b**. If it holds, they are shared and 2a
closes them.

**Do not skip this and infer from a coverage number.** This session refuted
three confident attributions built on aggregate counters.

**Artifact retirement schedule** — honest verdicts, least-coupled first:

| # | artifact | verdict | prerequisite |
|---|---|---|---|
| **7** | the A.1 fresh load at `unifyParamsBestEffort:1542` | **2a** — and probably a *no-op edit*: with slots memoised, a second `loadType (TOpt.typeOf arg)` in the same ctx is idempotent. **Verify by asserting `Engine.pointKey` equality across two loads before deleting anything.** | — |
| **3a** | `injectArgLambdaMember`'s two lambda arms (`Translate.elm:3505-3510`) | **2a** — both sites load the same object (`argUnifyVar:3465-3483` vs `specializeLambda:1357-1410`). Its own doc at `:3486-3494` names LSS_006 as the reason it exists. | — |
| **1** | `demandUnifyRoot` + `itemAux.lssRootAnn` + the `classifyLambdaHead` stash | 2a **iff EXP-2a passes**, else 2b | EXP-2a |
| **2** | the lss-on TailDef branch (`Translate.elm:1186-1251`) | with #1 — it consumes `demandUnifyVar`'s var directly at `:1192` | #1 |
| **4a** | `overlayAnnotations` at `:1213, 1227` | with #2 | #2 |
| **10** | `connectTypes`' **arrow half** only (`:132-145` + 11 callers) | **2b** | 2b |
| **8** | `enrichFromEnv`'s **set-carrying half** (`:3606-3611`) | **2b** | 2b |
| **9** | `enrichLocalMultiUses` (`:5418-5472`) | **2b, and only half** — see below | 2b |
| **6** | `bindParamsFromSpine` + the `letEnv` it threads | **2b** | 2b |
| **5** | the whole `joinArrowSets`/`flowArrowSets` block | **LAST** — it is the terminal consumer of #6/#8/#9/#10 | all of the above |
| **11** | the ArrowFact encoding | **partial** — see below | 2b |
| **3b** | `standaloneArgMember` / `standaloneArgKernelMember` (`:3512-3576`) | **DOES NOT DIE.** Nothing else injects a member for a standalone value passed as an argument (`translateVarRef:1502-1516` does not). Depth contract pinned to `LssInfer.spineDepthForGlobal` (`:3555-3557`). | — |
| **4b** | `overlayAnnotations` at `:1484, 2409, 5462` | **DOES NOT DIE.** `:1484` is a number/alias/structure fidelity guard (`:1473-1478`: "the store zonk contributes ONLY the lambda-set annotations"); `:2409` overlays onto a **storeless** classify (`Store.classifyDirect:2040-2043`) which reads no slots at all. | — |

**#5's exact extent**, verified as contiguous top-level definitions in
`LssInfer.elm`: **2237-2587** (`joinArrowSets` 2237-2331, `joinArrowSetsSig`
2334-2340, `flowArrowSets` 2343-2427, `degradeToSymmetric` 2430-2448,
`storeMentionsArrow(Go)` 2451-2504, `flowArrowSetsSig` 2507-2512,
`flowArrowSetsPlain` 2515-2520, `sigFlowJoinInto` 2523-2536,
`joinArrowSetsList` 2539-2551, `joinArrowSetsPairs` 2554-2566, `poisonBoth`
2569-2587) **plus 2739-2752** (`flowAllSig`). **KEEP** `canTypeIsArrow`
(2590-2600) and `canTypeMentionsArrow` (2603-2634) — used elsewhere, and (b)
is the model for §4.6(a)'s comparator. Call sites: `joinLetUse:2226` (whose
body becomes vacuous), `joinCfHub:2707`, `walkFunction:1404`,
`walkMembers:633`, the `Let` arm `:1260, 1296`, `localCalleeJoin:1598`,
`joinCallArgs:1650`, `:1855/:1858`, exports `:10-11` and `:1871-1873`. **Plus
one cross-module consumer that will break the build if forgotten:**
`Translate.joinKernelTunnels:3940-3960`, which selects between the two at
`:3951`/`:3954`.

**#9 is only half-dead even under 2b.** `enrichLocalMultiUses` bridges
per-use instantiations to a per-instance re-translated RHS produced by
`retranslateAt:4608-4626` — which runs in a **separate scratch store with
`arrowMemo` cleared** (§4.5). Points cannot cross that boundary by
construction, so the graph-level annotation overlay remains the only channel.
Arrow ids remove the mismatch *within* one instance's translation, not across
the scratch boundary. **Keep it; measure what it still patches.**

**#11 breaks into four independent questions.**
- *(a) Key `ArrowFact` by id instead of ordinal?* **Only for the annotated
  population.** Both sides source through `sigSourceTypeFor:188-195`; when the
  global HAS an annotation both get literally the same `Can.Type MVarId` out
  of `s.env.annotations` ⇒ identical ids ⇒ id-keying pairs exactly, no length
  guard. When it does **not**, the signature side uses the node's own type and
  the caller side the use-site `funcMeta.tipe` (`Translate.elm:1560-1567`) —
  different objects under any policy. So: `{ arrow : ArrowId, … }`, **pair by
  id when both sides are stamped and the id sets intersect, else fall back to
  positional-with-length-guard. Do not delete the positional path.**
- *(b) `fact.rep`* **stays.** It encodes that *two different arrows* were
  unified by the body (`twice : (a -> a) -> a -> a`) — a different relation
  from "the same arrow loaded twice". It should become an `ArrowId` rather
  than an ordinal, not disappear.
- *(c) `applyFacts:214`'s length guard* **can go on the id-keyed path.** A
  miss means "no fact for this arrow", which is sound: an unconstrained
  `FlexVar` slot reads back ⊤ at zonk (`Store.elm:195-196`), so a dropped
  `top=True` costs nothing and a dropped `members`/`rep` costs precision only.
  Retain it for the positional fallback. The `sig.trivial` short-circuit
  ordering at `:201-207` stays.
- *(d) `selfIdOf:585`* — **I could not show that this dies, and the plan
  should stop claiming it does.** Its doc `:576-584` gives two reasons, both
  about **member ids**, not arrow ids; and the second ("an unfiltered self-id
  makes EVERY ≥1-param def's signature nontrivial, killing the `trivial`
  short-circuits") gets *worse* under §4.3's shared-rep prediction. **Keep it.**

**And an unconditional constraint that survives all of Phase 2:** signature
inference runs under `withScratchStore` (`LssInfer.elm:348`), whose store is
discarded at `:1483`. An `LssSignature` must remain a **store-independent
value of Ints and Bools**, which it already is. Stable arrow ids let the two
sides *name* the same arrow; they do **not** let a signature hold Points. The
zonk-out (`zonkSigGo:724-839`) / re-apply (`applyFactsGo:234-290`) copy stays
exactly as it is. Reading "arrows have stable ids now" as "signatures can hold
Points" reintroduces §4.5's leak.

### §4.9 PHASE 2b — solver-root arrow ids (DESIGNED, NOT LOWERED)

Do not start 2b until 2a is green and EXP-2a has been run. Sketch, with the
one blocker named:

1. **`SolverRoots`** — extend `walkTypeForBinders:136-163` (or add a sibling)
   to emit, in a fixed pre-order, the rooted `Pt` index of every `TLambda` it
   reaches in lockstep, with a hole where the lockstep walk loses the solver
   var (alias/mismatch arms).
2. **`Compile.elm:326-348`** — this is where `solverState` is live and where
   `normalizeNodeVars` already gives every node its rooted var; run the walk
   for each def's annotation **and** each node type.
3. **THE BLOCKER: `TOpt.GlobalGraph` (`TypedOptimized.elm:421-422`) carries
   `SchemeRootsByGlobal` and nothing else about solver Points — node solver
   vars die in `Compile.elm`.** 2b therefore needs a new `GlobalGraph` field,
   and it must be **serialised** (`globalSchemeRootsEncoderS:1685` is the
   precedent, and its `(moduleKey, rootIdx)` scoping is required because each
   module's solve numbers `Pt` from zero). **⇒ artifact format bump ⇒ full
   `~/.eco` rebuild across every dev and CI machine.** This is the cost 2a
   avoids and 2b cannot.
4. **`AssignMVarIds`** — `ensureArrowIdForRoot`, an exact mirror of
   `ensureMVarIdForRoot:220-245` over a new
   `arrowRootEnv : Dict ( String, Int ) ArrowId`, consuming the emitted list
   in the same pre-order `rewriteCanType` walks. **The emit and consume walks
   must agree exactly**; that discipline is the same one
   `loadTypeWithArrows`'s ordinal contract already lives under, and it is
   testable directly.
5. Cross-module sharing is **impossible and not a goal**: `f`'s annotation
   read from an interface and a use site in another module are not the same
   solver arrow. Within-module (a def's annotation vs its own body nodes) is
   the whole prize, and it is exactly what artifacts #1/#6/#8/#10 hand-code.

### §4.10 Remaining hazards

- **H8 — poison blast radius.** Today a kernel/port/Debug crossing poisons one
  fresh instantiation. Under an item-shared memo it poisons the shared slot
  for **every other use of that type in the item**. ⊤ is absorbing and
  monotone, so this is a precision cliff, not a soundness break — but it reads
  as "flat or worse" and is hard to attribute afterwards. **Watch
  `causePoison` against `causeFlex`/`causeUnknown`: the phase succeeds only if
  unknown falls by more than top rises.**
- **D9 — `trivial`-signature mass shift.** Construction-time UF equivalence in
  `repOrdinal`/`ordinalOf` moves; there is a measured 60%-of-grounding
  precedent for this class. Report `signatures: N memoized (M trivial)` in
  every arm.

### §4.11 Gates

Flag-gate the whole phase (`lss.arrowIdentity`, default off) so the two-binary
byte-identity rail applies; then, per artifact removed, one at a time:

1. flag-off byte-identity (two-binary rail);
2. flag-on determinism ×2;
3. **the §2.5 ledger — the phase's headline gate.** `unknown` must FALL and
   `concrete` must RISE. §2.5.4's disambiguator applies: `k ≥ 2` rising while
   `k = 1` falls comparably and `unknown` is flat is POLLUTION, and the phase
   has failed even if the headline looks good. Report `sig|allflex` alongside
   — the producer decomposition is the ceiling and this is the change that
   should move it — and `multiSetSites` (§2.5.3), which no gate depends on but
   which is the first thing that could make sum lowering's feedstock non-zero;
4. `topMixedFlex` should fall to 0 and stay (the dangling sources LSS_026(a)
   guards against are *connected* now, not widened over);
5. dispatch census A/B with the `sat + fast` invariance rail — **gate: no
   fast-coverage regression** (a guard, not the objective);
6. `declinedNoInstance` watched, not feared (§5.2 Q4 explains why it may rise);
7. elm-tests, E2E both arms, MONO_030 quiet, poly-rec fixture still
   watchdog-aborts;
8. per-artifact: each of §4.8's removals must be individually byte-neutral
   flag-off and individually measured flag-on. **Do not remove them in one
   commit** — attribution is the whole value.

### §4.12 Tests

**Semantic pins that will move** (treat movement as a signal, not a fixture
chore): `LssSigFlowTest.elm` (832 lines, six cases keyed on stored keyed-demand
annotations — **case 3, the `apply f x = f x` negative control that flag-on
demands are IDENTICAL to flag-off, and case 4, `pick b g = if b then inc else
g 0` must be `LTop` and never a singleton, are MISCOMPILE pins: any change
there is a red flag, not a fixture update**); `LambdaSetIntegrity(Test).elm`
(LSS_002 totality — the best whole-pipeline check that slot sharing has not
lost a member); `MuTieTest.elm`; `KernelLicenseTest.elm` (transport pins 1-2
depend on §4.6(b) still *matching*; if they go red, someone compared the ids);
`LssGroundingTest`, `LssHonestSources(Pipeline)Test`, `LayoutQualTest`,
`PostSettleDevirtTest`, `AbiCloningFenceTest`, `BorrowFenceTest`; the CodeGen
devirt suite (`E2V2StagedDispatchTest`, `E5KeyedDispatchTest`,
`E92ConsDevirtTest`, `E9CtorDevirtTest`, `SpinePapDispatchTest`) — **a lost
member there is a precision regression; a spurious member is a miscompile**;
and the `test/elm/src/Lss*` E2E fixtures.

`LssDirectedFlowTest.elm` builds its store by hand with `UF.set` and is
**unaffected** by 2a — it needs updating only when #5 is removed.

**Nothing anywhere pins arrow ordinals by name or number, and nothing pins
`lssRootAnn` or signature triviality directly** — which is why EXP-2a
(§4.8) is not optional. Three tests to ADD, none of which exist:

- **the ordinal contract (§4.3):** load a type with two `TLambda`s sharing one
  `ArrowId` via `loadTypeWithArrows`; assert `Array.length slots == 2`, both
  entries UF-equivalent, and `lssStats.slotsMinted` up by exactly **1**;
- **the isolation asymmetry (§4.4):** two `loadTypeIsolatedWithArrows` of the
  same type return **disjoint** slot Points and leave `s.itemAux.arrowMemo`
  untouched;
- **scratch-store isolation (§4.5):** around `Engine.withScratchStore`, an
  inner load must not hit an outer entry, and the outer `arrowMemo` must be
  unchanged on exit.

---

## §5 PHASE 3 — the set variable (OUTLINE)

### §5.0 This is not a work order

Phase 3 is designed only to the point of naming its open questions. It is
recorded here so the arc is legible, not so it can be started. **Do not
implement §5 from this document.** It needs its own plan, written after Phase
2's numbers exist.

### §5.1 The change in principle

`LambdaSetAnno` gains a variable, and `LUnknown` retires into it:

```elm
type LambdaSetAnno
    = LTop                 -- genuine: kernel, budget, soundness fallback
    | LVar SetVarId        -- deferred: a ∀-parameter the caller must ground
    | LSet (List Int)
```

Then the paper's three properties become reachable:

1. **Signatures fully flexible** — every set position in a stored signature is
   a variable, never a concrete set. This makes "concrete ∼ concrete"
   unreachable, so **no join operator is needed anywhere** — including §3.1's
   awkward `LUnknown ∪ LSet = LTop` arm, which exists only because `LUnknown`
   is a commitment and a variable is not.
2. **Propagation by unification** — with Phase 2's shared arrow identity, sets
   ride the type and tie as a byproduct. `Unify.elm:732-736` already
   sub-unifies `FunL` slots; the machinery exists and simply never fires
   between two loads today.
3. **Unknown deferred UP, not committed DOWN** — `monoTypeToVarC` encodes
   `LVar` as a fresh slot (Phase 1b already does this for `LUnknown`);
   internalization at the def boundary takes the **minimal** solution
   (default ∅ — bottom, not top).

### §5.2 The open questions — all genuinely open

- **Q1 — where does the deferral bottom out?** The paper terminates because
  the program is whole-program, topologically ordered, and the entry point's
  type contains **no arrows** (AT-Entry). Eco's monomorphizer is
  **demand-driven and interleaved** — the fidelity mapping calls this "the
  deepest legitimate divergence". What is Eco's analogue of a closed root, and
  does the LSS_010 dirty-flush fixpoint substitute for reverse-dependency-order
  specialization? **This is the question Phase 3 lives or dies on.**
- **Q2 — variables in spec keys.** Keying by annotated type IS lambda-set
  specialization (`enqueueSpecKeyed`). What does a *variable* in a key mean?
  Two demands differing only in a variable must key together, or fan-out
  explodes; if they key together, what grounds the variable? (Phase 1's
  `annoKeyEq`, §3.3-T4, is the degenerate one-variable case of this.)
- **Q3 — the consumer is still singleton-only. ACCEPTED, 2026-08-24.**
  `maxSetSize` 8/16/32 gives a byte-identical compiler and every devirt arm
  requires `|set| = 1`, so a perfectly resolved 2-set buys nothing at runtime
  today. **Accepted rather than blocking**, on the explicit condition that
  progress is measured by the §2.5 resolution ledger — `unknown` falling,
  `concrete` and `k ≥ 2` rising — which needs no consumer. Sum lowering
  (`plans/lss-sum-lowering.md`) arrives later and turns the ledger into
  runtime; `multiSetSiteHist` (§2.5.3, **zero today**) is the row that tells
  us when it would have something to consume. Note the register's GAP-6 NO-GO
  was argued as "multi-member sets don't form" — 544 DO form; what is zero is
  multi-sets *at call sites*. Correcting that conflation is a precondition for
  re-opening sum lowering honestly.
- **Q4 — raw vs qualified member ids.** The inference walk mints **raw**
  `injectLambdaMember`, not `…Qualified`, so signature-transported `l|` ids
  arrive at AbiCloning with no closure instance carrying that id and decline
  as `noInstance`. That is the measured cause of D1/D2's `devirtDirect`
  staying flat at 4,453 — and it will bite Phase 3 identically unless
  LSS_017-v2 (`plans/lss-fork-qualified-members.md` §8) lands first.
- **Q5 — µ.** The paper needs a lambda-set-level `µ` for variables occurring
  free in their own constraints (recursive/iterative control flow). Eco severs
  set-in-own-identity with id-only members (`widenSets`). Does the variable
  form re-import the need?

---

## §6 Risks

1. **Phase 1b trades HOP-3 poison for honest-∅ widening** and nets nothing, or
   worse. Owned by §3.6's mandatory measurement; the acceptable outcome is
   landing 1a alone and reordering 1b after Phase 2.
2. **Phase 1a is not byte-identical** because one of §3.3's T2/T4/T5/T7/T9
   was missed. T2 and T4 both compile cleanly when wrong and both produce the
   same symptom (duplicate SpecIds → `MONO_030` breadth). Mitigation: T13
   makes `ComparableKeyEncodingTest` non-vacuous **in the same commit**.
3. **Phase 2a lands green and silently regresses** via §4.6(a) — the `==`
   comparator switching `lssRootAnn` off. Mitigation: EXP-2a's counter is
   added **before** the AST change, so the HEAD baseline exists.
4. **Phase 2 claims eleven artifacts and delivers two.** Owned by §4.0/§4.8:
   the schedule now states per-artifact prerequisites, and #3b/#4b/#11(d) are
   marked as NOT dying at all.
5. **Phase 2's poison blast radius** (H8) converts kernel boundaries from
   local to item-wide.
6. **2b forces a full artifact rebuild** (§4.9 step 3) across every developer
   and CI machine. 2a does not — keep them separately revertible.
7. **The consumer cap makes all of it worthless at RUNTIME** (Q3) — accepted,
   with the §2.5 ledger as the substitute objective. Residual risk: the ledger
   improves and runtime never follows because sum lowering proves infeasible.
   Mitigated only by tracking `multiSetSiteHist` throughout, so the feedstock
   question is answered with data before that plan is written.
8. **Scope creep into Phase 3.** §5 is an outline. "Just add the variable
   while we're in here" during Phase 2 must be resisted — it is the change
   with the least-understood interaction surface.

---

## §7 Non-goals

- Sum lowering (`plans/lss-sum-lowering.md`) — the consumer that would make
  multi-member precision worth an instruction. Phase 3 depends on it; this
  plan does not attempt it.
- LSS_017-v2 / raw→qualified bridging (`plans/lss-fork-qualified-members.md`
  §8) — a Phase 3 prerequisite (Q4), not Phase 1/2 work.
- Removing kernel poison or the budget. **Explicitly kept** (§0).
- The PAP argument-member transport
  (`plans/lss-pap-argument-members.md`) — 2,475 sites, but the combinator
  families carry 1.1% of dispatch heat on this workload.
- Re-adding any call-argument transport layer. LSS_026's history clause is
  explicit: **not before arrow identity exists.**
- The `IO (\state -> …)` source-level rewrite. It is **68.6% of all generic
  dispatch**, ~8% from `readPointCell` alone, and has no plan file. It is
  cheaper than everything here and deserves costing independently — but it is
  a source change, not an analysis change.

---

## §8 Step 0 — before any of this

**Trace `Terminal_Main_lambda_14760` by hand.** One creation site (a single
`papCreate` inside `System_TypeCheck_IO_andThen`), 179.7 M generic dispatches,
and a signature that already carries `ordinal 3: m=1,l` naming it. Find
exactly where the set stops travelling between those two points.

This is not ceremony. **This session refuted three confident attributions
built on aggregate counters** — the annotation-key-split story (§10 of the
GAP-2 plan), the adoption-blocking story (§11.1, whose repair drove
`declinedBlocked` 156 → 0 and moved coverage 0.000 pp), and earlier the
sigFlow "stamp reshuffling" story. The aggregates are exhausted as an
attribution instrument. **Trace the object.**

**And it now decides a real fork**, not just confidence: if the set dies
crossing two loads of the **same** type object, 2a is sufficient and 2b's
artifact-format bump is unnecessary. If it dies between an annotation and a
node type, 2b is required and should be scheduled from the start. §4.0's table
is the decision matrix; this trace is its input. If it shows something else
entirely, this plan is wrong and cheap to abandon.

---

## §9 Register delta (lands with the phases)

- **AMEND LSS_001** — the "never `LSet []`" fallback becomes `LUnknown` where
  the position was never written, `LTop` where it was genuinely widened. Note
  the Phase-1 producer set is exactly two arms (§3.2).
- **AMEND LSS_006** — Phase 2a's amendment text is in §4.3: ordinals count
  POSITIONS, not MINTS; a position may reuse an earlier position's slot.
- **AMEND LSS_007** — note that the demand path can now mint a bare `FlexVar`
  set slot (Phase 1b), which was previously only `loadTypeC`'s behaviour.
- **AMEND LSS_020** — the A.1 residue row closes *structurally* rather than by
  repair; the B.0 WpOpaque acceptance rule can retire with the honesty
  machinery it rests on.
- **AMEND LSS_023** — directed `LsFrom` flow retires with §4.8 item 5. Record
  WHY: it was the right idea in a representation that could not carry it.
- **AMEND LSS_026** — clause (a) may relax once dangling sources cannot arise;
  keep it as a safety net, and keep the runtime witness
  (`test/elm/src/LssMixedSigHonestyTest.elm`) green throughout.
- **NEW — arrow identity.** One id per syntactic `TLambda`, minted once at
  type creation, **only in `AssignMVarIds`**; every `Can.Type Name` carries
  `noArrowId`; structural keying banned; the §4.4 isolation policy stated as a
  rule; the §4.3 hit/miss table stated as a rule.
- **NEW — the clone rule.** `TypeSubst.renameMVarIdsInCanType` clones arrow
  ids and is sound only while its output never reaches `Store.loadType*`
  (§4.7). Same for `Analysis.convertCanTypeNameToMVarId`.
- **NEW — the ledger.** `renderLssReport` emits the §2.5.1 ledger with its
  `RECONCILES` self-check; any new zonk cause arm must be wired into it.
- `benchmarks/lss-opt.md` — a Run per phase in the house format, each with
  **the §2.5 resolution ledger as the headline table**, plus the dispatch
  census A/B and the `sat + fast` invariance rail as the regression guard, and
  the `multiSetSites` row for sum lowering's feedstock.

---

## §10 RESULTS (2026-08-24)

### §10.0 The measurement series — one binary per phase, ONE frozen corpus

Every arm below compiles the **same** frozen snapshot of `compiler/src`
(`/work/.lssue-snapshots/src-1a`) with a **different** binary. That is the
satisfiable form of the two-binary rail: "flag-on byte-identity of
`eco-compiler.mlir`" is unsatisfiable for any compiler source change, because
that artifact IS the compiled compiler.

Stage-1 JS compiler loop (reproduces the native census at ~1/3 the cost),
`ECO_MONO_LSS_REPORT=1 ECO_MONO_ENGINE=solver`, defaults otherwise
(budget 512, `maxSetSize` 8, `sigFlow`/`layoutQualMembers`/`postSettleDevirt`
on).

| arm | binary under test | `md5(out.mlir)` |
|---|---|---|
| **A** | pre-Phase-1 (T-LEDGER only) | `52a668e5d83786026b8fabbfd46d046d` |
| **B** | Phase 1a | `52a668e5…` — **identical to A** |
| **C** | Phase 1a + the §10.2 guard fix | `52a668e5…` — **identical to A** |
| **D** | Phase 1b | `641d11809b29210bf37490f5af69d74e` |
| **E** | Phase 2a, `arrowIdentity` **off** | `641d1180…` — **identical to D** |
| **F** | Phase 2a, `arrowIdentity` **on** | `870eb594927b7e448d2081596af10b46` |

Both byte-identity rails pass: **A ≡ B ≡ C** (Phase 1a is a pure relabel) and
**D ≡ E** (Phase 2a flag-off is inert).

### §10.1 The §2.5 resolution ledger — the acceptance metric

| bucket | A/B/C (1a) | D/E (1b) | F (2a on) |
|---|---:|---:|---:|
| `set` k = 1 | 101,065 | 144,875 | **155,729** |
| **`set` k ≥ 2** | **544** | **545** | **2,005** |
| over-cap | 7 | 7 | 7 |
| **`top`** | **152,024** | **29,379** | 30,919 |
| **`unknown`** | **168,006** | 249,087 | **237,057** |
| total (= `setsZonked`) | 421,646 | 423,893 | 425,717 |
| `RECONCILES` | yes | yes | yes |
| **concrete** | **101,616** | **145,427** | **157,741** |
| **resolution completeness** | **24.10 %** | **34.31 %** | **37.05 %** |

Supporting counters:

| counter | 1a | 1b | 2a on |
|---|---:|---:|---:|
| signatures memoized (trivial) | 9,850 (9,456) | 9,850 (9,456) | 9,850 (**9,439**) |
| join flush rounds / retranslations | 3 / 235 | 3 / **439** | 3 / 443 |
| joins changed | 604 | 859 | 864 |
| set-writes skip / flex / **union** | 53,979 / 176,958 / **0** | 10,849 / 220,713 / **0** | 25,738 / 206,155 / **25** |
| slotsMinted | 897,088 | 900,969 | **819,165** |
| `honestSources: topMixedFlex` | 0/0 | **0/0** | **1/0** |
| `devirtDirect` / `devirtKernel` | 4,453 / 968 | 4,459 / 969 | 4,482 / 973 |
| `dispatchUpgraded` | 4,483 | **4,764** | 4,763 |
| `declinedNoInstance` / `declinedBlocked` | 1,084 / 8 | 1,084 / 8 | **1,204 / 167** |
| `widened byBudget` | 8,594 | 8,733 | 8,766 |
| `grounding grounded` | 12,656 | 12,687 | 12,827 |
| **`multiSetSites`** | **(none)** | **(none)** | **`2->2`** |

### §10.2 Phase 1a — PASS, and one real drift found and closed

Byte-identical on the two-binary rail, ledger identical to the digit in all
five buckets, `RECONCILES=yes`, elm-tests at the pre-existing baseline. The
only counter that moved is the `joins: identical`/`noop` split (71,725/22,362 →
62,809/31,278, sum and `changed` both preserved) — the `bumpKeyedHit`
reclassification §3.3-T9 predicted, and output-neutral because
`enqueueSpecKeyed` treats `HitNoopJoin` exactly as `HitIdentical`.

**One drift the plan did not anticipate, caught by the census and fixed.**
`Translate.numericLeafOnlyDiff` short-circuits on `a == b`, where `a` is a
storeless `classify` result (all `LTop` by design, §3.2) and `b` is
store-zonked. Once `b` could carry `LUnknown`, that `==` reported "different"
for what is one type, `sameShapeModuloNumeric` — which ignores annotations —
then answered True, and `useBodyType` flipped at **14** `Let`s
(`leak|letAnno` 44 → 30). Byte-neutral, because the two labels are one key
point; but it is a behaviour change at a def-type SELECTION site, and Phase 1a
is meant to be a pure relabel. Closed by a new `Mono.eqModuloTopLabel`
(normalise-then-`==`, so it is EXACT against `==` including red-black tree
shape, unlike a hand-written size-plus-probe walk). Arm C confirms:
`leak|letAnno` back to 44, and the whole `ARGF` census block diffs EMPTY
against arm A except the new `zc|…|unknown` rows.

### §10.3 Phase 1b — PASS, and it beat its own prediction

The plan predicted a **re-labelling**: `top` falls, `unknown` rises by a
comparable amount, `concrete` roughly flat, with a `concrete` FALL blocking the
phase. What happened instead:

- `top` **−122,645 (−80.7 %)** — so §0's unexplained 19 : 1 gap between
  attributed ⊤ writers (≈7,881) and `causePoison` (152,890) was, as
  hypothesised, almost entirely the `monoTypeToVarC` laundering site;
- `unknown` +81,081 — the predicted relabelling;
- **`concrete` +43,811 (+43.1 %)** — so roughly **36 % of the transferred mass
  became REAL ANSWERS**, not relabelled unknowns. §1's "flex is recoverable
  where poison is terminal and absorbing" is confirmed: a later LSS_010 join
  or retranslation fills slots that used to be permanently ⊤.

`set-writes skip` 53,979 → 10,849 with `flex` 176,958 → 220,713 is the
mechanism in one line: slots that used to be skipped as already-⊤ are now
written.

**§3.6's named risk did NOT materialise.** `topMixedFlex` stays **0/0**. The
feared trade — HOP-3 poison for LSS_026(a) honest-∅ widening, which discards
*members* where poison merely occupied an empty slot — does not occur on this
workload, so 1b does **not** need to be resequenced after Phase 2.

Costs: `retranslations` 235 → 439 (+87 %) and `joins changed` 604 → 859, the
height-2 lattice's one extra round per position, exactly as §3.1 said. Upside
on the consumer side: `dispatchUpgraded` **+281 (+6.3 %)**, `devirtDirect` +6.

### §10.4 EXP-2a — MEASURED, and the answer is NEGATIVE for 2a

The plan's §4.8 method was to count how often `classifyLambdaHead`'s raw
`annCanType == canType` fires, at HEAD and under 2a. **That method would have
caused the regression it was designed to detect** (§4.6a): keeping the raw `==`
as the *guard* under per-occurrence ids switches `lssRootAnn` off. So the guard
was made id-blind (`sameCanTypeIgnoringArrows`, implemented as
strip-then-`==` so it reproduces the old `==` exactly, Dict tree shape
included) and the counter was SPLIT — `rootAnn|hit` counts the id-blind match,
`rootAnn|hitExact` additionally counts the raw `==`.

```
pre-2a  (arm D): rootAnn|hit = 22,653   rootAnn|absent = 12,953   (no missType row)
2a      (arm F): rootAnn|hit = 22,703   rootAnn|hitExact = 567
```

**567 / 22,703 = 2.5 %.** In **97.5 %** of cases a def's stashed `defType` and
its body `Function`'s `meta.tipe` are structurally-equal but **DISTINCT
objects**, so per-occurrence ids do not agree.

**Verdict: 2a cannot reach artifacts #1, #2 or #4a** — they need 2b's
solver-root ids, exactly as §4.0's table said they might. Had the guard kept
the raw `==`, `lssRootAnn` would have fired 567 times instead of 22,703: a
97.5 % collapse of def-root demand reuse, green build, large precision loss.
Also note `rootAnn|missType` is ABSENT pre-2a: whenever `lssRootAnn` was
`Just`, the types always matched. The mechanism was never type-limited; it is
object-identity-limited.

### §10.5 Phase 2a — PASS on the ledger gate, ships DEFAULT-OFF

§4.11 gate 3 is the headline, and §2.5.4's disambiguator decides its sign:

- **COMPLETENESS signature** (good) = `k ≥ 2` ↑ while `unknown` ↓ and `k = 1`
  held or rising.
- **POLLUTION signature** (bad) = `k ≥ 2` ↑ while `k = 1` ↓ comparably and
  `unknown` flat. This is what sigFlow did.

Measured: `unknown` **−12,030**, `k = 1` **+10,854**, `k ≥ 2` **+1,460
(+268 %)**, `concrete` **+8.5 %**. Unambiguously the completeness signature.

Predicted side effects, all observed: `trivial` signatures 9,456 → 9,439 (two
ordinals sharing a rep, §4.3 — a compile-time cost, not a precision change);
`slotsMinted` −9.1 % (the memo sharing slots); `set-writes union` **0 → 25**
(real set unions, for the first time on this workload).

**And `multiSetSiteHist` is non-empty for the first time: `2->2`.** Sum
lowering's feedstock stopped being zero. Two sites is not a business case, but
§2.5.3's row exists precisely so that transition is noticed when it happens.

Two counters to keep watching, neither a gate failure:

- `topMixedFlex` **0/0 → 1/0**. §4.11 gate 4 predicted it would fall to 0 and
  stay ("the dangling sources LSS_026(a) guards against are *connected* now").
  It ROSE by one instead: slot sharing creates an edge-reachable source where
  there was none, and the honest-∅ rule fires. Sound either way, and one event
  is immaterial — but the prediction was wrong and that is worth recording.
- `declinedBlocked` 8 → 167 and `declinedNoInstance` 1,084 → 1,204. §4.11
  gate 6 marks these "watched, not feared": more members reach AbiCloning, so
  more of them get declined. `dispatchUpgraded` is flat (4,764 → 4,763).

**It ships DEFAULT-OFF** (`lss.arrowIdentity`, `ECO_MONO_LSS_ARROW_ID`, hash
token `lssAI=`), per §4.11. The flip needs the runtime dispatch A/B and the
wall A/B, which need native counters-lowered binaries.

### §10.6 Artifact retirement — NOTHING retired, and why

§4.11 gate 8 requires each removal to be individually byte-neutral flag-off and
individually measured flag-on. With the phase shipping DEFAULT-OFF, an
unconditional removal would break the one rail that must hold (D ≡ E), so every
retirement must itself be flag-gated and separately measured. Combined with
§10.4:

| # | artifact | status after this pass |
|---|---|---|
| **7** | the A.1 fresh load at `unifyParamsBestEffort` | **retired BY CONSTRUCTION, no edit exists to make.** It loads through `Store.loadType` (shared memo), so under `arrowIdentity` the "fresh" second load hits `arrowMemo` and is idempotent. Pinned generically by `ArrowIdentityTest`'s "a SHARED seed DOES reuse it". |
| **3a** | `injectArgLambdaMember`'s two lambda arms | **REACHABLE, NOT TAKEN.** Both sides load the same object, so 2a plausibly closes it — but it needs its own flag-gated A/B (does the member still reach the callee?), which this pass did not run. |
| **1, 2, 4a** | `demandUnifyRoot` / lss-on TailDef / `overlayAnnotations` ×2 | **BLOCKED ON 2b** — EXP-2a says so with a measurement (§10.4), not an argument. |
| **5, 6, 8, 9, 10, 11** | flow/transport block, `bindParamsFromSpine`, `enrichFromEnv`, `enrichLocalMultiUses`, `connectTypes`, `ArrowFact` | **BLOCKED ON 2b**, as §4.8 already scheduled them. |
| **3b, 4b, 11(d)** | — | **DO NOT DIE**, unchanged from §4.8. |

So Phase 2 delivered **one** artifact retirement (#7, structurally) and a
measured verdict on the rest — which is §6 risk 4 ("claims eleven and delivers
two") landing about where §4.0 predicted, with the difference that the
prerequisite is now measured rather than argued.

### §10.7 Gates

| gate | result |
|---|---|
| two-binary byte-identity, Phase 1a | **PASS** (A ≡ B ≡ C) |
| two-binary byte-identity, Phase 2a flag-off | **PASS** (D ≡ E) |
| §2.5 ledger + `RECONCILES` | **PASS** in every arm |
| `honestSources: topMixedFlex` | 0/0 through 1b; 1/0 at 2a-on (recorded) |
| `joinRounds` / `retranslations` | +87 % at 1b, +1 % at 2a-on |
| elm-tests | **13,355 / 12** — the failure set is EXACTLY the pre-existing one (11 × POST_010/TYPE_007 + the stale `if-chain` golden). +135 new passes: 10 × `ArrowIdentityTest`, and 125 × LSS_002 totality re-run over the WHOLE SourceIR corpus with `arrowIdentity` ON — slot sharing loses no member anywhere. |
| E2E (`--target full`) | **1,687 / 1,687 in BOTH flag arms** (default-off, and `ECO_MONO_LSS_ARROW_ID=1` after a `build/test/*/eco-stuff` purge) |
| lss-opt wall / GC A/B (native, `benchmarks/lss-opt.md` Run AH) | **RUN.** 1b **+2.8 %** wall (351.6 → 361.5 s), majors IDENTICAL at 14; 2a flag-on **+0.7 % = FLAT** (361.5 → 364.0 s), majors 14. |
| dispatch census A/B with the `sat + fast` invariance rail (`benchmarks/runtime-calls.md` Run AE) | **RUN — and it is the phase's verdict. 1b NEUTRAL (−0.003 pp); 2a −0.50 pp, so the flip gate FAILS.** See §10.10. |

Two native binaries were built for the wall gate (`eco-lss-pre1b` = Phase 1a,
`eco-lss-post` = 1a+1b+2a) and run against one frozen corpus; the native
ledger reproduces the Stage-1 JS loop's ledger shape exactly, which is an
independent check on the whole measurement series. **1b's +2.8 % sits below the
house 3 % action band and above the ±1.1 % noise floor** — by the protocol's
own rule that is "no regression detected", and it lands exactly where the
mechanism puts it (`retranslations` 236 → 441). Majors identical at 14 across
all three arms is the strong statement at n = 1.

Every gate has now been run. Phase 1b ships unconditionally on the §2.5 ledger,
which §2.5 makes this arc's acceptance metric precisely because dispatch
coverage measures the consumer rather than the analysis — and the dispatch
census confirms that framing exactly: 1b's +43 % concrete-resolution gain
reaches the runtime by **−0.003 pp**, i.e. not at all. Phase 2a's flip gate
FAILS and it stays default-off; §10.9 has the attribution.

### §10.8 Fixture movements, all classified

- `LssSigFlowTest` case 5 (TailDef) and case 9 (contravariance): the flag-off /
  caller-side arrows now read `LUnknown`, not `LTop`. **Free information, not a
  fixture chore** (§3.3-T12): case 9's own comment already said "the
  CALLER-side hof params read ⊤ because `useH`'s own instantiation writes no
  members into them" — the label now says what the comment said. Both pins keep
  their content (a k-less non-⊤ SET is still excluded; `LUnknown` is not an
  `LSet`). **The two MISCOMPILE pins — case 3's `apply f x = f x` negative
  control and case 4's `pick` honesty pin — stayed GREEN untouched.**
- `GoldenConstraintTest`: 4 of 13 fingerprints rebased (`binop-chains`,
  `pipe-chains`, `top-level-vars`, `typed-defs`). `Can.TLambda` gained a field,
  so `Debug.toString` of a constraint embedding an arrow-bearing `Can.Type`
  gained an `Id 0`. The constraint is unchanged — every arrow carries
  `noArrowId` at that phase, and arms C/E prove a whole self-compile is
  byte-identical across the change. The 9 arrow-free entries were untouched,
  which is the shape a representation-only rebase must have. `if-chain` was
  ALREADY failing at HEAD and is left alone.
- `ComparableKeyEncodingTest` was made NON-VACUOUS in the same commit as the
  key law it protects (§6 risk 2): `annoAt` draws `LUnknown`, the goldens carry
  an `LUnknown` row with DELIBERATELY the same golden string as the `LTop` row,
  and three nested `LUnknown` shapes enter the `handwritten × handwritten`
  near-miss block so both K4 differential tests actually see
  `LUnknown`-vs-`LTop` and `LUnknown`-vs-`LSet` pairs.

### §10.9 The dispatch census — the phase's verdict, and a finding that changes the plan's model

`benchmarks/runtime-calls.md` Run AE. Three counters-lowered binaries, one
cold solver+LSS workload each.

| build arm | sat | gen | typed | fast | sat+fast | coverage |
|---|---:|---:|---:|---:|---:|---:|
| pre-1b (Phase 1a) | 1,812,897,282 | 1,782,258,808 | 30,638,474 | 513,488,797 | 2,326,386,079 | 22.072 % |
| Phase 1b (`arrowIdentity` OFF) | 1,812,971,230 | 1,782,332,761 | 30,638,469 | 513,414,773 | 2,326,386,003 | 22.069 % |
| Phase 2a (`arrowIdentity` ON) | 1,824,632,934 | 1,793,994,465 | 30,638,469 | 501,784,644 | 2,326,417,578 | **21.569 %** |

**Phase 1b is dispatch-NEUTRAL: −0.003 pp.** Its +43 % concrete-resolution gain
reaches the runtime by essentially nothing, `typed` moves by 5 events and
`sat + fast` by 76. That is §2.5's thesis measured rather than argued — the
consumer is singleton-only, so a better analysis with no new singletons is
worth zero instructions. 1b ships on the ledger, and this row is why the ledger
had to be the acceptance metric.

**Phase 2a FAILS the flip gate: −0.50 pp, fast −11,630,129, gen +11,661,704,
`typed` EXACTLY unchanged.** That is the LSS_026 `callArgFlow` signature
reproduced to within 0.2 % (that arm: −11,651,310 / +11,651,310 / 0 /
−0.51 pp) — and unlike that arm, this one is **attributed**.

Method note, because the obvious approach is wrong here: symbol names cannot be
joined across arms. A naive name join reports 1,214 symbols losing 502.7 M fast
and 1,199 gaining 491.1 M — essentially the whole population, all renames, from
`lambda_N` renumbering. The rename-proof instrument is the **multiset
difference of per-site `fast` counts**: a renamed site keeps its value and
cancels. It gives **6 vanished magnitudes, of which one is 11,515,632 = 99.0 %
of the entire loss.**

That site is `Terminal_Main_lambda_15169$cap`, flag-off `sat = 0,
fast = 11,515,632` — a closure reached ONLY through a static stamp, never
dispatched. Flag-on it is gone, and that exact magnitude reappears as
`gen` on `lambda_15217$cap` and `lambda_15219$cap`, with `15215`/`15223`
carrying 11,459,306. Analysis side, same pair: `multiSetSites` `(none)` →
`2->2`, `declinedBlocked` 8 → 167, `declinedNoInstance` +120.

**The mechanism, and it is a correction to this plan's model.** Slot sharing
unions what per-load minting kept apart. One syntactic arrow instantiated at
several call sites had, under per-load minting, a SEPARATE slot per site — each
seeing one callee, each a singleton, each stamped. Under arrow identity it has
ONE slot seeing the union, which is an honest multi-member set that every
devirt arm declines. **Per-load minting is not only fragmentation; it is also
the analysis's context sensitivity, and that context sensitivity is what
manufactures the singletons the consumer can use.**

So `plans/…/lss-why-the-fidelity-program-failed.md`'s reading — "sets don't
travel with types, hence the transport artifacts" — is true but one-sided. The
paper does not have this problem because its α is a set **variable**
instantiated per use, so identity and context sensitivity arrive TOGETHER.
Splitting them into Phase 2a (share the slot) and Phase 3 (make it a variable)
puts a measured regression in between, and this run is it.

**Three consequences that should govern the next steps:**

1. `lss.arrowIdentity` stays DEFAULT-OFF. The gate is "no fast-coverage
   regression"; this is one.
2. **Phase 2b would very likely make this WORSE, not better.** It shares across
   type objects, i.e. it merges strictly more contexts. Scheduling 2b before
   Phase 3 would buy more analysis completeness and more de-stamping. The
   §10.9 ordering below is amended accordingly.
3. **A new lead on the `callArgFlow` de-stamp, which three attributions failed
   to explain** (`lss-destamp-attribution-refuted`): same magnitude, same
   shape, same `typed = 0`. The hypothesis is now that it too made a hub's set
   honestly multi-member and the singleton-only consumer declined it. Testable
   with the multiset instrument used here, on the preserved `callArgFlow`
   arm — cheap, and it would close a question the register has carried open.

### §10.10 What to do next, in order

1. ~~**Cost 1b.**~~ DONE — Run AH: +2.8 % wall, majors identical, sub-action-band.
2. ~~**Dispatch A/B for `arrowIdentity`.**~~ DONE — §10.9. Verdict: the flip
   gate FAILS at −0.50 pp, attributed to ONE de-stamped site.
3. **Re-test the `callArgFlow` de-stamp with the §10.9 multiset instrument.**
   Cheapest item on this list by a wide margin, and it may close a question the
   register has carried open through three refuted attributions.
4. **Phase 3 now OUTRANKS Phase 2b, which is a reversal of this plan's order.**
   §10.9's mechanism says sharing without a per-use variable trades the
   context sensitivity that manufactures usable singletons; 2b shares strictly
   more, so it should not land before the variable exists. EXP-2a's 97.5 %
   (§10.4) still says 2b is what closes the transport artifacts — but it should
   be scheduled WITH Phase 3, not before it, and its artifact-format bump
   (§4.9 step 3) is then paid once.
5. **Artifact #3a** remains the only artifact 2a can reach; it needs its own
   flag-gated A/B and is now low priority, since the flag is off.
6. When Phase 3 is started, re-read §5.2 Q4 first: the raw-vs-qualified member
   question (LSS_017-v2) is a prerequisite and is unchanged by anything
   measured here. And note §10.9 gives Q3 ("the consumer is still
   singleton-only") a measured price tag for the first time: **11.5 M dispatches
   on ONE site.**

---

## §11 PHASE 2b + THE MULTI-SET CENSUS (2026-08-24, same day)

### §11.0 The instruments that made this measurable

Two were added first, because §10.9 showed the arc's real question is not "are
there more multi-member sets" but "are they HONEST or merge-induced", and
nothing could answer that:

- **M3 — per-ARROW multi-sets.** `Store.loadTypeC` records `pointKey -> ArrowId`
  (report-gated, both flag arms), `zonkSetSlot` records every `|set| >= 2`
  readback against that arrow, and `renderLssReport` emits an `MSET` block.
  This fixes §2.5.5: `sizeHist` counts READBACKS and cannot tell 518 distinct
  6-member arrows from one hot arrow read 518 times.
  **Trap, and it cost a run:** the slot that gets ZONKED is usually not the slot
  that was MINTED — a loaded arrow and a demand-encoded arrow unify, and only
  the loaded side ever has an ArrowId (`monoTypeToVarC` builds from
  `Mono.MonoType`, which has no arrow ids at all). Keying by the raw Point gave
  `arrows=0`; the lookup must go through the union-find class (`UF.repr`).
- **M1** — the per-consumer `zc|<gkey>|` census, split by SET SIZE as well as by
  cause.
- **M2** — `benchmarks/multiset-census.py`, an offline join of two arms **by
  ArrowId**. Valid ONLY where both arms number ids the same way; the script now
  REFUSES a join with zero overlap rather than reporting nonsense (see §11.3).

### §11.1 The three arms — one binary, one frozen corpus

| arm | arrows with k≥2 | kN readbacks | k=1 | top | unknown | total | completeness | `md5(out.mlir)` |
|---|---:|---:|---:|---:|---:|---:|---:|---|
| **1b** (`arrowIdentity=0`) | **13** | 545 | 144,875 | 29,379 | 249,087 | 423,893 | 34.24 % | `641d1180…` ≡ armE |
| **2a** (`arrowIdentity=1`) | **100** | 2,005 | 155,729 | 30,919 | 237,057 | 425,717 | 37.05 % | `870eb594…` ≡ armF |
| **2b** (`+ arrowSolverRoots=1`) | **1,009** | 4,302 | 165,854 | 29,644 | 243,922 | 443,729 | **38.35 %** | `d62dd3c7…` |

**Both byte-identity rails pass to the digit.** The 2b binary — which carries
the `ArrowSlot` refactor, the solver-root stamping in `Compile`, the ARTIFACT
FORMAT CHANGE, and all the census instrumentation — reproduces armE exactly with
`arrowIdentity` off and armF exactly with `arrowIdentity` on. The whole of 2b is
provably inert until its own flag turns on.

### §11.2 13 arrows produce all 545 baseline multi-sets

The §2.5.5 ambiguity, resolved: it is a handful of hot arrows, not a broad
population. Per-arrow UNION sizes (across all specs of that arrow — not
per-readback sizes, which are capped at `maxSetSize` 8):

```
1b    15->5  23->5  132->1  421->1  500->1          — 13 arrows, all polymorphic hubs
2a    + 2->39 3->18 4->23 5->5 6->2                 — 87 NEW, all small
2b    2->937 3->18 4->21 5->6 6->9 7->2 8->1 9->1 …  — 1,009
```

M2 on the one valid join (1b → 2a): **13 STRUCTURAL** (present in both arms —
11 with IDENTICAL member sets, 2 grew), **87 MERGE-INDUCED**, **0 LOST**. The
baseline population is entirely structural and entirely hubs; everything 2a adds
is small and appears only under slot sharing.

And the consumer row explains §10.9's regression exactly: of those 87 new
multi-set arrows, `multiSetSiteHist` says only **2** reach a dispatch site.
**85 of 87 are inert — they cost nothing and buy nothing — and the 2 that are
not cost 11.5 M dispatches.**

### §11.3 A method note that will recur

The 2a → 2b join is **INVALID** and the script now says so: 0 overlap out of
100/1,009. ArrowIds are flag-independent across `arrowIdentity` (both arms mint
per occurrence from a flag-independent walk) but NOT across `arrowSolverRoots`,
which allocates ids over solver roots instead and renumbers every one. The
signature is identical to the symbol-name join failure in runtime-calls Run AE
(1,214 "losses", 1,199 "gains", all renames). **Any cross-arm join needs a key
whose PRODUCER is unchanged between the arms; that is a stronger condition than
"the key is stable within a run".**

### §11.4 EXP-2a re-run — 2b does exactly what it was predicted to do

| arm | `rootAnn\|hit` | `rootAnn\|hitExact` | ratio |
|---|---:|---:|---:|
| 1b | 22,653 | 567 | 2.5 % |
| 2a | 22,703 | 567 | 2.5 % |
| **2b** | 22,883 | **22,816** | **99.7 %** |

§10.4 measured that a def's annotation and its body node's type are
structurally-equal DISTINCT objects 97.5 % of the time, and concluded that only
solver identity could tie them. **2b ties 99.7 %.** The prediction and the
result agree to within the noise of the remaining unstamped arrows (types built
after the solve, which correctly fall back to occurrence ids).

Also moved, and this is the first time in the register:
**`signatures: 9,850 memoized (9,439 → 8,480 trivial)` — 959 signatures stop
being trivial.** Signature triviality is GAP-2's own success metric and it had
never moved.

### §11.5 The consumer-side warning, and it is loud

| counter | 1b | 2a | 2b |
|---|---:|---:|---:|
| `multiSetSites` | (none) | `2->2` | **`2->20 3->4 4->4 5->1 6->1 7->1` = 31 sites** |
| `declinedNoInstance` | 1,084 | 1,204 | **6,695** |
| `declinedBlocked` | 8 | 167 | 182 |
| `dispatchUpgraded` | 4,764 | 4,763 | 4,745 |
| `topMixedFlex` | 0/0 | 1/0 | 2/0 |
| `retranslations` | 439 | 443 | 436 |

`declinedNoInstance` ×5.6 is **§5.2 Q4 arriving on schedule**: the inference walk
mints RAW `l|` members, so a transported member reaches AbiCloning with no
closure instance carrying that id and declines. The plan predicted this would
"bite Phase 3 identically unless LSS_017-v2 lands first"; it bites 2b first.
**LSS_017-v2 is now a measured prerequisite, not a projected one.**

`multiSetSites` 0 → 2 → **31** is the other side of the same coin: sum
lowering's feedstock is now real. Every one of those 31 is a site a
singleton-only consumer declines.

### §11.6 Design record — how 2b was built, and why not the way §4.9 sketched

§4.9 proposed carrying arrow roots as a SEPARATE serialised field on
`TOpt.GlobalGraph`, consumed in a pre-order that must agree exactly with
`rewriteCanType`'s walk. **That was not built, because the lockstep obligation
is unbounded:** a def has one annotation but MANY node types, and `rewriteNodes`
calls `rewriteCanType` at a dozen sites across an expression tree. Reproducing
that traversal in `SolverRoots` is a standing invariant nobody can check.

What was built instead stamps the identity INTO the type, where the ordering
question cannot arise:

1. **`TypeIds.ArrowSlot = NoArrow | SolverRoot Int | Arrow ArrowId`** replaces
   the `ArrowId`-with-a-reserved-zero. Its meaning is PHASE-DEPENDENT exactly as
   `Can.Type id`'s parameter is (`Name` → `MVarId`), and three constructors make
   that impossible to confuse. `NoArrow` is nullary, so it is an embedded
   constant and costs LESS than the `Id` box it replaced (REP_CONSTANT_001).
2. **`SolverRoots.stampArrowRoots`** walks a `Can.Type` against its solver var —
   the same descent `walkTypeForBinders` uses, arm for arm — and writes each
   arrow's own union-find root index. Where the lockstep is lost it leaves the
   subtree alone, so 2b degrades to 2a locally, never to a WRONG id.
3. **`Compiler.Compile`** applies it to node types and annotations after
   PostSolve — the last point where `solverState` is live. UNCONDITIONAL, not
   flag-gated: the value rides `Can.Type` and therefore the cached artifact, so
   gating it would key the on-disk format to a mono-time flag.
4. **The codec carries it**, which is the format change, and
   **`V.compiler 0.1.0 → 0.1.1`** is the bump. That constant is used in exactly
   one place — `Stuff.compilerVersion` — which keys BOTH `eco-stuff/<version>`
   and `~/.eco/<version>/packages/`, so one edit invalidates every cache. The
   bump is not optional: an older artifact would decode SHORT, and the recorded
   failure mode for that is silent (`eco-missing-typed-artifacts-silent-empty`),
   surfacing much later as a mono crash.
5. **`AssignMVarIds.ensureArrowIdForRoot`** resolves `(moduleKey, rootIdx)` to a
   global `ArrowId` — an exact mirror of `ensureMVarIdForRoot`, and the module
   scoping is load-bearing for the same reason: each module numbers `Pt` from
   zero, so an unscoped raw index would FALSELY union two unrelated lambda sets.
   Safe because `TOpt` carries only `Meta.tipe` and `AnnotationsByGlobal` — no
   foreign `Can.Annotation` — so every type is rewritten under the home module
   of the global that owns it.

### §11.6a Gates

| gate | result |
|---|---|
| two-binary byte-identity, `arrowIdentity` OFF | **PASS** — `641d1180…`, identical to Run AH armE |
| two-binary byte-identity, 2a arm (`arrowSolverRoots` OFF) | **PASS** — `870eb594…`, identical to Run AH armF |
| §2.5 ledger + `RECONCILES` | yes in all three arms |
| EXP-2a re-run | `hitExact` 2.5 % → **99.7 %** (§11.4) |
| elm-tests | **13,355 / 12** — the pre-existing failure set exactly. Four golden constraint fingerprints rebased, representation-only (the arrow slot's printed form went `Id 0` → `NoArrow`); the nine arrow-free corpus entries were untouched BOTH times this has happened, which is the shape such a rebase must have. |
| E2E `--target full`, format bump exercised | **1,687 / 1,687** |
| E2E `--target full`, `arrowSolverRoots=1` | **1,687 / 1,687** |
| runtime dispatch A/B for the 2b arm | **NOT RUN** — it is a DEFAULT-FLIP gate and 2b is not being flipped (§11.7). §11.5's `declinedNoInstance` ×5.6 and 31 undispatchable multi-set sites already predict its sign. |

### §11.7 Verdict

**2b works, does precisely what EXP-2a predicted, and is byte-neutral until its
flag turns on. It ships DEFAULT-OFF, alongside 2a, and it should STAY off until
Phase 3.** §10.9's mechanism says slot sharing without a per-use set variable
trades the context sensitivity that manufactures usable singletons, and 2b
shares strictly more contexts than 2a — `declinedNoInstance` ×5.6 and 31
undispatchable multi-set sites are that trade, measured.

The Phase 3 plan is written: `plans/lss-set-variable.md`. Its headline finding
is that the set variable does **not** remove the join on its own — specialization
keying is a commitment to a concrete set, and sum lowering is what removes that
commitment. Read its §2 before starting any of it.
