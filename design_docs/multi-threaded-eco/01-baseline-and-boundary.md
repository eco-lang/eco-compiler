# 01 — Baseline and the heap boundary

## 1.1 Today

- **One mutator per process** [C: `HEAP_007`, `design_docs/invariants.csv`]. A
  second `initThread` aborts unless `Allocator::allowMultipleMutators(true)`,
  which only the benchmark driver and test harnesses set. The committed bytes,
  decommit clocks and released-extent list are process-wide (CR-012,
  `plans/threaded-gc-concurrency-register.md`, won't-fix as "option F",
  2026-10-01).
- **No write barrier.** The collector relies on Elm immutability: compiled
  code writes only fresh objects (HEAP_031), and no runtime or kernel code
  writes into an object that has survived a GC unless it carries
  `builder == 1` (P1, `plans/threaded-gc-04-frozen-published-heap.md`). There
  are no old-to-young pointers (HEAP_005).
- **HPointers are raw absolute addresses** [C: `THEORY.md`, "HPointers: Raw
  Absolute Addresses"; `design_docs/theory/heap_representation_theory.md`
  note]. Any thread in the process can dereference any heap address.
- **Embedded constants** (`True`, `False`, the merged `Empty`) are HPointer
  values with `ptr_ind` set and are never heap allocated [C:
  `REP_CONSTANT_001`, `REP_CONSTANT_002`]. Unboxed slots (Int, Float, Char)
  are identified by 2-bit kind words [C: `REP_HEAP_002`].
- **Kernels:** the eco/system I/O reactor thread never touches the Elm heap
  (G1); results are posted as POD to queues drained on *the* main thread; the
  kernel tables (sockets, streams, HTTP) are main-thread-only.
- The TLA+ models under `test/tla/` assume one mutator.

## 1.2 The decided threading model

- **[decided]** Each thread owns a heap with exactly one mutator. HEAP_007
  becomes "one mutator per heap", with several heaps per process.
- **[decided]** Threads communicate only by sending messages to typed
  mailboxes. Any heap type can be a message.
- **[decided]** Small messages are written into a ring buffer and copied onto
  the receiver's heap; larger ones are allocated in memory shared between
  threads, and that sharing is kept to a minimum.

Rejected alternative (for the record): a single shared heap with many
mutators. It needs per-thread nurseries with cross-thread young references
(publication or stop-the-world minors with safepoint polls in compiled
code), per-mutator root handshakes for the concurrent marker, CR-012 fixed,
and multi-mutator TLA+ models; and the JavaScript backend (Node workers)
cannot match shared-heap semantics. [E]

Consequences that hold for every option below:

- CR-012 stops being won't-fix: several heaps in one process share the
  process-wide accounting it names.
- Per-heap GC determinism (GC_DET_001) can survive per heap; the program as a
  whole becomes nondeterministic in message arrival order.

## 1.3 The boundary rule

A thread's GC moves and frees its own objects freely (nursery evacuation,
promotion, young-large-object handling). So:

> **Rule S1 — closure.** Memory reachable by more than one thread (a ring
> record, an arena in transit, a shared object) never points into any
> thread's heap. It points only within itself, to other shared memory, to
> embedded constants, or to static data (function code, static kernel
> singletons such as the `Order` values in `libElmKernel_Utils`).

> **Rule S2 — immutability.** Shared memory is never written after it is
> published (release store), apart from GC metadata kept outside the objects
> (reference counts, forwarding during a receiver's evacuation of memory it
> owns exclusively).

> **Rule S3 — age order.** Shared memory points only to shared memory that
> was published before it.

S1 is HEAP_005 ("no old-to-young pointers") one level up: no
shared-to-thread pointers. S2 is P1 one level up. S3 follows from
immutability (an object can only reference values that existed when it was
built) and is what makes the shared graph a **DAG**: reference counting,
which fails only on cycles, is then complete at any granularity, and no
tracing collector for shared memory is needed (02 §2.5). [E]

Pointers from a thread heap into shared memory are allowed, but the thread's
GC must not move or free their targets unless it owns them exclusively; how
that is avoided or accounted for is the subject of 02.

## 1.4 What crosses the boundary must be sendable

"Any heap type" holds for the data's shape, not for everything a value can
stand for. Values that are handles onto per-thread kernel state cannot simply
be copied to another thread: `Task`, `Cmd`, `Sub`, `Stream.Readable` /
`Writable`, sockets, servers, WebSockets, process ids, HTTP request handles.
Their closures or ids refer to the sending thread's kernel tables and
liveness holds. Options [E]:

- a **sendable** constraint on mailbox message types, checked by the compiler
  after monomorphization (when concrete types are known), in the spirit of
  `comparable`;
- explicit **transfer** semantics for selected handles (an HTTP request handle
  or a socket handed to a worker), where the kernel moves the table entry to
  the receiving thread.

Pure data and closures over sendable values are fine: function code pointers
are valid in every thread of the process. Copying changes object identity,
which Elm cannot observe, but kernel code must not cache by HPointer address
across threads (compare FORBID_HEAP_005).
