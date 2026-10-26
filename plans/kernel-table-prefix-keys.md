# Plan: Key the Kernel Tables by Prefix, Home and Name (SD-16, native side)

**Status: DONE 2026-10-26.** Gates: elm-tests 918/0 and 14,439/0; bootstrap 4b, 8c and 9b OK;
byte-identity corpus 169/169 identical; `full` native 2,492/2,492 and JS E2E 207/209 (see below).

## Context

A kernel function is named `<Prefix>.Kernel.<Home>.<name>`, where the prefix is `Elm` (elm/core,
elm/file, elm/http) or `Eco` (eco/kernel, eco/system). Three compiler tables key a kernel by
`( home, name )` only:

- `Compiler.Type.KernelTypes`: the per-module table of types recorded for kernel uses.
- `Compiler.GlobalOpt.KernelFacts`: the global table of effect, GC, borrow, CSE and devirt facts.
  `Borrow/KernelSigs` is a shim over it.
- `Compiler.MonoSolver.KernelSetFacts`: the global table of lambda-set licences (LSS_022).

So `Elm.Kernel.File.size` and `Eco.Kernel.File.size` share a key. Three homes exist in both
kernels: `File`, `Http` and `Process`. Only `File.size` shares a name.

None of this is a live bug today:
- `KernelTypes` is built per module, and no module calls both prefixes.
- `KernelFacts` has no `File.size` row.
- The one `KernelSetFacts` row for `File.size` was audited against both kernels.

The hazard is the next row added for a name both kernels have. This plan removes it.
`Compiler.Type.KernelIntrinsics` already keys by `( prefix, home, name )`; the other three follow
it.

The prefix is available at every lookup site. `Can.VarKernel`, `TOpt.VarKernel` and
`Mono.MonoVarKernel` all carry it. An emitted symbol starts with `Elm_Kernel_` or `Eco_Kernel_`,
so `splitSymbol` can keep the prefix instead of dropping it.

Out of scope: the hard-coded dispatches on elm/core kernels, such as `Generate/MLIR/Intrinsics`,
both `KernelAbi` modules and `BytesFusion/Reify`. None of them names `File`, `Http` or
`Process`, so they cannot mistake an Eco kernel for an Elm one today.
`test/scripts/check-kernel-homes.sh` keeps guarding new shared homes for their sake.

## Steps

1. **Tables.**
   - Every row key becomes `( prefix, home, name )`. A script derives each row's prefix:
     - `KernelSetFacts` rows from their `files`: `elm-kernel-cpp/...` gives `Elm`;
       `eco-kernel-cpp/...` and `system-kernel-cpp/...` give `Eco`.
     - `KernelFacts` rows from their `evidence` paths, the same way.
     - A row with no path, or paths into both kernels, is decided by hand.
   - The `File.size` licence row splits into one row per prefix. Each new row cites only its own
     kernel's files and carries the shared evidence.
2. **APIs.**
   - `KernelTypes.lookup`, `hasEntry` and `insertFirstUsage` take the prefix.
   - `KernelFacts`:
     - `lookup`, `devirtOf` and the `...For` forms take `( prefix, home, name )`.
     - `splitSymbol` returns it.
   - `KernelSigs.lookup` and `KernelSetFacts.factFor` take the prefix too.
3. **Callers.** Each lookup site passes the prefix carried by the `VarKernel` it already holds,
   or by the `KernelInstanceKey`.
4. **Tests and scripts.**
   - Update the suites that build keys: `KernelFactsTest`, `KernelLicenseTest` and the
     `KernelTypes` test logic.
   - Add a test that a lookup under the other prefix misses.
   - `check-kernel-license-manifest.sh` reads the three-part keys. Licence pins are labelled
     `<Prefix>.<Home>.<name>`, so they cannot be mistaken for intrinsic pins
     (`<Prefix>.Kernel.<Home>.<name>`). Regenerate the manifest. Only labels change: no C++ file
     changed, so no re-audit is due.
   - Update the comment in `check-kernel-homes.sh`.
5. **Records.**
   - Amend KERNEL_FACTS_001, whose keys are now prefix-qualified.
   - Mark SD-16 fixed in `review-bug-list.md`.
6. **Gates.**
   - elm-tests.
   - The **byte-identity corpus**: the new native compiler must emit byte-identical MLIR to the
     old one. Each binary uses a fresh package cache. The corpus is a frozen copy of the
     compiler's own source (self-compile), every `test/eco-kernel` and `test/elm-http` program,
     elm-core's `Process*` tests, and the eco-system tests importing `File`, `Http`, `Process`,
     `FileSystem` or `ChildProcess` (169 programs).
   - `--target full` once, and a bootstrap (the 4b and 8c fixed points).

## Baseline (taken before any change)

- `eco-before` is a copy of `build/compiler/build-kernel/bin/eco-optfix`, the 24 Oct bootstrap of
  this tree. Its self-compile of the frozen source is byte-identical to `ecofix.mlir`, saved that
  day.
- The corpus compiled cleanly: 169 programs, 0 failures.

## Progress

- **Tables.**
  - The script re-keyed the 75 `KernelFacts` rows and 236 `KernelSetFacts` rows.
  - 35 rows are in shared homes. Each was decided by its evidence and cross-checked against the
    exported C++ symbols: the chosen kernel defines the name, and the other kernel does not.
  - `File.size` split into an `Elm` row (elm/file's `FileExports.cpp`; that native export is an
    `assert(false)` stub) and an `Eco` row (eco/kernel's `File.cpp` and `FileExports.cpp`). Each
    row keeps its half of the 2026-10-03 evidence.
- **APIs and callers.**
  - The `KernelTypes`, `KernelFacts`, `KernelSigs` and `KernelSetFacts` lookups take the prefix.
  - `splitSymbol` keeps the prefix.
  - `Mono.OriginKernel` gained the prefix.
  - In `Translate`, the kernel id is `( prefix, home, name )`, cut to `( home, name )` only where it
    reaches `KernelAbi`'s elm/core dispatch.
  - The census label of `recordRefusedLicense` includes the prefix.
- **Tests.**
  - `KernelFactsTest` and `KernelLicenseTest` goldens were re-keyed.
  - New tests:
    - KernelFactsTest 8: a row is found only under its own prefix, by `lookup` and by
      `lookupSymbol`.
    - KernelLicenseTest 15: `File.size` has one row per kernel, and `Elm.File.open` misses.
    - KernelLicenseTest 16: no licensed row cites the other kernel's C++.
  - elm-tests: 918/0 and 14,439/0, the earlier 14,436 plus the three new tests.
- **Scripts.** The license manifest was regenerated. It is a pure relabel: the same 369 pins with
  the same hashes, once the license label's new prefix is dropped. `check-kernel-homes.sh` passes,
  and its comment now names the hard-coded dispatches as what it protects.
- **Records.**
  - Amended KERNEL_FACTS_001, TYPE_KERNEL_001 clause (3) and LSS_016.
  - Updated `design_docs/theory/kernels/kernels.md`.
- **Bootstrap.** rc 0: every stage passed, including the 4b JS fixed point, the 8c native fixed
  point and 9b.
- **Byte-identity corpus.** `eco-before` and the new `eco-compiler-boot` emit byte-identical MLIR
  for all 169 programs, the self-compile of the frozen source included. Each binary used a fresh
  package cache.
  - A trap on the first try: `build/compiler/build-kernel/src` is a symlink to the live
    `/work/compiler/src`, so a self-compile run there compiles whatever the tree holds, not the
    frozen copy. The corpus now runs the self-compile in its own project directory, whose `src`
    points at the frozen copy. The "before" arm reproduced `ecofix.mlir` both times.
- **`full`.**
  - Native: 2,492/2,492.
  - JS E2E: 207 of 209, with 2 failures, neither from this change.
    - `UnhandledTaskFailWarnsTest` (from `plans/unhandled-task-fail.md`) checked for the
      native-only warning line. It is now `SKIP-JS` with that reason. On native it still passes,
      and on JS it is skipped.
    - `WebSocketDeflateBombTest` failed a memory bound ("after cancel bounded False", 35 MB) under
      the loaded parallel run. Its JavaScript, compiled by the old and the new native compiler, is
      byte-identical, so this change cannot have caused it. It was green on 2026-10-24 and is left
      to watch.
