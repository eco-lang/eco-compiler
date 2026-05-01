# Large Strings / Byte Buffers via Split Header + Body

## Motivation

Today, strings (`Tag_String`) and byte buffers (`Tag_ByteBuffer`) above
`HeapConfig::large_object_threshold` (default 8 KiB) are allocated directly in
old gen as a single pinned object via `ThreadLocalHeap::allocateLargePinned`
(see `large-object-pinned-allocation.md`). Strings/buffers below that threshold
live entirely in the nursery and are copied verbatim by Cheney evacuation on
every minor GC.

Two pain points:

1. **Copies.** Mid-sized payloads (a few KiB up to `large_object_threshold`)
   pay full-payload memcpy cost on every minor GC until promotion. The bytes
   themselves never matter to GC — they are pointer-free — so the work is pure
   overhead.
2. **Late reclamation.** Above the threshold, the entire blob lives in old gen
   and is reclaimable only at major GC. A short-lived large string/buffer
   stays committed until the next major cycle, even though its lifetime is
   nursery-scale.

This plan introduces a *split representation* for `Tag_String` and
`Tag_ByteBuffer` allocations whose payload exceeds a new
`large_header_split_threshold`:

- Body (pointer-free payload) lives in **old gen** as a regular,
  size-class-or-large-block cell. It is never copied, never moved.
- Header (small, fixed-size, points to the body) lives in the **nursery**.
  Minor GC copies/promotes only the header.
- A 1-bit per-body "seen this minor GC" color drives early reclamation of
  bodies whose only reference (the nursery header) died this cycle.

Eco's existing invariants make this cheap and safe:

- HEAP_005: no old→young pointers. The nursery header → old-gen body link
  is young→old, which is fine.
- Bodies are pointer-free (Tag_String chars[], Tag_ByteBuffer bytes[]). Major
  GC never has to scan inside.
- One thread per heap (HEAP_007), so there is no cross-thread visibility
  problem on the per-body color bit.

## Non-goals

- **No change to small strings/byte buffers.** Below the new threshold the
  representation is unchanged.
- **No new heap region.** Bodies use the existing old-gen allocator
  (size-class cell or `is_large` block, depending on payload size).
- **No write barriers.** We are not enabling old→young pointers. The header
  still embeds a young→old `HPointer body` (legal under HEAP_005).
- **`Tag_StringRope` and `Tag_StringSlice` are out of scope.** Their bodies
  contain pointers, so they cannot adopt this scheme. Concat/slice operations
  that today might produce a large flat leaf already go through StringOps;
  the leaf they produce is what changes.
- **No change to Bytes module semantics.** Only the underlying representation
  switches above threshold.
- **No change to `Tag_Array` (ElmArray)** — even when uniform-unboxed it can
  contain pointers depending on `header.unboxed`, so a generic split would
  need per-instance reasoning. Defer until profiling shows it matters.

## Files Touched

| File | Change |
|---|---|
| `runtime/src/allocator/Heap.hpp` | Add `Tag_LargeStringHeader`, `Tag_LargeByteHeader`; define `LargeStringHeader` / `LargeByteHeader` structs (small fixed-size, contain `HPointer body`). |
| `runtime/src/allocator/AllocatorCommon.hpp` | Add `large_header_split_threshold` to `HeapConfig`; validate it; teach `getObjectSize` about the new tags. |
| `runtime/src/allocator/OldGenSpace.hpp` / `.cpp` | New `LargeBodyMeta`, `large_bodies_`, `large_body_index_`, `nursery_owned_bodies_`; new methods `allocateLargeBody`, `registerLargeBody`, `markLargeBodySeen`, `promoteLargeHeader`, `sweepNurseryLargeBodies`, `freeLargeBodyCell`. Extend `markChildren` to handle the new header tags. |
| `runtime/src/allocator/NurserySpace.hpp` / `.cpp` | Add `bool minor_color_`. In `minorGC`, flip color at the start and call `oldgen.sweepNurseryLargeBodies(minor_color_)` at the end. In `scanObject`/`evacuate`, special-case the new header tags so the body HPointer is *not* treated as a child to evacuate; instead call `oldgen.markLargeBodySeen`. After promotion of a `Large*Header`, call `oldgen.promoteLargeHeader`. |
| `runtime/src/allocator/ThreadLocalHeap.hpp` / `.cpp` | New `allocLargeString` / `allocLargeByteBuffer` helpers. Update `allocate` / `allocateSlow` so the existing large-object path uses these for the two tags. |
| `runtime/src/allocator/HeapHelpers.hpp` | Update `allocString`, `allocByteBuffer`, `allocByteBufferZero` to route through the new split path when the requested size exceeds the new threshold. |
| `runtime/src/allocator/StringOps.cpp` / `.hpp` | Existing readers (`stringLength`, `stringData`, `charAt`, `toStdU16String`, leaf-only assertions) must accept the new header tag and resolve through `body`. `isLeaf` semantics: a `Tag_LargeStringHeader` is conceptually a flat leaf (length + chars), so `stringLength`, `charAt`, etc. must transparently handle it. |
| `design_docs/invariants.csv` | Add a new HEAP_* invariant capturing the split-header rule. Update HEAP_025 (StringRepresentation) to mention the additional `Tag_LargeStringHeader` form. |
| `runtime/test/allocator/AllocatorTest.cpp` | New tests (see Step 8). |

## Step-by-Step Plan

### Step 1 — New tags and header structs

**File:** `Heap.hpp`.

1. Add `Tag_LargeStringHeader` and `Tag_LargeByteHeader` to the `Tag` enum.
   Insert them **before** `Tag_Free` and `Tag_Forward`. The runtime relies
   on `hdr->tag <= Tag_Forward` (NurserySpace.cpp:914,944) and Tag_Forward
   "must remain last", so the new tags slot in next to `Tag_Array`.
2. Define:
   ```cpp
   struct LargeStringHeader {
       Header header;     // tag = Tag_LargeStringHeader; size = logical UTF-16 length
       HPointer body;     // -> Tag_String body in old gen
   };
   struct LargeByteHeader {
       Header header;     // tag = Tag_LargeByteHeader; size = logical byte count
       HPointer body;     // -> Tag_ByteBuffer body in old gen
   };
   ```
   Both are 16 bytes (header + HPointer). `header.size` carries the *logical*
   length so existing `stringLength` / `byteBufferLength` callers can read it
   without resolving the body. The body's own `header.size` matches.
3. Add `LargeStringHeader` and `LargeByteHeader` to the `HeapValue` union.

**Rationale.** The bodies reuse `Tag_String` / `Tag_ByteBuffer` unchanged, so
all existing pointer-free code paths still apply. Only the *headers* are new
tag kinds, distinguished from inline-payload allocations by tag.

### Step 2 — `getObjectSize` + tag-coverage updates

**File:** `AllocatorCommon.hpp`.

1. Add cases in `getObjectSize`:
   ```cpp
   case Tag_LargeStringHeader: size = sizeof(LargeStringHeader); break;
   case Tag_LargeByteHeader:   size = sizeof(LargeByteHeader);   break;
   ```
2. HEAP_004 requires updates to every place that switches on `Tag`: audit
   `getObjectSize`, `markChildren` (`OldGenSpace.cpp:1421` and the matching
   fixup walk at line 3354), `scanObject` (`NurserySpace.cpp:1171`), and any
   debug printers in `RuntimeExports.cpp` / `HeapHelpers.hpp`.

### Step 3 — `HeapConfig::large_header_split_threshold`

**File:** `AllocatorCommon.hpp`.

1. Add field with default `2048` bytes (tunable; lower bound experiment is
   ~512 B but Eco's `alloc_buffer_size` of 128 KiB and the rope-flatten
   limit of 32 Ki UTF-16 units make 1–2 KiB the right starting point):
   ```cpp
   size_t large_header_split_threshold = 2048;
   ```
2. In `validate()`:
   - Reject `large_header_split_threshold < sizeof(Header)`.
   - Reject `large_header_split_threshold > large_object_threshold`. Above
     `large_object_threshold` the existing pinned-large path no longer fires
     for these two tags (we replace it), so the split path absorbs that
     range.
   - Reject bodies that exceed `max_heap_size / 2` (handled implicitly by
     old-gen allocation failing).

   The relationship between thresholds:
   - `[0, large_header_split_threshold)`: small inline allocation in nursery
     (status quo).
   - `[large_header_split_threshold, ∞)`: split header+body for `Tag_String`
     and `Tag_ByteBuffer`. Other tags continue to use the existing
     `large_object_threshold` pinned path.

### Step 4 — Old-gen body allocator and bookkeeping

**File:** `OldGenSpace.hpp` / `.cpp`.

1. Add types and storage:
   ```cpp
   using LargeBodyId = uint32_t;
   struct LargeBodyMeta {
       void*  body_base;   // raw pointer to the body object's header.
       size_t cell_size;   // full cell size in bytes (includes Header).
       bool   is_large;    // true if the cell is an is_large block.
       bool   color;       // last minor_color that saw a live header.
   };
   std::vector<LargeBodyMeta>       large_bodies_;
   std::unordered_map<void*, LargeBodyId> large_body_index_;
   std::vector<LargeBodyId>         nursery_owned_bodies_;
   std::vector<LargeBodyId>         free_large_body_ids_;  // tombstone reuse.
   ```

2. New methods:

   - `void* allocateLargeBody(size_t totalSize, Tag bodyTag, bool initialColor)`:
     decides between size-class cell and `is_large` block via the same
     branching as `OldGenSpace::allocate` (size vs `alloc_buffer_size`),
     allocates, writes the body header (tag = `Tag_String` or `Tag_ByteBuffer`,
     `header.size` = logical length, `pin = 1` only when it landed on an
     `is_large` block — bodies in size-class cells do NOT need pinning, since
     the compactor doesn't move pointer-free objects... actually it does
     evacuate by tag, so we DO need pin = 1 here; see Step 7.2 for the
     reasoning), calls `registerLargeBody`, returns the cell pointer.

   - `LargeBodyId registerLargeBody(void* body, size_t cellSize, bool isLarge,
     bool minorColor)`: appends `LargeBodyMeta`, inserts into
     `large_body_index_` and `nursery_owned_bodies_`. Reuses a tombstone id
     from `free_large_body_ids_` if present.

   - `void markLargeBodySeen(HPointer body_hptr, bool minor_color)`: O(1) hash
     lookup; if found and tracked, sets `meta.color = minor_color`. No-op for
     untracked addresses (covers small inline strings).

   - `void promoteLargeHeader(HPointer body_hptr)`: removes the body from
     `nursery_owned_bodies_` (swap-remove). Does NOT free or change the body
     — it is now major-GC-managed. Idempotent for non-tracked bodies.

   - `void sweepNurseryLargeBodies(bool minor_color)`: walks
     `nursery_owned_bodies_`, frees every body whose `meta.color !=
     minor_color`, compacts the vector in place. Returns count freed.

   - `void freeLargeBodyCell(LargeBodyMeta& m)`: depending on
     `m.is_large`:
     - **Large block path:** clear `large_block_mark_[block_index]`,
       transition the block via the existing `markBlockAsFreeLarge` /
       `releaseBlockToAllocator` helpers (whichever fits — `markBlockAsFreeLarge`
       leaves the block on `free_large_blocks_` for reuse without returning
       to the OS; `releaseBlockToAllocator` returns it). Match what major
       GC does for dead is_large blocks today.
     - **Size-class cell path:** write `Tag_Free` over the cell header,
       set `header.size = m.cell_size`, push onto
       `free_lists_[freeListClassFor(m.cell_size)]` (or split across
       smaller classes via `pushSpanOnFreeLists` if it exists; use
       whichever helper sweep already uses for coalesced runs).
       Decrement `buffer_meta_[blk].live_bytes` by `m.cell_size`.
     Erases `m.body_base` from `large_body_index_`, pushes the id onto
     `free_large_body_ids_`, nulls out `m.body_base` for debug.

3. Major-GC integration in `markChildren`:
   ```cpp
   case Tag_LargeStringHeader:
   case Tag_LargeByteHeader: {
       HPointer body = (hdr->tag == Tag_LargeStringHeader)
           ? static_cast<LargeStringHeader*>(obj)->body
           : static_cast<LargeByteHeader*>(obj)->body;
       markHPointer(body);  // marks the body live in its block
       break;
   }
   ```
   Bodies are pointer-free, so once marked their bit prevents sweep from
   freeing them; the existing oldgen sweep already skips scanning into
   pointer-free objects via tag dispatch.

4. Reset bookkeeping in `OldGenSpace::reset()` so tests work cleanly.

### Step 5 — Minor-GC color toggling and body marking

**File:** `NurserySpace.hpp` / `.cpp`.

1. Add `bool minor_color_ = false;` to `NurserySpace`.

2. In `minorGC`:
   - Flip `minor_color_ = !minor_color_;` at the very start, *before* any
     evacuation.
   - At the very end, after the phase-3 promoted-object scan completes:
     `oldgen.sweepNurseryLargeBodies(minor_color_);`

3. In `scanObject` and `evacuate`, add cases for the new tags:
   ```cpp
   case Tag_LargeStringHeader: {
       LargeStringHeader* h = static_cast<LargeStringHeader*>(obj);
       oldgen.markLargeBodySeen(h->body, minor_color_);
       // body HPointer points to old gen — never traced by minor GC.
       break;
   }
   case Tag_LargeByteHeader: {
       LargeByteHeader* h = static_cast<LargeByteHeader*>(obj);
       oldgen.markLargeBodySeen(h->body, minor_color_);
       break;
   }
   ```
   These are scan-time hooks; the body field is *never* passed to `evacuate`,
   so the body pointer keeps its identity across minor GC.

4. Promotion path: `evacuate` already detects `hdr->age >= promotion_age` and
   allocates in old gen via `oldgen.allocate`. After the `memcpy` of the
   header into old gen, dispatch on tag:
   ```cpp
   if (hdr->tag == Tag_LargeStringHeader || hdr->tag == Tag_LargeByteHeader) {
       HPointer body = /* read from new_obj */;
       oldgen.promoteLargeHeader(body);
   }
   ```
   This removes the body from `nursery_owned_bodies_` so subsequent minor
   GCs don't try to mark/free it.

5. Order matters: the `markLargeBodySeen` call in scanObject must run for
   *every* live header path — both when the header is being scanned in
   to-space (post-evacuation) and when it is being promoted. The simplest
   correct rule is: do it during the to-space scan only (Cheney loop),
   because every live header ends up scanned exactly once there, regardless
   of whether it was kept in nursery or promoted to old gen. Promotion
   handling is then *only* the `promoteLargeHeader` call.

### Step 6 — Allocation entry points

**File:** `ThreadLocalHeap.cpp` / `.hpp`, `HeapHelpers.hpp`.

1. New helpers in `ThreadLocalHeap`:
   ```cpp
   HPointer allocLargeString(const u16* chars, size_t length);
   HPointer allocLargeByteBuffer(const u8* bytes, size_t length);
   ```
   Each:
   - Computes total payload size (`sizeof(ElmString)+length*2`, or
     `sizeof(ByteBuffer)+length`).
   - If size < `large_header_split_threshold`: delegate to the existing inline
     path (`alloc::allocString` / `allocByteBuffer`), preserving status quo.
   - Else: allocate body in old gen via `old_gen_.allocateLargeBody(...)`,
     fill `body->header` and copy `chars`/`bytes`. Then nursery-allocate the
     small `Large*Header`, fill `header.size = length`, `body = wrap(body_raw)`,
     and return its HPointer.
   - GC may fire on either allocation. Order matters: allocate the body
     **first** (it can fail / trigger major GC, but cannot move other
     objects), then the header (which can fire minor GC, which now handles
     the new tag correctly because steps 1–5 are in place). The body's
     `body_base` does not move, so the order is safe.
   - On nursery-allocation failure (slow path), re-issue. The body is
     already registered as `nursery_owned`; if the header allocation
     ultimately succeeds, the next minor GC will see the live header and
     keep the body. If header allocation fails fatally (OOM), the body is
     leaked until the next major GC marks it unreachable — acceptable, same
     as any partial-construction-OOM failure today.

2. Update `HeapHelpers.hpp` `allocString` / `allocByteBuffer` /
   `allocByteBufferZero` to call the new ThreadLocalHeap helpers. The
   threshold check lives there so callers don't have to know.

3. Update `ThreadLocalHeap::allocate` / `allocateSlow` so the existing
   pinned-large path **does NOT** fire for `Tag_String` /
   `Tag_ByteBuffer`: those two tags now go through the split path
   regardless of whether they exceed `large_object_threshold` (they only
   need to exceed `large_header_split_threshold`). All other tags retain
   the current pinned-large behaviour. Concretely: the checked condition
   becomes `size >= large_object_threshold && tag != Tag_String && tag !=
   Tag_ByteBuffer`. The new `alloc::allocString` / `alloc::allocByteBuffer`
   paths bypass `ThreadLocalHeap::allocate` entirely for the split case,
   so this only matters for the (rare) caller that already routes Tag_String
   / Tag_ByteBuffer through `allocate(size, tag)` directly — audit those.

### Step 7 — String/Bytes API surface

**File:** `StringOps.cpp` / `.hpp`, `HeapHelpers.hpp`.

1. `stringLength` and `byteBufferLength` already read `header.size`; for the
   new headers `header.size` is the logical length, so they continue to
   work without changes. Verify.

2. `stringData(s)` currently asserts `Tag_String`. Three options:
   - (a) Change the assertion to accept `Tag_LargeStringHeader` and route
     to `body->chars` after `Allocator::resolve`.
   - (b) Force callers through a new helper `stringDataFlat(s)` that handles
     both inline and split leaves uniformly.
   - (c) Have `ensureFlat` collapse a `Tag_LargeStringHeader` to its inline
     form, so internal hot loops can keep their flat-leaf assumption.
   Recommend (a) for read-only callers (`charAt`, `toStdU16String`,
   `equal`/`compare`); avoid (c) because it would defeat the whole point
   of not copying.

3. `isLeaf(obj)` (StringOps.hpp:41): treat `Tag_LargeStringHeader` as a
   leaf for rope/slice purposes — its body is a flat character array,
   which is exactly what callers want.

4. Bodies get `header.pin = 1` (see Resolved Decision 3). The body is
   pointer-free and unchanging, so pinning costs nothing semantically and
   guarantees `body_base` is stable for the entire body lifetime — which is
   what `large_body_index_` requires to be a valid hash key.

5. Add a debug assertion in `HeapHelpers::isStringLeaf` and
   `isByteBuffer` (or equivalent) that the input is *never* a
   `Tag_LargeStringHeader` / `Tag_LargeByteHeader`. Catches any callsite
   that accidentally hands a header to a body-shaped reader.

### Step 8 — Tests

Add to `runtime/test/allocator/AllocatorTest.cpp`:

1. **Header tag/layout test.** Allocate a 10 KiB string. Assert the result
   has tag `Tag_LargeStringHeader`, the result lives in the nursery
   (`alloc.isInNursery(obj)`), and the body lives in old gen
   (`alloc.isInOldGen(resolve(h->body))`). Verify `header.size` reflects
   logical length.
2. **Survival across minor GC without copy.** Capture body raw address.
   Run several minor GCs. Assert: the header HPointer may have moved
   (semi-space evacuation), but the body raw address is **unchanged**.
3. **Early reclamation.** Allocate a 10 KiB byte buffer, drop the
   reference, run one minor GC. Assert: the body's old-gen cell is back on
   the appropriate free list (or in `free_large_blocks_`), and a
   subsequent same-sized allocation reuses it.
4. **Promotion transfers ownership.** Allocate a large string, root it,
   run minor GCs until promotion. Assert the body is no longer in
   `nursery_owned_bodies_` and a subsequent unrelated minor GC does NOT
   free it.
5. **Major GC reclaims promoted bodies.** Continue test 4: drop the root,
   run major GC, assert the body cell is reclaimed by the standard
   mark/sweep path (not by `sweepNurseryLargeBodies`).
6. **Threshold boundary.** Allocate at `large_header_split_threshold - 8`
   and `large_header_split_threshold` exactly. Assert the former is an
   inline `Tag_String` in nursery; the latter is a `Tag_LargeStringHeader`
   with old-gen body.
7. **Boundary at `alloc_buffer_size`.** Allocate a string whose body is
   just below and just above `alloc_buffer_size`, asserting the body lands
   in a size-class cell vs. an `is_large` block respectively, and that
   `freeLargeBodyCell` reclaims it correctly in both cases.
8. **Stress.** Loop allocating and dropping mid-sized strings. Track total
   committed old-gen bytes; assert it stays bounded across many minor GCs
   (validates that the 1-bit color scheme actually frees bodies promptly).
9. **Mixed read paths.** `String.length`, `String.left/right`, equality,
   and `String.toList` all behave identically for split and inline strings
   of equal content. Same for `Bytes.width`, slicing, encoder/decoder
   round-trips.

### Step 9 — Documentation and invariants

1. Add a new HEAP_* invariant, e.g.:
   ```
   HEAP_026;Runtime_Heap;LargeStringSplit;enforced;
     Strings/byte buffers whose payload exceeds large_header_split_threshold
     are represented by a small Tag_LargeStringHeader / Tag_LargeByteHeader
     in the nursery whose `body` HPointer references a Tag_String /
     Tag_ByteBuffer object pinned in old gen. Bodies are never copied;
     bodies of nursery-owned headers are reclaimed at the end of the next
     minor GC if no surviving header refers to them, via a per-body 1-bit
     "seen" color tracked in OldGenSpace::large_bodies_.
   ```
2. Update HEAP_025 to mention `Tag_LargeStringHeader` as an additional
   string form (alongside `Tag_String` / `Tag_StringSlice` / `Tag_StringRope`).
3. Note in `design_docs/theory/` that the body HPointer is a young→old
   reference (HEAP_005-compliant — that direction is always allowed).

## Resolved Decisions

1. **Default for `large_header_split_threshold` = 1–2 KiB.** Start at
   1024–2048 bytes, not 512 B. Eco's `alloc_buffer_size` is 128 KiB and
   strings already have a higher rope-flatten limit (32 Ki UTF-16 units),
   so 512 B is too eager as a default. Use `GCStats`' per-allocation size
   histogram and free-list occupancy stats to tune downward later if real
   workloads support it. The field stays a `HeapConfig` knob so individual
   tests / consumers can override.

2. **`Tag_StringSlice` / `Tag_StringRope` and `ensureFlat`.** Bodies are
   ordinary `Tag_String` leaves with inline `chars[]` (HEAP_025
   unchanged). Headers use a *distinct tag* (`Tag_LargeStringHeader`)
   that StringOps never treats as a string. Consequence:
   - `ensureFlat` / `flattenToLeaf` / `makeLeafFromBuffer` continue to
     return real `Tag_String` leaves — those leaves may now be the body
     of a `Tag_LargeStringHeader`, but every existing kernel/StringOps
     reader that follows a `Tag_String` keeps working. The only audit
     required is that no caller hands a `Tag_LargeStringHeader` object
     to a reader that assumes inline `chars[]`. Enforce by adding a
     debug assertion in `HeapHelpers::isStringLeaf` / `isByteBuffer`
     that they never observe the new header tags.
   - Rope/slice construction is unaffected — it operates on `Tag_String`
     leaves regardless of whether those leaves are inline-payload or
     split-body.

3. **Bodies are pinned (`header.pin = 1`).** Mirrors the existing
   above-`large_object_threshold` pinned-large-object policy. Keeps
   `body_base` stable so `large_body_index_` keys remain valid; avoids
   teaching the compactor's fixup phase about nursery headers (which
   would be a much bigger surface change). The cost is acceptable —
   bodies are large, pointer-free, and live in segregated-fits blocks
   anyway.

4. **Major GC interleaved with minor GC: safe by construction.** The
   ownership invariant "only nursery-owned bodies (i.e. headers still in
   nursery) are eligible for early free" is sufficient:
   - Major GC traces old gen only; nursery objects go through
     `nursery_visited_` and never have their headers mutated.
   - Once a header is promoted to old gen, `promoteLargeHeader` removes
     the body's id from `nursery_owned_bodies_`. From then on the body
     is governed only by old-gen mark/sweep.
   - Bodies still in `nursery_owned_bodies_` have, by discipline, no
     other root path — only the nursery header references them. Major
     GC therefore cannot depend on a nursery header to keep a body alive
     while minor GC is freeing it.
   Add a defensive `assert(compact_phase_ != CompactionPhase::Evacuating
   && compact_phase_ != CompactionPhase::FixingRefs)` at the top of
   `sweepNurseryLargeBodies` to flag any future regression.

5. **Initial `minor_color_` and construction window.** Safe as long as
   `registerLargeBody` installs `meta.color = minor_color_` *before*
   returning from the allocation routine, and the routine doesn't
   safepoint between body alloc and metadata installation. Eco's
   fast-path allocations are gc-leaf (`eco_gc_alloc_region_fast`) and
   only the slow path safepoints around a `gc.statepoint`. Implement
   `allocLargeString` / `allocLargeByteBuffer` so the body alloc + meta
   registration happen inside a single non-yielding span; if a future
   refactor splits them across safepoints, add a transient construction
   root.

6. **Direct `Tag_String` allocations in `StringOps.cpp` (lines 335, 434)
   must route through the threshold helper.** Centralise via a single
   `allocStringMaybeSplit` (or fold into `alloc::allocString`). No code
   path may construct an `ElmString` directly without consulting
   `large_header_split_threshold`.

7. **Compiler-generated callsites are covered automatically.** Per
   existing invariants, MLIR emits only leaf `Tag_String` allocations via
   `eco_alloc_string*` / `Eco_StringLiteralOp` / `Eco_AllocateStringOp`,
   and `ByteBuffer` allocations route through `elm_alloc_bytebuffer` /
   `BytesOps` helpers. Pushing the threshold logic *inside* those runtime
   helpers means generated code needs no changes. Ensure no MLIR/LLVM
   lowering inlines a raw `Tag_String` / `Tag_ByteBuffer` construction.

8. **`ECO_GC_DEBUG_LIVENESS` / `EcoPtrIntVerify` need no conceptual
   change.** They care about pointer/tag consistency and GC root
   coverage, not specific tag names. Provided the new tags are wired
   into `Tag`, `getObjectSize`, `scanObject` (nursery), and
   `markChildren` (old gen) per HEAP_004, and HEAP_001/HEAP_025 stay
   intact, the verifiers stay happy. Add the debug assertion in
   `isStringLeaf` / `isByteBuffer` mentioned in (2) to shake out any
   callsite that accidentally treats a header as a body.

## Remaining Open Questions

1. **`free_large_body_ids_` reuse vs. id stability.** `LargeBodyId` is
   internal to `OldGenSpace` (no mutator-visible escape), so reuse is
   safe. Confirm no test grabs an id and expects stability across
   allocations.

2. **Body `header.size` width.** `Header.size` is 32 bits → 4 GiB byte
   buffers, 8 GiB UTF-16 strings. Matches the existing inline ceiling.
   Document; no regression.

3. **`HeapValue` union footprint.** Both new headers are 16 bytes —
   smaller than existing members. Add a `static_assert` confirming
   `sizeof(HeapValue)` doesn't grow.

4. **Profiling-driven threshold tuning.** Locked-in default is 1–2 KiB,
   but the actual sweet spot needs measurement on real workloads via
   `GCStats` size histograms before considering pushing the default
   downward.

## Risks

- **Increased old-gen allocation pressure.** Bodies now occupy old-gen
  capacity from birth, even for short-lived large strings. If the
  reclamation in `sweepNurseryLargeBodies` doesn't fire often enough
  (many objects below the split threshold per minor cycle so minors are
  rare), old-gen capacity may grow. Mitigation: tune
  `large_header_split_threshold` upward if profiling shows churn.
- **Header-promotion / body-color races.** The 1-bit color scheme
  assumes minor GC is the only writer. If we later add concurrent
  threads, this needs to become atomic or per-thread. HEAP_007 says
  one-thread-per-heap today, so this is a future concern. Document.
- **Compaction interaction.** Bodies are pinned per Resolved Decision 3,
  so the compactor leaves them in place. If a future change drops the
  pin, every header pointer would need updating during fixup, and the
  compactor's fixup walk would have to be extended over nursery headers
  — a much larger surface change. Re-evaluate only if profiling shows
  pinning is materially costing fragmentation.
- **String hot paths regress.** Every read through a `Tag_LargeStringHeader`
  pays an extra HPointer resolve compared to inline `Tag_String`. For
  long random-access workloads this is fine; for tight loops over many
  strings it may not be. Profile before locking in the default threshold.
