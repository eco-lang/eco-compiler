# Promotion-time list chunking — build chunks where the survivors are

**Status: NEW 2026-08-05, PROPOSED (user), UNSIZED. Two gating
measurements before any implementation: P1 (promoted-spine run-length
histogram) and LH3 (mark-cost composition).**

**Provenance:** proposed on reading the LH1 result
(`plans/live-heap-composition-census.md`, `benchmarks/tier2-opt.md` Run H).
LH1 showed `ConsChunk`+`ListBacking` are **0.05%** of promotion while raw
`Cons` is **36.7%** — i.e. the shipped chunked-list representation is almost
entirely absent from the retained heap. The proposal: stop trying to build
chunks at *construction*, and build them at *promotion* instead.

> **CATEGORY: runtime/GC.** No codegen change, no compiler pass, no
> language-level representation change. This is the first unit in the
> series whose entire implementation lives in the collector.

---

## 0. The idea

When a `Cons` cell is promoted into old gen, walk its spine and emit **one
`Tag_ListBacking` + one `Tag_ConsChunk` view** covering the whole promotable
run, instead of N individual `Tag_Cons` cells.

## 1. Why it is sound — the invariant does the work

Elm values are immutable, so a cons cell's tail is always constructed before
the cell itself and is therefore **at least as old**. The collector states
and *enforces* this:

> *"By Elm's immutability invariant, every child of a promoted object must
> be at least as old as the parent and therefore also qualify for
> promotion."* — `NurserySpace.cpp:687`, asserted again at `:1269` under
> `ECO_HEAP_VALIDATE` (a phase-3 child too young to promote aborts).

Consequently a promoting cons cell's tail is always one of: promoting in
this same cycle, already in old gen, already forwarded, an embedded constant
(`Nil`), or a non-`Cons` object. **There is no case where a promoted cell is
followed by a cell that stays in the nursery** — which is exactly the
property that makes a contiguous promoted run well-defined. The one caveat
is `pin`/`builder`, which forbid promotion independently of age
(`HEAP_BUILDER_001/002`); no kernel currently marks `Cons` cells either way,
but the walk must bail rather than assume.

## 2. Why the delta is much smaller than it looks

**A spine walk already exists — but read what it is for.**
`NurserySpace::evacuateListSpine` (`:1847`) is entered from `scanObject`'s
`Tag_Cons` arm (`:1650-1672`), gated on `use_hybrid_dfs` (default `true`,
`main.cpp:114`). **Its purpose is nursery Cheney-copy locality**, not
promotion: it exists so surviving spines land contiguously in to-space.
There is **no dedicated promotion-time spine pass today.**

What it does give this proposal is that the same walk *also* makes the
promote-vs-copy decision per cell inline (`:1919-1949` — the promotion arm
at `:1935` is one of the three `GC_STATS_MINOR_INC_PROMOTED` sites), and it
already handles every termination condition:

| condition | handled at |
|---|---|
| already-forwarded cell → link and stop | `:1869-1881` |
| not in from-space → stop | `:1883` |
| non-`Cons` tail → delegate to `evacuate` and stop | `:1887-1896` |
| `Nil` / constant terminator | `:1854` |
| per-cell promote-vs-copy decision | `:1919-1949` |
| `pin`/`builder` respected on `Cons` | `:1919` |
| two-pass head evacuation | `evacuateListHeads` `:1982` |

Today the promoting branch emits one `oldgen.allocate(sizeof(Cons))` per
cell. **The proposed change is the output format of that one branch** —
plus, if §2.1's variant is taken, a second entry point.

### 2.1 A structural gift: the promoting portion is always a clean SUFFIX

Ages are **non-decreasing along a spine**. The invariant says every child is
at least as old as its parent, and a cons cell's child *is* its tail, so
walking head→tail the age never decreases. The promotion predicate
(`age >= promotion_age`) is therefore **monotone along the walk**: once it
becomes true it stays true.

So any spine partitions, with no interleaving, into

```
[ young prefix → to-space ] [ old suffix → promoted ] [ terminator ]
```

and the chunk candidate is exactly that suffix. The walker never has to
handle a promoted cell followed by a non-promoted one, and run detection is
a single predicate flip rather than a segmentation problem. (`pin`/`builder`
can still break a run independently of age — bail, do not assume.)

**And the entire chunk representation is already shipped and GC-aware**
(chunked-list L1.2/L1.4 as-builts): `Tag_ListBacking` + `Tag_ConsChunk`
layouts, nursery/oldgen/permanent GC arms, mixed-spine walkers for
eq/compare/toString/JSON/ports/Debug, `ChunkCursor`, chunk-aware
`list_head`/`list_tail` lowering, `eco_list_pos_view`, and the
`EcoListCursor` backend pass that already walks mixed spines
allocation-free (3,191 of 4,626 whiles). **Nothing downstream needs to
learn a new representation** — mixed spines are already the norm.

## 3. Why the chunked-list track's failure does not predict this one's

The chunk work was measured at **−47.5% Cons, −24% list bytes, zero wall**.
LH1 explains why: it cheapened *construction-time* lists, and construction-
time lists are overwhelmingly nursery garbage, which a copying collector
does not charge for. Chunk-form objects reaching old gen: 0.05% of
promotion.

This proposal inverts the targeting. It touches **only** objects that have
already proven they survive, and it does so at the moment the collector is
already paying to copy them. The population is, by construction, the one
LH1 identified as 36.7% of retention.

That is a genuinely different argument — but note what it means for the
**win mechanism**: this saves *mark cost, scan cost, and old-gen allocation
calls*, not allocation volume. It must be judged on major-GC time and
promotion time, never on object counts. Hence the gates below.

## 3.1 Variant: chunk during the nursery Cheney copy instead (or as well)

Raised alongside the main proposal. The numbers are more favourable than
they first look, and LH1 already has them:

| | subst | solver |
|---|---|---|
| `Cons` **copied in nursery** | **324,505,143** | 331,854,110 |
| `Cons` **promoted** | 131,038,610 | 133,991,816 |

To-space cons copies outnumber promotions **2.5×**. And they are partly the
*same cells copied repeatedly*: `promotion_age` is 3 nursery cycles
(`Heap.hpp:135`), so a cell that survives to promotion is Cheney-copied up
to three times before it gets there. Chunking at **first survival** would
collapse copies 2 and 3 as well as the promotion itself.

**Why it is still the second choice, not the first:**

- A cell copied to to-space has survived *one* minor GC; a cell being
  promoted has survived `promotion_age` of them. Chunking on first survival
  spends work on a population that still contains objects about to die,
  which is precisely the mistake the construction-time chunk work made
  (§3) — one generation later, but the same shape of mistake.
- Age accounting: a chunk is one object with one age, where the absorbed
  cells had individual ages. Within a run those ages are equal or
  near-equal (§2.1 monotonicity), but "near" needs a rule, and getting it
  wrong either delays promotion of old cells or promotes young ones.
- It puts the more complex path (§4 lazy views) on the hotter, more
  frequently executed of the two paths.

**Recommended sequencing:** gate and build the promotion-time version
first — it is conservative, it targets the population LH1 proved is
retained, and it is on the colder path. Then, if P1 shows long runs, re-run
LH1 and reconsider this variant with the *residual* to-space copy volume,
not the pre-change 324M. Do not build both at once; they overlap and
neither could then claim its own delta (the double-count discipline from
`mono-comparable-key-optimization.md` §11).

## 4. The design problem — forwarding for absorbed cells

Evacuation leaves a forwarding pointer so other references to a moved cell
still resolve. If cell C is absorbed into a backing, any *other* reference
to C must resolve to something meaning "the list starting at C" — which in
this representation is a `ConsChunk` view at C's index.

Materializing a view per absorbed cell would defeat the purpose (backing +
N views ≥ N cons cells). Three options, best first:

- **(a) Lazy views via the spare `Forward` bits.** `Forward`'s header has
  **17 unused bits** (`Heap.hpp:633`) beside `forward_ptr`. An absorbed cell
  can be forwarded to *the backing* with its index in those bits (up to
  131,071 — far beyond any run length), marked by a distinguishing state.
  When something later evacuates a reference to that cell, the collector
  materializes one view on demand. **Interior cells reached only through
  the spine walk never get a view at all**, so the cost is charged exactly
  in proportion to real sharing. This is the same "one view per escape, not
  per element" discipline `eco_list_pos_view` already implements for
  compiled walks (chunked-list slice 4).
- **(b) Eager view per cell** — correct, trivially, and pointless.
- **(c) Absorb only cells with no other in-cycle referent** — undecidable at
  evacuation time without a second pass. Recorded so it is not re-proposed.

Option (a) is the design; it is also the part most likely to contain the
bug, so it wants its own `ECO_HEAP_VALIDATE` assertions and a sharing-heavy
unit test (two live references into the middle of one promoted spine).

## 5. Gating measurements — do these before writing any of §4

### P1 — promoted-spine run-length histogram (cheap, decisive)

Instrument `evacuateListSpine` to histogram the length of each **contiguous
promotable run** (buckets 1,2,3,4-7,8-15,16-31,32+). This is the number the
whole idea turns on:

- If promoted cons cells mostly sit in runs of **1-3**, chunking cannot
  help — the chunked-list design's own ≥4 threshold applies, and slice 3
  already measured a population (recursive encoders, 1-3 elements per call)
  where `finish` correctly fell back to cells for exactly this reason.
- If runs average, say, 16+, then 131M promoted cells collapse toward ~8M
  chunk objects, and the mark set for lists shrinks by an order of
  magnitude.

Reuse the LH1 harness — same file, same macro discipline, same self-check
(histogram total ≡ promoted `Cons` count from LH1).

### LH3 — mark-cost composition

`plans/live-heap-composition-census.md` LH3. This proposal's win is mark
work; LH3 measures whether `Cons` dominates it. Run F is suggestive — K6's
−5.07% wall came with majors 13→10 and GC time covering 91% of the delta —
but "list spines dominate mark cost" is currently an inference, not a
measurement.

### D-PC — the gate

Build only if P1 shows a promoted-run distribution whose mean is ≥8 **and**
LH3 attributes ≥20% of mark cost to `Cons`. Record the histograms either
way; a short-run distribution closes this cleanly and cheaply.

## 6. Risks

- **Uniform element kind.** `ListBacking` scans its slots by a *single*
  2-bit element kind in `Header.unboxed` bits 1:0 (`Heap.hpp:503-507`),
  whereas `Cons` carries the kind per cell. A run must be kind-uniform to
  become one backing. Monomorphic Elm lists should satisfy this by typing,
  but the walk must **verify and split the run on mismatch**, not assume —
  a wrong bitmap here is a GC miscompile, and REP_HEAP_002 governs.
- **Pause time.** The walk already happens; the extra work is run-length
  measurement plus a bulk fill. Sizing the backing exactly (the run length
  is known before the fill, as the kernels already do count-first) avoids
  slack. Net promotion cost should *fall* — one `oldgen.allocate` per run
  instead of per cell — but it must be measured, not assumed.
- **Old-gen fragmentation.** Backings are variable-size; old gen already
  handles variable-size classes (`Array`/`Record`/`Custom`), but the size
  distribution changes and `oldgen-segregated-fits-bbop` assumptions should
  be re-checked.
- **`needs_head_pass` interaction.** `evacuateListHeads` (`:1982`) walks the
  copied spine to evacuate heads; for a chunk it must fill backing slots
  instead of cons head fields.
- **Compaction.** Old-gen compaction has no production caller today, but if
  it is ever wired up, absorbed-cell forwarding needs the same fixup
  treatment the scratch stack already flagged.

## 7. What this does not do

- No effect on user programs' *allocation* behaviour, and no compile-time
  component — this is invisible to the compiler.
- Does not subsume `plans/accumulator-templates.md`: that deletes the
  allocation and the traversal at construction; this reshapes what survives.
  They are complementary, and if this ships first it *reduces* the
  accumulator plan's remaining upside — sequence deliberately, and re-run
  LH1 between them (the double-count discipline from
  `mono-comparable-key-optimization.md`).
