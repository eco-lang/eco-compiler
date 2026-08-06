# Promotion-time list chunking — build chunks where the survivors are

**Status: BUILT, TESTED, MEASURED, CLOSED NO-GO, AND FULLY REVERTED
2026-08-06 (`benchmarks/tier2-opt.md` Run J). Implemented per user order
(invariant HEAP_041, removed again with the revert); all gates were green
(unit+E2E 1627/1627 incl. 8 new PromoChunk tests; all green under
ECO_HEAP_VALIDATE; `.mlir` byte-identity across all flavors). The shipped
P1 instrument then answered §5's own gate: mean promotable run = 1.69 (73%
singletons; ≥8 was required), only 11.2% of promoted Cons sit in chunkable
runs, and mode 2 cost +5.7% wall (majors 9→11, +2.14M mutator view
allocations from chunk-tail materialization) against −3.1% promotion /
−1.2% RSS; the peek alone (mode 1) costs +1.8%. The implementation was then
REVERTED in full (user decision — no point carrying a default-off
mechanism). The revert also removed the LATENT validate-walker fix this
work uncovered; it was RE-LANDED standalone 2026-08-06 (the old-gen check
walk in `NurserySpace.cpp` now skips only fully-zero header words and
resyncs on a zero `getObjectSize` stride — `Tag_Int == 0`, so a `tag == 0`
skip stepped into promoted boxed-Int VALUE words, and value 25 decodes as
`Tag_Free` size 0 = infinite loop), pinned by a `NurserySpaceTest`
promotion roundtrip over value-25 boxed Ints.
The §4(a) lazy-view design itself validated cleanly (704 materializations),
so this file is the rebuild recipe if a long-list workload ever warrants
it. §3.1's first-survival variant is pre-empted by the same histogram: the
population is short runs, not late chunking.
Lowering-time analysis (§§0–7 original, ⟦corrected⟧ where wrong) and the
implementation plan (§§8–18) kept for the record; the TIER PATTERN from
`eco-opt-tier-roadmap` extends to a fifth instance — static plausibility
collapsed at the measured-population gate, this time measured by the
feature's own peek.**

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
*same cells copied repeatedly*: ⟦corrected⟧ `promotion_age` defaults to
**2** (`AllocatorCommon.hpp:123` `PROMOTION_AGE`, config field
`HeapConfig::promotion_age`, not `Heap.hpp:135`), so a cell that survives
to promotion is Cheney-copied twice before it gets there. Chunking at
**first survival** would collapse copy 2 as well as the promotion itself.

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

---
---

# IMPLEMENTATION PLAN (lowered 2026-08-05)

## 8. Load-bearing facts established during lowering

Every design decision below traces to one of these; re-verify them if the
tree has moved.

1. **`ConsChunk.len` is load-bearing and must be EXACT.**
   `ListOps::length` (`ListOps.hpp:89`) and `listLogicalLen`
   (`HeapHelpers.hpp:944`) do `count += view->len; STOP` — they never walk
   `next` past a view. A GC-built view with an understated `len` silently
   truncates every consumer. Consequence: a run whose continuation length
   cannot be established exactly **must not be chunked** (fallback:
   per-cell promotion, status quo). See §10.4 for how continuation length
   is obtained O(1) in the common cases.
2. **HEAP_039 gates all chunk production on `eco_g_list_chunks`**
   (`RuntimeExports.cpp:260`, set once by the compiled binary's `@main`
   entry iff it was compiled `list.chunks`-aware). A binary compiled with
   chunks off has non-chunk-aware head/tail lowerings; the GC must never
   hand it a view. The collector therefore checks
   `eco_g_list_chunks && config_->promo_chunk_mode == 2` before emitting.
3. **HEAP_038 (backing < large_object_threshold) is a MUTATOR-producer
   invariant whose rationale is old→young edges from pinned old-gen
   backings that minor GC never rescans.** A GC-built old-gen backing is
   pushed onto `promoted_objects` in the same cycle, so its element slots
   are rescanned and finalized before the cycle ends — the rationale does
   not apply. We nonetheless cap links at `listBackingMaxElems()` (= 1021
   elems under the 8 KiB LOT) and chain, exactly like `listChunkChain`
   (`HeapHelpers.hpp:973`), to keep the old-gen size-class distribution
   familiar and the absorbed-cell delta small. HEAP_038's text gains a
   carve-out sentence (§15).
4. **Forwards are cycle-local to the minor GC.** The mutator-side
   forward-followers (`Allocator::resolve` `Allocator.cpp:838`,
   `eco_follow_forward` `RuntimeExports.cpp:4580`) exist for OLD-GEN
   compaction tombstones only; nursery from-space forwards are never
   mutator-visible (all references are rewritten within the cycle, and
   from-space is poisoned/zeroed before reuse). So the absorbed-forward
   encoding (§9.2) needs decoding ONLY in `NurserySpace`'s three
   forward-reading sites, all in this cycle: `evacuate` (`:1183`),
   `evacuateJitPtr` (`:1384`), `evacuateListSpine`'s forward arm
   (`:1868`). A validator-build assert in `Allocator::resolve` tripwires
   the impossible case.
5. **Normal forwards write `unused = 0` at all three creation sites**, so
   a marker bit in `unused` unambiguously distinguishes absorbed forwards.
6. **The existing walker only sees cells 2..N of a spine.** The first
   `Cons` of any list is evacuated by generic `evacuate()`
   (root/child), and `scanObject`'s `Tag_Cons` arm then walks its TAIL
   (`:1650`). So a chunk covers at most cells 2..N; the head cell stays a
   `Cons` whose tail points at the first view. Accepted (one cell of
   overhead per promoted spine).
7. **`consChunkView` conventions** (`HeapHelpers.hpp:695`): view
   `header.size = 0`, `header.unboxed = kind`, backing `header.size =
   capacity`, `hd = 0`, boxed-kind backing slots zeroed at birth.
   `eco_list_pos_view` (`RuntimeExports.cpp:4192`) is the mutator-side
   precedent for "materialize view at (canonical view, index delta)":
   `{backing, offset+delta, len-delta, next}` — the GC materializer (§11)
   uses the identical formula.
8. **Old-gen allocation during minor GC is already the promotion path**
   (`oldgen.allocate`, any size: ≥ `alloc_buffer_size` gets a dedicated
   pinned block, [8 KiB, 512 KiB) bag pages, below that size classes).
   Headers must be written immediately after each `allocate` so lazy-sweep
   walks (`getObjectSize`-strided) see a well-formed object; element slots
   may stay stale ONLY while the object is unreachable — we zero
   boxed-kind slots at birth anyway (fact 7 discipline, defensive).
9. **Old-gen mark/fixup arms for `Tag_ConsChunk`/`Tag_ListBacking` already
   exist** (`OldGenSpace.cpp:1645/1651` mark, `:3921/3927` compaction
   fixup; `PermanentSpace.cpp:130/136`), as do the `scanObject` arms
   (`NurserySpace.cpp:1694/1700`) and the post-GC validate walkers. No new
   consumer work anywhere — chunks in old gen are already first-class.
10. **Ages are monotone along a spine** (§2.1) — but `pin`/`builder` can
    break runs, and root-order evacuation can forward cells mid-spine, so
    the walker treats "promotable run" operationally (peek until the
    predicate fails), never assuming the suffix property.

## 9. Data structures and encodings

### 9.1 New `HeapConfig` fields (`AllocatorCommon.hpp`)

```cpp
// ---- Nursery (promotion-time list chunking) ----
// 0 = off (pre-change walker, zero overhead)
// 1 = measure (run peek + P1 histogram, per-cell promotion — no emission)
// 2 = on (peek + histogram + chunk emission)          [default]
u32 promo_chunk_mode = PROMO_CHUNK_MODE;               // constexpr = 2
// Minimum kind-uniform promotable run length that becomes a chunk;
// shorter runs promote per-cell. The chunked-list ≥4 threshold: at k=4
// the chunk form (48 + 8k bytes) first beats k cells (24k bytes).
u32 promo_chunk_min_run = PROMO_CHUNK_MIN_RUN;         // constexpr = 4
```

`validate()`: `promo_chunk_mode <= 2`; `promo_chunk_min_run >= 2` (a
1-cell "chunk" is strictly worse than a cell and offset math assumes ≥2).

JSON keys `"promo_chunk_mode"` / `"promo_chunk_min_run"` in
`HeapConfigJson.cpp` (add to the known-keys table at `:174` and the parse
block at `:246`). Env override for same-binary A/B (read where the JSON
overrides are applied, `Allocator.cpp:174` region): `ECO_PROMO_CHUNK=0|1|2`
overrides `promo_chunk_mode` after the JSON pass.

### 9.2 Absorbed-forward encoding (`Heap.hpp` `Forward`)

`Forward.header` today: `tag:5, color:2, forward_ptr:40, unused:17`. The
17 spare bits become `absorbed:1 + delta:16` **by convention** (no struct
change — accessors keep the bitfield layout identical):

```cpp
// Forward.unused bit 16 = "absorbed into a promoted chunk run".
// forward_ptr then points at the run's CANONICAL Tag_ConsChunk view and
// delta (unused bits 0..15) is this cell's index within that view's run.
// delta == 0 cells use a NORMAL forward to the view itself, so absorbed
// forwards always have delta >= 1. delta < listBackingMaxElems() = 1021,
// far under the 16-bit cap. Normal forwards keep unused == 0 (all
// existing creation sites already write 0), so the bit is unambiguous.
constexpr u64 FWD_ABSORBED_BIT  = 1ull << 16;
constexpr u64 FWD_DELTA_MASK    = 0xFFFFull;
```

Helpers in `Heap.hpp` next to `encodeForwardPtr`:

```cpp
inline void encodeAbsorbedForward(Forward* f, void* canonicalView, u32 delta);
inline bool forwardIsAbsorbed(const Forward* f);   // unused & FWD_ABSORBED_BIT
inline u32  forwardAbsorbedDelta(const Forward* f);
```

### 9.3 Chunk emission format (per promotable run of k cells)

`nlinks = ceil(k / listBackingMaxElems())`; link runs `r_i` follow
`listChunkChain`'s split (head links full, tail link takes the
remainder). Per link, in OLD GEN: one `Tag_ListBacking` (16 + 8·r_i
bytes; `size=r_i`, `unboxed=kind`, `hd=0`, boxed slots zeroed at birth)
and one `Tag_ConsChunk` (32 bytes; `size=0`, `unboxed=kind`, `offset=0`,
`len` telescoped: `len_i = r_i + len_{i+1}`, tail link's
`len = r_tail + lenOfNext`). All headers: `color=White`, `age=0`,
`pin=0`, `builder=0`, `refcount=0` — same as any promoted object.

Byte math: k cells = 24k bytes today; chunked = 48·nlinks + 8k. Break-even
k=3, min_run=4 → strict win from the first emitted chunk.

## 10. The walker change (`NurserySpace::evacuateListSpine`)

All changes live between the "Not a Cons?" check and the existing
promote-vs-copy arm (`:1899-1950`). The existing per-cell code path is
preserved VERBATIM as the fallback — mode 0 must be byte-equivalent in
behaviour to today.

### 10.0 Entry condition

At the top of the per-cell loop body, after the forward / from-space /
non-Cons checks, where today the promote-vs-copy decision happens:

```cpp
bool promotable = hdr->age >= config_->promotion_age
               && !hdr->pin && !hdr->builder;          // existing predicate
if (promotable && config_->promo_chunk_mode != 0 && eco_g_list_chunks) {
    // Enter run handling (10.1); it consumes cells up to the run
    // terminator and either RETURNS from the walk (chunk emitted, spine
    // finished) or falls back to per-cell for this run (10.6).
}
```

Mode 0 never evaluates anything new: the guard reads one config field.
`eco_g_list_chunks` needs a local `extern "C" bool eco_g_list_chunks;`
declaration in NurserySpace.cpp (declared in `HeapHelpers.hpp:69`, which
NurserySpace.cpp does not include).

### 10.1 Peek pass (no mutation)

From the current cell, walk `tail` collecting:

- `k` — number of consecutive cells satisfying ALL OF: unforwarded
  (`tag != Tag_Forward`), `isInFromSpace`, `tag == Tag_Cons`,
  promotable-predicate true, head kind == first cell's head kind
  (`tupleFieldKind(hdr->unboxed, 0)`).
- `terminator` — the `HPointer` tail of the last run cell (whatever
  first fails the conjunction, including a kind-change cell, which stays
  in from-space and re-enters the outer loop afterwards).

No forwarding pointers are written, no headers touched — the run is
re-walkable. Cost: one extra header-read pass over promotable cells.

Record the P1 histogram here (§12): bucket `k` regardless of mode.

### 10.2 Decide

- mode 1 (measure) → fallback 10.6.
- `k < promo_chunk_min_run` → fallback 10.6.
- else continue.

### 10.3 Resolve the terminator eagerly

```cpp
HPointer nextHP = terminator;
if (nextHP.ptr_ind == 0) evacuate(nextHP, oldgen, promoted_objects);
```

`evacuate` handles every case uniformly: constant — untouched; already
old-gen — early return; normal forward — followed; absorbed forward —
materialized (§11); unforwarded from-space object — evacuated (by
monotonicity it must qualify for promotion; a pinned/builder terminator
goes to to-space, which mirrors today's behaviour for spine cells that
follow promoted cells — no new edge class). After this call `nextHP` is
FINAL: views built from it never need a phase-3 scan.

### 10.4 Continuation length (`lenOfNext`) — exact or bail

On the FINAL `nextHP`:

| target | lenOfNext | cost |
|---|---|---|
| constant (Nil) | 0 | O(1) |
| `Tag_ConsChunk` | its `len` | O(1) |
| `Tag_Cons` | bounded walk, ≤ `PROMO_CHUNK_LEN_PEEK` = 64 steps | O(64) cap |
| anything else | UNKNOWN → fallback 10.6 (counter `runs_abandoned_len`) | — |

Bounded-walk step rules (node = resolved pointer):
`Nil/constant` → done exact; `Tag_ConsChunk` → `+= len`, done exact;
`Tag_Cons` → `+= 1`, follow tail; **normal forward** → follow, no count
(mid-cycle old-gen cells can still hold from-space pointers to unscanned
promoted content — following the forward lands on the final copy);
**absorbed forward** → `+= canon->len − delta`, done exact (no
materialization — absorbed forwards double as O(1) length oracles);
budget exhausted or non-list tag → UNKNOWN → fallback. After this
feature has been on for a while, continuations are almost always
Nil/chunk-headed, so the walk is O(1) in steady state; the 64-step budget
covers residual short per-cell-promoted prefixes from sub-threshold runs.

### 10.5 Emit

```cpp
// (a) plan the links
u32 maxE = listBackingMaxElems();                  // 1021 today
u32 nlinks = (k + maxE - 1) / maxE;
// r_i: head links full (maxE), tail link k - (nlinks-1)*maxE
//      == listChunkChain's split (remainder at the tail).

// (b) allocate tail-first so every view's next is final at birth
std::vector<std::pair<ListBacking*, ConsChunk*>> links(nlinks);
HPointer chainNext = nextHP;  u32 lenAcc = lenOfNext;
for (int i = nlinks - 1; i >= 0; --i) {
    r = runOf(i);
    ListBacking* b = oldgen.allocate(sizeof(ListBacking) + r*8);
    /* write full header + hd immediately; memset elems if kind == 0 */
    ConsChunk* v = oldgen.allocate(sizeof(ConsChunk));
    /* write full header; backing=wrap(b); offset=0; lenAcc += r;
       len=lenAcc; next=chainNext */
    chainNext = Allocator::toPointerRaw(v);
    links[i] = {b, v};
    // stats: 2× GC_STATS_MINOR_INC_PROMOTED (backing bytes incl. slack,
    // view 32B); push b onto promoted_objects (phase 3 evacuates heads).
    // v is NOT pushed: backing and next are final old-gen/constant.
}

// (c) fill + forward, walking the run cells again head-first
for each link i, for j in [0, r_i):
    Cons* cell = current run cell;
    links[i].first->elems[j] = cell->head;         // verbatim 8 bytes
    HPointer t = cell->tail;                       // save before overwrite
    Forward* f = (Forward*)cell;
    if (j == 0) normal forward -> links[i].second; // delta 0 = the view
    else        absorbed forward {view_i, delta=j};
    advance to t;

// (d) link into the spine
HPointer headView = Allocator::toPointerRaw(links[0].second);
if (prev_copied) ((Cons*)prev_copied)->tail = headView;
else             ptr = headView;                   // walk started here
return first_copied;                               // walk is complete
```

Notes:
- Between (b) allocations, earlier links hold zeroed/garbage elems but are
  UNREACHABLE (nothing references them until (c)/(d)), so concurrent
  lazy-sweep walks see only well-formed headers (fact 8) and mark cannot
  reach them.
- The `needs_head_pass` machinery is untouched: chunk heads are evacuated
  by the phase-3 scan of the pushed backings (`scanObject`
  `Tag_ListBacking` arm), not by `evacuateListHeads`, whose walk stops at
  the first non-Cons node (the view) exactly as it stops at old-gen
  boundaries today.
- Stats: also count `absorbed_cells += k`, `runs_emitted += 1`,
  `links_emitted += nlinks`.

### 10.6 Fallback (no emission for this run)

Set a countdown `skip = k` and let the EXISTING per-cell loop body run
unchanged for the next `skip` cells (each decrements it; while `skip > 0`
the 10.0 guard is bypassed so we never re-peek inside a rejected run).
Cells promote individually exactly as today.

### 10.7 What is deliberately NOT changed

- `evacuate()` / `evacuateJitPtr()` promotion arms: single cells reached
  as roots/children stay `Cons` (fact 6).
- The to-space copy arm and all of its ordering.
- `scanObject` arms, `evacuateListHeads`, phase-3 alternation.
- The §3.1 first-survival variant: out of scope (measured later against
  residual copy volume, per the original plan).

## 11. Absorbed-forward resolution (the §4(a) lazy views)

New private helper used by ALL THREE forward-reading sites (10.3's
`evacuate` call inherits it via the `evacuate` site):

```cpp
// Follows a Tag_Forward header to its final target, materializing a
// ConsChunk view on demand for absorbed cells (delta >= 1) and REWRITING
// the forward to a normal one so each absorbed cell materializes at most
// once (sharing-proportional cost, §4(a)).
void* NurserySpace::forwardTarget(Forward* fwd, OldGenSpace& oldgen) {
    char* heap_base = allocator_->getHeapBase();
    void* tgt = decodeForwardPtr(fwd->header.forward_ptr, heap_base);
    if (!forwardIsAbsorbed(fwd)) return tgt;
    ConsChunk* canon = static_cast<ConsChunk*>(tgt);
    u32 delta = forwardAbsorbedDelta(fwd);
    /* ECO_HEAP_VALIDATE: canon tag==Tag_ConsChunk, in old gen,
       1 <= delta < min(canon->len, backing cap - canon->offset) */
    ConsChunk* v = oldgen.allocate(sizeof(ConsChunk));
    /* header: tag=Tag_ConsChunk size=0 unboxed=canon kind, White/0/0/0;
       backing=canon->backing; offset=canon->offset+delta;
       len=canon->len-delta; next=canon->next  (final by §10.3) */
    /* stats: GC_STATS_MINOR_INC_PROMOTED(view) + views_materialized++ */
    fwd->header.forward_ptr = encodeForwardPtr(v, heap_base);
    fwd->header.unused = 0;                     // now a normal forward
    return v;
}
```

Call sites (replace the two-line decode at each):
- `evacuate` `:1186` — `tgt = forwardTarget(fwd, oldgen)`.
- `evacuateJitPtr` `:1386` — same.
- `evacuateListSpine` forward arm `:1870` — same (a spine walk hitting a
  cell absorbed by an EARLIER walk this cycle — the shared-suffix case —
  links `prev->tail` to the materialized view and stops).

Materialized views are born final (backing old-gen, next final): no
`promoted_objects` push. The `ECO_HEAP_VALIDATE` forward-chain-depth
check in `evacuate` continues to hold: after rewrite the forward points
at a real `Tag_ConsChunk`, depth 1.

Mutator-side tripwire (fact 4): in `Allocator::resolve`'s follow loop,
under `ECO_HEAP_VALIDATE` only:
`assert(!(fwd->header.unused & FWD_ABSORBED_BIT) && "absorbed forward escaped its minor GC cycle")`.

## 12. GCStats: P1 histogram + feature counters

Fields (all `uint64_t`, in `GCStats`, + `combine()` + `reset()` + print):

```cpp
// ===== Promotion-time list chunking (P1 + feature telemetry) =====
static constexpr int PROMO_RUN_BUCKETS = 12;
// buckets: 1,2,3,4-7,8-15,16-31,32-63,64-127,128-255,256-511,512-1023,1024+
uint64_t promo_run_hist[PROMO_RUN_BUCKETS];
uint64_t promo_runs_seen;          // == sum of promo_run_hist
uint64_t promo_run_cells_seen;     // Σ k over all runs (P1 mass)
uint64_t promo_chunk_runs_emitted;
uint64_t promo_chunk_links_emitted;   // == backings == views (canonical)
uint64_t promo_chunk_cells_absorbed;  // Σ k over emitted runs
uint64_t promo_chunk_views_materialized;   // §4(a) sharing cost, exact
uint64_t promo_chunk_runs_below_min;       // k < min_run
uint64_t promo_chunk_runs_abandoned_len;   // continuation length UNKNOWN
```

Print block (next to the LH1 "Retention by Object Kind" block, gated on
`promo_runs_seen > 0`): the histogram with mean run length, plus the
counters. **Self-checks the entry records in the benchmark file:**
(a) `promo_runs_seen == Σ hist`;
(b) `promoted Cons count (LH1) + cells_absorbed == cells that would have
promoted as Cons` — i.e. across an A/B pair at equal workload,
`Cons_promoted(A) ≈ Cons_promoted(B) + cells_absorbed(B) + first-cells`;
(c) `promoted ConsChunk count == links_emitted + views_materialized`,
`promoted ListBacking count == links_emitted`.

Recording from the collector uses direct field access on `stats` (the
NurserySpace member), wrapped in `#if ENABLE_GC_STATS` like the
surrounding sites — no new macro family needed for GC-internal counters.

## 13. Config plumbing summary

| where | what |
|---|---|
| `AllocatorCommon.hpp` | `PROMO_CHUNK_MODE=2`, `PROMO_CHUNK_MIN_RUN=4` constexprs; 2 `HeapConfig` fields; `validate()` rules |
| `HeapConfigJson.cpp` | keys `promo_chunk_mode`, `promo_chunk_min_run` (known-keys table `:174`, parse `:246`, header comment `:24` block) |
| `Allocator.cpp:174` region | `ECO_PROMO_CHUNK` env override (0/1/2) applied after JSON |
| `main.cpp` | nothing (JIT driver keeps defaults; AOT binaries configure via env/JSON) |

Default **ON (mode 2)**. Rollback is `ECO_PROMO_CHUNK=0` at runtime — no
rebuild, no recompile of Elm code (the feature is invisible to the
compiler; CGEN untouched).

## 14. Validation-build assertions (ECO_HEAP_VALIDATE)

1. Emit-time: every absorbed cell was `Tag_Cons`, promotable, kind ==
   run kind (assert inside the 10.5 fill loop).
2. Emit-time: `view->len == r_i + next view len` telescoping check per
   link; tail link `len == r_tail + lenOfNext`.
3. `forwardTarget`: canon is `Tag_ConsChunk` in old gen; `1 <= delta <
   run(canon)`.
4. `Allocator::resolve`: absorbed forward never seen (fact 4 tripwire).
5. The existing post-GC to-space/old-gen walkers already trace
   `ConsChunk`/`ListBacking`; the existing phase-3 too-young-child abort
   already covers backing scans (children of absorbed cells must
   promote).
6. The existing `verifyToSpaceBlockEndOfObjects` and from-space pre-walk
   are unaffected (absorbed forwards size as `sizeof(Forward)` like any
   forward).

## 15. Invariant ledger updates (`design_docs/invariants.csv`)

- **HEAP_037**: append "; the minor-GC promotion path is an additional
  chunk producer (promotion-time chunking, HEAP_041)".
- **HEAP_038**: append carve-out: "GC-built promotion-time backings
  (HEAP_041) are exempt from the strictly-below-LOT birth rule's
  *rationale* (they are scanned via promoted_objects in the same cycle,
  so no unrescanned old→young edge can survive) but follow the same
  `listBackingMaxElems()` link cap regardless."
- **HEAP_039**: append "; promotion-time chunk emission is gated on the
  same `eco_g_list_chunks` and additionally on
  `HeapConfig::promo_chunk_mode == 2`".
- **NEW HEAP_041** (ChunkedLists): promotion-time list chunking — the
  minor-GC list-spine walker may emit each kind-uniform promotable run of
  ≥ `promo_chunk_min_run` cells as old-gen `ListBacking`+`ConsChunk`
  links (≤ `listBackingMaxElems()` elems each, telescoped `len`, `len`
  EXACT including continuation or the run is not chunked); absorbed cells
  forward to the canonical view via `Forward.unused` bit 16 + 16-bit
  delta, materialized to per-cell views on demand and rewritten to normal
  forwards (once per cell max); absorbed forwards are cycle-local to the
  emitting minor GC; gated on `eco_g_list_chunks && promo_chunk_mode==2`.

## 16. Tests

### 16.1 Unit (`test/allocator/PromoChunkTest.{cpp,hpp}`, registered like ChunkedListTest)

Harness idioms from `ChunkedListTest.cpp`: `initAllocator(cfg)` with a
custom `HeapConfig` (small nursery optional — promotion needs
`promotion_age`+1 = 3 `minorGC()` calls with the list rooted via
`RootSet::pushStackRootRange`), `eco_g_list_chunks = true` saved/restored
around each test, content checks via `alloc::ListCursor` /
`ListOps::length`.

1. **long-spine roundtrip**: 5,000-int cons list → 3× minorGC → content
   identical, `length` exact; walk the promoted spine: node 0 is `Cons`
   (fact 6), node 1 is `ConsChunk` with `len == 4999`, links chained at
   1021; LH1 counters show the expected backing/view promotions.
2. **sharing / lazy views**: root A = full list; root B = `Tuple2`
   pointing at cell #100's list value (walk tails before GC); 3×
   minorGC → both contents correct; `views_materialized == 1`; a THIRD
   root at the same cell materializes no second view (dedupe rewrite).
3. **mixed ages**: build 200-cell suffix, 2× minorGC (age=2), prepend 50
   young cells, 1× minorGC → suffix chunked in old gen, prefix copied to
   to-space, content/order exact across the seam.
4. **kind split**: alternate runs of unboxed-Int heads and boxed heads
   (spans > min_run and < min_run) → content exact; sub-min runs promote
   as cells (`runs_below_min` > 0), uniform runs ≥4 chunk.
5. **continuation telescoping**: promote a suffix (chunked), then prepend
   ≥ min_run cells, age them, GC → second chunk's `next` is the FIRST
   chunk's view and its `len` telescopes exactly (`length` == total).
   Repeat with a sub-min first promotion (cells) to exercise the bounded
   Cons-walk length peek, and with a > 64-cell cells-only old suffix to
   exercise `runs_abandoned_len` (build with min_run raised so the first
   promotion stays cells).
6. **rapidcheck property**: random int lists (0..3000 elems), random
   prepend/GC interleavings and a random `drop` root — model equality
   against `std::vector`, both mode 2 and mode 0, plus mode equivalence
   of contents.
7. **mode gates**: mode 0 emits nothing (counters zero); mode 1 records
   the histogram but promotes per-cell (no ConsChunk promotions);
   `eco_g_list_chunks == false` suppresses emission even in mode 2.

### 16.2 System gates (in order, per repo discipline)

1. `cmake --build build --target test` unit suite (includes 16.1; run
   once, tee to /tmp, grep — including `rc::check` "Falsifiable" lines,
   which do NOT fail the suite per the UTF-8 plan gotcha).
2. `cmake --build build --target full` — full E2E 1619 (compiled-code
   projections against GC-built chunks; the compiler front-end tests
   don't exercise the runtime and can be skipped unless touched).
3. ECO_HEAP_VALIDATE build of the unit suite (separate build dir or
   config flip) for the §14 asserts under the new tests.
4. Bootstrap gate only if warranted by E2E/benchmark anomalies — the
   benchmark itself (Stage 7a cold, both engine legs) IS a self-compile
   of the full compiler under the feature and serves as the primary
   at-scale gate here (runtime-only change; `.mlir` byte-identity is the
   workload-constancy check).

## 17. Benchmark protocol (`benchmarks/tier2-opt.md` Run J)

Runtime-only change ⇒ the SAME binary serves every leg; legs differ only
in `ECO_PROMO_CHUNK`. Per the file's methodology: Phase-1 rebuild of
`eco-compiler-borrowopt` (the tree changed: runtime sources), then per
leg cold `eco-stuff`, warmup + measured:

- **Leg 0 (baseline)**: `ECO_PROMO_CHUNK=0` — pre-change walker.
- **Leg 1 (P1 measure)**: `ECO_PROMO_CHUNK=1` — records the P1 run-length
  histogram against per-cell promotion; also prices the peek overhead.
- **Leg 2 (chunking)**: `ECO_PROMO_CHUNK=2` (= default).

`cmp` all legs' `out.mlir` (byte-identity — GC cannot move compiler
output). Record per the file's fixed format + the §12 self-checks +
the P1 histogram table (this run RECORDS the original §5 P1/D-PC gate
numbers rather than being gated by them — user decision 2026-08-05).
Interpretation guide: wall/majors/GC-time/promoted-bytes are the
decision numbers; `Objects promoted` is EXPECTED to drop mechanically
(runs collapse to 2·links) — do not read it as a win by itself.
Optionally add a solver-engine leg pair if the subst deltas are
promising (Run F precedent: retention wins show larger on solver).

## 18. Risks and rollback

- **Silent truncation** is the catastrophic failure mode (understated
  `len`). Defenses: exact-or-bail rule (10.4), telescoping asserts
  (§14.2), `length`-checking unit tests, E2E.
- **Stale heads in backings**: backing must be pushed to
  `promoted_objects` in the same emit (10.5b); defense: sharing tests +
  post-GC old-gen validate walker (already scans backing elems).
- **Absorbed forward mis-decode**: marker bit collides with nothing
  (fact 5); validator tripwires §14.3/14.4.
- **Pause-time regression from the peek**: leg 1 vs leg 0 isolates it.
- **Old-gen size-class shift** (many 8 KiB-ish backings): visible in the
  existing old-gen size histogram + residency snapshots; record in Run J.
- **Rollback**: `ECO_PROMO_CHUNK=0` (runtime), or flip
  `PROMO_CHUNK_MODE` to 0 (source default) — no compiler artifacts move
  either way.
