# Plan: Build-tree `eco/kernel` resolution (B) + a clear "kernel not found" error (D)

## Summary

A clean `eco make` of an app that depends on `eco/kernel` fails with `INCOMPATIBLE
DEPENDENCIES` when run from the **build tree**. Root cause: `eco/kernel` is a
bundled package (not in `registry.dat`); the solver can only resolve it if it is
registered as a *local package*, which `Terminal/Make.resolveLocalPackage` does
automatically **only** when it finds the kernel at
`dirname(exe)/../share/eco/kernel/eco-kernel-cpp` (the install layout). The
build-tree binary (`build/compiler/build-kernel/bin/eco`) has no such sibling, so
`resolveLocalPackage → Nothing` → `eco/kernel` is treated as a registry package →
`Registry.getVersions` returns `Nothing` → `getRelevantVersions` backtracks →
`Solver.NoSolution` → `Exit.DetailsNoSolution` → "INCOMPATIBLE DEPENDENCIES".

This plan implements two of the four options from the investigation:

- **Option B (build-side):** have CMake mirror the install layout in the build
  tree by symlinking `${BUILD_KERNEL_DIR}/share/eco/kernel/eco-kernel-cpp` →
  `${CMAKE_SOURCE_DIR}/eco-kernel-cpp`. The *existing* probe then resolves with
  **zero compiler change**, so the build-tree binary behaves like an installed one.
- **Option D (compiler-side):** when solving fails specifically because the
  bundled kernel could not be located, emit a precise, actionable error instead of
  the misleading generic `INCOMPATIBLE DEPENDENCIES`.

Not in scope: Option A (hardening `resolveLocalPackage` with an ancestor walk /
`ECO_KERNEL_PATH`) and Option C (teaching the solver to read the kernel from the
package cache). See `build-tree-kernel-resolution-and-error.md` companion notes /
the investigation summary for those.

## Design Decisions

| Decision | Choice |
|----------|--------|
| Build-tree probe parity | Symlink, not copy — `share/eco/kernel/eco-kernel-cpp` → source kernel, matching `install(DIRECTORY …)` |
| Where the symlink is created | `compiler/CMakeLists.txt`, next to the existing `src` / `src-kernel` dir-links (~line 200), via `eco_create_dir_link` |
| Link reuse | Reuse `eco_create_dir_link` (already handles Win/Unix + canonicalization); `MAKE_DIRECTORY` the parent first |
| D: detection point | In `Details.verifyConstraints`, the `Solver.NoSolution` branch — it already holds `Env` (cache + registry) and the constraint set |
| D: trigger condition | bundled kernel pkg ∈ stated constraints **AND** not `isLocalPackage` **AND** `Registry.getVersions` = `Nothing` |
| D: new error | New `Exit.Details` variant `DetailsBundledKernelMissing` with a dedicated report |
| Kernel pkg constant | Add `Pkg.ecoKernel = ("eco","kernel")` (shared) rather than importing `Terminal.Make.ecoKernelName` into `Builder` |
| Scope | Single PR; B and D are independent and can land/revert separately |

## Background (verified)

- `resolveLocalPackage` returns `Just (eco/kernel, path)` — identical to
  `--local-package eco/kernel=…` — the moment it finds the kernel dir
  (`Terminal/Make.elm:219`). That output is **already sufficient** for the solver:
  `eco make … --local-package eco/kernel=/work/eco-kernel-cpp` solves on a clean
  tree and writes a valid `d.dat`. So **no separate "register with solver" step is
  needed** — only the *find* must succeed.
- `nodeGetDirname` → native `currentExecutableDir()` (`/proc/self/exe` dir), so the
  probe base for the build-tree binary is `…/build-kernel/bin`.
- `eco` and `eco-quick` both output to `${BUILD_KERNEL_DIR}/bin`
  (`compiler/CMakeLists.txt:857-860`), so a single symlink at
  `${BUILD_KERNEL_DIR}/share/eco/kernel/eco-kernel-cpp` serves them all.
- Local packages always resolve as version `V.one` = `1.0.0` (`Version.elm:144`);
  `eco/kernel` is `1.0.0`, pinned `1.0.0` in apps → satisfies. (Caveat below.)

## Steps — Option B (CMake build-tree symlink)

### B1. Create the share-tree symlink next to the build-kernel binaries

**File:** `compiler/CMakeLists.txt` (immediately after the existing dir-links at
~lines 200-201, which already create `src` and `src-kernel`).

```cmake
# Mirror the install layout in the build tree so the build-tree `eco`/`eco-quick`
# binaries auto-resolve the bundled kernel the same way an installed binary does.
# resolveLocalPackage probes dirname(exe)/../share/eco/kernel/eco-kernel-cpp;
# dirname(exe) here is ${BUILD_KERNEL_DIR}/bin.
file(MAKE_DIRECTORY ${BUILD_KERNEL_DIR}/share/eco/kernel)
eco_create_dir_link(${CMAKE_SOURCE_DIR}/eco-kernel-cpp
                    ${BUILD_KERNEL_DIR}/share/eco/kernel/eco-kernel-cpp)
```

**Why this location:** the link target (`${CMAKE_SOURCE_DIR}/eco-kernel-cpp`) is the
kernel *package* root — it has `elm.json` + `src/`, exactly what
`localPackageSource`/`getConstraints` read. It mirrors the three
`install(DIRECTORY eco-kernel-cpp DESTINATION share/eco/kernel/eco-kernel-cpp)`
rules (CMakeLists.txt:550/695/758).

### B2. Confirm no interference with the bootstrap stages

The bootstrap self-compile stages (`eco-compiler`, `eco-compiler-boot`, …) also live
in `${BUILD_KERNEL_DIR}/bin` but compile the *compiler* and already pass explicit
`--kernel-package eco/compiler` + `--local-package eco/kernel=…`; `resolveLocalPackage`
short-circuits on an explicit `--local-package`, so the new symlink is inert for them.
No change needed — just verify the bootstrap still succeeds (it builds the default ALL
graph, which now also materializes the link).

## Steps — Option D (precise "bundled kernel not found" error)

### D1. Add a shared `eco/kernel` package constant

**File:** `compiler/src/Compiler/Elm/Package.elm`
Add and expose `ecoKernel : Name` = `( "eco", "kernel" )` (next to the existing
`kernel`, `core`, … constants). Avoids importing `Terminal.Make` into `Builder`.

### D2. New `Exit.Details` variant + report

**File:** `compiler/src/Builder/Reporting/Exit.elm`
- Add `DetailsBundledKernelMissing` to `type Details` (near `DetailsNoSolution`,
  line ~1481).
- Add a `toDetailsReport` case rendering an actionable message, e.g.:

  > -- BUNDLED KERNEL NOT FOUND --
  > Your project depends on `eco/kernel`, which ships with eco rather than the
  > package registry. eco couldn't locate it next to the executable
  > (`<dir>/share/eco/kernel/eco-kernel-cpp`).
  > Fixes: install eco so the kernel sits at `<prefix>/share/eco/kernel/…`; or pass
  > `--local-package eco/kernel=<path-to>/eco-kernel-cpp`.

### D3. Detect the condition in the solver-failure branch

**File:** `compiler/src/Builder/Elm/Details.elm` — `verifyConstraints`
(line ~674). In the `Solver.NoSolution` branch, branch on a helper:

```elm
Solver.NoSolution ->
    if bundledKernelUnresolvable envData constraints then
        Task.throw Exit.DetailsBundledKernelMissing
    else
        Task.throw Exit.DetailsNoSolution
```

Helper (same module), using data already in `Env`:

```elm
bundledKernelUnresolvable : EnvData -> Dict Pkg.Name C.Constraint -> Bool
bundledKernelUnresolvable envData constraints =
    Dict.member Pkg.ecoKernel constraints
        && not (Stuff.isLocalPackage envData.cache Pkg.ecoKernel)
        && (Registry.getVersions Pkg.ecoKernel envData.registry == Nothing)
```

**Why here:** `verifyConstraints` is the single funnel for `Solver.verify`
(`verifyApp`/`verifyPkg` both route through it) and already destructures `Env`
(`cache`, `registry`). The check is cheap and only runs on the failure path, so it
adds nothing to the success path. It is deliberately narrow — it fires *only* when
the kernel is genuinely both un-local and absent from the registry, so a real
version conflict still reports `DetailsNoSolution`.

### D4. (Optional, same PR) Verify `Solver` exposes equality on `KnownVersions`/`Maybe`

`Registry.getVersions … == Nothing` needs no extra API. Confirm `Pkg.Name`
comparability for `Dict.member` (it is — used as a Dict key throughout).

## Testing / Verification

1. **B, primary:** `rm -rf projects/eco-test/eco-stuff`; ensure `~/.eco` lacks the
   justgook subtree; run the **build-tree** binary with **no flag**:
   `build/compiler/build-kernel/bin/eco make src/Hello.elm --output=test`.
   Expect: solving succeeds (no `INCOMPATIBLE`), the dep closure compiles
   (`typed-artifacts.dat` written for `justgook/elm-image` + `danfishgold/base64-bytes`
   + `folkertdev/elm-flate`), build proceeds past monomorphization. This also
   confirms the original `no annotation entry … Image.decode` crash is gone by
   construction (no empty graph).
2. **B link presence:** `ls -l build/compiler/build-kernel/share/eco/kernel/eco-kernel-cpp`
   resolves to `…/eco-kernel-cpp/elm.json`.
3. **D positive:** temporarily move/rename the symlink (and ensure no
   `--local-package`) → expect the new `BUNDLED KERNEL NOT FOUND` report, **not**
   `INCOMPATIBLE DEPENDENCIES`.
4. **D negative (no false positive):** with the kernel resolvable but a genuinely
   conflicting pin (e.g. hand-edit an indirect dep version) → still
   `INCOMPATIBLE DEPENDENCIES` (`DetailsNoSolution`).
5. **Regression:** `cmake --build build --target bootstrap` still completes (symlink
   is inert for the self-compile stages); installed-layout probe unchanged.

## Risks / Caveats

- **Version pin assumption:** local packages always resolve as `1.0.0`. If
  `eco/kernel` is ever bumped, the local/symlink path can't satisfy a `> 1.0.0`
  pin (`getRelevantVersions` filters `[V.one]`). Out of scope here; note in code.
- **Single local-package slot:** `PackageCache` holds one `Maybe (Pkg.Name, FilePath)`.
  B doesn't change that (it provides a *directory*, consumed by the existing probe,
  not a second local slot), so a user's explicit `--local-package foo=…` still wins
  and still works. No regression.
- **Symlink portability:** `eco_create_dir_link` already abstracts Win (junction) vs
  Unix (symlink); the FATAL_ERROR-on-missing-target guard means a misconfigured
  source tree fails loudly at configure time, which is acceptable.
- **D is a safety net, not the fix:** with B in place D should rarely fire in the
  build tree; its value is turning the *remaining* miss modes (relocated binary, no
  install, stripped share dir) into a legible message.

## Out of scope (follow-ups)

- Option A: ancestor-walk + `ECO_KERNEL_PATH` override in `resolveLocalPackage`
  (makes a *relocated/stand-alone* binary self-sufficient without the build symlink).
- Option C: solver reads `eco/kernel` straight from the package cache.
- The `loadSinglePackageTypedArtifacts` silent-empty-graph robustness fix (separate
  defense-in-depth; tracked in the missing-typed-artifacts investigation).
