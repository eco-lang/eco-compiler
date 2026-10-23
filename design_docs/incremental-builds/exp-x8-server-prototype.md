# X8: Server-mode prototype: many rebuilds in one process

**Status:** run on 2026-10-06 in a bootstrapped copy of the tree. Raw data is in
`/tmp/inc-exp/results/x8/` (`summary.txt`, `runs/<run>/{log.txt,rss.tsv,time.txt}`), and the
instrumentation in `experiments/x8-repeat-mode.diff` (`Terminal/Make.elm`, `Builder/Generate.elm`).

**Question (05, 07 §2):** is an always-on compiler process viable on the current runtime? How do
memory and fragmentation behave over many rebuilds, and can the old-gen compactor be used?

## Verdict

**Viable for memory, provided a full major GC plus release runs between builds.**
- Without it, the process sits on 5-11 GB.
- With it, peak memory is flat at about 4.8 GB, and RSS between builds is 0.6-0.8 GB.

**Two slow leaks would matter over hundreds of builds:**
- about 1.2 MB of live data per edit build that is never freed;
- about 16 MB per release of old-gen extent slack.

**The compactor is not usable as it stands.**

**A server alone buys nothing for speed.** In-process warm rebuilds are as slow as fresh-process
ones, and the typed program a server would keep resident is only about 105 MB and 0.55 s to reload.

## Method

**Instrumented binaries** (`build-eco.sh`) with an env-gated repeat mode:

| Switch | What it does |
|---|---|
| `ECO_EXP_REPEAT=N` | Runs the same `make` N times in one process |
| `ECO_EXP_REPEAT_GC=1` | Calls `Eco.GC.majorGC` (= `collectMajorAndRelease`) between builds; otherwise only a minor GC, for observation |
| `ECO_EXP_REPEAT_EDIT=<file>` | Rewrites a string-literal marker in a leaf module of a subject copy each iteration ("Compiled 1 module" confirmed every time) |
| `ECO_EXP_RETAIN=2` | Keeps the merged typed program (TOpt GlobalGraph + GlobalTypeEnv, the input to mono) resident between builds, approximating a server's retained state |

**Subject:** the compiler's own source, compiled to MLIR, with a warm on-disk cache.
- N = 10 builds per mode, and N = 3 for native executable output.
- RSS was sampled every 0.5 s, with a 20 GB abort that never triggered.
- Old-gen and fragmentation figures come from the runtime's GC reports and residency histograms.
- Every run held the machine-wide lock.

## Results (N = 10 in one process, warm cache, MLIR output)

| Mode | Build wall (mean) | Peak RSS | RSS between builds | Old-gen in use after build or release | Live after release |
|---|---|---|---|---|---|
| fresh process, warm (×3) | 43.5 / 43.9 / 45.6 s | 4.77 GB | — | — | — |
| fresh process, 1-module edit (×2) | 44.2 / 43.7 s | 4.77 GB | — | — | — |
| no GC between builds | 44.0 s | **11.05 GB** | 4.75-11.05 GB | high-water 4.2 → 10.5 GB | — |
| majorGC between builds | 44.3 s | **4.79 GB** | 596 → 700 MB (+11.5 MB/build) | 17 → 170 MB (+18.3 MB/build) | 0.0-0.5 MB |
| edit + majorGC | 44.4 s | 4.83 GB | 600 → 739 MB | 22 → 231 MB (+23 MB/build) | 1.2 → **12.3 MB** (+1.2 MB/build) |
| typed program kept + majorGC | 45.0 s | 4.97 GB | 797 → 802 MB | 211 → 340 MB (+14 MB/build) | 104-109 MB |

**Release cost:**
- about 280 ms (GC ~155 ms + discard ~125 ms) with ~0.5 MB live;
- about 300 ms with ~105 MB live;
- one release after 10 un-collected builds took 376 ms and took RSS from 11.0 GB to 0.75 GB.

**Native executable output in a loop** (N = 3, in-process LLVM back end):
- wall 99-104 s against 100.6 s for a fresh process;
- peak RSS flat at about 6.5 GB;
- about 1.1 GB of freed LLVM/MLIR heap stays in glibc until `malloc_trim`, which only the explicit
  release calls;
- after trim, about 400 MB more than MLIR-only runs stays resident, flat after build 2;
- builds 2-3 were about 3 % slower than build 1 in both modes. This is weak evidence (n = 3) of
  per-build accumulation in process-global back-end counters.

## Findings

1. **Retained state is small.** The merged typed program for the whole self-compile is about
   **105 MB live**, and reloading it from `.ecot` takes about **0.55 s**. Doc 05 estimated
   1.5-2.4 GB and 2-8 s; that estimate is corrected here.
2. **In-process warm rebuilds are not faster** (≤ 0.3 s, within noise). The cost of a warm build
   is the whole-program work after type checking, not process start or cache decode. This
   confirms 05 §3: a server is an enabler for incremental mono, not a win on its own.
3. **Leak 1: live data per build.** About 50 KB per no-change build and about **1.2 MB per edit
   build** are never freed.
   - Hypothesis, not instrumented: native MVars that are never dropped (they stay GC roots until
     `drop`), or kernel caches.
   - The survivors also pin pages: 51 pages (25 MB) hold 0.56 MB live after 10 builds.
4. **Leak 2: extent slack.** About 16 MB of old-gen "in use" per explicit release is not accounted
   for by blocks.
   - Probable cause (inferred from code): `Allocator::acquireOldGenBlock` reuses free extents
     first-fit *without splitting*. The code says "we accept the slack" (`Allocator.cpp` around
     line 960). After a release frees gigabytes of mixed-size extents, 512 KB requests take
     oversized extents.
   - At about 20 MB of high-water per build, the 20 GiB old-gen cap is reached after about 750
     builds.
   - The fix (split the extent, return the remainder) is in TLA-modelled allocator code, so the
     models must be checked first (`test/tla/README.md` "The canary").
5. **Compaction would recover only 25-90 MB after 10 builds,** less than the two leaks.
6. **The compactor (`OldGenSpace.hpp:2580`) is not wired, and is unsafe to call as is:**
   - it is reachable only from a test-access shim, and `shouldCompact` has no caller;
   - it rewrites pointers only inside old-gen blocks: no stack-map roots, RootSet roots, external
     scanners (MVar, CellStore, scheduler) or nursery referrers;
   - it recycles evacuated pages immediately, so unfixed referrers dangle;
   - it moves only 80 KiB per cycle and then walks the whole old gen.

   Making it usable means a root-fix pass, a nursery walk, a larger budget and a TLA review: days
   of work with crash risk. Fix the leaks first.
7. **IPC and file watching (confirmed).**
   - There is no socket, listen, accept, epoll, poll, select or inotify use anywhere in the kernels
     or runtime. HTTP is client only.
   - `Console.readLine` blocks the scheduler thread.

## What a real server needs (updates 05 §3)

1. A per-build `majorGC` + release (~0.3 s), or the process sits on 5-11 GB.
2. Fixes for leak 1 (MVar and kernel-cache hygiene) and leak 2 (extent splitting, with a TLA
   check). Until then, a restart policy, e.g. every few hundred builds or at an RSS threshold.
3. A socket service (or non-blocking stdin) and an inotify service (or mtime polling), in the
   Timer/Http service pattern.
4. Back-end global hygiene: process-global counters, and `malloc_trim` after native builds.
5. **Incremental mono, codegen and back end,** which is where all the time is. A server without
   them saves about 0.5 s per build.

## Limitations

- One subject; N = 10 (N = 3 for native).
- Other agents' jobs ran between runs; all timed runs held the lock.
- `RETAIN=2` keeps only the typed program, not mono state.
- Both leak causes are inferred from code plus numbers, not instrumented.
