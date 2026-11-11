---
status: done
updated: 2026-11-11
---

# Plan: send MAX graphs from Elm as MLIR bytecode

The MAX spike (`spikes/max/mnist`) already runs the pipeline end to end in text: `Graph.elm` (a
typed graph DSL with autodiff) prints `mo` in MAX's custom assembly syntax, a bytes port carries it
to `host/max_bridge.cpp`, which writes it to a file and compiles it with `M_setModelPath` +
`M_compileModelSync`. This plan replaces the custom text with MLIR bytecode written by Elm itself,
now that eco and MAX share LLVM 24.0.0git (llvm-project `8d4fc8f1d17e`, `spikes/max/README.md`,
"Eco on MAX's LLVM").

**Read before coding:** `spikes/max/README.md`; MLIR's `mlir/docs/BytecodeFormat.md`,
`lib/Bytecode/Reader/BytecodeReader.cpp` and `include/mlir/IR/BuiltinDialectBytecode.td` at
`8d4fc8f1d17e` (fetched to `/tmp/eco-max-bc/llvm/`, scratch).

## 1. Decision: no LLVM or MLIR in the eco runtime

The bytecode is written by a pure Elm encoder over `elm/bytes`. Linking MLIR into the host instead
would put a second LLVM 24 in the process beside the one statically inside `libmax.so` (patched by
Modular): duplicate `cl::opt` registration and symbol interposition. Building the module in libmax's
own MLIR context is not offered by the C API (`M_setModelPath` takes a path; there is no in-memory
module entry point). LLVM stays a development-time tool: eco's `/opt/llvm-mlir/bin/mlir-opt` is the
same MLIR commit as MAX's, so it is an exact checker of the bytecode container.

## 2. Facts (verified 2026-11-11)

- MAX's own bytecode for the MNIST graphs (`capi/scripts/to_bytecode.py`, dumped by the new
  `capi/scripts/bc_dump.py`): version 6, producer `MLIR24.0.0git`. `builtin` attributes and types
  use the builtin dialect's custom encoding (public: `BuiltinDialectBytecode.td`); `kgen` and `M`
  use private custom encodings; `mo` tensor types and `mosh` attributes are stored as text, even by
  MAX. Inherent attributes go in the properties section.
- Eco's `mlir-opt` cannot read MAX's bytecode ("dialect 'M' does not implement the bytecode
  interface"), so MAX's files cannot be golden files.
- The MLIR reader accepts any attribute/type as its text (the assembly-format fallback), and for a
  registered op it moves inherent attributes given as ordinary attributes into its properties
  (`sym_name`, `functionType`, `axis`, ...). The first spike showed MAX accepts that form.
- `mo.graph` needs `functionType`, `signature` (a `!kgen.generator<...>` with the same function
  type), `inputParameters`, `resultParameters` (both `#kgen<param.decls[]>` for static shapes) and
  `sym_name`, plus `argument_names`/`result_names`. `outputParamDecls`, `parameters` and `counter`
  default.

## 3. Design

- **`MlirBc.elm`** (new, in `spikes/max/mnist/src`): a small generic MLIR IR (ops with name,
  attributes, result types, operands, single-block regions) and two writers over it:
  - `encode`: MLIR bytecode version 6. Sections: dialect, attr/type offsets, attr/types, IR,
    string, and an empty properties section (the reader requires one from version 5 on); no
    resource or dialect-version sections. `builtin` attributes and types
    (dictionary, array, string, integer, unknown location, type attribute; integer, index and
    function types) use the builtin custom encoding; every other dialect's entries are text. Entries
    are numbered in first-use order within dialect groups, so the bytes are a pure function of the
    graph (MAX's compile cache keys on the bytes). Isolated regions are nested IR sections, as
    MLIR's writer emits them.
  - `printGeneric`: the same IR in MLIR's generic text form.
- **`Graph.elm`**: `toModule` builds the generic `mo`/`rmo` ops with MAX's attributes (§2); `print`
  (custom syntax) stays for comparison.
- **`Bridge.elm` / `max_bridge.cpp`**: `compile` carries a `Bytes` payload. The host picks the file
  extension by the payload's magic (`ML\xEFR` → `.mlirbc`) and writes it in binary mode.
- **`Mnist.elm`**: a `format` flag: `"bytecode"` (default), `"generic"` (`printGeneric`) or
  `"text"` (the old printer).

Out of scope: `kgen`/`M` custom encodings (private and unstable), a native properties section,
multi-block or non-isolated nested regions, use-list orders, resources.

## 4. Validation

1. **Container check:** for both graphs, `mlir-opt --allow-unregistered-dialect
   --mlir-print-op-generic` on the Elm bytecode and on the Elm generic text must print identical
   output.
2. **MNIST through MAX:** `make run-mnist` with each format gives the expected run: 14.78% untrained,
   then 92.52, 94.31, 95.24, 95.60, 95.87% test accuracy, mean train losses 0.4225 → 0.1334.
3. Record the bytecode sizes against the text sizes, and the cold compile times.

## 5. Results (2026-11-11)

Done as designed. `make -C spikes/max run-mnist FORMAT=bytecode|generic|text`, then
`make -C spikes/max check-bytecode`.

- **MNIST through MAX:** all three formats give the expected run exactly (14.78% untrained, then
  92.52, 94.31, 95.24, 95.60, 95.87%; mean train loss 0.4225 → 0.1334). The custom-text baseline was
  rerun first on the LLVM 24 eco build (`build-llvm-git`) and matched.
- **Container check:** `check-bytecode` passes for both graphs (60 and 21 lines of generic IR).
- **Determinism:** two runs write byte-identical `.mlirbc` files, and the second run's compiles hit
  MAX's cache (0.0 s against 29 s and 41 s cold).
- **Sizes** (train_step / evaluate, bytes): Elm bytecode 2,493 / 1,392; MAX's own bytecode for the
  same graphs 2,248 / 1,185; MAX custom text 6,202 / 1,893; generic text 7,194 / 2,525. In the Elm
  bytecode every `builtin` entry (32 in evaluate) uses the binary builtin encoding; the `mo`, `kgen`,
  `M` and `mosh` entries are text. The remaining gap to MAX's size is the `kgen`/`M` private
  encodings and its native properties.
- **One correction on the way:** the first bytecode omitted the properties section; MAX's reader
  refused it ("missing data for top-level section: Properties (8)") and then segfaulted (the known
  libmax bug on unreadable input). Check new bytecode with `mlir-opt` before handing it to MAX.
- **Spike fixes:** the Makefile's Stage 1 compiler now takes `guida.js` from `ECO_BUILD`, not
  `build/` (the same trap as the test harnesses after the LLVM 24 port). New tool:
  `capi/scripts/bc_dump.py` prints any bytecode file's sections, dialects, ops and attribute/type
  entries with their encoding.

Next steps, not planned: `M.dense_array` constants as bytecode resources or builtin dense arrays
(large weights inline in the graph); symbolic dimensions (`kgen` parameter declarations in
`signature`); moving `MlirBc` out of the spike if eco grows a tensor package.
