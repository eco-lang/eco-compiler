# Heap-level TSan harness (threaded-gc-05c D9)

The real allocator (`runtime/src/allocator/*.cpp`, validate + stats on) under
g++ `-fsanitize=thread`, driven by `heap_driver.cpp`: an old graph plus a
churning set of rooted young, large-string and replaced values; a cycle is
forced every ~40 minors with `conc_mark = 2` (B = 2/4/3, T = 4/16/8, assist
lag 1) so background markers overlap minor GCs, promotions (allocate-black)
and assists. Every rooted value is checked periodically. The default run is
the nine `gc_thread_mode = 0` scenarios (legacy serial and parallel minors,
region nursery) plus two with the helper pool and young large object families
on (the `pool` arm's knobs, below: one legacy parallel-minor, one region).

```bash
cmake -S test/gc-heap-tsan -B build-heap-tsan -DCMAKE_CXX_COMPILER=g++ -G Ninja
cmake --build build-heap-tsan
timeout 3600 build-heap-tsan/gc-heap-tsan 2>&1 | tee /tmp/heap_tsan.txt
grep -c "WARNING: ThreadSanitizer" /tmp/heap_tsan.txt     # must print 0
ECO_GC_HELPER_JITTER_US=50 build-heap-tsan/gc-heap-tsan  # jitter arm
```

## Register arms: the helper pool (CR-006), young large objects (CR-020, CR-019)

```bash
build-heap-tsan/gc-heap-tsan pool [jitter_us [first [count]]]
build-heap-tsan/gc-heap-tsan ylos [jitter_us [first [count]]]
build-heap-tsan/gc-heap-tsan ylos-sweep [seed [rounds [workers [jitter_us [age [sweep_bytes]]]]]]
```

`pool` and `ylos` run the default run's nine scenarios (or `count` of them from
index `first`) with extra knobs; `jitter_us` sets `ECO_GC_HELPER_JITTER_US`
before the allocator's first `initialize` (pool jobs, mark gang, background
gang and tenure collectors sleep a random [0, n) µs).

- **Families** (`Knobs::ylos_every = 2`, both arms): every second step a
  pointer-bearing Array of 8.1-48 KiB (above `large_object_threshold`: legacy
  mode puts one up to 12 KiB in the nursery and the rest in the YLOS, region
  mode puts all of them in the YLOS; a mixed bag page below 32 KiB, a large
  block above) whose elements point at eight young Ints, at old Tuple2s and at
  the previous family's Array, under eight young Tuple2 parents that are each a
  RootSet root. A parallel minor deals the roots' grey entries round-robin to
  the gang, so several workers reach one Array in the same minor
  (`reachYoungLargeP` / `reachYoungLargeR` under `ylos_mu_`); 16 families live
  at a time and every one is checked every 25 steps.
- **Pool** (`Knobs::pool`, the `pool` arm only): `gc_thread_mode = 2`, two
  helper threads, `decommit_on_oldgen_release` on with a released extent's
  Discard job posted at the next pause end (`decommit_delay_syncs = 0`), and a
  1 MiB commit-ahead window (a Populate job per 2 MiB granule). The families'
  promoted Arrays become old garbage that the post-sweep shrink releases, so the
  pool gets 26-38 Discard jobs and 7-11 Populate jobs per scenario.

| Arm | Command | Register | Expected |
|---|---|---|---|
| pool | `gc-heap-tsan pool` | CR-006 | `heap_driver pool PASS`, 0 TSan warnings |
| pool, jitter | `gc-heap-tsan pool 50` | CR-006 | as above |
| pool, long jitter | `gc-heap-tsan pool 20000 3 2` | CR-006, CR-007 | as above; about 21 reuses per scenario wait on a posted Discard job, about a third of them in a parallel minor on a promotion worker holding `promo_mu_` (`ladderFrom2W` → `startVirginBlockShared` → `acquireOldGenBlock` → `PageWork::onReuse` → `GCHelperPool::wait`: CR-007's stall; seen on gang member 0, the mutator thread) |
| ylos | `gc-heap-tsan ylos` | CR-020 | `heap_driver ylos PASS`, 0 TSan warnings |
| ylos-sweep | `gc-heap-tsan ylos-sweep` | CR-019 | **expected to fail**: TSan reports CR-019 in every run (below) |
| det-cr014-live | `gc-heap-tsan det-cr014-live` | CR-014 | **expected to fail**: REACHED, `flushCursorW` (atomic `live_bytes` add) vs `computeFragmentationStats` ← `onSweepComplete` ← the tail completion in `lazySweep`, every run |
| det-cr001 | `gc-heap-tsan det-cr001 {rf,wf} {inloop,tail}` | CR-001 | **expected to fail**: REACHED, `finalizeBitmapCellW`'s `gc_phase_` read vs `lazySweep`'s completion write (in-loop or tail), every run |
| det-cr002 | `gc-heap-tsan det-cr002` | CR-002 | **expected to fail**: REACHED, `bitscan::loadWord` ← `nextSetBit` ← `lazySweep` vs `setMarkBitAtomic` ← `finalizePoppedCellW`, every run |
| det-cr019 | `gc-heap-tsan det-cr019 {t1first,t2first}` | CR-019 | **expected to fail**: REACHED, `getObjectSizeFromHeader` ← `lazySweep` vs `promoteYoungLarge`, both orders, every run |
| cr012 | `gc-heap-tsan cr012 {a,e}` | CR-012 | **expected to fail**: REACHED; (a) `acquireOldGenBlock` vs `cyclePressureFinishDue` on `old_gen_in_use_bytes_`; (e) `materializeVirginBlock` vs `validatePageWork` (two reports: `unassigned_blocks_`, `BlockTable`) |
| promo, tail | `gc-heap-tsan promo <seed> 40 4 0 0 8 1` | CR-014 | prints tail-eligible and tail-hit counts (seeds 1-3: 35-39 tail hits in 40 rounds); fails under TSan (`computeFragmentationStats` vs `flushCursorW`) |
| promo, exact | `gc-heap-tsan promo <seed> 40 {4,6,8} 0 1` | CR-016 | abort or corruption: `allocateFromEmptyRegularBlocks` flips a block a worker still allocates in (seen in 5 of 7 seed/worker runs; 4 aborted in `Allocator::resolve`) |
| lbaba | `gc-heap-tsan lbaba [jitter_us [seed0]]` | CR-017, CR-037 | fails today |

**Deterministic register arms** (`det-*`, `cr012`; plans/threaded-gc-register-repros-impl.md
Phase C). Two plain threads drive two promotion workers (or two heaps) of the real allocator,
ordered by relaxed atomics only (`DetHandshake.hpp`), so TSan sees exactly the runtime's own
happens-before edges; each arm builds its heap state deterministically, prints `<arm>: REACHED`
or `NOT REACHED: <why>`, and exits 0 (clean), 3 (not reached) or 66 (a TSan report: expected
today). Run with `TSAN_OPTIONS=halt_on_error=0`. None is in the default run.

Each scenario of `pool` and `ylos` prints a `ylos:` line (families, YLOS
allocations, reach calls, in-place promotions) and, for `pool`, a `pool:` line
(released extents, Discard and Populate jobs, reuse waits, pool stalls).

**`ylos-sweep` (`ylos_sweep.cpp`, register CR-019).** Legacy nursery, 4 KiB
blocks, `large_object_threshold` 2 KiB (the YLOS band is (2 KiB, 4 KiB): a
mixed bag page per YLOS), every pointer-bearing large object in the YLOS,
promotion age 2 by default, no pre-drain sweep slice and no virgin block
before sweep-on-demand. Per round: 24 families (an Array in the band under
eight young parents), a STW major (the Arrays are marked; a lazy sweep is
pending over their pages), then six parallel minors that promote young trees,
so the workers sweep on demand while other workers age (`h->age++`) or promote
(`age = 0`) the same Arrays. The summary line counts the young Arrays ahead of
the sweep at each minor's start and those the sweep walked in that minor (the
race's precondition). It runs only when the first argument is `ylos-sweep` and
is **expected to fail** under TSan until CR-019 is fixed: every run with 4096-
or 1024-byte sweep slices (the default is 1024) reports the pair
`getObjectSizeFromHeader` ← `lazySweep` (the gap sweep's
`walkStep(block, getObjectSize(live_obj))`, and the validate-only V11 walk) ←
`sweepOnDemandAllocate` ← `ladderFrom2W` ← `allocatePromotion`, under
`promo_mu_`, against `reachYoungLargeP`'s `h->age++` or
`promoteYoungLarge`'s `age = 0` under `ylos_mu_`; with 144-byte slices about
one run in three does. Its runs report no other race.

## M4: promotion during a pending lazy sweep (`promo`, not in the default run)

```bash
build-heap-tsan/gc-heap-tsan promo [seed [rounds [workers [jitter_us [exact [sweep_bytes]]]]]]
```

`promo_sweep.cpp` (TLA+ model M4, `test/tla/M4-promotion-bitmap/`): per round an
old population of four size classes, most of it dropped, a STW major (a lazy
sweep is now pending over mixed blocks), then six parallel minors that promote
young trees (Tuple2 nodes over leaves of every class, so the gang's workers
steal subtrees) and, with `exact` = 1 (the default), a pointer-bearing Array of
exactly `alloc_buffer_size` bytes now and then. Odd rounds have a short sweep
backlog under a large promotion volume. `sweep_bytes` is the sweep slice
(default 144; 4096 and up let the workers complete the sweep inside a minor);
`PROMO_DEBUG=1` prints the sweep's progress. It runs only when the first
argument is `promo`, and it is **expected to fail** under TSan until the
register's CR-002 (every slice size), CR-001 (large slices) and CR-016
(`exact` = 1: heap corruption and an abort) are fixed; the validate-only V11
walk in `lazySweep` also races, and a debug assert on the promotion ladder's bag
rung (`allocateFromBagPage`) aborts some runs (see
`test/tla/M4-promotion-bitmap/AUDIT.md`, 2026-09-29 trace wave).

Notes: `StackUnwind` is stubbed (no frames: every value is a RootSet root), and
`reserveAddressSpaceBelow` probes TSan's low application range [64 GB, 512 GB)
first under `__SANITIZE_THREAD__` (TSan's shadow occupies 1 TB and up).

## TLA+ trace build (`-DECO_TLA_TRACE=ON`)

The same project builds `gc-heap-trace` instead: the runtime's `ECO_TLA_TRACE`
hooks compiled in, `test/tla/trace/TlaTrace.cpp` linked, no TSan (trace builds
and TSan builds are separate). `test/tla/run_traces.py` (the `tla-trace`
target) builds and runs it; see `test/tla/README.md`, "Trace validation".

- `gc-heap-trace cycle <scenario>`: a short `heap_driver.cpp` scenario with fork
  stops and explicit majors mid-cycle, recording M1's cycle events (M1 trace
  (a); scenarios `legacy-b2`, `legacy-b4-t8`, `parminor-b2`, `region-b2`,
  `pressure-b2`).
- `gc-heap-trace tiny <seed> [steps bg T jitter_us]`: `tiny_graph.cpp`, at most 8
  objects with every scan, grey and liveness decision recorded (M1 trace (b)).
- `gc-heap-trace promo <seed> [workers [trees [jitter_us]]]`: `promo_sweep.cpp`,
  one parallel minor promoting young Tuple2 trees while a lazy sweep is pending
  over a mixed block, with M4's `m4.*` events recorded (`TracePromoBitmap.tla`).

The raw log goes to `$ECO_TLA_TRACE_OUT`. With no arguments the trace build runs
nothing; the TSan build's `main` and scenarios are unchanged.

## Fork harness (`gc-fork-harness`, TLA+ model M6; register CR-008)

`fork_harness.cpp`: the real allocator (helper pool and concurrent marking on,
asserts and validation on), a synthetic mutator, and a thread that forks. NOT
under TSan (TSan does not support fork in a threaded process), and not built by
default:

```bash
cmake -S test/gc-heap-tsan -B build-heap-tsan -DCMAKE_CXX_COMPILER=g++ -G Ninja
cmake --build build-heap-tsan --target gc-fork-harness
build-heap-tsan/gc-fork-harness <arm> [trials [seed]]
```

Every trial runs in its own process with a hard deadline, and every forked child
probes under `alarm()`, so no arm can hang a run. An arm exits 1 when it
reproduces its register entry (a guard that "fails on the current code"), 0 when
it does not; `mut` exits 1 on any failure.

| Arm | What it does | Reproduces |
|---|---|---|
| `mut` | the heap's mutator forks between pauses; the child finishes the cycle, checks every rooted value, calls `exit()` | nothing: the supported contract, must pass |
| `host` | another thread forks at random; the child probes `thread_mutex_`, then drains the helper jobs | CR-015 (child blocks on `thread_mutex_`); CR-003 (a stranded job) |
| `host-exit` | as `host`; the child calls `exit()` | the child's `exit()` hangs in `~Allocator` (CR-015 / CR-003) or crashes tearing down the dead mutator's heap |
| `two-heap` | two mutators, one forks between its own pauses | CR-015 through the second heap's mutator |
| `relaunch` | host forks while episodes run; harness atfork hooks classify each fork | the CR-004 window, CR-023 (exact only in the trace build) |
| `closing` | host forks while long closing joins run | CR-005 (the parent aborts in `closingFinish`) |
| `closing-early` | the mutator asks for a fork just before the closing step | CR-005's wider window |
| `tenure-storm`, `tenure-storm-l3` | region nursery (k = 1, one exact collector / L3 with 2 members); host forks at random; only children forked while the tenure collector was relaunched inside prepare (`g_r1`) are tested: adopt + 2 minors (storm) or `exit()` (`-l3`) | CR-013, stress only (`flaky`): counts TV1/TV3/TV6 child aborts and, for `-l3`, `hang_dtor` |

`FORK_HARNESS_BT=1` prints the stack of every hung or crashing child. The validate
build's P1 census has a process-wide mutex and tables with no atfork handler (a
host child can block on them or crash on a half-updated table); the harness
turns it off unless `FORK_HARNESS_CENSUS=1`.

With `-DECO_TLA_TRACE=ON` the same file builds `gc-fork-trace`, which also has
- the deterministic guards `det-cr015`, `det-cr003`, `det-cr005`, `det-cr004`: M6's
  probe hooks (`m6.post.cas`, `m6.pool.drained`, `m6.closing`, `m6.stopset`,
  `m6.bg.stopped`, active only while `gc::tla_m6` is set) pause one thread exactly
  in the window while another acts, so each reproduces in every trial;
- the register guards (plans/threaded-gc-register-repros-impl.md Phase D), same
  mechanism, plus trace-only probes `m5.item.taken` / `m5.item.copied` /
  `m5.item.popped` (`TenureWork.hpp`, active while `tenurework::tla_probes`),
  `m5.l3.claimed` (`TenureParEnv::tenure`), `m6.census.locked` (`p1::recordPromoted`)
  and `m6.tlh.dtor` (`~ThreadLocalHeap`). Each trial prints `reached=` (0: the
  precondition was missed, exit 4, never a pass) and `window=open|closed`:

  | Arm | Child | Today (exit 1, every trial) |
  |---|---|---|
  | `det-cr013-start` | adopt + minor | abort, `TV1: resolve found no forwarding` |
  | `det-cr013-start-exit` | `exit()` | clean (control; exit 0) |
  | `det-cr013-copy` | adopt + minor | abort, `TV3/TV4: forwarded objects != tenured` |
  | `det-cr013-copy-scan` | adopt + minor | abort, `TV6: a tenured copy has a young child after the merge` |
  | `det-cr013-l3-exit` | `exit()` | code 15 (`hang_dtor`, `waitPublished` in `tenureTeardown`) |
  | `det-cr013-l3-minor` | adopt + minor | code 13 (`hang_heap`) |
  | `det-cr031` | `exit()` | code 16 (`foreign_teardown`: `~ThreadLocalHeap` of the mutator's heap) |
  | `det-cr032` | `exit()` (census on) | code 14 (`hang_atexit`: the census mutex) |

  The `-minor` arms adopt the dead mutator's heap (`adoptThreadHeap`), a path outside
  the fork contract. `fork_arms.txt` registers every guard arm with its expected
  result; `run_fork_arms.py --tier quick|stress` builds both flavours and runs them
  (`fork-det` here, `register-guards` / `register-guards-stress` in the top-level build).
- `gc-fork-trace gangs <none|host|mut-parent|mut-child> <seed> <T> <mark threads>
  <bg_first|mark_first> <hold>`: one recorded 5c cycle with at most one fork, for
  `test/tla/M6-lifecycle/TraceGangs.tla` (`test/tla/traces.txt`).

## The register's TSan arms in the guard runner (`tsan` flavour)

`fork_arms.txt` also lists the deterministic TSan race arms (flavour `tsan`; arm arguments joined
with `:`), so `run_fork_arms.py` and the top-level `register-guards` target run them with the fork
arms. A trial reproduces only when it prints REACHED, exits 66 and the report names the row's
`match=` function. Alone: `cmake --build <plain tree> --target tsan-det`, or
`run_fork_arms.py --flavor tsan --exe build-heap-tsan/gc-heap-tsan`. `ECO_TEST_XFAIL=strict` makes
every reproduced row fail.
