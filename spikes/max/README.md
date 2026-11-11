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

### `tensor/`: the typed tensor package (`eco-lab/tensor`)

Nabla's API as an Elm package that writes MAX graphs (`plans/nabla-api-in-elm.md`, `tensor/README.md`):
tensors typed by kind, dtype and a fixed rank of named dimensions (`Tensor Floating F32 (R2 n
Hidden)`), so mixing up dimensions, axes or dtypes does not compile; reverse- and forward-mode
autodiff to any order, `vmap` by batching rules, `cond`/`whileLoop` as `mo.if`/`mo.while`, shared
MAX subgraphs, layers, losses, optimizers, transformers, convolutions, LoRA and QLoRA; MLIR bytecode
written in Elm. Apps use it through eco's `--local-package eco-lab/tensor=tensor` (the Makefile's
`LOCAL_PKGS`).

- `tensor-api/`: the API's example programs (must compile) and counterexamples with the errors eco
  gives (`bad/`, must not compile): `make check-api`.
- `opcheck/`: every operation and gradient on MAX against NumPy. `OpCheck.elm` (run under node)
  builds one graph per family of operations and a manifest; `ref.py` runs them through MAX's Python
  API and checks values in f64 and gradients by central differences: `make check-ops`
  (`FAMILIES=...` for some), `OPCHECK_FORMAT=bytecode` to run the bytecode, and
  `make check-opcheck-bytecode` to compare every graph's bytecode and text with eco's `mlir-opt`.
- `make check-tensor`: the package's own tests (elm-test-rs).

### `bridge/` and `mnist/host/max_bridge.cpp`: the generic MAX host

`max_bridge.cpp` knows nothing about the models: it compiles graphs on worker threads and runs them.
A graph's specs give each tensor a role: **resident** tensors (parameters, optimizer state) live in
host buffers that outlive a run; a run reads them and its outputs with the same resident name
replace them, so only fed tensors (a batch, a seed) cross from Elm and only fed outputs (the loss)
come back. `bridge/Bridge.elm` is the Elm side every model app shares: `compile`, and commands —
`run`, `put`, `get`, `save`, `loadInto` — that `send` delivers in one message, in order (separate
sends to one port arrive in either order). The bridge takes `ECO_MAX_THREADS=N` (MAX's CPU worker
pool size) and `ECO_MAX_BUSY_WAIT_US=T` (how long an idle worker spins; it sets both of MAX's
variables, which must agree or MAX aborts).

### `mnist/`: training networks on MNIST with Elm and MAX

- `src/MnistNet.elm`: the network (784 → 128 ReLU → 10) and its SGD training, in the typed API.
- `src/MnistModels.elm`: the models `make run-mnist MODEL=...` trains: `sgd` (`MnistNet`), `adamw`
  (the same network, AdamW 1e-3), `stack` (784 → 512 → 256 → 10 with dropout 0.1), `cnn` (two
  convolutions and poolings), `lora` (`adamw`'s saved network, frozen, with a rank-8 LoRA adapter).
- `src/Mnist.elm`: runs a model on MAX: the data, the training loop, checkpoints
  (`work/checkpoints/`; `RELOAD=true` saves, reloads and re-evaluates).
- `ref/numpy_ref.py`: the `sgd` run in NumPy (same LCG, init order, shuffles), as an oracle.

`make run-mnist` (`MODEL`, `FORMAT=bytecode|generic`, `TRACE=n` logs the first n step losses) and
`make run-mnist-ref`. After a `bytecode` and a `generic` run, `make check-bytecode` reads both back
with eco's `mlir-opt` (the LLVM commit MAX pins) and requires identical IR.
`capi/scripts/bc_dump.py FILE.mlirbc` prints a bytecode file's tables.

Results (MAX 26.7.0, CPU; first runs spend 20–50 s compiling, MAX's cache makes later ones start at
once):

| Model | Test accuracy |
|---|---|
| `sgd` | 14.78% untrained, then 92.52, 94.31, 95.24, 95.60, 95.87% (mean train loss 0.4225 → 0.1334; NumPy agrees to four decimals; the first 100 step losses are bit-identical to the hand-threaded DSL this package replaced) |
| `adamw` | 97.15% after 5 epochs; the same after saving and reloading the parameters |
| `stack` | 97.65% after 5 epochs |
| `cnn` | 98.57% after 2 epochs |
| `lora` | 97.15% → 97.54% in one epoch; the frozen buffers byte-identical afterwards |

### `models/charlm/`: a character language model

`CharModel.elm`: a pre-norm transformer over windows of 64 bytes (width 64, 4 heads), trained by
`CharLm.elm` on the repo's `design_docs/theory` (837 KB; 10% held out): `make run-charlm`
(`LAYERS`, `SHARED=true` for every layer as a call of one MAX subgraph, `STEPS`). Two layers, 1,000
steps: held-out loss 1.96 nats, against the corpus's unigram entropy of 3.19. `GptBench.elm` and
`bench.js` build (do not run) a GPT-sized training step (96 layers, width 768, vocabulary 50257,
sequence 1024, batch 8) under node: 3.7–3.9 s and 0.67 MB of bytecode with shared blocks, 4.0 s and
0.92 MB inlined.

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
