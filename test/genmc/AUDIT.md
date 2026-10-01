# W1–W5 (weak-memory companions) — audit log

Dated entries, newest last. Each records what was checked against which tree, the tool, the
verdicts, and every change to the drivers. Plan: `plans/threaded-gc-tla-W-weak-memory.md`. A
canary re-audit (parent plan §7.4) adds an entry here quoting the new hash prefix. The canary is
not built yet.

How to run: `cmake --build build --target genmc-check`, or directly
`python3 test/genmc/run_drivers.py [--only NAME] [--log-dir DIR]`. Rows are in `drivers.txt`.

## 2026-09-28 — first implementation (plan §12 steps 1–7)

**Tree:** 2026-09-28, post-7c. Every line the plan cites was re-read against it; they match
(`MarkWork.hpp` 63-195, 246-395; `MinorWork.hpp` 51-113; `TenureWork.hpp` 51-95, 248-268;
`BitmapScan.hpp` 25-39; `OldGenSpace.cpp` 540-664, 874-878, 1075-1135, 1171-1275, 1797-1816,
2765-2775, 3067-3068, 3498-3504, 5247, 5339, 5360; `OldGenSpace.hpp` 407-451, 696-699, 1822-1833;
`ReservedArray.hpp` 110-174).

### Tool facts (the §4.2 spike)

| Fact | Value |
|---|---|
| Tool | GenMC v0.19.0, commit `9f6c4c0772d0c42b325681581acc6a0f3eb9b5f7` (upstream `MPI-SWS/genmc`) |
| Memory model | RC11 (`-rc11`; `-sc` for the SC cross-check rows) |
| LLVM | 19.1.7, Debian bookworm's own `llvm-toolchain-19`, pinned `1:19.1.7-3~deb12u1`. Our LLVM 21 (`/opt/llvm-mlir`) is not involved |
| Built with | GCC 14.4.0 (GNU tarball, SHA256-pinned, gpgv-checked), in a temporary prefix: GenMC is C++23 (`<format>`, `<print>`) and bookworm's libstdc++ is 12. GCC 14's `libstdc++.so.6` ships in `/opt/genmc/lib`; `genmc` has `DT_RPATH=/opt/genmc/lib`, so the process loads one libstdc++, which `libLLVM-19` also uses |
| Install | `docker/install-genmc.sh` (modes `build`, `runtime`, `smoke`). Image: `docker/genmc.Dockerfile` builds `eco-genmc:0.19.0-llvm19`; `docker/eco-dev.Dockerfile` copies `/opt/genmc` from it and runs `install-genmc.sh runtime` (clang-19 at the pinned version, `/usr/local/bin/genmc`, the smoke test). This container's `/opt/genmc` was installed by `install-genmc.sh build` from the final version of the same script (a clean rebuild, 2026-09-28 23:52, smoke test passed) |
| Smoke test | C message passing passes and its relaxed mutant is flagged; a C++20 `std::atomic_ref` program compiled the drivers' way passes and its plain mutant is reported as a race |
| Real headers | Compile **unchanged**. No shim of any allocator header, no transliteration |
| Command line | `clang++-19 -std=c++20 -fno-exceptions -g -fno-discard-value-names -Xclang -disable-O0-optnone -DWDRIVER_GENMC [-D…] -I<mutant dir> -I runtime/src/allocator -idirafter /opt/genmc/include/genmc/runtime -S -emit-llvm -o d.ll test/genmc/<driver>.cpp`, then `genmc -rc11 -disable-estimation -disable-ipr -disable-sr [row flags] d.ll` |
| Time | 49 rows in 20–22 s with 3 at a time; the slowest row 0.9–1.2 s (`w1_deque_2thieves` and its paper variant, 1,055 executions each). Budget 10 min |

What the spike found about GenMC, and what the drivers do about it. Items 1–4 are GenMC bugs or
gaps; the rest are behaviours a driver has to respect.

1. **GenMC's own compile step cannot compile the headers.** It puts its C headers (`pthread.h`,
   `stdlib.h`, `stdio.h`, `assert.h`) first on the include path. libstdc++'s C++20 `<atomic>`
   (`bits/atomic_wait.h` → `gthr-posix.h`) needs pthread types those headers lack, and its
   `<cstdio>` needs `FILE` functions they lack. So `run_drivers.py` compiles each driver itself,
   with the ordinary glibc/libstdc++ headers (as the runtime is compiled), and hands GenMC the
   `.ll`. GenMC intercepts only `__VERIFIER_*` functions (plus `_Znwm`, `_ZdlPv`), so
   `wdriver.hpp` routes threads, the mutex, assume and assert to those. `std::atomic_ref` is
   libstdc++'s own: its operations are ordinary IR atomics (`load atomic`, `atomicrmw`,
   `cmpxchg`), which GenMC models.
2. **The assertion text is lost.** `GenMCDriver::handleError` moves the message into the error
   label and then reports the moved-from string, so GenMC prints only
   `(t, i): ERROR <file>:<line>`. `wdriver.hpp` redefines `assert` (it is included last) to call
   `__VERIFIER_assert_fail` at the assert's own line, and the runner reads the expression from
   that source line. An assert inside an allocator header reports `wdriver.hpp`'s forwarder line;
   the runner names it "an allocator-header assertion".
3. **`memset` to a constant-expression address aborts GenMC** (SIGILL):
   `PromoteMemIntrinsicPass` lowers constant-expression operands for `memcpy` but not for
   `memset`. W4 zeroes its mark slot with a byte loop (the same plain bulk write; no other thread
   reads it).
4. **An undefined external global crashes GenMC** (segfault after "Transformation complete"). The
   headers' fatal paths name glibc's `stderr` (`fprintf(stderr, …)` in
   `SerialEngine::tenure`; GenMC makes `fprintf` a no-op). `wdriver.hpp` defines `stderr` and
   `stdout` for the checker.
5. **Allocation.** Only `operator new(size_t)` and `operator delete(void*)` are intercepted.
   `wdriver.hpp` defines `new[]`, `delete[]` and the sized deletes (clang 19 emits them) in terms
   of those. `calloc` is not supported (W5 allocates with `operator new` and zeroes the fields).
   Reading allocated memory before any write is an error ("uninitialized memory").
6. **Addresses.** A heap address is `(thread << 32) | offset` (main's allocations are below
   2^32); a static's address has bit 63 set. So heap objects fit the 40-bit address fields of the
   forward word and the shadow entry, and statics do not: W5's forwarding targets are heap
   objects, and its four round-trip asserts pass. (Natively, glibc's heap of a PIE binary is near
   2^46, so the native smoke build takes W5's objects from an arena mapped at 2^36.)
7. **Mixed-size accesses.** GenMC requires only overlapping *atomic* accesses to have one size.
   A plain 64-bit word read (`loadWord`: the 8-byte `memcpy` becomes an `i64` load) against a
   byte `atomic_ref` `fetch_or` goes to the race detector, per byte. W3's word-granularity
   mutants (`W3_CURSOR_ON_T0_BYTE`, `W3_BYTE_CHUNK`) are flagged on exactly that overlap, so
   §7.6's byte-read fallback is not needed.
8. **Heap objects have no name** in GenMC's report (`Rna (, 11) [(2, 9)] w5_forwarding.cpp:84`).
   Statics appear by symbol (`_ZL4bits[0]`, demangled by the runner). A row names a heap race by
   the source line of a racing event (`race:@<code>`).
9. **A fresh heap object read without happens-before** is reported as "Attempt to read from
   uninitialized memory", not as a race, when the reader can see no write at all (the
   allocation's contents are undefined to it). It is the same missing edge; `drivers.txt` calls
   it `uninit:` (`W1_RELAXED_ARRAY`).
10. **Spin-assume can hide a CAS-failure-order mutant.** GenMC turns a loop iteration with no
    side effect into an assumption. With the code's own `for (;;)` claim loop, the iteration
    after a failed claim is cut before the retry reads through the forward word, and
    `W5_RELAXED_CLAIM_FAIL` **passes silently** (2 complete, 6 blocked executions). With
    `-disable-spin-assume` it is flagged. The copied claim loops (W4b, W5) are written with their
    bound, and those rows run with `-disable-spin-assume`.
11. **"Unordered writes" is upgraded to an error** under in-place revisiting and under symmetry
    reduction. A failed `SpinMutex::try_lock` still writes `true` with its `exchange`, unordered
    with the holder's later unlock: the ordinary test-and-set lock, not a defect. Every row runs
    with `-disable-ipr -disable-sr` (disabling an optimisation is sound).
12. **CAS failure orders and weak CAS are modelled** (GenMC ≥ 0.18): `W4_RELAXED_CLAIM_FAIL` and
    `W5_RELAXED_CLAIM_FAIL`, which weaken only a failure order, are flagged.
13. **Spin loops as written cannot run.** `cpuRelax()`'s `llvm.x86.sse2.pause` aborts GenMC
    ("Code generator does not support intrinsic"); `sched_yield` and `nanosleep` are unknown
    external functions. So `backoff()`, `idleUntilWorkOrDone` as written and `SpinMutex::lock()`
    cannot be checked; the drivers use `try_lock` under an assumption, a pruning `pause`
    callback, and (W2) a straight-line copy of one round. `w2_real_loop` (§6.3) is not added.

### Results

All 49 rows as expected (`run_drivers.py`; the final run, on the clean reinstall, took 22 s). Natively, every driver variant compiles without warnings under g++ 12.2 and clang++ 14
(`-std=c++20 -Wall -Wextra`) and passes 20 runs. Executions are GenMC's complete executions
(blocked ones in brackets); a flagged row stops at its first report.

| Row | Expected | Result | Executions | Time |
|---|---|---|---|---|
| `w1_deque` | pass | pass | 24 | 0.2 s |
| `w1_deque_2thieves` | pass | pass | 1,055 | 1.1 s |
| `w1_deque_paper` | pass | pass | 24 | 0.1 s |
| `w1_deque_paper_2thieves` | pass | pass | 1,055 | 0.7 s |
| `W1_NO_TAKE_FENCE` (2 thieves) | assert `n == 1` | as expected | 24 | 0.2 s |
| `w1_no_take_fence_1thief` | pass (review R3) | pass | 24 | 0.1 s |
| `W1_RELAXED_PUBLISH` | race `payload` or assert `n == 1` | assert `n == 1` | 1 | 0.2 s |
| `W1_STEAL_RELAXED_BOTTOM` (on the paper orders) | race `payload` or assert `n == 1` | assert `n == 1` | 1 | 0.1 s |
| `W1_RELAXED_ARRAY` | uninit or race at `a->buf[t & a->mask]` | uninit, `MarkWork.hpp:124` | 6 | 0.1 s |
| `w2_termination` | pass | pass | 4 | 0.1 s |
| `w2_priv` | pass | pass | 4 | 0.0 s |
| `w2_reactivate` | pass | pass | 32 (8) | 0.1 s |
| `w2_returned_tickets` | pass | pass | 5 | 0.1 s |
| `w2_idle_before_publish` | assert `!(decided && left)` | as expected | 5 | 0.1 s |
| `w2_idle_before_publish_sc` (`-sc`) | pass | pass | 10 | 0.1 s |
| `w2_idle_before_publish_onescan_sc` (`-sc`) | assert `!(decided && left)` | as expected | 2 | 0.1 s |
| `W2_RELAXED_GOIDLE` | assert `!(decided && left)` | as expected | 2 | 0.1 s |
| `W2_RELAXED_GOIDLE_TICKETS` | assert `!(decided && left)` | as expected | 3 | 0.1 s |
| `W2_RELAXED_DECIDER_LOAD` | assert `!(decided && left)` | as expected | 2 | 0.1 s |
| `W2_PUBLISH_AFTER_IDLE_MINOR` | assert `!(decided && left)` | as expected | 1 | 0.1 s |
| `W2_DONE_STORE` (new) | assert `!(decided && reactivated)` | as expected | 16 (6) | 0.1 s |
| `w3a_marker_alloc_black` | pass | pass | 3 | 0.0 s |
| `w3b_cursor_own_slot` | pass | pass | 1 | 0.0 s |
| `w3c_CR002_gap_sweep` | race `bits` | race `bits[0]`: `fetch_or` vs `clearBit` | 0 (1) | 0.0 s |
| `w3d_CR001_gc_phase` | race `phase_idle` | race `phase_idle` | 0 | 0.0 s |
| `w3e_grant_chunks` | pass | pass | 1 | 0.0 s |
| `w3f_promo_mu` | pass | pass | 4 (3) | 0.0 s |
| `W3_PLAIN_ALLOCATE_BLACK` | race `bits` | race `bits[0]` | 0 | 0.0 s |
| `W3_CURSOR_ON_T0_BYTE` | race `bits` | race `bits[0]`: `loadWord` vs `fetch_or` | 0 | 0.1 s |
| `W3_SMALL_CHUNK` | race `bits` | race `bits[0]`: `loadWord` vs `setBit` | 0 | 0.0 s |
| `W3_BYTE_CHUNK` | race `bits` | race `bits[0]`: `loadWord` vs `setBit` | 0 | 0.0 s |
| `W3_SPIN_RELAXED_UNLOCK` | race `counter` | race `counter` | 0 (1) | 0.0 s |
| `W3_SPIN_RELAXED_TRYLOCK` | race `counter` | race `counter` | 0 (1) | 0.0 s |
| `w4_publication` | pass | pass | 5 | 0.1 s |
| `w4_commit` | pass | pass | 11 | 0.0 s |
| `W4_RELAXED_OWNER` | race `info` | race `info[1].start` | 2 | 0.1 s |
| `W4_RELAXED_OWNER_COMMIT` (new) | race `info` | race `info[1].start` | 3 | 0.0 s |
| `W4_REGION_SHRINK` | assert `blockIdFor(heap + 72) == 0` | as expected | 2 | 0.0 s |
| `W4_RECOMPUTE_PLAIN` | race `region_end` | race `region_end` | 0 | 0.0 s |
| `w4b_shared_chunk` | pass | pass | 12 | 0.2 s |
| `W4_RELAXED_SHARED` | race `info` or `mark` | race `info[1].end_of_objects` | 1 | 0.1 s |
| `W4_RELAXED_CLAIM_FAIL` | race `info` | race `info[2].end_of_objects` | 7 | 0.1 s |
| `w5_forwarding_a` | pass | pass | 8 (2) | 0.1 s |
| `w5_forwarding_b` | pass | pass | 1 (1) | 0.2 s |
| `w5_parallel_tenure` | pass | pass | 8 (2) | 0.0 s |
| `W5_RELAXED_PUBLISH` | race at the read-through, or its assert | race: read-through vs copy | 0 (1) | 0.1 s |
| `W5_RELAXED_CLAIM_FAIL` | race at the read-through, or its assert | race: read-through vs copy | 2 (2) | 0.1 s |
| `W5_HELP_WITHOUT_JOIN` | assert `copiesCol + copiesHelpA == 1` | as expected | 0 | 0.1 s |
| `W5_SHADOW_RELAXED_PUBLISH` | race at the read-through, or its assert | race: read-through vs `copyObj` | 0 (1) | 0.0 s |

### Counterexamples read

Every mutant's report was read, to check that it is the plan's story and not another path to the
same report (parent plan trap 11).

- **`W1_NO_TAKE_FENCE`** is §5.4's execution, event for event. Thief A steals index 0 (entry 1).
  The owner's first `take` stores `bottom = 2`, reads the initial `top = 0` and takes index 2.
  Thief B reads `top = 1` and the old `bottom = 3`, and steals index 1 (entry 2). The owner's
  second `take` stores `bottom = 1`, reads `top = 0` again and takes index 1 without a CAS.
  Entry 2 is returned twice. With one thief the mutant passes (review R3).
- **`W1_RELAXED_PUBLISH`, `W1_STEAL_RELAXED_BOTTOM`**: the thief reads `bottom = 1` without
  synchronizing, its element load returns the slot's initial 0 (`kEmpty`), its CAS succeeds, and
  entry 1 is lost (§5.4's second outcome).
- **`W1_RELAXED_ARRAY`**: the thief reads the new `array_` without synchronizing and reads its
  `buf` field (`MarkWork.hpp:124`), which `Array::make` wrote plainly: no write is visible to it.
- **`w2_idle_before_publish`** (RC11) is §6.3's "both scans miss". D's state load synchronizes
  with M's `goIdle`, which precedes the push. D's first scan reads the initial `bottom` and then
  `priv = 0` from M's store **after** the push (relaxed, no edge). Its second scan reads the same
  values. The done-CAS succeeds with the entry left. Under SC this execution does not exist:
  `w2_idle_before_publish_sc` passes, and only the one-scan reduction fails under SC (review R20).
  So the code's publish-before-`goIdle` order is load-bearing in the mark environment under the
  C11 model only, as the plan says.
- **`W2_DONE_STORE`**: R reactivates between D's check and D's store; D stores `done` over R's
  reactivation.
- **`w3c_CR002_gap_sweep`**: the finalizer's lock hold (its batch pop) comes first. The sweeper
  then takes the lock, reads word 0 (`loadWord`, `BitmapScan.hpp:27`) and plain-clears the live
  object's bit (`:38`). The finalizer's `fetch_or` after its unlock is unordered with both.
- **`w3d_CR001_gc_phase`**: the reader's plain read is unordered with the write under the lock.
- **`W4_RELAXED_OWNER`**: the marker decodes owner 2 from the relaxed owner store and reads
  `info[1].start` unordered with the mutator's write. With `W4_COMMITTED0=2` the same:
  `committed_`'s release precedes the `BlockInfo` writes in the code's order, so it cannot
  publish them (review R1).
- **`W4_RELAXED_CLAIM_FAIL`**: B's acquire load reads block 1's word; its CAS fails by reading
  block 2's word (relaxed); the retry reads `info[2]`, unordered with A's second lock hold.
- **`W5_HELP_WITHOUT_JOIN`**: the collector's relaxed load and help's acquire load both read the
  stale generation-1 entry of `sh[0]`. Help's CAS from that observed word comes before the
  collector's publish in modification order, so both copy A.
- **`W5_RELAXED_PUBLISH`, `W5_RELAXED_CLAIM_FAIL`, `W5_SHADOW_RELAXED_PUBLISH`**: the loser
  reads a forward word without synchronizing and reads through it, racing with the winner's
  plain copy.

### Register evidence (for the orchestrator; the register is not edited here)

- **CR-001** (race half): `w3d_CR001_gc_phase` reports the data race on the `gc_phase_` shape
  (plain write under `promo_mu_`, unlocked plain read). The recorded command is
  `run_drivers.py --only w3d`. Proposed: the race half moves to Reproduced (C11). The moved
  decision point is not a C11 question.
- **CR-002**: `w3c_CR002_gap_sweep` shows that the access pattern (the sweeper's `loadWord` and
  `clearBit` under the lock; a stashed cell's `fetch_or` outside it) is a C11 data race. The driver
  hard-codes the precondition, so this is classification evidence, not reproduction; the status
  stays Confirmed (shape) until M4 or a harness shows the precondition is reachable.
- **CR-009**: `W4_RECOMPUTE_PLAIN` states the hazard in C11 terms (a plain `region_end_` write
  races a marker's relaxed `atomic_ref` load, if a release path ran during a cycle). No status
  change; the guard stays the footprint grep.
- **CR-021**: not visible to GenMC (read/read is not a data race), as the plan predicted.
- **CR-022**: `W3_BYTE_CHUNK` is flagged: 8-cell (byte-disjoint) chunks race through
  `nextFreeCell`'s word read, so chunks must own whole words. It can join M4's
  `chunk_unit_subword` as a guard.
- No new defect in the code: every as-written driver passes.

### Deviations from the plan

- **Compile route** (item 1): the plan expected GenMC to compile the drivers; it compiles them
  itself. The plan's `pthread` calls became `wdriver.hpp`'s `spawn`/`join`/`WMutex` (GenMC's
  `__VERIFIER_*` under the checker, pthreads natively), and `wdriver.hpp` is included last.
- **W3** follows the sketch. **W2** adds `-DW2_REACTIVATE` and `-DW2_RETURNED_TICKETS` (the
  sketch describes them in prose), the `:373` done check in the copied round, the `-sc` rows, and
  the driver mutant `MUTANT_W2_DONE_STORE` (a negative control for `w2_reactivate`).
- **W4**: the `memset` is a byte loop (item 3); `blockIdFor(heap + 130)`'s success also asserts
  `mark_len[1] == 8`; new row `W4_RELAXED_OWNER_COMMIT`. **W4b** (`w4b_shared_chunk.cpp`, new): A
  publishes block 1, then block 2 in a later lock hold, in every W4b row; the claim loop has two
  iterations written out.
- **W5**: one compile per case (`-DW5_CASE='a'`, `'b'`, `'p'`), so each report belongs to one
  case; the three-thread variant is case `p` of `w5_forwarding.cpp`, not a separate file. Objects
  come from `operator new` (no `calloc`). The claim loops are bounded (item 10).
- Native builds (no `WDRIVER_GENMC`; syntax checks and smoke runs only): `VERIFIER_ASSUME(c)`
  waits until `c` holds, and the pruning pause yields. A condition-variable wait under a mutex is
  `WMutex::await(pred)`: under GenMC an assumption with the lock held, natively
  unlock-yield-relock. (An assumption under a held lock deadlocks natively.) The plan's stand-in (`pthread_exit` when
  `c` is false) deadlocked W5 (b) natively, because the mutator exits holding the gang mutex, and
  made W3f's native `counter == 2` depend on the schedule. Under GenMC nothing changes: an
  assumption prunes the execution.
- `mutate.sh` uses `perl -0777` regexes (a fence in `take` has a twin in `steal`, so some
  patterns need the line before). Each must match exactly once, and the result must differ.
  `W1_PAPER` (the paper's orders) is a header edit that is expected to pass.
- New rows beyond the plan's tables: `w1_no_take_fence_1thief`, `w2_idle_before_publish_sc`,
  `w2_idle_before_publish_onescan_sc`, `W2_RELAXED_GOIDLE_TICKETS`, `W2_DONE_STORE`,
  `W4_RELAXED_OWNER_COMMIT`.
- Not done: `w2_real_loop` (item 13); the proposed `w_pool_done` and `w_running_chain` (§10.1,
  M6/M7 close-outs); the canary lines (the orchestrator builds the canary).

### Limits

- `W2_RELAXED_GOIDLE_TICKETS` does not isolate the budget read: with `goIdle` relaxed, the deque
  reads can be stale too, and GenMC reports the first failing execution.
- Each W case checks an access pattern at a small size. It shows what the C11 model allows for
  that pattern, not that the code reaches the pattern (W3c, W3d, W4's premises IM5 and HEAP_049).
- C++20's `atomic_ref` exclusivity rule ([atomics.ref.generic]/3, CR-021) is outside every C11
  checker.

## 2026-09-28 — `w_pool_done` and `w_running_chain` (the two proposed drivers)

**Tree:** 2026-09-28, with the trace hooks in `GCHelperPool.cpp`. The line numbers the brief
quoted have moved; the current ones: `Done` store `GCHelperPool.cpp:220`, `wait`'s fast path
`:239`, `post`'s CAS `:155`, `joinLocked`'s `running_` store `:644`, `launch`'s `:627`;
`isIdle`/`isDone` `GCHelperPool.hpp:56-57`, `running()` `:258`; `tenureJoin`'s orphan test
`NurseryTenure.cpp:614-615`. **Tool:** as in the first entry (GenMC v0.19.0, LLVM 19).

### What the drivers are

- **`w_pool_done.cpp`**:
  - The **real** `HelperJob` from `GCHelperPool.hpp`: its state word, `isIdle()` and `isDone()`.
    A header mutant reaches `isDone()`.
  - Copies of the pool code, pinned by the canary (`GCHelperPool.cpp` needs `std::thread`,
    `std::mutex` and condition variables, which GenMC cannot run): `post`'s Concurrent path
    (`:150-179`), one `workerLoop` iteration (`:202-224`: dequeue under `m_`, `runJob` outside
    it, then `Done` with release under `m_`), and `wait` (`:237-253`, the condition-variable
    wait as an assumption under `m_`).
  - Copies of PageWork's collectors (`PageWork.cpp:50-111`): `runJob`, `reap`, `reapDone`,
    `awaitSlot`. `reap` reads the runner's outputs (`failures`, the end timestamp) and then
    **writes** the job (`kind`, the inputs, `resetForReuse`). So the pair must also order the
    runner's reads of the job before the owner's rewrite.
- **`w_running_chain.cpp`**: a pinned reduction of `GCBackgroundGang`. It copies
  `memberLoop`'s finish (`:603-610`), `stopAndJoin`/`joinLocked`/`join` (`:639-662`),
  `stopAllForFork`'s `if (g->running())` (`:669-677`), `running()` (hpp:258), and the exact
  engine's stop check between items (`TenureWork.hpp:218`). Three threads:
  - the member: two items, then finishes under `m_`;
  - the foreign joiner (fork prepare): `stopAndJoin`;
  - the owner, `tenureJoin`: on `!running()` it reads the job state with no join and finishes the
    job itself; on `running()` it calls `join()`.

  After the joins, `owner_seen == member_final`.

### Results

All 11 rows as expected (4 s). The full `genmc-check` is now 60 rows: 60/60 as expected in 24 s.
Natively, both drivers (and W5 after the `WMutex::await` change) compile without warnings under g++
12 and clang++ 14 and pass 20 runs.

| Row | Expected | Result | Executions | Time |
|---|---|---|---|---|
| `w_pool_done` (`wait`: fast path or locked wait) | pass | pass | 6 (5 blocked) | 0.0 s |
| `w_pool_done_reapdone` (`reapDone` first, then `awaitSlot`) | pass | pass | 15 (7) | 0.1 s |
| `w_pool_done_relaxed_cas` (`post`'s CAS relaxed) | pass | pass | 15 (7) | 0.0 s |
| `POOL_RELAXED_DONE` (`:220` relaxed) | race `job` or the reap asserts | race `job.failures`: `reap` vs `runJob` | 2 (3) | 0.1 s |
| `POOL_RELAXED_DONE_REAP` (the same, `reapDone` route) | same | race `job.failures` | 2 (3) | 0.1 s |
| `POOL_RELAXED_FASTPATH` (`:239` relaxed) | same | race `job.failures` | 2 (3) | 0.1 s |
| `POOL_RELAXED_ISDONE` (header mutant, hpp:57) | same | race `job.failures` | 9 (5) | 0.1 s |
| `w_running_chain` | pass | pass | 4 (4) | 0.0 s |
| `RUNNING_RELAXED_STORE` (`:644` relaxed) | race `job_next` or `owner_seen == member_final` | race `job_next` | 3 (4) | 0.0 s |
| `RUNNING_RELAXED_LOAD` (hpp:258 relaxed) | same | race `job_next` | 3 (4) | 0.0 s |
| `RUNNING_JOIN_EARLY` (`running_ = false` before the wait) | same | race `job_next` | 0 (1) | 0.0 s |

### Counterexamples read

- **`POOL_RELAXED_*`**: the owner reads `Done` without the mutex, from the worker's relaxed store
  or with a relaxed load. Its reads of `failures` in `reap` race with `runJob`'s writes. In the
  `reapDone` route, `isIdle()`'s acquire load reads `Running`, and the weakened `isDone()` reads
  `Done`: the code's own two loads.
- **`w_pool_done_relaxed_cas` passes.** The post half (the owner's writes to the job before
  `post`, read by the worker) is published by `m_`: the owner's enqueue happens under `m_`, and
  the worker dequeues under `m_`. The CAS's `acq_rel` is not load-bearing. M7's A4 row 2
  ("acq_rel + `m_`") can say "`m_`".
- **`RUNNING_RELAXED_STORE`**: M6's A4 chain (2), event for event. The member writes `job_next = 2`,
  then locks `m_`; the joiner locks `m_` after it and stores `running_ = false` (relaxed). The
  owner's acquire load reads that `false`, takes the orphan path and reads `job_next`, unordered
  with the member's write. `RUNNING_RELAXED_LOAD` is the same with the owner's load weakened.
- **`RUNNING_JOIN_EARLY`**: the joiner stores `false` before the member finished, and the owner
  reads `job_next` while the member is still writing it. GenMC found this error in an execution
  it could not replay for metadata, so the member's event prints as `Wna (, 2)` with no line; the
  runner matched on the owner's event. (A tool fact: a report found in a blocked execution may
  name only one of the two events.)

### Findings

- **A second orphan site.** `tenureJoin`'s L3 branch (`NurseryTenure.cpp:584-585`) also acts on
  `!g->running()` without joining: it skips the join and goes straight to `tenure_ctl_->done()`
  and `tenureConcFinish`, which read the members' state. The same chain carries it, and
  `w_running_chain` covers it. M6's A4 row and the parent plan cite only `:614-615`; add
  `:584-585`. `reapBackground` (`OldGenSpace.cpp:4527`) always calls `join()` (mutex), and
  `assertSlotsQuiescent` (`:4380`) only aborts. Neither needs the chain.
- No defect in the code. Both patterns hold under RC11 with the orders as written, and each
  weakening named in M6's A4 (the `running_` store and load) and in M7's A4 (the `Done` store,
  the fast-path load, `isDone`) is flagged.

### Register evidence (for the orchestrator)

- **CR-026**: `w_pool_done` is the guard of the fast path's ordering. It passes on the code, and
  its four mutants (`POOL_RELAXED_DONE`, `_DONE_REAP`, `_FASTPATH`, `_ISDONE`) fail. HEAP_058's
  amended text can cite it: publication on `wait`'s fast path and in `isDone()`/`isIdle()` is
  the release store of `Done` (made under `m_`) paired with those acquire loads; the post half is
  the mutex. The status change is the orchestrator's (the entry is D; its fix is the wording).
- The L3 orphan site above could go into M6's register notes (no new entry: it is not a defect).

### §10.1 census: coverage now

The census still has 259 `memory_order` / `atomic_thread_fence` lines in `runtime/src/allocator/`
(2026-09-28, recounted). By group:

| Group (§10.1) | Disposition |
|---|---|
| Chase–Lev deque | **W1** |
| termination word, decider, budget | **W2** |
| `priv` stores, `anyWork` loads | **W2** (`w2_priv`); the minor envs need nothing |
| mark bytes, allocate-black, gap sweep, `gc_phase_`, `promo_mu_` | **W3** (W3c/W3d race: CR-002, CR-001) |
| large-mark byte | no W (both sides atomic, no data travels) |
| region bounds, owner words, page-index count, shared chunk word | **W4**, **W4b**; `committed_` orders a syscall (no C11 check) |
| header forward word, shadow words, the join | **W5** |
| post-join shadow readers | W5 (b) plus the join's mutex |
| indivisibility-only RMWs | no W (RMW atomicity) |
| stop and share hints | no W (liveness only) |
| gang and episode hints | **now covered**: `running_`'s chain by **`w_running_chain`**; `finished_pub_` is a hint (no W); `bg_ep_` is plain and mutator-only |
| pool job state | **now covered** by **`w_pool_done`** (the `Done` pair; the post half is the mutex) |
| validators and test hooks; statistics; outside M1–M7 | out of scope |
| pause-only; relaxed counters a decision reads | no W |

Every group now has a W driver or a written disposition. The per-line mapping belongs to the
canary's census (parent §7.1), which is not built.

## 2026-09-29 — canary baseline (GC_MODEL_001)

The canary (`test/tla/manifest.txt`, `tla-canary` in every build) was first pinned today. Pins that
name the drivers: W1 2, W2 4, W3 15, W4 19, W5 9, w_pool_done 3, w_running_chain 4. They are the code the drivers include or reduce (whole files such as
`MarkWork.hpp`, `MinorWork.hpp`, `TenureWork.hpp`, `BitmapScan.hpp`, `GCHelperPool.*`, `PageWork.cpp`,
and `TLA-REGION` regions for the reduced functions). A pin that fires and names a driver needs an
entry here quoting the new hash prefix before `check-tla-manifest.sh --update` accepts it.


## 2026-09-30 — canary re-audit: register reproductions (GC_MODEL_001)

Pins fired: W3: OGS.lazySweep (3019e316a801); W5, w_running_chain: file TenureWork.hpp (1b0803bf3a66); W5: NT.TenureParEnv (53fc7d8f27b8).

Change (plans/threaded-gc-register-repros-impl.md, register reproductions; snapshot of the
prior tree `snapshots/register-repros/pre-impl-2026-09-30.tgz`). Code-level guards were added for
the open register entries. The runtime changes are of three kinds only, and none adds, removes or
reorders an atomic step, a lock, a shared location or a memory order on a production path:
- **test accessors** (`AllocatorTestAccess`: `acquireOldGenBlock`, `releaseOldGenBlock`,
  `freeBlocks`, `threadMutexHeldElsewhere`, `adoptThreadHeap`; `OldGenSpaceTestAccess`:
  `sweepCompleteDeferred`, `promoMuHeld`, `cyclePressureFinishDue`). They forward to existing
  functions or read existing fields; unit tests and harnesses call them only. They fire the
  footprint greps `F.promoMu`, `F.threadMutex`, `F.pageWorkCalls`, `F.oldGenFreeBlocks`,
  `F.setThreadHeap`, `F.parPromoActive` and the `Allocator.hpp` census by name only.
- **trace-only probes** (`ECO_TLA_TRACE_ONLY`, compiled out of every other build):
  `m5.item.taken`, `m5.item.copied`, `m5.item.popped` (`TenureWork.hpp`, gated by the new
  `tla_probes`, default false), `m5.l3.claimed` (`NT.TenureParEnv`), `m6.tlh.dtor`
  (`TLH.destructor`), `m6.census.locked` (`P1Census.cpp`). `tlatrace::probe` emits no event;
  it only calls the harness's callback while recording, so no recorded trace changes.
- **a stats-only counter** in `OGS.lazySweep`'s tail completion (`sweep_tail_completions`,
  `sweep_tail_in_promotion`), inside the existing `#if ENABLE_GC_STATS` block in the same
  `promo_mu_` section as the existing `total_post_sweep_shrink_ns` write.
`test/gc-heap-tsan/promo_sweep.cpp` gained non-trace arms (`promoDetMain`, tail mode, exact arrays
every minor); its trace section (`promoTraceMain`, the M4 trace harness) is byte-identical.

Runs (2026-09-30, this tree): `run_traces.py` (every harness rebuilt): **135/135 as expected** in 83 s.

The drivers compile without ECO_TLA_TRACE, so every probe is absent from them; the counter is outside every reduced function's logic.

**Verdict: no model change needed.**

## 2026-09-30 — register-fixes §3.2: CR-018, `finalizePoppedCellW` (GC_MODEL_001)

Pin fired: region `OGS.finalizePoppedCellW` (W3), new hash prefix **26356efabd55**.

Change (plans/threaded-gc-register-fixes.md §3.2): the relaxed `live_bytes` `fetch_add` moved out of
the black branch and now runs in every phase (one add per path); the `gc_phase_` read stays plain and
the mark-bit `fetch_or` stays phase-gated. W3 reduces this function to its mark-byte accesses (cases
a-c) and its `gc_phase_` read (case d, CR-001's race, still `race` until Phase 2); `live_bytes` is not
in W3 (M4's `NoRaceLive` covers it). No W3 access changes.

**Verdict: no model change needed.** (`w3d_CR001_gc_phase` still expects `race`.)

## 2026-09-30 — register-fixes Phase 2 (§4.1-§4.4): CR-014, CR-001 (race), CR-002, CR-028 fixed (GC_MODEL_001, one audit for the batch)

Pins fired naming W3 / W4: regions `OGS.finalizePoppedCellW` (**4d8b93453093**, W3),
`OGS.finalizeBitmapCellW` (**296d0825c9c5**, W3), `OGS.lazySweep` (**b033f3f0c837**, W3), census
`OldGenSpace.cpp` (**2afe7bc4cf4d**, W3 W4), census `OldGenSpace.hpp` (**493c238780a8**, W3 W4).

**W3 updated** (the register fixes, same day):
- case d (CR-001): `d_sweeper`'s write is a relaxed `std::atomic_ref<int>` store under the lock and
  `d_reader`'s read a relaxed `atomic_ref` load, as the code's `completeSweep` store and the two
  finalizers' loads. `w3d_CR001_gc_phase` now expects `pass`; new mutant row `W3_CR001_PLAIN_PHASE`
  (`MUTANT_W3_CR001_PLAIN_PHASE`, the pre-fix plain accesses) expects `race:phase_idle`.
- case c (CR-002): `c_finalizer` calls `allocateBlack` BEFORE `promo_mu.unlock()` (a cell of the
  block under the sweep cursor is finalized in the lock hold that popped it). `w3c_CR002_gap_sweep`
  expects `pass`; new mutant row `W3_CR002_UNLOCKED_FINALIZE` (`MUTANT_W3_CR002_UNLOCKED_FINALIZE`,
  finalize after the unlock) expects `race:bits`.
- Both variants of both cases compile (`g++ -std=c++20 -fsyntax-only`); `run_drivers.py --list`
  parses the registry.
- **GenMC was NOT run** (`genmc` is not installed in this environment; the eco-dev-genmc image has
  it). Audited by reading: with the lock ordering the sweeper's plain `nextSetBit`/`clearBit` and
  the finalizer's `fetch_or` (case c), and both `phase_idle` accesses atomic (case d), RC11 has no
  race to report; the mutants restore exactly the shapes that GenMC flagged on 2026-09-28. Owed: a
  `genmc-check` run of W3 (the two flipped rows and the two new mutants).

**W4**: census only (the new `atomic_ref<GCPhase>` lines are not W4's publication pattern).
**Verdict: W3 driver and registry updated (not run); W4 no change needed.**

## 2026-10-01 — register-fixes §6.1: CR-019 fixed, relaxed atomic whole-word YLOS header access (GC_MODEL_001)

Pins fired: W3: region `OGS.lazySweep`, new hash prefix **6066819cec59**.

Change (plans/threaded-gc-register-fixes.md §6.1, CR-019; HEAP_062/HEAP_067 amended): every
access to a header word that another thread may touch during a legacy parallel minor is a relaxed
atomic whole-word access through the new helpers `loadHeaderRelaxed` / `storeHeaderRelaxed`
(`AllocatorCommon.hpp`, newly census-pinned for M3, M4). Writers: `reachYoungLargeP` (age++ under
`ylos_mu_`), `promoteYoungLarge` (age = 0), region `reachYoungLargeR` (age = 1). Readers:
`lazySweep`'s gap sweep (one load per live object, reused for the trace event), the header walk
(one load reused for tag, sentinel and pin), the large-block branch's pin read, and the
validate-only `validateV11` walk. The values written are unchanged (tag/size/pin kept); no lock,
step order or memory order beyond "relaxed" is added, so no happens-before edge changes. TSan:
`det-cr019` both orders and `ylos-sweep` are clean (were: a report every run).

W3 models the sweeper's bitmap-word reads/clears against the finalizer's `fetch_or` and the `gc_phase_` accesses; it has no header word. The new relaxed header load adds no ordering and touches no W3 location. **Verdict: W3 no change needed.**

## 2026-10-01 — register-fixes §6.3: CR-007 fixed, no-wait acquire for a promotion holder with n > 1 (GC_MODEL_001)

Pins fired: `w_pool_done`: file `PageWork.cpp` (**3b5ca6feb509**); W4: regions `OGS.ensureBagPageAvailable` (**37f3ac00eb2f**), `OGS.allocateLargeBlock` (**e2c48a27f642**).

Change (plans/threaded-gc-register-fixes.md §6.3, CR-007; HEAP_058/HEAP_059 amended): a promotion
holder of a parallel promotion with n > 1 workers (`OldGenSpace::acquireWaitPolicy()` =
`AcquireWait::AvoidUnderPromo`, passed at `ensureBagPageAvailable`, `allocateFromBagPage` and
`allocateLargeBlock`) gets the no-wait policy in `Allocator::acquireOldGenBlock` (modes 1/2 with
decommit on): (1) the first fitting **Pending** extent (`PageWork::isPending`, job-blind; `onReuse`
cancels it, never waits), (2) else a fresh bump, (3) else -- the old-gen cap leaves no bump room --
today's first fit (may wait; counted). The first-fit body was factored into a `takeFreeAt` lambda
(no behaviour change for `Allowed`). New PageWork API: `isPending`, `decommitOn`, `noteNoWait` (the
counters `nowait_pending_reuse_bytes`, `nowait_fresh_bytes`, `nowait_fallback_waits` and the M7 trace
event `nw`), `noteNoWaitSkip` (`nowait_skipped_extents`). Validate builds: a no-wait Pending reuse
must not raise `reuse_waits`, and `releaseBlockToAllocator` / `releaseUnassignedBlockToAllocator` abort
while `acquireWaitPolicy() != Allowed`. No lock, atomic or memory order is added; every new
PageWork call runs under `thread_mutex_` like the old ones.

**w_pool_done**: the Done release / acquire pair, `post`'s CAS and `reap` are untouched; `noteNoWait` only bumps plain counters under `thread_mutex_` and emits a trace event. **W4**: the region-bounds publication pattern is unchanged; only the `acquireOldGenBlock` argument changed. GenMC is not installed here (as in Phases 1-2); audited by reading. **Verdict: no driver change needed.**


## 2026-10-01 — register-fixes Phase 5: GCHelperPool fork changes (w_pool_done, w_running_chain) (GC_MODEL_001)

Pins fired: files `GCHelperPool.hpp` (**376411c19869**), `GCHelperPool.cpp` (**22f4e3f2b546**).

Change (plans/threaded-gc-register-fixes.md §7, Phase 5; HEAP_007 fork contract, HEAP_058, HEAP_065,
HEAP_070 amended, HEAP_075 new): (1) `GCFork.{hpp,cpp}`: ONE `pthread_atfork` registration with fixed
layers (gangs: registry -> each background gang's `m_` to set `fork_hold_` -> `stopAllForFork` -> each
gang's `m_` held -> `GCMarkGang` `run_m_` -> its `m_`; allocator: `thread_mutex_`; census: the P1 census
mutex and detector N's; pool: `GCHelperPool::m_`, drained and held); the three old registrations are
gone. (2) No teardown holds `thread_mutex_` while it takes a gang lock (`cleanupThread`,
`finishTenureForExit`, `reset`, `~Allocator`). (3) CR-003/015: `post`'s Idle->Posted CAS and the enqueue
in one `m_` section; the pool prepare drains and keeps `m_` in one section; the allocator layer locks
`thread_mutex_`, the child re-creates it and records `fork_child_` / `fork_owner_`. (4) CR-013/004:
`GCBackgroundGang::launch` returns false (refuses) while `fork_hold_`; `launchBackground` then leaves
`bg_ep_ = None` (`cm.episodes_refused`), `tenureLaunch` / `tenureConcLaunch` count `rs.fork_refusals`
and the join's orphan path finishes the job. (5) CR-023: `stopAndJoin` waits for
`generation_ != my_gen || finished_ >= members` and clears `running_` only for its own generation;
`launch` notifies `cv_done_`. (6) CR-005: `closingFinish` accepts `bg_ep_ == None`. (7) CR-031:
`~Allocator` (and `initThread`, `getCombinedStats`, `validatePageWork`) never touch a heap the forker
does not own in a forked child; validate builds check `ThreadLocalHeap::owner_` in `minorGC` /
`majorGC`. (8) CR-032: the census layer; `atexitReport` returns in a forked child. Trace-only: the
probe `m6.tm.held` in `onGCPauseEnd` (under `thread_mutex_`), `fork.bghold`, `gang.refuse`, the step
event's `refused` field and an M1 `stop` after a refused launch.

**w_pool_done**: the Done store (release, under m_ in `workerLoop`) and the acquire loads (wait's fast
path, `isDone`, `isIdle`) are unchanged; `post`'s Idle->Posted CAS (acq_rel) moved inside the existing
`m_` section with the enqueue (Concurrent mode; Sync keeps it outside), which only adds ordering. The
driver's post-then-wait shape is unchanged. **w_running_chain**: `running_` is still stored with
release (launch; a stopAndJoin of its own generation) and read with acquire by `running()`; the new
generation test in `stopAndJoin` (under `m_`) only removes a store (it no longer clears a relaunched
episode's `running_`), and `launch`'s `cv_done_.notify_all()` is a wake-up, not a publication. The
chain member -> m_ -> joiner -> running_ -> owner holds for the joiner of its own generation; a foreign
stopper whose generation was relaunched publishes nothing. GenMC is not installed here (as in Phases
1-4); audited by reading. **Verdict: no driver change needed.**
