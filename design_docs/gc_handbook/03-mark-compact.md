# 3. Mark-Compact (Deep Summary with Pseudocode)

Mark-compact collectors eliminate fragmentation by relocating live objects after marking. This summary dives into the main compaction styles (two-finger, sliding, Lisp2/threaded, one-pass), practical engineering issues (forwarding metadata, object parsing, large/pinned objects), and incremental/parallel variants. Lengthy by design for quick CLI reference.

---

## 3.1 Motivation and Shape

- **Mark-sweep problem**: fragmentation and poor locality from holes in the heap.
- **Mark-compact answer**: mark live objects, then move them to coalesce free space; update all pointers.
- **Trade-offs**: better locality and space efficiency, but higher pause time and need to patch references; requires either extra pass or copy reserve.

---

## 3.2 Core Sliding Collector (Two-Phase)

Phases:
1) **Mark**: same as mark-sweep (tri-colour).
2) **Compute destinations**: determine new addresses for live objects (e.g., prefix sums of sizes).
3) **Relocate**: move objects to new addresses; leave forwarding pointers at old locations.
4) **Update references**: fix all pointers to point to new locations.

### Pseudocode (Stop-the-World Sliding)

```pseudo
mark_compact(heap, roots):
  // Phase 1: Mark
  mark_phase(roots)

  // Phase 2: Compute forwarding (prefix sum)
  dest = heap.start
  cursor = heap.start
  while cursor < heap.end:
    hdr = header(cursor)
    sz = object_size(cursor)
    if is_marked(hdr):
      set_forward(hdr, dest)   // store forwarding address
      dest += sz
    cursor += sz
  new_top = dest

  // Phase 3: Relocate (copy live objects down)
  cursor = heap.start
  while cursor < heap.end:
    hdr = header(cursor)
    sz = object_size(cursor)
    if is_marked(hdr):
      dest_addr = get_forward(hdr)
      memcpy(dest_addr, cursor, sz)
      clear_mark(new_header(dest_addr))
    cursor += sz

  // Phase 4: Update references
  cursor = heap.start
  while cursor < new_top:
    fix_children(cursor)
    cursor += object_size(cursor)

  heap.top = new_top
```

Notes:
- `set_forward` may store forwarding addresses in headers, side tables, or in-place (repurpose mark bits).
- Updating references traverses all live objects; can be folded into relocation if you scan children as you copy.

---

## 3.3 Two-Finger Compaction (Edwards)

- Uses two pointers: `free` (bottom → up) to find holes; `scan` (top → down) to find live objects.
- Moves topmost live objects into bottom holes until pointers cross.
- Benefits: simple, one-pass relocation; no full prefix sum needed.
- Downsides: poor size matching when object sizes vary; arbitrary ordering harms locality.

**Pseudocode:**
```pseudo
free = heap.start
scan = heap.end
while free < scan:
  while free < scan and is_marked(free): free += size(free)
  while scan > free and !is_marked(prev_obj(scan)): scan -= size(prev_obj(scan))
  if free >= scan: break
  // move object at scan to free
  src = prev_obj(scan)
  sz = size(src)
  memcpy(free, src, sz)
  set_forward(src, free)
  free += sz
// after move phase, update references using forwarding addrs
update_refs(heap.start, free)
```

---

## 3.4 Sliding Compaction (Classic)

- Perform a linear pass computing compacted destinations using a running allocation pointer.
- Usually preserves original order (improves locality vs two-finger).
- Needs a scan to compute prefix sums; can fuse with marking using “mark+scanline” techniques.

**Pseudocode (prefix-sum based)**:
```pseudo
dest = heap.start
for each object in address order:
  if marked(obj):
    set_forward(obj, dest)
    dest += size(obj)

for each object in address order:
  if marked(obj):
    memcpy(get_forward(obj), obj, size(obj))
    clear_mark(new_header(get_forward(obj)))

for each object in new space [heap.start, dest):
  for each pointer field p:
    old = *p
    if is_heap_ptr(old):
      *p = get_forward(old)
heap.top = dest
```

---

## 3.5 Lisp2 / Threaded Compaction

- Stores threading info in object headers/fields to avoid separate forwarding storage.
- Moves objects and threads pointers through them, allowing single-pass updates.
- Useful when header space is limited; complex to implement correctly with variable-sized objects.

---

## 3.6 One-Pass Algorithms

- Combine relocation and reference fixup in one traversal to reduce passes.
- Example: **Cheney-style sliding**: as you copy an object, immediately fix its pointers to forwarded targets (requires those targets’ forwarding addresses to be known).
- Another: **Treadmill-like non-copying with threading**; less common.

---

## 3.7 Copy Reserve and Sliding With Less Space

- Pure copying needs 2× space; sliding compaction can run in-place with small auxiliary metadata.
- However, in-place sliding needs scratch to avoid overwriting yet-to-be-copied objects if destination overlaps source. Solutions:
  - Move downward only (dest ≤ src) to avoid overlap (common).
  - Use evacuation sets (region-based) where sources and destinations are disjoint blocks.

---

## 3.8 Object Relocation Metadata

- **Forwarding pointers**: usually stored in header (reuse mark/color bits) or overwrite first word (requires type to tolerate temporary corruption).
- **Mark bits**: side bitmap or header bits; compaction may repurpose mark bit to “has forwarding entry”.
- **Crossing maps**: optional; help locate object starts during reference updates if interior pointers exist.

---

## 3.9 Handling Large and Pinned Objects

- Large objects often excluded from compaction: place in separate “LOS” (large object space) with page-sized blocks and free-list management; mark-sweep or pin-only.
- Pinned objects (FFI, stacks, raw buffers) can sit in non-moving region; compactor skips them and may leave holes (partial fragmentation).

---

## 3.10 Parallel Compaction

- Partition heap into regions; assign to threads. Must coordinate source→dest mapping to avoid overlaps.
- Region-based evacuations (G1/Immix-style): choose sparse regions as sources, dense regions as destinations; parallel evacuate.
- After evacuation, rebuild remembered sets/card tables for moved objects; update references within regions in parallel.

---

## 3.11 Incremental Compaction

- Goal: break long pause of relocation.
- Strategies:
  - **Region-based partial compaction**: evacuate a subset of regions per cycle (Beltway/Immix/G1 style).
  - **Incremental sliding**: interleave small relocation steps with mutator; requires read barriers or load barriers to follow forwarding pointers while objects may be mid-move.
  - **Brooks pointer** or **indirection table**: extra level of indirection so pointers stay valid while object moves.
- Barriers: read barriers to resolve forwarding addresses during incremental move; write barriers to handle mutator stores into objects being moved.

---

## 3.12 Compaction Order and Locality

- **Address order** preserves spatial locality of allocation order; good cache behavior if allocation order matches access.
- **Object graph order** (e.g., BFS from roots) can cluster related objects; requires copying in graph traversal order.
- **Size-based packing**: group by size class to reduce fragmentation within compacted area.

---

## 3.13 Interaction with Generational GC

- Young gen often copying; old gen may be mark-compact (full heap) or partial compaction of old-gen regions.
- Cross-gen pointers: remembered sets/card tables must be updated when objects move.
- Promotion: moving into compacted old-gen may require free lists or region allocation for destinations.

---

## 3.14 Example Sliding Collector with Forwarding in Header

```pseudo
mark() // standard tri-colour

// Compute forwarding addresses
dest = heap.start
for obj in heap in address order:
  if marked(obj):
    header(obj).fwd = dest
    dest += size(obj)
  else:
    header(obj).fwd = null
new_top = dest

// Relocate + clear mark
for obj in heap in address order:
  if header(obj).fwd != null:
    to = header(obj).fwd
    memcpy(to, obj, size(obj))
    clear_mark(header(to))

// Fix references
cursor = heap.start
while cursor < new_top:
  for each pointer field p in cursor:
    old = *p
    if is_heap_ptr(old):
      *p = header(old).fwd
  cursor += size(cursor)

heap.top = new_top
```

---

## 3.15 Two-Finger (Edwards) Example

```pseudo
free = heap.start
scan = heap.end

while true:
  while free < scan and marked(free): free += size(free)
  repeat:
    prev = previous_object(scan)
    scan = prev
  until scan <= free or marked(scan)
  if free >= scan: break
  memcpy(free, scan, size(scan))
  set_forward(scan, free)
  free += size(scan)

update_refs(heap.start, free)
```

---

## 3.16 Handling Interior Pointers

- Need mapping from interior address to object start. Approaches:
  - **Crossing maps** per block (byte/word offset to last object start).
  - **Object table** keyed by page/block.
  - **Tagged pointers** disallowing interior references simplifies compaction.
- When updating references, interior pointers must adjust relative offset (ptr = base + delta → ptr’ = fwd(base) + delta).

---

## 3.17 Dealing with Concurrency

- **Stop-the-world compaction**: simplest; common in many VMs.
- **Concurrent/Incremental**: requires barriers + indirection; often only compacts selected regions to cap pause (e.g., CMS with “mark-sweep-compact” fallback).
- **Read barrier** resolves to-space location; self-healing pointers (Brooks pointer) avoids repeated barrier cost after first access.

---

## 3.18 Region-Based Hybrid (Immix/G1 style)

- Divide heap into regions (e.g., 1–4 MB). Track live bytes per region during mark.
- Choose sparse regions to evacuate; choose dense regions as destinations.
- Non-evacuated regions are swept in place (mark-sweep), giving partial compaction without full-heap pause.
- Remembered sets track inter-region pointers; must be updated on evacuation.

---

## 3.19 Pseudocode: Region Evacuation Sketch

```pseudo
// After marking, we have live_bytes per region
evac_sources = regions with occupancy < evacuate_threshold
dest_regions = regions with occupancy < dest_threshold and not sources

for src in evac_sources in parallel:
  for obj in src.live_objects:
    dst = alloc_in_dest(dest_regions, size(obj))
    memcpy(dst, obj, size(obj))
    set_forward(obj, dst)

// Fix references in evacuated objects
for each evacuated obj:
  for ptr in children(obj):
    if is_heap_ptr(ptr):
      *ptr = resolve_forward(ptr)

// Rebuild free lists: evacuated source regions become free/available
```

---

## 3.20 Practical Engineering Concerns

- **Copy safety**: overlap avoidance; prefer downward sliding or region-disjoint evacuation.
- **Write amplification**: compaction writes whole live set; may stress caches/TLB; region-based compacts less at a time.
- **Page protection tricks**: sometimes used to detect interior pointer writes or to protect from-space during incremental compaction; can be expensive.
- **Alignment and padding**: preserve alignment when computing forwarding addresses; respect object-specific alignment (vectors, SIMD).

---

## 3.21 Testing Checklist

- Forwarding correctness: all pointers updated; no stale from-space references.
- Interior pointers: delta preserved.
- Large/pinned objects excluded and not moved.
- Cross-region remember-set update after moves.
- Stress: fragmented heaps, varied object sizes, deep graphs.
- Concurrency: barriers maintain correctness under mutator stores/reads.

---

## 3.22 When to Use Mark-Compact

- Need to control fragmentation and improve locality.
- Accept higher pause time than mark-sweep; can mitigate with regional/partial compaction.
- Good as full-heap collector in VMs where copy reserve is too costly for old gen but fragmentation is an issue.

---

## 3.23 Summary

Mark-compact collectors add a relocation phase to mark-sweep to deliver defragmented, dense heaps and better locality. Core styles include two-finger (single pass, arbitrary order) and sliding (prefix-sum, order-preserving). Region-based evacuation gives partial compaction with lower pauses. Forwarding metadata and pointer updates are central correctness concerns; pinned/large objects often stay out of compacted regions. Incremental/parallel variants rely on barriers or regional compaction to keep pauses tolerable.

