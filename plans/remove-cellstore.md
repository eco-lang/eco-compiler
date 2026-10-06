# Remove `Eco.CellStore`: an immutable point store, threaded explicitly

**Status:** DONE (2026-10-04): implemented, all gates green; measured +3.16 s (64.48 -> 67.64 s), accepted (fe-opt-loop entry `noCS`). **Byte-identical output:** yes. **Size:** small. Two phases, one
loop entry.

**Phases at a glance:**
- **§3, Phase A:** compiler source only. This is the measured change.
- **§4, Phase B:** delete the kernel module and everything that exists only to support it.
- **§5–6:** measurement and gates.
- **§7:** follow-ups, only if the cost matters.

## 1. Why

`Eco.CellStore` is a mutable, off-heap cell vector. The type checker and the mono solver keep their
union-find point store in it (`IO.State.ioRefsPoint`). Elm has no mutation, so the store needs:
- a *linearity contract* that the compiler cannot check (KERN_007): a stale handle reads changed or
  freed memory;
- a GC external root scanner (HEAP_047), and a second off-heap store class in the GC's TLA+ models;
- a pure twin in `src-xhr` that behaves differently from the kernel on stale handles;
- explicit undo scopes (`markStore` / `commitStore` / `rollbackStore`) at every speculative site;
- explicit lifecycle calls (`disposeThen`, `freeze`, `renew`, `release`), and `()` arguments on
  `freshState` / `freshStore` so that two states never share one store.

It went in as step 3 of `plans/lss-compile-time-optimizations.md` (2026-09-19). Before that step the
store was a persistent `Array PointCell`, already threaded by value. Step 3 made each write in place
instead of copying a trie path (loop entry `3`: −18.77 s, −5.2 %, at a 359 s wall).

**This plan goes back to an immutable store. It adds no monad and no new abstraction.** The store
stays where it is: a field of the state that is already passed explicitly from call to call:
- `IO.State` in the type checker;
- `S.store` in the mono solver, which is already direct state passing since step 10 retired the
  `Step` monad.

Nothing new is threaded. Speculation goes back to what a persistent value gives for free: keep the
old store and use it again.

**Out of scope:** the type checker's existing `System.TypeCheck.IO` state monad (`IO.andThen` and
friends, ~540 uses in `Type/*`). This plan neither extends it nor removes it. Replacing it with
explicit passing would be its own plan.

## 2. The store after the change

`ioRefsPoint : Array PointCell`, the core `Array`, used directly. There is no wrapper module, since
the old `Store` wrapper was an extra allocation per write (loop entry `8a`).

| today (`CellStore`) | after |
|---|---|
| `new 256` | `Array.empty` |
| `size` / `get` / `set` / `push` | `Array.length` / `Array.get` / `Array.set` / `Array.push`. Keep the out-of-range **crash** in `IORef` (core `Array.set` silently ignores a bad index) |
| `pushMark` … `rollback` | keep the pre-attempt store `s.store`; on failure put it back: `{ s1 \| store = s.store }` |
| `pushMark` … `commit` | nothing |
| `freeze` | the array itself |
| `disposeThen x`, `release _ keep` | `x`, `keep` |
| `renew` | `Array.empty` |

**Rollback is store-only.** Today `rollbackStore s1` keeps every *non-store* field of `s1` (stats,
counters) and only winds back the store. The replacement must be `{ s1 | store = s0.store }`, never
plain `s0`. Using `s0` would drop the attempt's stats and change census output.

## 3. Phase A: compiler source (the measured change)

| file | change |
|---|---|
| `System/TypeCheck/IO.elm` | `State.ioRefsPoint : Array PointCell`. `freshState` can become a constant, `emptyState` (the `()` argument existed only to avoid sharing a mutable store). `unsafePerformIO` drops `disposeThen`. Rewrite the module and `State` docs: no linearity contract, and an older state *is* a snapshot. |
| `Data/IORef.elm` | `readPointCellS` / `writePointCellS` / `newPointCellS` use `Array`. Delete the "read `size` before `push`" ordering hazard from the docs (it was real only in place). |
| `Compiler/Type/Solve.elm:133` | `cells = s.ioRefsPoint` |
| `Compiler/MonoSolver/Engine.elm` | `freshStore` becomes a constant. Delete `releaseScratch`, `renewStore`, `markStore`, `commitStore` and `rollbackStore`, plus their exports and docs. In `withScratchStore`, restore with `store = s0.store`. In `resetItem`, set `store = freshStore`. |
| `Compiler/MonoSolver/Store.elm` | `unifyBestEffort` (~1190): success ⇒ `s1`; failure ⇒ `{ s1 \| store = s.store }`. In the census sites `qCensusInto` (~1561/1637) and the settled replay (~2549/2579/2598), replace the `Engine.rollbackStore { sM \| … }` calls with `{ s \| … }`, because `sM` differed from `s` only in the store. |
| `Compiler/MonoSolver/Translate.elm` | `classifyRef` (~1749–1765): delete the four nested mark/commit brackets (no `Err` arm is left, so they are pure overhead now). The ~4747 site works like `unifyBestEffort`. In the scratch at ~5398/5409, set `store = freshStore` and restore `s0.store`. |
| `Compiler/MonoSolver/Monomorphize.elm` | ~208: drop `disposeThen`; ~3927: `Engine.freshStore`. |
| `Compiler/Type/UnionFind.elm`, `Unify.elm` | comment-only: remove the linearity and "caller must bracket" text. |
| `compiler/src-xhr/Eco/CellStore.elm` | delete (the pure twin). |
| tests | delete `TestLogic/CellStoreTest.elm`. In `GroundAliasMemoTest`, change `CellStore.size` to `Array.length` and drop the import. In `GroundAliasMemoTest` and `ArrowIdentityTest`, change `Engine.freshStore ()` to `Engine.freshStore`. |

**Check:** `grep -rn "CellStore\|markStore\|commitStore\|rollbackStore\|releaseScratch\|renewStore"
compiler/` returns nothing.

## 4. Phase B: delete the kernel module (after A builds)

- **`eco-kernel-cpp`:**
  - delete `src/Eco/CellStore.elm`, `src/Eco/Kernel/CellStore.js` and
    `src/eco-kernel/CellStore{.hpp,.cpp,Exports.cpp}`;
  - remove the entry from `elm.json` `exposed-modules`;
  - remove the export declarations from `src/eco-kernel/KernelExports.h`;
  - remove the `Eco_Kernel_CellStore_register_gc_roots()` call from `src/eco-kernel/RuntimeExports.cpp:48`.
- **License pins:** `RuntimeExports.cpp` is hash-pinned in
  `compiler/src/Compiler/MonoSolver/kernel-license-manifest.txt` (the 4 `Runtime.*` rows).
  - Re-pin those rows.
  - Update the 4 evidence strings in `KernelSetFacts.elm` (~1854–1875) that mention the CellStore
    hook.
  - `kernel-license-check` must pass.
- **CMake:**
  - `eco-kernel-cpp/CMakeLists.txt`: the library at 180–189 and the lists at 289 and 302;
  - `runtime/src/codegen/CMakeLists.txt:932` (`ECO_KERNEL_MODS`);
  - `test/CMakeLists.txt`: the 9 whole-archive / force-load / link entries;
  - re-run `cmake --preset build`, because sources are globbed at configure time.
- **Codegen special cases:**
  - `Generate/MLIR/KernelAbi.elm` ~406–445: delete the CellStore fail-stop arms, and the matching
    case in `KernelAbiTest`;
  - `GlobalOpt/CafHoist.elm` ~449: drop `|| home == "CellStore"`, and fix the 5 doc mentions and
    the `CafHoistTest` comment.
- **E2E tests:** delete `test/eco-kernel/src/CellStore{Roundtrip,Rollback,GcSurvival,FreshHandles}Test.elm`.
- **Invariants (`design_docs/invariants.csv`):**
  - set HEAP_047 and KERN_007 to `retired` ("RETIRED 2026-10-xx by plans/remove-cellstore.md");
  - drop CellStore from HEAP_SNAPSHOT_002's wording (MVar and the others still apply).
- **TLA+:** `test/tla/census/grep__F.externalRoots.txt` loses its CellStore line, so `tla-canary`
  will fail.
  - Per GC_MODEL_001, check the models first: `SnapshotMark.tla` `CellSlots` and `Tenuring.tla`
    `Roots` still model MVar and the other scanners, so this is a comment change, not a model change.
  - Then re-pin per `test/tla/README.md`, and update the comment mentions in `SnapshotMark.tla`
    (8, 361, 364), `Tenuring.tla:19` and `M1-snapshot-mark/MAPPING.md:20`.
- **Docs:** fix the mentions in `design_docs/parallel-gc.md` and the comment at
  `test/allocator/IncrementalMarkTest.cpp:478`.
- **Kernel package cache:** move `~/.eco/0.1.3/packages/eco/kernel/1.0.0` aside, because the local
  kernel package is copied into the cache once and never refreshed.

**Check:** `grep -rn CellStore` over `compiler eco-kernel-cpp elm-kernel-cpp runtime test design_docs`
finds only retired invariant rows and plan/benchmark history.

## 5. Measurement

Run one `benchmarks/fe-opt-loop.md` entry, named `noCS`, using Phase 1.3/1.4 and the Phase 2
triple. Judge it against the `tidy-check` row (64.48 s; parse/check/build 23.3 s; mono 23.3 s; minor
GC 1130; promoted 6311 MiB).
- **Fixed point and determinism are the gate.** The same cells are read and written in the same
  order, `push` gives the same index, and putting the old store back equals the old rollback (cells
  *and* count). So the output must be byte-identical to the tidy-check `.mlir` as well.
- **A regression is expected.** Each write copies a trie path again, and minor GC count and
  promoted MiB will rise. At step 3 the in-place store was worth 5 % of a 359 s run. The workload has
  shrunk a lot since then, so the current share is unknown. Lead the entry with the
  parse/check/build and mono phase times, because both contain union-find work.
- **This change ships as a design decision**, with its cost recorded (the precedent is the GC series'
  correctness-first rule). If the cost is large, §7 lists follow-ups that stay immutable and add no
  monad.

## 6. Gates (after the triple, as a separate pass)

1. `cmake --build build --target elm-tests`: green means the known 12 failures only.
2. `cmake --build build --target full` (E2E; the 4 CellStore kernel tests are gone).
3. `--target bootstrap` + `eco-verify`: the 4b JS and 8c native fixed points. Stage 1 (stock Elm)
   loses the `src-xhr` twin.
4. `kernel-license-check` and `tla-canary` (strict) green after the re-pins in §4.
5. `run-aot-e2e`, with `build/test/aot-e2e/*/eco-stuff` moved aside first: 2 known harness gaps.

## 7. Follow-ups if the cost matters (not part of this plan)

All of these keep the store immutable and passed explicitly:
- **Skip no-op writes:** don't write a cell that is already known to be unchanged (for example a
  compression link that already points at the root). Do path compression only when the path is
  longer than one link.
- **Pass the bare array through the hot union-find helpers** (`reprS`, `unionS`, `freshS`) instead of
  rebuilding the `IO.State` record on every write.
- **Re-read loop entries `8a`/`8b`** (compression trade-offs): their premise changes back once
  writes copy again.

**Result (2026-10-04, fe-opt-loop entries `uf1` and `uf2`): both measured FLAT and were reverted.**
Passing the bare array (with `Int` point compares) left wall unchanged at 67.64 s. Skipping
`adjustRank`'s unchanged-rank write left parse/check/build unchanged at 24.5 s, with minor GC +8.
The profile puts the remaining cost in the persistent array itself (trie reads and path copies),
which no immutable rewrite of these call sites removes.
