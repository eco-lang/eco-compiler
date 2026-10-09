# Plan: a separate large-object space (LOS) with header-less large bodies

Status: **v2, implemented** (2026-10-09; §10). v2 was implementation-ready the same day. v1 (same day) was the draft; §12 is the
adversarial review that produced v2. Follows `plans/large-body-gc-trigger.md` (implemented
2026-10-08), whose §10 found the remaining large-`Bytes` blow-up: bag-page fragmentation.

**Read before coding:**
- `design_docs/invariants.csv`: HEAP_005, HEAP_007, HEAP_021, HEAP_023, HEAP_024, HEAP_026,
  HEAP_036, HEAP_048–HEAP_051, HEAP_054–HEAP_056, HEAP_062, HEAP_063, HEAP_065, HEAP_069,
  HEAP_072, HEAP_073, HEAP_076, HEAP_079, and the REP_* rows for String/Bytes.
- `test/tla/README.md` in full ("The canary", "When it fires"). Every phase below that edits a
  `TLA-REGION` lists it; each needs an AUDIT.md entry in every named model before
  `check-tla-manifest.sh --update` (GC_MODEL_001). Never repair a hash without the audit.
- `plans/kernel-parametricity-license.md` §2 (Phase 2 edits three licensed kernel files).
- `CLAUDE.md`: run each test command once, tee to `/tmp`, then grep.

## 1. Problem (verified in the tree, 2026-10-08/09)

**P1. Objects in (64 KiB, 512 KiB) cost a fresh 512 KiB page each.** Requests in
(LOT = 8 KiB, `alloc_buffer_size` = 512 KiB) go to `OldGenSpace::allocateFromBagPage`. The largest
size class is 64 KiB, so `sizeClass(65,544)` = NUM_SIZE_CLASSES and step 1
(`tryAllocateBySplittingLarger`) finds nothing; step 3 takes a fresh page, carves the object at
offset 0 and `pushSpanOnFreeLists` cuts the tail into exact-class cells of at most 64 KiB (the free
lists hold only exact-size cells). No free cell above 64 KiB ever exists; the major sweep re-cuts
coalesced runs the same way. A 64 KiB `Bytes` (body 65,544 B: 8-byte `Header` + payload) costs
512 KiB. Measured: `LargeBytesChurnTest` (2 GiB of 64 KiB chunks, all dropped) peaks at 16,387 MB
of old gen in use and grows RSS by 7 GB although 33 minors freed 2,007 MB of bodies; the native
Autobahn `--no-split` server reached 11.6 GB.

**P2. Large and ordinary objects share blocks.** Mixed blocks hold split bodies, YLOS objects,
pinned pointer-free objects, legacy-mode promoted large objects (8 KiB, 128 KiB], survivors of
demoted uniform blocks and small objects carved by ladder rungs 2/4/7.

**P3. Released-extent reuse leaked the tail (O7).** `Allocator::acquireOldGenBlock`'s `takeFreeAt`
handed out a whole larger extent but callers record and release only the requested size: the tail
was lost from `old_gen_free_blocks_` and stayed counted in `old_gen_in_use_bytes_`. **Fixed in
Phase 1 (done 2026-10-09).**

**P4. Large bodies carry a header nobody needs**, which pushes a 64 KiB payload off every power of
two. The nursery `LargeByteHeader`/`LargeStringHeader` already holds tag and logical length.

**Not a cause (checked):** the size-class block budget (`small_class_heap_budget_bytes`) only
orders ladder rungs 3/4 and measured inert (sweeps 2026-09-22/28).

## 2. Goals and non-goals

Goals:
1. **O7 fixed** (done): `old_gen_in_use_bytes_` equals the bytes handed out.
2. **Complete placement separation:** every old-gen object larger than the largest uniform class
   (`largestClassBytes()` = 8 KiB at defaults) and every old-gen-direct allocation at or above LOT
   (split bodies, YLOS, pinned pointer-free, permanent fallback) lives in the LOS; ordinary blocks
   (uniform and mixed) never hold such an object, and LOS blocks never hold an ordinary one.
3. **Header-less large bodies:** a split String/Bytes body is its payload only; tag and length
   come from the owning header, GC state from the LOS.
4. **Full 64 KiB chunks:** a 64 KiB eco/system stream chunk occupies exactly 64 KiB of LOS,
   page-aligned, and freed chunk space is reused; `LargeBytesChurnTest` passes its RSS bound
   natively; producers keep `kChunk` = 64 KiB.
5. No regression of the Stage 7 self-compile beyond +2 % wall / +3 % RSS (medians of 3).

Non-goals (each a possible follow-up, recorded in §10 when relevant):
- Retiring bag pages / mixed blocks / demotion for SMALL objects ("uniform-only ordinary space").
  After this plan they hold only objects <= 8 KiB; whether to delete them is a separate, measured
  decision (it touches M8's model of rungs 2/4/7 and the config keys of every heap-config JSON).
- Deleting the inert budget keys (`HeapConfigJson` rejects unknown keys: removal breaks the
  benchmark configs that set them).
- Discarding free space inside a partly used LOS block (only whole free blocks are released).
- Moving/compacting LOS objects; zero-copy file reads into bodies (pool jobs may not hold heap
  references, HEAP_007 / PoolResult G1).

## 3. Design

### D1. O7 (done)

`takeFreeAt` accounts the whole extent, then hands the tail back with
`releaseOldGenBlock(block + size, block_size - size)` (thread_mutex_ is recursive). PageWork sees
reuse-then-release, two actions it already models. All callers request OS-page multiples (asserted).

### D2. LOS blocks: the LOS is made of ordinary 512 KiB blocks of a new kind

v1 put the LOS in a fixed sub-range of the reservation; the review (§12 R1) showed that creates a
second hard wall below measured old-gen peaks, collides with the 128 MiB commit-ahead window
(`MAP_FIXED` would zero LOS pages), and is invisible to every `contains()` / `blockIdFor` gate
(silent use-after-free). v2 instead builds the LOS from blocks:

- An **LOS block** is acquired exactly like a bag page (`acquireOldGenBlock(alloc_buffer_size)`,
  region bounds + page index + `materializeBlock`), so the page index (HEAP_049), mark arena slot
  (HEAP_050: one bit per 8 B, the same bitmap as a mixed block), region span (`contains`,
  `getCommittedBytes`), Occupancy/GarbageFraction denominators, `old_gen_in_use_bytes_`, the
  P1 census's `markedNow`, `snapshotYoungLarge`, IM4/IM8 and HEAP_051 live attribution all keep
  working unchanged.
- `BlockInfo` gets one byte (it fits the existing padding; `sizeof(BlockInfo)` stays 40):
  `uint8_t los` with flags `kLosBlock = 1` (an LOS block of `alloc_buffer_size`) and
  `kLosRaw = 2` (it holds header-less bodies, D4). `size_class = NUM_SIZE_CLASSES`, `is_large =
  false` for LOS blocks.
- Objects larger than one LOS block keep today's dedicated `is_large` blocks (the "huge tier",
  page-rounded, `free_large_blocks_`): they already hold exactly one large object each and are
  never used by ordinary allocation, so they are part of the LOS. A huge block holding a
  header-less body also gets `los = kLosRaw`.
- Two LOS block pools: **raw** (header-less bodies only) and **object** (headered YLOS, pinned
  pointer-free, promoted-in-place YLOS, permanent fallback). A block's kind is fixed when it is
  materialized; a background marker reads it from `BlockInfo` (published before the page-index
  owner, HEAP_065) to decide "set the bit, do not push" (raw) vs the normal grey/scan (object).

**Free space inside an LOS block.** `LargeObjectSpace` (new class, owned by `OldGenSpace`,
mutator-thread only) keeps for every LOS block, indexed by `BlockId` in a `ReservedArray`
(fixed addresses):
```
struct LosBlockMeta {           // 512 granules of 1 KiB per 512 KiB block
    uint64_t used[8];           // 1 = granule allocated
    uint16_t largest_free;      // largest free run, in granules (cache)
    uint16_t used_granules;
    uint32_t bin_prev, bin_next; // intrusive list of blocks in largest-free bin (BlockId.v)
    uint8_t  bin;               // 0xFF = not binned
    uint8_t  raw;               // pool: 1 raw, 0 object
};
```
- **Granule** = 1 KiB (`kLosGranule`); an object of `n` bytes takes `ceil(n / 1 KiB)` granules
  (8 KiB+8 B: 9 granules, 11 % waste; 64 KiB header-less: 64 granules, 0 waste).
- **Allocation** (`allocate(bytes, raw)`): bins by `largest_free` (11 bins: 1, 2, 3–4, 5–8, …,
  257–512 granules); take the first block in the smallest bin whose lower bound >= need (fall back
  to scanning the bin that may contain it); in that block choose the **best-fit** free run by a
  bitmap scan (512 bits); a request whose size is a multiple of `OS_PAGE_SIZE` places its run on
  a page boundary when possible (alignment = page / granule). If no block fits, acquire a new LOS
  block; if that fails, return nullptr (callers run the D4 recovery of
  `large-body-gc-trigger.md`).
- **Free** clears the bits: coalescing is implicit in the bitmap. Recompute `largest_free`
  (512-bit scan), rebin. A block whose `used_granules` drops to 0 stays empty-binned; empty LOS
  blocks beyond `los_empty_keep` (default 2) are released at the next post-mark tail through the
  existing `releaseBlockToAllocator` (whole-block PageWork discard; no sub-block discard).
- Every op is O(512 bits) — a few hundred ns, on allocations of >= 8 KiB.

**Tracking.** Every LOS object (any tier) has an entry in today's `large_bodies_` /
`large_body_index_` / `free_large_body_ids_` (the review's recommendation: reuse, do not replace,
the bookkeeping that minor GC, region mode, tenure and the TLA models already describe).
`LargeBodyMeta.kind` gains values:

| kind | object | minor GC | major GC |
|---|---|---|---|
| 0 Body | split String/Bytes body | today's seen-colour sweep (nursery-owned) | mark bit (raw: no push) |
| 1 Ylos | young pointer-bearing large object | today's `reachYoungLarge` | marked + scanned |
| 2 Old (new) | pinned pointer-free, promoted-in-place YLOS, permanent fallback | never | marked + scanned (headered) |

`promoteYoungLarge` today erases the index entry; it now re-kinds the entry to 2 (still under
`ylos_mu_` for workers) and removes it from `nursery_owned_bodies_` exactly as before. Kind 2
entries are never nursery-owned. The CR-037 guard in `markLargeBodySeen` (`kind == 0 &&
body_base == body`) and `youngLargeMeta`/`youngLargeMember` (kind 1) are unchanged.

**Major GC.**
- Marking: unchanged for object blocks (bitmap bit at the object start, then scan). For raw
  blocks and raw huge blocks, `greyObject` sets the bit and returns without pushing (no header is
  read; no ticket). `scanObject` asserts it never sees a raw block (validate builds).
- Live bytes: markers attribute object-block bytes as today. Raw bodies' bytes are added at the
  post-mark tail by `retireDeadLargeBodies` (mutator thread): for every tracked LOS entry that is
  marked, add its granule bytes to its block's `live_bytes` before `finalizeMetaAfterMark`
  (implementation: `retireDeadLargeBodies` runs inside `classifyBlocksAfterMark`, before the
  per-block loop — verify the order against `finalizeMetaAfterMark` and move the raw-live
  attribution there if it runs earlier).
- Freeing: `retireDeadLargeBodies` (post-mark tail, `cycleActive()` false) frees the memory of
  every unmarked tracked LOS-block entry through `LargeObjectSpace::free` and retires the index
  entry (`retireIndexEntry`; body_base = nullptr; a nursery-owned id is dropped by the next minor
  sweep, the existing CR-035 protocol). Huge-tier entries keep today's `classifyBlocksAfterMark`
  `is_large` arm (which must not read the header of a raw huge block: test `los & kLosRaw` first).
- LOS blocks are excluded from: lazy sweep and gap sweep (`fully_swept = true` always),
  `partial_`/cursors/demotion/mixed free lists, compaction candidate selection, the empty-block
  flip (`allocateFromEmptyRegularBlocks`), `maybeShrinkCapacity`'s per-block release (LOS blocks
  are released only by the LOS empty-keep rule), V11/V12 header parses of mixed blocks.
  Implementation step: audit every loop over `blocks_` (grep `blocks_.size()` / `idAt(` /
  `size_class` comparisons) and add the LOS arm; list the sites in §10.
- Mid-cycle allocation (HEAP_063): an LOS object allocated while a cycle is active is allocated
  black (mark bit set, bytes added to the block's `live_bytes` and `cycle_black_bytes_` like a
  black bag carve; IM4 `noteCycleAllocation` passes because the block is a block).
- Frees during a cycle stay deferred (`deferred_frees_` → `processDeferredFrees`), including
  objects allocated after t0. **Consequence:** LOS reuse pauses for a cycle's 33 minors; tests
  that assert flat LOS use must tolerate one cycle's allocation (§5).

**Accounting.** `LargeObjectSpace::allocate` adds the granule bytes to the block's `live_bytes`,
`allocated_bytes`, `old_alloc_total_` (P-hat), `frag_stats_.live_bytes`; `free` subtracts the
same quantity (fixes the v1 P3 drift for LOS). HEAP_079's `noteDirectAlloc` counts the same bytes.

### D3. What allocates where after the change

| Request | Before | After |
|---|---|---|
| split body (String/Bytes >= LOT) | `allocateLargeBody` → `allocate()` (bag/large) | LOS raw (<= 512 KiB) / huge raw |
| YLOS (`allocateYoungLarge`) | `allocate()` | LOS object / huge |
| pinned pointer-free (`allocateLargePinned`) | `allocate()` | LOS object / huge, tracked kind 2 |
| permanent fallback (`allocatePermanent`, size >= LOT) | `allocate()` | LOS object / huge, tracked kind 2 |
| legacy nursery placement of pointer objects (`placeLargeFor` → Nursery, up to 128 KiB) | promoted via bag page | **capped at `largestClassBytes()` in both nursery modes** (region mode already is): larger ones go YLOS |
| everything else (<= 8 KiB) | size classes, ladder | unchanged |

After this, `OldGenSpace::allocate()` path 2/4 are reachable only from the huge tier's own entry
and the small-class ladder's rung 7; assert in validate builds that `allocate()` never receives
`size > largestClassBytes()` from any other caller.

### D4. Header-less large bodies

- The body `HPointer` addresses the first payload byte; there is no `Header` in front.
  `allocLargeString(chars, n)` allocates `n * 2` bytes, `allocLargeByteBuffer(data, n)` `n` bytes,
  both from the raw pool (huge raw above 512 KiB).
- **Never `resolve()` a body.** `Allocator::resolve`/`resolveFast` read the target's tag to
  follow `Tag_Forward`; on a payload the low 5 bits of the first byte would be taken as a tag
  (`Tag_Forward` = 26: any large String starting with 'Z', 'z' or ':' and ~1/32 of Bytes would be
  "forwarded"). Bodies are pinned and never forwarded: read them with `fromPointerRaw`.
- **Accessors** (HeapHelpers.hpp; Phase 2 introduces them with no behaviour change):
  - `void* largeBodyRaw(const void* largeHeader)` — the ONLY reader of `->body` for payload:
    `fromPointerRaw(h->body)`.
  - `u8* largeBytesPayload(const LargeByteHeader*)`, `u16* largeStringPayload(const
    LargeStringHeader*)` — `largeBodyRaw(h) + kLargeBodyPayloadOffset` (`sizeof(Header)` before
    Phase 5, 0 after).
  - `U16Span stringPayload(void* obj)` → `{const u16* data; u32 len}` for `Tag_String` and
    `Tag_LargeStringHeader` (length always from the OUTER header); replaces `stringData`,
    `resolveStringBody` and the inline large-string branches in StringOps.
  - `ByteBufferView byteBufferView(void*)` keeps its name; its large branch takes the length
    from the outer header and the data from `largeBytesPayload`.
  Every one of the ~22 runtime payload readers (HeapHelpers 7, StringOps.hpp 13, StringOps.cpp 2,
  BytesOps.cpp 1) and the 3 kernel readers (BytesExports.cpp:231, :328, ParserExports.cpp:77)
  uses these. A grep gate (`test/scripts/check-large-body-access.sh`, added to `check`/`full`)
  fails on `->body` / `.body` of a large header, or `resolve*(…body)`, outside
  `HeapHelpers.hpp` (accessors), the allocator GC files, and `ThreadLocalHeap.cpp` (allocation).
- **GC paths** that today treat a body as an object:
  - `markChildren`'s `greyH(h->body)`: routed to the raw arm of `greyObject` (D2).
  - `HeapChildWalk::visitHeapChildren` keeps visiting `->body`; every visitor that then inspects
    the child as an object must check `isLargeBodyAddress` first: PermanentSpace
    (`PermanentSpace.cpp:144-190`: copy the payload by the outer header's length into a
    header-less permanent extent), the IM1/IM2 tracer (`ThreadLocalHeap.cpp` ~1524) and IM11
    (`OldGenSpace.cpp` ~4078).
  - Compaction (test-only): `fixHPointer(h->body)` and evacuation pin checks must skip LOS
    blocks (they are never evacuated); `fixReferencesSlice` must walk object-LOS entries via
    `large_bodies_` (kind 1/2) so their slots are fixed.
- The body `header.size` duplicate (HEAP_026) disappears; HEAP_026 is amended.

### D5. Full 64 KiB chunks

With D2 + D4 a 64 KiB chunk is 64 granules, page-aligned, reused exactly. No producer change.

## 4. Files

| File | Change |
|---|---|
| `Allocator.cpp` | D1 (done) |
| `BlockTable.hpp` | `BlockInfo::los` + flags |
| new `LargeObjectSpace.{hpp,cpp}` | D2 allocator (+ added to the hand-written source lists: top `CMakeLists.txt` `ecor`, `runtime/src/codegen/CMakeLists.txt` ×3; reconfigure for the GLOBs) |
| `OldGenSpace.{hpp,cpp}` | owns `LargeObjectSpace`; `allocateLargeBody`/`allocateYoungLarge`/`registerLargeBody` route; `freeLargeBodyCell` LOS arm; `retireDeadLargeBodies` frees + raw live; `greyObject`/`scanObject` raw arm; block-loop exclusions; huge-tier raw; accounting |
| `ThreadLocalHeap.{hpp,cpp}` | `allocateLargePinned`/`allocatePermanent` → LOS; `allocLarge*` header-less; `placeLargeFor` cap |
| `HeapHelpers.hpp`, `StringOps.{hpp,cpp}`, `BytesOps.cpp`, `RuntimeExports.cpp` | accessors |
| `elm-kernel-cpp/src/bytes/BytesExports.cpp`, `parser/ParserExports.cpp` | accessors (license re-audit) |
| `PermanentSpace.cpp`, `ThreadLocalHeap.cpp` tracer | header-less arms |
| `GCStats.{hpp,cpp}` | "LOS" block: blocks raw/object, granules used, allocs, frees, failed fits, empty releases |
| `AllocatorCommon.hpp`, `HeapConfigJson.cpp` | `los_empty_keep` (default 2) |

## 5. Tests

- **O7** (done): `OldGenCapacityTest` "O7: a reused larger extent is split…" (red before D1).
- **LOS unit suite** `test/allocator/LargeObjectSpaceTest.cpp` (isolated suite `LOS`): alloc/free
  /coalesce (both neighbours), best fit, page alignment of page-multiple sizes, block release at
  the empty-keep limit, random churn vs a shadow model (bitmaps, bins, `largest_free` agree after
  every op), raw/object pools never share a block.
- **Placement:** after Phase 4, every tracked entry's block has `los` set; no `los` block holds an
  untracked object; `allocate()` never sees `size > largestClassBytes()` (validate assert).
- **Header-less (Phase 5):** a large String whose first char is 'Z' (0x5A, low 5 bits 26 =
  `Tag_Forward`) and a Bytes starting with 0x1A survive minors and majors with exact contents
  (the forwarding-hazard regression); `String.slice`/`toUpper`/`Bytes.Decode` over large values.
- **D5:** `LargeBytesChurnTest` passes natively; new `LargeBytesReuseTest`: 1 GiB of 64 KiB
  chunks with LOS blocks bounded (allowing one mark cycle's deferral: bound = 2 × the blocks in
  use after warm-up + 64 MiB).
- Rewritten existing tests (§12 R5 inventory): split-header layout tests read the body through
  accessors; `testLarge*` and IncrementalMark placement assertions now expect LOS blocks; CR
  register guards and gc-heap-tsan arms whose scenarios put bodies/YLOS in bag pages are
  re-targeted to small objects in bag pages where the CR is about bag pages, or get a recorded
  "mechanism retired for this object kind" verdict in `plans/threaded-gc-concurrency-register.md`.

## 6. Phases

Every phase ends green: `full`, `stress`, the validate tree (`ECO_NURSERY_POISON=1
ECO_HEAP_CONFIG=benchmarks/heap-config-gc-pressure.json`, filters for the touched suites, both
nursery modes), `register-guards`, and `sh test/scripts/check-tla-manifest.sh .` (with audits).

**Phase 0 – baselines.** Self-compile A/B baseline: `heap-profiles/ws-dev-01/2026-10-08T18-06-26Z__
large-body-ab` `budget_1` (wall 73.20 s, RSS 6.524 GB, 1313/7, GC 3.05 s), same compiler MLIR
pinned in Phase 6 (`eco-compiler-ab.mlir`). `LargeBytesChurnTest`: 16,387 MB in use, +7 GB RSS.

**Phase 1 – O7 (done 2026-10-09).** Remaining: AUDIT.md entries for `AL.acquireOldGenBlock`
(M6, M7, M8): verdict "no model change: the split is a reuse followed by an ordinary release, two
existing actions" (check each model's MAPPING for the acquire/release actions first).

**Phase 2 – accessors, no behaviour change.** D4 accessors; convert every reader; kernel license
re-audit for BytesExports/ParserExports rows; grep gate. Self-compile output byte-identical
(`out_md5` equal).

**Phase 3 – `LargeObjectSpace`, unwired.** Class + unit suite. `BlockInfo::los`. Block-loop
exclusion audit (code paths ready, no LOS blocks exist yet).

**Phase 4 – route every large allocation to the LOS (headers kept).** D3 table; kind 2;
`retireDeadLargeBodies` frees LOS memory; raw arm in `greyObject` NOT yet (bodies still have
headers, `kLosRaw` unused); accounting; `placeLargeFor` cap; rewrite placement-dependent tests;
TLA audits for every touched region (list in §7). `LargeBytesChurnTest` should already pass
(65 granules, exact reuse).

**Phase 5 – header-less bodies.** `kLosRaw` pools; `kLargeBodyPayloadOffset` = 0; raw arm in
`greyObject`; raw-live at the tail; PermanentSpace/tracers/compaction arms; forwarding-hazard
tests; HEAP_026 amended.

**Phase 6 – workloads and A/B.** `LargeBytesReuseTest`; stress `-n 100` (EcoSystemTransformChain);
Autobahn native `--no-split` **only with >= 10 GB free** (stop and record if VmHWM passes 4 GB);
self-compile A/B vs Phase 0 with the pinned MLIR.

**Phase 7 – documentation and closure.** Invariants (§8), R7 in
`plans/eco-system-websockets.md`, `autobahn.sh` header if `--no-split` passes, `large-body-gc-
trigger.md` §10 cross-reference, memory.

## 7. TLA+ impact (GC_MODEL_001)

Regions this plan edits (manifest models in brackets) — each needs an AUDIT.md verdict:
`AL.acquireOldGenBlock` [M6 M7 M8] (Phase 1); `OGS.registerLargeBody` [M3 M5 M8],
`OGS.freeLargeBodyCell` [M1 M8], `OGS.sweepNurseryLargeBodies` [M1 M5 M8],
`OGS.retireDeadLargeBodies` [M1 M5 M8], `OGS.classifyBlocksAfterMark` [M1 M8],
`OGS.promoteYoungLarge` [M1 M3 M5 M8], `OGS.greyObject` [M1 M5] (Phase 5),
`OGS.lazySweep` [M4 M7 M8 W3] if its block filter changes, `OGS.maybeShrinkCapacity` [M4 M8],
`OGS.releaseBlockToAllocator` [M1 M5 M7 M8], `OGH.LargeBodyMeta` [M5 M8], whole-file pin
`BlockTable.hpp` [M8], census pins `OldGenSpace.cpp/.hpp` if an atomic line moves. Any new file
with a concurrency line needs a census pin (`LargeObjectSpace.cpp` is mutator-only: no atomics,
so none). Expected verdicts: the models abstract "a large body/YLOS cell in an old-gen block";
an LOS block is an old-gen block with its own free-space policy, so M1/M3/M5 need no change;
M8 BlockLifecycle needs a note (or an action) that LOS blocks are never on free lists, never
swept, never flipped — decide by reading its spec in Phase 4.

## 8. Invariants

- New **HEAP_080 LargeObjectSpace**: placement rule (D3), LOS blocks (`BlockInfo::los`), raw vs
  object pools, granule bitmap free space with implicit coalescing, tracking of every LOS object
  in `large_bodies_` (kinds 0/1/2), freeing at the post-mark tail and (nursery-owned) at minors,
  frees deferred during a cycle, whole-block release beyond `los_empty_keep`.
- New **HEAP_081 HeaderlessLargeBody**: the body is payload only; never resolved (raw); length
  and tag from its header; raw blocks are marked without a push.
- Amend HEAP_023 (the bag band no longer receives large objects), HEAP_024, HEAP_026 (body has no
  header; length only in the header), HEAP_036 (PermanentSpace copy of large values), HEAP_062
  (YLOS live in LOS object blocks; promote = re-kind), HEAP_073, HEAP_079 (LOS bytes).

## 9. Decisions (change them here if you disagree)

1. O7 as split-on-reuse (done).
2. **LOS = blocks of a new kind** (not a fixed address sub-range): §12 R1.
3. LOS block = `alloc_buffer_size` (512 KiB); larger objects use the existing huge tier.
4. Granule 1 KiB; per-block 512-bit bitmap; bins by largest free run; best fit within a block;
   page alignment for page-multiple sizes.
5. Reuse `large_bodies_` as the LOS metadata (kind 2 added) instead of a new `los_meta_`.
6. Separate raw and object pools (a marker needs the kind from `BlockInfo` alone).
7. Legacy-mode nursery placement capped at the largest uniform class.
8. Uniform-only ordinary space and budget-key deletion are out of scope (§2).

## 10. Progress log

**2026-10-09 – Phase 1 (O7).** `takeFreeAt` splits (Allocator.cpp): the tail goes back through
`releaseOldGenBlock`. Test `testReusedExtentTailIsReleased` red before (in-use rose by 4 pages for a
2-page request), green after. The tail release never waits (populates are posted only above the bump,
which never moves back; any populate over a free extent was awaited at its release): a validate-build
assertion (`release_waits` unchanged) guards it.

**Phase 2 (accessors).** `Heap.hpp`: `largeBodyAddr`, `largeStringChars`, `largeBytesData`,
`flatStringChars` (raw: `hpToAddr`, never `resolve`); `HeapHelpers.hpp`: `alloc::flatStringView` (`U16View`)
and `alloc::flatBytesView` replace `resolveStringBody` / `resolveByteBufferBody`; every reader in
HeapHelpers / StringOps / BytesOps converted (13 StringOps.hpp sites, 2 StringOps.cpp, 7 HeapHelpers,
1 BytesOps). Kernel files `BytesExports.cpp` (231, 328) and `ParserExports.cpp` (77) use `flatStringView`;
the 32 licensed rows (25 Bytes, 7 Parser) were re-audited (`audited: 2026-10-09`, evidence: a runtime-API
read of String units, no function-capable position, citations unchanged) and the manifest updated. Gate
`test/scripts/check-large-body-access.sh` (in `check`/`full`; negative control on a scratch tree fires
both rules). Gates: `full` 2,358/2,359 (the then-known LargeBytesChurnTest), JS 162/162. The planned
"self-compile output byte-identical" check was NOT applicable: the self-compile compiles the compiler's own
sources, which changed (the 2026-10-09 08:29 sync and the license evidence strings), so its hash moved.

**Phase 3/4 (LOS, routing).** `LargeObjectSpace.{hpp,cpp}` (+ 4 hand-written source lists); `BlockInfo::los`
(fits the padding, still 40 B); `OldGenSpace`: `addLosBlock`, `allocateLos`, `allocateTrackedCell` routes
<= one block to the LOS object pool, `allocateOldLarge` (kind 2), `freeLosCell`, `losSweepAtMarkEnd`
(in `finalizeMetaAfterMark`), `losReleaseEmptyBlocks` (after the reclaim; floor-respecting), kind 2
(`registerLargeBody(owned=false)`, `retireIndexEntry` recycles its id, `promoteYoungLarge` re-kinds, the
minor sweep never frees a kind-2 entry). Block-loop audit (37 loops): LOS arms in
`prepareMetaForLazySweep` / `resetBufferMetaForMark` (fully_swept stays true), `classifyBlocksAfterMark`,
the flip, the reclaim, shrink pass 1, `selectEvacuationSet`, compaction fix-up (walks LOS objects through
the index), the old->nursery validator walk; the rest are stats or skip non-uniform blocks already. Config
`los_empty_keep` (default 2). `placeLarge` caps nursery placement at `largestUniformClassBytes()`.
Tests: LOS unit suite (6) + placement + 1 GiB 64 KiB churn (21 blocks with headers, 2 header-less).
Retargeted: OldGenCapacity (floor bug found and fixed in `losReleaseEmptyBlocks`), LargePtrPlacement
(8 KiB arrays at the cap), WideObject (YLOS above the cap), OldGenBitmapAlloc (two LOS tests replace the
uniform/mixed body-free tests; the old mixed one had become vacuous), CR-018/CR-035 guards report
"route RETIRED" (register verdicts written), CR-039 detects an LOS free by the granule bitmap.
**Bug found by running LargeBodyChurn (b) alone (2026-10-09):** `promoteLargeHeader` erased the body's
index entry, so a promoted body in the LOS was never freed (OOM at the 32 MiB cap). Fixed (re-kind to 2);
validator `validateLosTracking` (HEAP_080) added at mark end, with a negative control (the old erase
restored: "[heap-validate] HEAP_080 ... LOS block 0 has 62464 used bytes but its tracked objects cover 0").
`LargeBytesChurnTest` passes natively from Phase 4 on (RSS growth 131 MB with headered bodies).

**Phase 5 (header-less bodies).** `kLargeBodyPayloadOffset = 0`; `allocLargeString/ByteBuffer` allocate the
payload only; `allocateRawCell` (raw pool / raw huge block, `attributeNewCell` = allocate-black without a
header); `greyObject` raw arm (mark, no push); `scanObject` validate abort; raw huge blocks: classify and
the legacy sweep arm no longer read a header, live bytes set at mark end; compaction never fixes a body
pointer; IM11 and the IM1/IM2 tracer skip raw bodies; PermanentSpace declines large values. Tests: the
forwarding-hazard test ('Z'/'z' String, 0x1A Bytes) and the exact 64 KiB test (64 granules, page-aligned,
reused at the same address); split-layout tests read through the accessors and check `isRawBody`.
CR-017 R1 / CR-037 report "route RETIRED" (a YLOS never reuses a body's cell: separate pools); CR-019's
fork arms are `retired` (new `run_fork_arms.py` expectation). IM11 first counted raw bodies in the closure
(validate abort, fixed: the skip precedes the closure insert).
Gates (Phase 5): `full` 2,369/2,369, JS 162/162 (3 skips), AOT eco- 179/179, validate stress 114/114,
validate LOS 12/12 and LargeBodyChurn 5/5 in both nursery modes; `stress` 113/114 (the known
EcoSystemFileManySmall sizing timeout, unrelated). Deviation: the planned Elm `LargeBytesReuseTest` is the
C++ `testLosChunkChurnReusesBlocks` (1 GiB of 64 KiB chunks: allocs - frees <= 8 per remaining block).

**Phase 6 (workloads).**
- Stage 7 self-compile, pinned compiler MLIR, 3 runs (`heap-profiles/ws-dev-01/*__los-ab`): wall
  **71.85 s**, CPU 101.10 s, RSS **5.638 GB**, minors/majors 1313/8, GC 2.81 s, output `f0c3b977`. Same-input
  baseline = the Phase 2 single run (73.06 s, 6.517 GB, same output hash); the Phase 0 cell (73.20 s,
  6.524 GB, GC 3.05 s) compiled older sources. Wall -1.7 %, RSS -13.5 %: inside the acceptance bound.
  LOS in that run: 30,731 allocs, 535.46 MB granule bytes for 519.42 MB of objects (3.1 % rounding waste;
  K3's 11 % was the worst case), 208 LOS blocks added, 23 released, 185 at exit (86 MB used).
- `LargeBytesChurnTest` native: RSS growth 117,052 KiB for 2 GiB of 64 KiB chunks (was ~7 GB).
- Native Autobahn `--mode both --backend native --no-split` (one process per run, VmHWM guard at 4 GB never
  fired): no crash; server 517 cases (507 OK, 7 NON-STRICT, 3 INFORMATIONAL), takeover 216/216 OK, client
  517 (505 OK, 9 NON-STRICT, 3 INFORMATIONAL); peak RSS **ws-echo-server 466 MB, ws-autobahn-client
  464 MB** (before: the server reached 11.6 GB and was killed). `autobahn.sh` header updated.
- `WebSocketEchoTest` "big echoed intact: False" under the validate tree + gc-pressure, legacy nursery,
  full eco-system suite: seen in 2 of the first 3 such runs after Phase 5, then 0 of the next 5 (one plain,
  four instrumented with a word-level diff that never fired); never in isolation (39/39 under 4x parallel
  load), never in region mode, never in release builds. **Cause not found; open.** A defensive fix was made
  on the way: a reused free large block clears `los` (a freed raw huge block could otherwise be reused
  headered with `kLosRaw` still set) - no path to that reuse exists today, so it is not claimed as the cause.

**TLA+ (§7).** M8 updated (constants `LOS`/`LosKeep`, LOS actions, `LosTracked`, `LosSeparation`, rows
`MC_quick_los{,_page}.cfg`, mutant `los_promote_untracks`); audits written for M1–M8, W3/W4 (see each
AUDIT.md, 2026-10-09). F.vnodeRegistry (the sync's deletion of VirtualDom.cpp) audited in M1.

## 11. Risks

| # | Risk | Mitigation |
|---|---|---|
| K1 | A missed block loop treats an LOS block as mixed (sweeps it, flips it, demotes it) | Phase 3 loop audit with the site list in §10; validate-build abort when a sweep/flip/demote/cursor touches `los != 0` |
| K2 | A missed raw-body reader reads payload as a header | Phase 2 grep gate; forwarding-hazard tests; validate poison of freed granules (0xD8) |
| K3 | 8–16 KiB bodies waste up to 11 % (1 KiB granule) | measured in Phase 6 ("LOS" stats: granule bytes vs object bytes) |
| K4 | Fragmentation inside LOS blocks for mixed sizes (blocks never fully empty) | best fit; stats; a sub-block discard is a follow-up |
| K5 | ABA on reused body addresses in region mode (`lb_bodies` by address, HEAP_072) | existing CR-037 guards (kind 0 + exact base); reuse makes it more frequent, the consequence stays floating garbage for <= k minors; recorded in Phase 6 stats |
| K6 | 33-minor free deferral during a cycle | test bounds allow one cycle; documented in HEAP_080 |
| K7 | Kernel license manifest blocks the build on BytesExports/ParserExports edits | re-audit per `kernel-parametricity-license.md` §2 in Phase 2 |
| K8 | Register guards / tsan arms lose their scenarios | §5 retarget or recorded verdicts |

## 12. Review log (v1 → v2, 2026-10-09)

Five read-only investigations (body lifecycle, YLOS/pinned/huge, body readers, address space and
concurrency, tests/TLA/infra). Findings that changed the plan:

| # | v1 said | Finding | v2 |
|---|---|---|---|
| R1 | LOS = top half of the old-gen reservation | second hard wall below measured 9.7–16 GB peaks; commit-ahead `MAP_FIXED` would zero LOS pages; `contains()`/`blockIdFor` gates silently skip LOS addresses (unmarked → freed live); multi-heap/fork ownership unclear | LOS = blocks of a new kind (D2) |
| R2 | free coalescing through PageWork discards | PageWork tracks extents by exact base; discarding inside a coalesced run could DONTNEED live data | whole-block release only |
| R3 | new `los_meta_` replaces `large_bodies_` | minor, region (`lb_bodies`), tenure (traps 14/15), YLOS (`join_minor`, HEAP_072), CR-035/037 all live on `large_bodies_` | keep it; add kind 2 |
| R4 | body readers ≈32 `->body` casts | all body reads go through `resolve`, which reads a tag: header-less payload hits `Tag_Forward` (~1/32 of Bytes, Strings starting 'Z'/'z'/':'); plus length readers via helpers, PermanentSpace copy, IM1/IM2/IM11 tracers, compaction fix-up | raw reads; accessor set; arms for each (D4) |
| R5 | test impact unstated | ~30 test cases (OldGenCapacity, AllocatorTest split tests, IncrementalMark placement, CR-014/016/017/018/019/029/033/035/036/037 guards, gc-heap-tsan ylos_sweep/promo_sweep/cr012) assume bodies/YLOS in bag pages or large blocks | §5 retarget/verdicts |
| R6 | "nothing existing at t0 is freed under a cycle" | ALL body/YLOS frees are deferred during a cycle (33 minors) | D2 + K6 |
| R7 | placement table: `allocatePromotion` large branch | that branch is dead at defaults; live paths are legacy bag-page promotion of (8, 128] KiB nursery objects; `allocatePermanent` missing; region mode already caps at 8 KiB | D3: cap legacy placement; permanent → LOS |
| R8 | accounting "one cap" | `getOldGenMaxBytes` is the cap; triggers use `old_gen_in_use_bytes_` and `getCommittedBytes()` (region span) — blocks keep both correct | D2 |
| R9 | LOS mutated only by the mutator | true once legacy large promotion is removed (D3) and YLOS promotion only re-kinds under `ylos_mu_` | D2/D3 |
| R10 | TLA list | missing M3/M5 regions (`registerLargeBody`, `markLargeBodySeen`, `youngLargeMeta`, `greyObject`, `snapshotYoungLarge`) | §7 |
| R11 | kernel files freely editable | `kernel-license-check` (in ALL) hashes BytesExports/ParserExports/Utils | Phase 2 re-audit |

## 13. Follow-ups (not part of this plan)

**F1. Make every large String header-less: route unsplit large `Tag_String` cells to the split form.**
(Raised 2026-10-09, after Phase 5.)

- *Today.* Header-less bodies (D4, HEAP_081) cover only split String/Bytes bodies. Some pointer-free large
  cells still keep a header and live in the LOS object pool as kind-2 pinned objects
  (`allocateLargePinned` → `allocateOldLarge`). These are mainly large **unsplit** `Tag_String` cells, which
  come from (line numbers approximate, not re-verified):
  - `StringOps` concat/join (`StringOps.cpp` ~634, ~748);
  - `eco_alloc_string` and `eco_alloc_string_slow` (`RuntimeExports.cpp` ~639, ~1719).

  Int, Float and Char cells are never large.
- *Change.* Have those paths build a `LargeStringHeader` with a header-less body, as
  `alloc::allocStringBlank` already does at or above `large_object_threshold`.
- *Benefits.*
  - Every large String and Bytes becomes header-less, so there is one representation for large strings.
  - Their bodies get exact sizes in the raw pool.
  - The "pinned pointer-free" category of D3 essentially disappears. The object pool would then hold
    pointer-bearing objects (YLOS, promoted YLOS) and the rare permanent fallback.
- *Risk to check first.* Does any caller, especially compiled code calling `eco_alloc_string`, write
  characters into the returned object at `+8` (an `ElmString` with inline `chars`)? Every such writer must
  move to the split pattern: a blank split string, characters written through `largeStringChars`. Audit:
  - `EcoBackend` / the codegen lowering of string construction;
  - the kernels' `eco_alloc_string*` callers;
  - `StringOps`' concat/join fill loops;
  - any `sizeof(ElmString)` arithmetic on a returned pointer.
- *Not in scope.* Pointer-bearing large objects (YLOS: arrays, wide records and custom types) and the
  permanent fallback keep their headers:
  - every holder of an ordinary pointer reads the header (compiled-code tag tests and field access, the
    kernels, the GC scan's size, tag and tail kind words);
  - removing it means an indirection on every large-array access;
  - the gain is about 0.01 % of a 64 KiB object, below the LOS's 1 KiB granule rounding.
- *Gates.* As Phase 5: `full`, `stress`, the validate tree in both nursery modes, AOT `eco-`, the
  self-compile A/B, the large-body access gate (extended to `ElmString` chars writes on
  `eco_alloc_string*` results), and the TLA canary audits for any pinned region touched.
