---
status: done
updated: 2026-11-11
---

# Plan: a typed Elm tensor API covering Nabla's, on MAX

## 1. Aim and outcome

Port the API of Nabla (a Python array and autodiff library on Modular MAX, https://www.nablaml.com/api/,
catalogued item by item in Appendix A) to an Elm package, `eco-lab/tensor`, that writes MAX's `mo`
graphs directly. An Elm program can then describe what Nabla can: element-wise math and linear
algebra, reductions and shape operations, reverse- and forward-mode autodiff to any order,
vectorisation, layers, losses, optimizers, transformers, convolutions, LoRA and QLoRA.

The design rule: **only valid compute graphs can be written.** Where Elm's type checker can refuse
a graph that MAX would refuse (or that would compute nonsense), it does, without making the API
heavy. What types cannot express is checked when the graph is built, before MAX sees it. Only
data-dependent faults (an index out of range at run time) are left to MAX.

**Read before coding:**
- `plans/tensor-dsl.md` (the DSL this replaces) and `plans/mlir-bytecode-to-max.md`.
- `spikes/max/README.md`, and `spikes/max/mnist/src/{Tensor,Graph,Param,Train,MlirBc,MnistNet,Mnist,Bridge}.elm`
  with `mnist/host/max_bridge.cpp`.
- `spikes/max/mo-inventory.md`: how MAX 26.7.0's own graph API spells every operation this plan
  emits, recorded from MAX itself. Its scripts are in `spikes/max/capi/scripts/inventory/`.
- `spikes/max/tensor-api/`: every public signature of §4 as a type-only stub. Eco compiles it with
  its example programs, and it refuses every program in `bad/`. Its README gives the check commands.

## 2. Where we start

- **The DSL** (`spikes/max/mnist/src`, `plans/tensor-dsl.md`):
  - `Tensor t` is an immutable expression with a structural key, a pair of 31-bit hashes.
  - `Tensor.graph name arg out body` lowers it onto `Graph.elm`'s tape, which infers shapes,
    differentiates (`Graph.grad`) and writes `mo`. The output is custom text, or, through
    `MlirBc.elm`, generic text or MLIR bytecode.
  - It has about 20 operations, phantom dtypes, and shapes as values.
  - `Param` describes parameters and `Train` builds the SGD step.
  - MNIST trains to 95.87% through `max_bridge.cpp`. Elm owns the parameter block as `Bytes` and
    sends it with every step.
- **MAX facts** (`spikes/max/mo-inventory.md`):
  - Graphs use one level of IR: `rmo.<op>`, `rmo.mo.<op>` and plain `mo.<op>`. This is exactly
    what `Graph.elm` writes.
  - Element-wise ops, `rmo.select` and `rmo.matmul` broadcast implicitly (numpy rules, including
    batch dimensions) and promote safe dtype mixes.
  - Reductions keep the reduced axis with size 1. Dropping it takes an `rmo.reshape`.
  - Axes are passed three ways:
    - an `index` attribute: reductions, softmax, cumsum, gather, scatter, concat;
    - an operand: transpose's permutation, `band_part`, pad;
    - `si64` attributes: `top_k`.

    `softmax` with a negative axis fails to compile.
  - `exp`, `sqrt` and `sigmoid` on integers, and `negate` on `u8`, build and verify, then fail to
    compile with an opaque error.
  - There is no `less`/`less_equal` op. There are:
    - one-op reductions: `rmo.mo.reduce.mean`, `mo.reduce.layer_norm`;
    - `rmo.mo.linalg.band_part`;
    - gather and scatter: `rmo.mo.gather`, `rmo.mo.scatter`, `rmo.mo.scatter_nd.add`;
    - convolution: `rmo.conv`, `rmo.conv_transpose` (NHWC, filters RSCF);
    - pooling: `rmo.max_pool` / `avg_pool`, with no backward op;
    - random: `rmo.mo.random.normal` / `uniform`, whose seed is a `[1] ui64` operand. The same seed
      gives the same values.
  - `acos` goes through `mo.custom [symbol = "mo.acos"]`.
  - **Subgraphs** are a second top-level `mo.graph` marked `isSubgraph`, called through
    `mo.call @name(args..., chain)` with a `!mo.chain` threaded call to call. A subgraph body may
    not read outer values: MAX enforces region isolation. **`mo.call` must sit directly in a
    `mo.graph`**: inside `mo.if` or `mo.while`, MAX refuses it.
  - **Control flow:**
    - `mo.if` has regions without block arguments that read outer values directly.
    - `mo.while` has a condition region and a body region over the carried values.
    - Both carry the chain as an extra value.
  - Compile cost is a fixed 19–25 s per structurally new graph and grows slowly with size. One
    GPT-like block took 25 s and 96 inlined copies 34 s (review, finding 12).
- **Prototypes and stub** (Appendix B; `spikes/max/tensor-api/bad/`): the counterexamples are
  rejected at compile time with errors at the faulty line, in the user's vocabulary.

## 3. Design decisions

### 3.1 Shapes: fixed ranks with named dimensions

`Tensor kind dtype shape`.
- `shape` is one of `R0`, `R1 a`, `R2 a b` … `R5 a b c d e`.
- Each letter is a **dimension tag**: an empty type the program declares (`type Hidden = Hidden`)
  and sizes with `hidden = T.dim Hidden 128`.
- `T.dim` takes the tag's constructor, so a tag is never a free type variable by accident.
- A tag that is a type variable in a signature (`Tensor … (R2 n Pixels)`) stands for any size.
  That is how one network serves several batch sizes.

Consequences:
- Element-wise operations need equal shape types.
- `matmul` unifies the inner dimension.
- Axis operations take generated witnesses (§3.7).
- A loss is `R0` by type, and a gradient has its parameter's type.

Ranks are fixed rather than type-level lists because errors then print as `R2 n Hidden`. Code that
works at several ranks is written once per rank; the library does that once and layers hide it.

Sizes the types cannot compute are written as **declared dimensions** and **checked when the graph
is built**. These are:
- a reshape's element count;
- `factorLast3 heads headDim` against the model width;
- concatenated sizes;
- slice bounds;
- conv and pool output sizes;
- `stack`'s length.

Tags are phantom types, so Elm cannot compare two `Dim`s of one tag. A tag declared twice with
different sizes is caught only where two such tensors meet in an operation, and the error then
names both sizes.

### 3.2 Kinds and dtypes; `Mask`

- **Kinds.** The kind is its own type parameter (`Tensor Floating F32 s`, `Tensor Integral U8 s`),
  so messages print the user's words. A first prototype nested the kind inside the dtype, and its
  messages printed `T.Num (T.Floating T.B32)` (Appendix B).
- **Which ops take which kinds.** Float-only operations take `Tensor Floating d s`; arithmetic
  takes any kind.
- **Pairing.** Only `Tensor` pairs a kind with a dtype: through inputs, `toFloat`, `toInt`, and
  `cast` with a witness such as `T.bfloat16 : DType Floating BF16`.
- **`Mask s`.** Booleans are a separate type: comparisons return a `Mask`, `select`, `and`, `or`
  and `not` take one, and `indicator` turns it into numbers. No arithmetic applies to it.
- **Finer kernel gaps** are not encoded in types. Examples are unsigned `negate` and an op
  missing for `bf16` on CPU; a split into signed and unsigned kinds would double many signatures.
  The dtype is known when the graph is built, so a **support table** per primitive refuses these
  with a clear message. The table is filled by a probe that compiles every primitive × dtype on
  MAX (P0).

### 3.3 Shapes and dtypes are known when a tensor is made

- Every expression carries its value-level shape and dtype, computed by its constructor.
- An error is recorded on the expression that caused it, with the public function's name and the
  shapes involved, and reported when the graph is built.
- `T.shapeOf` exposes the shape to user code.
- `Graph.elm`'s shape inference goes away; lowering only writes.

### 3.4 Broadcasting is explicit, and only element-wise operations consume it

These functions insert size-1 axes that MAX's implicit broadcasting expands:
- `T.rows` and `T.columns`;
- `T.broadcast` (an axis witness);
- `T.maskBroadcast`.

The size of such an axis is **pending** until the tensor meets a sized operand in an element-wise
operation (`plus`, `times`, `select`, …), which resolves it. Every other consumer of an unresolved
pending axis is a build error that suggests `broadcastTo`. Without this rule they would silently
compute on size 1; this covers reductions, softmax, cumsum, reshape, concat, slice, gather, a
matmul contraction, graph outputs, and subgraph or region arguments. Matmul's batch axes may be
pending.

Other rules:
- A real size-1 axis meeting a size-N axis is also a build error, because MAX would broadcast it.
- `broadcastTo` and `fillLike` know their sizes. Lowering writes them as size-1 operands where
  every consumer broadcasts, and as `rmo.broadcast_to` otherwise.
- There is no rank-free broadcast: the earlier `everywhere : R0 -> s` had no rank, so it is
  replaced by `fillLike scalar template`, `scale` and `shift`.

### 3.5 Gradients are expressions; every transform traces on placeholders

- **VJP rules.** Each primitive has a vector-Jacobian rule written with the same expression
  builders as the public operations. A gradient is therefore an ordinary expression: it shares
  sub-expressions with the forward pass through the structural keys, and it can be differentiated
  again.
- **Forward mode** (`jvp`) is derived by transposing the vjp ("double vjp"), so primitives need no
  separate jvp rules.

Transforms trace on placeholders. `grad f x` traces `f` on a fresh placeholder `v`, differentiates
with respect to `v`, then substitutes `x` for `v`. Differentiating with respect to the node `x`
itself would be wrong whenever `x` also occurs inside `f`:
- `grad (\y -> y |> times x) x` would give 2x.
- `hessianVector f x (grad f x)` would add a spurious term.

These are the classic perturbation-confusion bugs (review, finding 1).

**Placeholder keys** must differ between nesting levels without a name supply, which pure Elm
lacks. A transform:
1. traces `f` once on a *probe* placeholder, keyed by the transform kind and the key of `x`;
2. keys the real placeholder by (transform kind, key of `x`, key of the probe trace's result);
3. traces again.

Two nested transforms at the same point get different probe results, because the outer body
contains the inner one. This costs one extra trace per transform level. The tests include the
standard nesting cases.

**Subgraph placeholders** (§3.9) are keyed by (subgraph name, position, dtype, shape) instead, so
identical bodies deduplicate. Subgraph bodies are closed, so their placeholders cannot meet.

**Integer and mask nodes** carry no gradient. Primitives that are flat or not differentiable
(`argMax`, comparisons, `floor`, `round`, random draws) contribute nothing. `stopGradient` is the
identity with no rule.

### 3.6 Two-way signatures, and checks for hand-written codecs

`Signature.Sig a` both builds an `a` from tensors and flattens one back. One type serves graph
inputs and outputs, subgraph arguments and results, loop and branch state, and structured
gradients.
- `Sig.anyTensor` takes its shape from the value. It is allowed everywhere except graph inputs.
- `Param.sig spec` is the signature of a parameter record.

`Param.record` and `Sig.record` pair an accessor with a constructor position, and Elm cannot check
that they agree: `.bias` written where `.gain` belongs still type-checks when both have the same
type. So every record codec, and every `Sig.map`, is checked by a **round trip** when it is first
used to build a graph:
1. build from distinct placeholders;
2. flatten;
3. require the same placeholders, in order.

A mismatch is a build error naming the field position. `Param.config` values are constants of the
spec: a record whose config fields differ from the spec's (compared with `==`) is refused, rather
than silently rebuilt.

### 3.7 Witnesses

`Tensor.Axis` is generated (`scripts/gen_axis.py`, 65 values). Each holds a non-negative axis
index.

| Witness type | Meaning | Values |
|---|---|---|
| `Axis s r c` | remove or insert the axis tagged `c` | `axis{i}of{n}`, aliases `last{n}` |
| `Retag s t a c` | replace axis `i`'s tag `a` with `c` | `retag{i}of{n}`, aliases `retagLast{n}` |
| `Lift z s t` | prepend a batch axis to a rank-r shape | `liftRank{r}` |
| `Perm s t` | swap two axes | `swap{i}{j}of{n}`, composed with `andThen` |

### 3.8 Vectorisation

- `vmap` takes `Lift` witnesses for one tensor argument and result. `vmap2` takes two arguments.
- `vmapWith` takes `Batch` combinators:
  - `tensor lift` batches a tensor;
  - `keep` passes a value unbatched (Nabla's `in_axes=None`);
  - `pair` combines two.
- Batching rewrites the traced body with a per-primitive batching rule.
- Random draws inside a vmapped body are always batched, so each example gets its own values.
- A function whose batched form would need a batched parameter *record* (per-example gradients of
  a whole model) cannot be expressed. Elm has no type-level map over records. This is documented,
  not worked around.
- An unrolled `vmap` (`unstack`, apply, `stack`) is the test oracle.

### 3.9 Shared subgraphs: kept in the API, implemented last, optional

- `Transform.shared name sigA sigB f : Shared a b` traces `f` once on placeholders, when the
  `Shared` value is built. It is used through `Transform.call`.
- `Shared` is a data value, not a function. A top-level `Shared` is therefore evaluated once,
  whatever eco's eta-expansion does to functions (review, finding 14).
- Each call becomes `mo.call` of one `isSubgraph` `mo.graph`, and a chain is threaded through the
  calls. Identical bodies share one subgraph.
- The body is closed. A tensor the body reads but did not get through its signature is a build
  error; this includes seeds, so `Random.Seed` is a tensor with a `Sig`.
- A call inside a `cond` or `whileLoop` region is inlined, because MAX allows `mo.call` only
  directly in a graph.
- The vjp of a call is a call of a second subgraph that recomputes the forward pass and returns
  the cotangents.

Measured gain: about 10 s of MAX compile time on a 96-block model, plus a much smaller Elm-side
graph. Costs: closed bodies and recomputation in the backward pass. The work is therefore phase 5.
The API is fixed now so that code written earlier keeps compiling.

### 3.10 Control flow

- **`Control.cond pred sigA sigB t f a`** becomes `mo.if`.
  - Its branches are traced on placeholders for `a`.
  - Tensors the branches capture from outside are lifted into explicit operands by closure
    conversion: every non-constant node that a branch body reads but that does not depend on the
    branch's placeholders.
  - Its vjp is a `cond` over the branches' vjps, with recomputation. That gives the captured
    operands their cotangents.
- **`Control.whileLoop`** becomes `mo.while` and is forward only. Differentiating through it is a
  build error that suggests `repeat`.
- **`Control.repeat` and `Control.scan`** are unrolled while the graph is built (Nabla's scan is
  unrolled too), so they are differentiable.

### 3.11 Randomness

- **Seed.** `Random.Seed` is a `ui64 [1]` tensor, as MAX's random ops take. It is a graph input
  (`Random.sig`), or `Random.seed` converts an `i64` scalar.
- **Salting.** `Random.salt i s` computes `s * 25214903917 + (2i + 1)` in the graph, with
  ui64 wrapping (checked by the P0.4 probe; §10). Nested and distinct salts therefore differ. Additive
  salting would make layer i's second mask equal layer i+1's first.
- **Purity.** Draws are pure: the same seed and shape give the same values. Hash-consing two equal
  draws into one node is therefore correct.

### 3.12 State stays on the host

Parameters and optimizer state live in host buffers that outlive a run (review, finding 7). A GPT
of the example's size has about 3 GB of parameters, 9 GB with AdamW state, and cannot round-trip
through Elm `Bytes` every step.

- `Graph.Spec` gains a `role`:
  - **`Resident name`** inputs are host buffers.
  - An output with the same resident name **replaces** that buffer after the run.
  - **`Fed`** inputs (a batch, a rate, a seed) are sent with each run.
- Elm sends fed inputs and receives the loss. It fetches resident buffers only to save a
  checkpoint or to evaluate on the host.
- Small models are initialised in Elm (`Train.initial`, the MNIST LCG). Large ones use
  `Param.initGraph`, a graph that draws the parameters with MAX's random ops.
- `Train.initialFrom` starts from a saved block: a pretrained base or a checkpoint.

### 3.13 A package, for opacity

- **Name and build.** The package is `eco-lab/tensor` in `spikes/max/tensor/`, built with eco's
  `--local-package eco-lab/tensor=<dir>`. The solver pins a local package to 1.0.0. The author
  `eco` is avoided because eco gives packages by `elm`, `elm-explorations` and `eco` kernel
  privileges (`Compiler/Elm/Package.elm:158`).
- **Hiding.** Only public modules are exposed. Every type is defined with its constructor in
  `Tensor.Internal.Types` and re-exported as a type alias, so user code can name types but cannot
  build or open them. The review verified that importing the internal module fails.
- **Public aliases only.** Every public signature uses the public aliases, witness types included.
  The stub showed that otherwise `Tensor.Internal.Types.R2` leaks into error messages.
- **Tests** live inside the package. Tools such as elm-test-rs cannot resolve a local package
  from an application.

### 3.14 What is checked where

| Elm type checker | When the graph is built | MAX only |
|---|---|---|
| dtype and kind agreement; float-only ops on floats; no arithmetic on masks | sizes types cannot compute (reshape, factor, concat, slice, pad, stack, conv/pool outputs) | gather/scatter index ranges |
| rank, axis validity, contraction and broadcast structure; causal attention's equal lengths | sizes where two tensors meet (a tag declared twice) | memory, NaN, overflow |
| scalar losses; gradients shaped like their parameters | pending broadcast axes reaching anything but an element-wise op | |
| parameter fields' shapes match their declarations | dtype support per primitive (the probed table) | |
| inputs only from signatures; no hand-built nodes (opacity) | record codecs' round trip; `Sig.map` inverses; config constants | |
| | placeholders or inputs escaping their graph, subgraph or region; differentiating through `whileLoop` | |

## 4. The public API

Every signature below is in `spikes/max/tensor-api/src` and compiles there. In this section:
- `k` is a kind, `d` a dtype, `s t r u v` are shapes, other letters are dimension tags.
- Pipeline convention: `x |> op y` means x op y, so the subject comes last.
- Functions marked *(not a pipeline)* take their operands in reading order.

### 4.1 `Tensor`: types, dimensions, dtypes

```elm
type alias Tensor kind dtype shape ; Mask shape ; Dim tag ; Shape s ; DType kind dtype
type alias Axis s r c ; Retag s t a c ; Lift n s t ; Perm s t          -- values in Tensor.Axis
R0 ; R1 a ; R2 a b ; R3 a b c ; R4 a b c d ; R5 a b c d e ; One ; Elems
Floating ; Integral ; F16 ; BF16 ; F32 ; F64 ; I8 ; I32 ; I64 ; U8 ; U64
float16, bfloat16, float32, float64 : DType Floating _
int8, int32, int64, uint8, uint64 : DType Integral _
dim : tag -> Int -> Dim tag                 size : Dim tag -> Int
scalar : Shape R0    r1 : Dim a -> Shape (R1 a)   ..   r5
shapeOf : Tensor k d s -> List Int          dtypeName : Tensor k d s -> String
```

`One` is the tag of a real size-1 axis (`insertOne`, `dropOne`). `Elems` is the shape an
element-wise update sees (§4.11). Only rank-free operations apply to it.

### 4.2 Construction and casts

```elm
float : Float -> Tensor Floating F32 R0            int : Int -> Tensor Integral I64 R0
constant : DType k d -> Float -> Tensor k d R0
fillLike : Tensor k d R0 -> Tensor k d s -> Tensor k d s          -- fillLike rate grad
zeros, ones : DType k d -> Shape s -> Tensor k d s
full : DType k d -> Float -> Shape s -> Tensor k d s
fromList : DType k d -> Shape s -> List Float -> Tensor k d s   -- build time: length = size
zerosLike, onesLike : Tensor k d s -> Tensor k d s     fullLike : Float -> Tensor k d s -> Tensor k d s
iota : Dim n -> Tensor Integral I64 (R1 n)
arange : { start : Int, step : Int } -> Dim n -> Tensor Integral I64 (R1 n)
hannWindow : { periodic : Bool } -> DType Floating d -> Dim n -> Tensor Floating d (R1 n)
cast : DType k d -> Tensor k0 d0 s -> Tensor k d s     castLike : Tensor k d t -> Tensor k0 d0 s -> Tensor k d s
toFloat : Tensor k d s -> Tensor Floating F32 s        toInt : Tensor k d s -> Tensor Integral I64 s
```

### 4.3 Element-wise

```elm
abs, negate, sign, relu : Tensor k d s -> Tensor k d s               -- (support table: no unsigned negate)
plus, minus, times, max, min : Tensor k d s -> Tensor k d s -> Tensor k d s     -- x |> plus y
exp, log, log1p, sqrt, rsqrt, sin, cos, acos, atanh, erf, floor, round, truncate,
  sigmoid, tanh, gelu, geluTanh, silu : Tensor Floating d s -> Tensor Floating d s
dividedBy, pow : Tensor Floating d s -> Tensor Floating d s -> Tensor Floating d s
scale, shift : Float -> Tensor Floating d s -> Tensor Floating d s
isInfinite, isNaN : Tensor Floating d s -> Mask s
modBy : Tensor Integral d s -> Tensor Integral d s -> Tensor Integral d s
```

`max` and `min` are element-wise, as `Basics.max` is. The reductions are `maximum` and `minimum`,
as `List.maximum` is.

### 4.4 Comparisons and masks

```elm
equals, notEquals, greaterThan, atLeast, lessThan, atMost : Tensor k d s -> Tensor k d s -> Mask s
and, or, xor : Mask s -> Mask s -> Mask s           not : Mask s -> Mask s
select : Mask s -> Tensor k d s -> Tensor k d s -> Tensor k d s      -- select mask whenTrue whenFalse (not a pipeline)
indicator : DType k d -> Mask s -> Tensor k d s
maskBroadcast : Axis t s c -> Mask s -> Mask t
lowerTriangle : Tensor k d (R2 a a) -> Mask (R2 a a)
```

### 4.5 Linear algebra

```elm
matmul  : Tensor k d (R2 b c) -> Tensor k d (R2 a b) -> Tensor k d (R2 a c)          -- x |> matmul w
matmul3 : Tensor k d (R3 n b c) -> Tensor k d (R3 n a b) -> Tensor k d (R3 n a c)
matmul4 : Tensor k d (R4 m n b c) -> Tensor k d (R4 m n a b) -> Tensor k d (R4 m n a c)
matmul3By2 : Tensor k d (R2 b c) -> Tensor k d (R3 n a b) -> Tensor k d (R3 n a c)
vecMat : Tensor k d (R2 a b) -> Tensor k d (R1 a) -> Tensor k d (R1 b)               -- v |> vecMat m
matVec : Tensor k d (R1 b) -> Tensor k d (R2 a b) -> Tensor k d (R1 a)               -- m |> matVec v
dot : Tensor k d (R1 a) -> Tensor k d (R1 a) -> Tensor k d R0
outer : Tensor k d (R1 b) -> Tensor k d (R1 a) -> Tensor k d (R2 a b)                -- x |> outer y
```

### 4.6 Reductions (the axis is removed)

```elm
sum, maximum, minimum : Axis s r c -> Tensor k d s -> Tensor k d r
mean, logSumExp : Axis s r c -> Tensor Floating d s -> Tensor Floating d r
argMax, argMin : Axis s r c -> Tensor k d s -> Tensor Integral I64 r
cumsum : Axis s r c -> Tensor k d s -> Tensor k d s
cumsumWith : { exclusive : Bool, reverse : Bool } -> Axis s r c -> Tensor k d s -> Tensor k d s
sumAll, maximumAll, minimumAll : Tensor k d s -> Tensor k d R0
meanAll : Tensor Floating d s -> Tensor Floating d R0
minMax : Tensor k d s -> { min : Tensor k d R0, max : Tensor k d R0 }
softmax, logSoftmax : Axis s r c -> Tensor Floating d s -> Tensor Floating d s
```

Nabla's `keepdims=True` is a reduction followed by `broadcast` with the same witness. A
multi-axis reduction is a chain of reductions. A global `argmax` is `flatten` followed by
`argMax Axis.last1`.

### 4.7 Shape

```elm
reshape : Shape t -> Tensor k d s -> Tensor k d t                                    -- count checked
flatten : Dim m -> Tensor k d s -> Tensor k d (R1 m)
flattenTail3 : Dim m -> Tensor k d (R3 n a b) -> Tensor k d (R2 n m)                ; flattenTail4
factorLast2 : Dim a -> Dim b -> Tensor k d (R1 m) -> Tensor k d (R2 a b)            ; factorLast3, factorLast4
mergeLast2 : Dim m -> Tensor k d (R2 a b) -> Tensor k d (R1 m)                      ; mergeLast3, mergeLast4
transpose : Tensor k d (R2 a b) -> Tensor k d (R2 b a)
permute : Perm s t -> Tensor k d s -> Tensor k d t
broadcast : Axis t s c -> Tensor k d s -> Tensor k d t          -- pending axis (§3.4)
broadcastTo : Dim c -> Axis t s c -> Tensor k d s -> Tensor k d t
rows : Tensor k d (R1 b) -> Tensor k d (R2 a b)               columns : Tensor k d (R1 a) -> Tensor k d (R2 a b)
insertOne : Axis t s One -> Tensor k d s -> Tensor k d t      dropOne : Axis s r One -> Tensor k d s -> Tensor k d r
slice : Retag s t a c -> Int -> Dim c -> Tensor k d s -> Tensor k d t               -- start, size
sliceUpdate : Retag s t a c -> Int -> Tensor k d t -> Tensor k d s -> Tensor k d s  -- x |> sliceUpdate r start update
concat : Retag s t a c -> Dim c -> List (Tensor k d s) -> Tensor k d t
concat2 : Retag s t a c -> Retag u t b c -> Dim c -> Tensor k d s -> Tensor k d u -> Tensor k d t   -- x then y (not a pipeline)
chunks : Retag s t a c -> Dim c -> Tensor k d s -> List (Tensor k d t)              -- equal chunks
stack : Lift n s t -> Dim n -> List (Tensor k d s) -> Tensor k d t
unstack : Lift n s t -> Tensor k d t -> List (Tensor k d s)
flip : Axis s r c -> Tensor k d s -> Tensor k d s
pad : Retag s t a c -> { before : Int, after : Int, value : Float } -> Dim c -> Tensor k d s -> Tensor k d t
take : Retag s t a c -> Tensor Integral i (R1 c) -> Tensor k d s -> Tensor k d t      -- gather along one axis
rowsAt : Tensor Integral i (R1 n) -> Tensor k d (R2 v m) -> Tensor k d (R2 n m)       -- embedding lookup
pick : Tensor Integral i (R1 n) -> Tensor k d (R2 n c) -> Tensor k d (R1 n)           -- x[i, idx[i]]
put, putAdd : Retag s t a c -> Tensor Integral i (R1 c) -> Tensor k d t -> Tensor k d s -> Tensor k d s
triu, tril : Int -> Tensor k d (R2 a b) -> Tensor k d (R2 a b)
stopGradient : Tensor k d s -> Tensor k d s
```

### 4.8 `Tensor.Axis` (generated)

These are the witnesses of §3.7. Typical uses:
- `T.softmax Axis.last2`
- `T.sum Axis.axis0of3`
- `T.slice Axis.retagLast2 0 half`
- `Transform.vmap Axis.liftRank1 Axis.liftRank0 f`
- `T.permute Axis.swap12of4`

### 4.9 `Signature` and `Graph`

```elm
type alias Sig a                                   -- two-way (§3.6)
tensor : DType k d -> Shape s -> Sig (Tensor k d s)       f32, bf16, i64, u8 : Shape s -> Sig (..)
mask : Shape s -> Sig (Mask s)     anyTensor : Sig (Tensor k d s)     unit : Sig ()
pair, triple ; list : Int -> Sig a -> Sig (List a) ; record : f -> Builder r f
field : (r -> a) -> Sig a -> Builder r (a -> f) -> Builder r f ; map : (a -> b) -> (b -> a) -> Sig a -> Sig b
label : String -> Sig a -> Sig a                   -- names inputs/outputs l, or l0, l1 ..

Graph.build : String -> Sig a -> Sig b -> (a -> b) -> Result (List String) Graph
Graph.function : String -> Sig a -> (a -> Tensor k d s) -> Result (List String) Graph   -- one output, "result"
Graph.name : Graph -> String ; inputs, outputs : Graph -> List Spec
type alias Spec = { name : String, dtype : String, shape : List Int, role : Role }
type Role = Fed | Resident String
Graph.toBytecode : Graph -> Bytes ; Graph.toGenericText : Graph -> String
```

### 4.10 `Transform`, `Tensor.Control`, `Tensor.Random`

```elm
grad : (Tensor Floating d s -> Tensor Floating d R0) -> Tensor Floating d s -> Tensor Floating d s
valueAndGrad : .. -> ( Tensor Floating d R0, Tensor Floating d s )
gradOf : Sig a -> (a -> Tensor Floating d R0) -> a -> a                 ; valueAndGradOf
vjp : Sig a -> Sig b -> (a -> b) -> a -> ( b, b -> a )
jvp : Sig a -> Sig b -> (a -> b) -> a -> a -> ( b, b )
jacobian : (Tensor Floating d (R1 a) -> Tensor Floating d (R1 b)) -> Tensor Floating d (R1 a) -> Tensor Floating d (R2 b a)
hessianVector : (Tensor Floating d s -> Tensor Floating d R0) -> Tensor Floating d s -> Tensor Floating d s -> Tensor Floating d s
vmap : Lift n s t -> Lift n u v -> (Tensor k d s -> Tensor k2 d2 u) -> Tensor k d t -> Tensor k2 d2 v ; vmap2
type Batch a b ; tensor : Lift n s t -> Batch (Tensor k d s) (Tensor k d t) ; keep : Batch a a ; pair
vmapWith : Batch a ba -> Batch b bb -> (a -> b) -> ba -> bb
type Shared a b ; shared : String -> Sig a -> Sig b -> (a -> b) -> Shared a b ; call : Shared a b -> a -> b

Control.cond : Mask R0 -> Sig a -> Sig b -> (a -> b) -> (a -> b) -> a -> b
Control.whileLoop : Sig s -> (s -> Mask R0) -> (s -> s) -> s -> s           -- forward only
Control.repeat : Int -> Sig s -> (s -> s) -> s -> s                          -- unrolled
Control.scan : Lift n x xs -> Lift n y ys -> (c -> Tensor k d x -> ( c, Tensor k2 d2 y )) -> c -> Tensor k d xs -> ( c, Tensor k2 d2 ys )

Random.Seed ; seed : Tensor Integral I64 R0 -> Seed ; salt : Int -> Seed -> Seed ; sig : Sig Seed
uniform : { low : Float, high : Float } -> DType Floating d -> Shape s -> Seed -> Tensor Floating d s ; normal { mean, std }
uniformLike, normalLike : {..} -> Tensor Floating d s -> Seed -> Tensor Floating d s
bernoulliLike : Float -> Tensor k d s -> Seed -> Mask s
```

### 4.11 `Param`, `Optim`, `Train`

```elm
Param.Spec r = Builder r r ; record : f -> Builder r f
heUniform, heNormal, xavierUniform, xavierNormal, zeros, ones ; normal : Float -> ..
   : (r -> Tensor Floating d s) -> DType Floating d -> Shape s -> Builder r (Tensor Floating d s -> f) -> Builder r f
data : (r -> Tensor k d s) -> DType k d -> Shape s -> Builder r (Tensor k d s -> f) -> Builder r f   -- loaded, never trained
sub : (r -> p) -> Spec p -> Builder r (p -> f) -> Builder r f ; list : Int -> Spec p -> Spec (List p)
config : (r -> c) -> c -> Builder r (c -> f) -> Builder r f ; frozen : Spec p -> Spec p
sig : Spec r -> Sig r ; initial : Spec r -> Int -> Bytes ; initGraph : String -> Spec r -> Result (List String) Graph
mapElems : (Tensor Floating F32 Elems -> Tensor Floating F32 Elems) -> Spec r -> r -> r
count, byteSize : Spec r -> Int ; grad : Spec r -> (r -> Tensor Floating d R0) -> r -> r

Optim.Optimizer ; Rate = Fixed Float | PerStep
sgd : Float -> Optimizer ; sgdWith { rate, momentum, weightDecay }
adamW : Float -> Optimizer ; adamWWith { rate, beta1, beta2, epsilon, weightDecay, biasCorrection }
custom : { rate, slots : Int, update : Hyper -> { param, grad, state } -> { param, state } } -> Optimizer   -- over Elems
clipGlobalNorm : Float -> Optimizer -> Optimizer ; type alias Hyper = { rate, step : Tensor Floating F32 R0 }

Train.step : Param.Spec r -> Optimizer -> Sig batch -> (r -> batch -> Tensor Floating F32 R0) -> Result (List String) Graph
Train.measure : Param.Spec r -> Sig batch -> (r -> batch -> Tensor k d R0) -> Result (List String) Graph
Train.initial : Param.Spec r -> Optimizer -> Int -> List ( String, Bytes )        -- resident buffers' contents
Train.initialFrom : Param.Spec r -> Optimizer -> Bytes -> List ( String, Bytes )
Train.loss : Bytes -> Float ; Train.measured : Bytes -> Float
```

`Elems` makes one update function serve every parameter. Elm cannot pass a function polymorphic in
the shape, so the library applies the update to each parameter retyped to `Elems`. On `Elems`, only
rank-free operations exist: element-wise ones, `sumAll`, `maximumAll`. That is exactly what
optimizers and clipping need, so the retyping is sound.

### 4.12 `Nn` and layers

```elm
Nn.crossEntropy : Tensor Floating d (R2 n c) -> Tensor Floating d (R2 n c) -> Tensor Floating d R0   -- one-hot, mean
Nn.crossEntropyIndices : Tensor Integral i (R1 n) -> Tensor Floating d (R2 n c) -> Tensor Floating d R0
Nn.mseLoss : Tensor Floating d s -> Tensor Floating d s -> Tensor Floating d R0
Nn.dropout : { rate : Float, training : Bool } -> Seed -> Tensor Floating d s -> Tensor Floating d s
Nn.attention : { mask : Maybe (Mask (R2 s t)), bias : Maybe (Tensor Floating d (R2 s t)) }
    -> Tensor Floating d (R3 h t j) -> Tensor Floating d (R3 h t e) -> Tensor Floating d (R3 h s j) -> Tensor Floating d (R3 h s e)
Nn.causalAttention : Tensor Floating d (R3 h s j) -> Tensor Floating d (R3 h s e) -> Tensor Floating d (R3 h s j) -> Tensor Floating d (R3 h s e)
Nn.maxPool2d, Nn.avgPool2d : Int -> Dim h2 -> Dim w2 -> Tensor Floating d (R4 n h w c) -> Tensor Floating d (R4 n h2 w2 c)
```

Layer modules each have a record type, `params`, and `apply`:
- `Nn.Linear`: `Linear d i o`, `apply`, `apply3`.
- `Nn.LayerNorm`: `apply`, `apply3`.
- `Nn.Embedding`.
- `Nn.Attention`: `Attention d m h j`, with `self { causal }` and `cross`.
- `Nn.Transformer`: `EncoderLayer d m h j f` and `DecoderLayer` (pre-norm), `encode` and
  `decode`.
- `Nn.Conv2d`: `Conv2d d c o` with library-owned kernel tags, `apply { stride, padding }`,
  `applySame`, `applyTransposed`.
- `Nn.Stack`: `Seq i o`, `Width`, `dense n act`, `denseTo dim act`. Hidden widths are anonymous.

### 4.13 `Finetune`, `Tensor.Check`

- `Finetune.Lora`: `Lora d i r o`, `params`, `delta`, `apply`, `merge`, `unmerge`.
- `Finetune.Qlora`: `Quantized d i o` (codes are `Param.data`), `blocks`, `params`, `quantize`
  (host side), `dequantize`, `apply`.
- `Tensor.Check.allClose`.

### 4.14 Coverage of Appendix A

| Nabla | Elm |
|---|---|
| `Tensor` math, unary, activations | §4.3 (same names; `trunc` → `truncate`, `is_inf` → `isInfinite`, `logsoftmax` → `logSoftmax`) |
| reductions, `cumsum`, `argmax/argmin`, `minmax` | §4.6; `keepdims` and multi-axis as in §4.6's note |
| `reshape`, `view`, `flatten`, `squeeze`, `unsqueeze`, `permute`, `transpose`, `swap_axes`, `moveaxis`, `broadcast_to`, `expand` | `reshape`, `flatten*`, `factor*`/`merge*`, `dropOne`/`insertOne`, `permute` with `swap…` witnesses, `transpose`, `broadcast`/`broadcastTo` |
| `concatenate`, `stack`, `split`/`chunk`, `unbind`, `gather`, `scatter`, `slice_tensor`, `slice_update`, `flip`, `pad` | `concat`/`concat2`, `stack`, `chunks` (equal only), `unstack`, `take`/`rowsAt`/`pick`, `put`/`putAdd`, `slice`, `sliceUpdate`, `flip`, `pad` (one axis at a time) |
| creation (`zeros` .. `full_like`, `arange`, `triu/tril`, `hann_window`, `uniform`, `normal`) | §4.2, §4.10 Random |
| binary, comparison, logical, `where` | §4.3, §4.4 |
| `matmul` (batched, 1-D promotion), `outer` | §4.5 by rank |
| `cast`, `type_as` | `cast`, `castLike` |
| `conv2d`, `conv2d_transpose`, `avg/max_pool2d` | `Nn.Conv2d`, `Nn.maxPool2d`/`avgPool2d` (window = stride) |
| `grad`, `value_and_grad`, `vjp`, `jvp`, `jacrev`/`jacfwd`, `vmap` | §4.10 (`jacobian` for R1 → R1; `vmap` by `Lift`/`Batch`) |
| `cond`, `while_loop`, `scan` | `Control.*` |
| `compile`, `CompiledFunction`, `CompilationStats` | not needed: every graph is compiled ahead of time; MAX caches by bytes |
| pytrees | `Sig`, `Param` (typed) |
| `nn.Module`, `Linear`, `LayerNorm`, `Dropout`, `Embedding`, `MultiHeadAttention`, `Transformer*Layer`, `Sequential`, activations | §4.12 (`Sequential` = `Nn.Stack` or a pipeline; activation modules = functions) |
| `nn.functional`, losses, `xavier_normal`, `he_normal` | §4.12, `Param` inits |
| `SGD`, `AdamW`, `sgd_step` … `adamw_update` | `Optim` |
| LoRA, QLoRA, checkpoints | `Finetune.*`; checkpoints are resident buffers saved by the host (§3.12) |
| `assert_allclose`, `batch_realize` | `Tensor.Check.allClose`; `batch_realize` n/a |
| `call_custom_kernel` | not ported (§4.15) |

### 4.15 Not ported

- **Multi-device work:** sharding, device meshes, collectives, device placement, `shard_map`.
- **Eager-only APIs:** `realize`, `item`, `numpy`, `backward()`, `.grad`, `requires_grad_`.
- **Pytree registration.**
- **Data types:** complex dtypes.
- **Shape and index variants:** symbolic dimensions (a later plan), uneven `chunk`, gathers with
  multi-dimensional indices beyond `rowsAt`.
- **Convolution options:** `conv2d` dilation and groups. Nabla supports only (1, 1) and 1 itself.
- **Mojo custom kernels.**
- **Per-example gradients of whole parameter records** (§3.8).

## 5. Internal architecture

### 5.1 Layout

```
spikes/max/tensor/                    Elm package eco-lab/tensor 1.0.0 (deps: elm/core, elm/bytes)
  src/<public modules>                from spikes/max/tensor-api/src, bodies filled in
  src/Tensor/Internal/Types.elm       every public type with its constructor
  src/Tensor/Internal/Key.elm         keys and mixing (from mnist Tensor.elm), float constants by bits
  src/Tensor/Internal/Expr.elm        Node, Op, Prim application, Meta, problems
  src/Tensor/Internal/Prim.elm        the Prim enum: tag, public name, family, element-wise?
  src/Tensor/Internal/Shape.elm       shape and dtype rule per Prim
  src/Tensor/Internal/Support.elm     dtype support table per Prim (generated from the probe)
  src/Tensor/Internal/Vjp.elm         vjp rule per Prim
  src/Tensor/Internal/Trace.elm       placeholders (probe-salted keys), substitution, closure conversion
  src/Tensor/Internal/Grad.elm        reverse mode, un-broadcasting, jvp by double vjp
  src/Tensor/Internal/Batch.elm       batching rules (P4)
  src/Tensor/Internal/Lower.elm       expressions → MlirBc ops: regions, subgraphs, chains
  src/Tensor/Internal/Mo.elm          op spellings (spikes/max/mo-inventory.md)
  src/Tensor/Internal/MlirBc.elm      moved from mnist/src; extended (§5.6)
  src/Tensor/Internal/Host.elm        byte layouts (packed, paddedSize), f32/bf16/f16/f64 encoders
  src/Tensor/Internal/Init.elm        LCG, He/Xavier uniform and normal (Box–Muller)
  tests/                              elm-test-rs suites (inside the package, §3.13)
  scripts/gen_axis.py, scripts/gen_support.py
spikes/max/tensor-api/                examples/ and bad/ (must and must not compile); after P0.1 its src/ lives
                                      in the package and its elm.json depends on the package (`make check-api`)
spikes/max/opcheck/                   Elm app + host run + ref.py (NumPy oracle), §7
spikes/max/mnist/                     the MNIST app, depending on eco-lab/tensor
spikes/max/models/<name>/             one app per phase model (P2–P5)
```

`Makefile`'s `elm_so` macro passes `--local-package eco-lab/tensor=$(CURDIR)/tensor`. Each app's
`elm.json` lists `"eco-lab/tensor": "1.0.0"` as a direct dependency.

### 5.2 Expressions

```elm
type Expr = Expr Node
type alias Node =
    { key : Key                -- ( Int, Int ), as today
    , op : Op
    , meta : Meta
    }
type alias Meta =
    { shape : List Int         -- logical sizes; 1 at a pending axis
    , pending : List Int       -- axes whose size is not yet known (§3.4)
    , dtype : DType            -- internal enum: F16 | BF16 | F32 | F64 | SI8 | SI32 | SI64 | UI8 | UI64 | Bool
    , problem : Maybe String   -- the first error made here (operands' problems are not copied)
    }
type Op
    = Input { graph : String, position : Int, label : String }
    | Var { key : Key, position : Int }               -- a placeholder (§3.5)
    | Const ConstData                                  -- scalar or row-major list, hashed by bit pattern
    | Prim Prim (List Expr) Params                     -- one primitive applied
    | Call Subgraph (List Expr)                        -- P5
    | If { pred : Expr, branches : ( Body, Body ), operands : List Expr }    -- P4
    | While { cond : Body, body : Body, init : List Expr }                  -- P4
    | Proj Expr Int                                    -- result i of Call/If/While
type alias Params = { ints : List Int, floats : List Float, dtype : Maybe DType }
```

- **Smart constructor.** `Expr.prim : Prim -> List Expr -> Params -> Expr` computes the key with
  `mix (primTag p)` over the params and the operands' keys. It computes the meta with
  `Shape.rule`. A rule failure becomes `problem = Just "<public name>: <message>"`; the meta is
  then a best guess, so building can go on and report every error.
- **Constants** hash their values through `Bytes` (f64 bits). That keeps `-0.0` and `0.0` apart and
  lets NaN equal itself.
- **Public operations** are thin. `T.plus y x = wrap (Expr.prim Add [ unwrap x, unwrap y ] none)`.
  Operations with no MAX primitive are compositions in Elm:
  - `lessThan` is `greaterThan` with the operands swapped (IEEE semantics; MAX's Python uses
    `not (x >= y)`, which is true for NaN);
  - `atMost` is `atLeast` swapped;
  - `outer`, `stack`, `chunks`, `sign`, `logSumExp`, `minMax`;
  - `hannWindow`, `lowerTriangle`, `fillLike`.
- **`Prim` families** (each one lowers to one `mo`/`rmo` op, or to a fixed few):
  - element-wise unary and binary;
  - `Cast`;
  - `Reduce kind` (keeps the axis) plus `DropAxis` (reshape);
  - `Softmax` / `LogSoftmax`;
  - `CumSum`;
  - `MatMul`;
  - `Reshape`, `Transpose perm`, `BroadcastTo`;
  - `Slice`, `Concat`, `Pad`;
  - `Gather`, `Scatter`, `ScatterNdAdd`;
  - `BandPart`, `Select`, `Range`;
  - `Random uniform|normal`;
  - `LayerNorm` (a custom-vjp composite), `XentLogits` (custom vjp);
  - `Conv`, `ConvTranspose`, `MaxPool`, `AvgPool`;
  - `StopGradient`, `Acos` (`mo.custom`).

### 5.3 Rules

One module per concern. Each is a total `case` over `Prim`, so the compiler lists a missing case.
- **`Shape.rule : Prim -> List Meta -> Params -> Result String Meta`** gives the result shape and
  dtype:
  - element-wise operands must have equal sizes except at pending axes, which resolve;
  - a real 1 against N is an error;
  - pending axes into non-element-wise primitives are an error.
- **`Support.allowed : Prim -> DType -> Bool`** is generated from the probe (§6, P0.4).
- **`Vjp.rule : Prim -> { operands : List Expr, out : Expr, cotangent : Expr, params : Params } -> List (Maybe Expr)`**
  is written with the `Expr`-level builders. `Nothing` means no gradient to that operand.
- **`Batch.rule`** (P4) takes `Prim`, operands each with a batched flag (batch axis 0), and params,
  and gives a batched expression.

### 5.4 Gradients (`Grad.elm`)

Reverse mode for `gradWrt : Expr -> List Expr -> List Expr` (loss, placeholders):
1. **Order.** An iterative post-order DFS from the loss (an explicit stack, not recursion, so a
   10⁵-node graph cannot overflow), with a visited set keyed by `Key`.
2. **Active nodes.** In post-order, a node is active if it is one of the placeholders, or if an
   operand is active and the node's dtype is floating.
3. **Cotangents.** The cotangent of the loss is `ones`. In reverse post-order, for each active
   node that has a cotangent:
   - apply `Vjp.rule`;
   - un-broadcast each operand's cotangent to that operand's meta. Sum over the operand's pending
     axes (the reduction keeps the axis, so the shapes match as they are). A rank-0 operand that
     met a higher rank is summed fully, then reshaped to `[]`.
   - accumulate with `plus` in a `Dict Key Expr`.
4. **Results.** Each placeholder's cotangent, or `zerosLike` it.

`Transform.grad f x`:
1. Trace `f` on a probe placeholder, then make the real placeholder `v` (§3.5).
2. Compute `g = gradWrt (f v) [v]`.
3. Substitute `x` for `v` in `g`. `Trace.substitute` is an iterative post-order rebuild that
   re-keys and re-checks every node depending on `v`, memoised by key.

`jvp f x t` is the transpose trick:
1. Trace `f` on `v`, giving `y`.
2. Take a second placeholder `u` shaped like `y`. Let `g u = vjp (f, v)(u)`, which is linear in
   `u`.
3. `jvp = vjp of g at u, applied to t`.

The result needs no jvp rules, at the cost of one extra backward pass.

### 5.5 Lowering (`Lower.elm`)

**State:**

```elm
{ regions : List RegionState      -- a stack; the top is where ops go
, subgraphs : Dict Key LoweredSub
, chain : Maybe Value
, errors : List String
}
```

Each `RegionState` has its ops, its next value number, and a memo `Dict Key Value`.

**Walking the graph.** An iterative post-order walk from the outputs:
- A node found in any enclosing region's memo is reused. Captures are allowed in `mo.if` and
  `mo.while`, but not across a subgraph boundary.
- On a memo hit, the shallow structure (prim tag, params and operand keys) is compared with the
  stored one. A mismatch is reported as an internal key collision.

**What each node becomes:**
- `Input` must belong to this graph.
- `Var` must be bound by an enclosing region. Otherwise the error is "reads a tensor that is not
  an argument".
- `Prim` goes through `Mo.emit`:

  ```elm
  Mo.emit : Prim -> List Value -> Params -> Meta -> List Value -> List MlirBc.Op
  ```

  It gives the op or ops from the inventory, for example:
  - `Reduce` is the reduction followed by an `rmo.reshape` that drops the axis;
  - `Transpose` is a permutation `mo.constant` followed by `rmo.mo.transpose`;
  - `Conv` is `rmo.rebind_tensor_shape` to RSCF followed by `rmo.conv`;
  - `Random` is `rmo.shape_to_tensor`, two constants, and the random op.
- `If` opens two regions. Its operands are captured from outside. Calls inside are inlined (§3.9).
- `While` opens two regions with block arguments.
- `Call` lowers its subgraph once per key into a separate `mo.graph` and emits `mo.call` with the
  chain.

**Chains.** A chain is created on first use with `mo.chain.create` and threaded in emission order.

**Axes.** Every axis is written non-negative. `index` attributes are used where the inventory has
them, operands where it has those.

### 5.6 `MlirBc` changes

- **New attributes:** `UnitAttr` (`isSubgraph`) and `SymbolRefAttr String` (`callee = @name`), in
  the builtin binary encoding (`BuiltinDialectBytecode.td`).
- **Non-isolated regions.** `Region` gains `isolated : Bool`. Inside a non-isolated region, value
  numbering continues from the enclosing region and operands may refer to outer values. The
  bytecode encodes such regions inline with the parent's value scope, per
  `mlir/docs/BytecodeFormat.md`; `printGeneric` does the same. Today the module assumes every
  region is isolated (its header says so).
- **Printer speed.** `printGeneric` keeps its scope in an `Array` and builds lines with
  `List.concat` once. Today it uses `List.drop` lookups and `++`, which is O(n²).
- **Tests.** Each change gets a byte-for-byte test against bytecode MLIR itself writes for the
  same IR:

  ```sh
  /opt/llvm-mlir/bin/mlir-opt --allow-unregistered-dialect --emit-bytecode
  ```

  The comparison uses the same pinned LLVM.

### 5.7 Host protocol (P2)

`max_bridge.cpp` keeps a table of resident buffers by name.
- **Compile.** The compile message's spec lines become `name:dtype:shape:role`, where role is `f`
  (fed) or `r=<resident name>`.
- **Run.** The run message carries only the fed inputs. The host binds resident inputs from its
  table. After the run it moves each output with a resident role into the table, replacing the old
  buffer, and returns the other outputs.
- **New messages:**
  - `put name bytes` sets a resident buffer (initial values, a checkpoint);
  - `get name` returns one;
  - `save name file` and `loadInto name file` move one to or from disk.
- **Dtypes.** The table of dtypes grows to `f16 bf16 f32 f64 si8 si32 si64 ui8 ui64 bool`, the
  MAX C API's `M_FLOAT16` …, with their element sizes.

## 6. Phases, step by step

Each phase ends with its acceptance checks green. The plan's front matter then moves to `partial`,
with the phases still open in `remaining`.

### P0. Core, MNIST, harness

The phase is done when MNIST trains on the package with the new gradient engine, the op-check
harness runs, and the design of placeholders, pending axes and regions is in code.

1. **Package skeleton.**
   - Create `spikes/max/tensor/elm.json`: type `package`, name `eco-lab/tensor`, version 1.0.0,
     the exposed modules of §4, deps `elm/core` and `elm/bytes`.
   - Copy `tensor-api/src`.
   - Move `MlirBc.elm` to `Tensor/Internal/MlirBc.elm`.
   - Add the `--local-package` flag to `elm_so`.
   - Point `mnist/elm.json` at the package.
   - Check: `make` builds `mnist.so` with the stub package. It links but does not run yet.
   - Add `make check-api`, which compiles `tensor-api/examples/All.elm` against the package's
     public modules and refuses any `bad/*.elm` that compiles. For this, `tensor-api/elm.json`
     depends on the package instead of carrying `src/`.
2. **Keys and expressions** (§5.2).
   - Write `Key.elm` from `mnist/src/Tensor.elm`'s `mix…` functions, plus `mixFloat` by bits.
   - Write `Expr.elm`, with the `Prim` subset MNIST needs: Cast, Add, Sub, Mul, Neg, Relu, MatMul,
     Reduce add/mean/argMax, DropAxis, Softmax, LogSoftmax, Reshape, Transpose, Range, Equal,
     Greater, Select, XentLogits.
   - Write their `Shape` rules, with pending axes per §3.4, and `Support` entries for f32, ui8,
     si64 and bool.
   - Write `Mo.emit` for each, spelled as `mnist/src/Graph.elm` spells them today.
3. **`Sig` and `Graph.build`.**
   1. Collect the slots of the input `Sig`. A slot without a shape is an error.
   2. Name them by their labels, numbered when a label repeats.
   3. Make the `Input` nodes, keyed with the graph name and the position.
   4. Run the body.
   5. Flatten the outputs.
   6. Collect problems in an iterative walk, deduplicated by key: `meta.problem`, pending axes at
      outputs, foreign inputs and placeholders, and the round-trip failures of §3.6.
   7. Lower (§5.5).
   8. Make the specs. Every role is `Fed` until P2.
4. **Probes, kept in `capi/scripts/inventory/`.**
   - `support_probe.py` compiles every primitive of §5.2 × every dtype of §4.1 on MAX. Primitives
     are batched into one graph per dtype, then bisected when that fails.
   - It writes `support.json`, and `gen_support.py` turns that into `Support.elm`.
   - It also checks `rmo.mod`'s sign convention against Elm's `modBy` and ui64 wrapping in
     `rmo.mul` and `rmo.add`. Record both results in the inventory.
5. **The gradient engine** (§5.4).
   - Vjp rules for the P0 primitives. `XentLogits` gets the rule `(softmax − onehot) / n`, as
     `Graph.softmaxXentLoss` has today.
   - `Trace.elm`: placeholders, probe salting, substitution.
   - `Transform.grad`, `gradOf`, `valueAndGrad`; `Param.grad`.
   - Unit tests, in elm-test on expression structure:
     - (a) `grad (\y -> y |> times x) x` is `x`, not `2x`, checked by evaluating both on MAX in
       the harness;
     - (b) the Siskind–Pearlmutter case: the derivative at x = 1 of `x * d/dy (x + y)` is 1;
     - (c) `hessianVector f x (grad f x)` against the analytic value for a quadratic f.
6. **Witnesses.** Run `scripts/gen_axis.py` and check the output into the package. An elm-test
   checks each witness's index against its name.
7. **`Param`, `Train` and `Optim.sgd`, as today but on the new core.**
   - `Param.initial` must produce the same bytes as `mnist/src/Param.elm` for the MNIST spec, with
     the same LCG and draw order. A golden test compares them.
   - `Train.step` keeps today's protocol (Elm round-trips the block) until P2.
   - Rename the MNIST output names to the new labels.
8. **Port MNIST.**
   - Write `MnistNet.elm` in the typed API (the stub's example, with SGD 0.1).
   - Make `Mnist.elm` use `Graph.toBytecode` and `Graph.toGenericText`.
   - Retire `FORMAT=text`. The custom-syntax printer is not ported; update `README.md` and the
     Makefile.
   - Delete `mnist/src/{Tensor,Graph,Param,Train,MlirBc}.elm`.
   - Acceptance:
     - `make run-mnist` with both formats gives accuracies within 0.05 points of 14.78, 92.52,
       94.31, 95.24, 95.60, 95.87%;
     - the mean losses are within 1e-4 of `make run-mnist-ref`;
     - the first 100 step losses are within 1e-5 of a trace recorded from the current code
       before the port (`work/mnist-trace-before.txt`, recorded in step 0);
     - `make check-bytecode` passes.
9. **Op-check harness** (§7). Build `spikes/max/opcheck` for the P0 primitives and run
   `make check-ops`.
10. **Package tests** (`tests/`, run with elm-test-rs from `build-llvm-git/toolchain/bin`):
    - shape-rule acceptance and refusal, with the error texts golden;
    - key determinism and sensitivity;
    - `Sig` round trip;
    - `Param` layout;
    - witness indices;
    - placeholder nesting.

    Add `make check-tensor`, which runs these and `check-api`.

Step 0, before everything else: record the current MNIST step losses (add a log line) into
`work/mnist-trace-before.txt`.

### P1. Operations

The phase is done when every operation of §4.2–4.7 exists, with shape, support, lowering and vjp,
checked by `check-ops`.

1. Add the remaining primitives family by family, in this order:
   - (a) element-wise unary and binary, comparisons, masks;
   - (b) reductions, `cumsum`, `logSumExp`, `minMax`;
   - (c) shape: reshape, flatten, factor/merge, permute, broadcast/broadcastTo, insert/dropOne,
     slice, sliceUpdate, concat, concat2, chunks, stack/unstack, flip, pad;
   - (d) `take`/`rowsAt`/`pick`. Their vjp is `putAdd`, through `rmo.mo.scatter_nd.add`.
     `put`/`putAdd` themselves (`putAdd`'s vjp is a `take`);
   - (e) `band_part` (`triu`, `tril`, `lowerTriangle`), `select`, `iota`/`arange`,
     `hannWindow`, constants, `fromList`;
   - (f) linear algebra by rank.

   For each primitive:
   - a `Prim` constructor;
   - a `Shape` rule;
   - its `Support` row, from the probe;
   - `Mo.emit`, spelled per the inventory;
   - a `Vjp` rule;
   - an op-check case, for values and gradients;
   - an elm-test for refusals.
2. Record each composition in the module docs: `lessThan`, `sign`, `outer`, `stack`, `chunks`,
   `hannWindow`, `fillLike`. Compositions need no primitive and no rule.
3. Acceptance:
   - `make check-ops` passes for every family, at most one MAX compile per family (`check-ops`
     builds one graph per family);
   - `make check-tensor` passes;
   - MNIST is unchanged.

### P2. Training at scale: state on the host, optimizers, layers, randomness

The phase is done when MNIST trains with AdamW from host-resident state, and an MLP stack and
dropout work.

1. **Host protocol** (§5.7).
   - `max_bridge.cpp` gets resident buffers, roles, `put`/`get`/`save`/`loadInto`, and the dtype
     table.
   - `Bridge.elm` gets the matching messages.
   - `Graph.Spec.role` is filled by `Train.step`:
     - parameters, frozen and data tensors, and optimizer state are `Resident`;
     - rate, batch and seed are `Fed`;
     - `next…` outputs replace their buffers.
2. **`Param`.**
   - `data`, `frozen`, `config` (with the §3.6 checks), `list`, `sub`;
   - inits: He/Xavier uniform and normal, where fan-in is the product of all but the last
     dimension and fan-out is the last dimension; normals use Box–Muller on the LCG;
   - `initial` for every dtype: bf16 rounds f32 to nearest-even on its upper 16 bits, and f16 is
     converted in Elm;
   - `initGraph`, using MAX random ops;
   - `mapElems`.
3. **`Optim`.**
   - State layout: per trainable parameter, in spec order, its slots, which have the parameter's
     shape and dtype. Then one `f32 []` step counter.
   - SGD with momentum and weight decay.
   - AdamW with decoupled weight decay and optional bias correction. The bias-correction terms
     β^t are computed in the graph as `exp (t * log β)`.
   - `PerStep` adds a fed `rate : f32 []` input.
   - `custom`: updates over `Elems`. `clipGlobalNorm` uses `sumAll` of the squares over all
     gradients.
4. **`Train`.**
   - `step`, `measure`, `initial` and `initialFrom` give resident contents by name.
   - `loss` and `measured`.
   - Frozen and data tensors are inputs but not outputs.
5. **`Nn`.**
   - Losses: `crossEntropyIndices` uses `pick` on `logSoftmax`, with the custom vjp of
     `XentLogits`.
   - `dropout`.
   - `Nn.Linear`, `Nn.LayerNorm` (`mo.reduce.layer_norm` with a custom vjp, `apply3`),
     `Nn.Embedding`, `Nn.Stack`.
6. **`Tensor.Random`.**
   - The seed is `ui64 [1]`.
   - `salt` per §3.11.
   - `uniform`/`normal` and their `Like` forms; `bernoulliLike`.
7. **Models** (`spikes/max/models/mnist-adamw`, `mlp-stack`):
   - MNIST with AdamW 1e-3, five epochs, from resident state: test accuracy ≥ 97.0%, and no
     parameter bytes cross the Elm boundary after `put`.
   - A 784-512-256-10 `Nn.Stack` with dropout 0.1: ≥ 97.5%.
   - A checkpoint written by `save` and read back by `loadInto` must give the same test accuracy.

### P3. Transforms and attention

The phase is done when higher-order autodiff works and a small transformer trains.

1. `vjp`, `jvp` (double vjp), `valueAndGradOf`, `hessianVector`, `jacobian`, implemented through
   unrolled `vmap` until P4.
2. `Nn.attention` and `causalAttention`; `Nn.Attention`, `Nn.Transformer` (pre-norm encoder and
   decoder).
3. `Nn.crossEntropy`, `mseLoss`, `logSumExp` stability (subtract the maximum).
4. Model (`spikes/max/models/charlm`): a character language model.
   - Configuration: 2 layers, model width 64, 4 heads, sequence length 64, AdamW. It trains on
     the concatenated `design_docs/theory/**/*.md` (in the repo, no download).
   - Acceptance: the validation loss falls below the unigram entropy of the corpus. Also, op-check
     cases for the attention block's gradients and for `hessianVector` on a quadratic pass.

### P4. Control flow, vectorisation, convolution

1. **`MlirBc`.** Non-isolated regions (§5.6), with byte-identical tests against `mlir-opt`.
2. **`Control.cond`.**
   - Closure conversion (§3.10), `mo.if` lowering.
   - Its vjp is `cond` over the branch vjps.
   - Op-check: values and gradients against the unconditional versions.
3. **`Control.whileLoop`** (`mo.while`, forward only), **`repeat`** and **`scan`** (unrolled).
4. **`vmap`, `vmap2`, `vmapWith`.**
   - Batching rules for every primitive, with random draws always batched.
   - Every rule is tested against the unrolled oracle in op-check.
   - `jacobian` moves onto `vmap`.
5. **Convolution.**
   - `Nn.Conv2d.apply` and `applySame` (`rmo.conv`) and `applyTransposed` (`rmo.conv_transpose`;
     the bias is added separately, because MAX's NHWC bias path is broken).
   - The vjps:
     - with respect to the input, `conv_transpose`;
     - with respect to the filter, a convolution of the permuted input with the permuted
       cotangent (stride becomes dilation). A probe first checks that MAX compiles dilated
       convolutions. If it does not, fall back to `take`-based im2col and `matmul`.
   - Pooling with window = stride, and its vjp through an internal rank-6 reshape:
     - max: a mask of the maxima, split evenly between ties;
     - average: a broadcast.
6. **Model** (`spikes/max/models/cnn`): MNIST, conv32–pool–conv64–pool–dense, AdamW, two epochs.
   Acceptance: ≥ 98.5%.

### P5. Shared subgraphs, fine-tuning, closing

1. **`MlirBc`.** `UnitAttr`, `SymbolRefAttr`, and modules with several `mo.graph`s.
2. **`Transform.shared` and `call`.**
   - Tracing, `Call` nodes, lowering into `isSubgraph` graphs with chains.
   - Inlining inside regions.
   - The vjp subgraph, by recomputation.
3. **Model and benchmark.** `charlm` at 8 layers, with shared blocks against inlined blocks:
   - the same losses within 1e-5;
   - record MAX compile time, Elm build time and bytecode size.

   Also build a GPT of the example's size (96 × 768). Only build it; do not run it. Record the
   Elm build time and graph size.
4. **`Finetune.Lora`.**
   - Fine-tune the P2 MNIST network, loaded by `initialFrom`, with LoRA rank 8 on the first layer.
   - Acceptance: the frozen buffers are byte-identical after training, and accuracy does not drop.
5. **`Finetune.Qlora`.**
   - NF4 codebook from Dettmers et al. (2023), §3: 16 values.
   - Host-side `quantize`.
   - `dequantize` through `take` on the codebook and a per-block scale.
   - Acceptance: matches a NumPy NF4 reference to 1e-6.
6. **`Tensor.Check.allClose`.** Package documentation for every public module (examples from
   `tensor-api/examples`). Close the catalogue: every Appendix A row is either in §4.14 or listed
   in §4.15.

## 7. Validation

- **Package tests** (elm-test-rs, inside the package): build-time behaviour, error texts,
  structure, layouts.
- **Op-check** (`spikes/max/opcheck`, `make check-ops`):
  1. An Elm app builds **one graph per family**, with many outputs. Compile cost is fixed per
     graph, about 20 s cold and 0 s warm, so batching keeps a full run under 15 minutes cold.
     There are about 10 families.
  2. Inputs come from the LCG in fixed small shapes. For each case the graph outputs the forward
     value and, for differentiable primitives, the gradient of `sumAll (op x |> times w)` for a
     fixed random `w`.
  3. The app writes a manifest (case, op, params, input and output names) and the host saves
     every buffer.
  4. `opcheck/ref.py` (venv NumPy; erf through `math.erf`) computes the forward in f64, and the
     gradient by central differences on that NumPy forward. Finite differences never run on MAX.
  5. It compares with tolerances: forward rtol 1e-4, atol 1e-5; gradient rtol 1e-3, atol 1e-4 in
     f32. Per-family overrides are documented.
- **Batching and transforms**: `vmap` against the unrolled oracle; `jvp` against finite
  differences; `hessianVector` against the analytic value.
- **Models**: each phase's acceptance numbers above, recorded in this plan when the phase lands.
- **Gates**: `make check-tensor check-api check-ops run-mnist check-bytecode` before each phase
  is marked done.

## 8. Risks and open questions

- **Elm build time and memory for very large graphs** (the 96-layer example) are unmeasured until
  P5. Building and lowering are linear by design: iterative walks, `Dict` memos, an `Array`-based
  printer. P5's benchmark settles it.
- **Placeholder keys are probabilistic**, through hashing. A collision is detected on memo hits
  (§5.5) and reported, not silently merged.
- **Gradients.** The conv filter gradient may need the im2col fallback (P4.5). Pooling gradients
  are limited to window = stride.
- **Shared subgraphs** may never pay for themselves on CPU (finding 12). P5 measures this before
  making them a recommended path.
- **Per-example gradients over parameter records** are out of reach of Elm's types (§3.8).
- **The stub.** `tensor-api` must stay in step with the package. `check-api` enforces this.

## 9. Adversarial review (2026-11-11)

An independent review ran against the first version of this plan. Its scratch work is in
`/tmp/eco-nabla-review/`; the MAX probes are reproduced in the inventory. It made 19 findings.
Each one, and what changed:

1. **`grad f x` differentiated with respect to the node `x`, which is wrong when `x` occurs inside
   `f`.** Every transform now traces on placeholders with probe-salted keys (§3.5), with nesting
   tests in P0.5.
2. **Pending broadcast axes silently computed on size 1** in reductions, softmax, reshape and
   matmul contractions; `everywhere` had no rank. Pending axes now only reach element-wise ops
   (§3.4), a real 1 against N is refused, and `everywhere` is replaced by `fillLike`.
3. **`mo.call` must sit directly in `mo.graph`** (verified with MAX). Calls inside regions are
   inlined (§3.9).
4. **`MlirBc` could not write regions that capture.** Non-isolated regions were added (§5.6, P4.1).
5. **Placeholder keys were unspecified and collided under nesting.** Keys are now specified (§3.5)
   and tested.
6. **Record codecs could swap fields; `Sig.map` inverses and config constants were unchecked.**
   Round-trip checks were added at build time (§3.6).
7. **Parameters round-tripped through Elm every step, which does not scale.** State is now resident
   on the host, with roles and `initGraph` (§3.12, §5.7, P2).
8. **QLoRA codes could not be parameters; there was no `tree_map` and no custom optimizer; the rate
   could not be passed; frozen parameters broke the layout; pretrained starts were impossible.**
   Added `Param.data`, `mapElems`/`Elems`, `Optim.custom`, `clipGlobalNorm`, the fed rate input,
   resident roles and `initialFrom`.
9. **`Random.salt` was unspecified; additive salts collide; vmapped draws were identical.**
   Salting is now multiplicative (§3.11), and draws are always batched under vmap (§3.8).
10. **MAX has no pooling gradient, and the conv filter gradient was unplanned.** Pooling is
    restricted to window = stride with a composed vjp; the filter gradient has a probe and a
    fallback (P4.5).
11. **`negate` on u8 fails inside MAX.** A probed dtype support table checks this at build time
    (§3.2, P0.4).
12. **`shared` saves only about 10 s of compile time.** It moved to the last phase and is
    measured there (§3.9, P5). Its API stays.
13. **vmap, jvp and cond were underdesigned.** Now: jvp by double vjp, `Batch` combinators,
    `cond`'s closure conversion, and the unrolled vmap oracle.
14. **"Traced once" through a partially applied function is fragile under eta-expansion.**
    `shared` now returns a `Shared` value used through `call`.
15. **"One size per tag" cannot be implemented.** The claim was restated (§3.1), and `stack` takes
    a `Dim`.
16. **Coverage and naming gaps.** Added `matVec`, `fullLike`, `castLike`, `concat2` (replacing
    `append`), `sign`, attention mask and bias options, `LayerNorm.apply3`, `applyTransposed`,
    four-sided padding, and AdamW `biasCorrection`. Swapped `max`/`min` (element-wise) with
    `maximum`/`minimum` (reductions). Gave the witnesses consistent names. Specified the
    `lessThan` lowering and constant hashing by bits, and the printer fix. Remaining gaps are
    listed in §4.15.
17. **Evidence was only in `/tmp`; no autodiff oracle; compile cost; no MNIST criterion.** The stub
    and inventory are now in the repo; gradients are checked against NumPy finite differences;
    graphs are batched per family; the criterion is in P0.8.
18. **Phase order.** Placeholders, pending axes, the rule shape and witnesses moved into P0.
19. **Local package.** It works (verified). The name is now `eco-lab/tensor` rather than kernel
    author `eco`, and the tests live in the package.

The corrected API was compiled again (`spikes/max/tensor-api`): 28 modules and 6 example programs
compile, and all 17 counterexamples are refused.

## 10. Results (2026-11-11)

All six phases are implemented and checked. The package is `spikes/max/tensor` (`eco-lab/tensor`);
its README lists the modules.

**Gates, all green.**
- `make check-tensor`: 38 package tests.
- `make check-api`: the six example programs compile against the package; all 17 counterexamples
  are refused.
- `make check-ops`: 16 families of operations (328 checks), every value against NumPy in f64 and
  every gradient against central differences, also run from the Elm-written bytecode
  (`OPCHECK_FORMAT=bytecode`).
- `make check-opcheck-bytecode`: every family's bytecode and generic text read back identical
  through eco's `mlir-opt`.
- `make run-mnist` and `make check-bytecode`.

A deliberately wrong reference (a 1% value error, a 0.002 gradient error) makes `check-ops` fail.

**Models** (MAX 26.7.0, CPU):

| Phase | Model | Plan's acceptance | Result |
|---|---|---|---|
| P0 | MNIST, SGD 0.1 | accuracies within 0.05 points; first 100 step losses within 1e-5 of the old DSL | 14.78 → 92.52 … 95.87%, exactly; all 100 step losses bit-identical |
| P2 | MNIST, AdamW 1e-3, resident state | ≥ 97.0%; no parameter bytes cross the Elm boundary after `put` | 97.15%; the same after `save`, `loadInto` and re-evaluation. The host counts each run's bytes: a training run receives at most 78,528 (header, 78,400 bytes of images, 112 of labels) and returns 32 (header, loss); the parameters (407 KB) and AdamW state never cross |
| P2 | 784-512-256-10 `Nn.Stack`, dropout 0.1 | ≥ 97.5% | 97.65% |
| P2 | SGD with momentum and weight decay; Lion as `Optim.custom` | (exercise the API) | 97.51%, 95.97% after 3 epochs |
| P3 | character model, 2 layers, 1,000 steps | held-out loss below the unigram entropy | 1.96 nats against 3.19 |
| P4 | CNN, 2 epochs | ≥ 98.5% | 98.57% |
| P5 | 8-layer character model, shared blocks against inlined | same losses within 1e-5; MAX compile time, Elm build time, bytecode size recorded | within 7.15e-7 over 20 steps; compile 68–70 s / 83–85 s (training step, three runs each on an empty MAX cache), Elm build 0.2 s / 0.2 s, bytecode 75 KB / 88 KB |
| P5 | LoRA rank 8 on the AdamW network, its base loaded by `Train.initialFrom` (the runner reads the saved parameters into Elm as a `Param.initial`-layout block) | frozen buffers byte-identical; accuracy holds | identical; it starts at exactly the base's 97.15% and reaches 97.54% after one epoch |
| P5 | QLoRA `dequantize` | NumPy NF4 to 1e-6 | passes |

**Measurements:**
- **Shared blocks, 8 layers** (final code, each run with its own empty MAX cache; the two graphs
  compile concurrently). Over three cold runs each, the training step compiles in 67.5–69.6 s shared
  and 82.9–84.6 s inlined; the evaluation graph in 46.8–51.1 s shared and 34.2–34.9 s inlined. Shared bytecode is 15% smaller. Over
  four runs each, steps 1–20 take 0.89–1.01 s shared (mean 0.97 s) and 0.67–0.95 s inlined (mean
  0.83 s): shared is about 17% slower, with a wide spread over so few steps. An earlier measurement
  of 2.5 times slower does not reproduce on the final code; the held-out loss is 3.1038 in all
  eight runs. At this size, sharing saves some compile time on the
  training step and costs it on evaluation; it stays opt-in.
- **GPT of the example's size** (96 × 768, vocabulary 50257, sequence 1024, batch 8, AdamW), built
  under node, not run. The training step is 4,626 inputs:
  - shared: 3.7–3.9 s to build (three runs) and 0.67 MB of bytecode (669,103 bytes every run);
  - inlined: 4.0 s in all three runs and 0.92 MB (919,823 bytes).

  Both use about 200 MB of heap, so Elm-side build cost is no obstacle at that scale (§8's open
  risk).
- **Dtype support probe** (`capi/scripts/inventory/support_probe.py`, 46 primitives × 9 dtypes):
  MAX refuses only `negate` on `ui8` and `ui64`. The generated `Support.elm` refuses those when a
  graph is built.
- **Probes P0.4 asked for:**
  - `rmo.mod` is floored like Elm's `modBy` (op-check `modBy` against `np.mod`);
  - `rmo.mul` and `rmo.add` on `ui64` wrap like NumPy.

**Where the implementation departs from §3–§7, and why:**
- **The seed salt is `s * 25214903917 + (2i + 1)`.** The multiplier in §3.11 is not exact as an Elm
  `Float`.
- **Host commands.** `run`, `put`, `get`, `save` and `loadInto` travel on one port (`hostOut`), and
  `Bridge.send` packs several into one message the host runs in order. Elm, and eco, deliver several
  sends to one port within a `Cmd.batch` in reverse order, and sends to different ports in no
  guaranteed order. The first checkpoint attempt saved empty buffers because of this.
- **Scalar resident and fed tensors travel as shape `[1]`** (the optimizer's `step`, a per-step
  `rate`). MAX's C API does not take rank-0 inputs ("Required input … not provided").
- **Op-check harness.** It runs the Elm side under node and the graphs through MAX's Python API
  (`InferenceSession.load` reads an MLIR file directly), so it needs neither the C++ host nor a save
  message.
- **The filter gradient needs no fallback.** It is one more convolution with dilation (MAX compiles
  dilated convolutions). A strided convolution's input gradient drops the padding the forward pass
  never read.
- **`MlirBc` additions:** besides §5.6's, `SignedIntegerType` (`num_groups` must be `si64`). Open
  regions are numbered after all of their enclosing regions' values, as MLIR's bytecode reader
  expects.
- **API additions found while implementing:**
  - `Tensor.one`, for a grey image's channel;
  - `Nn.Stack.applyWithDropout`;
  - `Qlora.codebook`.
- **`jacobian`** is the pullback `vmap`ped over the identity's rows.

## Appendix A. Nabla's API (catalogue, 2026-11-11)

Every documented item of https://www.nablaml.com/api/ (about 35 pages), read page by page.
Signatures as the site renders them. The "Elm" column is the first-pass mapping written before the
design decisions of §3; **§4 and its coverage table (§4.14) are authoritative** where they differ
(phase numbers and some names here are the first draft's).


Signatures are as the docs site renders them (Python), shortened only by dropping quote marks in
annotations. "Elm" gives the existing name, or the phase and the proposed name, or why not.

### A.1 Core: `Tensor` (core/tensor)

`class Tensor(*, buffers, value, impl, is_traced: bool = False)`: a multi-dimensional array with
eager execution and automatic compilation. Elm: **have** `Tensor t` (an expression, phantom dtype).

| Method | Meaning | Elm |
|---|---|---|
| `abs(self)` | \|x\| | P1 `T.abs` |
| `acos(self)` | arccosine | P1 `T.acos` |
| `atanh(self)` | inverse hyperbolic tangent | P1 `T.atanh` |
| `cos(self)` | cosine | P1 `T.cos` |
| `erf(self)` | error function | P1 `T.erf` |
| `exp(self)` | e^x | P1 `T.exp` |
| `floor(self)` | round down | P1 `T.floor` |
| `log(self)` | natural log | P1 `T.log` |
| `log1p(self)` | log(1+x) | P1 `T.log1p` |
| `round(self)` | round half to even | P1 `T.round` |
| `rsqrt(self)` | 1/√x | P1 `T.rsqrt` |
| `sigmoid(self)` | logistic | P1 `T.sigmoid` |
| `silu(self)` | x·sigmoid(x) | P1 `T.silu` |
| `sin(self)` | sine | P1 `T.sin` |
| `sqrt(self)` | √x | P1 `T.sqrt` |
| `tanh(self)` | tanh | P1 `T.tanh` |
| `trunc(self)` | round toward zero | P1 `T.truncate` |
| `is_inf(self)` | infinite? → bool | P1 `T.isInfinite` |
| `is_nan(self)` | NaN? → bool | P1 `T.isNaN` |
| `relu(self)` | max(0, x) | **have** `T.relu` |
| `gelu(self, approximate='none')` | GELU, exact or tanh form | P1 `T.gelu`, `T.geluTanh` |
| `logsoftmax(self, axis=-1)` | log-softmax | **have** `T.logSoftmax axis` |
| `softmax(self, axis=-1)` | softmax | **have** `T.softmax axis` |
| `argmax(self, axis=None, keepdims=False)` | index of max | **have** `T.argMax axis`; P1 `argMaxWith` |
| `argmin(self, axis=None, keepdims=False)` | index of min | P1 `T.argMin` |
| `cumsum(self, axis: int)` | running sum | P1 `T.cumsum` |
| `max(self, axis=None, keepdims=False)` | maximum | P1 `T.max`, `maxAll`, `maxWith` |
| `mean(self, axis=None, keepdims=False)` | mean | P1 `T.mean` .. (compose: sum / n) |
| `min(self, axis=None, keepdims=False)` | minimum | P1 `T.min` .. |
| `sum(self, axis=None, keepdims=False)` | sum | **have** `T.sum axis`; P1 `sumAll`, `sumWith` |
| `broadcast_to(self, shape)` | NumPy broadcast | P1 `T.broadcastTo` |
| `expand(self, *shape)` | broadcast (PyTorch name) | alias of `broadcastTo`, not ported |
| `flatten(self, start_dim=0, end_dim=-1)` | merge dims | P1 `T.flatten`, `flattenRange` |
| `flip(self, axis)` | reverse along axis | P1 `T.flip` |
| `permute(self, *order)` | reorder dims | P1 `T.permute` |
| `reshape(self, shape)` | new shape, one −1 inferred | **have** `T.reshape` (P1: −1) |
| `squeeze(self, axis=None)` | drop size-1 dims | P1 `T.squeeze`, `squeezeAll` |
| `swap_axes(self, axis1, axis2)` | swap two dims | P1 `T.swapAxes` |
| `transpose(self, axis1, axis2)` | swap two dims | **have** `T.transpose` (2-D); P1 → `swapAxes` |
| `unsqueeze(self, axis)` | insert size-1 dim | P1 `T.unsqueeze` (`T.column` is the 1-D case) |
| `view(self, *shape)` | reshape view | alias of `reshape`, not ported |
| `size(self, dim=None)`, `dim(self)`, `numel(self)`, `num_elements(self)` | shape queries | P1 `T.shape`, `T.rank` at build time (need `Graph` shape inference on expressions; see note) |
| `physical_local_shape(self, shard_idx=0)`, `physical_local_shape_ints`, `logical_local_shape`, `shard_shape` | per-shard shapes | out (sharding) |
| `gather(self)` | gather shards to one tensor | out (sharding) |
| `backward(self, gradient=None, retain_graph=False, create_graph=False)` | fill `.grad` | n/a (mutation); use `grad` |
| `detach(self)` | cut from autograd | P3 `T.stopGradient` |
| `requires_grad_(self, value=True)` | mark leaf | n/a (grad names its arguments) |
| `trace(self)` | trace graph | n/a (always a graph) |
| `cast(self, dtype)` | convert dtype | **have** `toFloat`, `toInt`; P1 `T.cast witness` |
| `type_as(self, other)` | cast to other's dtype | P1 `T.castLike` |
| `to(self, target)`, `cpu(self)`, `cuda(self, device=0)` | move device | out (devices) |
| `realize(self)`, `hydrate(self)` | evaluate | host (running a graph) |
| `item(self)`, `numpy(self)`, `to_numpy(self)`, `to_numpy_all(*tensors)`, `tolist(self)` | read back | host (`Train.measureReply`-style decoders) |
| `new_empty(self, shape, *, dtype=None, device=None)` | uninitialised | n/a (no uninitialised data) |
| `new_full(self, shape, fill_value, *, dtype=None, device=None)` | filled, like self | P1 via `T.full` |
| `new_ones(..)`, `new_zeros(..)` | ones/zeros like self | P1 via `T.ones`, `T.zeros` |
| `shard(self, mesh, dim_specs, replicated_axes=None)`, `with_sharding(..)`, `with_sharding_constraint(..)` | sharding | out |
| module: `realize_all(*tensors)` | evaluate many | host |
| module: `is_tensor(obj)` | type test | n/a (types) |

Note on shape queries: shapes are known only when `Graph` lowers. Exposing `T.shape` at build time
means running shape inference on expressions as they are made (each `Tensor` carrying its shape
and dtype). That also gives source-level errors (the open "source labels in errors" step). Decide
in P0; it is the likely direction.

### A.2 Core: defaults and context (core/context)

| Nabla | Meaning | Elm |
|---|---|---|
| `defaults(dtype: DType \| None = None, device: Device \| None = None) -> tuple[DType, Device]` | current default dtype/device | n/a (dtypes are explicit types) |
| `default_device(device: Device \| graph.DeviceRef) -> Generator` | context manager | out (devices) |
| `default_dtype(dtype: DType) -> Generator` | context manager | n/a |
| `defaults_like(like: Tensor \| TensorType) -> Generator` | context manager | n/a |

### A.3 Core: autograd runtime (core/autograd)

| Nabla | Meaning | Elm |
|---|---|---|
| `backward(outputs: Any, cotangents: Any = None, *, create_graph: bool = False) -> None` | PyTorch-style: trace from outputs, VJP, fill `.grad` on `requires_grad` leaves, realize | n/a; `grad` (have) |
| `forward(trace: Trace, tangents: Any, *, create_graph: bool = True) -> TangentMap` | forward-mode AD on a trace; tangents shaped like the trace inputs | P3, inside `Transform.jvp` |

### A.4 Core: pytrees (core/pytree)

| Nabla | Meaning | Elm |
|---|---|---|
| `class PyTreeDef(kind: int, meta: Any, children: tuple[PyTreeDef, ...], num_leaves: int)` | structure of a tree | n/a: the Elm type is the structure |
| `tree_flatten(tree, is_leaf=None) -> tuple[list, PyTreeDef]` | leaves + structure | **have** in spirit: `Arg`, `Out`, `Param.toList` |
| `tree_unflatten(treedef, leaves) -> Any` | rebuild | **have** in spirit: `Arg` builders, `Param` make |
| `tree_map(fn, tree, *rest, is_leaf=None) -> Any` | map over leaves | P2 `Param.map`, `Param.map2` over parameter records |
| `tree_leaves(tree, is_leaf=None) -> list` | leaves only | **have** `Param.toList` |
| `tree_structure(tree, is_leaf=None) -> PyTreeDef` | structure only | n/a |
| `register_pytree_node(cls, flatten_fn, unflatten_fn) -> None` | custom container | n/a (combinators instead) |
| `tensor_leaves(tree) -> list[Tensor]` | tensor leaves | n/a |
| `traced(tree)`, `untraced(tree)` | mark traced | n/a |
| `with_batch_dims(tree, delta: int)` | adjust vmap batch dims | P4, internal to `vmap` |

### A.5 Core: sharding (core/sharding)

All **out** (single device for now): `class DeviceMesh(name: str, shape: tuple[int, ...],
axis_names: tuple[str, ...], devices: list[int] | None = None, device_refs: list[DeviceRef] | None
= None, bandwidth: float = 1.0)` (logical device grid `@name = <["x"=2, ..]>`); `class
PartitionSpec(*args)` and its alias `class P(*args)` (JAX-compatible); `class DimSpec(axes:
list[str], is_open: bool = False, priority: int = 0, partial: bool = False)` (per-dimension
sharding); `class ShardingSpec(mesh: DeviceMesh, dim_specs: list[DimSpec], replicated_axes:
set[str], partial_sum_axes: set[str])` (`sharding<@mesh, [dims], replicated={..}>`);
`compute_local_shape(global_shape, sharding, device_id) -> tuple[int, ...]` (one device's shard
shape); `get_num_shards(sharding) -> int`.

### A.6 Core: types and devices (core/types)

| Nabla | Meaning | Elm |
|---|---|---|
| `class DType(*values)` | tensor element type | **have** phantom types `F32`, `U8`, `I64`, `Boolean`; P1 more plus witnesses (§2.5) |
| `class CPU(*args, **kwargs)` | CPU device | out (host picks the device) |
| `class Accelerator(*args, **kwargs)` | GPU device | out |

### A.7 Transforms: differentiation (transforms/differentiation)

| Nabla | Meaning | Elm |
|---|---|---|
| `grad(fun, argnums=0, create_graph=True, realize=True)` | gradient function of a scalar function | **have** `T.grad loss wrt` (expression form); P3 `Transform.grad f` (function form, higher order) |
| `value_and_grad(fun, argnums=0, create_graph=True, realize=True)` | value and gradient | P3 `Transform.valueAndGrad` (today: `loss` and `T.grad loss ws` side by side) |
| `vjp(fn, *primals, has_aux=False, create_graph=True)` | `(output, pullback)` or `(output, pullback, aux)` | P3 `Transform.vjp : (a -> Tensor F32) -> a -> ( Tensor F32, Tensor F32 -> a )` |
| `jvp(fn, primals, tangents, *, has_aux=False, create_graph=True)` | forward-mode `(output, tangent_out)` | P3 `Transform.jvp` (needs forward rules) |
| `jacrev(fn, argnums=None, has_aux=False)` | Jacobian by vmap over VJPs | P4 (after `vmap`) |
| `jacfwd(fn, argnums=None, has_aux=False)` | Jacobian by vmap over JVPs | P4 |

### A.8 Transforms: vectorisation (transforms/vectorization)

| Nabla | Meaning | Elm |
|---|---|---|
| `vmap(func=None, in_axes=0, out_axes=0, axis_size=None, spmd_axis_name=None, mesh=None)` | JAX-compatible auto-batching | P4 `Transform.vmap` (in/out axes; `spmd_axis_name`, `mesh` out) |

### A.9 Transforms: compilation (transforms/compilation)

| Nabla | Meaning | Elm |
|---|---|---|
| `compile(fn=None, *, fullgraph=False, max_cache_size=64, dynamic_dims=None)` | trace once, cache compiled graph by signature (LRU) | n/a: every Elm graph is compiled ahead of time; MAX caches by bytes. `dynamic_dims` → symbolic dims, later |
| `class CompiledFunction(fn, *, fullgraph=False, max_cache_size=64, dynamic_dims=None)` | the compiled wrapper | n/a (`T.Graph` plays the role) |
| `class CompilationStats(hits=0, misses=0, fallbacks=0, total_compile_time_ms=0.0, total_cached_exec_time_ms=0.0, cache_size=0)` | cache counters | host (the bridge can report MAX's compile times and cache hits) |

### A.10 Transforms: distributed (transforms/distributed)

| Nabla | Meaning | Elm |
|---|---|---|
| `shard_map(func, mesh: DeviceMesh, in_specs: dict[int, ShardingSpec], out_specs: dict[int, ShardingSpec] \| None = None, auto_sharding: bool = False, debug: bool = False) -> Callable` | SPMD: shard inputs, trace once, run sharded, reshard outputs; optional ILP auto-sharding | out |

### A.11 Ops: creation (ops/creation)

Every factory except `constant`, `arange`, `triu`, `tril` and the `*_like` functions also takes
`is_traced: bool = False` (undocumented; n/a in Elm).

| Nabla | Meaning | Elm |
|---|---|---|
| `zeros(shape, *, dtype=None, device=None, is_traced=False)` | all zeros | P1 `T.zeros dtypeWitness shape` |
| `ones(shape, *, dtype=None, device=None, is_traced=False)` | all ones | P1 `T.ones` |
| `full(shape, value: Number, *, dtype=None, device=None, is_traced=False)` | filled with `value` | P1 `T.full` |
| `constant(value: NestedArray \| Number, *, dtype=None, device=None)` | tensor from data | **have** `T.constant` (scalar); P1 `T.scalar`, `T.int`, `T.fromList shape values` |
| `arange(start=0, stop=None, step=1, *, dtype=None, device=None)` | [start, stop) by step; length ⌈(stop−start)/step⌉ | **have** `T.range`; P1 start/step |
| `uniform(shape=(), low=0.0, high=1.0, *, dtype=None, device=None)` | U[low, high) | P2 `Random.uniform key` (§2.9) |
| `normal(shape=(), mean=0.0, std=1.0, *, dtype=None, device=None)` | N(mean, std²) | P2 `Random.normal key` |
| `gaussian(shape=(), mean=0.0, std=1.0, *, dtype=None, device=None)` | same as `normal` | alias, not ported |
| `hann_window(window_length: int, *, periodic=True, dtype=None, device=None)` | w[n] = ½(1 − cos(2πn/N)), shape (L,) | P1 `T.hannWindow` (MAX has `hann_window`) |
| `triu(x, k=0) -> Tensor` | zero below k-th diagonal of (*, M, N) | P1 `T.triu` |
| `tril(x, k=0) -> Tensor` | zero above k-th diagonal | P1 `T.tril` |
| `zeros_like(x)`, `ones_like(x)`, `full_like(x, value)` | same shape/dtype as x | P1 `T.zerosLike` .. |

### A.12 Ops: binary (ops/binary)

All broadcast (NumPy rules); the second argument may be a Python scalar (§2.4).

| Nabla | Meaning | Elm |
|---|---|---|
| `add(x, y)` | x + y | **have** `T.plus` |
| `sub(x, y)` | x − y | **have** `T.minus` |
| `mul(x, y)` | x · y | **have** `T.times`; `T.scale` for a Float |
| `div(x, y)` | x / y | P1 `T.dividedBy` |
| `matmul(x, y)` | (*, M, K) @ (*, K, N) → (*, M, N); 1-D operands promoted then squeezed | **have** `T.matmul` (2-D); P1 batch prefixes and 1-D |
| `mod(x, y)` | x % y | P1 `T.modBy` (check sign convention against Elm's `modBy`/`remainderBy`) |
| `pow(x, y)` | x ** y | P1 `T.pow` |
| `outer(x, y)` | (M,) ⊗ (N,) → (M, N) | P1 `T.outer` (MAX has `outer`) |

### A.13 Ops: convolution and pooling (ops/vision)

NHWC input, HWIO filter, as MAX.

| Nabla | Meaning | Elm |
|---|---|---|
| `conv2d(x, filter, *, stride=(1, 1), dilation=(1, 1), padding=(0, 0, 0, 0), groups=1, bias=None, input_layout=None, filter_layout=None)` | 2-D convolution; x (N,H,W,Cin), filter (Kh,Kw,Cin,Cout); padding int, (h, w) or (top, bottom, left, right); only dilation (1,1), groups 1; bias (Cout,) | P4 `T.conv2d`, `conv2dWith` |
| `conv2d_transpose(x, filter, *, stride=(1, 1), dilation=(1, 1), padding=(0, 0, 0, 0), output_paddings=(0, 0), bias=None, input_layout=None, filter_layout=None)` | transposed convolution (gradient of conv2d w.r.t. input); filter (Kh,Kw,Cout,Cin); only output_paddings (0,0) | P4 `T.conv2dTranspose` |
| `avg_pool2d(x, *, kernel_size, stride=None, padding=0, dilation=(1, 1))` | mean over windows; stride defaults to kernel | P4 `T.avgPool2d` |
| `max_pool2d(x, *, kernel_size, stride=None, padding=0, dilation=(1, 1))` | max over windows | P4 `T.maxPool2d` |

### A.14 Ops: unary and activations (ops/unary)

| Nabla | Meaning | Elm |
|---|---|---|
| `abs(x)` | \|x\| | P1 `T.abs` |
| `neg(x)` | −x | **have** `T.negate` |
| `exp(x)` | e^x | P1 `T.exp` |
| `log(x)` | ln x; −inf at 0, NaN below | P1 `T.log` |
| `log1p(x)` | ln(1 + x), stable near 0 | P1 `T.log1p` |
| `sqrt(x)` | √x | P1 `T.sqrt` |
| `rsqrt(x)` | 1/√x | P1 `T.rsqrt` |
| `sin(x)`, `cos(x)` | radians | P1 `T.sin`, `T.cos` |
| `acos(x)` | arccos; NaN for \|x\| > 1 | P1 `T.acos` |
| `atanh(x)` | inverse tanh | P1 `T.atanh` |
| `erf(x)` | Gauss error function | P1 `T.erf` |
| `floor(x)` | toward −inf | P1 `T.floor` |
| `round(x)` | half to even | P1 `T.round` |
| `trunc(x)` | toward zero | P1 `T.truncate` |
| `cast(x, dtype=None)` | convert dtype (None: unchanged) | **have** `toFloat`, `toInt`; P1 `T.cast` |
| `is_inf(x)`, `is_nan(x)` | → bool | P1 `T.isInfinite`, `T.isNaN` |
| `relu(x)` | max(0, x) | **have** `T.relu` |
| `sigmoid(x)` | 1/(1 + e^−x) | P1 `T.sigmoid` |
| `tanh(x)` | tanh | P1 `T.tanh` |
| `gelu(x)` | exact x·Φ(x) | P1 `T.gelu` (compose with `erf` if no primitive) |
| `silu(x)` | x·sigmoid(x) | P1 `T.silu` (compose) |
| `softmax(x, axis=-1)` | stable softmax; all-reduce if axis sharded | **have** `T.softmax axis` |
| `logsoftmax(x, axis=-1)` | log-sum-exp form | **have** `T.logSoftmax axis` |

### A.15 Ops: reduction (ops/reduction)

`axis: int | tuple[int, ...] | list[int] | None = None` (None: all elements, scalar result) and
`keepdims: bool = False` for the first seven.

| Nabla | Meaning | Elm |
|---|---|---|
| `reduce_sum(x, *, axis=None, keepdims=False)` / `sum(..)` | sum | **have** `T.sum axis`; P1 `sumAll`, `sumWith` |
| `reduce_max(..)` / `max(..)` | maximum | P1 `T.max`, `maxAll`, `maxWith` |
| `reduce_min(..)` / `min(..)` | minimum | P1 `T.min` .. |
| `mean(x, *, axis=None, keepdims=False)` | sum / n (correct when sharded) | P1 `T.mean` .. (compose) |
| `argmax(x, axis=-1, keepdims=False)` | index of max, int64 | **have** `T.argMax axis` |
| `argmin(x, axis=-1, keepdims=False)` | index of min, int64 | P1 `T.argMin` |
| `cumsum(x, axis=-1, exclusive=False, reverse=False)` | running sum; exclusive starts at 0; reverse right to left | P1 `T.cumsum`, `cumsumWith` |
| `reduce_sum_physical(x, axis: int, keepdims=False)` | sum over a physical (vmap/shard) axis | P4, internal to `vmap` |
| `mean_physical(x, axis: int, keepdims=False)` | mean over a physical axis | P4, internal |

### A.16 Ops: comparison and logical (ops/comparison)

| Nabla | Meaning | Elm |
|---|---|---|
| `equal(x, y)` | x == y → bool | **have** `T.equals` |
| `not_equal(x, y)` | x != y | P1 `T.notEquals` |
| `greater(x, y)` | x > y | **have** `T.greaterThan` |
| `greater_equal(x, y)` | x >= y | P1 `T.atLeast` |
| `less(x, y)` | x < y | P1 `T.lessThan` |
| `less_equal(x, y)` | x <= y | P1 `T.atMost` |
| `logical_and(x, y)`, `logical_or(x, y)`, `logical_xor(x, y)` | on truthiness | P1 `T.and`, `T.or`, `T.xor` (on `Tensor Boolean`) |
| `logical_not(x)` | not | P1 `T.not` |

### A.17 Ops: control flow (ops/control_flow)

| Nabla | Meaning | Elm |
|---|---|---|
| `where(condition, x, y)` | element-wise select, broadcasting all three | P1 `T.select cond x y` |
| `cond(pred, true_fn, false_fn, *operands)` | run one branch on a scalar bool; branches match in shapes/dtypes | P4 `T.cond` (an `mo` region op, if usable) |
| `while_loop(cond_fn, body_fn, init_val)` | loop on a state (tensor or pytree) of fixed structure | P4 `T.whileLoop` with an `Arg`-like state description |
| `scan(f, init, xs, length=None, reverse=False)` | `(carry, x) -> (carry, y)` over axis 0, unrolled at trace time; `(carry, stacked ys)`; reverse unsupported | P4 `T.scan` as an Elm fold over `unbind` + `stack` (unrolled, as Nabla) |

### A.18 Ops: multi-output (ops/multi_output)

| Nabla | Meaning | Elm |
|---|---|---|
| `split(x, num_splits: int, axis=0) -> list` | equal chunks; size must divide | P1 `T.split n axis : Tensor a -> List (Tensor a)` |
| `chunk(x, chunks: int, axis=0) -> list` | ⌈size/chunks⌉ chunks, last may be smaller | P1 `T.chunk` |
| `unbind(x, axis=0) -> list` | slices along axis, rank − 1 each | P1 `T.unbind` |
| `minmax(x) -> dict[str, Tensor]` | global min and max as scalars, keys `min`, `max` | P1 `T.minMax : Tensor a -> { min : Tensor a, max : Tensor a }` |

### A.19 Ops: view and shape (ops/view)

| Nabla | Meaning | Elm |
|---|---|---|
| `reshape(x, shape)` | keep count; one −1 inferred | **have** `T.reshape` (P1: −1) |
| `transpose(x, axis1, axis2)` | swap two dims, negative ok | **have** 2-D `T.transpose`; P1 `T.swapAxes` |
| `permute(x, order)` | permutation of dims | P1 `T.permute` |
| `unsqueeze(x, axis=0)` | insert size-1 dim | P1 `T.unsqueeze` |
| `squeeze(x, axis=0)` | drop size-1 dim (doc: None drops all) | P1 `T.squeeze`, `squeezeAll` |
| `flatten(x, start_dim=0, end_dim=-1)` | merge dims, inclusive | P1 `T.flatten` |
| `broadcast_to(x, shape)` | NumPy broadcast | P1 `T.broadcastTo` |
| `concatenate(tensors: Sequence[Tensor], axis=0)` | join on existing axis | P1 `T.concat axis : List (Tensor a) -> Tensor a` |
| `stack(tensors: list[Tensor], axis=0)` | join on new axis | P1 `T.stack` |
| `gather(x, indices, axis=0)` | `x.take(indices, axis)`; shape x[:axis] + indices + x[axis+1:] | P1 `T.gather` (indices `Tensor I64`) |
| `scatter(x, indices, updates, axis=0)` | out-of-place `out[indices] = updates` | P1 `T.scatter` |
| `slice_tensor(x, start, size)` | rectangular slice, negative starts ok | P1 `T.slice { start, size }` |
| `slice_update(x, update, start, size)` | out-of-place region replace, differentiable | P1 `T.sliceUpdate` |
| `moveaxis(x, source, destination)` | move one axis | P1 `T.moveAxis` |
| `swap_axes(x, axis1, axis2)` | same as transpose | P1 `T.swapAxes` |
| `flip(x, axis)` | reverse along axis | P1 `T.flip` |
| `pad(x, paddings=None, mode='constant', value=0.0, **kwargs)` | (before, after) per dim; constant only; alias `pad_width` | P1 `T.pad value [ ( b, a ) .. ]` |
| `rebind(x, shape, **kwargs)` | re-annotate with a (symbolic) shape; no gradient | later (symbolic dims) |
| `as_interleaved_complex(x)` | (..., 2) real → (...) complex | later (complex dtype) |
| `view_as_real_interleaved(x)` | complex → (..., 2) real | later |
| `broadcast_to_physical(x, shape)`, `squeeze_physical(x, axis=0)`, `unsqueeze_physical(x, axis=0)` | physical-layout forms for transforms | P4, internal to `vmap` |
| `incr_batch_dims(x)`, `decr_batch_dims(x)`, `move_axis_to_batch_dims(x, axis)`, `move_axis_from_batch_dims(x, batch_axis=0, logical_destination=0)` | vmap batch-dim bookkeeping | P4, internal |

### A.20 Ops: communication (ops/communication)

All **out** (multi-device): `shard(x, mesh, dim_specs, replicated_axes=None, **kwargs)` (distribute
per `DimSpec`s, collecting first if needed); `reshard(*args, **kwargs)` (deprecated, = `shard`);
`all_reduce(sharded_tensor, **kwargs)` (`reduce_op` sum/max/min/prod, `reduce_axes`);
`all_gather(sharded_tensor, axis=None, **kwargs)`; `all_to_all(sharded_tensor, split_axis,
concat_axis, tiled=True)` (distributed transpose); `reduce_scatter(sharded_tensor, axis,
**kwargs)` (sum only on MAX); `distributed_broadcast(x, mesh=None)`; `ppermute(sharded_tensor,
permutation)`; `to_device(x, device=None, *, sharding=None)` and its twin `transfer_to(..)`
(differentiable device_put); `cpu(x)`; `gpu(x)`; `accelerator(x, device_id=0)`.

### A.21 Ops: custom op utilities (ops/custom)

Nabla's extension points. In Elm the equivalent is adding a constructor to `Tensor`'s `Op` and
`Graph`'s node, with a shape rule, a lowering and a gradient rule; these classes are the checklist
for that, not API to port.

| Nabla | Meaning | Elm |
|---|---|---|
| `class Operation()` | base of differentiable ops: validation, SPMD, structural-hash caching, eager/trace dispatch; stateless singletons; overrides `name`, `kernel`, `compute_physical_shape`, `vjp_rule`, `jvp_rule` | n/a (internal op table; structural hashing **have**: `Tensor` keys) |
| `Operation.adapt_kwargs(self, args, kwargs, batch_dims: int) -> OpKwargs` | shift kwargs for vmap batch dims | P4, internal |
| `Operation.compute_cost(self, input_shapes, output_shapes) -> float` | FLOP estimate | later (auto-sharding only) |
| `Operation.compute_physical_shape(self, args, kwargs, output_sharding=None) -> tuple[shapes, dtypes, devices]` | per-shard output shapes | the shape rule in `Graph` (**have** for current ops) |
| `Operation.execute(self, args, kwargs) -> tuple[list, ShardingSpec \| None, DeviceMesh \| None]` | run kernel per shard | n/a |
| `Operation.get_sharding_rule_template(self)`, `sharding_rule(self, input_shapes, output_shapes, **kwargs)` | SPMD rules | out |
| `Operation.infer_output_rank(self, input_shapes, **kwargs) -> int` | rank rule | part of the shape rule |
| `Operation.jvp_rule(self, primals, tangents, outputs, kwargs) -> list[Tensor \| None]` | forward rule | P3, one per op |
| `Operation.kernel(self, args, kwargs) -> OpTensorValues` | emit MAX graph ops | the lowering in `Graph.print`/`MlirBc` (**have** for current ops) |
| `Operation.memory_cost(self, input_shapes, output_shapes, dtype_bytes=4) -> int` | output bytes | later |
| `Operation.vjp_rule(self, primals, cotangents, outputs, kwargs) -> list[Tensor \| None]` | reverse rule | **have** on the tape (`Graph.grad`); P3 on expressions |
| `class UnaryOperation()` | element-wise unary; shape/dtype pass-through; VJP and JVP from one `_derivative` | P1/P3: a helper giving both rules from one derivative |
| `class BinaryOperation()` | element-wise binary; broadcasting, vmap alignment | P1: shared broadcast rule (**have** for add/sub/mul) |
| `class ReduceOperation()` | reductions; keepdims; all-reduce when sharded | P1: shared reduction rule |
| `class AxisOp()` | ops with an axis kwarg; vmap offset | P1/P4 |
| `class ShapeOp()` | pure view ops; vmap prepends batch dims | P1/P4 |
| `class CreationOperation()` | creation ops; leaves, VJP `None` | P1 |
| `class CollectiveOperation()` | cross-mesh communication; ring cost model | out |
| `ensure_tensor(x) -> Tensor` | lift scalars and arrays to constants | P1 `T.scalar`, `T.fromList` |

### A.22 nn: modules (nn/modules)

| Nabla | Meaning | Elm |
|---|---|---|
| `class Module()` with `forward`, `backward(loss, gradient=None, retain_graph=False, create_graph=False, *, realize_grads=None)`, `parameters`, `named_parameters(prefix='')`, `buffers`, `named_buffers(prefix='')`, `modules`, `register_buffer(name, tensor)`, `state_dict`, `load_state_dict(state_dict)`, `train`, `eval`, `zero_grad`, `extra_repr` | PyTorch-style module base | P3 by convention: a `Param` description + an `apply` function; `parameters`/`state_dict` = `Param.toList`/the packed block (**have**); `backward`, `zero_grad`, `register_buffer` n/a; `train`/`eval` = a `training` argument |
| `class Linear(in_features, out_features, bias=True, *, dtype=float32)`, `forward(x)` | x @ W + b | P3 `Nn.Linear.params in out`, `.apply` (MNIST's layers are this) |
| `class LayerNorm(normalized_shape, eps=1e-05, elementwise_affine=True, *, dtype=float32)`, `forward(x)` | layer normalisation | P3 `Nn.LayerNorm` |
| `class Dropout(p=0.5)` | dropout | P3 `Nn.Dropout` (key, training) |
| `class Embedding(num_embeddings, embedding_dim, *, dtype=float32)`, `forward(indices)` | row lookup | P3 `Nn.Embedding` |
| `class MultiHeadAttention(d_model, num_heads, dropout=0.0, bias=True, *, dtype=float32)`, `forward(query, key, value, attn_mask=None, is_causal=False)` | multi-head attention | P3 `Nn.MultiHeadAttention` |
| `class TransformerEncoderLayer(d_model, num_heads, dim_feedforward=2048, dropout=0.1, *, dtype=float32)`, `forward(src, src_mask=None, is_causal=False)` | pre-norm encoder block | P3 `Nn.TransformerEncoderLayer` |
| `class TransformerDecoderLayer(d_model, num_heads, dim_feedforward=2048, dropout=0.1, *, dtype=float32)`, `forward(tgt, memory, tgt_mask=None, memory_mask=None, is_causal=False)` | pre-norm decoder block | P3 `Nn.TransformerDecoderLayer` |
| `class Sequential(*args)` | chain of modules | P3 `Nn.sequential` (layers of one type) or function composition |
| `class ReLU()`, `GELU()`, `Sigmoid()`, `Tanh()`, `SiLU()`, `Softmax(axis=-1)` | activation modules | n/a: the functions are values (`T.relu`) |

### A.23 nn: functional (nn/functional)

| Nabla | Meaning | Elm |
|---|---|---|
| `linear(x, weight, bias=None) -> Tensor` | x @ weight + bias | P2 `Nn.linear` |
| `layer_norm(x, weight=None, bias=None, eps=1e-05, axis=-1) -> Tensor` | layer norm over one or more axes | P2 `Nn.layerNorm` (MAX has `layer_norm`) |
| `dropout(x, p=0.5, training=True) -> Tensor` | inverted dropout; identity when not training | P2 `Nn.dropout key p training` |
| `embedding(indices, weight) -> Tensor` | (*) ints → (*, dim) rows | P2 `Nn.embedding` (= `gather` on axis 0) |
| `scaled_dot_product_attention(query, key, value, attn_mask=None, dropout_p=0.0, is_causal=False, training=True) -> Tensor` | softmax(QKᵀ/√d + mask) V; additive mask; causal option | P2 `Nn.attention` |
| `mse_loss(predictions, targets) -> Tensor` | mean squared error | P2 `Nn.mseLoss` |
| `cross_entropy_loss(logits, targets, axis=-1) -> Tensor` | targets one-hot, or class indices when rank is one lower | **have** `T.crossEntropy` (one-hot); P2 `Nn.crossEntropy` with indices (check the reduction: mean or sum) |
| `xavier_normal(shape, *, dtype=float32, device=None) -> Tensor` | Glorot normal init | P2 `Param.xavierNormal` (host-side init, like `Param.weights`) |
| `he_normal(shape, *, dtype=float32, device=None) -> Tensor` | He normal init | P2 `Param.heNormal` (**have** He-uniform as `Param.weights`) |

### A.24 nn: optimizers (nn/optim)

| Nabla | Meaning | Elm |
|---|---|---|
| `class Optimizer(params)`, `step(self, grads=None)` | stateful base | n/a; **have** `Train.Optimizer` (a value) |
| `class SGD(params, *, lr, momentum=0.0, weight_decay=0.0)`, `step(grads=None)` | stateful SGD | via `Train.sgd` |
| `class AdamW(params, *, lr, betas=(0.9, 0.999), eps=1e-08, weight_decay=0.0)`, `step(grads=None)` | stateful AdamW | via `Optim.adamW` |
| `sgd_step(param, grad, momentum_buffer=None, *, lr, weight_decay=0.0, momentum=0.0) -> (new_param, new_momentum_buffer)` | one parameter | P2, inside `Optim.sgd` |
| `adamw_step(param, grad, m, v, step, *, lr, beta1=0.9, beta2=0.999, eps=1e-08, weight_decay=0.0, bias_correction=True) -> (param, m, v)` | one parameter | P2, inside `Optim.adamW` |
| `sgd_update(params, grads, state=None, *, lr, momentum=0.0, weight_decay=0.0) -> (params, state)` | whole tree | **have** `Train.sgd rate` (no momentum, no decay); P2 options |
| `adamw_init(params) -> dict` | zero moments, step 0 | P2: the optimizer state's initial block (host side, like `Param.initial`) |
| `adamw_update(params, grads, state, *, lr, weight_decay=0.0, beta1=0.9, beta2=0.999, eps=1e-08, bias_correction=True, realize=None) -> (params, state)` | whole tree | P2 `Optim.adamW`; `Train.step` gains state inputs/outputs |

### A.25 nn: fine-tuning (nn/finetune: lora, qlora, checkpoint)

| Nabla | Meaning | Elm |
|---|---|---|
| `init_lora_adapter(weight, rank: int, init_std=0.01, dtype=None) -> dict[str, Tensor]` | A (in, rank) Gaussian, B (rank, out) zero | P5 `Lora.params weightShape rank` |
| `lora_delta(adapter, alpha=1.0) -> Tensor` | (alpha / rank) · A @ B | P5 `Lora.delta` |
| `lora_linear(x, frozen_weight, adapter, alpha=1.0) -> Tensor` | frozen path + adapter path | P5 `Lora.linear` |
| `merge_lora_weight(frozen_weight, adapter, alpha=1.0) -> Tensor` | W + delta | P5 `Lora.merge` |
| `unmerge_lora_weight(merged_weight, adapter, alpha=1.0) -> Tensor` | W − delta | P5 `Lora.unmerge` |
| `tree_lora_delta(adapters, alpha=1.0, *, is_leaf=None) -> Any` | deltas over a tree | P5 via `Param.map` |
| `NF4_CODEBOOK()` | the NF4 codebook (the docs page shows a NumPy docstring instead of its values) | P5 constant table |
| `quantize_nf4(weight, block_size=64) -> dict[str, Any]` | 2-D weight → NF4 indices + block scales | P5 `Qlora.quantize` (host side) |
| `dequantize_nf4(qweight, *, dtype=float32) -> Tensor` | back to dense with Nabla ops | P5 `Qlora.dequantize` (`gather` + scale) |
| `qlora_linear(x, qweight, adapter, *, alpha=1.0, compute_dtype=float32) -> Tensor` | frozen NF4 weight + LoRA | P5 `Qlora.linear` |
| `save_finetune_checkpoint(path, *, lora_params, optimizer_state=None, metadata=None) -> None` | write checkpoint | host (packed blocks to files) |
| `load_finetune_checkpoint(path, *, lora_template, optimizer_template=None) -> tuple[params, state \| None, metadata]` | read checkpoint | host |

### A.26 Testing (testing/utils)

| Nabla | Meaning | Elm |
|---|---|---|
| `assert_allclose(actual, expected, *, rtol=1e-05, atol=1e-08, equal_nan=False, realize=True) -> None` | numeric closeness across Nabla/JAX/PyTorch/NumPy | P5 an elm-test helper over decoded host results (P1 needs a minimal one for §4.7) |
| `batch_realize(*objs) -> None` | realize all tensors in a tree | host |

### A.27 Mojo integration (mojo/custom_kernels)

| Nabla | Meaning | Elm |
|---|---|---|
| `call_custom_kernel(func_name: str, kernel_path: str \| Path \| list, values: TensorValue \| list, out_types: Any \| list, device=None, **kwargs) -> TensorValue \| list` | run a `@register("name")` Mojo kernel, loading its library | later: a `T.custom name outTypes inputs` op lowering to `mo.custom`, the bridge loading the kernel package |

### A.28 Pages with no API of their own

`api/index.html`, `core/index.html`, `transforms/index.html`, `ops/index.html`, `nn/index.html`,
`nn/finetune/index.html`, `testing/index.html` and `mojo/index.html` are landing pages that only
link the sections above. The site's "Getting Started" and 13 "Examples" pages were not catalogued
(no API); the examples are a source of end-to-end test programs for P2–P4.

## Appendix B. Evidence

- **Type checking** (`spikes/max/tensor-api/bad/*.elm`, errors in `bad/*.txt`). Each of these is
  refused at compile time, with the message at the faulty line in the user's vocabulary (e.g.
  `Tensor Floating F32 (R2 n Hidden)` vs `Tensor Floating F32 (R2 n Classes)`):
  - layers in the wrong order;
  - a bias with the batch dimension;
  - a bias without `rows`;
  - raw `u8` pixels into a layer;
  - `sqrt` of integer labels;
  - `argMax` over the wrong axis;
  - a per-example loss for `Train.step`;
  - a parameter shape that disagrees with its field;
  - mismatched batch sizes;
  - causal attention across two lengths;
  - a LoRA adapter with swapped dimensions;
  - a mask in arithmetic;
  - a convolution into a dense layer without flattening;
  - a reduction to the wrong shape;
  - the gradient of a non-scalar function;
  - softmax of integers;
  - an axis witness of the wrong rank.
- **Encoding of kinds.** With the dtype as a nested phantom kind (`F32 = Num (Floating B32)`),
  messages printed `Tensor (T.Num (T.Floating T.B32)) (R2 n Hidden)`. With the kind as its own
  parameter they print `Tensor Floating F32 (R2 n Hidden)` (prototypes in `/tmp/eco-typed-dsl*`).
- **MAX behaviour**: `spikes/max/mo-inventory.md`, including the compile probes.
- **Review** (§9).
- **Final run** (2026-11-11, `spikes/max/work/final-gates.sh`, after the last edits): check-tensor
  38/38; check-api refuses all 17; check-ops 328/328, and 328/328 again from bytecode; sgd 95.87%
  as bytecode and as generic text, its first 100 step losses identical to the old DSL's; adamw
  97.15%, the same after reload; stack 97.65%; cnn 98.57%; momentum 97.51%; lion 95.97%; LoRA
  97.15% → 97.54% with frozen0–3 freshly written and byte-identical to the base; the character
  model's held-out loss 1.9624 against a unigram entropy of 3.1856. Every training run carried at
  most 78,528 bytes in (78,544 for the seeded dropout stack) and 32 out.
- **P5 on the final code** (`spikes/max/work/p5-bench.sh`, then the 8-layer runs again, each with an
  empty MAX cache through `XDG_CACHE_HOME`): the numbers in §10. A first run on the warm cache
  reported a 0.0 s compile for the inlined model, a cache hit, so compile times are only quoted
  from cold runs. The 8-layer model's held-out loss after 20 steps is 3.1038 both ways. After the
  last edits to this plan, `spikes/max/work/p5-repeat.sh` reran every gate and model (the same
  results as the final run above, to the digit) and repeated the cold compiles and GPT builds.

