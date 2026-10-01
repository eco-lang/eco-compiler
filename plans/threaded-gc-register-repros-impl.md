# Threaded GC: register reproductions, implementation plan

**Status:** ready to implement, 2026-09-30. Nothing is built yet.

**Parents and companions:**
- `plans/threaded-gc-register-repros.md`: the design. This plan supersedes it wherever the two disagree; §1 lists every correction.
- `plans/threaded-gc-concurrency-register.md`: the register. Status changes are recorded there (§9).

**Tree.** Every identifier and line number was checked against the tree of 2026-09-30. Functions are named too, because lines drift.

---

## 0. Goal and scope

Every open register entry that may be a real concurrency defect gets a code-level guard. Each guard:
1. **reaches the model's faulty state deterministically**, and returns `kNotReached` (never a pass) when a precondition is missed;
2. **fails on today's tree**, as an expected failure (xfail);
3. **flips when the fix lands** (XPASS). A negative control shows the oracle can tell the two apart.

Stress arms that raise hit rates come after the deterministic guards and never gate a build.

| Entry | Guard kind | Where | Phase |
|---|---|---|---|
| CR-014 | unit, one thread (A: FATAL, N=2 and N=1; B: silent release); TSan pair (`live_bytes`); stress (tail mode) | `ConcurrencyRegisterTest.cpp`, gc-heap-tsan | A, C, E |
| CR-001 | unit, one thread ((a) recount, (b) release); TSan pair | same | A, C |
| CR-016 | unit, one thread (chunk variant, stash variant); stress (exact arrays) | same | A, E |
| CR-028 | unit, one thread, validate builds only | `ConcurrencyRegisterTest.cpp` | A |
| CR-037 | unit, one thread, k=1 and k=2, plus a negative control | `ConcurrencyRegisterTest.cpp` | A |
| CR-017 | unit, held background marker (R1, R2), plus negative controls; stress (`lbaba`) | same, gc-heap-tsan | A, E |
| CR-007 | unit, a pool job blocked on a latch plus a gang | `ConcurrencyRegisterTest.cpp` | B |
| CR-023 | unit, `GCBackgroundGang` alone with a signal-parked thread | `ConcurrencyRegisterTest.cpp` | B |
| CR-012 | unit value checks (a)–(d); TSan (a), (e) | `ConcurrencyRegisterTest.cpp`, gc-heap-tsan | B, C |
| CR-002 | TSan pair | gc-heap-tsan | C |
| CR-019 | TSan pair, both orders | gc-heap-tsan | C |
| CR-013 | fork-trace deterministic arms, three ways; stress (`tenure-storm`) | `fork_harness.cpp` | D, E |
| CR-031, CR-032 | fork-trace deterministic arms | `fork_harness.cpp` | D |
| CR-003, 005, 015 | existing deterministic arms, now wired into a target | `fork_arms.txt` | D |

**Out of scope:**
- the serial bugs CR-018, CR-033 and CR-035 (CR-018 already has a guard);
- CR-036 (a coverage gap);
- CR-038 (premise drift);
- all fixes.

---

## 1. Corrections to the design (`threaded-gc-register-repros.md`)

Each of these was found by checking the design against the code. The steps below already include the fixes.

**CR-014**
1. **Scenario A needs `demote_live_fraction = 0`.** At the default 0.3 the all-dead V is demoted to mixed and never Queued. W1 then creates a virgin block after M, which kills the tail path.
2. **Scenario B's layout was wrong.** An all-dead bag page coalesces into one 64 K cell, not "32 K + 8 K". At LOT 32 K that cell is in a mixed-only class, and W2's split rung (`tryAllocateBySplittingLarger`, which walks only classes `>= num_size_classes_`, `OldGenSpace.cpp:2447`) serves it before sweep-on-demand.
   - Fix: make D and D' demoted **uniform** blocks of 24 B and 40 B cells. Each spans 65,520 bytes, which the packer splits into 32 K, 16 K, 8 K, 4 K, … cells, so each block gives exactly one 8 K cell.
3. **B's "ABA" is only partial.** D's id is re-issued (LIFO, `BlockTable.hpp:158`), but D's range goes to `Allocator::old_gen_free_blocks_` while `virgin()` takes a bag page, so the start differs. The oracle is therefore "D is no longer live at its start", not an overlap.

**CR-001**

4. **The trailing block T does not work.** An 8-byte slice that finishes the last block always exhausts its budget. With T after M, the phase then stays `Sweeping` with `sweep_pending_blocks_ == 0`, and every parallel-minor sweeper is gated on `hasPendingSweepWork()`. Completion never happens.
   - Fix: no T, and set all four budgets to 32 K (more than M's 24 K gap). The completion then happens in the loop and is deferred; the test checks this with the new `sweepCompleteDeferred` accessor.

**CR-016**

5. **The stash variant cannot use CR-018's block D.** An all-dead bag page gives one mixed-only 32 K cell. Use a demoted 24 B block (32,760 → 16 K, 8 K, …).
   - The first, finalized pop must come from **another** block (D'). Otherwise a CR-018 fix alone would XPASS the guard.
6. **Reachability.** The register says "test geometries only". The code suggests a non-default legacy config can reach it at 512 KiB blocks. This is unverified.

**CR-028**

7. **The pop and the V11 walk need separate slices.** One slice sweeps a gap and the live object after it. So the popped cell must be a gap followed by **two** live objects, and T is needed after M so that the fixed code does not run into the CR-014 tail path.

**CR-017**

8. **`conc_mark = 1` is synchronous.** It drains the whole mark inside the t0 pause (`OldGenSpace.cpp:4983-4986`), so `test_bg_hold_` holds nothing. R1 and R2 need `conc_mark = 2`, `gc_mark_threads ≥ 1` and `conc_mark_threads ≥ 1`.
9. **`isT0Block` exists only in validate builds** and matches by id, so it misses a same-id re-issue (CR-036). The tests compare against a snapshot of block **starts** taken at t0.
10. **R2 geometry.**
    - `initial_old_gen_size = 32 K`, because the 256 K floor keeps d's page.
    - c's block needs a live keeper.
    - d must not sit at its page's start: rematerialisation carves offset 0, which is allocated black.
    - Pages are rematerialised with `oldByteBuf`: a mutator `allocInt` never reaches the old gen.
11. **The S1 route in the register is impossible.**
    - `setBit` (`BitmapScan.hpp:34`) is a plain byte `|=`. The parallel marker uses `atomic_ref::fetch_or` (`OldGenSpace.cpp:3299`).
    - When they race, only the **marker's** bit can be lost. That is harmless in a block issued after t0, where every live cell is allocated black.
    - What remains is S2, plus the every-build abort that R1 shows.

**CR-037**

12. **It also reproduces at k = 2**, not only at k = 1 as the register says. The colouring happens at the first minor after the one that copied the header: at k = 1 in the hand-over prep (`NurseryRegion.cpp:751-753`), at k = 2 in the ageing prep (`:776-778`).

**CR-013**

13. **A host-forked child cannot run a minor today.** It has no `tl_heap_`: `Allocator::minorGC` asserts, and `getRootSet()` would create an empty heap. The `-minor` arms therefore need `adoptThreadHeap` and test a path **outside** the fork contract. Only the `-exit` arms are contract-relevant.
14. **Graphs.**
    - Way 1 needs two independent objects: with `p.a = o`, a lost start is re-tenured through p.
    - `-scan` needs a child that is not itself a start.
    - L3 needs 64 roots pointing at o.

**CR-031**

15. **A torn rehash does not crash `exit()`.** The destructor walks only the relinked chain and leaks the rest. The deterministic oracle is "the child tore down a heap it does not own".

**CR-019**

16. **There is no value oracle.** The tag and size bits are rewritten unchanged, so the defect is undefined behaviour only.

**CR-012**

17. **(d) is invisible to TSan.** It is an `madvise` vs `mmap` race, so it needs a value check with `mincore`.

**CR-007**

18. **`FnJob` is not a runtime type.** It is local to `GCHelperTest.cpp:77`, so copy it.

**Several guards**

19. **Three defaults bite:** `gc_thread_mode = 2`, `commit_ahead_bytes = 128 MiB`, `decommit_delay_syncs = UINT32_MAX`. Every test that touches page work sets all three.

**Stress**

20. **`region-b2` is a trace-build scenario** that belongs to the M1 trace corpus, and `major_every` fires only in trace builds while a cycle runs. Do not retune it; add the new `lbaba` arm instead.
21. **`m4.swend` is compiled only in trace builds**, and the trace build's `promo` runs a different main. Counting tail hits in the TSan build needs a stats counter (Step 22).

---

## 2. Shared infrastructure

### Step 1: test accessors (runtime headers; no behaviour change)

**`runtime/src/allocator/OldGenSpace.hpp`, class `OldGenSpaceTestAccess`** (after `setKeepWorkerCursor`, ~:2068):

```cpp
// CR-001: the in-loop completion held onSweepComplete for the merge.
static bool sweepCompleteDeferred(const OldGenSpace& og) { return og.sweep_complete_deferred_; }
// CR-007: try_lock probe of the promotion lock (a success is undone at once).
static bool promoMuHeld(OldGenSpace& og) {
    if (!og.promo_mu_.try_lock()) return true;
    og.promo_mu_.unlock();
    return false;
}
// CR-012(a): the handoff trigger that reads old_gen_in_use_bytes_ unlocked.
static bool cyclePressureFinishDue(const OldGenSpace& og) { return og.cyclePressureFinishDue(); }
```

**`runtime/src/allocator/Allocator.hpp`, class `AllocatorTestAccess`** (after `ensureOldGenCapacityFor`, ~:609):

```cpp
// CR-007 / CR-012: the private block-supply calls (each takes thread_mutex_).
static char* acquireOldGenBlock(Allocator& a, size_t n) { return a.acquireOldGenBlock(n); }
static void releaseOldGenBlock(Allocator& a, char* p, size_t n) { a.releaseOldGenBlock(p, n); }
// CR-007 / CR-012(b): the process-wide released-extent list (read with no mutator running).
static const std::vector<std::pair<char*, size_t>>& freeBlocks(const Allocator& a) { return a.old_gen_free_blocks_; }
// CR-007: true when ANOTHER thread holds thread_mutex_ (recursive: false on the holder).
static bool threadMutexHeldElsewhere(Allocator& a) {
    if (!a.thread_mutex_.try_lock()) return true;
    a.thread_mutex_.unlock();
    return false;
}
// CR-013 (fork harness only): the calling thread, a host-forked child's only thread,
// runs heap h, whose mutator does not exist in the child. OUTSIDE the fork contract.
static void adoptThreadHeap(Allocator&, ThreadLocalHeap* h) { Allocator::setThreadHeap(h); }
```

- `adoptThreadHeap` goes through `setThreadHeap` (`Allocator.cpp:175`) because that also syncs `eco_tl_bump_state` and resets the root-range cursors. Never write `tl_heap_` directly.
- Existing accessors that make new ones unnecessary: `OA::drainUnassignedBlocksForTest` (empty the bag); `Allocator::pageWork()`, `onGCPauseEnd` and `drainHelperWork` (all public); `og.promoCtx()` and the public `PromoWorker::stash` / `stash_n`.

### Step 2: shared helpers (`test/allocator/ConcurrencyRegisterTest.cpp`)

Put the new code in **one section at the end of the file**, so that `cr017Config` (:360), `oldByteBuf` (:537) and `byteBufIntact` are already visible. The section's anonymous namespace holds:

```cpp
constexpr size_t kEq = 12816;                       // 16 + 8*1600 == 8 + 2*6404 (ElmArray n=1600, ElmString L=6404)

void formatAsBytes(void* p, size_t sz) {            // copy of PromoBufferTest.cpp:45
    std::memset(p, 0, sz); Header* h = getHeader(p);
    h->tag = Tag_ByteBuffer; h->size = static_cast<u32>(sz - sizeof(ByteBuffer)); }
void* promo(OldGenSpace& og, OldGenSpace::PromoWorker& w, size_t sz, uint8_t fill = 0) {
    void* p = og.allocatePromotion(w, sz, false);
    if (!p) throw std::runtime_error("promo: nullptr");
    formatAsBytes(p, sz); std::memset(static_cast<ByteBuffer*>(p)->bytes, fill, sz - sizeof(ByteBuffer));
    return p; }

// CR-014 / CR-001 / CR-028: one-thread sweep-and-promotion geometry.
HeapConfig tailConfig(size_t lot, size_t sweep, double demote) {
    HeapConfig cfg;
    cfg.alloc_buffer_size = 64 * 1024;  cfg.nursery_block_count = 4;
    cfg.initial_old_gen_size = 256 * 1024;   // == committed at the major: the floor keeps all-dead blocks
    cfg.max_heap_size = 64ULL << 20;    cfg.large_object_threshold = lot;
    cfg.decommit_on_oldgen_release = false;  cfg.old_gen_bitmap_alloc = true;
    cfg.gc_thread_mode = 0;  cfg.gc_mark_threads = 1;
    cfg.incremental_mark = false;  cfg.conc_mark = 0;
    cfg.small_class_heap_budget_bytes = 0;   // no bag-first rung
    cfg.demote_live_fraction = demote;  cfg.minor_sweep_divisor = 0;
    cfg.sweep_work_budget = cfg.initial_sweep_budget = sweep;
    cfg.max_sweep_bytes_per_alloc = cfg.max_sweep_bytes_hard = sweep;
    cfg.validate(); return cfg; }
bool noMixedOnlyCells(const OldGenSpace& og) {       // W2's split rung must fail
    for (size_t c = OA::numSizeClasses(og); c < NUM_SIZE_CLASSES; ++c)
        if (OA::getFreeList(og, c)) return false;
    return true; }
bool sweepTo(OldGenSpace& og, const char* at) {
    for (int g = 0; OA::getSweepCursor(og) != at; ++g) {
        if (g > 1000 || !OA::hasPendingSweepWork(og)) return false;
        OA::lazySweep(og, NUM_SIZE_CLASSES, 8); }
    return true; }
bool grewBag(Allocator& a, OldGenSpace& og) {        // opens the light-shrink gate (:6134); call AFTER the major
    const size_t n0 = OA::getUnassignedBlocks(og).size();
    AllocatorTestAccess::ensureOldGenCapacityFor(a, og, 512 * 1024);
    return OA::getUnassignedBlocks(og).size() >= n0 + 4; }

// CR-017 / CR-037: region mode.
HeapConfig cr017ConcConfig(uint32_t k, size_t initial_old = 256 * 1024) {
    HeapConfig cfg = cr017Config(k);
    cfg.conc_mark = 2; cfg.gc_mark_threads = 1; cfg.conc_mark_threads = 1;
    cfg.conc_mark_priority = 0; cfg.initial_old_gen_size = initial_old;
    cfg.validate(); return cfg; }
void holdNext(Allocator& a, OldGenSpace& og) {       // = ConcurrentMarkTest.cpp:125 holdNextCycle
    while (og.cycleActive()) a.minorGC();
    og.test_bg_hold_.store(true); }
bool waitBg(OldGenSpace& og, int ms = 20000) {       // = ConcurrentMarkTest.cpp:137 waitBackground
    for (int i = 0; i < ms; ++i) {
        if (OA::bgEpisode(og) != OldGenSpace::BgEpisode::Running || OA::bgFinishedApprox(og)) return true;
        std::this_thread::sleep_for(std::chrono::milliseconds(1)); }
    return false; }
uint64_t bits(HPointer p) { uint64_t r; std::memcpy(&r, &p, 8); return r; }
bool lbHas(const region::Extent& X, void* body) {
    for (const HPointer& b : X.lb_bodies) if (AllocatorTestAccess::fromPointer(b) == body) return true;
    return false; }

// CR-007: a pool job (copy of GCHelperTest.cpp:77, which is file-local).
struct FnJob : gc::HelperJob { std::function<void()> f; explicit FnJob(std::function<void()> g) : f(std::move(g)) {}
                               void run() override { f(); } };   // match HelperJob's actual virtual
```

- **Includes:** `PageWork.hpp`, `NurseryRegions.hpp` (NurserySpace.hpp does not include it), `<sys/mman.h>`, `<atomic>`, `<chrono>`, `<functional>`, `<pthread.h>`, `<csignal>`, `<semaphore.h>`.
- **`FnJob`:** copy the original's exact base-class interface from `GCHelperTest.cpp:77`. The sketch above is only a shape.

### Step 3: registration

Each new test needs three things:
1. a `TestCase` in `ConcurrencyRegisterTest.cpp`, using the file's convention: `"CR-NNN [xfail CR-NNN]: <what must hold>"`, with the body `runXfailGuard(id, scenario)` (or `runFixedGuard` for a negative control);
2. an `extern` line in `ConcurrencyRegisterTest.hpp`;
3. a `concurrencyRegisterTests.add(...)` call in `test/main.cpp` (~:1021-1028).

**How the harness treats results:**
- `--filter` is a substring match (`TestSuite.hpp:288`).
- `runXfailGuard` forks: a `kDefect` result or a SIGABRT counts as "reproduced".
- Without `ECO_TEST_XFAIL=strict`, a reproduced defect PASSes (XFAIL) and `kCorrect` FAILs as XPASS. Strict mode inverts both.
- `kNotReached` always FAILs.

### Step 4: the validate build

There is no preset. `build-validate/` is a RelWithDebInfo tree configured by hand:
```sh
cmake -S /work -B /work/build-validate -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo \
      -DCMAKE_CXX_FLAGS_RELWITHDEBINFO="-O2 -g -UNDEBUG" -DECO_HEAP_VALIDATE=ON
```
`build/` has `ECO_GC_STATS` ON (a non-Release build); `build-nostats/` has it OFF.

---

## 3. Phase A: one-thread unit guards (`ConcurrencyRegisterTest.cpp`)

All Phase A guards drive the promotion workers from **one thread**, calling `og.promoCtx()`, `beginParallelPromotion(ctx, n)`, `allocatePromotion(ctx.w[i], size, false)` and `endParallelPromotion(ctx)`, as `PromoBufferTest.cpp:129-192` does. Every interleaving is therefore exact. The exceptions are CR-017 R1/R2, which hold the background marker and release it.

**Reference facts:**
- Size classes: `sizeClass(64)` = 7, `sizeClass(512)` = 32, `sizeClass(8192)` = 36.
- `num_size_classes_` is 37 at LOT 8 K and 39 at LOT 32 K.
- The `kAllocNone/Queued/Current` states are private; use the literals 0, 1, 2.

### Step 5: CR-014 A, the FATAL (N=2 and N=1)

**Tests:**
- `"CR-014 [xfail CR-014]: the tail completion never shrinks under a worker's Current block (A, N=2)"`
- the same with `(A, N=1)`

**Config:** `tailConfig(8*1024, 8, 0.0)`.

```cpp
int cr014A(unsigned n) {
    const char* id = n == 1 ? "CR-014 A (N=1)" : "CR-014 A (N=2)";
    auto& a = initAllocator(tailConfig(8 * 1024, 8, 0.0));
    OldGenSpace& og = AllocatorTestAccess::getThreadHeap(a)->getOldGen();
    void* v = og.allocate(32); formatAsBytes(v, 32);          // V: a class-32 virgin block, unrooted
    const BlockId V = OA::blockOf(og, v);
    std::vector<char*> m; std::vector<HPointer> roots;
    for (int i = 0; i < 4; ++i) { m.push_back(static_cast<char*>(oldByteBuf(og, 16 * 1024, 0x40 + i)));
                                  roots.push_back(AllocatorTestAccess::toPointer(m.back())); }
    for (auto& r : roots) a.getRootSet().addRoot(&r);
    std::sort(m.begin(), m.end());
    const BlockId M = OA::blockOf(og, m[0]);
    const BlockInfo& mi = OA::getBlockTable(og).info(M);
    if (!OA::inUniformBlock(og, v) || OA::blockCount(og) != 2 || OA::blockIdAt(og, 1) != M ||
        m[0] != mi.start || m[3] != m[0] + 3 * 16384 || mi.end_of_objects != m[3] + 16384)
        return notReached(id, "layout is not [V][M = four packed 16 KiB objects]");
    a.majorGC();
    if (!OA::blockLive(og, V) || OA::allocState(og, V) != 1 ||
        OA::partialFront(og, OA::sizeClass(32)) != V || OA::blockIdAt(og, OA::blockCount(og) - 1) != M)
        return notReached(id, "V is not live and Queued, or M is not last");
    if (!sweepTo(og, m[3])) return notReached(id, "could not stop the sweep at m[3]");
    if (!grewBag(a, og)) return notReached(id, "the bag did not grow (light gate stays shut)");
    if (OA::getFreeList(og, OA::sizeClass(64)) || !noMixedOnlyCells(og))
        return notReached(id, "W2 would be served before sweep-on-demand");
    auto& ctx = og.promoCtx(); og.beginParallelPromotion(ctx, n);
    void* p1 = promo(og, ctx.w[0], 32);                        // W1: publishes V, takes a cell
    if (OA::blockOf(og, p1) != V || OA::allocState(og, V) != 2 || OA::metaOf(og, V).live_bytes != 0 ||
        OA::blockCount(og) != 2)
        return notReached(id, "V is not Current with live_bytes 0, or a block was created");
    promo(og, ctx.w[n - 1], 64);   // today: tail path -> light shrink pass 1 -> detach(V) -> FATAL
    if (OA::gcPhase(og) != GCPhase::Idle) return notReached(id, "W2 did not complete the sweep");
    int rc = OA::blockLive(og, V) && OA::blockOf(og, p1) == V ? kCorrect : kDefect;
    og.endParallelPromotion(ctx);
    if (!OA::blockLive(og, V) || !OA::allocStateConsistent(og)) rc = kDefect;
    return rc;
}
```

- **Oracle:** SIGABRT with `[gc] FATAL: detachFromAllocation(..) during a parallel minor` (`OldGenSpace.cpp:758-764`), in every build.
- **N=1:** `refillCursorW` puts V in `w[0].cur`, and `onSweepComplete` flushes only the mutator's `cursor_[]`, so the path is the same.
- **XPASS:** the tail path at `:5829-5843` is routed through `par_promo_active_ ? sweepCompleteInPromotion() : onSweepComplete()`. This is M4's `tail_defers`.
- **Expected today:** XFAIL (abort).
- **Builds:** `build` and `build-validate`.

### Step 6: CR-014 B, the silent release of a stashed cell's block

**Test:** `"CR-014 [xfail CR-014]: the tail completion never releases a block whose cell is in a worker's stash (B)"`

**Config:** `tailConfig(32*1024, 8, 0.5)`.

The layout builder below is shared with Step 7:

```cpp
struct DPair { BlockId D, Dp, M; char *Dstart, *Dcell, *Dpcell; std::vector<HPointer> roots; };
int buildDPair(Allocator& a, OldGenSpace& og, const char* id, DPair& L) {
    void* d  = og.allocate(24); formatAsBytes(d, 24);         // D : class-24 virgin block, dies
    void* dp = og.allocate(40); formatAsBytes(dp, 40);        // D': class-40 virgin block, dies
    char* mo = static_cast<char*>(oldByteBuf(og, 40 * 1024, 0x4D));   // M: bag page [40K obj][16K][8K]
    L.D = OA::blockOf(og, d); L.Dp = OA::blockOf(og, dp); L.M = OA::blockOf(og, mo);
    if (OA::blockCount(og) != 3 || OA::blockIdAt(og, 0) != L.D || OA::blockIdAt(og, 1) != L.Dp ||
        OA::blockIdAt(og, 2) != L.M || mo != OA::getBlockTable(og).info(L.M).start)
        return notReached(id, "layout is not [D][D'][M]");
    L.roots = {AllocatorTestAccess::toPointer(mo)}; a.getRootSet().addRoot(&L.roots[0]);
    a.majorGC();                                               // the initial slice sweeps all of D
    if (!OA::blockLive(og, L.D) || !OA::blockLive(og, L.Dp) || !OA::demoted(og, L.D) ||
        !OA::demoted(og, L.Dp) || OA::metaOf(og, L.D).live_bytes != 0 || !OA::metaOf(og, L.D).fully_swept)
        return notReached(id, "D/D' not kept by the floor, demoted, D swept and all-dead");
    OA::lazySweep(og, NUM_SIZE_CLASSES, 8);                    // D' (one whole gap)
    OA::lazySweep(og, NUM_SIZE_CLASSES, 8);                    // M's object
    if (OA::getSweepCursor(og) != mo + 40 * 1024) return notReached(id, "cursor not at M's tail gap");
    L.Dstart = OA::getBlockTable(og).info(L.D).start;
    L.Dcell = L.Dstart + 48 * 1024;
    L.Dpcell = OA::getBlockTable(og).info(L.Dp).start + 48 * 1024;
    FreeCell* h = OA::getFreeList(og, OA::sizeClass(8192));
    if (reinterpret_cast<char*>(h) != L.Dpcell || reinterpret_cast<char*>(h->next_in_class) != L.Dcell ||
        h->next_in_class->next_in_class != nullptr)
        return notReached(id, "free_lists_[8K] is not [D'-cell, D-cell]");
    if (OA::getFreeList(og, OA::sizeClass(64)) || !noMixedOnlyCells(og))
        return notReached(id, "W2 would not reach sweep-on-demand");
    if (!grewBag(a, og)) return notReached(id, "the bag did not grow");
    return kCorrect;
}
int cr014B() {
    const char* id = "CR-014 B";
    auto& a = initAllocator(tailConfig(32 * 1024, 8, 0.5));
    OldGenSpace& og = AllocatorTestAccess::getThreadHeap(a)->getOldGen();
    DPair L; if (int rc = buildDPair(a, og, id, L)) return rc;
    const size_t c8 = OA::sizeClass(8192);
    auto& ctx = og.promoCtx(); og.beginParallelPromotion(ctx, 2);
    auto &w1 = ctx.w[1], &w2 = ctx.w[0];
    void* p1 = promo(og, w1, 8192, 0xD1);     // batch pop: finalizes the D'-cell (Sweeping), stashes the D-cell
    if (p1 != L.Dpcell || w1.stash_n[c8] != 1 || reinterpret_cast<char*>(w1.stash[c8][0]) != L.Dcell ||
        OA::metaOf(og, L.D).live_bytes != 0 || OA::gcPhase(og) != GCPhase::Sweeping)
        return notReached(id, "W1's batch pop did not stash D's cell");
    void* p2 = promo(og, w2, 64);             // one 8-byte slice: M's 24K gap -> tail path
    if (OA::gcPhase(og) != GCPhase::Idle) return notReached(id, "W2 did not complete the sweep");
    const bool dOk = OA::blockLive(og, L.D) && OA::getBlockTable(og).info(L.D).start == L.Dstart;
    if (!dOk) {
        std::fprintf(stderr, "  %s child: D released inside the minor; W1's stash still holds %p; "
                     "D's id now names %s (p2 %p)\n", id, (void*)L.Dcell,
                     OA::blockLive(og, L.D) ? "another block" : "nothing", p2);
        return kDefect;                       // do NOT pop the stash: it would write released memory
    }
    return kCorrect;
}
```

- **Oracle:** D is no longer a live block at its start. On today's tree W2's `virgin()` re-issues D's id elsewhere.
- **XPASS:** the tail defers (the same fix as Step 5).
- **Expected today:** XFAIL. A validate build may abort first in `validateOldGenMetadata`, which also counts as the defect.
- **Builds:** `build` and `build-validate`.

### Step 7: CR-001, the S1 half ((a) recount, (b) release)

**Tests:**
- `"CR-001 [xfail CR-001]: a cell popped while Sweeping is counted although the sweep completed before its finalize (a: recount)"`
- `"CR-001 [xfail CR-001]: the deferred shrink never releases a block holding a promoted object (b)"`

**Config:** `tailConfig(32*1024, 32*1024, 0.5)`. The budgets exceed M's 24 K gap, so the completion happens in the loop (`:5587-5606`) and is deferred. D's 65,520-byte gap is taken whole, so the major's initial slice still sweeps only D.

```cpp
int cr001(bool releaseArm) {
    const char* id = releaseArm ? "CR-001 (b)" : "CR-001 (a)";
    auto& a = initAllocator(tailConfig(32 * 1024, 32 * 1024, 0.5));
    OldGenSpace& og = AllocatorTestAccess::getThreadHeap(a)->getOldGen();
    DPair L; if (int rc = buildDPair(a, og, id, L)) return rc;
    const size_t c8 = OA::sizeClass(8192);
    auto& ctx = og.promoCtx(); og.beginParallelPromotion(ctx, 2);
    auto &w1 = ctx.w[1], &w2 = ctx.w[0];
    void* p1 = promo(og, w1, 8192, 0xD1);
    if (p1 != L.Dpcell || w1.stash_n[c8] != 1 || OA::metaOf(og, L.D).live_bytes != 0)
        return notReached(id, "W1 did not stash D's cell");
    promo(og, w2, 64);                          // in-loop completion -> deferred
    if (OA::gcPhase(og) != GCPhase::Idle || !OA::sweepCompleteDeferred(og))
        return notReached(id, "the completion was not in-loop and deferred (tail path? budgets)");
    if (!OA::blockLive(og, L.D) || OA::getBlockTable(og).info(L.D).start != L.Dstart)
        return notReached(id, "D was released before W1's finalize");
    void* p3 = promo(og, w1, 8192, 0xC1);       // stash pop: the finalize reads Idle (:1130)
    if (p3 != L.Dcell) return notReached(id, "W1 did not take its stashed D cell");
    if (!releaseArm) {
        const uint64_t lb = OA::metaOf(og, L.D).live_bytes;
        std::fprintf(stderr, "  %s child: D holds an 8 KiB promotion; live_bytes reads %llu\n",
                     id, (unsigned long long)lb);
        return lb == 0 ? kDefect : kCorrect;
    }
    og.endParallelPromotion(ctx);               // the deferred onSweepComplete: light pass 1
    if (!OA::blockLive(og, L.D) || OA::getBlockTable(og).info(L.D).start != L.Dstart) {
        std::fprintf(stderr, "  %s child: D released with the promoted object %p in it\n", id, p3);
        return kDefect;
    }
    return byteBufIntact(p3, 8192, 0xC1) ? kCorrect : kDefect;
}
```

- **Optional read-back for (b)** after a release: call `OA::drainUnassignedBlocksForTest(og)`, then `oldByteBuf(og, 56*1024, 0x5A)`. If that lands at `L.Dstart` (first fit), `byteBufIntact(p3, …)` fails.
- **XPASS:** the colour and count are decided at pop time, or CR-018's count-at-Idle fix is in. A relaxed-atomic `gc_phase_` still fails both oracles, which matches M4's `phase_atomic_release`.
- **Expected today:** XFAIL in both arms. **This settles CR-001's severity:** (b) failing means S1.

### Step 8: CR-016, chunk variant

**Test:** `"CR-016 [xfail CR-016]: the empty-block flip never takes a block whose chunk a worker holds (chunk)"`

**Config `cr016Config(demote)`:**
- `alloc_buffer_size = 32K`
- `nursery_block_count = nursery_max_block_count = 8`
- `initial_old_gen_size = 256K`, `max_heap_size = 512M`
- `large_object_threshold = 8K`
- `decommit_on_oldgen_release = false`, `old_gen_bitmap_alloc = true`
- `gc_minor_threads = 1`, `minor_lab_bytes = 4096`
- `gc_thread_mode = 0`, `incremental_mark = false`, `conc_mark = 0`
- `demote_live_fraction = demote`
- then `validate()`

The chunk variant uses `demote = 0.0`. With 32 K / 512 = 64 cells, one chunk unit covers the whole block (`resetRun`, `:1069`).

```cpp
auto& a = initAllocator(cr016Config(0.0)); OldGenSpace& og = AllocatorTestAccess::getThreadHeap(a)->getOldGen();
if (OA::blockCount(og) != 0) return notReached(id, "heap not fresh");
auto& ctx = og.promoCtx(); og.beginParallelPromotion(ctx, 2); auto &w0 = ctx.w[0], &w1 = ctx.w[1];
void* p0 = promo(og, w0, 512);      // virgin V published; w0 claims unit 0 = all 64 cells
const BlockId V = OA::blockOf(og, p0); char* Vs = OA::getBlockTable(og).info(V).start;
if (p0 != Vs || OA::cellsIn(og, V) != 64 || OA::metaOf(og, V).live_bytes != 0 ||
    !OA::metaOf(og, V).fully_swept || OA::allocState(og, V) != 2 || OA::blockIdAt(og, 0) != V)
    return notReached(id, "V is not a fully claimed 64-cell block with live_bytes 0 at position 0");
void* p1 = promo(og, w1, 512);      // advanceSharedW (:1315) retires V (kAllocNone); new virgin block
if (OA::allocState(og, V) != 0 || OA::blockOf(og, p1) == V || !OA::getFreeLargeBlocks(og).empty())
    return notReached(id, "V was not retired while w0's chunk is open");
char* big = static_cast<char*>(promo(og, w1, 32 * 1024, 0xEE));   // allocateLargeBlock -> allocateFromEmptyRegularBlocks (:2855)
if (big == Vs) { std::fprintf(stderr, "  %s child: V flipped to large at %p under w0's chunk\n", id, big);
                 return kDefect; }
char* p2 = static_cast<char*>(og.allocatePromotion(w0, 512, false));   // the stale cursor
if ((p2 >= big && p2 < big + 32 * 1024) || !byteBufIntact(big, 32 * 1024, 0xEE)) return kDefect;
formatAsBytes(p2, 512); og.endParallelPromotion(ctx);
return OA::allocStateConsistent(og) ? kCorrect : kDefect;
```

- **XPASS:** the flip skips blocks with an open worker chunk.
- **Expected today:** XFAIL. A validate build may abort on PM6/HEAP_054 at the merge, which also counts as the defect.

### Step 9: CR-016, stash variant

**Test:** `"CR-016 [xfail CR-016]: the empty-block flip never takes a block whose cell is in a worker's stash (stash)"`

**Config:** `cr016Config(0.5)`.

```cpp
auto& a = initAllocator(cr016Config(0.5)); OldGenSpace& og = AllocatorTestAccess::getThreadHeap(a)->getOldGen();
void* d = og.allocate(24); formatAsBytes(d, 24);                   // D: class-24 block, dies
char* lv = static_cast<char*>(oldByteBuf(og, 20 * 1024, 0x21));   // D': bag page, tail 8K@20K + 4K@28K
void* dead8 = oldByteBuf(og, 8192, 0x22);                          // pops D'+20K, dies
const BlockId D = OA::blockOf(og, d), Dp = OA::blockOf(og, lv);
if (OA::blockCount(og) != 2 || OA::blockIdAt(og, 0) != D || dead8 != lv + 20 * 1024)
    return notReached(id, "layout is not [D][D' = live 20K, dead 8K]");
HPointer r = AllocatorTestAccess::toPointer(lv); a.getRootSet().addRoot(&r);
a.majorGC(); OA::driveSweepToCompletion(og);
char* Ds = OA::getBlockTable(og).info(D).start;
char* Dcell = Ds + 16 * 1024;                  // 32760 -> 16K@0, 8K@16K, ...
char* Dpcell = lv + 20 * 1024;
const size_t c8 = OA::sizeClass(8192);
FreeCell* h = OA::getFreeList(og, c8);
if (OA::gcPhase(og) != GCPhase::Idle || !OA::blockLive(og, D) || !OA::demoted(og, D) ||
    !OA::metaOf(og, D).fully_swept || OA::metaOf(og, D).live_bytes != 0 ||
    reinterpret_cast<char*>(h) != Dpcell || reinterpret_cast<char*>(h->next_in_class) != Dcell ||
    !OA::getFreeLargeBlocks(og).empty())
    return notReached(id, "D is not an all-dead swept mixed block under [D'-cell, D-cell]");
auto& ctx = og.promoCtx(); og.beginParallelPromotion(ctx, 2); auto &w0 = ctx.w[0], &w1 = ctx.w[1];
void* p1 = promo(og, w1, 8192);   // finalizes the D'-cell, stashes the D-cell
if (p1 != Dpcell || w1.stash_n[c8] != 1 || reinterpret_cast<char*>(w1.stash[c8][0]) != Dcell ||
    OA::metaOf(og, D).live_bytes != 0 || OA::allocState(og, D) != 0)
    return notReached(id, "D's cell is not (only) in w1's stash");
char* big = static_cast<char*>(promo(og, w0, 32 * 1024, 0xEE));
if (big == Ds) { std::fprintf(stderr, "  %s child: D flipped to large at %p; w1's stash cell %p is inside\n",
                              id, big, Dcell); return kDefect; }
char* p3 = static_cast<char*>(promo(og, w1, 8192));
if (p3 >= big && p3 < big + 32 * 1024) return kDefect;
og.endParallelPromotion(ctx); return kCorrect;
```

- **Isolation from CR-018:** the finalized pop lands in D', so a CR-018 fix leaves D at 0 and the guard still reproduces.
- **Expected today:** XFAIL.

### Step 10: CR-028 (validate builds only)

**Test:** `"CR-028 [xfail CR-028]: the V11 walk never parses a cell a worker popped from the block (validate builds)"`

- **Wrapper:** `#if ECO_HEAP_VALIDATE` runs `runXfailGuard`; the `#else` branch prints `(skipped: needs ECO_HEAP_VALIDATE=ON)`. In a normal build V11 is compiled out, and the guard would XPASS.
- **Config:** `tailConfig(8*1024, 8, 0.0)`.

```cpp
char* av = static_cast<char*>(oldByteBuf(og, 12 * 1024, 0xA1));  // M: [a dead][32K@12K][16K@44K][4K@60K]
char* b = static_cast<char*>(oldByteBuf(og, 32 * 1024, 0xB2));   // split step 1: exact 32K cell
char* c = static_cast<char*>(oldByteBuf(og, 16 * 1024, 0xC3));   // exact 16K cell
char* d = static_cast<char*>(oldByteBuf(og, 4096, 0xD4));        // rung-2 pop of the 4K cell
void* t = oldByteBuf(og, 24, 0x7E);                               // T: uniform block after M
const BlockId M = OA::blockOf(og, av);
if (b != av + 12 * 1024 || c != av + 44 * 1024 || d != av + 60 * 1024 || OA::blockIdAt(og, 0) != M ||
    OA::blockIdAt(og, 1) != OA::blockOf(og, t) || av != OA::getBlockTable(og).info(M).start)
    return notReached(id, "layout is not [M][T]");
// root b, c, d, t
a.majorGC();                             // initial slice: gap a (-> 8K@0 + 4K@8K), then b
OA::lazySweep(og, NUM_SIZE_CLASSES, 8);  // c
if (OA::getSweepCursor(og) != d ||
    reinterpret_cast<char*>(OA::getFreeList(og, OA::sizeClass(8192))) != av ||
    OA::getFreeList(og, OA::sizeClass(64)) || !noMixedOnlyCells(og))
    return notReached(id, "the sweep is not at d with M's gap cell listed");
auto& ctx = og.promoCtx(); og.beginParallelPromotion(ctx, 2);
char* p1 = static_cast<char*>(og.allocatePromotion(ctx.w[1], 8192, false));
if (p1 != av) return notReached(id, "W1 did not pop M's first gap cell");
// copyClaimed's order (NurseryParallel.cpp:301-303): body first; the header is still tag 0 (Int, 16 B)
std::memset(p1 + sizeof(Header), 0xAB, 8192 - sizeof(Header));
Header fake{}; fake.tag = Tag_String; fake.size = 0x7FFFFFFFu;
std::memcpy(p1 + 16, &fake, sizeof fake);
void* p2 = og.allocatePromotion(ctx.w[0], 64, false);   // sweeps d -> M's boundary -> V11 abort
if (OA::getSweepCursor(og) != nullptr || !OA::metaOf(og, M).fully_swept)
    return notReached(id, "W2 did not sweep M to its end");
formatAsBytes(p1, 8192); formatAsBytes(p2, 64); og.endParallelPromotion(ctx);
return kCorrect;
```

- **Oracle:** SIGABRT with `[heap-validate] lazySweep: V11 block id … parse breaks` (`:5785-5804`).
- **XPASS:** V11 is skipped while `par_promo_active_`.
- **Expected today:** XFAIL in `build-validate`; skipped in `build`.

### Step 11: CR-037, reused-address YLOS (k=1, k=2, negative control)

**Tests:**
- `"CR-037 [xfail CR-037]: region k=1, a new YLOS at a freed lb_bodies address is reached at the hand-over minor"`
- the same with `k=2 … (ageing extent)`
- the control, run with `runFixedGuard`: `"CR-037: negative control, no body re-mark: the reused-address YLOS is reached and aged"`

**Why the address is reused:**
- An `ElmArray` is 16 + 8n bytes and an `ElmString` body is 8 + 2L (the size counts UTF-16 units, `Heap.hpp:426-427`). With n = 1600 and L = 6404 both are 12,816 bytes.
- Both go through `allocateTrackedCell` (`OldGenSpace.cpp:7394`) → `allocate` → Path 4 `allocateFromBagPage` (`:2528`): the string body via `allocateLargeBody` (`:7430`), the YLOS via `allocateYoungLarge` (`:7460`). So they take the same cell.

**The minor count, checked against `NurseryRegion.cpp:716-735` and `:1098-1105`:**
- Minor 1 copies the header into fill F, which ends as Young with age 1.
- At minor 2, F is the hand-over extent (k=1) or an ageing extent (k=2), and its prep colours X.
- Exactly one minor separates the copy from the colouring. **None** may run between the major and B.

```cpp
void* deadBodyAfterMajor(Allocator& a, int* ext, const char** why) {
    ThreadLocalHeap* h = AllocatorTestAccess::getThreadHeap(a);
    OldGenSpace& og = h->getOldGen(); RegionState* R = NurserySpaceTestAccess::region(h->getNursery());
    HPointer s = alloc::allocString(std::u16string(6404, u'q')); a.getRootSet().addRoot(&s);
    void* X = AllocatorTestAccess::fromPointer(static_cast<LargeStringHeader*>(a.resolve(s))->body);
    a.minorGC();                                                     // minor 1: header -> fill F; X joins F.lb_bodies (:427)
    int j = R->extentOf(a.resolve(s));
    if (j < 0 || !lbHas(R->x[j], X) || R->x[j].state != region::XState::Young || R->x[j].age != 1)
        { *why = "X not in a Young age-1 extent's lb_bodies"; return nullptr; }
    a.getRootSet().removeRoot(&s);
    a.majorGC(); OA::driveSweepToCompletion(og);                    // frees X; retireDeadLargeBodies erases its entry
    if (og.largeBodyIndexed(X) || !lbHas(R->x[j], X) || og.cycleActive())
        { *why = "X still indexed, dropped from lb_bodies, or a cycle is active"; return nullptr; }
    *ext = j; return X;
}
int cr037Scenario(uint32_t k, bool control) {
    const char* id = control ? "CR-037 control" : (k == 1 ? "CR-037 (k=1)" : "CR-037 (k=2)");
    auto& a = initRegionAllocator(cr017Config(k));                   // no cycle needed; mode 1 is fine
    ThreadLocalHeap* h = AllocatorTestAccess::getThreadHeap(a);
    NurserySpace& ns = h->getNursery(); OldGenSpace& og = h->getOldGen();
    RegionState* R = NurserySpaceTestAccess::region(ns);
    if (!ns.regionMode() || R == nullptr) return notReached(id, "no region nursery");
    int j; const char* why; void* X = deadBodyAfterMajor(a, &j, &why);
    if (!X) return notReached(id, why);
    const uint64_t seq = R->minor_seq;
    HPointer e = alloc::allocInt(0xE37);
    HPointer B = alloc::arrayFromPointers(std::vector<HPointer>(1600, e));
    a.getRootSet().addRoot(&B);
    if (R->minor_seq != seq) return notReached(id, "a minor ran before B existed");
    if (a.resolve(B) != X) return notReached(id, "B did not reuse X (fallback: n=4500 / L=18004)");
    if (!og.isYoungLarge(X)) return notReached(id, "B is not a YLOS");
    auto* arr = static_cast<ElmArray*>(X);
    const uint64_t e_bits = bits(arr->elements[0].p);
    if (control) ns.test_no_body_remark_ = true;                     // skips :751 and :776
    a.minorGC();                                                     // minor 2: the prep colours X
    const bool unaged = getHeader(X)->age == 0;                      // a reached YLOS has age 1 (:535)
    const bool unhealed = bits(arr->elements[0].p) == e_bits;
    std::fprintf(stderr, "  %s child: B age %u, slot %s\n", id, getHeader(X)->age, unhealed ? "UNHEALED" : "healed");
    a.getRootSet().removeRoot(&B);
    return (unaged || unhealed) ? kDefect : kCorrect;
}
```

- **Oracle:** B has age 0, or its slot still points into eden.
- **Stronger check (optional):** allocate about 10 K `allocInt(0xBAD)` to overwrite eden, then read e's value. In validate builds, run `minorGC(); majorGC()` and expect TV7 or HEAP_044.
- **If reuse misses:** use sizes of 32 K or more (`is_large` blocks, reused at their start): n = 4500, L = 18004.
- **Expected today:** XFAIL at k=1 and k=2, and the control passes. Builds: `build` and `build-validate`.

### Step 12: CR-017 R1, a YLOS in a body cell that t0 greyed

**Tests:**
- `"CR-017 [xfail CR-017]: region k=1, a YLOS allocated into a body cell the t0 walk greyed (R1)"`
- the control: `"CR-017: R1 negative control, no t0 young walk"` (`runFixedGuard`)

```cpp
int cr017R1Scenario(bool control) {
    const char* id = control ? "CR-017 R1 control" : "CR-017 R1";
    auto& a = initRegionAllocator(cr017ConcConfig(1));
    ThreadLocalHeap* h = AllocatorTestAccess::getThreadHeap(a);
    OldGenSpace& og = h->getOldGen(); RegionState* R = NurserySpaceTestAccess::region(h->getNursery());
    int j; const char* why; void* X = deadBodyAfterMajor(a, &j, &why);
    if (!X) return notReached(id, why);
    const BlockId bx = OA::blockOf(og, X);
    if (!bx.valid() || !OA::blockLive(og, bx)) return notReached(id, "X's page was released (floor)");
    if (OA::isMarked(og, X)) return notReached(id, "X marked before t0");
    holdNext(a, og);
    h->test_snapshot_skip_young_walk_ = control;
    h->test_force_major_trigger_ = true;
    a.minorGC();                          // minor 2: F -> Tenuring; t0 walks the dead header and greys X
    h->test_snapshot_skip_young_walk_ = false;
    if (!og.cycleActive() || OA::bgEpisode(og) != OldGenSpace::BgEpisode::Running || !og.test_bg_hold_.load())
        return notReached(id, "no held background episode");
    if (!control && (!OA::isMarked(og, X) || OA::markStackEmpty(og)))
        return notReached(id, "t0 did not grey X");
    const uint64_t seq = R->minor_seq;
    HPointer e = alloc::allocInt(0xE17);
    HPointer B = alloc::arrayFromPointers(std::vector<HPointer>(1600, e)); // validate: IM4 aborts HERE
    a.getRootSet().addRoot(&B);
    if (R->minor_seq != seq || a.resolve(B) != X) return notReached(id, "B not at X / a minor ran");
    og.test_bg_hold_.store(false);
    if (!waitBg(og)) return notReached(id, "background never finished");
    return kCorrect;                      // release: the marker scans B and aborts first
}
```

- **Oracles** (both are SIGABRT, which counts as the defect):
  - validate: `IM4: in-cycle allocation into a MARKED cell` (`OldGenSpace.cpp:5118`, from `assertCellWasWhite` via `:536`);
  - release: `[gc] parallel marker reached nursery object` (`:3326`).
- **Control:** X stays unmarked, so neither abort fires and the result is `kCorrect`.
- **Ordering note:** B must be allocated **after** the trigger minor. If B already sits at X at t0, the young walk skips it (`:3342`).
- **Expected today:** XFAIL in both builds.

### Step 13: CR-017 R2, a mark bit on a free cell of a rematerialised page

**Tests:**
- `"CR-017 [xfail CR-017]: region k=1, no mark bit lands on a free cell of a post-t0 block at a freed page (R2)"`
- a control (skip the young walk) run with `runFixedGuard`

**Config:** `cr017ConcConfig(1, 32 * 1024)`.

**Steps** (each "check" returns `kNotReached` on failure):
1. **Place f and d.** `f = oldByteBuf(og, kEq, 0xF1)`, then `d = oldByteBuf(og, kEq, 0xD1)`. Check: same block, the block is not uniform, and `d != info(block).start`. Record `P = info(block).start`.
2. **Tenure c.** Allocate 32 keeper Tuple2s, then `c = tuple2(boxed(toPointer(d)), boxed(allocInt(1)), 0)`, then 32 more keepers. Root them all and run `minorGC` until c and every keeper are old (at most 8 minors). Check that some keeper shares `OA::blockOf(og, c)`.
3. **Link x to c.** `x = tuple2(boxed(c), boxed(allocInt(4)), 0)`. Root x, unroot c, run `minorGC`. Check x is still young.
4. **Major.** Unroot x, then `majorGC()` and `driveSweepToCompletion`. Check all of:
   - `!OA::isMarked(og, c)`;
   - c's block is live;
   - c's stale image is intact (`getHeader(c)->tag == Tag_Tuple2` and `bits(((Tuple2*)c)->a.p) == bits(toPointer(d))`);
   - `!OA::blockOf(og, d).valid()`, i.e. P was released.
5. **Start the held cycle.** `holdNext`, set `test_force_major_trigger_ = true`, run `minorGC`. Check: the episode is Running, the hold is set, `OA::isMarked(og, c)`, and c's image is still intact. Then snapshot the t0 block **starts**: for each `pos < OA::blockCount(og)`, collect `OA::getBlockTable(og).info(OA::blockIdAt(og, pos)).start`.
6. **Rematerialise P.** Call `oldByteBuf(og, kEq, 0x66)` up to 64 times until one returns P. Check all of:
   - the page was found;
   - P is not among the t0 starts;
   - `getHeader(d)->tag == Tag_Free` (a free cell starts at d);
   - `!OA::isMarked(og, d)`.
7. **Release.** `og.test_bg_hold_.store(false)`, then `waitBg(og)`.
8. **Oracle.** `OA::isMarked(og, d) && getHeader(d)->tag == Tag_Free` → `kDefect`.

- **Validate builds:** calling `oldByteBuf(og, kEq, 0x77)` afterwards additionally shows IM4.
- **Expected:** XFAIL is likely, but this is the least certain scenario. A `kNotReached` here means the free-cell layout differs; record which precondition failed.
- **The TSan variant** (owner `setBit` vs marker `fetch_or`) needs owner allocations at d after step 7. Leave it to the stress arm (Step 23).

---

## 4. Phase B: latched stalls and multiple mutators (`ConcurrencyRegisterTest.cpp`)

**Timing margins:**
- Hold H = 200 ms; the oracle fires at H/2. A correct run takes microseconds.
- Every precondition wait is bounded at 5 s.
- Every release path fires even when a precondition is missed, so a missed precondition can never hang the test.

### Step 14: CR-007, a `promo_mu_` holder waits on a helper Discard job

**Test:** `"CR-007 [xfail CR-007]: a promotion worker never waits on a helper job while holding promo_mu_"`

**Config `cr007Config()`:** the `promoConfig()` fields (PromoBufferTest.cpp:53, file-local, so copy them), plus:
- `gc_minor_threads = 2`, `minor_lab_bytes = 4096` (this pins it against `ECO_TEST_MINOR_THREADS`)
- `incremental_mark = false`, `conc_mark = 0`
- `gc_thread_mode = 2`, `gc_helper_threads = 1`, `gc_helper_cpu = -1`
- `decommit_on_oldgen_release = true`, `decommit_delay_syncs = 0`, `decommit_delay_majors = 0`, `decommit_pending_max_bytes = 0`
- `commit_ahead_bytes = 0` (keeps Populate jobs out of the FIFO)
- then `validate()`

**Route, checked:**
1. `allocatePromotion` locks `promo_mu_` (`:1705`);
2. `advanceSharedW` returns false (empty `partial_`);
3. `tryPopFromFreeList` returns null;
4. `ladderFrom2W` → `virgin()` → `startVirginBlockShared` (`:1349`) → `ensureBagPageAvailable` (`:917`, the bag is empty);
5. `acquireOldGenBlock` takes `thread_mutex_` (`Allocator.cpp:760`);
6. first-fit finds b → `onReuse` (`:799`) → `awaitSlot` (`PageWork.cpp:126-128`) → `GCHelperPool::wait`.

Aging rule: `epoch - rel_epoch > delay` (`PageWork.cpp:285-287`), so `delay = 0` posts b at the first sync.

```cpp
int cr007Scenario() {
    const char* id = "CR-007";
    constexpr uint64_t kHold = 200'000'000;                 // H = 200 ms
    HeapConfig q = cr007Config(); q.gc_thread_mode = 0;
    initAllocator(q);                                       // quiesce the inherited page work
    auto& pool = gc::GCHelperPool::instance();
    if (pool.configured()) pool.shutdownForTesting();       // zero the process-wide stats
    const HeapConfig cfg = cr007Config();
    auto& a = initAllocator(cfg);
    ThreadLocalHeap* h = AllocatorTestAccess::getThreadHeap(a);
    OldGenSpace& og = h->getOldGen();
    gc::PageWork* pw = a.pageWork();
    if (!pw || pool.mode() != gc::HelperMode::Concurrent || pool.threads() != 1) return notReached(id, "pool");
    const size_t sz = 40, cls = OA::sizeClass(sz), page = cfg.alloc_buffer_size;
    if (OA::cursorBlock(og, cls).valid() || OA::partialQueueLength(og, cls) != 0) return notReached(id, "class in use");
    for (size_t c = cls; c < OA::numSizeClasses(og); ++c)
        if (OA::getFreeList(og, c)) return notReached(id, "a free cell exists");
    gc::GCMarkGang& gang = og.ensureGang();
    if (gang.members() < 2) return notReached(id, "gang < 2");
    OA::drainUnassignedBlocksForTest(og);                                   // (1)
    char* b = AllocatorTestAccess::acquireOldGenBlock(a, page);             // (2) fresh bump
    AllocatorTestAccess::releaseOldGenBlock(a, b, page);                    //     -> Pending
    const auto& fl = AllocatorTestAccess::freeBlocks(a);
    if (fl.size() != 1 || fl[0].first != b) return notReached(id, "free list is not {b}");
    std::atomic<bool> latch{false};
    FnJob blocker([&] { while (!latch.load()) std::this_thread::sleep_for(std::chrono::milliseconds(1)); });
    pool.post(blocker);                                                     // (3) FIFO head
    a.onGCPauseEnd(*h, false);                                              // (4) posts b's Discard
    int st = 0;
    pw->forEachTracked([&](char* p, size_t, int s) { if (p == b) st = s; });
    if (st != gc::PageWork::kPostedDiscard) return notReached(id, "b not posted");
    auto& ctx = og.promoCtx();
    og.beginParallelPromotion(ctx, 2);                                      // (5)
    struct Run { Allocator* a; OldGenSpace* og; OldGenSpace::PromoCtx* ctx; size_t sz;
                 void* p[2]{}; uint64_t wait_ns = 0; bool reached = false;
                 std::atomic<bool> held{false}; } r{&a, &og, &ctx, sz};
    std::thread releaser([&] {                                              // (6)
        const uint64_t dl = gc::GCHelperPool::nowNs() + 5'000'000'000ull;
        while (!r.held.load() && gc::GCHelperPool::nowNs() < dl) std::this_thread::yield();
        std::this_thread::sleep_for(std::chrono::nanoseconds(kHold));
        latch.store(true);
    });
    gang.run([](void* v, unsigned m) {
        Run& r = *static_cast<Run*>(v);
        if (m == 1) { r.p[1] = r.og->allocatePromotion(r.ctx->w[1], r.sz, false); return; }
        const uint64_t dl = gc::GCHelperPool::nowNs() + 5'000'000'000ull;
        while (!(OA::promoMuHeld(*r.og) && AllocatorTestAccess::threadMutexHeldElsewhere(*r.a)))
            if (gc::GCHelperPool::nowNs() > dl) return; else std::this_thread::yield();
        r.reached = true; r.held.store(true);
        const uint64_t t0 = gc::GCHelperPool::nowNs();
        r.p[0] = r.og->allocatePromotion(r.ctx->w[0], r.sz, false);
        r.wait_ns = gc::GCHelperPool::nowNs() - t0;
    }, &r, 2);
    latch.store(true); releaser.join(); pool.wait(blocker, false);
    const uint64_t mw = ctx.w[0].mutex_wait_ns;          // meaningful only with ENABLE_GC_STATS
    for (void* p : r.p) if (p) formatAsBytes(p, sz);
    og.endParallelPromotion(ctx);
    if (!r.reached || !r.p[0] || !r.p[1]) return notReached(id, "member 1 never held both locks");
    std::fprintf(stderr, "  %s child: member0 %.1f ms (mutex_wait %.1f ms), stall_max %.1f ms, reuse_waits %llu\n",
                 id, r.wait_ns / 1e6, mw / 1e6, pool.stats().stall_max_ns.load() / 1e6,
                 (unsigned long long)pw->counters().reuse_waits);
    return r.wait_ns >= kHold / 2 ? kDefect : kCorrect;
}
```

- **Oracle:** member 0's own promotion takes at least H/2. It works in every build: `mutex_wait_ns`, `stall_max_ns` and `reuse_waits` are printed but never gate the result.
- **XPASS:** member 0 returns well under 100 ms, whatever the fix is (skip posted extents under the lock, or move the wait out of it).
- **Hazard:** while member 1 holds `thread_mutex_`, member 0 must not read `PageWork`; use only the `try_lock` probes.
- **Expected today:** XFAIL.
- **Builds:** `build`, `build-nostats` and `build-validate`.

### Step 15: CR-023, a foreign `stopAndJoin` waits out a relaunched episode

**Test:** `"CR-023 [xfail CR-023]: a foreign stopAndJoin returns without waiting out a relaunched episode"`

It needs no heap, only `GCBackgroundGang` (`GCHelperPool.cpp`: `launch` :662, `joinLocked` :687-697 with `cv_done_.wait` at :689, `join` :699, `stopAndJoin` :705, `memberTids` :715, which takes `m_`).

```cpp
std::atomic<bool> g_parked{false}, g_unpark{false};          // lock-free: async-signal-safe
void cr023Park(int) {
    g_parked.store(true, std::memory_order_relaxed);
    while (!g_unpark.load(std::memory_order_relaxed)) { timespec ts{0, 1'000'000}; nanosleep(&ts, nullptr); }
}
struct Ep { std::atomic<bool> release{false}; std::atomic<bool>* stop; std::atomic<int> ran{0}; };
void cr023Fn1(void* p, unsigned) { auto& e = *static_cast<Ep*>(p); ++e.ran;
    while (!e.release.load()) std::this_thread::sleep_for(std::chrono::milliseconds(1)); }   // ignores stop
void cr023Fn2(void* p, unsigned) { auto& e = *static_cast<Ep*>(p); ++e.ran;
    while (!e.release.load() && !e.stop->load()) std::this_thread::sleep_for(std::chrono::milliseconds(1)); }

int cr023Scenario() {
    const char* id = "CR-023"; constexpr auto H = std::chrono::milliseconds(200);
    struct sigaction sa{}; sa.sa_handler = cr023Park; sa.sa_flags = SA_RESTART; sigaction(SIGUSR1, &sa, nullptr);
    gc::GCBackgroundGang::Options o; o.members = 1; o.name = "eco-cr023";
    gc::GCBackgroundGang gang(o);
    std::atomic<bool> stop1{false}, stop2{false};
    Ep e1; e1.stop = &stop1; Ep e2; e2.stop = &stop2;
    auto until = [](auto pred, int ms) { auto dl = std::chrono::steady_clock::now() + std::chrono::milliseconds(ms);
        while (!pred()) { if (std::chrono::steady_clock::now() > dl) return false; std::this_thread::yield(); } return true; };
    gang.launch(cr023Fn1, &e1, &stop1);                                         // (1)
    if (!until([&] { return e1.ran.load() == 1; }, 5000)) return notReached(id, "fn1 did not start");
    std::atomic<bool> f_done{false};
    std::thread F([&] { gang.stopAndJoin(); f_done.store(true); });              // (2)
    if (!until([&] { return stop1.load(); }, 5000)) return notReached(id, "F never set stop1");
    (void)gang.memberTids();   // takes m_: once F has released it, F is inside cv_done_.wait
    if (f_done.load()) return notReached(id, "F returned early");
    pthread_kill(F.native_handle(), SIGUSR1);                                   // (3)
    if (!until([&] { return g_parked.load(); }, 5000)) return notReached(id, "F not parked");
    e1.release.store(true);                                                     // episode 1 ends
    if (!until([&] { return gang.finishedApprox(); }, 5000)) return notReached(id, "episode 1 did not finish");
    std::atomic<bool> launched{false};
    std::thread O([&] { gang.join(); gang.launch(cr023Fn2, &e2, &stop2); launched.store(true); });   // (4)
    until([&] { return launched.load(); }, 1000);     // a "refuse relaunch" fix may block here
    g_unpark.store(true);                                                       // (5)
    std::this_thread::sleep_for(H);
    const bool stalled = !f_done.load();
    std::fprintf(stderr, "  %s child: after %lld ms F %s; launched=%d launches=%llu stop2=%d\n", id,
                 (long long)H.count(), stalled ? "STILL BLOCKED" : "returned", (int)launched.load(),
                 (unsigned long long)gang.stats().launches.load(), (int)stop2.load());
    e2.release.store(true); F.join(); O.join(); gang.join();
    return (stalled && launched.load()) ? kDefect : kCorrect;
}
```

- **XPASS:** F returns within H, whatever the fix is (a generation-based wait, stopping episode 2, or refusing the relaunch).
- **Optional second arm:** e2 is released only after `f_done`, with a bounded wait of 2 s. That turns the stall into the deadlock the register mentions.
- **Signal-parking safety:**
  - It is safe because F holds no user lock inside `cv_done_.wait`.
  - The owner spins on `finishedApprox()` before `join()`, so it never blocks on `cv_done_`.
  - The handler touches only lock-free atomics and calls `nanosleep`.
- **Expected today:** XFAIL.
- **Why it lives in this file:** `runXfailGuard`'s fork keeps the handler and any stuck threads out of the test binary.

### Step 16: CR-012 (a)–(d), value oracles for two mutators

**Base config:**
- the geometry of `cr018Config`: `alloc_buffer_size = 64K`, `initial_old_gen_size = 256K`, `max_heap_size = 64 MiB`;
- plus `old_gen_bitmap_alloc = true`, `conc_mark = 0`, `incremental_mark = false`, `commit_ahead_bytes = 0`.

**Heap B** is always a `std::thread` that runs `a.initThread()`, publishes `&getThreadHeap(a)->getOldGen()` (seq_cst), parks on an atomic, then runs `a.cleanupThread()`. The pattern is `fork_harness.cpp` `trialTwoHeap` (:471-523).

Tests are named `"CR-012(x) [xfail CR-012]: …"`.

| Arm | Config delta | Steps | Precondition | Oracle → `kDefect` | XPASS when |
|---|---|---|---|---|---|
| **(a)** trigger | mode 0 | B is created. `d0 = OA::cyclePressureFinishDue(*ogB)`. On A: `while (a.getOldGenCommittedBytes() < a.getOldGenMaxBytes() && !OA::cyclePressureFinishDue(*ogB)) AllocatorTestAccess::acquireOldGenBlock(a, page);` (≤ ~1000 iterations) | `d0 == false` | B's decision becomes true, though B did nothing (a GC_DET_001 break) | committed bytes are counted per heap |
| **(b)** free list | mode 0, decommit off | On B: `X = acquire…; release…`. On A: `drainUnassignedBlocksForTest(ogA); p = ogA.allocate(24)` | `freeBlocks(a) == {X}`; p is non-null and in a valid block | `info(blockOf(ogA, p)).start == X` | each heap has its own list |
| **(c)** clock | mode 2, 1 helper, decommit on, `decommit_delay_syncs = 4` | On A: `E = acquire…; memset(E, 1, page); release…`. On B: `a.minorGC()` ×4, check, then a 5th. Then `a.drainHelperWork()` | E is `kPending` before B's pauses and after the 4th | after the 5th, `counters().discard_posted_extents` rose by 1, E is untracked, and `mincore(E)` shows it non-resident. A had no pause | E stays Pending |
| **(d)** window | mode 2, 1 helper, decommit off, `commit_ahead_bytes = 2 MiB` | On A: `a.minorGC(); a.drainHelperWork()`. Set `bump = getHeapBase(a) + a.getOldGenCommitHighWaterBytes()`, then `mincore` `[bump, bump + 256K)`. Start B (its `initThread` → `OldGenSpace::initialize` → `acquireOldGenRegion`, `Allocator.cpp:1002-1033`, `commitAt` MAP_FIXED, no `onFreshBump`), then `mincore` again | populate is supported, `populate_jobs ≥ 1`, `windowEnd() ≥ bump + 256K`, all pages resident, `ogB->regionBase() == bump` | fewer pages resident afterwards (expect 0) | `acquireOldGenRegion` goes through `onFreshBump` |

- **`mincore` helper:** 4 KiB granules; count the entries with `v[i] & 1`.
- **Kernel requirement:** populate needs Linux ≥ 5.14; without it, (d) returns `kNotReached`.
- **Expected today:** all four XFAIL.
- **If CR-012 is fixed by *forbidding* a second mutator:** `initThread` aborts and these guards would still read as "reproduced". Convert them to a death test at that point.

---

## 5. Phase C: deterministic TSan pairs (`test/gc-heap-tsan/`)

**Rules:**
- Order the two threads with **relaxed atomics only**. TSan derives no happens-before (HB) edge from them.
- Workers never print, assert or take a `std::mutex`. They store results in plain variables, and main reads them after `join()`.
- A plain `std::thread` may call `allocatePromotion(ctx.w[i], …)`. There is no thread affinity: the only `tl_heap_` read is `callerInPause`, reached only through `page_work_`, which is null at mode 0.
- **Never call `initThread()`** on these threads: that would create a second heap.

**`test/gc-heap-tsan/DetHandshake.hpp`** (new):
```cpp
#pragma once
#include <atomic>
#include <thread>
inline void waitFor(std::atomic<int>& s, int v) { while (s.load(std::memory_order_relaxed) < v) std::this_thread::yield(); }
inline void post(std::atomic<int>& s, int v) { s.store(v, std::memory_order_relaxed); }
```

**Dispatch.** In `heap_driver.cpp` `main` (non-trace build, before `:506`), add:
```cpp
if (argc >= 2 && std::strcmp(argv[1], "det-cr019") == 0) return ylosDetMain(argc - 1, argv + 1);
if (argc >= 2 && std::strncmp(argv[1], "det-cr0", 7) == 0) return promoDetMain(argc - 1, argv + 1);
if (argc >= 2 && std::strcmp(argv[1], "cr012") == 0) return cr012Main(argc - 1, argv + 1);
```
Declare the three mains next to `:453`.

**Exit codes:** 0 = clean, 3 = NOT REACHED, 66 = a TSan report. Each arm prints `<arm>: REACHED …` or `NOT REACHED: <why>`.

### Step 17: the shared tail fixture (`promo_sweep.cpp`, `promoDetMain`)

`promoDetMain` switches on `argv[0]`: `det-cr014-live`, `det-cr001`, or `det-cr002`.

**Config:**
```cpp
HeapConfig cfg = promoConfig(1);     // gc_minor_threads=1: serial setup minors, so the block order is deterministic
cfg.conc_mark = 0;                   // incremental_mark=false, small_class_heap_budget_bytes=0 and
cfg.demote_live_fraction = 0.6;      //   minor_sweep_divisor=0 are already set by promoConfig
setBudgets(cfg, B);                  // all four sweep budgets = B (new helper)
```
B = 8 for the tail path and `det-cr002`; B = 64 for `det-cr001 inloop`.

**Fixture** (main thread; each check prints NOT REACHED and returns 3 on failure):
1. **Block U, class 64.** `cap6 = (64 - sizeof(ElmArray)) / sizeof(Unboxable)`. Allocate 64 rooted `alloc::allocArray(cap6)`, then `minorGC()` ×2. Check: all 64 are in one block U, `cellsIn == 64`, and `classToSize(sizeClass(64)) == 64`.
2. **Block M, class 32.** Allocate 128 rooted `makeObj(2, …)` (Tuple3), then `minorGC()` ×2. Check: all 128 are in one block M.
3. **Drop.** In U, drop the cells with `k % 8 == 3`. In M, drop the odd cells (M becomes 50 % live and is demoted; cell 0 is live, cell 127 is dead).
4. `a.majorGC()`.
5. **Check:**
   - `gcPhase == Sweeping`;
   - `demoted(M)` and `!demoted(U)`;
   - `blockIdAt(blockCount - 1) == M`;
   - `partialFront(c64) == U`;
   - no cursor block for c64, c32 or c128;
   - `getFreeList(c128) == nullptr` and `partialQueueLength(c128) == 0`;
   - every class ≥ `numSizeClasses` has an empty list.
6. **Pre-sweep.** `while (getSweepCursor(og) != M.start + stop*32) OA::lazySweep(og, NUM_SIZE_CLASSES, 8);`, bounded at 1000 iterations. `stop = 127` for 014/001 and 3 for 002.

### Step 18: `det-cr014-live` (CR-014 `NoRaceLive`)

Uses B = 8, `stop = 127`, `beginParallelPromotion(ctx, 2)`.

```cpp
std::thread t1([&]{ auto& w = ctx.w[0];
  for (int i = 0; i < 8; ++i) { p1[i] = og.allocatePromotion(w, 64, false); formatCell(p1[i], 64); } // chunk full; pending unflushed
  post(step, 1); waitFor(step, 2);
  p1[8] = og.allocatePromotion(w, 64, false);  // cursorAllocateW:1236 -> flushCursorW:1086 fetch_add (RACE), then lock
  formatCell(p1[8], 64); });
std::thread t2([&]{ waitFor(step, 1);
  p2 = og.allocatePromotion(ctx.w[1], 128, false);  // ladder -> sweepOnDemandAllocate -> lazySweep(c128, 8): TAIL :5832
  formatCell(p2, 128); post(step, 2); });
t1.join(); t2.join();
reached = allInU(p1, 8) && ctx.w[0].bm_allocs == 8 && gcPhase(og) == GCPhase::Idle;
og.endParallelPromotion(ctx);
```

- **HB audit:**
  - T1's flush is the first shared access of its call #9 and comes before any lock.
  - `claimChunkW`'s CAS is on `sh[c64]`; T2 uses `sh[c128]`.
  - T1's finalize in call #9 runs under the lock, so CR-001 stays silent in this arm.
- **Expected report:**
  - `Atomic write … T1`: `flushCursorW :1086` ← `cursorAllocateW :1236` ← `allocatePromotion :1698`
  - `Previous read … T2`: `computeFragmentationStats :6760` ← `onSweepComplete :5859` ← `lazySweep :5838` ← `sweepOnDemandAllocate :2306` ← `ladderFrom2W :1444` ← `allocatePromotion :1759`
- **Optional:** `AllocatorTestAccess::ensureOldGenCapacityFor(a, og, 4 MiB)` after the major opens the light gate and adds the pass-1 read at `:6177`.
- **Expected today:** REACHED, exit 66.
- **Fix:** 0 warnings, still REACHED.

### Step 19: `det-cr001 {rf|wf} {inloop|tail}` (CR-001 race half)

Uses `stop = 127`; `inloop`: B = 64 (the write at `:5590`); `tail`: B = 8 (the write at `:5832`).

- **T1:** `p = allocatePromotion(ctx.w[0], 64, false)` once (lock, claim unit 0, 7 free cells left). Then:
  - `rf`: `post(1); waitFor(2); q = allocatePromotion(ctx.w[0], 64, false)`, a fast path whose `finalizeBitmapCellW :1199` reads `gc_phase_`;
  - `wf`: `q = …` (fast path), then `post(1)`.
- **T2:** `rf`: `waitFor(1); allocatePromotion(ctx.w[1], 128, false); post(2)`. `wf`: `waitFor(1); allocatePromotion(ctx.w[1], 128, false)`.
- **Checks:** `blockOf(q) == U`, and after the join `gcPhase == Idle`.
- **Expected report (rf):** `Read … T1`: `finalizeBitmapCellW :1199` ← `cursorAllocateW` ← `allocatePromotion :1698` / `Previous write … T2`: `lazySweep :5590` (tail: `:5832`) ← `sweepOnDemandAllocate :2306` ← `ladderFrom2W :1444`. In `wf` the report is mirrored.
- **Fix:** `gc_phase_` is atomic, or snapshotted under the lock. The S1 half (Step 7) stays separate.

### Step 20: `det-cr002` (CR-002)

Uses B = 8, `stop = 3`.
- After the pre-sweep, the only class-32 free cell is `g1 = M.start + 32` (bit 4), and the cursor is at cell 3 (bit 12). Both are in bitmap word 0.
- Precondition: `getFreeList(c32) == g1 && g1->next_in_class == nullptr`.
- **T1:** `r1 = allocatePromotion(ctx.w[0], 32, false)`. It locks, `advanceSharedW(c32)` returns false, it batch-pops g1 (`:1749`), unlocks, and `finalizePoppedCellW :1768` → `setMarkBitAtomic` does a `fetch_or` on byte 0. Then `post(1)`.
- **T2:** `waitFor(1); r2 = allocatePromotion(ctx.w[1], 32, false)` → `lazySweep(c32, 8)` → `nextSetBit` (from bit 12) loads word 0.
- **Reached:** `r1 == g1 && r2 == M.start + 3*32`.
- **Expected report:** `Read of size 8 … T2`: `bitscan::loadWord BitmapScan.hpp:27` ← `nextSetBit :121` ← `lazySweep :5685` / `Previous atomic write of size 1 … T1`: `setMarkBitAtomic OldGenSpace.hpp:1889` ← `finalizePoppedCellW :1141` ← `allocatePromotion :1768`.
- **No seam.** A hook between `:1767` and `:1768` would only add the byte-overwrite interleaving, which has no value oracle.
- **Fix criterion:** the M4 `sweep_race_bitmap` fix.

### Step 21: `det-cr019 {t1first|t2first}` (CR-019, `ylos_sweep.cpp`, `ylosDetMain`)

- Factor `ylosConfig(workers, age, sweep_bytes)` out of `:210-231` and call it with `(2, 2, 8)`. Set `gc_minor_threads = 1` for the setup, then `initialize` / `reset` / `initThread` as at `:233-236`.
- **Setup:**
  1. 256 olds, then `minorGC()` ×3.
  2. `D` = a rooted `allocString(1450 chars)`, about 2.9 K. It gets its own page and absorbs the major's initial slice (`:4255`).
  3. `Y` = a rooted `arrayFromPointers(384 × olds[i]->h)`, 3,088 B, a YLOS on its own page after D.
  4. `majorGC()`.
- **Check:**
  - `og.isYoungLarge(Y)`, `gcPhase == Sweeping`, `sweepWillReach(og, idY, Y)`;
  - a class c with an empty list, no partial queue and no cursor, found by scanning down from `numSizeClasses - 1` (2048 is expected);
  - empty lists for classes ≥ `numSizeClasses`.
- **Pre-sweep** with `lazySweep(og, NUM_SIZE_CLASSES, 8)` until the next live object is Y. `nextLiveIs(Y)`:
  - the first position ≥ `getSweepBufferIndex` that is not `fully_swept` must be `idY`;
  - the first set bit in `getMarkBitsForBlock(og, idY)`, from `(cursor ? cursor : start) - start` divided by 8, must be `(Y - start) / 8`;
  - re-check `sweepWillReach` on every iteration.
- **Run:** `beginParallelPromotion(ctx, 2)`. T1 calls `og.promoteYoungLarge(Y)` (`:7509`, which takes no lock). T2 calls `allocatePromotion(ctx.w[1], classToSize(c), false)`. Order them with `post`/`waitFor` per the argument. Reached when `!og.isYoungLarge(Y) && !sweepWillReach(…)`. Then `endParallelPromotion` and `og.recomputeYoungLargeBounds()`.
- **HB audit:** leave out `ylos_mu_`. T2 never takes it, and T1 takes neither `promo_mu_` nor `thread_mutex_`.
- **Expected report:** `getObjectSizeFromHeader AllocatorCommon.hpp:446` ← `getObjectSize :571` ← `lazySweep :5715` ← `sweepOnDemandAllocate :2306` against `promoteYoungLarge :7509`, in both orders. There is no value oracle (§1 item 16).

### Step 22: `cr012 {a|e}` (CR-012, new `cr012_two_heap.cpp`)

**Wiring:**
- Add the file to the non-trace `add_executable(gc-heap-tsan …)`.
- Keep it out of the default run.
- The build already has `ECO_HEAP_VALIDATE=1` and `ENABLE_GC_STATS=1`.

```cpp
int cr012Main(int argc, char** argv) {                 // gc-heap-tsan cr012 a|e
    const char arm = argc > 1 ? argv[1][0] : 'a';
    HeapConfig cfg = base(); cfg.gc_thread_mode = arm == 'e' ? 2 : 0; cfg.gc_helper_threads = 1;
    cfg.commit_ahead_bytes = 0; cfg.decommit_on_oldgen_release = false; cfg.validate();
    auto& a = Allocator::instance(); a.initialize(cfg); AllocatorTestAccess::reset(a, &cfg); a.initThread();
    std::atomic<int> step{0};
    std::thread B([&] {
        a.initThread();                                    // takes thread_mutex_ BEFORE A's access
        OldGenSpace& ogB = AllocatorTestAccess::getThreadHeap(a)->getOldGen();   // B-local; never shared
        post(step, 1); waitFor(step, 2);
        if (arm == 'a') std::printf("cr012 a: due=%d\n", (int)OldGenSpaceTestAccess::cyclePressureFinishDue(ogB));
        else { void* p = ogB.allocate(48); std::printf("cr012 e: %p\n", p); }   // materializeVirginBlock
        post(step, 3);
    });
    waitFor(step, 1);
    if (arm == 'a') (void)AllocatorTestAccess::acquireOldGenBlock(a, cfg.alloc_buffer_size);  // write under the lock
    else a.onGCPauseEnd(*AllocatorTestAccess::getThreadHeap(a), false);                    // validatePageWork reads B
    post(step, 2);
    waitFor(step, 3); B.join();
    return 0;
}
```

**Expected reports:**
- **(a):** `old_gen_in_use_bytes_`, between `Allocator::acquireOldGenBlock` (write) and `OldGenSpace::cyclePressureFinishDue` (read).
- **(e):** `unassigned_blocks_` and `BlockTable` state, between `Allocator::validatePageWork` (`Allocator.cpp:1306-1313`) and `OldGenSpace::materializeVirginBlock` (`:936`).

In (e) the read deliberately comes first: B takes no lock after `go`, because its bag is non-empty.

### README rows (`test/gc-heap-tsan/README.md`, the register arms table)

| Arm | Command | Register | Expected |
|---|---|---|---|
| det-cr014-live | `gc-heap-tsan det-cr014-live` | CR-014 | **expected to fail**: REACHED, `flushCursorW` vs `computeFragmentationStats` |
| det-cr001 | `gc-heap-tsan det-cr001 {rf,wf} {inloop,tail}` | CR-001 | **expected to fail**: `finalizeBitmapCellW` vs `lazySweep`'s `gc_phase_` write |
| det-cr002 | `gc-heap-tsan det-cr002` | CR-002 | **expected to fail**: `nextSetBit` word read vs `setMarkBitAtomic` |
| det-cr019 | `gc-heap-tsan det-cr019 {t1first,t2first}` | CR-019 | **expected to fail**: `lazySweep` header read vs `promoteYoungLarge` |
| cr012 | `gc-heap-tsan cr012 {a,e}` | CR-012 | **expected to fail**: the pairs above |
| promo, tail | `gc-heap-tsan promo <seed> 40 4 0 0 8 1` | CR-014 | prints tail-eligible and tail-hit counts; fails under TSan |
| promo, exact | `gc-heap-tsan promo <seed> 40 {4,6,8} 0 1` | CR-016 | abort or corruption |
| lbaba | `gc-heap-tsan lbaba [jitter [seed]]` | CR-017, CR-037 | fails today |

---

## 6. Phase D: fork harness (`test/gc-heap-tsan/fork_harness.cpp`)

### Step 23: probes (trace build only)

Probes use `tlatrace::probe(where)` (`TlaTrace.hpp:98`). The callback runs **only while recording**, so a harness must call `begin(hdr, "m6.nothing.")` as `fork_harness.cpp:671` does.

**`TenureWork.hpp`** (keeps the header standalone):
```cpp
#if ECO_TLA_TRACE_ENABLED
inline bool tla_probes = false;   // set by the M6 fork harness: the m5.* pause points
#endif
// :315, after `const size_t i = st_.next_start++;`
ECO_TLA_TRACE_ONLY(if (tla_probes) ::Elm::tlatrace::probe("m5.item.taken");)
// between :276 (tenured_bytes += size) and :277 (publish)
ECO_TLA_TRACE_ONLY(if (tla_probes) ::Elm::tlatrace::probe("m5.item.copied");)
// :311, before scanCopy(c)
ECO_TLA_TRACE_ONLY(if (tla_probes) ::Elm::tlatrace::probe("m5.item.popped");)
```

**`NurseryTenure.cpp`**, in `TenureParEnv::tenure` after the claim loop (it ends at :1020), before `getObjectSize`:
```cpp
ECO_TLA_TRACE_ONLY(if (tw::tla_probes) ::Elm::tlatrace::probe("m5.l3.claimed");)
```

**`P1Census.cpp`:**
- add `#include "TlaTrace.hpp"`;
- add `ECO_TLA_TRACE_ONLY(namespace gc { extern bool tla_m6; })` inside `namespace Elm`;
- after `registerReportLocked(g);` (:320), add `ECO_TLA_TRACE_ONLY(if (::Elm::gc::tla_m6) ::Elm::tlatrace::probe("m6.census.locked");)`.

**`ThreadLocalHeap.cpp`:** add the same extern, and put `ECO_TLA_TRACE_ONLY(if (::Elm::gc::tla_m6) ::Elm::tlatrace::probe("m6.tlh.dtor");)` first in `~ThreadLocalHeap` (:241).

**TLA canary.** These edits change hashes that `test/tla/manifest.txt` pins:
- `TenureWork.hpp` is pinned as a whole file (M5, W5, `w_running_chain`);
- the `NT.TenureParEnv` region (M2, M5, M7, W5);
- the `TLH.destructor` region (M6).

GC_MODEL_001 applies. For each named model, read the edit against that model's MAPPING.md, then add an AUDIT.md entry that quotes the new hash, stating "trace-only probe, no semantic change". Only then run `check-tla-manifest.sh --update`. Step 29's stats counter is also inside `lazySweep` and needs the same treatment if that region is pinned.

### Step 24: harness plumbing

- **Includes:** `NurserySpace.hpp`, `NurseryRegions.hpp`, `ThreadLocalHeap.hpp`, `P1Census.hpp`.
- **`Opts` additions:** `bool regions = false; unsigned tenure_b = 1; bool conc = true; size_t blocks = 0;`.
- **`makeConfig`, when `regions`:**
  - `nursery_regions = 1`, `tenure_mode = 2`, `promotion_age = 1`, `tenure_help = 1`, `tenure_help_threads = 0`, `tenure_collector_threads = o.tenure_b`;
  - if `!o.conc`: `conc_mark = 0`, `incremental_mark = false`, `gc_mark_threads = 1`;
  - if `blocks`: `nursery_block_count = blocks`.
  - Replace the unconditional `nursery_regions = 0` at ~:211 with `o.regions ? 1 : 0`.
  - `minor_parallel_min_bytes = 0` is already set (:193), so `tenure_b = 2` gives L3.

```cpp
enum DetArm : int { /*…existing 0-4…*/ kDet13Start = 5, kDet13StartExit, kDet13Copy, kDet13CopyScan,
                    kDet13L3Exit, kDet13L3Minor, kDetCr031, kDetCr032 };
constexpr int kForeignTeardown = 16;          // add to codeName / printCounts
std::atomic<bool> g_det_arm_item{false}, g_det_in_item{false};
thread_local bool tl_mut = false;
bool is13(int d) { return d >= kDet13Start && d <= kDet13L3Minor; }
const char* itemProbe(int d) {
    return d <= kDet13StartExit ? "m5.item.taken" : d == kDet13Copy ? "m5.item.copied"
         : d == kDet13CopyScan ? "m5.item.popped" : "m5.l3.claimed";
}
bool spinFor(const std::atomic<bool>& f, uint64_t ms) {   // bounded: a fix may block the other side
    const uint64_t end = nowNs() + ms * 1'000'000;
    while (!f.load()) { if (nowNs() > end) return false; std::this_thread::yield(); }
    return true;
}
// onProbe additions:
} else if (is13(d) && tl_host && !std::strcmp(where, "m6.bg.stopped") && !g_det_fired.exchange(true)) {
    g_det_mut_go.store(true); spinFor(g_det_mut_done, 3000);
} else if (is13(d) && !tl_host && !tl_mut && g_det_arm_item.load() && !std::strcmp(where, itemProbe(d)) &&
           !g_det_in_item.exchange(true)) {
    spinUntil(g_host->det_forked);                         // stay mid-item until fork() has returned
} else if (d == kDetCr032 && !tl_host && !std::strcmp(where, "m6.census.locked") && !g_det_fired.exchange(true)) {
    g_host->go.store(true); spinFor(g_host->det_forked, 3000);   // holds g.mu across the fork
} else if (d == kDetCr031 && tl_host && !std::strcmp(where, "m6.tlh.dtor")) {
    _exit(kForeignTeardown);                               // the child's exit() reached a foreign heap
}
```

**Driver changes:**
- Dispatch the new arms.
- Parse `reached=` from the RESULT line; any `reached=0` returns **4** (an error, never a pass or an expected failure).
- For `det-cr013-*`, count the oracle message in `r.out` (the child's stderr reaches the trial pipe). Return 1 if and only if it hit.
- Return 0 on `window=closed`.

### Step 25: `trialDetCr013(which, seed)` (arms `det-cr013-*`)

```cpp
int trialDetCr013(int which, uint64_t seed) {
    std::atexit(&markAtexitDone);                 // before any GC hook: runs last, sets phase 5
    setenv("ECO_GC_HELPER_JITTER_US", "0", 1);
    const bool l3 = which == kDet13L3Exit || which == kDet13L3Minor;
    const bool exit_child = which == kDet13StartExit || which == kDet13L3Exit;
    Opts o; o.old_pairs = 2000; o.regions = true; o.conc = false; o.pool = false; o.tenure_b = l3 ? 2 : 1;
    Allocator& a = initHeap(o);
    Heap hp(a, seed, o);
    tl_mut = true;
    RegionState* R = NurserySpaceTestAccess::region(hp.h->getNursery());
    for (int k = 0; k < 6; ++k) a.minorGC();      // warm-up: the collector exists, the roots are old
    if (!R || !R->collector) { std::printf("RESULT arm=det13 reached=0 why=no-collector\n"); return 0; }
    std::vector<std::unique_ptr<Root>> g;
    buildGraph(a, which, g);                      // see the table below; drop temporaries before minor A
    a.minorGC();                                  // A: the graph is copied into the fill extent
    Elm::tlatrace::setProbe(&onProbe);
    Elm::tlatrace::begin("{\"harness\":\"gc-fork-trace\",\"kind\":\"det13\"}", "m6.nothing.");
    gc::tla_m6 = true; tenurework::tla_probes = true;
    Host ho; g_host = &ho; ho.on_signal = true;
    ho.child = [&a, &hp, exit_child] {
        signal(SIGALRM, onAlarm);
        if (exit_child) { armAlarm(4, 3); std::exit(kClean); }
        AllocatorTestAccess::adoptThreadHeap(a, hp.h);
        armAlarm(3, 3);                           // < Host::waitChild's 5000 ms
        a.minorGC(); a.minorGC(); alarm(0);
        _exit(hp.verify() ? kClean : 4);
    };
    ho.run(seed * 31 + 7);
    g_det.store(which);
    ho.go.store(true);                            // the host forks and pauses at m6.bg.stopped
    spinUntil(g_det_mut_go);
    g_det_arm_item.store(true);
    a.minorGC();                                  // B: hands the graph over, relaunches the collector
    const bool closed = ho.det_forked.load();     // a fixed launch waited out the fork
    const bool in_item = spinFor(g_det_in_item, 2000);
    const bool reached = closed || (in_item && (!l3 || R->job.conc_parallel));
    g_det_mut_done.store(true);                   // the host locks m_ and forks
    spinUntil(ho.det_forked);
    ho.finish();
    g_det.store(kDetNone); gc::tla_m6 = false; tenurework::tla_probes = false;
    Elm::tlatrace::end("/dev/null");
    for (int k = 0; k < 3; ++k) a.minorGC();
    std::printf("RESULT arm=det13 reached=%d window=%s forks=%d clean=%d hang_heap=%d hang_dtor=%d "
                "abort_or_signal=%d\n", reached, closed ? "closed" : "open", ho.forks, ho.counts[kClean],
                ho.counts[kHangHeap], ho.counts[kHangDtor], ho.counts[30]);
    return hp.verify() ? 0 : 5;                   // the parent is the control
}
```

| Arm | Graph (young, rooted) | Child | Expected today | Oracle |
|---|---|---|---|---|
| `det-cr013-start` | r1→o, r2→p, **no edges** | adopt + minor | SIGABRT, XFAIL | `TV1: resolve found no forwarding` (`NurseryRegion.cpp:367`, every build) |
| `det-cr013-start-exit` | the same | `exit()` | clean (a control; PASS) | — (the teardown merge uses `heal=false`) |
| `det-cr013-copy` | r1→o, r2→p, p.a=o | adopt + minor | SIGABRT, XFAIL | `TV3/TV4: forwarded objects != tenured` (`NurseryTenure.cpp:737`, validate) |
| `det-cr013-copy-scan` | r1→o(a=q1), r2→p(a=q2) | adopt + minor | SIGABRT, XFAIL | `TV6: a tenured copy has a young child after the merge` (`:844`, validate) |
| `det-cr013-l3-exit` | 64 roots → o | `exit()` | code 15 (`kHangDtor`), XFAIL. With `FORK_HARNESS_BT=1` the stack ends in `waitPublished` | code 15 |
| `det-cr013-l3-minor` | 64 roots → o | adopt + minor | code 13 (`kHangHeap`), XFAIL | code 13 |

**Fix criteria:**
- **The launch/lock window is closed:** `window=closed`, and every row flips to clean.
- **The fork contract (children skip foreign heaps):** `-l3-exit` flips. The `-minor` rows then test an unsupported path; retire them or mark them `reach`.
- **The orphan path is repaired:** the `-minor` rows flip.

### Step 26: `det-cr031` and `det-cr032` (in `trialDet`)

Both register `std::atexit(&markAtexitDone)` first and use `o.pool = false`.

**`det-cr031`:**
- The mutator runs `churn(50, 0); minorGC()` until at least 3 minors have run, then sets `ho.go` and does `spinUntil(ho.det_forked)`. It is between minors, so its tables are intact.
- Child: `armAlarm(4, 3); std::exit(kClean)`.
- **Expected today:** code 16 (`foreign_teardown`) in every trial, XFAIL.
- **Fix:** the child skips teardown of heaps the forking thread does not own, and exits clean.
- **Optional `det-cr031-torn`:** a trace-only noexcept `RootPtrHash` that probes `rs.rehash`. It changes the `RootSet` set type, which touches about 10 signatures (`OldGenSpace.hpp:1398,1402,2154-2180`, `ThreadLocalHeap.hpp:355`, `RootSet.hpp:252`). Same oracle; do not expect a crash.

**`det-cr032`:**
- Run `setenv("ECO_P1_CENSUS", "1", 1)` before `initHeap`, inside the trial body: `main` sets it to 0, and `census()` initialises lazily.
- The mutator runs `churn(50, 0); minorGC()` until `g_det_fired` (at most 3000 steps). Legacy promotion reaches `recordPromoted` (`NurserySpace.cpp:1178`).
- Child: `armAlarm(4, 3); std::exit(kClean)`. `atexitReport` blocks on `g.mu`.
- **Expected today:** code 14 (`hang_atexit`), XFAIL.
- **Fix:** with census atfork handlers, the host's prepare blocks; `spinFor` times out after 3 s, prints `window=closed`, and the child exits clean.

### Step 27: registry, runner and CMake

**`test/gc-heap-tsan/fork_arms.txt`** follows the `test/tla/models.txt` convention: an expected column and a `# CR-NNN` tag, and the row flips in the fixing change.
```
# flavor tier   arm                   trials seed expected   # CR
plain  quick  mut                    3  1  clean
trace  quick  det-cr003              3  1  xfail       # CR-003
trace  quick  det-cr004              3  1  reach       # CR-004 (Not-a-bug; the window CR-013 needs)
trace  quick  det-cr005              3  1  xfail       # CR-005
trace  quick  det-cr015              3  1  xfail       # CR-015
trace  quick  det-cr013-start        3  1  xfail       # CR-013 lost start
trace  quick  det-cr013-start-exit   3  1  clean       # CR-013 control
trace  quick  det-cr013-copy         3  1  xfail       # CR-013 double copy
trace  quick  det-cr013-copy-scan    3  1  xfail       # CR-013
trace  quick  det-cr013-l3-exit      3  1  xfail       # CR-013 L3 hang
trace  quick  det-cr013-l3-minor     3  1  xfail       # CR-013
trace  quick  det-cr031              3  1  xfail       # CR-031
trace  quick  det-cr032              3  1  xfail       # CR-032
plain  stress host-exit             20  1  flaky       # CR-031
plain  stress host                  10  1  flaky       # CR-003/015 (census env row: CR-032)
plain  stress relaunch              20  1  flaky       # CR-023
plain  stress tenure-storm          20  1  flaky       # CR-013
plain  stress tenure-storm-l3       20  1  flaky       # CR-013
```

**`test/gc-heap-tsan/run_fork_arms.py`**, modelled on `test/tla/run_traces.py:137-152`:
- It configures `<bd>/plain` and `<bd>/trace` (`-G Ninja -DCMAKE_CXX_COMPILER=g++`, the second with `-DECO_TLA_TRACE=ON`) and builds `gc-fork-harness` and `gc-fork-trace`.
- It scrubs `ECO_HEAP_CONFIG`, `ECO_NURSERY_REGIONS`, `ECO_TENURE_MODE` and `ECO_GC_THREAD*` from the environment.
- It maps each arm's exit code to a result:

| Arm exit | `clean` row | `xfail` row | `reach` row | Strict mode (`ECO_TEST_XFAIL=strict`) |
|---|---|---|---|---|
| 0 (not reproduced) | PASS | XPASS, which fails ("flip the row") | FAIL | an `xfail` row passes |
| 1 (reproduced) | FAIL | XFAIL | PASS | an `xfail` row fails |
| 4 (precondition missed), other, timeout | ERROR | ERROR | ERROR | ERROR |

`flaky` rows only report.

**CMake:**
- `test/gc-heap-tsan/CMakeLists.txt`: per flavour, `add_custom_target(fork-det COMMAND python3 run_fork_arms.py --flavor plain|trace --exe $<TARGET_FILE:…> DEPENDS gc-fork-harness|gc-fork-trace USES_TERMINAL VERBATIM)`.
- `/work/CMakeLists.txt`, after the `ECO_TLA` block (~:1243-1246), add `register-guards`. It:
  1. builds `test` and runs `test/test --filter "xfail CR-"`;
  2. runs `run_fork_arms.py --tier quick --build-dir=${CMAKE_BINARY_DIR}/fork-det`.
- Add `register-guards-stress` (`--tier stress`) as well.
- **Keep both opt-in:** out of `ALL`, `check` and `full`. `check`/`full` are Gate A; these targets need separate g++ sub-builds, fork, run for minutes and abort by design.

---

## 7. Phase E: stress (never gating)

### Step 28: tail-hit counters (`GCStats.hpp`, `OldGenSpace.cpp`; stats builds only)

- In `BitmapAllocStats` (`GCStats.hpp:177`), add `uint64_t sweep_tail_completions = 0, sweep_tail_in_promotion = 0;` and add both to the merge (the `:203` block).
- After `OldGenSpace.cpp:5832`:
  ```cpp
  #if ENABLE_GC_STATS
  alloc_stats_.bm.sweep_tail_completions++; if (par_promo_active_) alloc_stats_.bm.sweep_tail_in_promotion++;
  #endif
  ```
  These are written under `promo_mu_`, so they add no race.
- If `lazySweep` is a pinned TLA region, see the canary note in Step 23.

### Step 29: `promo_sweep.cpp`, tail mode (CR-014) and exact arrays (CR-016)

**Tail mode** (new argument `argv[7]`, default 0; the parse is at `:217-222`). When it is 1:
- `exact_arrays = false`, and all four sweep budgets are 8.
- `cfg.initial_old_gen_size = 32 << 20`: the floor stops every release, so no swap-remove moves the last block.
- **Prefill `partial_`:** per round, allocate about 3× the round's promotion volume of `makeObj(rng()%4, …)` fillers over the leaf and Tuple2 classes. After the minors, drop 40 % of them. They stay uniform (0.6 live is above `demote_live_fraction` 0.5) and are queued at the major.
- **Bag object last:** after the drop (`:260`) and before `majorGC` (`:262`), allocate `bag = PRoot(allocString(L≈1900), kind 3)` so a fresh bag page is appended last. Drop the previous round's bag.
- **Per minor, count:**
  - `tail_eligible`, when `gcPhase == Sweeping`, the last block is not fully swept, and it is demoted;
  - `tail_hits`, as the delta of `bitmapStats(og).sweep_tail_in_promotion`.
- Print both in the summary (`:302`).
- **Expected:** `tail_hits > 0` in most seeds. This is to be confirmed; it is the first time the stress run reaches the tail path.

**CR-016:**
- `:269` becomes `size_t cap = (exact_arrays && i == 0) ? array_cap : 0;`. This consumes one fewer `rng()` per minor, so every seed's stream shifts.
- Run with 4, 6 and 8 workers.

### Step 30: `heap_driver.cpp`, the `lbaba` arm (CR-037, CR-017)

**`Knobs` additions** (`:61`):
```cpp
int cycle_at = 0;                              // force at step % cycle_every == cycle_at (was == 0)
int idle_major_every = 0, idle_major_at = 0;   // STW major in any build, cycle or not
int lb_every = 0;                              // CR-037: dying large string, 8+2L == 16+8*ylos_len
int doom_every = 0;                            // CR-017: young x -> old doomed Tuple2; both die next period step
size_t ylos_len = 0;                           // fixed family length (0 = random)
int verify_every = 25;
```

**Setup in `scenario()`:** if `doom_every > 0`, create `doomed`, 4096 rooted `tuple2(Int, Int)` held in `unique_ptr<Root>`. Also add `unique_ptr<Root> lb_slot, x_slot` and `size_t doom_next`.

**Step body**, in this order after the churn and the every-9 big string:
1. `if (lb_every && step % lb_every == 1) lb_slot.reset();`
2. `if (doom_every && step % doom_every == 1) { x_slot.reset(); if (doom_next) doomed[doom_next - 1].reset(); }`
3. `if (idle_major_every && step % idle_major_every == idle_major_at) a.majorGC();`
4. The family block, using `len = kn.ylos_len` when it is set.
5. `if (lb_every && step % lb_every == 0) lb_slot = make_unique<Root>(a, alloc::allocString(buf.data(), 4 * ylos_len + 4));`
6. `if (doom_every && step >= 8 && step % doom_every == 0 && doom_next < doomed.size()) x_slot = make_unique<Root>(a, tuple2(boxed(doomed[doom_next++]->h), boxed(allocInt(step)), 0));`
7. The trigger: `== 0` becomes `== kn.cycle_at`.
8. `minorGC`.
9. Verify:
   - when `step % verify_every == 0`, check all families (as today);
   - when `lb_every && step % lb_every == 1`, also `checkFamily` this step's family (`fams[serial % kFamilyRing]`) at once.

**The arm:** `int lbabaMain(argc, argv)`, run as `gc-heap-tsan lbaba [jitter_us [seed0]]`.
- It sets jitter the way `armMain` does.
- It loops `age ∈ {1, 2}` × `bg ∈ 1..4` × `ylos_len ∈ {1600, 4500}`.
- Knobs per run:
  - `steps = 600`, `old_pairs = 20000`
  - `cycle_every = 2 + n % 3`, `cycle_at = 1 % cycle_every`
  - `idle_major_every = 3`, `idle_major_at = 1`
  - `lb_every = doom_every = 3`
  - `ylos_every = 1`, `verify_every = 3`
- It calls `scenario(bg, 4, seed0 + n++, /*minor=*/1, /*regions=*/true, 1, age, kn)`.
- **Oracles:**
  - "a family's young element changed", or TV7 (CR-037);
  - IM4, or the nursery-object abort (CR-017);
  - TSan reports.
- It is out of the default `main` run and is expected to fail today.

### Step 31: the `tenure-storm` and `tenure-storm-l3` fork arms (CR-013)

- **Config:** `Opts{regions=true, conc=true, big_arrays=6, blocks=2, tenure_b = 1 | 2 for -l3}`, with `ECO_GC_HELPER_JITTER_US=200`.
- **Hook order:** `pthread_atfork(&prepLast, …)` before `initHeap`.
- **Gang order.** The registry is stopped in registration order (M6 `two_gangs_window`), so the tenure gang must register first:
  1. warm up with regions until `R->collector` exists; set `g_gang = R->collector.get()`;
  2. then set `test_force_major_trigger_` until `OA::hasBgGang`, so the mark gang registers second;
  3. then `pthread_atfork(&prepFirst, …)`.
- **Host:** `classify = true`, `min_us = 50`, `max_us = 500`.
- **Mutator:** 400 steps. Each reassigns 2000 ring `Root`s to fresh tuples, then runs `minorGC`.
- **Child:**
  - `if (!g_r1) _exit(kClean);`: only children forked inside the window are tested;
  - storm: adopt + 2 minors + `verify`;
  - `-l3`: `exit()` under an alarm.
- **Counting:** the driver counts as CR-013 only aborts whose output contains TV1/TV3/TV6. A storm child can fork mid-pause, where `adoptThreadHeap` is unsound.
- **Registry expectation:** `flaky`.

---

## 8. Traps

**Configuration**
1. **Defaults.** `gc_thread_mode = 2`, `commit_ahead_bytes = 128 MiB` and `decommit_delay_syncs = UINT32_MAX` are the defaults, so set them explicitly. `ECO_HEAP_CONFIG` is ignored in the old gen by unit tests, and `ECO_GC_*` applies only at the first allocator init. With `--filter`, a guard may be that first init, so run in a clean environment.
2. **Sweep budgets.** `computeSweepBudgetForAlloc` never goes below `sweep_work_budget`, so set all four budgets equal. `validate()` rejects `initial_sweep_budget < sweep_work_budget`.
3. **Demote fraction.** `demote_live_fraction` must be 0 in CR-014 A and CR-028, and above 0 in CR-014 B, CR-001 and the CR-016 stash variant.
4. **Floor.** It must equal the committed heap at the major (256 K) in the Phase A sweep guards, or the reclaim releases V or D first. CR-017 R2 needs 32 K. Check `blockLive` after the major.
5. **Light gate.** `grewBag` must run **after** the major. Before it, the heavy shrink releases the added pages again.

**Reaching the tail path**

6. **M must be the last block.** Any block created or released after M before the last slice (virgin, bag, exact-size large, swap-remove) disables the tail path. Check `blockIdAt(blockCount - 1) == M`, and check `blockCount` after W1.
7. **The split rung.** Any free cell in a class at or above `num_size_classes_` lets W2's split rung serve it first. Check `noMixedOnlyCells`.
8. **Early exit.** If W2's own class list is non-empty after M's last slice, `lazySweep` returns early at `:5812`. That is why W2 uses 64 or 128 while the gaps land elsewhere.
9. **Tail vs in-loop.** B = 8 always gives the tail path, and B ≥ the remaining gap gives the in-loop path. CR-001 proves the in-loop path with `sweepCompleteDeferred`, so a tail completion there reads `kNotReached`, not a spurious result.

**Safety**

10. **Released memory.** Never pop CR-014 B's stash after the release: it would write to released memory.
11. **Headers.** `og.allocate` leaves a tag-0 header. Format every object, or a validator aborts for the wrong reason and gives a false XFAIL. Read the child's message.

**Region mode**

12. `conc_mark = 1` is synchronous. Held-marker guards need `conc_mark = 2`.
13. **Minor count.** Exactly one minor between the copy and the colouring, and none between the major and B. Assert it with `R->minor_seq`.

**TSan**

14. **Hidden HB edges.** A report disappears if the reading thread acquires `promo_mu_` or `thread_mutex_` after the writer's release. The unlocked side must do its access before any lock in that call. Keep the sides on different `shared[cls]` words, and never share `ogB` between threads.
15. **One pair per arm.** Fast-path allocations after a completion read `gc_phase_` and add a CR-001 report. Judge a fix by the stack frames, not the warning count. Run each arm 5× with `TSAN_OPTIONS=halt_on_error=0`.
16. **V11** reads every header when a slice reaches a block's end. `det-cr002` stops at cell 3 to keep CR-028 reports out.

**Fork harness**

17. **Collector first.** Minor B must not construct the collector: its constructor takes `bgRegistryMutex`, which the paused host holds (`GCHelperPool.cpp:562`).
18. **Bounded spins.** Every spin that a fix could block must be bounded (`spinFor`), so a fixed tree gives `clean`, not a 240 s TIMEOUT.
19. **Alarms.** Child alarms must be under `waitChild`'s 5000 ms.
20. **`markAtexitDone`.** Register it before `initHeap`.
21. **Pool.** Keep it off in the new arms, or CR-003's drain hangs the child first.

**Housekeeping**

22. **Core dumps.** Abort-based guards leave cores in /work (the validate unit suite writes about 20 GB). Always run them under `ulimit -c 0`.
23. **Test binaries are not in `all`.** Build `test` by name.
24. **SIGABRT counts as the defect.** An unrelated abort gives a false XFAIL. Every guard prints what it saw; check it before recording a status.

---

## 9. Gates (definition of done)

1. **Invariants.** Before any runtime edit (Steps 1, 23, 28), re-read `design_docs/invariants.csv`. The accessors and probes change no behaviour; confirm that no HEAP_*, CGEN_* or FORBID_* row is touched.
2. **Every new xfail guard reproduces today:**
   - `ECO_TEST_XFAIL=strict build/test/test --filter "xfail CR-"` fails on exactly the new guards plus the existing ones;
   - the same holds in `build-validate`;
   - the non-strict run passes.
3. **Every negative control passes** (CR-037 control, CR-017 R1 and R2 controls, `det-cr013-start-exit`).
4. **No guard reports `kNotReached`** in `build`, `build-validate` or `build-nostats` (CR-007). A NOT REACHED is a design defect in the guard: fix the scenario.
5. **The TSan arms** (Phase C) each report their named pair in 5 of 5 runs, and print REACHED.
6. **`run_fork_arms.py --tier quick`:** every `xfail` row is XFAIL, every `clean` row PASSes, and `det-cr004` is `reach`.
7. **The TLA canary is green** after the AUDIT.md entries (Step 23). The manifest is never repaired without them (GC_MODEL_001).
8. **The existing suites are unchanged:** the unit tests, `gc-heap-tsan` (default run: 0 warnings), `gc-heap-tsan pool` and `ylos`.
9. **The register is updated** (§10).

## 10. Register updates when the guards land

- **CR-014, CR-016, CR-037, CR-017, CR-001, CR-028, CR-007, CR-023, CR-012, CR-013, CR-031, CR-032:** add each guard's name to the Repro and Guard rows, and add a History line such as "Reproduced in code (…)". CR-014, CR-037 and CR-013 move from model-only to code-level.
- **CR-001:** if Step 7 (b) fails, set the severity to **S1**.
- **CR-017:** replace the "lost allocate-black bit" S1 route with §1 item 11. The S1 claim becomes the every-build abort (R1) plus an S2 race.
- **CR-037:** "at k = 1" becomes "at k = 1 and k = 2".
- **CR-016:** refine "test geometries only" to "unreachable at defaults; a non-default legacy config (unverified)".
- **CR-019:** note that no value oracle is possible (undefined behaviour only).
- **CR-013:** correct the stale lines (§1), and note that the `-minor` arms are outside the fork contract.
- **CR-012:** (d) is not TSan-visible.

## 11. Order of work

1. Steps 1–4 (infrastructure).
2. Phase A (Steps 5–13). Start with 5–7, which settle CR-014 and CR-001's severity.
3. Phase B (Steps 14–16).
4. Phase C (Steps 17–22).
5. Phase D (Steps 23–27), including the TLA canary audits.
6. Phase E (Steps 28–31).

## 12. Run commands

```sh
ulimit -c 0
cmake --build build --target test
build/test/test --filter "CR-0"                              # xfail guards pass as XFAIL
ECO_TEST_XFAIL=strict build/test/test --filter "xfail CR-0"  # every guard must FAIL today
cmake --build build-validate --target test && build-validate/test/test --filter "CR-0"
cmake --build build-nostats --target test && build-nostats/test/test --filter "CR-007"

cmake -S test/gc-heap-tsan -B build-heap-tsan -DCMAKE_CXX_COMPILER=g++ -G Ninja && cmake --build build-heap-tsan
for arm in "det-cr014-live" "det-cr001 rf inloop" "det-cr001 wf tail" "det-cr002" \
           "det-cr019 t1first" "det-cr019 t2first" "cr012 a" "cr012 e"; do
  TSAN_OPTIONS=halt_on_error=0 build-heap-tsan/gc-heap-tsan $arm > /tmp/det.txt 2>&1; echo "$arm exit=$?"
  grep -c "WARNING: ThreadSanitizer" /tmp/det.txt; grep -E "REACHED|NOT REACHED" /tmp/det.txt; done
build-heap-tsan/gc-heap-tsan promo 1 40 4 0 0 8 1 2>&1 | tail -3
timeout 3600 build-heap-tsan/gc-heap-tsan lbaba 200 1

cmake -S test/gc-heap-tsan -B build-fork-trace -G Ninja -DCMAKE_CXX_COMPILER=g++ -DECO_TLA_TRACE=ON
cmake --build build-fork-trace --target gc-fork-trace
build-fork-trace/gc-fork-trace det-cr013-l3-exit 3 1         # FORK_HARNESS_BT=1 for stacks
python3 test/gc-heap-tsan/run_fork_arms.py --tier quick
ECO_TEST_XFAIL=strict cmake --build build --target register-guards
```

---

## 13. As built (2026-09-30)

Every step is implemented. Every deterministic guard and arm reproduces its defect on the tree of 2026-09-30. No runtime defect was fixed.

The only runtime changes are:
- the Step 1 test accessors;
- the Step 23 trace-only probes;
- the Step 28 stats-only counters.

Snapshot of the tree before the change: `snapshots/register-repros/pre-impl-2026-09-30.tgz` (git is unusable in this worktree).

### 13.1 Results

**Unit guards** (`build/test/test --filter "CR-0"`, and the same in `build-validate`):
- 29 of 29 pass in both builds: 21 xfail guards and 3 negative controls among them.
- Under `ECO_TEST_XFAIL=strict`, 20 of 21 fail in `build`. The one pass is CR-028, which skips outside validate builds. All 21 fail in `build-validate`.
- No guard reports NOT REACHED.
- Defect lines:

| Guard | Defect line |
|---|---|
| CR-014 A (N=2, N=1) | `detachFromAllocation` FATAL |
| CR-014 B | D released while the stash holds its cell |
| CR-001 (a) | `live_bytes` reads 0 |
| CR-001 (b) | D released with a promoted object: **S1** |
| CR-016 chunk and stash | V or D flipped to large |
| CR-028 | V11 parse breaks (validate) |
| CR-037 k=1, k=2 | age 0, slot unhealed |
| CR-017 R1 | IM4 (validate), "parallel marker reached nursery object" (release) |
| CR-017 R2 | a mark bit on a free cell of a post-t0 block |
| CR-007 | 201 ms stall |
| CR-023 | F still blocked after 200 ms |
| CR-012 (a)–(d) | the four value oracles |

**TSan arms** (`build-heap-tsan`): each arm printed REACHED and reported its named pair on 25 of 25 runs:
- `det-cr014-live`;
- `det-cr001` in all four variants (rf/wf × inloop/tail);
- `det-cr002`;
- `det-cr019` in both orders;
- `cr012 a` and `cr012 e`.

The default run, `pool` and `ylos` still report 0 warnings.

**Fork arms** (`run_fork_arms.py --tier quick`): 10 XFAIL and 3 PASS (`mut`, `det-cr004` reach, the `det-cr013-start-exit` control). Every `det-*` arm reproduced in 3 of 3 trials.

**Stress arms:**
- `promo` tail mode: 35-39 tail hits per run. The tail path had never been reached under stress before.
- `promo` exact arrays: heap corruption in 4 of 7 runs.
- `lbaba`: IM4 on seeds 1 and 7 (CR-017), TV7 on seed 20 (CR-037).
- `tenure-storm` and `tenure-storm-l3`: 37 and 49 fork-window hits, 0 hits mid-item. These are flaky rows and never gate.

### 13.2 Deviations from §§1-7

1. **CR-017 R2 geometry** needed three changes:
   - `demote_live_fraction = 0`, or the sweep overwrites c's image;
   - the first page is pinned by a rooted 24 KiB object, because `acquireOldGenBlock` never reuses `heap_base`;
   - three dead filler pages on each side of P, then the free-extent list reordered (acquire/release) so the trigger minor's tenure grants do not take P before t0.

   The page state itself (released, then re-issued after t0) arises naturally.
2. **CR-012 needs `nursery_max_block_count = 8`** in the unit guards (4 in the TSan arm). Otherwise heap B aborts with "nursery slice slots exhausted", which at first read as a false XFAIL.
3. **`abortMeansNotReached()`** now installs a SIGABRT handler in every value-oracle guard (CR-007, CR-023, CR-012), so an unrelated abort can never count as a reproduction.
4. **CR-007 needs `pool.drain()` before `pool.shutdownForTesting()`.** `FnJob` is copied exactly from `GCHelperTest.cpp`: `HelperJob` holds a function pointer, not a virtual.
5. **Extra preconditions:**
   - CR-014 B: `!sweepCompleteDeferred` (proves the tail path);
   - CR-016 chunk: w0's cursor still holds V;
   - CR-037: the string is a `LargeStringHeader`, and B's slot is in the nursery;
   - CR-028: `blockCount == 2`.
6. **`commit_ahead_bytes = 0`** is also set in `tailConfig` and `cr016Config`.
7. **`det-cr014-live`:** an extra class-16 block I between U and M. T1 makes one allocation from it under `promo_mu_`, so its later fast paths do not add a CR-001 report.
8. **`det-cr019`:**
   - It re-maps Y's page with `MAP_FIXED` to reset TSan's shadow. TSan's four shadow slots per word evicted the pair in about 1 run in 5.
   - The empty class is chosen after the pre-sweep (it was 248).
   - The frame is at `AllocatorCommon.hpp:449`.
9. **Tail mode (Step 29)** replaces the `partial_` prefill (0 hits) with a main-thread pre-sweep that leaves exactly one slice. It also needs `max_heap_size = 256 MiB`, because the 32 MiB floor must lie below the old-gen region.
10. **Another tail-path requirement:** the slice's gap must not push a cell of the sweeper's own class. The early exit at `:5812` comes before the budget check.
11. **`det-cr013-copy`** pauses only when the copy in flight is o's (`copyIsO()`), because the order of the starts comes from an `unordered_set`.
12. **`gc-fork-trace` links `TlaTrace.cpp` first.** Before this, the recorder's statics died before `~Allocator` and crashed the `-exit` children.
13. **Storm arms** use `o.pool = false`.

### 13.3 Pre-existing issues found (not caused by this work)

- **`build-nostats`:** the unit test binary does not compile. `EcoApplyClosureTypedTest.cpp`, `GCPressureTest.cpp`, `P1CensusTest.cpp` and `GCHelperTest.cpp` use stats-only APIs. CR-007 and CR-023 were checked there through a one-off driver.
- **`promo_sweep.cpp`** already needed stats (`NurserySpace::getStats`).

### 13.4 TLA canary

The accessors, probes and counter fire 12 pins, audited under GC_MODEL_001: the M2, M4, M5, M6, M7 and M8 AUDIT.md files and `test/genmc/AUDIT.md` each have an entry dated 2026-09-30. None adds an atomic step, lock, shared location or memory order to a production path:
- the probes only call a harness callback, and emit no event;
- the counter sits inside `#if ENABLE_GC_STATS`, in the same `promo_mu_` section as an existing stats write;
- `promo_sweep.cpp`'s trace section (`promoTraceMain`) is byte-identical.

### 13.5 Gap guards (2026-09-30, second round)

This round covers the model counterexamples the first round left out or reproduced only in part. Changes are in `ConcurrencyRegisterTest.{cpp,hpp}` and `test/main.cpp`: 8 new xfail guards and 4 negative controls. Nothing changed in the runtime, and no accessor was added, so the canary is untouched.

**Results:**
- `--filter "CR-0"`: 41/41 pass in `build` and in `build-validate`.
- Strict mode: all 29 xfail guards fail in `build-validate`. In `build`, 28 of 29 fail; the exception is CR-028, which skips outside validate builds.
- Snapshot of the tree before this round: `snapshots/register-repros/pre-gaps-2026-09-30.tgz`.

**The new guards:**

| Guard | Model row | Defect line |
|---|---|---|
| CR-014 C | M4 `sweep_tail_reuse` | same address handed out twice; W2's object overwritten |
| CR-017 R1 (k=2) + control | M5 `deep_boundary_k2_cr017` | IM4 / `parallel marker reached nursery object` |
| CR-033 parse + control | M8 `cr033` | page no longer parses by object size |
| CR-033 legacy S1 + control | M8 `cr033` | the next page's header is overwritten |
| CR-035 stale index | M8 `cr035` | two YLOS index entries name one address |
| CR-035 lost | M8 `cr035_lost` | a live object is freed |
| CR-036 witness | M8 `reissue_witness` | same id, start and class re-issued |
| CR-038 witness + control | M5 `k2_ylos_walk` | the snapshot walked a dead Y whose slot points into a retired extent |

**Notes:**
- **CR-014 C needs a second release in the same shrink.** A dead large block Lg sits below D, so its id tops the LIFO stack. Once the bag is emptied, D's extent is first-fit.
- **CR-036's guard will not flip by itself when its fix lands.** It must be extended once a per-id generation counter exists.

**Remaining model counterexamples with no code repro:**
- M2 `quick_wrap`: a benign witness (MAPPING.md §6).
- The fix-candidate controls and the mutants: by design.

### 13.6 `register-guards` covers every guard (2026-09-30)

`cmake --build build --target register-guards` now runs `test/scripts/run_register_guards.sh`. The script runs three steps, keeps going after a failing step, and prints a combined summary:

1. **The unit xfail guards:** `build/test/test --filter "xfail CR-"`.
2. **The validate-only guard CR-028:** run in `ECO_REGISTER_VALIDATE_DIR` (a cache path, default `build-validate`). The script configures that tree with `ECO_HEAP_VALIDATE=ON` if it has no cache, and refuses a tree that is not a validate build.
3. **`run_fork_arms.py --tier quick`**, which now also has a `tsan` flavour: the 10 deterministic TSan race arms, as rows of `fork_arms.txt`.

How a `tsan` row is run:
- `gc-heap-tsan` is built in the same plain tree. Arm arguments are joined with `:` (for example `det-cr001:rf:inloop`).
- The runner runs the row's `trials` itself, with `TSAN_OPTIONS=halt_on_error=0`.
- A trial counts as reproduced only when it prints REACHED, exits 66, **and** the report names the row's `match=` function. Negative control: `det-cr002` with `match=noSuchFunction` gives ERROR, not XFAIL.

The sub-project also has a new `tsan-det` target for those arms alone.

**Results:**

| Mode | Unit guards | CR-028 (validate) | Harness rows | Target |
|---|---|---|---|---|
| default | 29 of 29 pass as XFAIL | XFAIL | 20 XFAIL (10 fork/trace, 10 TSan, each TSan row 3/3) + 3 PASS | green |
| `ECO_TEST_XFAIL=strict` | 28 fail (CR-028 skips outside validate) | fails | 20 FAIL + 3 PASS | red, "open register defects reproduce" |

### 13.7 CR-039: the wider CR-038 variant (2026-09-30, register-fixes Step 0.4)

M5 `MC_k2_ylos_walk2` (`YC = 2`) violates `T0GreyAllocated`, so the wider variant was registered as
CR-039 and given a code guard, `cr038Z` (`ConcurrencyRegisterTest.cpp` `cr038ZScenario`), modelled
on `cr038`:

| Guard | Model row | Defect line |
|---|---|---|
| CR-039 `[xfail CR-039]` + control (Z live) | M5 `k2_ylos_walk2` | at minor 4's t0 the snapshot walked the dead Y; Z is FREED (Tag_Free, unindexed) and MARKED by t0 |

The guard does not install `abortMeansNotReached`: a validate abort on the way (IM4/IM6) is the
defect, as for CR-017. The control roots Z, so only Y dies: the same walk marks an allocated Z.
