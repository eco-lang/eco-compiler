---
status: superseded
updated: 2026-11-16
superseded_by: "the-sett/elm-mlir 6.0.0, published from its own repository; compiler/mlir was removed and the compiler and the MAX spike depend on the published package (2026-11-16)"
---

# The MLIR library as its own Elm package

The compiler's MLIR library (`compiler/src/Mlir/`, 4,483 lines: the IR model, the generic-text
printer and the bytecode writer) becomes an Elm package in `compiler/mlir/`, ready to be moved to a
repository of its own and published. The compiler uses it through its public API only, and the MAX
spike (`spikes/max/tensor`) drops its own MLIR writer (`Tensor.Internal.MlirBc`, 1,400 lines) for
it.

## Package layout

```
compiler/mlir/
  elm.json        package the-sett/elm-mlir, BSD-3-Clause, 1.0.0
  README.md       what it is, the model, text and bytecode output, a short example
  LICENSE
  src/Mlir/...    the modules, names kept
  tests/          the library's own tests, moved from compiler/tests/Mlir/
```

Dependencies: elm/core, elm/bytes, j-maas/elm-ordered-containers (all already compiler
dependencies).

Exposed (what the compiler uses today): `Mlir.Mlir`, `Mlir.Loc`, `Mlir.Pretty`,
`Mlir.Bytecode.StreamEncode`. Internal: `Mlir.Bytecode.{AttrType, DialectSection, IrSection,
Section, StringTable, VarInt}`, plus a copy of the compiler's `Data.Int64` renamed
`Mlir.Bytecode.Int64` (the compiler keeps its own; two `Data.Int64` modules in one build would
clash).

## Phase 1: move, and the compiler on the public API

- `git mv`-equivalent move of `compiler/src/Mlir` to `compiler/mlir/src/Mlir`; the module names do
  not change, so no compiler import changes.
- `compiler/elm.json` gains the source directory `mlir/src`; the build wiring that lists the
  compiler's source directories follows (`compiler/CMakeLists.txt` build-xhr links,
  `scripts/coverage/cov.py`, and any bootstrap stage that copies `src/`).
- Tests that import internal modules (`VarIntTest`, `AttrTypeTest`, `DenseArrayEncodingTest`,
  `LocStringCollisionTest`, `MlirEncodingCoverageTest`) move to `compiler/mlir/tests/`, run by
  elm-test-rs on the package; the compiler's own tests import only exposed modules.
- A source directory does not enforce `exposed-modules`, so a check script
  (`compiler/scripts/check-mlir-api.sh`, wired into the `elm-tests` target) fails when a file outside
  `compiler/mlir/` imports an unexposed `Mlir.*` module.
- Gate: compiler output unchanged. `full` E2E, `elm-tests`, the bootstrap (both fixed points), and
  the package's own tests and `elm make --docs`.

## Phase 2: what the spike needs from the package

The spike's IR differs from the compiler's in four places; each becomes a package addition that
leaves the compiler's output byte-identical:

- **Attributes:** a dictionary attribute, and an attribute written as its assembly text (MAX's
  `#M…`/`#kgen…` attributes), as `NamedStruct` already is for types.
- **Types:** `index` and signed integers (`si64`): `IndexType`, `SignedIntegerType w`.
- **Dialects without ops:** the writer numbered dialects from op names only, so an attribute of a
  dialect with no ops (`#kgen`, `#M`, `#mosh`) would be written under dialect −1. Such dialects are
  now added when the file is assembled, after every op dialect, so the compiler's bytes cannot
  change.
- **Isolated regions:** the bytecode writer treats only `func.func` and `builtin.module` regions as
  isolated from above (they number their values from 0). It takes the set of isolated op names as a
  setting, defaulting to those two (`StreamEncode.isolating`), so the spike can add `mo.graph`.
- **Value names:** the package names SSA values (`%x`); the spike numbers them relative to their
  region. The spike keeps its numbering (it suits lowering) and converts at the edge: each value is
  named after its absolute number, `%argN` for a block argument and `%N` for a result.

Gate: Phase 1's gate again (compiler output unchanged), plus package tests for each addition.

## Phase 3: the spike on the package

- `eco-lab/tensor` depends on the MLIR package. Eco apps resolve it with one more
  `--local-package` in `spikes/max/Makefile`.
- `Tensor.Internal.MlirBc` becomes `Tensor.Internal.Ir`: the builder IR, its value numbering and
  `unboundOperands` stay; its writers (≈900 lines) are replaced by a conversion to `Mlir.Mlir`
  written with `Mlir.Bytecode.StreamEncode` and `Mlir.Pretty`.
- Stock-Elm tooling cannot resolve an unpublished dependency. Until the package is published, the
  tensor tests run from an application project (`spikes/max/tensor-tests.elm.json`, used by
  `make check-tensor`) over `tensor/src` and `compiler/mlir/src`, and `make docs-tensor` builds
  `docs.json` from a copy of the package whose `src` also holds the MLIR modules, unexposed.
- Gate (after `. spikes/max/env.sh`): check-tensor, check-bytecode (eco's `mlir-opt` reads every graph),
  check-apicheck, check-ops, run-mnist sgd/lora/cnn with exact results, run-charlm, check-tensor-native.
  The graph snapshots change (other table order, bytecode version 4 rather than 6); MAX's results must
  not.

## Bytecode versions

MLIR bytecode carries its own format version, not LLVM's: LLVM 21 and MAX's pinned LLVM
(24.0.0git, MAX 26.7.0) both write version 6 and read versions 0 to 6. The builtin dialect's
attribute and type codes that both writers use are the same in both; the later LLVM only adds codes
at the end (affine maps, strided layouts, more float types) and renames the dense-elements entry.
So one encoder serves both. What does differ between LLVM versions is dialects (op names, inherent
attributes, properties), which are the caller's concern, not the writer's. A version setting is
added only when a format difference appears.

## Result (2026-11-15)

All three phases are in. Compiler: `elm-tests` (compiler 21,510, package 41, eco/system 918, all
passing, API check clean), `full` (E2E 3,099/3,099, JS 265 with 8 skipped, node-addon, driver-cli)
and `bootstrap` (Stage 4b and Stage 8c fixed points) pass. Spike: `check-tensor` 542/0,
`check-bytecode`, `check-apicheck`, `check-ops` 405/0, `check-ops-eval` 402/0, `check-api`,
`check-tensor-native` 8/8; MNIST sgd, generic, lora, cnn and both reloads give results identical to
2026-11-14's, and charlm's identical through step 250 (the earlier run stopped at 300). MAX's own
MLIR context parses and verifies the generic text of a graph with `mo.call` written as properties
(`<{callee …}>`), as the package prints it, and as an attribute dictionary.

