# Provenance-aware joins + demand-driven reference signatures

**Status: PLANNED 2026-08-29 — the follow-up pairing from the lever-4 close
(`plans/lss-coverage-four-levers.md` §7.5) and the ⊤-join lattice discussion.
Not yet reviewed, not yet implemented.**

Baseline when written: shipped-default coverage **88.07 %** (var 12,314 /
top 3,664); `lss.argPoints` DEFAULT-OFF carrying the probe-proven M3
machinery (walked-point threading, ctor call arm, `joinLetUse` family-point
handoff, reference-triggered signature instantiation).

---

## 0. The two measured problems this plan pairs against

**Problem 1 — the join destroys knowledge it could keep (manufacturer B).**
`unionAnno (LSet xs) (LVar _) = LTop` fires at the completion join whenever
one side of a spec's inputs knows a set and another side never wrote. The
rule is correct *when the var side is a value channel* (keeping the set would
be the false-singleton miscompile — the `{identity}`/`Task.map` incident).
But the measured ⊤ mass comes overwhelmingly from var sides that are **type
restatements** — demands from `classify`/references/seeding, and body zonks
at positions whose inhabitants the body cannot contribute. Evidence: the
2,997 head-⊤ population healed by lever 1's completion re-stamp was exactly
this (the stamp re-asserts what the restatement-var erased), and the probe
`LssGapKernelPipeline` shows the producer flip `var → ⊤` at a non-spine
payload position that lever 1's spine-only stamp cannot reach.

**Problem 2 — reference-triggered signatures work but dilute (M3's verdict).**
M3 proved the missing paper rule ("every use instantiates the scheme"): a
container-typed reference now triggers the referent's signature walk, and the
probe's consumer payload flipped `var → k1` — the first time the cross-item
ctor-payload chain ever closed. At self-compile scale it measured **−0.21 pp**:
`argpt|refSig` fired 815× and positions grew +422 (map +114, Decoder +54,
apply +53, andThen +53, Ok +53 — extra SPECS of the same combinators), of
which +332 var vs only +88 newly covered. Dilution, not destruction (top
moved +2).

**The post-mortem detail that makes Problem 2 look very fixable:** most of
those 815 instantiations applied **empty (allflex/trivial-ish) signatures** —
there were no facts to transport — yet the instantiate-and-unify still ran,
merging fresh isolated slots into the reference's Points and thereby changing
the zonked **var-numbering pattern** of the demand. Demand annotations are
part of the keyed SpecKey, so demands that previously coalesced now split,
each extra spec re-contributing its var-heavy deep positions. The unify was
pure key churn whenever the signature had nothing to say.

## 1. Part A — provenance-aware join

### 1.1 Design

Give each side of the completion join a **provenance class**, and let the
join keep a set over a var when the var side provably contributes no
inhabitants.

Who can contribute inhabitants to a position (the value-channel analysis, by
position class — LSS_013's spine partition):

| position class | inhabitants come from | body zonk is | call demand is | reference/classify/seed demand is |
|---|---|---|---|---|
| head (depth 0) | the def itself | restatement | restatement | restatement |
| param spine (1..arity−1) | CALLERS' arguments | restatement | **value-bearing** | restatement |
| result tail / returned closures | the BODY | **value-bearing** | restatement | restatement |
| nested payloads (`/c<n>`, fields) | whoever constructed the value | value-bearing (if body constructs) | value-bearing (args flow in) | restatement |

v1 rule (deliberately coarse, always erring toward ⊤):

- Tag each **demand** with one bit at its producer: `Restatement`
  (classify/classifyRef, `seedSpec`, bare-reference enqueues, retranslation
  re-registrations of an unchanged stored type) vs `ValueBearing` (call-site
  demands — conservative: value-bearing at every position).
- At the join, `LSet ∪ LVar` keeps the **set** iff the var side is
  `Restatement`; body-zonk var sides count as `Restatement` **only at spine
  positions** (which exactly subsumes lever 1's re-stamp — same tautology,
  now expressed as a join rule instead of a repair).
- Everything else keeps today's `LTop`.

### 1.2 Why this is sound (and where the danger line is)

A restatement demand's annotations describe what its *context knew*, and a
var there means "this context knew nothing" — but a reference/classify/seed
context also **adds no runtime values** to the referent's arrows (only calls
add param inhabitants; only bodies add result inhabitants). Joining zero
contributed inhabitants into a set leaves the set complete. The danger line
is mis-tagging: one `ValueBearing` demand tagged `Restatement` re-creates the
false-singleton class. Hence: the tag is set at the *producer* (each enqueue
site chooses explicitly, no default), and the adversarial review must
enumerate every enqueue path (the regIdentity arc catalogued them:
`enqueueSpecStamped`'s five sites + `seedSpec` + retranslation).

### 1.3 Paper fidelity

The paper has no join because one global store means no position is ever
asked to reconcile two solvers' views; its α accumulates only from real
constraint emissions (𝒬 injections and flow), i.e. **only value channels
ever write**. A provenance-aware join is Eco converging on that: joins stop
treating "a context restated the type" as if it were "a context emitted a
constraint." The technique differs (tag + join rule vs one store); the
judgment — sets survive unless a genuine flow says otherwise — is the
paper's.

## 2. Part B — demand-driven reference signatures (M3, refined)

Two refinements to the parked `lss.argPoints` machinery, both aimed squarely
at the measured dilution:

- **B1 — fact-gated instantiation.** In the M3.3 arm
  (`Translate.injectArgLambdaMember`, VarGlobal case) and the inference twin:
  after `signatureFor`, instantiate-and-unify **only if the signature carries
  at least one non-default fact** (members non-empty or top at some ordinal).
  An empty signature transports nothing — skip the unify entirely, so the
  demand's var numbering (and hence its SpecKey) is untouched. This should
  eliminate most of the 815-fire key churn outright; the probe's win (the
  `makePair2` signature DOES carry a fact once walked) is preserved.
- **B2 — nested-arrow static filter.** Trigger the reference instantiation
  only when the referent's signature-source type has an arrow in a
  **non-spine** position (`/c<n>`, field, tuple, list payloads) — the class
  the sig channel is the only transport for. Arrow-headed references are
  already identity-injected; call sites already instantiate.

Note the ordering dependency: B1's "carries a fact" test is only useful if
producers' signatures HAVE payload facts — which is what Part A protects
(today the completion join destroys the producer's knowledge, and a destroyed
stored type feeds the next retranslation's demands). **A then B** is the
required order; B alone re-measures M3's dilution.

## 3. Part C (recorded option, not v1) — the `LPartial` lattice state

If Part A's census (§4 P0) shows a large residual of joins where *both*
sides are value-bearing and one is var — real members meeting a real unknown
channel — the honest label is neither `LSet` (false completeness) nor `LTop`
(destroys the members): it is a lower bound. Design sketch, recorded for
that eventuality:

- `LPartial members` — "at least these; possibly more."
  Joins: `LPartial ∪ LVar = LPartial`; `LPartial ∪ LSet = LPartial(∪)`;
  `⊤` still absorbs. The user-proposed arm `LSet ∪ LVar(valueBearing) →
  LPartial(xs)` replaces today's ⊤ there.
- Runtime-safe by construction: every devirt/singleton consumer matches the
  literal pattern `LSet [m]`; `LPartial` matches nothing.
- Encodes as members-plus-writable-slot (the recoverable middle between
  `LVar`'s bare flex and `LTop`'s terminal poison — the encode asymmetry at
  `Store.monoTypeToVarC` already establishes this axis).
- **Promotion** `LPartial → LSet` = the paper's fixpoint argument
  transplanted: at final drain quiescence, promote iff every var-contributor
  at the position was restatement-class or injection-covered. Cross-item
  value channels (`knownElsewhere`) block promotion — that residue is
  genuinely architectural.
- Precedent in-tree: LSS_026's honest-sources policy already REFUSES to
  publish populated-but-incomplete sets and widens to ⊤ instead
  (`honestSources: topMixedFlex`); `LPartial` is the state that makes that
  refusal expressible without destruction.
- Costs to review before building: SpecKey space changes (`toComparable`
  fragment for `LPartial`), `annoCovers`/`joinAnnotationsChanged` lockstep
  extension, coverage-census accounting (`LPartial` counts UNCOVERED until
  promoted — the gate stays honest), and the multiset/sum-lowering consumer
  (`plans/lss-sum-lowering.md`) which needs FULL sets and must ignore
  `LPartial`.

## 4. Phases

- **P0 — the join-site census (measure before building).** At the completion
  join, count `LSet×LVar` collisions by cell: (var side ∈ {demand, actual})
  × (position class ∈ {head, param-spine, result-tail, nested}) ×
  (demand provenance, approximated post-hoc by demand origin counters).
  Report-gated counters, one self-compile. GO test for Part A: the
  restatement-classifiable cells hold ≥ 60 % of collisions. Also: re-run the
  M3 A/B with **B1 alone** (a ~5-line guard) to size how much of the −0.21 pp
  was empty-fact key churn.
- **P1 — Part A** under a new flag `lss.provJoin` (env
  `ECO_MONO_LSS_PROV_JOIN`, token `lssPJ`): the demand-provenance bit through
  the enqueue paths + the join rule. Differential unit pins (the
  LssGroundingTest lesson: pin overlapping flags), probe micro-gates
  (`LssGapKernelPipeline`'s producer `⊤ → k1`), self-compile census A/B.
  Expectation: subsumes lever 1 — verify by measuring `injTotal`-L1's
  incremental effect with `provJoin` on; if ~0, retire the re-stamp in a
  follow-up.
- **P2 — Part B (B1+B2)** under the existing `lss.argPoints`, A/B'd on top of
  P1. GO: coverage strictly up vs the P1 arm; spec-count growth < 25 % of the
  covered-position gain.
- **P3 — battery** (elm-tests, E2E both arms, Q-infer `diverge=0`, dispatch
  pair if ≥ 2 pp — expect exactly neutral; nothing here touches devirt
  inputs). Flip decisions with the user, per flag.
- **P4 — Part C GO/NO-GO** from P0's residual-cell numbers. Only if the
  both-sides-value-bearing cell is large does `LPartial` get its own plan.

## 4.1 Implementation lowering (2026-08-29)

### P0 census — two instrumented join sites, both `lss.report`-gated

- **Pure walker** (`Monomorphize.elm`):
  `joinCollisionCells : Int -> Mono.MonoType -> Mono.MonoType -> List String`
  — parallel walk of (actual, stored) / (demand, stored); tracks
  `spineDepth` along the root result chain and a `nested` flag (set once the
  walk enters an arrow's argument or any container: MList/MTuple/MRecord/
  MCustom args). At each paired `MFunction`, classify position:
  `head` (depth 0, not nested), `spine` (1..arity−1), `tail` (≥ arity),
  `nested`. Emit cells for the pairs:
  `(LSet, LVar)` → `jc|<side>Var|<pos>` where side names WHICH input held the
  var; context rows `(LSet, LTop)` → `jc|<side>Top|<pos>` (destruction that
  already happened upstream); everything else ignored. Arity via
  `LssInfer.declaredArityOf g 8 s` (import LssInfer into Monomorphize if
  absent).
- **Site 1 — completion join** (`Monomorphize.elm`, the `completionJoin`
  block): compute cells on the RAW `(actualType, storedT)` — before L1's
  re-stamp, so the census sees the true collisions L1 currently masks.
  Thread the bumps through the existing `s2 → s3` chain
  (`List.foldl Engine.bumpArgFlowCensus`). `actVar` = body side ignorant,
  `demVar` (stored side) = every demand ignorant.
- **Site 2 — incremental demand join** (`Engine.enqueueSpecKeyed`, HIT path):
  before the registry join, `Registry.lookupSpecKey` the current stored type
  and run the walker on `(demandType, storedType)` — `ji|demVar|…` /
  `ji|storVar|…`. This is where most destruction happens (demand ∪ demand),
  and it sees each demand INDIVIDUALLY — the per-demand truth the completion
  site cannot recover. Known undercount at site 1 is thereby covered.
- Read-out: one defaults self-compile with `ECO_MONO_LSS_REPORT=1`; the
  cells print in the argFlowCensus block. GO test (§4 P0): restatement-
  classifiable cells (`jc|demVar|head`, `jc|demVar|spine`, `jc|actVar|head`,
  `jc|actVar|spine`, plus nested `demVar` from reference-class demands —
  approximated by the `ji|` split) ≥ 60 % of collisions.

### B1 — the fact gate (one guard, two sites)

`sig.trivial` is DEFINED as "every fact is `{rep=self, members=[], top=False}`"
(`Engine.LssSignature`), i.e. exactly "nothing to transport". In BOTH M3
reference-instantiation arms (`Translate.injectArgLambdaMember` VarGlobal
M3.3 block; `LssInfer` walkExpr VarGlobal M3.2 block): call
`LssInfer.signatureFor g` first (memoized) and skip the
instantiate-and-unify when `sig.trivial` — the demand's var numbering, and
hence its SpecKey, stays untouched when there are no facts to move. Census:
rename fires to `argpt|refSigLive` vs `argpt|refSigSkipTrivial`.

### Part A lowering (P1, after P0 GO)

- Flag `lss.provJoin` (default False, env `ECO_MONO_LSS_PROV_JOIN`, token
  `lssPJ`) — Config/Builder wiring per the house pattern.
- Provenance bit: `type DemandProv = Restatement | ValueBearing`, a NEW
  explicit parameter on `Engine.enqueueSpecKeyed`/`enqueueSpec` (no default —
  every caller chooses). Producers: `Translate.translateGlobalCall` demand →
  `ValueBearing`; `classifyRef`/`classify`-derived enqueues, `seedSpec`,
  retranslation re-registrations → `Restatement`.
- Join rule application at the INCREMENTAL site only (the accumulation
  problem: stored types cannot carry per-demand provenance, so the
  completion join is handled by the spine rule): when `provJoin` and the
  incoming demand is `Restatement`, the registry join uses a variant
  `joinAnnotationsChangedKeepSet` whose `(LSet, LVar)` arm keeps the SET
  when the VAR is on the demand side. Completion join: `actVar` at
  head/spine positions keeps the stored set (the body cannot contribute
  there — subsumes L1).
- `annoCovers` lockstep is untouched (no new lattice element in v1).

## 4.2 P0 RESULTS (2026-08-29) — both measurements run; plan REFRAMED

Source note: the compiler's own source grew by the M2/M3/census code since the
88.07 % baseline, so the same-day defaults census reads
positions=134,385 / coveredBp=8786 — the ratio drift vs 88.07 % is source
growth, not analysis regression. All comparisons below are same-source
(P0A defaults vs P0B argPoints+B1: byte-equal counters).

### Site-1 collision cells (defaults, one self-compile)

| cell | head | spine | tail | nested |
|---|---:|---:|---:|---:|
| `aVar` (body ignorant, demands knew) | 899 | 898 | 0 | 51 |
| `sVar` (ALL demands ignorant, body knew) | 0 | 0 | 24 | 21 |
| `aTop` (body ⊤, demands knew) | **2,052** | **1,936** | 1 | **1,516** |
| `sTop` (stored ⊤ already) | 0 | 0 | 0 | 0 |

**Findings:**

1. **The LSet×LVar mass this plan targeted is small at the completion site:**
   demand-side (`sVar`) collisions total **45**; body-side (`aVar`)
   head+spine (1,797) are already healed post-join by lever 1's re-stamp
   (census reads pre-stamp). Part A's original keep-set-over-restatement-VAR
   rule has a ~45-position completion-level ceiling plus whatever the
   incremental site hides — NOT the headline.
2. **The real mass is `LSet × LTop`:** 5,505 positions where DEMANDS KNEW a
   set and the body zonk's ⊤ absorbed it (`⊤ ∪ set = ⊤`). Head+spine
   (3,988) are L1-healed after the fact; **`nested` = 1,516 positions
   (≈ +1.1 pp ceiling) are destroyed and nothing heals them** — the
   kernel-ABI rebuild's placeholder ⊤ at payload positions, absorbing demand
   knowledge L1's spine-only stamp cannot reach. Part A v2 therefore targets
   **restatement-⊤**, not just restatement-var: keep the stored set over an
   actual-side ⊤ when that ⊤ is a placeholder (ABI rebuild / classify), not
   poison. This requires distinguishing the two ⊤ provenances — the
   recoverable-vs-terminal split this arc has circled twice (the encode
   asymmetry; Part C's lattice discussion). The danger line: body-⊤ from
   genuine kernel poison at a payload the kernel actually fabricates into
   must STAY absorbing.
3. **B1 verdict: decisive.** `argpt|refSigSkipTrivial=814 / refSigLive=1`,
   `refInstSkip=585 / refInst=1` — 99.8 % of M3's instantiations carried
   trivial signatures; with B1 the dilution vanishes ENTIRELY (P0B counters
   byte-equal to defaults). M3's −0.21 pp is fully explained as trivial-sig
   key churn. But the flip side: only **one** container-typed referenced def
   in the whole self-compile has a non-trivial signature — producer
   signatures are almost universally allflex for this class, so Part B
   transports nothing until the PRODUCER side (the scratch-walk leaks and/or
   the ⊤-destruction of finding 2) is fixed. **A-then-B confirmed at
   measurement level, with A refocused on restatement-⊤.**

### Revised sequencing

- P1 becomes: the restatement-⊤ rule at the completion join's nested cells
  (1,516-position target), which needs a body-⊤ provenance bit — cheapest
  honest form: the kernel-ABI rebuild stamps a DISTINCT placeholder label
  (or the deriveKernelAbiTypeWith path records per-position "placeholder"
  in a sidechannel consumed only by the completion join). Adversarial review
  required before building: this touches the ⊤-absorption invariant.
- The original Part-A demand-bit remains worthwhile but demoted (45-position
  completion ceiling; incremental-site size still unmeasured).
- Part B stands, blocked on P1 producing non-trivial producer signatures.

## 4.3 P1 adversarial review (2026-08-29, against code — pre-implementation)

- **AR-P1-1 — the hazard path is REAL, verified.** Registry stored sets reach
  devirt: `nodeSupportsRetranslation` covers every Define/Cycle node, and a
  retranslation re-encodes the stored type into a fresh store
  (`monoTypeToVarC`, `LSet → LsMembers`), whose members then flow through
  body unification into call-site zonks in later join rounds — the inputs
  `AbiCloning.stampCall` devirts on. A false-complete set recovered at the
  completion join is therefore a MISCOMPILE vector, not census cosmetics.
  The gate below is load-bearing.
- **AR-P1-2 — the gate: LICENSED kernel-alias nodes only.** Recovery applies
  iff the node is `Define/TrackedDefine (VarKernel _ home name _)` AND
  `KernelSetFacts.factFor home name = Just (TypeFaithful _)`. Soundness
  argument covering BOTH ABI branches: recovery fires only where the STORED
  side is `LSet` — meaning every demand agreed on a complete tracked set —
  and the license is precisely the audited proof that the kernel introduces
  no function inhabitants beyond its type's variable sharing. Any real
  extra inhabitant would have to arrive via a demand (making stored non-set)
  or via kernel fabrication (excluded by the license). Rowless/refused
  kernels are excluded: for them, fabrication is possible and the body-side
  ⊤ must keep absorbing.
- **AR-P1-3 — monotonicity/oscillation.** Recovery is a deterministic,
  idempotent post-join function of `(joined, stored)`; the actual side (the
  ABI rebuild) is constant across rounds; demand sets only union. Fixpoint
  arguments (LSS_010) unaffected; the completion write was already
  unconditional, and `changedJ` feeds census only.
- **AR-P1-4 — no lattice change.** `unionAnno`/`annoCovers`/SpecKey encoding
  untouched; recovery is site-local post-processing. The Part-C lattice
  hazard is entirely avoided in v1 — at the cost of leaving the non-kernel
  `aTop|nested` residue (classify-fallback vs poison indistinguishable)
  unaddressed; the A/B measures the captured fraction of the 1,516.
- **AR-P1-5 — L1 interplay.** Recovery runs BEFORE `stampSelfSpine`; the
  stamp never overwrites an `LSet`, so order is stable and the pair is
  idempotent. Recovery is strictly more general at head/spine for this node
  class (it restores demand sets, not just self members) — L1 stays for the
  non-kernel classes.
- **AR-P1-6 — flag/battery.** `lss.rsTop`, default OFF, env
  `ECO_MONO_LSS_RS_TOP`, token `lssRT` (artifact-affecting: stored types and
  hence retranslation demand keys move). A/B census + probes
  (`LssGapKernelPipeline` producer), elm-tests, E2E both arms on GO.

## 4.4 P1 implementation + probe results (2026-08-29)

**Shipped (flag `lss.rsTop`, DEFAULT-OFF, env `ECO_MONO_LSS_RS_TOP`, token
`lssRT`):**

- `Mono.recoverStoredSets : MonoType -> MonoType -> ( MonoType, Int )`
  (Monomorphized.elm) — parallel walk of (joined, stored); joined ⊤ over
  stored `LSet ms` restores `LSet ms`; count returned for the census.
- `licensedKernelAliasNode` (Monomorphize.elm) — Define/TrackedDefine with a
  bare-VarKernel body, Link-chased, whose kernel has a `TypeFaithful` row
  whose license APPLIES at the alias's occurrence type (`kMeta.tipe`).
- Wired into `completionJoin` between the raw join and the L1 stamp
  (AR-P1-5 ordering); census key `rsTop|recovered`, one bump per position.

**Probe A/B (JS loop, LssGapKernelPipeline, arrowCensus):**

| arm | coverage | rsTop|recovered |
|-----|----------|-----------------|
| off | positions=21 k1=16 kN=1 var=1 top=3, coveredBp=8095 | — |
| on  | positions=21 k1=18 kN=1 var=1 top=1, coveredBp=9047 | 12 |

Two registry ⊤s recovered to k1 (+9.52 pp at probe scale). NOTE the probe's
own `decodePair|/c0|top` row did NOT move — that ⊤ is CALL-BOUNDARY poison
(stored side is ⊤ too: the sTop class), outside P1's stored-LSet ⨯ joined-⊤
target. The 1,516 `aTop|nested` P0 cells are the in-class mass.

**Unit-test note:** a fixture-level off-vs-on differential is impossible —
the TestPipeline fixture graph has no kernel-alias nodes (the same E2E-only
constraint LssInjTotalTest's docstring records for L1). The probe A/B and
the scale A/B below are the differential pins.

## 4.5 P1 scale A/B (2026-08-29, native self-compile, same binary env A/B)

| arm | coverage | top | k1 | kN | var |
|-----|----------|-----|----|----|-----|
| defaults | positions=134,787 coveredBp=8764 (87.64%) | 3,668 | 87,840 | 30,288 | 12,991 |
| rsTop=1  | positions=134,787 coveredBp=8876 (**88.76%, +1.12 pp**) | **2,153 (−1,515)** | 89,294 | 30,349 | 12,991 |

- The −1,515 top is **99.9% of the 1,516 `aTop|nested` P0 target** — the
  reframed §4.2 prediction (+1.1 pp ceiling) captured almost exactly.
  Recovered positions land as k1 (+1,454) and kN (+61); var untouched by
  design.
- `rsTop|recovered` = 7,430 total bumps (per-join, so multi-round recounts of
  the same positions; the net registry effect is the −1,515).
- `jc|aTop|nested` raw-join cells 1,516 → 1,561: the census deliberately
  measures the RAW pre-recovery pair (§4.1), and arm-on's richer stored sets
  surface a few more collisions for the recovery to re-heal each round —
  expected, not a leak.
- Probe leg (§4.4) and defaults E2E 1,714/1,714 GREEN. Flag-on E2E
  (`ECO_MONO_LSS_RS_TOP=1`, test sources touched — harness cache env-blind)
  also **1,714/1,714 GREEN**; elm-tests at the known-12 baseline.
- **FLIPPED DEFAULT-ON 2026-08-29 (user decision).** Post-flip defaults E2E
  1,714/1,714, elm-tests 13,387/12 (known baseline).
- **Residual decomposition (the "1,516 vs −1,515" question):** the healed
  mass is exactly 21 callback-arrow keys (`andThen|/a0` 900, `map2|/a0(+/r)`
  122+122, `onError|/a0` 100, `foldl|/a0(+/r)` 62+62, `sortBy|/a0` 48,
  `initialize|/r/r/a0` 32, `map3` full family, `all`/`filter`/`sortWith`/
  `indexedMap`/`map`/`foldr`/`replaceAtMost`). ZERO keys gained top rows
  (no re-poisoning), and every partially-healed key's remaining top specs
  (foldl 89, map2 2, sortBy 2, …) are the **sTop class — stored side also
  ⊤**, out of P1's class by definition. There is NO identifiable in-class
  survivor: the 1,516th cell is a join EVENT whose position does not appear
  as a final-registry top in either arm — a spec pruned as unreachable (or
  re-keyed by respecialization) between its completion join and the final
  census walk; cells count join-time events, coverage counts final state.
  The remaining real ⊤ mass (2,153) is both-sides-⊤ — Part C territory.

**BLOCKING DISCOVERY en route (fixed):** the P1 battery was the FIRST full
E2E to include LssGapKernelPipeline, and it failed at DEFAULTS with garbage
output — a long-standing base-pipeline miscompile (both engines, LSS on or
off, oldest binaries on disk): the Json kernel stored escaping `Ok` payloads
BOXED where the static layout says unboxed (D.int/D.float/D.succeed/D.index
all returned pointer bits), plus `decodeValue` over encoder-built Values
returned Err (ENC_*/CTOR_JSON_* family split, never bridged). Fixed at the
escape boundary (`rewrapEscapingResult` + family bridge in JsonExports.cpp,
kind-aware reads in PlatformRuntime/PortRuntime), invariant HEAP_046 added,
31 kernel-license rows re-audited (manifest green), regression pin
test/elm/src/JsonDecodeScalarResult.elm. E2E 1,714/1,714.

## 4.6 ⊤ site-split census (2026-08-29, shipped — rides `lss.arrowCensus`)

`top sites:` line added to the census: every final-registry ⊤ position is
classified by NODE class (Link-chased). At the new defaults
(positions=134,828, coverage 88.76 %, top=2,154):

| class | n | % of top | reading |
|-------|---|----------|---------|
| ctor\|nested | 856 | 39.7 % | ⊤ inside CTOR demand types — bodyless members, no write path targets ctor slots (lss-ctor-arrow-identity.md territory). Placeholder-like. |
| elm (725 nested + 80 spine) | 805 | 37.4 % | manufactured/absorbed in Elm bodies — widening (byBudget=8,816 events dominates) + conflict joins + transported poison. |
| cycle (171 nested + 58 spine) | 229 | 10.6 % | same class, mutual-recursion groups. |
| licAlias\|nested | 222 | 10.3 % | licensed aliases whose stored side never got a set — inherited-unknown; Part-A provenance would split transported-poison vs never-known. |
| accessor | 38 | 1.8 % | accessor-keyed specs (37 head). |
| unlicAlias\|nested | 4 | 0.2 % | **kernel licensing as a lever is EXHAUSTED.** |
| refAlias | 0 | — | no refused-license tops. |

Limits: the census attributes by SITE (which mechanism could still reach the
position), NOT by HISTORY — whether a ⊤ that arrived at a licAlias/elm site
was BORN placeholder or poison needs the Part-A provenance bit; this table
bounds Part A's direct payoff at ~222 positions plus an unmeasurable
transported fraction of elm/cycle. Lever ranking now falsifiable:
ctor (856) > elm+cycle poison pool (1,034) > licAlias (222) ≫ licensing (4).

## 4.7 Limits factored out (2026-08-29, same-binary A/B; new env
`ECO_MONO_LSS_MAX_SET_SIZE` added alongside `ECO_MONO_LSS_MAX_SPECS`)

Arm `nolim` = budget 512→1,000,000 + setSize 8→100,000. All limit widening
eliminated (byBudget 8,818→0, bySize 8→0, bySigSize 5→0; byKernel 343→344
remains — kernel class, not a limit). Cost: wall 7:28.34→7:27.65 (FREE),
peak RSS +0.4 %.

| | base | nolim | Δ |
|---|---|---|---|
| positions | 134,836 | 140,420 | +5,584 (budget no longer folds demands into shared widened keys) |
| top | 2,154 | 2,123 | **−31 (−1.4 %)** |
| coverage | 87.64→88.76 % | 89.20 % | +0.44 pp (k1 +6,363, kN −786) |
| top sites moved | — | elm\|nested −10, cycle\|nested −21 | ctor 856, licAlias 222, accessor 38, unlicAlias 4 ALL UNCHANGED |

**Findings.** (1) The limits are STRUCTURALLY IRRELEVANT to the residual ⊤:
31 of 2,154 positions (1.4 %) trace to them; the §4.6 lever ranking is
unchanged with them factored out (ctor 856 = 40.3 %, elm+cycle 1,003 =
47.2 %, licAlias 222 = 10.5 %). Confirms and sharpens the Aug-28 refutation
at the new baseline. (2) **CORRECTION to §4.6's reading:** byBudget=8,818
looked like the dominant ⊤ manufacturer — it is NOT. Budget widening acts at
KEY MINTING (fan-out policy: demands share a widened spec key); it almost
never poisons the stored registry type. The elm/cycle pool is conflict-join
and transport manufacture, not limit widening. (3) The set-size limit is
nearly never binding: the whole compile has 8 oversize sets (6×9, 1×12,
1×21). (4) Un-budgeted self-compile is wall-neutral with +0.44 pp coverage
ratio — a default-raise is a plausible follow-up but the budget is the M4
pathological-workload backstop (elm-aws-codegen class), so it needs that
workload measured first, plus a dispatch leg.

## 4.8 No-limits SHIPPED as the default, spelled `0 = UNLIMITED` (2026-08-29)

User decisions, two steps: first the sentinel raise (100000/1000000), then
the cleaner rule — **`maxSetSize = 0` and `maxSpecsPerGlobal = 0` mean
UNLIMITED, and 0 is now the default for both.** The rule is enforced at all
five consultation sites: `Engine.enqueueSpecKeyed` (budget), the two
`Store` readback caps, and the two signature-channel B.4 riders in
`LssInfer`. `ECO_MONO_LSS_MAX_SPECS` / `ECO_MONO_LSS_MAX_SET_SIZE` (the
latter added this arc) restore any budget without a rebuild; non-zero
values still ride the `lssB=`/`maxSetSize` hash tokens.

Validation at the 0-defaults: census byte-identical to the §4.7 `nolim` arm
(positions=140,420, coverage 89.20 %, top=2,123, `widened: bySize=0
byKernel=344 byBudget=0 bySigSize=0` — the 0-rule provably engages), wall
7:24 / RSS 10.2 GB (unchanged), E2E 1,714/1,714, elm-tests 13,387/12
(known baseline). MuTieTest needed its budget PINNED in-harness
(`pinnedBudget = 64`, `maxSetSize = 8`) — the flag-off spiral's ONLY
terminator was the budget, so 0 = unlimited left it un-terminated (the 6th
overlapping-flag-pin occurrence). SEMANTIC NOTE: pre-2026-08-29 the
budget-0 experiment meant ZERO budget; that configuration is now spelled
with a tiny non-zero value.

Standing watch item: the elm-aws-codegen pathological-workload class — the
budget backstop no longer engages by default; if that class regresses, set
`ECO_MONO_LSS_MAX_SPECS`.

## 4.9 Part A v2 IMPLEMENTATION: the ⊤ provenance KIND (2026-08-30)

User-directed: not a bit — a KIND indicator on every ⊤, transported through
joins and the store, then a kind×site cross-census of the remaining 2,123.

**Taxonomy** (Int codes; JOIN = `min` — lower code = higher evidentiary
priority, so a position that ever saw real poison reads poison):

| code | kind | birth site |
|------|------|-----------|
| 0 | tkPoison | LSS_004 kernel-boundary poison (unlicensed/refused/shape-declined) |
| 1 | tkConflict | disagreement joins — LVar≠LVar, LVar×LSet (unionAnno + store unify) |
| 2 | tkWiden | maxSetSize / budget / sigSize / kernel widening caps |
| 3 | tkEdge | store readback fallbacks (edge Nothing / unresolvable slot) |
| 4 | tkAbi | kernel-ABI rebuild placeholder (hardcoded ⊤, store discarded) |
| 5 | tkDecl | declaration/classify placeholder (storeless classify, loadTypeC) |
| 6 | tkSynth | post-mono synthesized types (GlobalOpt/MapTemplate) — census-invisible |
| 7 | tkLegacy | unattributed catch-all (transitional; census shows the residue) |

**Neutrality invariants (the M3 lesson — provenance must be observationally
inert at defaults):**

- `annoHash`: `LTop _ -> 3` — spec hashes kind-blind by construction.
- `toComparableMonoType`: `LTop _ -> "A("` — SpecKeys kind-blind (no key
  dilution, the exact M3 failure mode).
- `eqModuloTopLabel`: `normalizeTopLabels` additionally canonicalizes every
  ⊤ kind (LVar → ⊤canon and ⊤k → ⊤canon); the allocation-free guard extends
  to "carries a non-canonical ⊤". Raw `==` fast paths stay sound: unequal
  kinds fall through to the normalized comparison.
- `joinAnnotationsChanged`: the `annoCovers` fast-arm keeps the LEFT ⊤
  pointer-shared (no kind merge there — convergent by construction; kinds
  are therefore FIRST-⊤-WINS at covers arms, priority-merged in `unionAnno`
  — the census reads this as a lower bound, noted honestly).
- Store `LsTop` → `LsTop Int` with EIGHT shared per-kind CAF contents
  (allocation-free writes preserved); Unify's absorb arms gain a
  (⊤,⊤) → min-merge case.
- GATE: at defaults the census totals (top/k1/kN/var), join
  rounds/retranslations must be IDENTICAL to the §4.8 baseline; E2E +
  elm-tests green.

**Tagging strategy:** bare `LTop` constructions start as `topLegacy`; the
arc's KNOWN manufacturers get true kinds (deriveKernelAbiType ⊤ → tkAbi,
poisonCallBoundary → tkPoison, storeless classify → tkDecl, unionAnno
conflict arms → tkConflict, widen caps → tkWiden, readback edges → tkEdge).
tkLegacy volume in the census = the honest not-yet-attributed residue.

**Census:** `top kinds:` line + `topkind|<kind>|<siteclass>` cross rows
(rides `lss.arrowCensus`) — kind = WHY it was born, site = WHERE it sits.

## 4.10 Part A v2 SHIPPED + the kind×site census (2026-08-30)

**Implementation landed** exactly per §4.9: `LTop Int` (+ per-kind CAFs
`topPoison..topLegacy`, `topOfKind`, `topKindLabel`), store `LsTop Int` with
8 shared CAF contents (`IO.lsTopContentK`), Unify (⊤,⊤) min-merge,
`unifySlotWithSet` takes `Maybe Int` (Just kind = ⊤ write),
`poisonArrowSets` writes tkPoison, `ArrowFact.topKind` rides the signature
channel, zonk readback transports the kind out, `eqModuloTopLabel`
canonicalizes kinds, `annoHash`/`toComparableMonoType` kind-blind. pos| rows
now read `top@<kind>`; census adds `top kinds:` (kind×site).

**Neutrality gates — ALL GREEN:** three probe artifacts BYTE-IDENTICAL
across the change (same config hash, same .mlir bytes); coverage ratio
8920bp unchanged; join flush rounds=0 retranslations=0 changed=0 — same as
baseline (no oscillation); wall 7:30 / RSS 10.26 GB unchanged.

**THE ANSWER — kind×site for all top=2,125 (ZERO legacy/edge/widen/synth —
every surviving ⊤ has a real birth kind):**

| kind | total | % | split by site |
|------|-------|---|---------------|
| decl (classify/declaration placeholder) | 1,233 | 58.0 % | ctor 549, elm 489, cycle 142, accessor 38, licAlias 15 |
| poison (LSS_004 kernel boundary) | 570 | 26.8 % | ctor 307, elm 195, cycle 65, licAlias 3 |
| abi (kernel-ABI rebuild placeholder) | 210 | 9.9 % | licAlias 206, unlicAlias 4 |
| conflict (LVar/LSet disagreement join) | 112 | 5.3 % | elm 111, cycle 1 |

Readings: (1) **placeholder classes (decl+abi) = 1,443 = 67.9 %** of the
residual ⊤ — never-observed, in-principle recoverable by write paths
(ctor-identity plan = the decl|ctor 549 + much of decl|elm); (2) **genuine
poison = 570 = 26.8 %**, and 307 of it sits INSIDE ctor payload demand
types (kernel-boundary ⊤ transported into ctor slots — licensing can't
shrink it further, unlicAlias=4); (3) conflict joins (the no-sum-lowering
residue, Part C's target) are only 112 = 5.3 %; (4) the licAlias bucket
decomposes as 206 abi-placeholder + 15 decl + 3 poison — the sTop residue
at licensed aliases is almost entirely the ABI rebuild's own placeholder
surviving because no demand ever knew better (NOT transported poison).

Caveat recorded from §4.9: covers-arm joins are first-⊤-wins and the
in-store skip arm does not kind-merge, so kinds are a deterministic
lower-bound attribution, not a full history lattice.

**Suite gates:** E2E 1,714/1,714; elm-tests 13,387/12 (known baseline)
after two test-side updates that are themselves new pins:
MonomorphizeTest's KernelAbi fixtures now expect `topAbi` (pinning the
derivation's kind), and ComparableKeyEncodingTest's fuzz generator varies
the ⊤ kind with the seed — the key/hash law tests now actively verify
kind-blindness (`annoHash`/`toComparableMonoType` must not split on
provenance).

## 5. Known traps to carry in (from this arc's records)

- Killed background tasks can lose queued file writes — verify edits landed
  before building.
- The JS fast loop (guida.js under node + `Debug.log`, ~60 s/cycle) is the
  diagnosis tool of choice; probe before native rebuilds.
- `pos|` drops the module — name-level attribution is not measurement.
- Q-shadow `REPRODUCES=NO` (~70 sub-diverges) is baseline; the gate is
  Q-infer.
- Flag-on `--target full` deletes `bin/eco-compiler`.
- Census-ON wall deltas are confounded when instrumented-site counts change;
  measure census-OFF for wall claims.
- elm-tests must run from `/work` (cwd-relative `build/`).

## 6. Success criteria for the pairing

1. `LssGapKernelPipeline` reads **fully covered** — consumer AND producer —
   at flags-on.
2. Self-compile coverage strictly above 88.07 % with the pair on; ⊤ falls at
   the nested-payload cells P0 identifies.
3. Dispatch exactly neutral; workload outputs byte-identical flag-off.
4. Lever 1's re-stamp measurably subsumed (its incremental effect ≈ 0 under
   `provJoin`) — the special case retired by the general rule.
