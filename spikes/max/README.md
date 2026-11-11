# Eco × MAX spikes

Experiments behind the white paper *Eco × MAX: Options for Tensor Compute Graphs*
(<https://claude.ai/artifact/RADyuhBFQrYEqHL2hWpmLF>), run on 7 Nov 2026 against MAX 26.7.0
(`max` on PyPI) on x86-64 Debian 12. They are spikes: kept to reproduce the findings, not product
code.

## Setup

```sh
spikes/max/setup.sh            # .venv with MAX 26.7 (~600 MB), MNIST into mnist/data (MD5-checked)
. spikes/max/env.sh            # libmax's package paths; telemetry off
make -C spikes/max             # needs the eco dev build tree: cmake --preset build; cmake --build build
```

On an eco built against MAX's LLVM (below) the tree is elsewhere: pass it, e.g.
`make -C spikes/max ECO_BUILD=$PWD/build-llvm-git`.

`MAX_VENV=<dir>` reuses an existing venv. Outputs go to `build/` and `work/`; both are ignored, as
are `.venv/` and `mnist/data/`.

## What is here

### `capi/`: hand-written `mo` text through libmax's C API

`spike.cpp` compiles a model file with `M_compileModelSync`, runs it on borrowed host buffers at
batch 1, 7 and 1024, and checks the results against a scalar reference. `make run-capi`.

The models are `relu(x @ w + b)`:

| File | What it shows |
|---|---|
| `mlp_rmo.mlir`, `mlp_rmo_f64.mlir` | the `rmo` level MAX's Python API emits, symbolic `batch`, f32 and f64 |
| `sym_mlp.mlir` | every dim symbolic: one compile serves any shape (`--k`/`--n` pick it) |
| `sym_mlp_b.mlir` | the same op kinds plus one add: a structurally new graph, so a new ~20 s compile |
| `mlp_mo.mlir` | the lower `mo` level written by hand: fails to verify |
| `bad_syntax.mlir`, `bad_types.mlir` | invalid text: MAX prints a good diagnostic, then **segfaults** (`--expect-fail`) |
| `sym_mlp.generic.mlir` | `sym_mlp` in generic form, as MAX prints it: shows the hidden `kgen` properties |
| `sym_mlp.attrs.generic.mlir` | the same with properties as plain attributes (`scripts/props_to_attrs.py`) |
| `sym_mlp.minimal.generic.mlir` | the fewest `mo.graph` fields MAX accepts (needs `resultParameters`, `signature`) |
| `sym_mlp.too-minimal.generic.mlir` | one field short: refused |

Binary MLIR from eco's own LLVM 21:

```sh
/opt/llvm-mlir/bin/mlir-opt --allow-unregistered-dialect capi/models/sym_mlp.attrs.generic.mlir \
    --emit-bytecode -o build/sym_mlp.mlirbc
cd capi && ../build/spike ../build/sym_mlp.mlirbc --k 64 --n 17
```

`scripts/` (run with `$MAX_VENV/bin/python -I`): `dump.py` and `dump_ops.py` print the `mo` that
MAX's Python API emits (the source of every op spelling used here), `to_bytecode.py` writes MAX's own
bytecode and generic form, `export_mef.py` exports a MEF (the only way to get one; the C API has no
export), `pytime.py` times a cold compile through Python, `gen_big_graph.py` makes a large graph for
the text-versus-bytecode parse comparison.

### `embed/`: an eco program and libmax in one process

- `json/`: `TensorService.elm` builds inputs, the host runs them through MAX, Elm checks the outputs;
  JSON ports. Originally built with the eco 0.2.0-rc1 bundle (`eco make --output=x.so`, which carries
  a hidden static libc++), to test it beside libmax's libstdc++. `make run-json`.
- `bytes/`: `TensorBytes.elm` with bytes ports. The host borrows the tensors straight out of the Elm
  heap inside the port callback and emits the result back in: zero copies in, one out.
  `make run-bytes`.

The stress runs in the white paper repeated the batch list 1,500 times
(`List.concat (List.repeat 1500 [ 1, 7, 1024, 4096 ])`) and passed a second, uncached model to the
host so a cold compile ran concurrently.

### `mnist/`: training a neural network on MNIST with Elm and MAX

- `src/Tensor.elm`: tensors as values, so a network reads like the textbook
  (`x |> matmul w1 |> plus b1 |> relu`); the dtype is a phantom type (mixing dtypes does not
  compile), and `Tensor.graph` lowers the expressions onto `Graph`, sharing each tensor by a
  structural key (`plans/tensor-dsl.md`).
- `src/Param.elm`: a network's parameters described once (`Param.record Params |> Param.weights
  "w1" .w1 [ 784, 128 ] |> ...`): graph inputs, SGD outputs, byte layout and initial values.
- `src/Graph.elm`: the tape behind `Tensor`: shapes and dtypes checked as it is built,
  reverse-mode autodiff over it, the `mo` printer, and `toModule`, the same graph as generic MLIR
  ops with the inherent attributes MAX's parser would derive. MAX has no autodiff, so Elm derives the
  backward pass.
- `src/MlirBc.elm`: a small generic MLIR IR written as MLIR bytecode (version 6, as MLIR 24.0.0git
  writes it; builtin attributes and types in the builtin binary encoding, other dialects' as text)
  or as generic text. No LLVM or MLIR in the process: see `plans/mlir-bytecode-to-max.md`.
- `src/Mnist.elm`: the network (784 → 128 ReLU → 10), the `train_step` and `evaluate` graphs, and the
  training loop (SGD, learning rate 0.1, batch 100, 5 epochs). Elm owns the parameters as one `Bytes`
  block.
- `src/Bridge.elm`: the ports and the byte layout shared with the host.
- `host/max_bridge.cpp`: a generic MAX host that knows nothing about MNIST: it compiles graph text on
  worker threads, runs graphs on borrowed `Bytes`, and loads files.
- `ref/numpy_ref.py`: the same run in NumPy (same LCG, init order, shuffles), as an oracle.

`make run-mnist` and `make run-mnist-ref`. `FORMAT=bytecode` (the default) sends the graphs as
Elm-written MLIR bytecode, `FORMAT=generic` as MLIR generic text, `FORMAT=text` in MAX's custom `mo`
syntax; all three give the same run. After a `bytecode` and a `generic` run, `make check-bytecode`
reads both back with eco's `mlir-opt` (the LLVM commit MAX pins) and requires identical IR.
`capi/scripts/bc_dump.py FILE.mlirbc` prints a bytecode file's tables and which entries are text. The bridge takes `ECO_MAX_THREADS=N` (MAX's CPU worker
pool size, applied through the CPU mask MAX sizes it from) and `ECO_MAX_BUSY_WAIT_US=T` (how long an
idle worker spins; it sets both of MAX's variables, which must agree or MAX aborts). Expected: 14.78% untrained, then 92.52, 94.31, 95.24,
95.60 and 95.87% test accuracy, with mean train losses 0.4225 → 0.1334 (NumPy agrees to four
decimals). The first run spends about 27 s compiling; with MAX's cache warm the whole run takes
about 2.6 s.

### `memgrowth/`: why the MNIST run's RSS grows

`Churn.elm` replays the MNIST run's per-step `Bytes` traffic without MAX, one allocation path per
mode. `make run-churn MODE=both` stays flat (239 MB); `MODE=hold`, which only adds a live 47 MB
`Bytes` (the size of the training set), used to climb to about 2.7 GB and then plateau. The live
body starts an incremental major mark cycle (32 slices, one per minor); while a cycle runs,
`OldGenSpace::sweepNurseryLargeBodies` defers every dead young large body to `deferred_frees_`
instead of freeing it, and in this workload minors come only from the HEAP_079 large-allocation
budget, so the whole cycle's large-body churn was held until it ended. Not a leak: the memory was
reused afterwards.

Fixed by `plans/large-body-deferral-pacing.md` (HEAP_084): a cycle now finishes early once its
deferred bytes reach max(F × live estimate, one budget). `hold` peaks at about 360 MB, its one cycle
ending after 2 minors (`deferred=` on the `[gc-profile] cycle handoff` line, `ECO_GC_PHASE_PROFILE=1`).
`ECO_HEAP_CONFIG=memgrowth/heap-deferred-off.json` restores the old behaviour, for comparison.

## Eco on MAX's LLVM

Eco builds against LLVM 21.1.8; MAX 26.7.0 (and Mojo 1.2.0) pins llvm-project commit
`8d4fc8f1d17e64e1826346a0230a87b50ec371e4` (2026-10-09, LLVM 24.0.0git) in
`bazel/public-patches/llvm_source.bzl` at the `max/v26.7.0` tag of github.com/modular/modular, plus
its own patches. To try eco on that commit, so the two can exchange MLIR without a version gap:
`docker/llvm-debian-git.Dockerfile` builds `eco-llvm-debian-git:<commit>` (the stable
configuration, unpatched), and `docker/eco-dev-llvm-git.Dockerfile` layers it onto `eco-dev` as
`eco-dev-llvm-git:<commit>`. The stable `eco-llvm-debian:21.1.8` and `eco-dev` images, and the
Dockerfiles CI builds them from, are unchanged. The build commands are in each Dockerfile's header.

## Known problems these exposed

- libmax segfaults on `mo` text that fails to parse or verify
  (`GraphCompiler/lib/FrameworkFrontend/FrameworkFrontend.cpp:474` never checks `parseMODialect`).
- Each structurally new graph costs about 20 s of compile; the cache keys on the input bytes, so the
  same graph as text and as bytecode compile separately.
- Telemetry is on by default (`env.sh` sets `MODULAR_TELEMETRY_ENABLED=0`).
- MAX's CPU worker pool, one thread per core, spins 200 µs after every task: 26.7 s of CPU for a
  2.7 s run. `ECO_MAX_THREADS=2 ECO_MAX_BUSY_WAIT_US=0` gives 1.7 s and 2.6 s of CPU, same results.
  Setting `MODULAR_THREAD_BUSY_WAIT_US` alone, or `MODULAR_RUNTIME_NUM_THREADS`, aborts the process.
- Eco's RSS peaked at 2.8 GB on the MNIST run (see `memgrowth/`); since HEAP_084 it peaks at about
  530 MB, with the same results.
