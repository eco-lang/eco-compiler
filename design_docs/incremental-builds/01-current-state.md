# 01: Current state: what is incremental, and where the time goes

> **Measured update (2026-10-06, see `exp-x6-warm-timing.md`).**
> - The "≈ 5.8 s" lump in §3 is, on a cold build: typed-graph load 0.07 s, assign 3.0 s,
>   pre-mono 0.3 s, inline 0.85 s, GlobalOpt 1.35 s.
> - A warm *no-change* build and a warm *one-module-edit* build cost the same: **~43 s to MLIR**.
>   Of that, mono is 25 s, codegen 12.3 s, assign 2.9 s, and warm typed-graph load (all `.ecot`
>   decode) only 0.6 s.
> - On the 12-core test box the back end added ~56 s.
> - Touching `elm.json` (even rewriting identical bytes) makes the next build cold.

## 1. Incrementality up to type checking

### Artifacts

Each module has these files under `eco-stuff/<ver>[/<builddir>]/` (`Builder/Stuff.elm:128-151`):
- `.eci`: the interface;
- `.eco`: the untyped form, used by the JS path only;
- `.ecot`: the typed graph plus type env, used by the MLIR/ELF path.

Beside them are `d.dat` (build state and per-module `Local` records), `i.dat` and `o.dat`. Each
package has a `typed-artifacts.dat` under `~/.eco/<ver>/packages/...`
(`Builder/Elm/Details.elm:337-353`).

### Project-level invalidation

The cached `Details` is discarded and rebuilt with no locals in three cases
(`Details.loadWithTime`, `Details.elm:470-486, 826-835`):
- the `elm.json` mtime changes;
- the typed/untyped form flips;
- `Config.hash` changes. That hash is a token string such as `cthk=N` or `lchunks=1`
  (`Compiler/Eco/Config.elm:885`).

So any change to an artifact-affecting flag means a cold rebuild.

### Module-level invalidation

- A module is re-parsed if its path or mtime differs (`Builder/Build.elm:701`).
- A cached module is reused (`RCached`) when its dependencies report `DepsSame`. That means no
  dependency has a new interface and `lastDepChange <= lastCompile` (`Build.elm:1187`).
- The format is versioned by `typedGraphFormatVersion = 3` (`AST/TypedOptimized.elm:1601`).

### Early cutoff at type checking

After a module compiles, the old `.eci` is decoded and compared structurally with the new
interface (`Build.elm:1624`).
- Equal → `RSame`: dependents see `DepsSame` and are not re-checked.
- Different → `RNew`: direct importers recompile.

This is Elm's `_lastChange`/`_lastCompile` scheme (`Details.elm:224-234`), exercised by
`benchmarks/incremental-cache-check.sh`. That script's G6 gate requires the incremental build's
MLIR to be **byte-identical** to a cold build's, which bears on 03.

## 2. Everything after type checking runs whole-program on every build

**"Typed-graph load"** is `Generate.buildMonoGraph` (`Builder/Generate.elm:697-718`):
- load every package's typed artifacts;
- merge the fresh modules;
- stream-load and merge every cached `.ecot` (`:643-681`);
- run `AssignMVarIds` and the pre-mono passes (`:743-776`).

It has no timer of its own (`FEStats.elm:663-685`).

**Then, on every build:**
- monomorphization;
- inline and simplify;
- GlobalOpt;
- MLIR codegen to a temp file;
- `GcPoints.preLink`;
- in-process lowering and link.

There is no "output is up to date" check.

**Caches after mono: none.**
- No Mono, GlobalOpt, MLIR or object cache exists.
- `EcoJIT.h` includes LLVM's `ObjectCache.h`, but it is unused.
- The only MLIR cache is the E2E harness's config-blind mtime cache
  (`test/ElmE2ETestBase.hpp:447-458`).

## 3. Where the time goes (Stage 9b self-compile)

| part | time | incremental today? |
|---|---:|---|
| parse / check / build (≈ 6.5 s of it is cache encode and write) | 23.6 s | yes |
| monomorphization (with LSS) | 23.8 s | no |
| dependency check, typed-graph load, assign/pre-mono, inline, GlobalOpt | ≈ 5.8 s (by subtraction) | no |
| MLIR codegen | 12.0 s | no |
| C++ back end (parse 1.4 + pipeline 4.1 + partitions 13.9 + link 1.3) | ≈ 20.7 s | no |
| **cold total** | **86.6 s** | |

### No-change rebuild

- **Measured to `.mlir` (fe-opt-loop G5):** cold 68.83 s, **warm 43.35 s**, RSS 4.90 GB, MLIR
  identical (`benchmarks/fe-opt-loop.md:835-836, 866`).
- **Not measured to ELF.** Adding the back end gives roughly **64 s for a rebuild where nothing
  changed**. A one-module edit costs about the same, plus that module's recompile.

So the incremental part already saves ~25 s, and ~64 s of whole-program work remains. Of that:
- mono is the largest single block, at 23.8 s;
- codegen plus back end add ~33 s.

An incremental design has to take a bite out of all three. Caching only the back end would leave
about 30 s of whole-program front end on every edit.

## 4. Gaps in the measurements

The plan stage would need these:
- separate timers for typed-graph load and assign/pre-mono;
- a warm `--stats` run;
- a warm ELF (9b) run;
- a timed `.ecot` decode;
- GlobalOpt broken out from the 5.8 s.
