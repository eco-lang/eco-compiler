# Plan: Local package as read-only seed + per-module compiled-form check

## Context

Two independent caching bugs surface when the installed `eco` binary auto-locates
the bundled kernel at `/usr/local/share/eco/kernel/eco-kernel-cpp` (see
[`local-package-eco-kernel.md`](local-package-eco-kernel.md), whose original design
decision "Artifact location: written into the local package directory" this plan
revises):

1. **Package layer** — building `eco/kernel` writes `artifacts.dat` /
   `typed-artifacts.dat` *into the `--local-package` source directory*. When that
   directory is the root-owned install dir, the write fails:
   `Eco crash: IO error: permission denied: …/eco-kernel-cpp/artifacts.dat`.

2. **Project layer** — building one source for the native/MLIR target
   (`--output=foo`) then for JS (`--output=foo.js`) from one `eco-stuff/` yields a
   misleading `CORRUPT CACHE`. The native build writes only `Hello.ecot` (typed)
   and deliberately skips `Hello.eco` (untyped); the JS build sees the unchanged
   source as cached, never checks that `.eco` exists, then fails to load it.

These are distinct layers with distinct fixes. Do **Change 2 first** — it is
self-contained and independently testable.

---

## Change 2 — symmetric per-module compiled-form check

### Problem

The per-module "already compiled?" decision in `Build.elm`'s
`handleCachedDepsStatus` (`DepsSame` branch, lines 826-841) is asymmetric:

- Native build (`needsTypedOpt = True`): checks `File.exists (Stuff.ecot root name)`;
  if the `.ecot` is missing it recompiles (lines 830-832 →
  `handleCachedWithTypedOptCheck` 870-882).
- JS build (`else`, 834-841): unconditionally returns `RCached` **without checking
  that `Stuff.eco root name` exists**.

So after a native build leaves `.ecot` but no `.eco`, the JS build trusts the
source-mtime "cached" verdict, then `readAndStoreCachedObject`
(`Generate.elm:345-347`) reads the missing `.eco`, gets `Nothing`, →
`Exit.GenerateCannotLoadArtifacts` → rendered by `corruptCacheReport`
(`Exit.elm:2495-2496`). It is a target-artifact mismatch, not real corruption.

The codebase already uses **on-disk artifact presence** as the form signal — the
fix completes the symmetry rather than adding a new `d.dat` field. (A
`compiledForm` field on `LocalData` with `localEncoder`/`localDecoder` migration
would duplicate a signal disk already carries and could disagree with it; rejected.)

### Changes

**File:** `compiler/src/Builder/Build.elm`

1. Generalize `handleCachedWithTypedOptCheck` (line 870) into a shared helper
   parameterized by the artifact path + an `exists : Bool`, branching to:
   - exists → `Utils.newMVar cachedInterfaceEncoder Unneeded |> Task.map (RCached hasMain lastChange)`
   - missing → `loadInterfaces root same cached |> Task.andThen (recompileIfInterfacesLoaded …)`
2. In `handleCachedDepsStatus` `DepsSame` (827-841): keep the `needsTypedOpt`
   branch checking `Stuff.ecot`; change the `else` branch to check
   `File.exists (Stuff.eco root name)` and route through the same helper instead of
   unconditionally returning `RCached`.

The JS recompile writes `.eco` because, with `needsTypedOpt = False`, the compile
produces `typedObjects = Nothing` and `writeUntypedObjectsIfNeeded`
(`Build.elm:1509-1520`) takes the write branch.

### Cost / risk

One extra `stat` per cached module on the JS path (the native path already pays
the symmetric cost). No `d.dat` schema change. Low risk.

---

## Change 1 — local package as read-only seed, build into ECO_HOME

### Problem

`Stuff.package` (`Stuff.elm:289-300`) returns the `--local-package` **source path
directly** for a local package, so every package read (elm.json, `src/**`) *and
write* lands there: `artifacts.dat` (`Details.elm:1278`), `typed-artifacts.dat`
(`Details.elm:1262`), `docs.json` (`Details.elm:1876`). A read-only source dir
makes the writes fail.

### Design

Treat the `--local-package` path as a **read-only seed**. On first use, copy the
package source into the normal cache (`~/.eco/<ver>/packages/eco/kernel/1.0.0/`)
and build artifacts there — so a local package behaves like a normal downloaded
package after seeding.

**Decisions (chosen):**

| Decision | Choice |
|----------|--------|
| Freshness | **Copy only when the cache package dir is absent.** No source-mtime stamp. Matches today's fingerprint-based staleness; a kernel source edit needs the cache pkg dir cleared to take effect. |
| Prebuilt `.dat`s | **Source only, recompile.** Copy `elm.json` + `src/**` + LICENSE/README (all text); do not copy `artifacts.dat`/`typed-artifacts.dat`. Kernel recompiles once into the writable cache per fresh `~/.eco`. No binary-safe copy needed. |

### Changes

1. **`compiler/src/Builder/Stuff.elm`** — `Stuff.package` (289-300): drop the
   `maybeLocal` special-case; always return the cache path
   `dir/<author>/<name>/<version>`. Keep `maybeLocal` in `PackageCache` and
   `isLocalPackage`. Add `localPackageSource : PackageCache -> Pkg.Name -> Maybe FilePath`
   to retrieve the seed path. This single chokepoint redirects all ~11
   `Stuff.package` read/write consumers to the writable cache.

2. **`compiler/src/Builder/File.elm`** — new `copyDir : FilePath -> FilePath -> Task Never ()`:
   recursive text copy using `Utils.dirListDirectory` + `readUtf8`/`writeUtf8` +
   `dirCreateDirectoryIfMissing`, with the same whitelist as `File.writePackage`
   (212-232: `src/`, `elm.json`, `LICENSE`, `README.md`). Source-only ⇒ `.dat` /
   `docs.json` naturally excluded, so no binary copy is required.

3. **`compiler/src/Builder/Elm/Details.elm`** — `handleDepExistence` (914-923):
   replace the `else if Stuff.isLocalPackage … → BD_LocalPackageNotFound` branch
   with a new `seedLocalPackage ctx`:
   - seed source (`localPackageSource`) and its `src/` exist →
     `File.copyPackageSource seed (Stuff.package …)` then `handleCachedDep ctx`;
   - else → `BD_LocalPackageNotFound`.

   After the copy, `checkArtifactCache` (932-940) finds no
   `artifacts.dat`/`typed-artifacts.dat` → `handleArtifactCache`/`handleTypedArtifactCache`
   `Nothing` branch → `build` → compiles the kernel from the copied source and
   writes artifacts into the writable cache. Rejoins the normal flow; no new build
   path.

4. **`compiler/src/Builder/Deps/Solver.elm`** — constraint loading (`getConstraints`,
   ~617-618) reads a package's `elm.json` via `Stuff.package`, which now points at
   the not-yet-seeded cache. The solver runs *before* `verifyDep` seeds the copy,
   so for a local package read `elm.json` from `Stuff.localPackageSource` instead
   (the one legitimate pre-seed read; everything post-seed uses the cache path).
   Without this the solver falls back to the registry and 404s on `eco/kernel`.

### Risk

The `Stuff.package` semantic change touches every package read/write — but routing
through one chokepoint is safer than redirecting writes piecemeal. The bootstrap /
E2E builds pass explicit `--local-package=/work/eco-kernel-cpp` and share the real
`~/.eco` (no build sets `ECO_HOME`), so a one-time seed-copy happens and **kernel
edits during dev now require clearing `~/.eco/<ver>/packages/eco/kernel/`** to take
effect. Document this gotcha.

---

## Verification

- **Change 2:** MLIR then JS build of `examples/Hello.elm` sharing one `eco-stuff/`
  — both succeed (currently the second prints `CORRUPT CACHE`).
- **Change 1:** clean `~/.eco`; no-flag `eco make src/Hello.elm --output=hello`
  (native) then `--output=hello.js` (JS) against the installed read-only kernel —
  both succeed; `~/.eco/<ver>/packages/eco/kernel/1.0.0/` ends up with the copied
  `src/` + freshly-built `artifacts.dat` and `typed-artifacts.dat`.
- **Bootstrap:** `cmake --build build --target full` still passes with the explicit
  `--local-package=/work/eco-kernel-cpp`.

## Sequencing

1. Change 2 (Build.elm only) → verify the MLIR→JS sequence.
2. Change 1 (Stuff.elm + File.elm + Details.elm) → verify the installed no-flag
   native+JS sequence and the bootstrap.
