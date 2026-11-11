---
status: partial
updated: 2026-11-11
remaining: "M1–M4 (§7): real models (MNIST diffusion, llama2.c and GPT-2, Stable Diffusion 1.5) need downloads, and the GPU host, branches and loops on a GPU, and runs on the A4500/A1000 need the GPU machine. A0–A3 are done (§11)."
---

# Plan: eco-lab/tensor, round 2: the API for open-weight models, diffusion and GPUs

## 1. Aim, scope and outcome

Round 1 (`plans/nabla-api-in-elm.md`) gave Elm a typed tensor API on MAX that trains MNIST models and
a small character transformer on the CPU. Round 2 adds what three kinds of model need, each placed
where it belongs in the API:

- **Language models with downloaded weights:** GPT-2 small and Karpathy's llama2.c `stories`
  models, generating text with a KV cache.
- **Diffusion:** a small UNet trained from scratch on MNIST, then Stable Diffusion 1.5 inference.
- **GPUs:** the same graphs on the user's RTX A4500 (20 GB) and RTX A1000 (8 GB), with half
  precision.

**Scope of this round (user's decision, 2026-11-11): the API only.** This machine has no GPU and
32 GB of free disk, so nothing is downloaded and no real model is run. Everything is built and
tested here, on the CPU, with synthetic weights and NumPy references (phases A0–A3, §5). Running the
real models and the GPUs is planned in §7 (M1–M4) and starts when the user says so, on the GPU
machine.

**What this round delivers:**
- every operation and layer the four models need, typed, with gradients where they make sense,
  each checked against NumPy on MAX and with must-not-compile programs for its classic mistakes;
- `Infer`, the inference counterpart of `Train`: a graph with resident weights and resident state
  (KV caches, latents) that the host keeps in place between runs;
- checkpoint import: weights loaded from disk straight into host buffers and converted (transposed,
  split, cast) by a typed graph, without passing through Elm;
- a host that keeps resident tensors without copying them after every run;
- graphs written for a GPU (`Graph.toBytecodeOn (Gpu 0)`), checked structurally here;
- an end-to-end check that ties these together on small synthetic models.

## 2. Where we start

The exploration (2026-11-11) and two reviews against the code established:

- **A linear layer without a bias needs no new type.** `Param.config` can hold a tensor: it adds no
  field to any layout, so a constant zero bias is not a parameter.
- **MAX already has** `mo.reduce.rms_norm`, `mo.reduce.group_norm`, `rmo.mo.resize.nearest`,
  `rmo.top_k` (values sorted, any axis on the CPU), `rmo.mo.bottom_k`, element-wise
  `rmo.mo.scatter`/`scatter_add` along an axis, flash attention (`flash_attention_gpu`) and
  quantized matmuls. `argsort` is a 1-D built-in kernel only.
- **GPU graphs build without a GPU** in MAX's Python API, and the device is part of every tensor
  type: `!mo.tensor<[2, 3], f32, gpu:0>`; `rmo.mo.transfer` moves values between devices.
- **Primitives have one result.** `Op` is `P Prim (List Expr) Params`; multi-result nodes and `Proj`
  exist only for `Call`, `If`, `While` (`Tensor/Internal/Expr.elm`).
- **Only `Train` makes resident buffers.** `Param.initGraph`'s outputs are fed back to Elm.
- **Resident names are positional:** `Names.names "param"` over the fields' kind labels
  (`Train.elm`, `layout`); a label used once stays unnumbered.
- **Scalars travel as `[1]`** only for `Train`'s step and rate (`Train.elm`, "scalars travel as
  [1]"); MAX's C API takes no rank-0 inputs.
- **The host copies every resident output** into a `std::vector` after each run
  (`mnist/host/max_bridge.cpp`, `residents` is `std::map<std::string, std::vector<std::byte>>`).
- **`put` on axis i > 0 transposes the whole tensor** to the front and back (`scatterAlong` in
  `Tensor.elm`) around a `scatter_nd`.
- **eco's `elm/regex` has no `\p{L}`/`\p{N}`** (no `u` flag; `elm-kernel-cpp/src/regex/
  RegexExports.cpp`), which matters for tokenizers later (§7).
- **Library layers may use the internal, rank-free `Tensor.Internal.Ops`,** as `Nn.Conv2d` does; only
  public types are limited to rank 5.

## 3. Placement principles

1. **The package stays architecture-neutral and I/O-free.** `eco-lab/tensor` holds operations,
   generic layers and the machinery around graphs. Whole architecture blocks, tokenizers and image
   files live in `spikes/max/models/lib/` (§4.8), shared by the model apps.
2. **Composite before primitive.** A layer built from existing ops gets gradients, batching and dtype
   checks for free. It becomes a primitive only when a measurement says so, without changing its
   public signature. RMSNorm and GroupNorm start composite.
3. **Existing types stay; variants get new records.** Round-1 programs keep compiling.
4. **Functions live next to their family.** Activations in `Tensor`; pooling-like image operations in
   `Nn`; random draws in `Tensor.Random`; each layer with parameters is a module `Nn.<Layer>` with a
   record, `params` and `apply`.
5. **Devices are chosen when a graph is written,** not when it is described; `Graph` refuses what a
   device cannot do.
6. **Gigabytes never pass through Elm.** Weights go from disk into host buffers and are converted
   there by a graph Elm writes.
7. **Layers are unbatched; batches come from `Transform.vmap`.** Round 1's layers take `R2 s m`;
   convolutions take `R4 n h w c`. Model code batches the rest with `vmap`/`vmapWith`.

## 4. Where every piece goes

Signatures are final unless §5 says otherwise. "Composite" means built from existing internal ops in
`Tensor.Internal.Ops` (`O.*`) over `Expr`, wrapped as typed tensors the way `Nn.Conv2d` does.

### 4.1 `Tensor`

| Function | Signature | Implementation |
|---|---|---|
| `topK` | `Retag s t a c -> Dim c -> Tensor k d s -> ( Tensor k d t, Tensor Integral I64 t )` | primitives `TopKValues`, `TopKIndices` sharing one `rmo.top_k` (§5, A1.2) |
| `bottomK` | same | the same primitives with `largest = 0`, sharing one `rmo.mo.bottom_k` |
| `sort` | `{ descending : Bool } -> Axis s r c -> Tensor k d s -> ( Tensor k d s, Tensor Integral I64 s )` | `topK`/`bottomK` with k = the axis's size |
| `quickGelu` | `Tensor Floating d s -> Tensor Floating d s` | composite: x · sigmoid(1.702 x) |
| `put`, `putAdd` (changed inside) | unchanged | one `rmo.mo.scatter` / `scatter_add` along the axis, no transposes (§5, A1.1) |

Differentiating through `topK`, `bottomK` or `sort` is refused when the graph is built. Writing for a
GPU refuses them on any axis but the last (A3).

### 4.2 `Tensor.Random`

| Function | Signature | Implementation |
|---|---|---|
| `gumbelLike` | `Tensor Floating d s -> Seed -> Tensor Floating d s` | u uniform in (2⁻²³, 1 − 2⁻²³) in f32; −log(−log u); cast to d |
| `categorical` | `Tensor Floating d (R2 n v) -> Seed -> Tensor Integral I64 (R1 n)` | `argMax` over the last axis of logits + `gumbelLike logits seed` |

### 4.3 `Nn` (functions without parameters)

| Function | Signature |
|---|---|
| `upsampleNearest2d` | `Int -> Dim h2 -> Dim w2 -> Tensor Floating d (R4 n h w c) -> Tensor Floating d (R4 n h2 w2 c)` |
| `timestepEmbedding` | `{ maxPeriod : Float, cosFirst : Bool, shift : Float } -> Dim e -> Tensor Floating d (R1 n) -> Tensor Floating d (R2 n e)` |
| `causalMaskAt` | `Tensor Integral I64 R0 -> Dim s -> Dim t -> Mask (R2 s t)` |
| `repeatHeads` | `Dim h -> Tensor k d (R3 g t j) -> Tensor k d (R3 h t j)` |

### 4.4 New `Nn.Sampling`

```elm
greedy : Tensor Floating d (R2 n v) -> Tensor Integral I64 (R1 n)
sample : Tensor Floating d (R2 n v) -> Seed -> Tensor Integral I64 (R1 n)
keepTopK : Int -> Tensor Floating d (R2 n v) -> Tensor Floating d (R2 n v)
nucleus : Float -> Tensor Floating d (R2 n v) -> Seed -> Tensor Integral I64 (R1 n)
```

### 4.5 Layers

```elm
-- Nn.Linear (added)
paramsWithoutBias : DType Floating d -> Dim i -> Dim o -> Param.Spec (Linear d i o)

-- Nn.Embedding (added)
unembed : Embedding d v m -> Tensor Floating d (R2 s m) -> Tensor Floating d (R2 s v)

-- Nn.RmsNorm (new)
type alias RmsNorm d m = { scale : Tensor Floating d (R1 m), epsilon : Float }
params : DType Floating d -> { epsilon : Float } -> Dim m -> Param.Spec (RmsNorm d m)
apply : RmsNorm d m -> Tensor Floating d (R2 n m) -> Tensor Floating d (R2 n m)
apply3 : RmsNorm d m -> Tensor Floating d (R3 b n m) -> Tensor Floating d (R3 b n m)

-- Nn.GroupNorm (new)
type alias GroupNorm d c = { scale : Tensor Floating d (R1 c), bias : Tensor Floating d (R1 c), groups : Int, epsilon : Float }
params : DType Floating d -> { groups : Int, epsilon : Float } -> Dim c -> Param.Spec (GroupNorm d c)
apply : GroupNorm d c -> Tensor Floating d (R4 n h w c) -> Tensor Floating d (R4 n h w c)

-- Nn.Rotary (new)
type Pairing = Interleaved | Halves
type alias Rotary = { base : Float, pairing : Pairing }
apply : Rotary -> Tensor Integral I64 (R1 s) -> Tensor Floating d (R3 h s j) -> Tensor Floating d (R3 h s j)

-- Nn.FeedForward (new)
type alias Gated d m f = { gate : Linear d m f, up : Linear d m f, down : Linear d f m }
gatedParams : DType Floating d -> { bias : Bool } -> Dim m -> Dim f -> Param.Spec (Gated d m f)
applyGated : (Tensor Floating d (R2 n f) -> Tensor Floating d (R2 n f)) -> Gated d m f -> Tensor Floating d (R2 n m) -> Tensor Floating d (R2 n m)

-- Nn.KvCache (new)
type alias Cache d g t j = { keys : Tensor Floating d (R3 g t j), values : Tensor Floating d (R3 g t j) }
sig : DType Floating d -> Dim g -> Dim t -> Dim j -> Sig (Cache d g t j)
write : Tensor Integral I64 R0 -> Tensor Floating d (R3 g s j) -> Tensor Floating d (R3 g s j) -> Cache d g t j -> Cache d g t j

-- Nn.Attention (added; Attention, params, self, cross unchanged)
paramsWith : DType Floating d -> { projectionBias : Bool, outBias : Bool } -> Dim m -> Dim h -> Dim j -> Param.Spec (Attention d m h j)
type alias Grouped d m kv h g j =
    { query : Linear d m m, key : Linear d m kv, value : Linear d m kv, out : Linear d m m
    , model : Dim m, kvWidth : Dim kv, heads : Dim h, kvHeads : Dim g, headDim : Dim j }
groupedParams : DType Floating d -> { projectionBias : Bool, outBias : Bool } -> Dim m -> Dim kv -> Dim h -> Dim g -> Dim j -> Param.Spec (Grouped d m kv h g j)
selfGrouped : { causal : Bool, rotary : Maybe ( Rotary, Tensor Integral I64 (R1 s) ) } -> Grouped d m kv h g j -> Tensor Floating d (R2 s m) -> Tensor Floating d (R2 s m)
selfCached : { rotary : Maybe Rotary } -> Grouped d m kv h g j -> Tensor Integral I64 R0 -> Cache d g t j -> Tensor Floating d (R2 s m) -> ( Cache d g t j, Tensor Floating d (R2 s m) )
type alias Cross d m c h j = { query : Linear d m m, key : Linear d c m, value : Linear d c m, out : Linear d m m, model : Dim m, heads : Dim h, headDim : Dim j }
crossParams : DType Floating d -> { projectionBias : Bool, outBias : Bool } -> Dim m -> Dim c -> Dim h -> Dim j -> Param.Spec (Cross d m c h j)
attendTo : Cross d m c h j -> Tensor Floating d (R2 t c) -> Tensor Floating d (R2 s m) -> Tensor Floating d (R2 s m)
```

`Grouped` with g = h and biases covers GPT-2's and CLIP's attention; with g < h and no biases,
Llama's; with g = h, no projection bias and no mask, SD's self-attention. `Cross` covers SD's
attention from image features (m wide) to text states (c wide).

### 4.6 `Param`, new `Infer`, `Graph`

```elm
-- Param (added)
names : Spec r -> List String
named : String -> Spec p -> Spec p
importGraph : String -> Spec r -> Sig raw -> (raw -> r) -> Result (List String) Graph
initInPlace : String -> Spec r -> Result (List String) Graph

-- Infer (new)
step : String -> Param.Spec r -> Sig state -> Sig input -> Sig output -> (r -> state -> input -> ( state, output )) -> Result (List String) Graph
initGraph : String -> Sig state -> state -> Result (List String) Graph

-- Graph (added)
type Device = Cpu | Gpu Int
toBytecodeOn : Device -> Graph -> Result (List String) Bytes
toGenericTextOn : Device -> Graph -> Result (List String) String
```

### 4.7 Bridge and host

| Elm (`spikes/max/bridge/Bridge.elm`) | Code | Message after the 8-byte header | Effect |
|---|---|---|---|
| `loadRangeInto : String -> String -> Int -> Int -> Command` (name, path, offset, length) | 7 | NAME `\0`, offset (u32 low, u32 high), length (u32 low, u32 high), PATH (the rest) | the file's bytes [offset, offset + length) become resident buffer NAME |
| `drop : String -> Command` | 8 | NAME (the rest) | frees resident buffer NAME (missing: an error) |
| `loadRange : Int -> String -> Int -> Int -> Command` (id, path, offset, length) | 9 | offset, length as above, PATH (the rest) | the bytes come back on `loadIn` under `id`, as `load`'s do |

Residents become MAX tensors kept in place (A0.6). Writing an image needs no command: `put` the
file's bytes, then `save`.

### 4.8 `spikes/max/models/lib/`

A source directory listed by model apps (`"source-directories": ["src", "../lib/src",
"../../bridge"]`), allowed to depend on `elm/json`. **This round builds only `Checkpoint.Safetensors`**
(A2 uses it); tokenizers, model blocks, schedulers, the generation loop and image files come with the
models (§7).

### 4.9 Deferred, and where each would go

| Piece | Where | Why later |
|---|---|---|
| Fused attention | `Nn.attention` becomes a primitive lowered to `flash_attention_gpu` (BSHD) on a GPU, the composite as its gradient | speed, GPU only (M4) |
| Quantized matmul (GGUF Q4_0/Q4_K/Q6_K, GPTQ) | `Nn.Quantized`: `Param.data` blocks, `apply` → `mo.custom` qmatmul | 4-bit 7B models |
| Bilinear, bicubic resize | `Nn.resize2d { method }` → `rmo.mo.resize.linear` / `.bicubic` (NCHW: permutes) | no model here needs them |
| Argsort | `Tensor.argsort`, rank 1 only | `sort` covers every use |
| Several GPUs | a separate plan: device meshes, `rmo.mo.transfer`, allreduce/allgather | models over 20 GB |

## 5. Implementation (this round: A0–A3, CPU, no downloads)

**Gates.** After every phase, round 1's gates pass unchanged: `make check-tensor`, `check-api`,
`check-ops`, `check-opcheck-bytecode`, `run-mnist` (SGD: the first 100 step losses identical to
`work/mnist-trace-before.txt`; AdamW: 97.15%, the same after save and reload), `run-charlm`
(held-out 1.9624). Build and run commands are those of round 1 (`cd spikes/max && . ./env.sh &&
make ECO_BUILD=/work/build-llvm-git ...`). New Elm code follows the package's conventions: public
aliases only in signatures; composites in `Tensor.Internal.Ops` or in the layer module over `Expr`;
every build-time error message names the function and the sizes.

**Adding a primitive** (used by A1.1 and A1.2) touches, in order: `Prim.elm` (constructor with its
`Params` comment, `tag`, `name`, `family`), `Shape.elm` (`rule` case), `Support` (regenerate after
adding the primitive to `capi/scripts/inventory/support_probe.py` and `scripts/support.json`),
`Vjp.elm` (`rule` case), `Batch.elm` (`rule` case; `axisRule shifted` for axis primitives, otherwise
`unroll`), `Mo.elm` (`emit` case), `Ops.elm` (a builder), and `mo-inventory.md` (the spelling, from a
Python probe added to `capi/scripts/inventory/`).

### A0. Foundations

**A0.1 Scalars in any signature.** New internal module `Tensor/Internal/Io.elm`:

```elm
widenSlot : I.Slot -> I.Slot              -- shape Just [] becomes Just [ 1 ]
narrowIn : I.Slot -> Expr -> Expr         -- for a slot that was rank 0: O.reshape [] e
widenOut : Expr -> Expr                   -- rank 0: O.reshape [ 1 ] e; otherwise e
```

Refactor `Train.step` to use them for step and rate (today's `takeIf … O.reshape []` and `unscalar`).
Test: `Train.step`'s graph text is byte-identical before and after for the MNIST AdamW spec
(compare `Graph.toGenericText` in a unit test against a string saved before the change).

**A0.2 Resident names.**
1. `Types.elm`: `Field` gains `name : Maybe String` (default `Nothing` in every builder in
   `Param.elm`).
2. `ParamInit.elm`: `residentNames : List I.Field -> List String`:
   - fields with `name = Nothing` are named exactly as today: `Names.names "param"` over their kind
     labels, numbered among themselves only;
   - fields with `name = Just p` are grouped by p (in field order) and named `p ++ "." ++ n`, where
     n comes from `Names.names "param"` over that group's kind labels.
3. `Train.layout` uses `residentNames` for `paramNames`.
4. `Param.named n spec` sets `name = Just n` on every field whose name is `Nothing` (the innermost
   `named` wins, so names are absolute: write `named "unet.down0"`, not nested names).
5. `Param.names (I.ParamBuilder s) = ParamInit.residentNames s.fields`.

Tests: for every round-1 spec used in `mnist/src/MnistModels.elm` and `models/charlm`, `Param.names`
equals `Train`'s current names (literal lists); a spec with two named parts gives
`["param0", "a.param0", "a.param1", "b.param"]`-style names; `Param.names (Param.named "a" p)` equals
the "a." names of a whole spec containing `Param.sub .a (Param.named "a" p)`.

**A0.3 A constant bias.** `Nn.Linear.paramsWithoutBias dt i o = Param.record Linear |>
Param.heUniform .weight dt (T.r2 i o) |> Param.config .bias (T.zeros dt (T.r1 o))`. Tests: `Param.count`
is i·o; `Param.names` has one entry; a `Train.step` over it builds, has no bias input, and its
generic text contains the zero constant; `Finetune.Lora.apply` accepts it.

**A0.4 `Param.initInPlace`.** Copy `Param.initGraph` (`Param.elm`, the `one i f seed` draw) but give
the outputs `role = I.Resident n` with n from `residentNames`, so parameters are drawn on the host
and never sent to Elm. Same seed input (`seed`, ui64 [1]), same draws: a test compares the two
graphs' texts, which must differ only in output roles (`Graph.outputs`).

**A0.5 `Infer`.** New public module `src/Infer.elm`, listed in `elm.json`. `step name spec stateSig
inSig outSig f`:
1. Slots, in order:
   - parameters: one per field, `role = Resident n`, `n` from `residentNames`, dtype and shape from
     the field;
   - state: the state signature's slots; each must have a dtype and shape (else the error "Infer:
     state slot <i> has no shape"); names `"infer." ++ n` for n in `Names.names "state"` over their
     labels; `role = Resident` that name;
   - inputs: the input signature's slots through `Io.widenSlot`, `role = Fed`.
2. Output slots: one per state slot, `role = Resident` the same name, dtype and shape `Nothing`;
   then the output signature's slots, `role = Fed`.
3. The input `SigBuilder.build` takes the parameters with the spec's `build`, the state with the state
   signature's `build`, and the inputs with the input signature's `build` after `Io.narrowIn` on each
   rank-0 slot. The body applies `f`, flattens the new state with the state signature's `flatten` and
   the outputs with the output signature's `flatten`, then `Io.widenOut` on each output.
4. Check, for each state slot: the new state's shape and dtype equal the slot's, else "Infer: state
   infer.<n> changes from f32[2,8] to f32[2,9]".
5. `Graph.build name inSig outSig body` (as `Train.step` does).

`initGraph name stateSig value`: inputs `Sig.unit`; outputs the state slots with the resident names
above; body ignores its input and flattens `value`. Tests: roles and names of `Graph.inputs`/
`Graph.outputs`; a rank-0 input arrives as `[1]`; a state that changes size is refused with the
message above; a must-not-compile program (A1.10) for a state of another type.

**A0.6 `Param.importGraph`.** `importGraph name spec rawSig convert`:
- inputs: `rawSig`'s slots, each `role = Resident l` with l from `Names.names "raw"` over the labels
  (a slot without dtype or shape is an error);
- outputs: one per field, `role = Resident n`, n from `residentNames`;
- body: `convert raw`, flattened with the spec's `flatten`;
- check: each output's dtype and shape equal its field's, else "importGraph: <n> is f32[768,2304],
  the parameter is f32[2304,768]".

The caller labels raw slots with the names it gave the host's buffers (`Sig.label "raw17"`).

**A0.7 Host: residents kept in place** (`mnist/host/max_bridge.cpp`).
1. Types:

   ```cpp
   struct OutMap { M_AsyncTensorMap *map; ~OutMap() { M_freeAsyncTensorMap(map); } };
   struct Resident {
     std::shared_ptr<OutMap> owner;   // set when the tensor came from a run
     M_AsyncTensor *tensor = nullptr; // freed with M_freeTensor in the destructor
     std::vector<std::byte> bytes;    // set by put, loadInto, loadRangeInto
     size_t size = 0;
     const void *data() const { return tensor ? M_getTensorData(tensor) : bytes.data(); }
   };
   std::map<std::string, Resident> residents;   // Resident is move-only
   ```

   (`M_freeAsyncTensorMap` is in `max/c/tensor.h`. `M_getTensorByNameFrom`'s comment says its
   tensor is borrowed from the map, hence `owner`.)
2. Binding inputs: unchanged except `r.data()`/`r.size` replace `r->second.data()`/`size()`.
3. After a run: wrap the output map in a `shared_ptr<OutMap>`. For each resident output, if its data
   pointer lies inside any borrowed input's range (MAX reused an input buffer), copy it into a new
   `Resident{bytes}` as today; otherwise store `Resident{owner, results[i], {}, bytes}` and do not
   free `results[i]`. Fed outputs are copied to Elm as today and their tensors freed.
4. `get`, `save`: read `data()`/`size`. `put`, `loadInto`: fill `bytes`.
5. New handlers: `handleLoadRangeInto` (7), `handleDrop` (8), `handleLoadRange` (9; reply on
   `loadIn` exactly as the `loadOut` handler does). Offsets are two u32 (low, high). Reading past the
   end of the file is an error (`std::_Exit` with a message, as today's errors).
6. At exit, print `HOST residents: N buffers, B bytes` after the per-graph lines.
7. `Bridge.elm`: `loadRangeInto`, `drop`, `loadRange` (encodings in §4.7; a `u64` helper writing two
   u32 LE).

Tests: the gates (MNIST SGD trace identical, AdamW identical after save/reload, charlm identical);
A2.2 exercises codes 7–9.

### A1. Operations and layers

Each item lists its code, its unit tests (`tensor/tests/TensorTests.elm` or a new
`tensor/tests/Round2Tests.elm`), its op-check entries and its must-not-compile program. Op checks go
in two new families in `opcheck/src/OpCheck.elm`, `"select"` (A1.1–A1.3, A1.5) and `"layers"`
(A1.4, A1.6–A1.9), each built with `family`, with NumPy references added to `REF` in
`opcheck/ref.py` and random-statistics checks to `STATS`/`check_stats`. Every new layer also gets a
`vmap` check in the existing `"vmap"` family: `Transform.vmap` over a batch of 3 against the three
results stacked (`T.stack`).

**A1.1 `put` without transposes.**
- Primitives `ScatterAxis`, `ScatterAxisAdd` (`a: [axis]`; operands x, updates, indices (rank 1,
  integer)).
- Shape: x and updates have the same rank; equal sizes except at `axis`, where updates has the
  indices' length; the result is x's meta.
- Mo: reshape indices to rank r with their length at `axis` and 1 elsewhere, cast to si64,
  `rmo.broadcast_to` the updates' shape, then `rmo.mo.scatter` (or the `scatter_add` spelling, which
  the inventory probe records first) with the axis attribute.
- Vjp: `ScatterAxis` → x: `scatterAxis axis g (zerosLike upd) idx`; updates: `gather axis g idx`;
  indices: none. `ScatterAxisAdd` → x: g; updates: `gather axis g idx`.
- Batch: x and updates batched → axis + 1 (an unbatched updates is broadcast first); indices batched
  → `unroll`.
- `Tensor.put`/`putAdd` call `O.scatterAxis`/`O.scatterAxisAdd`; `scatterAlong` is deleted.
  `ScatterRows`/`ScatterRowsAdd` stay for their internal users (gather's gradient).
- Op checks: the existing `put`/`putAdd` checks keep passing; new `putAxis1`, `putAxis2`,
  `putAddAxis1` on a rank-3 input, with gradients for x and updates (NumPy: index assignment and
  `np.add.at`).

**A1.2 `topK`, `bottomK`, `sort`.**
- Primitives `TopKValues`, `TopKIndices` (`a: [axis, k, largest]`, largest 1 or 0).
- Shape: axis in range; 1 ≤ k ≤ size (error "topK: k = 9 but axis 1 has size 5"); the result is x
  with size k at the axis; dtype x's (values) or si64 (indices).
- Mo: largest = 1 → `rmo.top_k(x) [k, axis]`, attributes si64, axis non-negative, two result types;
  largest = 0 → `rmo.mo.bottom_k(x, k, axis, sorted)` with rank-0 si64, si64, bool constants. Values
  return the op's first result, indices the second (`push` returns the first value number; the second
  is one more).
- Lower shares the op: after emitting either primitive for node e, also enter the sibling node
  (`E.prim sibling args params`, the other of the pair) in the region's memo with the other result's
  value number, together with its shallow structure, so the memo's collision check still holds.
- Vjp: `TopKValues` → `[ Just (E.failWith "topK: cannot be differentiated" (O.zerosLike x)) ]`, as
  `whileLoop` does in `Grad.elm`; `TopKIndices` is integral, so it is never differentiated.
- Batch: `axisRule shifted`.
- Public: `topK`, `bottomK` (`Retag` witness, the result size from the `Dim`), `sort` (the size read
  from the operand's shape at the axis; descending → `TopK*` with largest 1, else 0).
- Tests: the k error; a graph using both results has one `rmo.top_k` in its text; differentiating
  through `topK` reports the message once.
- Op checks (inputs from a new domain `"distinct"`: a random permutation of distinct values, so no
  ties): `topKValues`, `topKIndices` on the last and a middle axis, `bottomK`, `sortDesc`,
  `sortAsc` (NumPy: `np.sort`, `np.argsort`, `np.take_along_axis`).

**A1.3 `quickGelu`, `gumbelLike`, `categorical`.**
- `quickGelu x = x * sigmoid (1.702 x)`, in `Tensor` (composite in `Ops`).
- `gumbelLike x seed`: `Random.uniformLike` cannot take F32 when d is half, so build it in the
  module with `O.random` on F32 and x's shape, low 2⁻²³, high 1 − 2⁻²³; then
  `O.neg (O.log (O.neg (O.log u)))`, cast to x's dtype.
- `categorical logits seed = argMax last2 (logits + gumbelLike logits seed)`.
- Op checks: `quickGelu` value and gradient; STATS `categoricalStats`: 20,000 rows of the same
  4-class logits (broadcast from a constant), one draw each; the frequencies within 0.015 of
  softmax's.

**A1.4 `Nn` functions** (in `Nn.elm`, over `Expr`):
- `upsampleNearest2d f h2 w2 x`, x = [n, h, w, c]: reshape [n·h, w, 1, c]; `broadcastTo`
  [n·h, w, f, c]; reshape [n, h, 1, w·f·c]; `broadcastTo` [n, h, f, w·f·c]; reshape [n, h2, w2, c].
  Check h2 = f·h and w2 = f·w (`checkSpatial`, as pooling does). Op check vs `np.repeat` on axes 1,
  2, with gradient (each input cell receives the sum of its f² copies).
- `timestepEmbedding { maxPeriod, cosFirst, shift } e t`: half = e/2 (e odd: error); freqs_i =
  exp(−ln(maxPeriod) · i / (half − shift)) for i < half (a constant); args = `outer` of t and freqs
  ([n, half]); result `concat2` of (sin args, cos args), or (cos, sin) when `cosFirst`. Op check vs
  diffusers' formula written in NumPy (`get_timestep_embedding`).
- `causalMaskAt p s t`: query positions qp = p + `iota s` ([s], p broadcast); key positions
  kp = `iota t`; mask[i, j] = kp_j ≤ qp_i, with both broadcast to [s, t] (`columns`, `rows`) and
  `atMost`. Op check vs `np.arange(t)[None, :] <= (p + np.arange(s))[:, None]` for p = 0 and p = 5.
- `repeatHeads h x`, x = [g, t, j]: if h mod g ≠ 0, `E.failWith "repeatHeads: 8 heads are not a
  multiple of 3"`; else r = h / g; reshape [g, 1, t, j]; `broadcastTo` [g, r, t, j]; reshape
  [h, t, j]. Head i reads kv head i // r, as llama2.c (`h / kv_mul`) and Hugging Face's `repeat_kv`
  do. Op check vs `np.repeat(x, r, axis=0)`, with gradient.

**A1.5 `Nn.Sampling`** (new module; `elm.json`):
- `greedy = T.argMax Axis.last2`; `sample logits seed = Random.categorical logits seed`.
- `lowest : DT -> Float` in `Ops`: f16 −65504, bf16 and f32 −3.4028235e38, f64 −1.7976931348623157e308.
- `keepTopK k logits`: values from `topK` on the last axis with a module-owned tag `K` (`T.dim K k`);
  threshold = its last column (`slice` of size 1, broadcast back to [n, v]); keep where logits ≥
  threshold (`atLeast`), else `lowest`. Ties at the threshold keep more than k (documented).
- `nucleus p logits seed`: `( sorted, order ) = T.sort { descending = True } Axis.last2 logits`;
  `before = T.cumsumWith { exclusive = True, reverse = False } Axis.last2 (T.softmax Axis.last2
  sorted)`; keep where `before < p` (the first column always kept); masked = `select keep sorted
  lowest`; `j = Random.categorical masked seed`; token = `T.pick j order`.
- Op checks: `greedy`, `keepTopK` (values; masked entries equal `lowest`); STATS `nucleusStats`:
  20,000 rows of one 6-class distribution with p = 0.6, sampled tokens never outside the nucleus and
  frequencies within 0.015 of the renormalised probabilities.

**A1.6 `Nn.Linear.paramsWithoutBias`** (A0.3) and **`Nn.Embedding.unembed e x = x |> T.matmul
(T.transpose e.table)`** (the record's field is `table`). Op check `unembed`
vs `x @ table.T`, gradients for x and the table.

**A1.7 `Nn.RmsNorm` and `Nn.GroupNorm`** (new modules; `elm.json`). A helper in `Ops`:
`inF32 : (Expr -> Expr) -> Expr -> Expr` casts F16/BF16 to F32, applies, casts back (identity for
F32/F64).
- RmsNorm: y = x · rsqrt(mean(x², last axis, kept) + ε) · scale (scale broadcast as rows), the
  normalisation inside `inF32`. `apply3` is the same over rank 3. `params`: `Param.ones .scale`,
  `Param.config .epsilon`.
- GroupNorm, x = [n, h, w, c], g groups (c mod g ≠ 0: error): reshape [n, h·w, g, c/g]; μ = mean over
  axes 3 then 1, kept as [n, 1, g, 1]; var = mean of (x − μ)² the same way; x̂ = (x − μ) ·
  rsqrt(var + ε) inside `inF32`; reshape [n, h, w, c]; · scale + bias broadcast on the last axis. Rank
  4 throughout. `params`: `ones .scale`, `zeros .bias`, `config .groups`, `config .epsilon`.
- Op checks: both, values and gradients for x and scale (NumPy: the same formulas in f64, compared at
  round 1's f32 tolerance); a bf16 variant of each in the `"dtypes"` family at its bf16 tolerance if
  `Support` allows the primitives on the CPU (otherwise recorded as a GPU-only check for M4).

**A1.8 `Nn.Rotary`** (new module). Positions cast to F32. invFreq_k = base^(−2k/j) for k < j/2 (a
constant). θ = `outer` positions invFreq ([s, j/2]); cos θ and sin θ broadcast over heads to
[h, s, j/2]. j odd: error.
- `Halves`: x1 = x[..., :j/2], x2 = x[..., j/2:] (`slice` on the last axis); result `concat2`
  (x1·cos − x2·sin, x1·sin + x2·cos).
- `Interleaved`: reshape x to [h, s, j/2, 2]; even = [..., 0], odd = [..., 1] (slice and reshape to
  [h, s, j/2]); (even·cos − odd·sin, even·sin + odd·cos) stacked on a new last axis and reshaped to
  [h, s, j].
- Op checks: both pairings vs NumPy written from llama2.c's `run.c` loop (Interleaved) and Hugging
  Face's `rotate_half` (Halves), for positions 0..s−1 and 7..7+s−1; gradients for x.

**A1.9 `Nn.FeedForward`, `Nn.Attention` additions, `Nn.KvCache`** (new modules where new).
- `gatedParams dt { bias } m f`: three `Linear.params` or `paramsWithoutBias`; `applyGated act p x =
  Linear.apply p.down (act (Linear.apply p.gate x) |> T.times (Linear.apply p.up x))`.
- `paramsWith`: as `params` with each projection's spec chosen by the two flags.
- Heads helper (module-internal, generalising today's `heads`): project with a `Linear d m w`, then
  `T.factorLast3 heads headDim` ([s, H, j]; its size check enforces H·j = w) and
  `T.permute Axis.swap01of3` ([H, s, j]); `merge` as today.
- `selfGrouped cfg p x`: q from `query` with h heads, k and v from `key`/`value` with g heads; with
  `rotary = Just (r, pos)`, `Rotary.apply r pos` on q and k; k, v through `Nn.repeatHeads p.heads`;
  `Nn.causalAttention` if `causal`, else `Nn.attention` without mask; merge, `out`.
- `selfCached cfg p pos cache x` (x = [s, m], the new tokens): positions = pos + `iota s`; q, k, v
  as above with rotary at those positions; `cache2 = KvCache.write pos k v cache`; keys and values
  from `cache2` through `repeatHeads`; `q |> Nn.attention { mask = Just (Nn.causalMaskAt pos s t),
  bias = Nothing } keys values`; merge, `out`; return `( cache2, y )`. Positions past t are the
  caller's to prevent (MAX's scatter is undefined there); documented.
- `crossParams`, `attendTo p memory x`: q from x with `query`, k and v from memory with `key`/`value`
  (`Linear d c m`), `Nn.attention` without mask, merge, `out`.
- `KvCache.sig dt g t j`: a record signature with `Sig.label "keys"` and `Sig.label "values"`
  tensors. `write pos k v c`: idx = pos + `iota s`; `{ keys = c.keys |> T.put Axis.retag1of3 idx k,
  values = c.values |> T.put Axis.retag1of3 idx v }`.
- Op checks (NumPy multi-head attention written out, weights as inputs): `selfGrouped` with g = h,
  g = h/2 (causal, both rotary pairings); `attendTo`; `selfCached` from an empty cache at pos 0 with
  s = 4, then pos 4 with s = 1, equal to `selfGrouped` over the 5 tokens' last row; gradients of
  `selfGrouped` and `attendTo` for x.

**A1.10 Must-not-compile programs** in `tensor-api/bad/`, each with its compiler output saved as
`.txt` as round 1's are:

| Program | The mistake |
|---|---|
| `BadRotarySeq.elm` | rotary positions of a sequence `T` applied to queries of `S` |
| `BadGroupedHeadDim.elm` | `Grouped` keys projected to another head width tag |
| `BadGroupNormRank.elm` | `GroupNorm.apply` on an R2 tensor |
| `BadTopKIndexFloat.elm` | `topK` indices added to float logits |
| `BadCategoricalInt.elm` | `Random.categorical` of integer logits |
| `BadInferState.elm` | an `Infer.step` body returning a cache of another type |
| `BadCrossWidth.elm` | `attendTo` with the memory and query widths swapped |
| `BadCacheSeq.elm` | `KvCache.write` keys of tag `S` into a cache whose head tag differs |

`examples/All.elm` gains one example per new module (they must compile).

**A1.11 Half-precision paths testable on the CPU.** `Nn.attend` fills masked scores with
`max(−1e9, lowest dtype)` (−65504 in f16; unchanged in f32, so round 1 is bit-identical), and its
softmax runs inside `inF32`. Tests: generic text of an f32 attention graph unchanged; an f16 graph
builds.

### A2. End-to-end checks with synthetic models

A new app, `spikes/max/models/apicheck/` (`elm.json` with `"../lib/src"`, `"../../bridge"`;
`src/ApiCheck.elm`; a `Makefile` target `run-apicheck` building `build/apicheck_bridge` from
`mnist/host/max_bridge.cpp` and the app's `.so`, as `charlm_bridge` is built). Flags select a check;
each prints `PASS`/`FAIL` lines; `make check-apicheck` runs all three and fails on any `FAIL`.

**A2.1 Cache against recompute.** A Llama-shaped model in `ApiCheck.elm`: vocabulary 256, width 64,
4 heads, 2 kv heads, head width 16, feed-forward 128, 2 layers, context t = 32; `RmsNorm`,
`selfGrouped`/`selfCached` with rotary, `Gated` SwiGLU, tied `unembed`. Parameters drawn on the host
with `Param.initInPlace` (seed 7).
- Graph `full` (`Infer.step`, state `Sig.unit`): tokens [32] fed (padded with 0) → logits [32, 256].
- Graph `step` (`Infer.step`, state a list of 2 `KvCache.sig`, initialised by `Infer.initGraph` with
  zeros): token [1] and position [1] fed → logits [1, 256].
- Feed a fixed 8-token prompt through `step` one token at a time, then 8 greedy tokens; run `full`
  on the same 16 tokens. Pass: at every position, max |Δ| / max |ref| ≤ 1e-4 between the two logits,
  and the 8 greedy tokens equal `full`'s argmax continuation. Both pairings (`Interleaved`,
  `Halves`).

**A2.2 Import.** `models/apicheck/make_checkpoint.py` (MAX venv, NumPy only, seed 0) writes
`work/apicheck/synthetic.safetensors`: a `__metadata__` entry; f32 and f16 tensors in PyTorch
layouts: a linear weight [out, in], a conv filter OIHW, a fused qkv weight [3m, m], a bias; and
`work/apicheck/expected.bin`, the parameters in our layouts (transposed, filter to RSCF, qkv split,
f16 cast to f32), concatenated in `Param.names` order.
- `models/lib/src/Checkpoint/Safetensors.elm`: `headerLength : Bytes -> Maybe Int` (the first 8
  bytes, u64 LE); `parse : Bytes -> Result String (List Entry)` with `Entry = { name : String, dtype
  : String, shape : List Int, begin : Int, end : Int }` (offsets relative to the data, which starts
  at 8 + header length; `__metadata__` skipped); `loadAll : String -> (Entry -> String) -> List
  Entry -> List Bridge.Command` (one `loadRangeInto` per entry, under the name the function gives).
- The app: `loadRange` 8 bytes, then the header; `loadAll`; an `importGraph` over a spec with two
  `Param.named` parts, run once whole and once part by part; `get` each parameter and compare with
  the matching slice of `expected.bin` (read with `loadRange`); `drop` every raw buffer. Pass:
  bytes identical both ways; the exit line shows only the parameters resident.

**A2.3 A UNet-shaped block against NumPy, trained.** A block over [2, 8, 8, 16]: conv 3×3 →
`GroupNorm` (4 groups) → SiLU → plus a `timestepEmbedding` (16) through a `Linear` → conv →
`upsampleNearest2d` 2 → `attendTo` a memory [6, 24] (per image, via `vmap`) → conv 1×1.
- Forward: the parameters are `save`d to `work/apicheck/`, a NumPy forward pass in
  `models/apicheck/ref_block.py` reads them and the same inputs; pass at max |Δ| / max |ref| ≤ 1e-4.
- Training: 30 `Train.step`s (AdamW 1e-3) on MSE to a fixed random target; pass if the mean loss of
  the last 5 steps is below half that of the first 5.

### A3. Writing graphs for a GPU (no GPU needed)

1. **Inventory.** `capi/scripts/inventory/gpu_ir.py` builds, with `DeviceRef.GPU()`, one small graph
   per lowering pattern the package uses (element-wise, constant, matmul, each reduce, reshape,
   transpose, broadcast, slice, concat, pad, gather, scatter, top_k, bottom_k, range, random,
   layer_norm, conv, conv_transpose, pools, `mo.if`, `mo.while`, `mo.call`, `mo.custom`), prints each
   in custom and generic form to `work/inventory/g14_gpu.txt`, and runs the generic text through
   `mlir-opt --emit-bytecode` and `capi/scripts/bc_dump.py`. Record in a new `mo-inventory.md` §14:
   the type's text and bytecode encoding with a device, which operands stay on the CPU (and how a CPU
   value is typed inside a GPU graph), where MAX inserts `rmo.mo.transfer` and its chain.
2. **`Graph`.** `I.Graph` keeps, besides its CPU ops, what lowering needs to run again (the output
   expressions and the specs). `toBytecodeOn Cpu` and `toGenericTextOn Cpu` return today's results.
3. **`Lower`, `Mo`, `MlirBc`.** A device in the lowering state; `Mo.tensorType` takes it; `MlirBc`
   encodes the device in tensor types as recorded in step 1; a per-primitive list in `Mo` of operands
   that stay on the CPU, emitted with CPU types; refusals collected as errors (`topK`/`bottomK`/`sort`
   off the last axis: "topK: on a GPU only the last axis is supported").
4. **Tests.** `toBytecodeOn Cpu` is byte-identical to `toBytecode` for every op-check, MNIST, charlm
   and apicheck graph. For every op-check family written for `Gpu 0`: our bytecode equals what
   `mlir-opt --emit-bytecode` writes from our generic text, and five small graphs match the IR MAX's
   Python API builds for the same computation, up to value names. Running them waits for M4.

## 6. Validation of this round

| What | Reference | Pass |
|---|---|---|
| round 1's gates | round 1 | unchanged, MNIST and charlm bit-identical |
| new primitives and layers | NumPy (`opcheck`) | round 1's tolerances; bf16 at its tolerance |
| random draws | statistics (`check_stats`) | within 0.015 of the target frequencies |
| layers under `vmap` | unrolled loop | round 1's tolerances |
| must-not-compile programs | the compiler | 8 new programs refused |
| cache vs recompute (A2.1) | the same model, uncached | max \|Δ\| / max \|ref\| ≤ 1e-4; tokens equal |
| import (A2.2) | NumPy's conversion | byte-identical |
| UNet-shaped block (A2.3) | NumPy forward pass; training | 1e-4; loss halves |
| GPU writing (A3) | `mlir-opt`; MAX's Python IR | identical bytecode; same IR up to names |

## 7. Later: models and GPUs (M1–M4)

Starts when the user says so. Needs downloads (asked for first, licenses checked), about 5 GB of
disk, and for M4 the GPU machine with a GPU-enabled dev image (NVIDIA container toolkit, `--gpus
all`), leaving the stable images alone. Each phase is lowered to this round's level of detail when it
starts. **Error metric** throughout: max |ours − ref| / max |ref|.

`models/lib/` gains, as the phases need them: `Checkpoint.Llama2c` (seven i32 config fields, a
negative vocabulary size meaning an untied output; f32 tensors in a fixed order including two legacy
`freq_cis` arrays before `wcls`, skipped); `Tokenizer.Unicode` (letter and number tables generated
from Python's `unicodedata`, since eco's regex has no `\p{..}`); `Tokenizer.Bpe` (hand-written
pre-tokenizers: GPT-2's contractions, letter, number and other runs; CLIP's cleaned, lower-cased text
with digits split one by one, `</w>` word ends, start 49406, end 49407, padded to 77 with 49407,
`ftfy` not reproduced); `Tokenizer.Llama2c` (`tokenizer.bin`, vocabulary size from the checkpoint, a
dummy-prefix space and BOS, merges by best score, byte fallback); `Model.Gpt2`, `Model.Llama`,
`Model.Clip`, `Model.Unet`, `Model.Vae`, `Model.MnistUnet`; `Diffusion.Schedule`, `Diffusion.Guidance`;
`Generate` (prompt fed one token at a time through one compiled cached step); `Image.Ppm`.

**M1. Diffusion from scratch on MNIST (CPU, no download).** `Model.MnistUnet`: resolutions 28, 14,
7 with 32, 64, 64 channels; GroupNorm, SiLU, timestep embedding, nearest upsampling, attention at
7×7, batched with `vmap`; linear schedule of 1,000 steps; noise-prediction loss with `Train.step`;
DDIM in 50 steps with `Infer`; PPM grids. Pass: round 1's CNN (98.57%) gives 1,000 samples a mean
top probability ≥ 0.9, each digit 5–15% of them.

**M2. Language models on the CPU.** Downloads: llama2.c `stories15M.bin` (60 MB), `tokenizer.bin`
(derived from Meta's Llama 2 tokenizer: license checked), GPT-2 small `model.safetensors` (~550 MB),
`encoder.json`, `vocab.bpe` (MIT). A reference venv (`spikes/max/work/ref-venv`: NumPy, `regex`).
- llama2.c with `Interleaved` rotary vs `run.c` (`cc -O2`, patched to dump logits): tokenizer ids
  identical on 20 prompts; teacher-forced logits on `run.c`'s own greedy continuation ≤ 1e-4; 128
  greedy tokens identical except at a near-tie (top two within 1e-4 · max |logit|), where the
  comparison stops and the position is reported.
- GPT-2 small (tied `unembed`, `geluTanh`, `Conv1D` weights already `[in, out]`, `c_attn` split by the
  import graph, `__metadata__` and mask buffers skipped) vs a NumPy forward pass and OpenAI's
  `encoder.py`: ids identical on 20 prompts; logits ≤ 1e-4 on 3 prompts from one padded uncached
  graph; cached generation equal to it (tokens identical, logits ≤ 1e-4); tokens per second recorded.

**M3. Stable Diffusion 1.5 (CPU first).** Download the fp16 safetensors of the text encoder, UNet and
VAE (~2 GB; CreativeML OpenRAIL-M, accepted by the user first); reference: diffusers and CPU PyTorch
in a separate venv (~2 GB). Facts to follow: `to_q/to_k/to_v` without bias, `to_out` with;
`attention_head_dim: 8` means 8 heads; cross-attention keys and values from 768-wide text states;
`proj_in`/`proj_out` are 1×1 convolutions; GroupNorm 32 groups, ε 1e-5 in ResNets and 1e-6 in
transformer blocks and the VAE; timestep embedding `flip_sin_to_cos = True`, shift 0; GEGLU's fused
`proj`: first half the value, second the gate; VAE decode of latents / 0.18215 through
`post_quant_conv`; DDIM constructed explicitly (scaled-linear 0.00085–0.012, `steps_offset = 1`,
`set_alpha_to_one = False`, "leading", eta 0). Pass: CLIP states ≤ 1e-3; one UNet prediction ≤ 1e-3;
VAE decode ≥ 40 dB PSNR; 25 DDIM steps at guidance 7.5 from the same latents ≥ 25 dB; time per image
recorded.

**M4. GPUs.** The host's `M_ACCELERATOR` device (`"device": "gpu:0"`), residents on it (`put` makes a
host tensor and `M_copyTensorToDevice`; `get`/`save` copy back); round 1's gates and this round's on
the GPU in f32 (tolerances widened where GPU kernels need it, recorded); MNIST AdamW within 0.3
points of 97.15%; the f16/bf16 op checks and support probe on the GPU; M2 and M3 on the A4500 and
the A1000, f32 then bf16, with tokens per second and seconds per image; then fused attention
(§4.9).

## 8. Risks and open questions

- **The host rework (A0.7)** changes how every model's state is kept. The gates require bit-identical
  MNIST and charlm results, and the aliasing guard covers MAX reusing an input buffer.
- **Output map lifetime.** Whether a tensor from `M_getTensorByNameFrom` outlives its map is not
  documented clearly; keeping the map alive (`OutMap`) is safe either way.
- **`rmo.mo.scatter` semantics and spelling** (element-wise along an axis, indices shaped like the
  updates) are checked by the A1.1 inventory probe before `put` switches over.
- **Sharing `top_k` in `Lower`** relies on memo entries for a node the walk has not visited; the
  shallow-structure check guards collisions.
- **bf16/f16 on MAX's CPU** may be unsupported for some primitives; such checks move to M4.
- **GPU IR** may need more than types and CPU operands (A3.1 finds out); refusals carry what is not
  understood yet.

## 9. Adversarial review (2026-11-11)

A separate reviewer checked the first draft against the package, the host, MAX's headers and Python
ops, with two MAX probes. It confirmed: `T.put`, `Axis.retag1of3`, the `Retag`/`Axis` parameters,
`cumsumWith`'s `exclusive`, `pick`, `Nn.attention`'s argument order; `Param.config` holding a tensor;
multi-result nodes only for `Call`/`If`/`While`; rank-free internal ops; `rmo.top_k`'s attributes and
sorted output on a middle axis; `bottom_k`'s operands; 1-D `argsort`; `rms_norm`, `group_norm`,
`resize.nearest`; `M_ACCELERATOR`, `M_copyTensorToDevice`; free host codes 7 and 8. Its findings,
all accepted after checking the cited code (phase names are this version's):

| # | Severity | Finding | Resolution |
|---|---|---|---|
| 1 | high | `importGraph` over a whole spec cannot import one part at a time: names are positional | `Param.named` (A0.2) |
| 2 | high | eco's `elm/regex` has no `\p{L}`/`\p{N}`; CLIP's split differs from GPT-2's | hand-written pre-tokenizers over generated tables (§7) |
| 3 | medium-high | the MNIST UNet's padding, resolutions and attention size contradicted each other | 28 → 14 → 7, attention at 7×7 (M1) |
| 4 | medium | the host copies every resident output; on a GPU that reads device memory | residents kept in place (A0.7) |
| 5 | medium | `KvCache.write` through `put` transposes the whole cache four times | `put` as one element-wise scatter (A1.1) |
| 6 | medium | element-wise relative error undefined near zero; 1e-5 too tight; exact greedy match fragile; `run.c` prints no logits | max \|Δ\| / max \|ref\|; 1e-4; near-tie rule; patched `run.c` (M2) |
| 7 | medium | per-length graphs mean many compiles | one padded uncached graph; one cached step (A2.1, M2) |
| 8 | medium | SD 1.5 details missing | listed in M3 |
| 9 | medium | batching unstated; `selfGrouped` required positions without rotary | principle 7, `vmap` checks (A1); positions in `rotary` |
| 10 | medium-low | GPU graphs build without a GPU; device in the type; CPU-only operands; `top_k` last axis on GPU | A3 |
| 11 | low | resident names come from `Names.names` | A0.2 |
| 12 | low | GPT-2's `Conv1D` weights are `[in, out]`; `geluTanh`; skip `__metadata__` and mask buffers | M2, A2.2 |
| 13 | low | llama2.c `freq_cis` arrays, tokenizer vocabulary size, dummy prefix and BOS, tokenizer license | §7, M2 |
| 14 | low | rank-0 as `[1]` only in `Train`; `Param.initGraph` outputs fed | A0.1, A0.5 |
| 15 | low | rank 6 in upsampling unnecessary | rank 4 (A1.4) |
| 16 | low | `keepTopK`'s tag; `flash_attention_gpu`'s layout; channels-first MAX ops | §4.4, §4.9 |
| 17 | low | Gumbel noise in half precision reaches +∞; −1e9 is −∞ in f16 | f32 draws (A1.3); lowest finite fill, f32 softmax (A1.11) |
| 18 | low | apps need `../../bridge`; the venv lacks `regex`, `safetensors`; tie-free top-k tests | §4.8, M2, A1.2 |

## 10. Changes made while lowering (2026-11-11)

- **Scope:** the user chose to build the API only: no downloads, no real models, no GPU in this
  round. The model and GPU phases moved to §7; `models/lib/` keeps only `Checkpoint.Safetensors`
  now. Phases are named A0–A3 and M1–M4, because R0–R5 collided with the rank types `R1`–`R5`.
- **No multi-result primitives.** `topK` is two single-result primitives whose lowering shares one
  `rmo.top_k`, instead of changing `Shape`, `Vjp`, `Grad`, `Batch`, `Lower`, `Shared` and `Control`
  for several results.
- **`put` as one element-wise `rmo.mo.scatter`** along the axis, instead of full-coordinate
  `scatter_nd` indices; the gradient is a `gather` on the same axis.
- **Host ownership:** residents hold their output map alive and fall back to a copy when MAX reuses
  an input buffer; `loadRange` is a `hostOut` command (9) replying on `loadIn`.
- **Names:** `Param.named` takes absolute names; the innermost wins.
- **Added `Param.initInPlace`** so synthetic models are drawn on the host (A2).
- **GroupNorm at rank 4** ([n, h·w, g, c/g]); **`Graph` keeps what re-lowering needs** for
  `toBytecodeOn`.
- **Added A2**, an end-to-end check on synthetic models, so everything is tested without downloads.

## 11. Results (2026-11-11): A0–A3 done

All gates on the final code (`/tmp/eco-round2/gates-final.sh`, then the bf16 norms):

| Gate | Result |
|---|---|
| round 1's models | identical: SGD 95.87% (bytecode and text), first 100 step losses bit-identical to the original DSL; AdamW 97.15% (same after save and reload); stack 97.65%; CNN 98.57%; momentum 97.51%; Lion 95.97%; LoRA 97.54% with frozen buffers byte-identical; charlm held-out 1.9624 |
| `check-tensor` | 67/67 (38 before) |
| `check-api` | examples compile (new `Round2.elm`); 25 programs refused, 8 new, each a type mismatch at the faulty line (`bad/*.txt`) |
| `check-ops` | 389/389, also from bytecode: round 1's 328; `select` 22 (top-k, sort, put on middle axes with gradients, quickGelu, greedy, keep-top-k, categorical and nucleus statistics); `layers` 29 (upsampling, timestep embeddings, causal masks, repeated heads, unembed, RMS-norm, group-norm, both rotary pairings, gated SwiGLU, grouped and full self-attention, cross-attention, a cached step against the full sequence; gradients); `vmap` +3; `dtypes` +2 (RMS-norm and group-norm in bf16 on the CPU) |
| `check-apicheck` | cache: 16 positions, max \|Δ\| / max \|ref\| 1.0e-6 (interleaved) and 0 (halves), greedy tokens equal; import: whole (11 parameters) and part (6) byte-identical, raw buffers dropped; block: 2.1e-6 against NumPy, loss 3.46 → 0.10 in 40 AdamW steps |
| `check-gpu-ir` | 13 families written for GPU 0 read back through `mlir-opt` identically; 1,895 ops placed as MAX's API places them (76 op names), 0 differ; `control`, `transforms`, `vmap` refused (they contain `cond`), `select` refused (top-k off the last axis) |

Per-run boundary bytes stayed as round 1 measured them; a cached decoding step of the A2.1 model
sends 48 bytes and receives 1,040.

## 12. Changes made while implementing (2026-11-11)

- **Rank-0 outputs need no widening:** MAX returns them (round 1's `measure` does). `Io` widens
  inputs only; `Train` uses its `unnarrow` instead of a private copy.
- **The host header is 16 bytes,** not 8; codes 7–9 keep the field order of §4.7 after it.
- **The aliasing guard is needed:** in the import check MAX returned 8 outputs inside input buffers
  (unchanged biases, slices). Without the copy, dropping the raw buffers would have freed memory the
  parameters still used. Round 1's models never trigger it.
- **`Conv2d.kernel` added:** with its kernel tags private, no user code could describe a raw
  checkpoint filter (A2.2 found this).
- **GPU writing is a pass over marked ops, not a second lowering:** `Mo` marks the ops that make host
  operands (`eco.host`) and a top-k off the last axis; the graph keeps the marked ops; `Device.place`
  strips the marks for the CPU (so CPU output is round 1's, byte for byte) or writes the device into
  every other type. `MlirBc` needed no change: opaque types are encoded as their text.
- **Predicates must be on the CPU** (`work/inventory/g16_gpu.txt`): MAX refuses `cond` and
  `while_loop` with a GPU predicate. Writing them for a GPU is refused until M4, which needs a
  transfer threaded through the chain.
- **The GPU placement check covers every op-check family** (1,895 ops against the inventory) instead
  of five small graphs compared with MAX's text.
- **Module documentation:** `mo-inventory.md` §14.

### Ideas recorded for later (2026-11-11 discussion)

- **mmap in the host:** `loadRangeInto` as views into a read-only mapping, kept alive like `OutMap`,
  copying only misaligned tensors. It removes the file-to-vector copy and keeps raw tensors in the
  page cache, so peak memory is about the converted parameters (a 7B fp16 model would not fit this
  machine's 29 GB otherwise).
- **A linear layout option** so checkpoint weights in `[out, in]` need no conversion: the mapped
  bytes are the parameters, loaded lazily.
- **mmapped `Bytes` in eco** (off-heap bodies addressed by `HPointer`, view slices): not faster for
  weights, which Elm never reads, but the way to stream datasets and NIC/accelerator buffers without
  copying through the Elm heap; it touches the HEAP invariants.
