# Garbage Collector

Each Eco process has one mutator, the eco thread, and it owns one heap of two generations. Young objects are allocated by bumping a pointer through an area called eden. Each young collection, a minor collection, copies eden's survivors into one of a few rotating survivor extents, and a background thread later promotes (tenures) the ones still live into the old generation. The old generation never moves. It is made of blocks of cells grouped by size, each block with a bitmap recording which cells are live, plus a space for large payloads, and it is reclaimed by marking on background threads while the program runs and then sweeping. The collector can be this simple because no object the program can see is ever written again. No old object can gain a pointer to a younger one, so there is no write barrier, and the same fact lets marking and tenuring run concurrently without a barrier of any kind. The price is a discipline that compiled code, the kernels and the scheduler must keep, and a body of validators and formal models that check the concurrent protocols against the code.

## Why immutability is enough

In Elm a value is built only from values that already exist, so every pointer stored when an object is made leads to something of the same age or older. If nothing writes into an object once the program can reach it across a point where the collector may run, no old object can point to a younger one. A minor collection then needs only the roots and the young generation. It never searches the old generation for pointers into the nursery, so there is no remembered set (a record of old-to-young pointers), no card table, and no check on each pointer store to maintain them.

None of this depends on the heap being acyclic, and it is not. A closure that calls itself holds its own pointer, mutually recursive closures point at each other, and such cycles survive into the old generation. The collector traces them like any other graph: copying leaves a forwarding address in each moved object and marking sets a bit, so each object of a cycle is visited once. The write barrier disappears because objects are not written after publication, whatever shape the graph has.

The same property removes the barriers a concurrent collector normally needs. If no object that existed when marking began is written, every pointer the program holds later leads either to something reachable at that moment or to something allocated since. Background marking therefore needs only a snapshot of the off-heap mutable locations at the start, and it treats everything allocated in the old generation during the cycle as live. It needs no barrier recording overwritten pointers and no second pause to re-mark. Background tenuring needs no read barrier for a related reason: until an extent is retired, a pointer to an unmoved original is still valid, and because neither the original nor its copy is ever written, the two are interchangeable. Concurrency is worth having here because it keeps pauses from growing with the size of the old generation.

The runtime calls this rule the frozen published heap: no runtime or kernel code writes an object after it has survived a collection unless the object is still being built. Validation builds check it with a census that hashes survivors and promoted objects and reports any hash that changes.

## Keeping the heap frozen

Immutability is a property of Elm, but the heap is written by compiled code and by C++ that could store anywhere. So each place that writes keeps its own rule, and there are five.

1. Compiled code stores only into objects it allocated since its last safepoint, the last point where it could have collected. Such an object cannot have moved or aged.
2. Recursive closures are the one place compiled code stores an object's pointer into a slot after allocation. A self-capturing closure is patched with its own address, and mutually recursive closures are allocated as one contiguous group and cross-wired afterward. Every such store lands in the same allocation with no safepoint in between, so each edge joins objects of the same age. These stores are where the heap's cycles come from.
3. A kernel that fills a container across calls into user closures, each of which may collect, sets the container's builder bit. A builder is traced and copied but never aged or promoted, so it stays young while it is being written, and the kernel clears the bit before Elm code can see the container. Chunked list chains are built the same way.
4. A large object that holds pointers, such as a big array, is always allocated young, because its kernel fills it with young pointers after allocation. Allocated old, each of those stores would be an old-to-young pointer that nothing records.
5. Long-lived mutable runtime state lives off the heap and is scanned as an external root. The scheduler's process record is rebuilt on every update and found through a registry, because updating it in place creates old-to-young pointers, and those corrupt programs that use MVars (the runtime's shared mutable variables).

The default nursery cannot survive a breach of these rules. It tenures an extent while the mutator runs, so a late write into a survivor leaves an old object pointing into an eden that has since been reset. A semi-space nursery, used only when explicitly configured, rescans promoted objects to tolerate such writes. The default has no such fallback, which is why the rule is enforced at each writer and checked by the census rather than assumed.

## How the heap is laid out

The heap is one reserved range of address space below 2^43 bytes, split by configuration into the old generation at the bottom and the nursery region at the top. A heap pointer is the object's address, as [runtime.md](runtime.md) explains, so asking whether an object is young is a bounds compare. That keeps the check cheap on the paths that run most often. The collector uses two more facts about the pointer word, whose full encoding [value-representation.md](../value-representation.md) gives: the address sits in its low 43 bits, which is why the reservation lies below 2^43, and a word whose pointer indicator bit is set, an embedded constant, is never traced.

Every object starts with an eight-byte header. No live object is smaller than 16 bytes, because the forwarding table that tenuring keeps outside the headers has one entry per 16-byte granule. The tag alone gives the object's size and the layout of its children, so the collector never needs Elm types. For the kinds that may hold an unboxed Int, Float or Char, two bits per field say which fields are pointers to trace. Three other fields decide whether a survivor may be promoted.

```cpp
typedef struct {
    u32 tag : TAG_BITS;
    ...
    u32 pin : 1; // Memory-pinned object (prevents relocation).
    u32 age : 2; // Nursery promotion counter; doubles as on-free-list
                 // sentinel for Tag_Free cells (see above).
    u32 unboxed : 6; // 2 bits per slot; used by Cons/Tuple2/Tuple3/ElmArray.
    ...
    u32 builder : 1; // Builder flag: object is under construction; pinned
                     // to nursery (no aging, no promotion) while set.
    u32 size; // Object size in type-specific units.
} Header;
```

From `runtime/src/allocator/Heap.hpp`. A survivor is promoted only when its pin and builder bits are clear and its age has reached the promotion age. The age field has two bits, so the promotion age can be 1 to 3, and it is 1. The header also carries color bits and a reference count, which the cut hides: the collector does not use them to decide liveness, and the old generation's bitmaps do.

The nursery region is contiguous and holds eden and the survivor extents. Compiled code bumps eden's pointer inline, and the end of the bump area is clamped in advance to the point where a minor collection should start. One unsigned compare then means both "eden is full" and "time to collect", and the branch taken when it fails is compiled code's only safepoint. Eden is given whatever the nursery threshold leaves after the last minor collection's survivors, so collections come as often as they would with a plain nursery of that size. Fresh objects are zeroed at their allocation site rather than by clearing the space after each collection. That works because the collector scans a closure only up to its count of filled captures and never reads a slot that has not been written.

The old generation allocates from uniform blocks, each serving one size class, and from mixed blocks that hold cells of several sizes. Each block has a stable number and metadata that never moves, so a background thread can hold a block number while the heap grows. In a uniform block, the mark bitmap doubles as the allocation map: the free cells are the unmarked ones, so the block is never swept, and a cursor owned by one thread walks it. Mixed blocks are swept lazily, when allocation needs space, by reading only the headers of live objects. Because liveness lives in the bitmaps, a block with no marks can be released without being scanned. Code to compact the old generation exists, but only tests call it.

Large strings and byte buffers are split in two. A 16-byte header sits in the nursery and points at the payload, which lives in the large-object space and never moves, so a minor collection never copies it. The payload has no header of its own, so that a power-of-two buffer fits its allocation exactly. For the same reason it must never be read as an object: a payload byte could look like a forwarding tag. The large-object space carves payloads from 1 KiB granules inside ordinary old-generation blocks, so each payload does not take a fresh page.

Large objects that hold pointers go into the nursery up to a cap, the largest old-generation size class, and above it into the young large-object space. An object there occupies a cell taken directly from old-generation memory, but the collector treats it as young. It never moves; a minor collection finds it through a bounding box and an index, ages it like any young object, and promotes it in place by changing its index entry. Allocation straight into old-generation memory, for large payloads and these young large objects, does not advance eden's pointer and so would never bring on a collection. Each minor collection therefore allows a budget of it, and past the budget the bump end is clamped so that the next nursery allocation collects.

Some values never die. A top-level constant, once computed, is never cleared, so tracing and copying it at every collection is wasted work. Computed top-level constants, interned literals and closures that capture nothing are copied, with everything they reach, into a permanent space outside the heap range that the collector never visits. The copier uses a visited set, so cycles do not stop it. A value it cannot close over, such as the scheduler's process record, stays on the heap and is rooted.

## One collection cycle, in order

A minor collection starts when a bump allocation misses. It finds the roots, copies eden, and hands the previous survivors to tenuring. When the old generation needs collecting, one minor collection also starts a major cycle that marks it in the background.

### Roots

Roots come from compiled frames, through LLVM's stack maps and a platform unwinder, and from C++, through registered slots, stack guards and scanners, as [runtime.md](runtime.md) describes. Off-heap stores each register a scanner: the scheduler's queues, the MVar store, the list scratch stack and platform state. Roots must be exact and updatable because the nursery moves. LLVM's statepoints give that for compiled code. A shadow stack, where generated code keeps its own list of root slots on every call, or a mode in which nothing moves, would each disable minor collections in compiled code or pin every object.

The collector never stops the mutator from outside. Stack maps describe only the return addresses of calls that may collect, so a signal could stop the thread at a point with no map. Polls inside loops would undo the compiler's knowledge of which calls can never collect, and a loop that does not allocate cannot write the heap, so it never needs to stop.

### Minor collection and tenuring

A minor collection empties eden completely, copying its live objects into a free survivor extent with several threads at once. A thread claims an object by an atomic update of its header, copies it, and then publishes the forwarding address, so no two threads copy the same object. A minor collection never promotes. Pointers into the extent filled by the previous minor collection are only recorded, and that extent is handed to a tenure job that promotes exactly what is reachable from the recorded roots and slots. By default the job runs on a background thread while the program runs. It keeps its forwarding addresses in its own table rather than in headers, and it allocates only from a grant of old-generation blocks that no other path may touch, so it shares no state the mutator writes.

The order of a pause is what lets tenuring run between pauses without barriers.

```text
ThreadLocalHeap::minorGC, region nursery:
  collect stack-map roots (unwind the compiled frames)
  tenureJoin: wait for or finish job m-1, then mergeJob (heal recorded slots,
              return the promotion grant, apply large-body and
              young-large-object results)
  minorGCRegion:
    assign roles: Fill = a Free survivor extent (receives this minor's copies)
                  Hand = the Young extent whose age reached promotion_age
                  Retire = the Tenuring extent whose job was just merged
    evacuate every root
    drain gray objects (parallel workers); for each boxed slot, by target role:
      Eden or previous builders -> claim header, copy into Fill (builders to
                                   its top-down area), age = 1, publish forward
      Hand   -> do not copy; record the slot to heal or the object as a root
      Retire -> rewrite the slot to the promoted copy from the shadow table
      Fill, old gen, permanent space -> leave alone
    Retire -> Free; reset eden; Fill -> Young(1); Hand -> Tenuring
  (on every return path) tenureLaunch: build job m for the Tenuring extent
              from the recorded roots and slots, and start it
```

Checked against `ThreadLocalHeap.cpp`, `NurseryRegion.cpp` and `NurseryTenure.cpp`; the extra aging extents used when the promotion age is above 1 are left out. Notice that the previous job is merged first, while the mutator is stopped, and the next job is launched last, so the background thread only ever works on an extent the mutator has stopped copying into. Builders are copied again at every minor collection, into their own area of the receiving extent, so a builder never sits in an extent that is being tenured. Because recorded slots are healed at the merge and a retired extent has no referrers left, at most three survivor extents are in use at once, a bound known in advance.

When the configuration cannot support this nursery, start-up fails and names the reason instead of falling back to the semi-space one, so that a test cannot quietly run the wrong nursery.

### Major collection

The old generation is collected by one mark cycle that spans several minor collections. At the end of the minor collection that starts a cycle, the pause marks gray the old-generation targets of every root, every off-heap store and every young object, and then hands that set to background marker threads, which mark while the program runs. Old-generation allocation during the cycle is marked live at once. Later minor pauses join marking only to help a marker that has fallen behind, the last one waits for marking to finish, and the minor collection after that classifies blocks for sweeping. Inside a pause, several markers share work through per-thread queues that idle markers steal from, and they count outstanding work exactly so that each knows when all of it is done.

A cycle starts for one of three kinds of reason. The old generation may be filling: its occupancy is high, the process is under memory pressure, or headroom is low. Its contents may have changed enough: a large fraction is garbage, or live data has outgrown a paced budget. Or something asks: an allocation fails, a collection is forced, or a program calls the explicit collection Task. A stop-the-world major collection also exists, and it first joins any cycle already running.

## Threads, and who decides

The collector runs three groups of helper threads, distinguished by what they may touch. A helper pool runs jobs that touch no heap object, such as returning pages to the operating system and pre-faulting pages before they are needed. They are the safest work to give a helper, because they hold no heap pointer and so cannot break any heap rule. A pause gang runs parallel minor collections and marking inside a pause. A background gang runs concurrent marking and tenuring. Jobs are posted and collected only at points where the mutator synchronizes with them. The arrangement is safe across a fork, because a host that embeds Eco may fork even though Eco itself only spawns.

Three rules govern these threads.

No collector thread writes what the mutator can read. Forwarding replaces a whole header with a forwarding tag, and code that reads an object checks the tag and then reads the size or field kinds. If another thread could forward the object between those two reads, the reader would act on a stale check. So background forwarding lives in the tenure job's table, and slots are healed only inside a pause.

Every collection decision is a function of the mutator's own state, never of how far a helper has got. Helper progress may decide only whether a pause waits or helps. A synchronous mode therefore reproduces the concurrent one counter for counter, and that is what makes a concurrent change testable. Parallel minor collections make the exact placement of objects in the old generation depend on thread scheduling, so the rule covers object-level counters and not placement. Making majors bit-identical at every worker count would need trigger inputs that change what the memory-based triggers mean, and a compacting nursery to fix placement.

A process has one mutator. A second thread that calls the heap's set-up aborts, unless a benchmark or test harness has explicitly allowed several; production programs never do. Committed-memory accounting, the timing of returning memory to the system, and the list of released address ranges are process-wide, and splitting them per heap is a design of its own. A single mutator also lets a mark cycle end with one handshake. A heap per thread, each with one mutator, is the runtime's decided direction and is not built; [runtime.md](runtime.md) sets out the three threading designs.

Each concurrent protocol is also written as a TLA+ model, with trace validation against the real allocator and weak-memory checks of the atomic code. A canary hashes the exact code regions each model describes and every concurrency-related line in the allocator, and warns when one changes; making it fail the build is a build setting. A warning means the named models must be re-audited before the hash is touched. [concurrency-models.md](../verification/concurrency-models.md) covers the models and [runtime-tests.md](../verification/runtime-tests.md) the allocator tests.

## Designs that would bring barriers back

Most collector designs that Eco does not use are ones that would let an old object point to a younger one. Pretenuring, allocating an object directly in the old generation to save a copy, is one: an object allocated old and filled afterward is an unrecorded old-to-young pointer. Collectors that collect older regions first, such as the beltway and train designs, need remembered sets of their own. Allocating large pointer-bearing objects old and scanning them as roots at every minor collection makes old-to-young pointers legal, and every concurrent phase would have to honor the exception; the young large-object space avoids that. Forcing a minor collection whenever such an object is created would cost a full pause per large array and still leave builders uncovered.

The nursery's shape is preferred to other ways of getting tenuring off the mutator. Replicating survivors and flipping at the pause still copies the youngest survivors inside the pause. Pipelined regions need every kernel to obey the stronger rule of storing only into fresh objects, and they give no retention bound in advance. Promoting a whole prefix of survivors at once tenures garbage, and its advantage of avoiding atomic claims shrinks once claims are cheap.

Two settings exist but are off. Aging survivors through more than one extent costs about as much marking as it saves. Running background markers at a lower priority lets a starved marker stall the join that ends the cycle.

Reference counting is out of scope for this heap. Any reference-counted tier would be a separate heap, and reusing an object in place is compatible only with an object that has never survived a collection.

## Examples of changes that fit the theory
A change fits when it keeps published objects unwritten, keeps collector threads away from anything the mutator reads, and bases every decision on the mutator's own state.

- An added heap object kind changes its tag, structure, size calculation, both nursery scanners, the marker and the shared child walker together, because each of them reads the layout from the tag. String ropes, slices, the UTF-8 string forms and chunked list nodes have this shape; [runtime-data-structures.md](data-structures.md) explains the forms themselves.
- An added off-heap mutable store registers an external root scanner that markers read only at the start of a mark cycle, as the MVar store, platform state and pending resumes do. Reading it later would break the snapshot that background marking relies on.
- A kernel that builds a container across safepoints uses the builder helpers, or gathers its elements on the rooted list scratch stack and allocates once, so the container is either young while written or written only before publication.
- An added trigger, pacing rule or tunable reads only mutator-observed state, is a heap configuration key with its file and environment overrides, and leaves counters equal between the synchronous and concurrent modes. The live budget, the headroom trigger and the direct-allocation budget are built this way.
- An added old-generation space uses ordinary blocks with a block kind, is covered by the page index and mark storage, and frees only through an index, as the large-object space does, so marking and sweeping need no special case for it.
- More parallel work in a pause reuses the shared marker loop, work counting and stealing queues, and keeps object-level counters the same at every worker count.
- A change to a modeled protocol updates the model, its mapping and its audit notes in the same change, then the canary's manifest, so the specification never lags the code.
- An explicit collection point is a kernel Task that collects when the mutator reaches a synchronization point, so the decision stays with the mutator.

## Examples of changes that would break the theory
- Writing into an existing object from a kernel: updating a process record in place, one "harmless" slot store, or reusing a survivor's storage. In the default nursery this leaves a dangling pointer once the extent is tenured, and it breaks the argument that makes marking barrier-free. Allocate a replacement, use the builder bit while the object is young, or keep the mutable thing off the heap behind a root scanner.
- Adding a remembered set or store buffer to tolerate such writes. It brings back what the design removed and invalidates barrier-free marking and tenuring. Fix the writer instead.
- Allocating a pointer-bearing object directly in the old generation to save a copy. Its later stores are unrecorded old-to-young pointers. Use the young large-object space.
- Letting a collector thread write a header or field the mutator can read, or heal slots outside a pause. The mutator's check-then-read on headers becomes a race. Keep background results in the job's own table and apply them at the merge.
- Basing a collection decision on helper or marker progress. The synchronous mode stops matching the concurrent one, and concurrent changes become untestable. Let progress decide only whether a pause waits or helps.
- Skipping a root because an allocation "will not collect". Any allocation can collect and move every young object, leaving the unrooted pointer at the old copy. Root it with a guard or a scanner.
- Loosening the abort on a second mutator to get parallelism. The process-wide accounting, the determinism argument and the models all assume one. Parallel Elm belongs to the heap-per-thread design, with its own per-heap accounting and models.
- Updating the canary's hash to silence a warning. The models it names may no longer describe the code. Re-audit them first.
- Wiring old-generation compaction into production. External root scanners would need pointer fix-up first, and the forwarding check that compiled code performs inline would need reconciling with moved old objects.
- Reading a large payload as a heap object, or special-casing one kernel's large buffers. A payload has no header and its bytes can look like a tag. Go through the large-object space and its body accessors.

## References

Parent: [runtime.md](runtime.md). Related: [runtime-data-structures.md](data-structures.md), [value-representation.md](../value-representation.md), [closures-and-calls.md](../closures-and-calls.md), [concurrency-models.md](../verification/concurrency-models.md), [runtime-tests.md](../verification/runtime-tests.md).

Code (`runtime/src/allocator/` unless noted):

- `AllocatorCommon.hpp`: `HeapConfig`, every default with its rationale, `validate()`, `resolveNurseryRegions`, `regionIncompatibility`.
- `Heap.hpp`: tags, `Header`, object structures, the builder bit. It is shared with [value-representation.md](../value-representation.md), which explains `HPointer`.
- `Allocator.hpp`, `Allocator.cpp`: address reservation, heap lifecycle, `initThread` and `allowMultipleMutators`.
- `ThreadLocalHeap.hpp`, `ThreadLocalHeap.cpp`: allocation slow paths, `minorGC` and `majorGC`, the mark-cycle driver, large-object placement, `zeroNewObject`.
- `NurseryRegion.cpp`, `NurseryTenure.cpp`, `NurseryParallel.cpp`, `TenureWork.hpp`, `OldGenTenure.cpp`, `NurserySpace.cpp`: the region minor, the tenure job, the parallel copy engine, the semi-space minor.
- `OldGenSpace.hpp`, `OldGenSpace.cpp`, `BlockTable.hpp`, `LargeObjectSpace.cpp`: old generation, marking, sweeping, the large-object space.
- `MarkWork.hpp`, `MinorWork.hpp`, `GCHelperPool.cpp`, `GCFork.cpp`, `GCStats.hpp` (`MajorReason`): parallel and concurrent machinery, major triggers.
- `RootSet.hpp`, `StackMap.cpp`, `StackUnwind.cpp`, `RootedSlots.hpp`, `HeapHelpers.hpp` (`allocArrayBuilder`, `BuilderGuard`): roots, builders and kernel helpers.
- `PermanentSpace.cpp`: the permanent space. `P1Census.cpp`: the frozen-heap census.
- `runtime/src/codegen/Passes/EcoGCStrategy.cpp`: the LLVM collector strategy.
- `runtime/src/platform/Scheduler.hpp`: the off-heap process registry.

Other files in `runtime/src/allocator/` belong to other documents: `RuntimeExports.cpp` and `RuntimeExports.h` to [closures-and-calls.md](../closures-and-calls.md); `StringOps.*`, `ListOps.*`, `BytesOps.*` and `Utf8.hpp` to [runtime-data-structures.md](data-structures.md); `ElmBytesRuntime.cpp` and `ElmBytesRuntime.h` to [bytes-fusion.md](../compiler/bytes-fusion.md).

Documents:

- `design_docs/parallel-gc.md`, sections 2 and 7: the snapshot argument, the writer rules and the nursery design.
- `test/tla/README.md`, `test/tla/`, `test/genmc/`: models, canary and weak-memory drivers.

Invariants (`design_docs/invariants.csv`):

- HEAP_005, HEAP_031, HEAP_034, HEAP_SNAPSHOT_001, HEAP_SNAPSHOT_002: unwritten published objects and the snapshot.
- HEAP_BUILDER_001 to HEAP_BUILDER_003, HEAP_040: builders and the scratch stack.
- HEAP_001 to HEAP_004, HEAP_008, HEAP_019, HEAP_028, HEAP_044, HEAP_071: layout, object kinds, field kinds, minimum size.
- HEAP_007: one mutator per process. GC_DET_001: decisions from mutator state. FORBID_HEAP_004: no collector writes the mutator reads. The canary's rule is in `test/tla/README.md` "The canary" (warn by default; it covers M1 to M8 in `test/tla/models.txt`).
- HEAP_011, HEAP_020, FORBID_HEAP_003: rooting.
- HEAP_041, HEAP_042, HEAP_069, HEAP_070, HEAP_079, HEAP_082: allocation, region nursery, direct-allocation budget.
- HEAP_026, HEAP_062, HEAP_080, HEAP_081: large objects and the young large-object space.
- HEAP_048 to HEAP_055: old-generation blocks and bitmaps. HEAP_058 to HEAP_060: helper pool. HEAP_063 to HEAP_066, HEAP_076: marking and triggers.
- HEAP_033, HEAP_035, HEAP_036: the permanent space (HEAP_036 calls it default-off; the code has it on).
- HEAP_018: states that values are acyclic; wrong for closures.
