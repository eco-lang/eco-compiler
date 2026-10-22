# 02 — Message tiers

A message is an Elm value graph rooted at one HPointer. Moving it to another
heap has two halves: the **send** (making a closed copy, rule S1) and the
**receive** (making it usable on the receiver's heap). The tiers differ in
where the closed copy lives and who owns it afterwards.

| Tier | When | Where the closed copy lives | After receipt | Copies | Shared afterwards |
|---|---|---|---|---|---|
| **A** | Small (closed size below a threshold, e.g. a few cache lines) | A ring record | Copied out onto the receiver's heap (eagerly or lazily, §2.3) | 1 in + 0–1 out | Nothing |
| **B** | Large, one receiver | A fresh arena | The receiver's heap **adopts** the arena | 1 | Nothing |
| **C** | Large and genuinely shared (several holders at once) | Shared memory | Read in place; reference counted | 1, then 0 when forwarded | The memory, until every holder drops it |

## 2.1 The send: a closed graph copy

The sender copies everything the message reaches that is not already shared
(rule S1). Requirements [E]:

1. **Preserve sharing inside the value.** `let x = big in (x, x)` must copy
   `big` once, or DAG-shaped values grow exponentially. The copier needs a
   visited map. It must be a **side table keyed by address**, not forwarding
   marks in object headers: writing into the sender's surviving objects
   breaks P1 and confuses the concurrent marker.
2. **Every heap shape.** Kind words including tail kind words for wide objects
   (`REP_HEAP_002`, `HEAP_019`), chunked list spines, string ropes, large
   string and bytes headers with separate bodies (`HEAP_026`), young large
   objects (`HEAP_062`), closures (code pointer plus captured values). Reuse
   the GC's object walkers instead of a second copy of that knowledge; the
   copier then joins the list of places `HEAP_004` says to update for a new
   tag.
3. **Stop at shared memory.** A pointer that already targets shared memory is
   kept as is (it is closed by construction). Forwarding a received shared
   value to a third thread is then a pointer pass, and re-sending an updated
   persistent structure copies only its new nodes (§2.6).
4. **Write final absolute addresses.** A ring record or arena sits at a fixed
   address, so the sender can write pointers that are directly valid there.
   The receiver can then read the record in place (lazy copy-out) with no
   fix-up, and eager copy-out is a `memcpy` plus a rebase.
5. **Cost is O(copied size), paid by the sender** on its own thread.

## 2.2 Tier A: through a ring, copied out

Small messages are written into a ring record laid out exactly like heap
objects (same headers and kind words). The receiver copies the record onto
its heap and advances its read cursor; nothing refers to the slot afterwards,
so nothing is pinned.

- **Copy-out is cheap:** reserve nursery space of the record's size first (so
  no GC starts mid-copy with half-built, unrooted objects), `memcpy`, then
  rebase each non-constant pointer by the address difference (pointer slots
  are known from the kind words). No graph walk, no visited map; internal
  sharing survives automatically.
- **When to copy out — at processing, not on arrival** [E]. Copying out when
  the receiver is about to run `update` keeps the backlog in the ring: bounded,
  so a slow receiver fills its rings and senders park (natural backpressure).
  Copying out on arrival frees the ring sooner but moves the backlog onto the
  receiver's heap, unbounded, where queued messages also survive minor GCs
  and are copied again by every one of them.

## 2.3 Eager versus lazy copy-out

**Eager:** copy out at the start of `update`; the slot is freed before
`update` runs.

**Lazy:** hand `update` a reference into the ring record. If `update` only
reads fields (into SSA values) and drops the message, nothing is ever
copied. The slot is freed at the end of `update` instead of the start.

What lazy copy-out needs [E]:

1. **An escape scan at the end of `update`.** `update` may store part of the
   message: in the new model, in a closure inside a `Cmd`, in a list. Because
   Elm values are immutable, an object can only point to things that existed
   when it was created, so **only objects allocated during this `update` can
   point into the record.** The scan is therefore: walk the nursery bump region
   allocated since `update` began, plus young large objects created during it
   (HEAP_062), plus the kernels' registered off-heap roots (root stack, list
   scratch stack HEAP_040, MVar and other root scanners); copy out every
   referenced part (the receiver owns the record until it frees it, so the
   copier may write forwarding into the record and needs no side table); then
   free the slot. Cost is proportional to what the update allocated, not to
   the model's size.
2. **The record is young memory during `update`.** If a minor GC runs
   mid-update, survivors pointing into the record would be promoted, and the
   end-of-update pass cannot fix them (that would write into survived objects,
   breaking P1 and the concurrent marker). So the minor GC must **evacuate
   reachable ring objects as if they were nursery objects**, updating stack
   roots through the statepoint maps. That adds a "held ring record?" range
   check to the minor GC's copy loop, which is hot: measure it.
3. **A walkable nursery.** The end-of-update scan reads the bump region object
   by object, so it must contain parseable headers with no unparseable gaps.
   Per-site nursery zeroing and its poison bytes, capacity-check reservations
   and multiple nursery regions need checking. This is a new requirement.
4. **Safety net.** A pointer that survives into the next message's use of the
   slot is silent corruption. Needed: an invariant ("no heap or root pointer
   into a record after the read cursor passes it"), a validate-build check
   after every `update` in the heap-validate gate, and poisoning of freed
   records (as the nursery uses 0xD8) so a dangling read fails loudly.

Trade-off [E]:

| Message kind | Lazy saves |
|---|---|
| Small (`Hello`, tags, counters) | Almost nothing; the scan can cost more than a tens-of-bytes copy if the update allocated a lot |
| Large, only partly read (an HTTP request whose body is not kept) | The whole bulk copy |
| Contents stored in the model | Nothing; the copy moves from start to end of `update` |

**Recommendation:** eager below a size threshold, lazy above it; later,
compiler escape analysis of `update` after monomorphization to prove a message
type never escapes, so such messages are read in place at any size with no
scan at all.

## 2.4 Tier B: arena transfer

The sender copies the message into a fresh **arena** (a block allocated by
bumping a pointer and freed as a whole), closed per rule S1, and passes the
arena's address. The receiver's heap **adopts** the arena: it becomes the
receiver's memory. Nothing stays shared; there is no cross-thread liveness
question. Precedent: ownership transfer of blocks in Singularity's exchange
heap; Rust moves; Pony `iso`; JavaScript transferables [L].

- **Adoption as young memory** (recommended default): the receiver's next
  minor GC copies out what is still reachable and frees the block, so a
  retained fragment does not pin a large arena. Adoption into the old
  generation avoids that copy but can strand dead space (fragmentation, or a
  whole block kept for one live object).
- The receiver's allocator needs an **adopt** entry point that registers the
  block in its region/extent metadata (the threaded-GC work has nursery
  regions and extents, HEAP_072), with the same layout guarantees as its own
  allocations (HEAP_001–HEAP_004).
- **Accounting:** an adopted arena counts against the receiver's GC budget; a
  burst of large messages pushes the receiver into collections it did not
  cause by allocating. Its triggers (live budget, the HEAP_079 debt clamp)
  should see adoption as allocation.
- **Sizing:** large arenas need size classes or chained blocks; small messages
  go through rings, not arenas.
- **One owner only.** Tier B cannot serve broadcast (04 §4.2).

## 2.5 Tier C: reference-counted shared memory

For memory that several threads hold at once. Its liveness protocol:

- **Thread-held references** are recorded by each thread's own GC, not by
  per-pointer reference-count operations: a minor GC adds the shared memory
  newly reached from survivors; a major GC recomputes the thread's set exactly
  and releases what it no longer reaches. Because a minor GC does not trace
  the old generation, references in promoted objects must be recorded **at
  promotion time**, or a minor GC under-reports.
- **In-flight messages** hold a count until received.
- **References between shared objects** are counted when the newer object is
  published (rule S3: always newer → older).
- Freed at count zero. Because of rule S3 the shared graph is acyclic, so
  counting is complete; no cycle collector, no shared tracing collector.

Granularity:

1. **Pointer-free leaves** (large `Bytes` and string bodies): one count per
   object, no children. The simplest form; precedent: Erlang's refc binaries
   [L].
2. **Per arena** (pointer-bearing structures: large `List`, `Array`, `Dict`):
   the whole structure lives in one shared arena; counts are per arena;
   arena-to-arena references are counted edges (acyclic by S3). Interior
   pointers (`List.drop 1000 shared`) need a cheap address → arena lookup:
   power-of-two-aligned arenas with an address mask, or an address map.
   **Cost: pinning** — one retained element keeps the whole arena. Mitigation:
   **copy out on long retention**: a thread that has held an arena across many
   collections copies out the parts it reaches (tracing into the arena is safe:
   immutable and alive) and drops its count.
3. **Per object** with cascading decrements: no pinning, but a count word per
   shared object, long cascading frees (to be done incrementally) and much
   larger per-thread tables. Only if per-arena pinning proves costly.

Rejected: a tracing collector for shared memory. Deciding that an object is
free needs a handshake with every thread (a thread that has not collected
recently may hold a reference only on its stack or in its nursery); rarely
collecting threads would delay every shared free. This is the ragged-epoch
problem the single-mutator GC was designed to avoid (`parallel-gc.md`
§Termination). [E]

## 2.6 Persistent structures and structural sharing

`Dict` (red-black tree), `Array` (tree of `JsArray` nodes plus tail) and
`List` share structure when updated. If thread B receives a shared `Dict`,
inserts one key and sends the result on, the new path (about log *n* nodes)
lives in B's heap and points into the old shared arena; the send copies only
those nodes into a new arena that points to the old one (a counted edge).
Passing an updated large `Dict` along costs O(log *n*) per hop, not O(*n*).
[E]

## 2.7 Tier selection

| Message | Tier |
|---|---|
| Small, any number of receivers | A (one record per receiver, or one shared record with several cursors, 04 §4.2) |
| Large, one receiver, transient | A with lazy copy-out, or B |
| Large, one receiver, kept | B |
| Large pointer-free payload, several holders | C, per object |
| Large structure, several holders | C, per arena |
| Stream the receiver keeps, or a delta stream | Incremental arena (03 §3.3) |

The threshold between A and B, and between eager and lazy, are measurement
questions.
