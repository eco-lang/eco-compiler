# Live-heap composition census — measuring retention instead of allocation

**Status: NEW 2026-08-05. The prerequisite for `plans/cse-pure-calls.md`,
`plans/accumulator-templates.md` and `plans/sum-type-wrapper-unboxing.md` —
all three are admitted or rejected by the numbers this plan produces.**

**Provenance:** closing out `plans/opt-tier2-cons-fusion.md`, which ranked
every one of its units by an `ECO_CONS_SITES` *allocation* census. That
metric has now been falsified three separate times (§0). The named
prerequisite is not new — `plans/mono-comparable-key-optimization.md` §13
already wrote it down:

> *"GC cost here follows SURVIVORS, not allocation volume… Sizing that
> requires a live-heap composition census, and that — not another allocation
> count — is the prerequisite."*

K6 and K7 then shipped without it and won anyway. Nobody should count on
that twice.

> **CATEGORY: measurement infrastructure.** This plan makes no program
> faster. It changes what we choose to build next, which on the evidence
> below is worth considerably more than another 1% unit.

---

## 0. Why — the metric falsification, in three controlled experiments

| change | allocation | promotion | wall |
|---|---|---|---|
| chunked lists (`chunked-list-representation.md` §6 L1 exit gates) | **−349.6M Cons (−47.5%), −261.9M objects** | not measured | **0** |
| K4 hash-consing-lite (`mono-comparable-key-optimization.md` §11, Run C) | −21.3% apparent / −1.31% true | **identical (375.9M)** | **flat (−0.35%)** |
| K6 construction-time hash-consing, solver (§15, Run F) | **+0.02% (allocates MORE)** | **−7.04% (−29.2M)** | **−5.07%** |

Run F states the mechanism without hedging: *"this change allocates nothing
and keeps 29M fewer objects alive"* — GC time covered **91%** of the wall
delta, majors 13→10, max RSS −13.2%.

The explanation is the collector's own cost model. A copying nursery pays
for **survivors**, not for allocation volume: dead-on-arrival objects cost
one inlined bump-pointer increment (HEAP_034) and are never touched again.
Removing them is therefore nearly free *to remove* and nearly free *to keep*.
Everything the opt-tier series has ranked by allocation count has been ranked
by a number the collector does not charge for.

**What nobody can currently answer:** of the ~357M (subst) / ~386M (solver)
objects promoted per self-compile, *what are they?* There is no per-tag,
per-site, or per-shape breakdown of the surviving set anywhere in the
runtime. Every retention decision to date has been inferred.

## 1. What exists, and the exact gap

**Exists — allocation side, complete:**

- Per-tag mutator allocation histogram: `tlh_alloc_count_by_tag` /
  `tlh_alloc_bytes_by_tag`, fed from `initHeaderForTag`, dumped as
  **"Mutator Allocations by Object Kind"** with count/percent/bytes/avg
  (`runtime/src/allocator/GCStats.cpp:1251-1297`).
- **The inline-alloc blind spot (census §18.3):** the HEAP_034 inline fast
  path writes its header word inline and never reaches the counter, so the
  standard binary undercounts codegen'd constructs ~6-10×. Every allocation
  figure needs a separate `ECO_INLINE_ALLOC=0` census leg. This trap has
  produced a wrong headline **twice** (K2 and K4).
- Site attribution precedent: the `ECO_CONS_SITES` return-address tally
  (`runtime/src/allocator/RuntimeExports.cpp:266-330`) — thread-local maps
  merged into a global at thread destruction, dumped at exit with the
  main-module base so sites symbolize offline via `addr2line`.

**Exists — retention side, one scalar:**

- `objects_promoted` (`GCStats.hpp:59`), incremented by
  `GC_STATS_MINOR_INC_PROMOTED` at exactly three sites:
  `NurserySpace.cpp:1263` (`evacuate`), `:1418`, `:1935`. Merged at
  `GCStats.cpp:693`, reset at `:1454`, printed with a promotion rate at
  `:867-875`.
- `objects_survived` — the to-space (non-promoted) counterpart.

**Missing — everything that would let you act on it:**

| question | today |
|---|---|
| which *kinds* get promoted? | unknown — one scalar |
| which *allocation sites* produce survivors? | unknown |
| what is the steady-state *live set* made of? | unknown |
| promoted because old, or dragged in by a promoted parent? | unknown |
| how much of the live set is retained across majors vs. promoted-then-died? | unknown |

**The decisive structural advantage of measuring here (state this in the
report, it changes the workflow):** promotion is counted **inside the
collector**, which the HEAP_034 inline fast path does not bypass. Retention
metrics are therefore *trustworthy in the standard binary* — no
`ECO_INLINE_ALLOC=0` census leg, no ~6× correction, no third repeat of the
K2/K4 misread. **Retention can be measured on the same binary whose wall you
are measuring.** Allocation never could.

## 2. Units

Staged cheapest-first. LH1 alone is expected to re-rank the backlog; stop
after any unit whose successor no longer justifies its cost.

### LH1 — per-tag promotion + survival histogram (do first: hours, no risk)

Mirror the allocation histogram on the retention side. Add
`promoted_count_by_tag` / `promoted_bytes_by_tag` (and the `survived_*`
pair) to `GCStats`, sized `NUM_ALLOC_TAGS` exactly as the allocation arrays
are. The tag is already in hand at all three promotion sites as
`new_hdr->tag`; the survival sites are the matching to-space copies. Merge
in `GCStats::merge` alongside `objects_promoted` (`:693`), zero in the reset
path (`:1454`), and print a **"Promotions by Object Kind"** block using the
existing `printRow`/`tagName` renderer immediately after the allocation one.

**Deliverable:** the promotion analogue of the table that has driven every
decision in this series, plus a per-tag *survival rate* (promoted ÷
allocated) — the single number that says whether a class is nursery garbage
or real retention. Expected shape, worth predicting in advance so the result
can surprise us: `Cons` and `Tuple2` high-allocation/low-survival (the
chunk and K4 results imply it), `Custom`/`Closure` the reverse.

**Gates:** `ENABLE_GC_STATS=0` builds compile to zero overhead (the existing
macro discipline gives this for free — verify, don't assume); no change to
emitted MLIR; full E2E once, teed.

### LH2 — promotion cause and age split

Distinguish the three promotion sites and record the age at promotion.
`NurserySpace.cpp:686-714` drains a `promoted_objects` queue under an
explicit invariant — *"every child of a promoted object must be at least as
old as the parent"* (`:687`, `:1269`) — so a promotion is either

- **primary:** the object was itself old enough / root-reachable, or
- **transitive:** it was dragged into old-gen by a promoted parent.

That distinction is the difference between "this allocation site is the
problem" and "this allocation site is innocent and one retained *root* is
dragging a subgraph across". They demand opposite fixes, and no current
counter separates them. Record the split per tag.

### LH3 — live-set composition at major GC

Tally per-tag count/bytes of every object marked black during a major cycle.

**Hook `OldGenSpace::markOneObject` itself** (`OldGenSpace.cpp:1814`, with
the `:1864` overload delegating to it) — *not* the callers. Every mark path
funnels through it precisely so attribution stays consistent: the
allocation-paced loop (`:647`), `incrementalMark` (`:1612`), and the
stats-build branch that deliberately calls it directly "to avoid touching
the stats counters" on the allocation hot path (`:637-647`). Hooking a
caller would miss paths and would put stats work back on the hot path the
existing code takes care to keep clean.

**The precedent is exact:** per-block `live_bytes` accounting is *already*
populated by `markOneObject` during mark (`:2554`, `:2619`). A per-tag tally
is the same shape of work in the same place.

This answers a strictly stronger question than LH1: promotion is *flow into*
old-gen, marking is the *standing* live set. A class can dominate promotion
and still be irrelevant if it dies in old-gen before the next major; a class
can be modest in promotion and dominate the marking cost that showed up as
"3 fewer majors" in Run F. Mark cost is what majors actually charge for.

### LH4 — site attribution for survivors (only if LH1-LH3 leave it ambiguous)

Two designs, cheap first:

- **LH4a — proportional bridging (free).** Do not attribute directly. Join
  LH1's per-tag survival rate against the existing per-tag *site* tallies
  (`ECO_CONS_SITES` and any successor). If tag T survives at 2%, every T
  site is exonerated at once; if T survives at 60%, its top sites are all
  implicated. This answers most practical questions for zero new machinery
  and should be tried before LH4b is written.
- **LH4b — nursery side-map (measurement builds only).** The nursery is
  bump-allocated and non-moving within an epoch, so a per-TLAB parallel
  array of caller return addresses, indexed by object offset, is valid for
  the whole epoch and can be consulted at evacuation time to attribute each
  promotion to its allocation site. Costs one word per nursery object —
  acceptable in a measurement build, never in the shipped one. Gate behind
  its own env flag alongside `ECO_CONS_SITES`.

### LH5 — the report, and the re-ranking

Record the tables in `design_docs/borrow-inf-census.md` as a new section
(§18 is where the allocation profile already lives), then **re-rank the
opt-tier backlog against them and write the re-ranking down** — including
the units this plan kills. A census that does not close anything has not
been read properly.

## 3. Decision gate D-LH (what the successors need from this)

Each successor plan names the number it needs; this is the single place they
are defined:

| plan | admitted iff |
|---|---|
| `sum-type-wrapper-unboxing.md` | `Custom` **promoted** share ≥ 10% of promotion, AND single-field wrappers are a measurable slice of it |
| `accumulator-templates.md` | `Cons`+`ConsChunk`+`ListBacking` **promoted** share ≥ 5%, or LH3 shows list spines dominating mark cost |
| `cse-pure-calls.md` | not gated on retention (its win is deleted work, not deleted objects) — but LH1 tells it whether CSE's live-range extension is affordable, which is its main risk |

Record the outcome either way. A failed gate is a result, not a setback —
this series has four precedents where a static census correctly killed a
unit before it was built.

## 4. Risks

- **Do not let this become a shipped-binary cost.** Everything here lives
  under `ENABLE_GC_STATS` / an env flag, output-only, excluded from the
  artifact hash (the `mono.validate` / `borrowCensus0` precedent in
  `compiler/src/Compiler/Eco/Config.elm:110-111`).
- **Do not re-derive allocation numbers from this instrumentation.** The
  inline-alloc blind spot still applies to the allocation side; only the
  retention side is clean. Keep the two clearly labelled in the dump.
- **GC-trigger lottery:** never report a wall without its major count.
  Retention changes move major counts, which is exactly why walls move —
  record both or the causal story is unverifiable.
- Run E/F/G legs compile *the compiler's own source*, which these changes do
  not touch — so unlike the K-track runs, raw walls here stay comparable
  across baselines.
- E2E/elm-tests cache race: run serially; run E2E once, teed, and grep the
  file.

## 5. What this plan explicitly does not do

- No transform, no codegen change, no new pass.
- No attempt to *reduce* retention. Identifying the retained set is this
  plan; acting on it is the successors' job, and which successor gets
  scheduled is the whole point of running this first.
