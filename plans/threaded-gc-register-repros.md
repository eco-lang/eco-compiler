# Threaded GC: code-level reproductions for the open register entries

**Status:** design, 2026-09-30. Nothing here is built yet. **Superseded in detail by
`plans/threaded-gc-register-repros-impl.md`**, which corrects this design in places (its §1).
**Companion to:** `plans/threaded-gc-concurrency-register.md`. Status changes are recorded there, not here.

**Aim.** Give every open entry a C++ test that forces the faulty state the TLA+ models found:
- deterministic paths first;
- stress strategies that raise the hit rate second.

Line numbers are from the tree of 2026-09-30. Some register entries cite stale lines; this file gives the current ones.

## 0. Enablers shared by many tests

1. **Driving the promotion workers from a single thread.** One thread can call `beginParallelPromotion(ctx, n)`, `allocatePromotion(ctx.w[i], size, false)` and `endParallelPromotion(ctx)`. This is the `PromoBufferTest.cpp:129-192` pattern.
   - It gives full control of the interleaving between workers, one call at a time.
   - CR-014, CR-016, CR-001 (its S1 half) and CR-028 need **no new runtime seam**.
2. **The xfail harness.** Deterministic guards go in `test/allocator/ConcurrencyRegisterTest.cpp`, using `runXfailGuard`.
   - Each scenario returns `kDefect` or `kNotReached`. A SIGABRT counts as the defect.
   - `ECO_TEST_XFAIL=strict` flips the result.
   - Every scenario asserts its precondition and returns `kNotReached` if it was missed, so a guard can never pass vacuously.
3. **TSan pairs need real threads.** Order the threads only with a `memory_order_relaxed` flag and a spin, never with a mutex or acquire/release. TSan derives no happens-before edge from relaxed atomics, so it reports the pair on every run, whatever the timing.
4. **Small test accessors on `OldGenSpaceTestAccess` / `AllocatorTestAccess`:**
   - `freeListContains(og, cls, BlockId)`
   - `promoMuHeld()` (a `try_lock` probe)
   - access to the private `acquireOldGenBlock`, `releaseOldGenBlock` and `onGCPauseEnd`
   - a way to empty `unassigned_blocks_`
   - `adoptThreadHeap(a, h)`, which sets `tl_heap_` in a forked child
5. **New trace-build probes** (compiled out otherwise; CR-013 only): `m5.item.taken`, `m5.item.copied`, `m5.l3.claimed`.
6. **Wiring.** Today `gc-fork-harness`, `gc-fork-trace` and all the `det-*` arms are `EXCLUDE_FROM_ALL` with no `add_test` (`test/gc-heap-tsan/CMakeLists.txt:53,61`). Add a target that runs every `det-*` arm and every expected-fail row.

## 1. Can lose or corrupt a live object (S1)

### CR-014: `lazySweep`'s tail completion runs `onSweepComplete()` inside a parallel minor

**Faulty state (M4 `sweep_tail*`).** A worker completes the sweep on the tail path (`OldGenSpace.cpp:5829-5843`) and runs the light shrink. Meanwhile either:
- another worker's Current block reads `live_bytes == 0` because its pending bytes are unflushed; or
- a stash holds a cell of an all-dead block.

**Shared config.**
- `old_gen_bitmap_alloc=1`, `alloc_buffer_size=64K`, `decommit_on_oldgen_release=0`, `gc_thread_mode=0`.
- `incremental_mark=0`, `conc_mark=0`, `small_class_heap_budget_bytes=0`, `demote_live_fraction=0`, `minor_sweep_divisor=0`.
- All four sweep budgets set to 8 bytes. The budget is checked only at the loop head (`:5682`), so each slice covers one gap and one object.
- `initial_old_gen_size` = the committed size at the major (the floor, `:6595`).
- `ensureOldGenCapacityFor` after the major, so the light-pass gate at `:6134` opens.

**The tail path is reached only when all three hold:**
- the last block in `blocks_` order is the unswept mixed block M, so no block may be created during the minor;
- the last slice ends exactly at M's end;
- the sweeper's class list is still empty (otherwise it returns early at `:5812`).

**Scenario A: the FATAL.**
1. Allocate V first with `og.allocate(32)`, unrooted. Then allocate M: four rooted 16 KiB ByteBuffers with `large_object_threshold=8K`.
2. Run `majorGC`. Check that V is live, uniform and Queued.
3. Sweep until `getSweepCursor == m[3]`.
4. `beginParallelPromotion(ctx, 2)`.
5. W1 promotes one class-A object: V becomes Current with `live_bytes == 0`.
6. W2 promotes 64 bytes. Its slice completes on the tail path. The shrink's pass 1 (`:6172`) picks V, and `detachFromAllocation` FATALs (`:759-764`).

- **Oracle:** SIGABRT `[gc] FATAL: detachFromAllocation(..) during a parallel minor`, in every build.
- **N = 1 variant:** the same steps with one worker. The tail path skips `sweepCompleteInPromotion`'s cursor hand-back (`:1470`).

**Scenario B: silent release, then address reuse (ABA).**
1. `large_object_threshold=32K`. Allocate three 40 KiB bag objects D, D', M; only M is rooted.
2. Sweep D and D'. `free_lists_[8K]` is now [D'-cell, D-cell], because the list is LIFO.
3. W1 promotes 8K. The batch pop (`:1748`) finalizes the D'-cell while Sweeping and stashes the D-cell.
4. W2 promotes 64 bytes. The tail completion releases D, and `virgin()` (`:1451`) re-issues D's id.
5. W1 promotes 8K again. It pops the stashed cell into D's old extent (`:1708`).

**Oracles:**
- `!blockLive(D)` right after step 4, or D's id now names a class-C block;
- W2's object overlaps W1's, so the fill is corrupted;
- otherwise, run `endParallelPromotion`, force D's start to be reused, and read back the promoted object's fill.

**The `live_bytes` race (`NoRaceLive`, S2).** Scenario A's layout on two `std::thread`s in a new gc-heap-tsan scenario. V keeps some live cells so it is not released.
- W1 exhausts a chunk and hits `flushCursorW`'s `fetch_add` (`:1086`).
- W2 does the tail completion (`computeFragmentationStats` `:6751`, pass 1).
- Order them with a relaxed handshake.

**Stress fallback.** `promo_sweep.cpp` has never reached `:5832` (0 hits in 4 gdb runs), because virgin blocks land after the unswept ones. To fix that:
- allocate a rooted bag-page object last before each major;
- pre-fill `partial_` for every promoted class;
- use `sweep_bytes=8`;
- count hits via the `m4.swend path 3` probe.

### CR-016: the empty-block flip takes a block a worker is still using

**Faulty state (M4 AUDIT:112-121).**
- **`minor_large` (chunk variant):** W1's claimed chunk of V is unflushed, so `live_bytes == 0`. W2 retires V (`advanceSharedW` `:1315` → `kAllocNone`), and its exact-size promotion flips V (`allocateFromEmptyRegularBlocks` `:2855`).
- **`sweep_large` (stash variant):** the same, but through a stash.

**Deterministic chunk variant.**
- **Config:** `promoConfig()` plus `alloc_buffer_size=32K`, `old_gen_bitmap_alloc=1`, and the default small-class budget (so a virgin block comes first). With `s=512`, one chunk of 64 cells is the whole block.

**Steps:**
1. `begin(2)`.
2. `p0 = w0.alloc(512)`. Check `cellsIn(V) == 64`, `live_bytes == 0` and `fully_swept`.
3. `w1.alloc(512)`. Check V is `kAllocNone` and that p1 is in a new block.
4. `big = w1.alloc(32K)`, filled with `0xEE`.
5. `p2 = w0.alloc(512)`, served from the stale cursor.
6. `end`.

**Oracle:** any of `big == V.start`, `p2 ∈ [big, big+32K)`, or a damaged fill. A validate build may also abort on PM6.

**Stash variant.** Build D the way CR-018's test does (a mixed or demoted block, all dead, floor held), and use the `freeListContains` accessor to check the precondition. Then:
1. w1 batch-pops D's cells into its stash;
2. w0 promotes 32K and flips D;
3. w1 pops from the stash into the large object.

**Stress fallback.** `gc-heap-tsan promo <seed> <rounds> 4+ <jitter> 1`, with the exact-size Array always added (`promo_sweep.cpp:269` currently adds it only half the time).

**Reachability.**
- **Default config:** unreachable. The region nursery's placement cap is `largestClassBytes`, and the legacy cap is 128 KiB, both below the 512 KiB block.
- **Correction to the register:** "test geometries only" is too narrow. `nursery_regions=0` with `large_ptr_nursery_max_size ≥ block` and a nursery of 4 MiB or more should reach it at 512 KiB blocks. This is unverified.

### CR-017: the t0 young walk greys cells a STW major freed

**Existing guard.** `cr017Scenario` k=1 and k=2 show the grey on a freed cell.

**The S1 route is wrong as the register states it.**
- The owner's `setBit` (`BitmapScan.hpp:34`) is a plain byte RMW. The parallel marker uses `atomic_ref::fetch_or` (`OldGenSpace.cpp:3299`).
- When they race, the owner's write-back can erase only the **marker's** bit, never the owner's allocate-black bit.
- In a block issued after t0, every live cell is already allocated black, so losing a marker bit there is harmless.
- The race is S2 (undefined behaviour). "Free a live copy" would need the `test_plain_bits_parallel_` mutant.
- **Action:** reword the register entry.

**Scenario R1: every-build abort, deterministic** (M1 `MC_quick_region_reuse`, M5 `MC_cycle_major_t0grey`).
- **Config:** `cr017Config(1)` (`conc_mark=1`). Use CR-037's equal-size body trick: the dead header's own body is the freed cell.
1. `holdNextCycle` (`test_bg_hold_`).
2. Force the major trigger and run a minor, so t0 greys X.
3. Check `isMarked(X)` and that the mark stack is non-empty.
4. Allocate e, then a same-size YLOS B at X. Require `resolve(B) == X`.
5. Release the hold and `waitBackground`, with no minors in between.

**Oracles:**
- validate builds: IM4 "allocation into a MARKED cell" at step 4 (`:5118`);
- release builds: "[gc] parallel marker reached nursery object" (`:3326`).
- **Negative control:** `test_snapshot_skip_young_walk_`.

**Scenario R2: the block released after the major and re-issued.**
1. c is an old Tuple2 pointing to d, with d a 12.8 K object alone in a bag page; both are reachable only from the dead x.
2. The major frees both.
3. With the marker held, allocate until a block materialises at d's page. Check it is not a t0 block.
4. Release the hold.

**Oracles:** a mark bit on a free cell or a mid-cell bit (V8/`AllocMapExact` at the next sweep); TV8 if the block is a tenure grant; TSan on `fetch_or` vs `setBit` if cursor cells are allocated after the release.

**Stress fallback.** gc-heap-tsan `region-b2` with:
- `cycle_every` 2-4;
- idle majors every 3;
- 8 nursery blocks;
- dying old families plus a same-size YLOS churn;
- jitter;
- k ∈ {1, 2} × 1-4 background threads.

### CR-037: hand-over `lb_bodies` colouring hides a new YLOS at a reused address

**Faulty state (M5 `MC_lb_aba`).**
1. A dead string's body address X is in `lb_bodies`.
2. A STW major frees X.
3. A new YLOS B pointing to a young e is allocated at X.
4. The prep's `markLargeBodySeen` (`NurseryRegion.cpp:750-753`, `OldGenSpace.cpp:7559`) colours B.
5. B's first reach returns "already reached" (`:528`), so e is lost with eden.

**Deterministic, single thread.**
- **Config:** `cr017Config(k)` or `tenureConfig(1)`: LOT 8K, `alloc_buffer_size` 32K.
- **Equal sizes for address reuse:** `ElmArray` n=1600 is 16 + 8n = 12,816 bytes, and `ElmString` L=6404 is 8 + 2L = 12,816 bytes. Both go through `allocateFromBagPage`'s reuse ladder (as in `testTenureYlosCellReuse`).

**Steps:**
1. Allocate a rooted string first (so its body starts a fresh bag page). X = its body.
2. `minorGC`: X joins `lb_bodies`.
3. Drop the root, `majorGC`, `driveSweepToCompletion`. Check there is no index entry at X.
4. With no minor in between, allocate e = `allocInt(0xE37)` and B = an array of 1600 × e. Require `resolve(B) == X`.
5. `minorGC`.

**Oracles:**
- `getHeader(B)->age == 0` (a reached YLOS has age 1);
- `B->elements[0]` unchanged (the slot was not healed);
- overwrite eden, then check e's value;
- validate builds: TV7 / HEAP_044 after a further minor and major.

**Negative control:** `ns.test_no_body_remark_ = true`.

**If the bag-page reuse misses:** use sizes of 32K or more (`is_large` blocks are reused at their start), e.g. n=4500 and L=18004.

**Stress fallback.** `heap_driver.cpp`:
- `major_every` currently fires only while a cycle runs (`:68`, `:317`); add an idle-major knob;
- add a family of dying large strings the same size as the YLOS families;
- use a small nursery.

## 2. Data races (S2)

### CR-001: `gc_phase_` race, and the moved decision point

- **Race half:** already reproduced by TSan `promo` and GenMC `w3d`.
- **S1 half, deterministic:** CR-014 scenario B plus a trailing uniform block T after M. W2's first slice therefore does not complete. Its second completes **in the loop** (`:5590`), which goes to `sweepCompleteInPromotion` and is deferred. W1 then finalizes its stashed D-cell and reads Idle (`:1130`).

**Oracles:**
- **(a) the recount check:** `metaOf(D).live_bytes == 0` although the cell was popped while Sweeping. This holds regardless of the shrink.
- **(b)** `endParallelPromotion` releases D; read back the promoted object after the address is reused.

This settles whether CR-001 is S1. A relaxed-atomic `gc_phase_` still fails oracle (a), which matches M4's `phase_atomic_release`.

### CR-002: gap sweep's plain word read vs `fetch_or`

- **Status:** already TSan-reproduced every run. The functional effect is benign (a lost bit behind the cursor), so there is no single-threaded oracle.
- **Deterministic TSan pair:**
  1. Demote a class-32 block with alternating live/dead cells (`demote_live_fraction=0.6`), and use 8-byte slices.
  2. W1 batch-pops the gap cell that shares a 64-bit word with the next live bit.
  3. W2's next slice runs `nextSetBit`/`clearBit` (`:5685`, `:5713`).
  4. Order them with a relaxed handshake.
- **Optional seam:** a hook at `:1767`, between the unlock and `finalizePoppedCellW`.

### CR-028: the validate-only V11 header walk vs a worker's popped cell

- **Deterministic, single thread, validate build:**
  1. W1 pops the first flushed gap cell of mixed block M and writes the body only, as `copyClaimed` does (`NurseryParallel.cpp:302`). The body bytes at offset 16 decode as a `Tag_String` with a huge size.
  2. W2 sweeps to M's end. The V11 walk (`:5789`) reads the fake header.
- **Oracle:** SIGABRT `[heap-validate] lazySweep: V11 ... parse breaks`.

### CR-019: legacy YLOS header written under `ylos_mu_`, read by a sweep under `promo_mu_`

- **Status:** TSan `ylos-sweep` hits it every time at 1024 and 4096 B slices, but only 3/10 at 144 B. The misses come from happens-before edges that `promo_mu_` creates.
- **Deterministic `det-cr019` arm** (`ylos_sweep.cpp` config):
  1. Allocate one 3 KiB YLOS Y and run a STW major.
  2. `begin(2)`.
  3. T1 calls `og.promoteYoungLarge(Y)` (`:7509`).
  4. After a relaxed flag, T2 calls `allocatePromotion` → `sweepOnDemandAllocate` → `lazySweep`, which reads Y's header.
  5. Run both orders.
- **No value oracle exists.** The tag and size bits are rewritten unchanged, so the race is undefined behaviour only. Note this in the register.

### CR-012: more than one mutator (needs a decision: support or forbid)

Unit tests with two `ThreadLocalHeap`s on two threads, following the `trialTwoHeap` pattern:
- **(a)** A's `acquireOldGenBlock` writes `old_gen_in_use_bytes_` under the lock; B's `cyclePressureFinishDue` reads it unlocked (`OldGenSpace.cpp:4524`). TSan plus a GC_DET_001 value oracle: B's decision flips because of A's allocation.
- **(b)** Shared free list: B releases block X, and A acquires X.
- **(c)** Shared decommit clock: with `decommit_delay_syncs=4`, B's pauses post the discard of A's extent.
- **(d)** B's `acquireOldGenRegion` (`Allocator.cpp:1002-1029`, `MAP_FIXED`) overwrites A's commit-ahead window. Check with `mincore` that the window was resident and is not afterwards.
- **(e)** Validate builds: `validatePageWork` reads B's tables while B runs `materializeVirginBlock`.

**Stress fallback:** a `two-heap` gc-heap-tsan arm (`trialTwoHeap` without forks) with the pool knobs.

## 3. Liveness (S3)

### CR-007: a `promo_mu_` holder blocks on a helper discard job

- **Deterministic unit test.** Config: `promoConfig()` plus `gc_thread_mode=2`, `gc_helper_threads=1`, decommit on, `decommit_delay_syncs=0`, `commit_ahead_bytes=0`.
  1. Empty `unassigned_blocks_`.
  2. Acquire and release block b.
  3. Post a test `FnJob` that blocks on latch L.
  4. `onGCPauseEnd` queues b's Discard job behind the blocker. Check that b is `kPostedDiscard`.
  5. Two `GCMarkGang` members: member 1's `allocatePromotion` reaches `onReuse` (`:799`) → `GCHelperPool::wait` while holding `promo_mu_` and `thread_mutex_`. Member 0 then promotes.
  6. Hold for H = 100 ms, then release L.
- **Oracles:** `w[0].mutex_wait_ns ≥ H`, pool `stall_max_ns ≥ H`, `reuse_waits == 1`.
- **Fix criterion:** never wait under `promo_mu_`; the guard then XPASSes.

### CR-023: a foreign `stopAndJoin` waits out a relaunched episode

- **Deterministic unit test of `GCBackgroundGang` alone:**
  1. Create a gang with one member and `launch(fn1)`.
  2. Thread F calls `stopAndJoin`. After `memberTids()` returns, F is in `cv_done_.wait` (`:688`).
  3. Park F with `pthread_kill` and a handler that blocks in `sem_wait`.
  4. The owner reaps and runs `launch(fn2)`, where fn2 blocks on latch L2.
  5. Unpark F.
- **Oracles:** F is still blocked after 100 ms; `stop2` is unset; `launches == 2`.
- **Second arm:** fn2 waits on the owner, which turns the stall into a deadlock.

## 4. Fork and exit (S4)

**Existing deterministic arms:**

| CR | Existing arm | Gap |
|---|---|---|
| 003 | `det-cr003` (probe `m6.pool.drained`), 5/5 | not wired |
| 005 | `det-cr005` (probe `m6.closing`) | not wired |
| 015 | `det-cr015` (probe `m6.post.cas`), 5/5 | not wired |
| 031 | `host-exit` only, 0.7 % of children | **needs a deterministic arm:** a probe inside `RootSet`'s rehash; the host forks; the child calls `exit()` |
| 032 | `host` with `FORK_HARNESS_CENSUS=1` | **needs a deterministic arm:** a probe in `p1::recordPromoted` while it holds the census mutex |

### CR-013: tenure-collector fork window, three ways

**The premise holds in code.**
- `atforkPrepare` (`GCHelperPool.cpp:735-744`) stops the gangs, then locks each gang's `m_`. `launch()` needs only `m_`, so a relaunch fits between the two.
- The member runs its function outside `m_` (`:648`), so the lock succeeds mid-item.
- `stop` is checked only between items (`TenureWork.hpp:218-235`).
- The existing per-item sleep sits between items, so it cannot open the window. New probes are needed.
- The fork harness sets `nursery_regions=0`, so the tenure collector has **zero** code-level coverage today.

**Shared `trialDetCr013(way)` (trace build).**
- **Config:** as in `tiny_tenure.cpp:127-148`: `nursery_regions=1`, `tenure_mode=2`, k=1, `tenure_help=1`, no marking, `gc_thread_mode=0`. Collector threads: 1 for ways 1 and 2; 2 with `minor_parallel_min_bytes=0` for way 3.

**Steps:**
1. Run two warm-up minors, so the collector's constructor has taken `bgRegistryMutex` already.
2. Set up root1 → o and root2 → p with p.a = o, then run one minor.
3. The host pauses at `m6.bg.stopped` (det-cr004's seam).
4. The mutator's minor relaunches. The member hits the new probe and spins.
5. The host forks.
6. The child runs `adoptThreadHeap`, then acts per way.
7. The parent's `verify()` is the control.

| Way | Probe | Child | Oracle |
|---|---|---|---|
| lost start | `m5.item.taken` (`TenureWork.hpp:316-319`, after `next_start++`) | minor | "TV1: resolve found no forwarding" (`NurseryRegion.cpp:370`, every build). Sub-arm `-exit` is expected clean (the teardown merge uses `heal=false`) |
| double copy | `m5.item.copied` (between `:276` and `:277`) | minor | TV3/TV4 at the merge (`NurseryTenure.cpp:737`, validate). Variant `-scan` (probe before `scanCopy`, `:311`): TV6 / TV1 |
| L3 hang | `m5.l3.claimed` (`NurseryTenure.cpp:1018-1020`) | `-exit`: `exit()` under `armAlarm(4)`; `-minor`: minor | `kHangDtor` (15), stack ends in `waitPublished`; `kHangHeap` (13) |

**Stress fallback: `tenure-storm` arm.**
- thousands of rooted young tuples per minor, `nursery_block_count=2`;
- construct the tenure gang **before** a slow 5c mark gang (`conc_mark=2`, `big_arrays`). The registry is stopped in order, so the tenure gang's window stays open while the mark gang drains (M6 `two_gangs_window`);
- jitter of about 200 µs, and host forks every 50–500 µs;
- count window hits via `prepFirst`/`prepLast`.

## 5. Register corrections found while designing

- **CR-017:** the lost allocate-black bit is impossible (see §1). The S1 claim needs rewording. The certain effects are the every-build abort (R1) and an S2 race.
- **CR-016:** "test geometries only" should read "non-default nursery config"; that reachability is still unverified.
- **CR-019:** no value oracle can exist, because the bits are rewritten unchanged. The defect is undefined behaviour only.
- **CR-013:** the cited lines are stale. The current ones are `NurseryTenure.cpp:598` (launch), `:643-660` (orphan join) and `TenureWork.hpp:218-235, 316-319`.

## 6. Suggested order

1. Single-thread, no-seam S1 guards: CR-014 A and B, CR-001 (a), CR-016 (chunk variant), CR-037, CR-017 R1. One file, and they settle the open severity questions.
2. CR-028 (validate) and CR-007 / CR-023 (latch-based stalls).
3. The relaxed-handshake TSan pairs: CR-014 `NoRaceLive`, CR-001 race, CR-002, CR-019, CR-012 (a)–(e).
4. CR-013 probes and `det-cr013-*` arms; `det-cr031` and `det-cr032`; wire every `det-*` arm into a target.
5. The stress changes, last.
