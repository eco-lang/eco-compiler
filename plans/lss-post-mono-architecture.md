# Post-monomorphization lambda-set solving

**Status: PHASE 0 COMPLETE, 2026-08-24 — verdict in §3.4: PROCEED, but §6's
sequencing is WRONG and is superseded there. §4–§5 stand. Measurements in
`benchmarks/lss-opt.md` Run AK; instrumentation pinned as LSS_035.**

**The thesis in one line: Eco's lambda-set analysis is incomplete at every read
because the set is part of the specialization key, and that one decision welds
the analysis to the pass that consumes it. Take the set out of the key and the
weld breaks — the spec graph becomes a fixed object determined by types alone,
and the sets can then be solved over it to a FIXPOINT, once, completely, before
anything reads one.**

The corollary that makes this cheaper than the version in
`plans/lss-set-variable.md`: **because Eco monomorphizes anyway, it can solve
AFTER monomorphization**, over a program that has no polymorphism left. That
removes the set variable, generalisation, instantiation and the
whole-program/reachable tension in one move. The paper cannot do this — it
defunctionalizes *instead of* monomorphizing, so it must solve over the
polymorphic program and therefore needs `α`. **Eco has an advantage here it has
never used.**

---

## §0 Where this comes from — the measured record

Five representation changes shipped in `plans/lss-unknown-elimination.md` and
`plans/lss-set-variable.md`. Their results, together, are the argument for this
plan:

| change | what it did | what it moved |
|---|---|---|
| Phase 1a — split ⊤ into widened/unknown | representation | nothing (byte-identical, by design) |
| **Phase 1b — stop re-encoding an unwritten slot as poison** | **removed a premature COMMITMENT** | **concrete +43.1 %** |
| Phase 2a — per-occurrence arrow identity | representation | analysis ↑, **dispatch −0.50 pp** |
| Phase 2b — solver-root arrow identity | representation | `rootAnn\|hitExact` 2.5 %→99.7 %, 959 signatures un-trivialised; dispatch untested (its self-compile does not lower, LSS_031) |
| Phase 3 — the set variable `LVar` | representation | `retranslations` −24…30 %, **completeness FLAT** |

**The one that worked is the one that stopped committing early.** The other four
improved how an incomplete answer is written down. That is the pattern this plan
acts on.

Supporting figures, all from the shipping-default arm of the same frozen corpus:

- **`var` = 254,211 of 432,578 readbacks = 58.8 %.** Nearly three fifths of all
  set reads return "not determined".
- `multiSetSites` = **(none)**. No call site anywhere carries a multi-member
  set, so there is nothing for sum lowering to consume.
- `devirtDirect` = 4,785, fast-dispatch coverage ≈ 22.07 %, `gen` = 1.78 B.
- The arrows that *do* accumulate multi-member sets are hubs: union sizes
  **15, 25, 140, 423, 504**.
- Dispatch is concentrated: top-10 fps = 33.7 % of `gen`, top-50 = 66.0 %,
  top-200 = 91.8 %; only 16 fps carry >1 % each.
- LSS_025's post-settle devirt finds ~420 sites the translate-time arm misses —
  **direct evidence that reading later finds more**.

**TWO OF THESE WERE WRONG, corrected by Run AK (§3.4):**

- The hub sizes (**15/25/140/423/504**) do **not** predict sum lowering's
  ceiling. They are what SURVIVED a keying regime that had already collapsed
  everything else into singletons. Turn keying off and the population inverts:
  302 multi-set arrows of which **229 (75.8%) fit inside `maxSetSize`=8**. §3.3's
  prediction that the megamorphic bucket dominates is refuted.
- "`devirtDirect` = 4,785" was `dispatchUpgraded`; `devirtDirect` at defaults is
  **4,524**. Both are recorded per arm in Run AK.

---

## §1 The architectural claim

Today the dependency is a cycle:

```
    the SET   is needed to choose which spec to make      (enqueueSpecKeyed)
    the SPEC  is needed to know the set                   (translate its body)
```

A cycle can only be resolved by iterating, iteration needs a JOIN each round,
and the join is where ⊤ comes from. Every piece of the compensation layer hangs
off that first link: ⊤-as-unknown, `unionAnno`, the LSS_010 dirty flush,
LSS_026(a)'s honesty rule, and the ~11 transport artifacts.

**Remove the set from the key and the first link vanishes:**

- spec choice depends on the TYPE alone → an ordinary demand-driven
  monomorphization, terminating on its own terms (MONO_030) and pruning to what
  `main` reaches;
- sets are computed over the resulting spec graph, which by then is a **fixed,
  finite object**.

So: drain to completion, then solve the sets to a fixpoint over exactly the
reachable spec graph, then let the consumers read. **Demand-driven discovery of
what to solve, followed by a complete solve over precisely that** — which is
what "a complete solve, on demand" means in practice.

---

## §2 Why solving AFTER monomorphization is the right side of the seam

`plans/lss-set-variable.md` §5 proposed solving BEFORE mono, over the
polymorphic `TOpt.GlobalGraph`. Post-mono is strictly easier:

| | pre-mono solve | **post-mono solve** |
|---|---|---|
| set variables (`α`) | required — the program is polymorphic | **not needed at all** |
| generalise / instantiate | required; `Engine.freshVar` says *"No generalization happens"*, so it must be built | **not needed** — nothing left to quantify |
| whole-program vs reachable | must solve over code `main` never reaches, or add a reachability pre-pass | **free** — solve the pruned graph |
| what a position is | an arrow in a polymorphic scheme | a concrete arrow in a concrete spec |
| analysis flavour | polymorphic set-constraint solving | **monomorphic 0CFA over a finite call graph** |

**And it retires Phase 3's `LVar`.** A variable expresses "unknown until
instantiated"; after monomorphization there is no more instantiation. Once the
fixpoint completes, "nothing wrote this position" is a COMPLETE statement, so it
grounds to ∅ where the inflow is closed and ⊤ at an opaque boundary.
`LambdaSetAnno` can go back to `LTop | LSet`. That is worth saying plainly:
**this plan supersedes work finished the same day**, and the honest reason is
that Phase 3 fixed the representation of an answer that was being read too
early.

**It also creates the multi-set population.** With sets out of the key,
`List.map` used with `inc` and with `double` is ONE spec whose callback arrow
carries `{inc, double}` — an honest 2-set. Today's set-keyed fan-out
*manufactures singletons by splitting those apart*. So removing sets from the
key is precisely what turns the near-empty multi-set population into a real one,
and it is what gives `plans/lss-sum-lowering.md` something to consume.

---

## §3 PHASE 0 — the two measurements. RUN THESE FIRST.

This register's record is that things get built and then measure flat. Both
items below are cheap and either can end the plan.

### §3.1 Item 1 — price the trade: `ECO_MONO_LSS=unkeyed` A/B

**Half a day, no code.** The unkeyed path already exists and is reachable
(`Builder/Eco/Config.elm:1200`, `Just "unkeyed" ->`).

Two arms on the frozen corpus (`/work/.lssue-snapshots/src-1a`, the harness in
`/work/.lssue-snapshots/README.md`), one binary:

| arm | env |
|---|---|
| keyed (today) | *(defaults)* |
| unkeyed | `ECO_MONO_LSS=unkeyed` |

Report, per arm: the §2.5 ledger, `multisets:` (arrows + `MSET` block),
`multiSetSites`, `devirtDirect`, `dispatchUpgraded`, spec counts, `widened
byBudget`, `retranslations`, and a **dispatch census A/B** (counters-lowered
binaries, `ECO_DISPATCH_STATS=1`, the `sat + fast` invariance rail) —
`benchmarks/runtime-calls.md` Run AE is the protocol.

**What it decides.** The unkeyed arm is a *lower bound* on the new
architecture's dispatch coverage: it removes set-directed specialization
WITHOUT giving anything back. The gap between the two arms is the hole that
sum lowering would have to fill.

- Hole small ⇒ this architecture is nearly free and can land before sum
  lowering.
- Hole large ⇒ sum lowering must land WITH it, not after, and the plan's
  sequencing changes.

It also gives the first real reading of **how many multi-member sets appear when
fan-out stops manufacturing singletons** — the number §0 says is `(none)` today.

### §3.2 Item 2 — test the premise: post-settle re-zonk of the ledger

**About a day.** Replay every readback the run made, later, and emit a SECOND
ledger line. Compare against the in-flight one.

#### §3.2.0 AMENDMENT (found while building it): the store is PER-ITEM

This plan was drafted assuming a re-zonk could run "at the end of `drain`", over
a long-lived store. **It cannot, and the reason reshapes the experiment.**
`Engine.resetItem` (`Engine.elm`) installs `store = freshStore` at the start of
**every work item**:

```elm
resetItem s =
    { s | store = freshStore, memo = CoreDict.empty, revMemo = Array.empty, … }
```

So a set slot read during translation can only ever be refined by writes that
land before that **same item** finishes. Item 1's Points are gone when item 2
runs; the cross-item flow is through `LssSignature`, the member table and the
annotations baked into spec `MonoType`s — never through the store. **There is no
long-lived store to settle into.**

Three consequences:

1. **The replay must run at `finishNode`,** the last moment the item's store is
   still alive — not after `drain`. Implemented as `Store.rezonkSettled`, driven
   by an `ItemAux.zonkLog` of every variable `zonkToMono` was handed
   (report-gated, store-scoped, cleared/restored on scratch-store swaps like
   `arrowMemo`). Same variables, same multiplicity, same denominator: only the
   TIME of the read differs, and the report prints `MATCHES=yes/no` to prove it.
2. **This is not an approximation of the post-mono read — it is the complete
   UPPER BOUND** on what reading-later can buy inside the current architecture.
   Whatever it does not recover is, by construction, reachable only by a solve
   that outlives the item.
3. **§3.2's original stop criterion was wrong.** "The ledger barely moves"
   does NOT imply "genuinely unconstrained": it is equally consistent with the
   members existing in *another item's* store, which per-item teardown
   guarantees can never meet. That reading argues **for** this plan, not
   against it, so a flat delta cannot discriminate on its own.

#### §3.2.1 The corrected criterion — the discriminator

Split the still-`var` population by `ArrowId` (the `settled-var-arrows:` line):

| bucket | meaning | verdict |
|---|---|---|
| **knownElsewhere** | that arrow read back a CONCRETE set in some **other** item | the prize — unreachable under per-item teardown, resolvable by one global solve ⇒ **PROCEED** |
| **unknownEverywhere** | nothing anywhere ever writes that arrow (kernel/FFI/port/`Debug`) | no reordering reaches it ⇒ the ceiling is Eco's **setting**, not its schedule ⇒ **STOP** |

Scored against `setArrows` — arrows that resolved to a set of **any** size — and
deliberately **not** against `multiSetsByArrow`, which is gated at `|set| ≥ 2`:
an arrow resolved to a **singleton** elsewhere is still known elsewhere, and
scoring against the multi-set table alone misfiles it as unconstrained and
**overstates** the kernel-boundary ceiling.

So the three numbers that decide it are `dVar` (intra-item settling),
`knownElsewhere` (what a global solve would add), and `unknownEverywhere` (the
hard floor).

Implementation note: READ-ONLY under `lss.report`, or it becomes a behaviour
change wearing a census's clothes. `zonkToMonoC` *does* mutate its `ZonkCtx`
(path compression, residual stamping, member interning), so the final ctx is
dropped entirely and only `ctx.lss` is read. Pinned as **LSS_035**.

#### §3.2.2 RESULT (2026-08-24, `benchmarks/lss-opt.md` Run AK): **intra-item settling recovers EXACTLY ZERO**

Built as `Store.rezonkSettled` (LSS_035). Frozen corpus, one binary
(`/work/.lssue-snapshots/eco-boot-ph0.js`), shipping defaults.

**The read-only rail passes in its strongest form.** The instrumented binary's
in-flight ledger is unchanged digit for digit, and its emitted `.mlir` is
**BYTE-IDENTICAL** to the pre-change binary's —
`c9ae525e2601518c50696d2929ab40b8`, 14,786,349 B. The census cannot be
influencing what it measures.

```
ledger:          k1=147708 kN=557 overcap=7 top=30095 var=254211 total=432578
ledger-settled:  k1=145173 kN=557 overcap=7 top=29995 var=249519 total=425251  items=39341
```

`MATCHES=NO`, short by **7,327 (1.7%)** — readbacks made inside a scratch store
(`Engine.withScratchStore`), whose Points die with it and which therefore cannot
be replayed at all. And the bucket deltas sum to exactly that shortfall:

```
−2,535 (k1)  + 0 (kN)  + 0 (overcap)  − 100 (top)  − 4,692 (var)  =  −7,327
```

**Zero unexplained. Every readback that COULD be replayed returned the identical
classification.** Not one variable became a set by being read later. `var` is
58.77% in flight and 58.68% settled — the same population, minus the part that
could not be re-read.

This is the answer to §3.2's question, and §3.2.0 says why it had to come out
this way: with a fresh store per item, the only settling window is inside one
spec's translation, and translation already walks the body in order.

#### §3.2.3 The discriminator — and why it MUST be read on the arrow-identity arm

The discriminator is only as good as its join key, and at shipping defaults the
key is broken. Arrow ids exist without any lss flag, but without
`arrowSolverRoots` they are **per-occurrence**: the same syntactic arrow reached
from two different items gets two different `ArrowId`s, so "did this arrow
resolve in some other item" systematically answers *no*. Arm D exists to close
exactly that hole, and it moves the answer by 5×:

| arm | arrow ids | attributed | knownElsewhere | unknownEverywhere | known as % of ALL readbacks |
|---|---|---|---|---|---|
| **Ap** (defaults) | per-occurrence | 203,687 | 16,866 = **8.3%** (619 arrows) | 186,821 = 91.7% (10,119) | 3.9% |
| **D** (`ARROW_ID=1 ARROW_ROOTS=1`) | solver-root | 207,485 | 90,523 = **43.6%** (5,222 arrows) | 116,962 = 56.4% (3,845) | **20.1%** |

**Read arm D. Arm Ap's 91.7% is an artifact of the broken join key, not a
finding.** With a stable key, **43.6% of the attributed `var` population sits at
arrows that DO resolve to a concrete set elsewhere in the run** — 90,523
readbacks, **20.1% of all readbacks**. That is the population a solve outliving
the item could claim and per-item store teardown structurally cannot.

**And arm D shows the FIRST non-zero settling effect ever measured here.** In
Ap/B/C every replayed readback returned an identical classification (all bucket
deltas ≤ 0, summing exactly to the un-replayable shortfall). In arm D two
buckets go **UP**: `kN +231` (5.3% of its multi-sets) and `top +109`, with the
total still reconciling to −7,544 exactly. Readbacks genuinely *changed class*
on being re-read.

The mechanism is visible one line away in the census: `set-writes … union=2225`
in arm D against **`union=0`** in Ap. **Arrow identity is what makes arrows
SHARE a slot; sharing is what lets a write through one arrow become visible at
another; and that is what creates a settling window at all.** Without it each
slot is private and there is by construction nothing to accumulate — which is
precisely why Ap/B/C measured a flat zero.

**CAVEAT that must ride with the 43.6%.** It bounds *the same constraint system,
joined across items*. A post-mono 0CFA builds constraints from the monomorphic
program directly rather than by unification during translation, so it is a
different system and this is neither an upper nor a lower bound on it. What it
does establish is the thing §3.2 was asked to decide: **a large part of the
`var` population is information that exists in the program and is lost to the
per-item store — not information that was never written.**

---

## §3.4 PHASE 0 VERDICT (2026-08-24) — **PROCEED, and §6's sequencing is WRONG**

Run AK, four census arms + three dispatch arms, one binary, one frozen corpus.
Both halves answered.

### The two numbers that decide it

| question | measured | reads |
|---|---|---|
| Is the `var` population MISTIMED or ABSENT? | **43.6%** of the attributed population is at arrows that resolve **elsewhere** in the run (20.1% of all readbacks) | **PROCEED** — a solve outliving the item has real material |
| What does `keyed = False` cost on its own? | fast dispatch **22.093% → 7.936%**, **−14.16 pp**, **−318.7 M** | **step 1 cannot ship alone** |

### The finding that reprices the plan

`keyed = False` **does not** trade singletons for honest multi-sets. It destroys
**16,221** `k1` readbacks and creates **1,307** `kN` — a **12.4 : 1
destruction-to-conversion ratio**. The lost singletons become `var`/`top`. Only
**8 call sites** carry a multi-member set sum lowering could consume, against
1,584 lost devirt stamps.

**So sum lowering cannot rescue step 1 — the population it consumes is not the
population that was lost.** The thing that would recover those 16,221 readbacks
as resolved sets instead of unknowns is the post-mono solve itself.

### Consequence for §6

**Steps 1–3 are ONE change or they are nothing.** §6 was written as an
incremental ladder with step 1 landing first "with the §3.1 numbers as the
accepted cost". That is not available: the cost is 64% of fast dispatch, paid
immediately, with the compensating mechanism two steps away. Revised shape:

1. **Build `solveLambdaSets` in shadow mode FIRST, under today's `keyed = True`.**
   Dump its ledger, compare against the in-flight analysis. This is now the
   *first* step, not the second — it is the only way to learn whether the solve
   recovers the 16,221 before betting the dispatch coverage on it.
2. **Gate on the shadow ledger:** the solve must resolve at least the
   ~90.5 K readbacks the discriminator says are knowable, and specifically must
   turn `k1`-lost-to-unkeying back into `k1`. If it does not, **STOP** — the
   architecture has no path to paying its own bill.
3. **Only then** flip `keyed` and consume the solve, in ONE commit, with the
   dispatch census as the acceptance gate (recover to ≥22.09%).

### What also has to be true

Arrow identity is **load-bearing for this whole architecture**, not an optional
precision knob. §3.2.3: the settling window exists only when arrows share slots
(`set-writes union=2225` on arm D vs **`union=0`** at defaults), and the
cross-item join is only measurable under solver-root ids. But
`arrowSolverRoots=1` **still does not lower** (LSS_031, unfixed). **That defect
is now on this plan's critical path** — it was previously a parked Phase-2b
follow-up.

### Arm D is the interesting shape

On the static count arm D keeps essentially all the devirt stamps (4,758 vs
4,785, −0.6%) **and** gains 1,009 multi-set arrows and 31 multi-set sites — it
does not pay the unkeying bill. Its costs are `declinedNoInstance` ×6.2
(LSS_017-v2 / LSS_030) and LSS_031. **If LSS_031 and LSS_017-v2 were fixed, arm
D is a cheaper route to the same feedstock than unkeying is** — worth pricing
before committing to §6 at all. Its dispatch cost is unmeasured (its `.mlir`
does not lower).

### §3.3 Optional item 3 — the per-site polymorphism census

Not a gate for THIS plan, but it is the number that decides which consumer to
build afterwards, and the runtime already has most of it (the `[dispatch-stats]`
fp→counter hash, the `ECO_DISPATCH_STATS` gate, the exit dump, and
`ECO_LSS_DISPATCH_SITE_COUNTERS` proving per-site counters can be lowered).

At each generic dispatch site, record the distinct callee fps seen and the event
count; dump a histogram:

```
sites with 1 distinct callee : N sites, X events (Y% of gen)   → devirt's ceiling
sites with 2–8               : N sites, X events (Y% of gen)   → SUM LOWERING'S ceiling
sites with >8                : N sites, X events (Y% of gen)   → out of reach of both
```

§0's hub sizes (140/423/504) predict the third bucket dominates. If that is
right, sum lowering's ceiling is small and the effort belongs on the producer
side — which is what this plan is.

---

## §4 The seam, and the new pass

`MonoSolver/Monomorphize.elm` already has the exact insertion point:

```elm
case drain s2 of
    Ok sFinal ->
        let
            graph =
                pruneGraph sFinal (assembleRawGraph sFinal mainSpecId maybeFlagsSpecId)
```

and the consumer entry is `MonoGlobalOptimize.globalOptimize : Mono.MonoGraph ->
Mono.MonoGraph`. So the pipeline becomes:

```
drain  →  assembleRawGraph  →  pruneGraph  →  [ NEW: solveLambdaSets ]  →  globalOptimize
```

`solveLambdaSets : Mono.MonoGraph -> Mono.MonoGraph` — same shape as
`globalOptimize`, running AFTER the prune so it solves only reachable specs.

**What it does.** A monomorphic 0CFA over the spec graph:

1. **Generate.** Walk every spec body. At each `MonoClosure`, its member id is a
   lower bound on the arrow it flows into. At each call, the callee's parameter
   arrows receive the argument's arrows; the result arrow flows out. Control-flow
   joins (`if`/`case`) union their branches. Kernel/FFI/port/`Debug` crossings
   emit ⊤.
2. **Solve.** Least fixpoint over the inclusion constraints. Flat `Int` member
   ids mean the lattice is finite sets over a finite universe, so ordinary
   worklist saturation terminates — **no `µ`**, for the reason
   `plans/lss-set-variable.md` §3 already established.
3. **Write back.** Fill every `MFunction`'s annotation from the solution.

---

## §5 What moves, what dies, what stays

**Already in the right place** — this is what makes it tractable. Almost all set
CONSUMERS are already post-mono:

| consumer | runs | moves? |
|---|---|---|
| `AbiCloning.stampCall` | `MonoGlobalOptimize` | **no** |
| `MapTemplate` | post-mono | **no** |
| `Borrow/LssFacts` | post-mono | **no** |
| LSS_025 post-settle devirt | post-mono | **no** |
| **`Translate.devirtDirectTarget`** (LSS_015/016, `Translate.elm:2130`) | **during translation** | **YES** — but LSS_025 is the working model for exactly this move |

**Reusable as-is:** `LssMemberTable` (the global member universe and its
interning), `Engine.pointKey`/union-find, the arrow identity from Phase 2b (for
naming positions in diagnostics), the multi-set census (`MSET` + the ledger +
`benchmarks/multiset-census.py`), the frozen-corpus harness.

**Dies, and only once the fixpoint is proven complete:**

- `Mono.unionAnno` / `annoCovers` and the whole join lattice — nothing joins any
  more, positions are SOLVED.
- ⊤-as-unknown; ⊤ narrows to the incompleteness marker.
- The LSS_010 dirty flush and `retranslations` — nothing to propagate backwards.
- LSS_026(a)'s honest-∅ rule — vacuous, because nothing is read before
  completion. **Note this is the opposite of `lss-set-variable.md` §1.3's
  conclusion**, and the reason is the seam moved: a pre-mono solve still reads
  during mono and needs the oracle; a post-mono solve does not.
- Most of the ~11 transport artifacts — they exist to reconnect slots the loader
  split, and there are no slots.
- `maxSpecsPerGlobal`'s LSS role — it is a set-fan-out budget.
- `LVar` and Phase 3's numbering (§2).

**Stays, because it answers Eco's setting rather than its representation:**
kernel/FFI poison (LSS_004/021/022), MONO_030's ordinary monomorphization
watchdogs, `#3b standaloneArgMember`, `#4b`, `#11(d) selfIdOf`.

---

## §6 Implementation steps

Each step is separately gated; none of them is started before §3 says proceed.

1. **Flip `keyed` to False** and land the fallout, with the §3.1 numbers as the
   accepted cost. This alone breaks the cycle.

   **CORRECTION (measured, Run AK arm B).** This step originally claimed
   "registry joins on annotations stop; `retranslations` should approach 0".
   **That is backwards.** Measured: `retranslations` 310 → **1,249 (×4.0)** and
   `joins changed` 694 → 2,976 (×4.3). The mechanism is obvious in hindsight —
   `keyed = True` SEPARATES demands into different specs so no join is needed;
   `keyed = False` merges them, and the LSS_010 join becomes the *only*
   mechanism that reconciles them. So step 1 alone makes the join **more**
   load-bearing, not less. The join dies at step 3, when the solve moves out of
   translation entirely — not here.
2. **Build `solveLambdaSets` in SHADOW MODE.** Run it, dump its ledger, compare
   against the in-flight analysis. Do **not** consume it. This is where the
   completeness claim is verified against real data at zero risk to codegen.
3. **Consume it.** Annotations come from the solution; `LssInfer`'s in-flight
   writes go quiet.
4. **Move `devirtDirectTarget` post-mono**, following LSS_025's pattern.
5. **LSS_017-v2** (`plans/lss-fork-qualified-members.md` §8) if the member-identity
   census says it is needed — post-mono, a member is a concrete lambda in a
   concrete spec, so the LSS_017 hijack may dissolve on its own. **Measure before
   building.**
6. **Delete** the §5 list, one piece per commit, each byte-neutral or
   individually measured. The rails exist: the two-binary method, the frozen
   corpus, the ledger, the per-arrow census.
7. **Then** decide the consumer: `plans/lss-sum-lowering.md`, priced by §3.3.

---

## §7 Hard parts, named

- **The `keyed = False` regression is real and immediate.** Step 1 gives up
  specialization-manufactured singletons before step 7 gives anything back.
  §3.1 measures it; if it is large, steps 1 and 7 must land together, which is a
  much bigger single commit.
- **Post-mono graphs are large.** The monomorphic spec graph has many more nodes
  than the polymorphic program. Mitigated by solving post-prune and by
  `keyed = False` shrinking the spec population, but it is the main perf risk
  and `solveLambdaSets` will be on the compile-time critical path.
- **Precision is context-insensitive WITHIN a spec.** Specs give
  type-directed context sensitivity for free, but two call sites in one spec
  body share their arrows' sets. Today's set-keyed fan-out is finer. Whether
  that costs anything is an empirical question for the shadow-mode arm.
- **Recursive specs and SCCs.** The fixpoint must handle cycles in the spec call
  graph. Standard, but it is real work, and the poly-rec fixture that currently
  hangs natively (`lss-unknown-elimination.md` §1.1) must terminate here.
- **`Prune` runs before the solve.** Checked: `Monomorphize/Prune.elm`'s
  `pruneUnreachableSpecs` is pure reachability from `mainSpecId`, so solving
  post-prune loses nothing a *caller* can reach. The residual risk is narrower
  and worth pinning: it marks via **`callEdges`**, so a spec that is only ever
  named as a closure VALUE — exactly the specs that become set members — must
  still be edge-reachable, or the solve will hold member ids pointing at pruned
  specs. Check this in shadow mode (step 2) by asserting every solved member id
  resolves to a live spec; it costs one pass and catches the failure at its
  source instead of in MLIR.

---

## §8 Gates

Per step, on the frozen corpus, using the existing harness:

1. §2.5 ledger with `RECONCILES=yes`, and the multi-set census (`multisets:`
   arrows + `MSET`) — **the headline for this plan is `var` FALLING**, which is
   the whole premise.
2. `multiSetSites` — expected to become non-trivial for the first time (§2).
3. Dispatch census A/B with the `sat + fast` invariance rail. Coverage is a
   REGRESSION GUARD, and step 1 is expected to regress it by design; the guard
   is that step 7 recovers it.
4. elm-tests at the pre-existing failure set; E2E `--target full` 1,687/1,687.
5. **A SELF-COMPILE LOWERING**, every arm. LSS_031 records why: `--target full`
   passed 1,687/1,687 with `arrowSolverRoots=1` while that flag's self-compile
   MLIR did not lower, because the E2E corpus is small programs. **Any change to
   lambda-set identity or annotation content must lower the self-compile.**
6. Wall/GC per `benchmarks/lss-opt.md`; `solveLambdaSets` is a new pass on the
   critical path and must be costed, not assumed free.

---

## §9 Non-goals

- **Defunctionalization / sum lowering** is `plans/lss-sum-lowering.md`. This
  plan produces its feedstock and prices it (§3.3); it does not build it.
- **Removing kernel/FFI ⊤.** Out of scope permanently — it is Eco's setting.
- **Anything in `plans/lss-set-variable.md` §5's Order A/B.** This plan replaces
  that sequencing; the analysis in its §1–§4 (especially Q2 and Q5) stands and
  is what led here.
- **The `IO (\state -> …)` source rewrite** — still 68.6 % of generic dispatch,
  still cheaper than all of this, still without a plan file. If §3.3's histogram
  says the hot sites are megamorphic hubs, that rewrite outranks everything
  here and this plan should be reconsidered against it.
