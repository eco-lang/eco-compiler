# 05: Persistent state vs an always-on compiler server

> **Measured update (2026-10-06, X8: `exp-x8-server-prototype.md`).**
> - The merged typed program a server would keep is only **~105 MB live** and reloads in
>   **~0.55 s** (not 1.5-2.4 GB / 2-8 s).
> - In-process warm rebuilds are not faster than fresh-process ones.
> - With a `majorGC` + release between builds (~0.3 s), peak RSS is flat at ~4.8 GB and idle RSS
>   is 0.6-0.8 GB. Without it, RSS reaches 11 GB.
> - Two slow leaks (≈1.2 MB live per edit build; ≈16 MB of extent slack per release) cap a
>   process at a few hundred builds until fixed.
> - The compactor is not usable without a root-fix pass.

> User: "Whatever global information is serialized during a compile will be read back in on the
> next incremental compile. That motivates the possibility of having a compiler that runs in
> server mode, always on, so it keeps its caches in memory, allowing subsequent incremental builds
> to run faster without re-reading all its state from disk."

## 1. What would have to survive between builds

The list depends on the choices in 02-04.

| State | Needed for | Size and scale (self-compile) |
|---|---|---|
| Interfaces `.eci` and typed graphs `.ecot` | Already persisted | 8.74 MB of `.ecot` after the S3 type table |
| Registry creation-key → SpecId map, LSS member table, counters | Append-only ids (03 §2.1); only for the package pool under 03 §3 | ~43K registry rows allocated, ~34K kept; ~30.5K lambda-home member ids |
| Per-module back-end interfaces (02 §6) and their fingerprints | Early cutoff for codegen and back-end units | Small: one summary per exported symbol |
| Per-spec dependency records (consumed signatures, demanded keys, inlined provenance) | Incremental mono (04) | Proportional to call edges |
| Per-unit cache keys → object files | Back-end reuse (06) | One entry per unit |
| Owned mono / GlobalOpt results per module | Avoiding re-monomorphization of clean modules | The post-mono live set is only ~150-200 MB (`benchmarks/fhr-gc-points.md`) |

## 2. Option A: serialize to disk between runs

**Machinery.**
- The hand-written `Bytes` codecs exist for Source, Canonical, Optimized, interfaces, Details and
  TypedOptimized. `.ecot` has per-file string tables and a deduplicated type table.
- **There is no codec for Mono, GlobalOpt or MonoSolver state.** `AST/Monomorphized.elm` is 3,999
  lines with no encoder.
- The only serialization after mono is the MLIR bytecode writer (13.37 MB on the self-compile).

**Cost lessons from `.ecot`.**
- Cold cache serialization went from ~40 s to ~6.5 s.
- The cost was Elm Dict/Set work (computeVarSupers, interning), not byte writing: 449 MB took
  ~0.3 s to write.
- A Mono-state codec would probably cost seconds per build for the same reason. That is an
  inference, not a measurement.
- Warm `.ecot` decode was never timed on its own.

**Robustness.**
- A corrupt `.ecot` in the current version directory **segfaults** the compiler instead of
  recompiling. This is still open (fe-opt-loop G8 follow-up).
- The I64 bug showed that cached artifacts can silently miscompile until the format version is
  bumped.
- Long-lived caches need checksums and a "decode failure → rebuild" path before they can carry
  more state.

**Pragmatic middle ground** (the user's "balance between the two extremes"):
- persist only small, stable things: id counters and the package-pool table, interface
  fingerprints, unit cache keys, object files;
- recompute anything that can be recomputed per module cheaply from `.ecot`.

## 3. Option B: an always-on compiler server

**Benefits.**
- Live heap values need no codec. That avoids both the encode cost and the missing Mono codec
  (the native-MVar point in `fe-opt-loop.md:812-822`).
- Typed graphs, interfaces and per-module mono results stay resident, so load and decode
  (~2-8 s) disappear.
- Incremental mono is much easier to build against live state than against a serialized one.

**On its own it saves little.** It recovers only the ~2-8 s of load and decode. The rest of the
~64 s no-change rebuild (mono 23.8 s, codegen 12 s, back end ~21 s) needs the incremental
machinery in 02-04 and 06. **A server is an enabler and a multiplier, not the win itself.**

### 3.1 What the runtime would need

**Process model.**
- One mutator per process (HEAP_007 / CR-012 option F). Elm concurrency is cooperative, so builds
  run one at a time. That is fine for a per-project server.
- Builds already take a per-root file lock (`Stuff.withRootLockBuildDir`).

**Memory.**
- 24 GiB is reserved (4 GiB nursery, 20 GiB old-gen cap). A cold self-compile peaks at ~6.5 GB
  RSS.
- What stays resident depends on what is kept:

  | Kept between builds | Resident cost |
  |---|---|
  | Type-checked state | ~1.5-2.4 GB |
  | Only post-mono state | ~0.2 GB |

- **Returning memory after a build.** Freed blocks are `MADV_DONTNEED`'d only at the *next* major
  GC's pause, and `old_gen_committed` never shrinks (`Allocator.cpp:1023-1052`). So an idle
  server would sit on its garbage.
  - `Eco.GC.majorGC` → `collectMajorAndRelease` solves this. It took RSS from 8,005 MB to 917 MB
    in 347 ms (frontend-heap-release §11.5).
  - Today it runs once, before link. A server would run it after every build: ~0.5 s with ~150 MB
    live, ~1.7-2.7 s with 1.5-2.4 GB live.

**Fragmentation: the main long-run risk.**
- The old generation is non-moving.
- The incremental compactor exists (`OldGenSpace.hpp:2580`) but is reachable only from tests.
- Hundreds of builds in one process need either compaction wired in, or a policy to restart the
  server when fragmentation crosses a threshold. A restart is cheap if option A's persisted
  middle ground exists.

**IPC.**
- There is no server-side networking anywhere in the kernels or runtime: no `socket`, `listen`,
  `accept`, `epoll` or `poll`.
- Options, roughly in order of cost:
  1. A thin client that talks to the server over a Unix socket. This needs a socket service in
     the Timer/Http/Wait service pattern (POD state, a worker thread, completion posted to the
     scheduler).
  2. Stdin/stdout line protocol. But `Console.readLine` blocks the scheduler thread
     (`eco/Console.cpp:10-12`), so it needs a non-blocking reader service first.
  3. Embedding through native ports (`runtime/src/platform/PortRuntime.hpp`).

**File watching.**
- There is no inotify support. The File kernel has read, atomic write, lock, list, mtime and
  touch.
- Either poll mtimes on a timer, or add an inotify service in the same service pattern.
- Note that module invalidation is mtime-based today, not content-hash-based (01 §1).

**Native back end inside the server.**
- LLVM target init is guarded by a `static bool`.
- Each build creates a fresh `DialectRegistry` + `MLIRContext` + `LLVMContext` and its own worker
  threads, so nothing leaks across builds.
- But some process globals persist:
  - `gCensus` and `OptPassTimesGlobal` only accumulate;
  - three env flags are cached in `static const`, so changing them between builds has no effect.
- Back-end memory (~9 GB peak) is C++ heap that the Elm GC cannot see and `GCReport` doesn't
  count. Keeping MLIR/LLVM objects alive between builds would cost GBs. **Keep objects on disk,
  not LLVM state in memory.**

**Existing hooks.** `Eco.Runtime.saveState`/`loadState` provides a GC-rooted static slot
(`eco-kernel-cpp/src/eco/Runtime.cpp:46-60`). It would be the natural anchor for retained compiler
state.

### 3.2 Invalidation in a server

- The server knows which files changed, from the watch or the client's request, and re-runs the
  incremental pipeline.
- Config flags that change `Config.hash` invalidate everything, as today. A server could keep
  several configurations resident, but that is out of scope.
- **Correctness check.** In debug builds the server periodically compares an incremental result
  with a clean build in a child process. This is the analogue of G6.

## 4. Assessment

- Persisting a *small* middle ground (ids for the pool, fingerprints, unit keys, objects) is
  needed either way. It makes cold starts and server restarts cheap.
- A server is worth it once incremental mono exists. It removes the codec problem and the decode
  time, and makes live dependency tracking natural.
- Before that, it buys only ~2-8 s.
- Runtime work needed for a server:
  - IPC (a socket service);
  - file watching (inotify or polling);
  - a per-build `majorGC` release;
  - a fragmentation policy;
  - process-global hygiene in the native back end.
