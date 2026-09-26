# Chunked lists — building the spine and the data separately

**Status:** PLANNED, deferred (2026-09-26). It is not scheduled. Written against the `keep-TG4`
tree.

**Replaces:** the size bound `alloc::chunkChainFits` introduced by threaded-gc-04 (S1 fix,
`plans/threaded-gc-04-frozen-published-heap.md` §7a and §9 item 1).

**Background:**
- `plans/chunked-list-representation.md` (the chunked-list design, len-consistency, hybrid spines);
- HEAP_SNAPSHOT_001 (P1), HEAP_BUILDER_001..003, HEAP_005, HEAP_061;
- the TG4 discussion that led here: every head-first `next` pointer points from an older object
  to a younger one.

---

## 0. The problem

A chunked list is a spine of **views** (`ConsChunk {backing, offset, len, next}`) over **backings**
(`ListBacking {elems[]}`, capped below the large-object threshold, ~1,020 elements, 8 KiB). The
bulk builders (`append`, `concat`, `reverse`, `listFromPointers` / `Ints` / `Unboxables`, the two
`eco_scratch_finish*`) all go through `alloc::listChunkChain`.

**Before threaded-gc-04:**
- `listChunkChain` allocated the whole chain (backings and views, tail-first), and the caller
  filled the backings afterwards.
- A minor GC during construction could age a backing (a P1 violation), and a second minor could
  promote it. The fill then wrote young pointers into an old object: an old→young edge that no
  minor scans.

**The TG4 fix and its cost:**
- All backings and views are built with `builder = 1` and released by `finishChunkChain` after
  the fill. Builders are never promoted, so the whole chain must fit in the nursery.
  `chunkChainFits` therefore limits the chunk path to chains of ≤ ¼ of the current per-side
  nursery.
- In practice that is ~2.1 M elements at the initial 64 MiB per side and ~4.2 M at the 128 MiB
  cap. Larger batches fall back to cons cells, at ~24 B per element against ~8 B chunked, with
  slower traversal and more GC copying.

**Goal:** remove the bound. Build a chunk chain of any length with **no write into any object
after a GC could have aged or promoted it**, and with only a small, length-proportional amount
of pinned (builder) memory.

---

## 1. The key observation

A chunk is two objects with different pointer directions:

| object | points to | written after creation? |
|---|---|---|
| backing | the elements (older than the backing: they exist in the source before it) | not needed: fill it **immediately** after allocation, with no allocation in between |
| view | its backing (older) and `next` | only `next`, and only in head-first construction, where `next` is allocated later (younger) |

So the data never needs the builder bit or a deferred write. Only the spine does, and only when
it is built head-first. There are two construction orders:

**T (tail-first, incremental): builder-free.**
1. Take the **last** run of elements.
2. Allocate its backing and fill it at once.
3. Allocate the view with `next` = the part of the chain already built (older). Repeat towards
   the head.

Every edge points to an older object. This is the natural direction, exactly like
cons-accumulation. It needs the source **backwards**: random access (a vector) or a source that
arrives in reverse order (`reverse`).

**H (head-first, streaming): builder views only.**
1. Take the **first** run.
2. Allocate its backing and fill it at once from the forward source.
3. Allocate the view as a builder, with `next` = Nil (a placeholder), and patch the previous
   view's `next` to it. The previous view is still a builder, so the write is legal.
4. After the last run, set the last view's `next` to the tail, then clear the builder bit on
   every view in one pass.

Backings are ordinary objects and may be promoted at any time. They point only at older
elements. Views stay in the nursery until the end. H needs the source only **forwards**
(`append`, `concat`).

Pinned memory in H is one view (40 B) per ~1,020 elements: about 4 MB for 100 M elements.

### 1.1 Edges during H construction (why it is sound)

| edge | direction | status |
|---|---|---|
| view → backing | young builder → any age (the backing may be promoted) | legal (young → old) |
| view → next view | builder → builder, both nursery | legal. Both move together, and the kernel roots the head |
| last view → tail list | young → older | legal |
| backing → element | backing → older element | legal. When a backing is promoted its elements are already old, or are promoted with it by the existing promoted-parent drain |
| anything → view | only other views and the kernel root | no promoted object ever points at a builder (HEAP_BUILDER_001) |

The one deferred write, `view.next`, lands in a builder, so HEAP_SNAPSHOT_001 holds.

### 1.2 Edges during T construction

All edges point from a newly allocated object to an older one. No builder bit is needed, and
nothing is written after its first safepoint.

---

## 2. Design

### 2.1 API (in `HeapHelpers.hpp`, namespace `Elm::alloc`)

```cpp
// Tail-first, builder-free. The caller supplies elements from the LAST to the
// FIRST through `pull(Unboxable& out)`, which must not allocate and must re-read
// rooted storage (called only after the backing allocation returns).
template <typename PullBackward>
HPointer buildChunkChainTail(u32 n, u8 kind, HPointer next, PullBackward pull);

// Head-first streaming. The caller supplies elements from FIRST to LAST through
// `pull(Unboxable& out)`, same contract. Views are builders until the function
// returns; an RAII guard clears them on every exit path.
template <typename PullForward>
HPointer buildChunkChainHead(u32 n, u8 kind, HPointer next, PullForward pull);
```

- Both take `n` (the count-first probe already computes it: `probeShape`, `rooted.size()`,
  scratch sizes) and the tail `next`. `len` needs `n + listLogicalLen(next)`, computed once.
- Run layout: runs are full (`listBackingMaxElems()`), and the **tail-most run takes the
  remainder**, exactly as today, so nothing that walks chains changes.
  - T builds the remainder run first.
  - H computes `first_run = n % max` (or `max`) and starts with that, so its *head* run holds the
    remainder. That is legal for a hybrid spine, but it differs from today's layout. Pick one:
    - keep today's layout by having H make its **last** run the remainder (`runs = [max, …, max,
      rem]`); **recommended**;
    - or document that the remainder may sit anywhere (check `listLogicalLen` and the `take` /
      `drop` fast paths first).
- `len` telescopes per view as today: the view's total logical length = the elements from its
  run to the end, plus the tail's length.
- The existing `listChunkChain` + `ListChainWriter` / `ListChainReverseWriter` +
  `finishChunkChain` + `chunkChainFits` are deleted once every caller has moved.

### 2.2 Rooting and allocation order (both modes)

Per run:
1. Allocate the backing: `listBacking(run, kind)`. **This may GC.**
2. Resolve the backing *after* the allocation.
3. `pull` `run` elements into it, with no allocation. `pull` reads from rooted storage: a
   `StackRootRangeGuard`ed vector, `RootedListCursor`, or the scratch stack, whose scanner keeps
   entries current.
4. Allocate the view: `consChunkView(backing, 0, len, next_or_nil, kind)`. **This may GC.** The
   backing HPointer and `next` are rooted by `consChunkView`'s own root array.
   - In H: `mark_as_builder` the view right after it is allocated.
   - In H: patch `prev_view.next = view`. The previous view is a builder, resolved after the
     allocation.
5. Keep the chain's anchor rooted across iterations: the current head in T, and the first view
   and last view in H (a small local root set).

H's exit guard (RAII `ChunkSpineGuard`): on normal exit, set `last_view.next = next` (the tail)
and walk from the first view, clearing the builder bit on each view (O(n / max)). On an
exceptional or early exit it does the same: the partial list is garbage but must not leave
builder bits behind, per HEAP_BUILDER_003.

### 2.3 Caller mapping

| caller | source | mode |
|---|---|---|
| `listFromPointers` (`HeapHelpers.hpp`) | rooted vector (random access) | **T** (pull from the vector end) |
| `listFromInts` | vector of scalars | **T** |
| `listFromUnboxables` (both `reversed` arms) | rooted vector | **T** (index direction per arm) |
| `eco_scratch_finish_int` / `eco_scratch_finish` (`RuntimeExports.cpp`) | scratch stack (random access, scanner-maintained) | **T** |
| `ListOps::reverse` | forward walk of the source = backward order of the result | **T**, pulling from a `RootedListCursor` over the source |
| `ListOps::append` (`a ++ b`) | forward walk of `a`, tail `b` | **H** with `RootedListCursor(a)` |
| `ListOps::concat` | nested forward walks | **H** with a rooted outer cursor and a rooted inner cursor |

Every cursor-based caller switches from `ListCursor` (raw) to `RootedListCursor`, because
allocation now interleaves with the walk. The count-first probe (`probeShape`) still decides
uniform kind and `n` before building starts.

### 2.4 What is removed

- `chunkChainFits` and the ¼-nursery bound: the chunk path is taken whenever the kind is uniform
  and `n >= 4`, as before TG4.
- `finishChunkChain`, the all-builder chain, and `ListChainReverseWriter`.
- Builder backings: backings are never builders again. This is expected to undo TG4's +1
  copied-in-nursery counter delta.

---

## 3. Invariants

- **Amend HEAP_SNAPSHOT_001:** replace "Chunk-chain backings and views are built as builders
  (`listChunkChain` / `finishChunkChain`, bounded by `chunkChainFits`)" with: "Chunk chains are
  built tail-first incrementally (builder-free), or head-first with builder **views** only;
  backings are filled immediately after allocation and never written again (plans/
  chunked-list-spine-data-split.md)."
- **HEAP_BUILDER_001:** no change. Views are nursery builders, and no promoted object references
  one.
- `chunked-list-representation.md`: record the construction orders and the layout choice of
  §2.1.
- **Phase 5a note** (master plan): builder views that exist at a snapshot t0 are written after
  t0 (their `next`), so they are snapshot roots, like every other builder.

---

## 4. Steps (outline)

1. **Characterise first.**
   - Add a counter of batches that take the cons fallback because of `chunkChainFits`: stats
     builds, runs of E2E and the self-compile. The expected count is 0 on the self-compile.
   - Add a list-heavy benchmark that builds lists of 5–50 M elements, where the fallback is
     visible.
   - Record wall, RSS and GC for both.
2. **Implement `buildChunkChainTail`** and move the five T callers. Unit tests:
   - element-exact lists across forced mid-construction minors (park the nursery with
     `NurserySpaceTestAccess::headroom` as the TG4 S1 test does), at 10 k, 1 M and 20 M elements
     under a small nursery config;
   - no builder bit left anywhere;
   - P1 census N/O/W at 0 in the validate and census trees.
3. **Implement `buildChunkChainHead`** and move `append` and `concat`. The same tests, plus:
   - early-exit and exception paths leave no builder;
   - `concat` of many small lists and of a few huge ones;
   - a chain whose views are the *only* nursery survivors across many minors (pinned views
     only).
4. **Delete** the old path and `chunkChainFits`, and amend the invariants and docs.
5. **Negative controls:**
   - fill a backing *after* allocating its view: census N/W must fire;
   - skip the builder bit on one H view: the validate tree's HEAP_BUILDER_001 or P1 tripwire
     must fire under a mid-construction promotion.
6. **Gates:** the threaded-gc gate set (unit + E2E, elm-tests, `full`, stress under GC pressure,
   the validate tree with the P1 tripwire, the census tree in abort mode, stats-off build,
   byte-identical `out.mlir`, bootstrap fixed point).
7. **Measurement:**
   - self-compile counters: expected identical to TG3's, i.e. the TG4 +1 copy disappears;
     otherwise explain;
   - the list-heavy benchmark from step 1: memory and time for lists over the old bound should
     move from the cons fallback's ~24 B per element to ~8 B.

---

## 5. Risks and traps

1. **Stale raw cursors.** Any `ListCursor` left in a caller that now allocates mid-walk reads
   stale memory. Grep every moved caller for `ListCursor(`, and run the validate tree (the
   stale-pointer tripwires) over the list suites.
2. **Reading an element before its backing's allocation.** A GC in the allocation moves the
   element: the value read earlier is stale. `pull` must be called only after `listBacking`
   returns. Design the helper so a caller cannot get this wrong: the helper calls `pull`, never
   the caller.
3. **H's builder views must never escape.** The guard must run before the head is returned, on
   every path.
4. **Layout drift** (§2.1): if the remainder moves to the head run, check every place that
   assumes "earlier links are full".
5. **`len` consistency:** the tail's length must be probed once, before building. A wrong `len`
   corrupts `List.length`'s O(1) path silently. Assert `len` against a walk in validate builds.
6. **Pinned-view pressure** is negligible (~40 B per ~1,020 elements), but a pathological
   `concat` of millions of tiny lists would create one view per input list only if runs were cut
   per input. Runs must stay packed across inputs, as today's writer does.

## 6. Out of scope

- Changing the chunked representation itself (backing capacity, offsets, `take`/`drop` views).
- Non-uniform-kind batches (they keep the cons path).
- The born-old pending list (HEAP_061). Backings stay below the large-object threshold, so they
  are never born old.
