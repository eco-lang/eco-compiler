---
status: done
updated: 2026-11-11
---

# Plan: a textbook-style tensor DSL for the MAX spike

The MNIST spike (`spikes/max/mnist`) describes its network through `Graph.elm`, a tape whose
builders take the graph last and return `( Graph, Ref )`. Every step threads the tape by hand
(`g0` … `g10`), so the network is lost in bookkeeping: the forward pass is 20 lines for six
operations. Nabla (a Mojo/MAX autodiff library) reads like the textbook instead:
`relu(input @ weight + bias)`, `loss.backward()`. This plan gives the spike that feel in Elm,
keeping the static, whole-graph compile that MAX needs and adding Elm's type checker.

**Read before coding:** `spikes/max/README.md`, `plans/mlir-bytecode-to-max.md`,
`spikes/max/mnist/src/Graph.elm` and `Mnist.elm`.

## 1. Decision: tensors are values; the tape stays as the back end

- **`Tensor t`** (new `Tensor.elm`) is an immutable expression: an operation and the tensors it
  reads. Operations are plain functions (`relu : Tensor F32 -> Tensor F32`), so nothing is
  threaded; pipelines read left to right: `x |> matmul w1 |> plus b1 |> relu`.
- **`Tensor.graph`** walks back from the named outputs and lowers the expressions onto the existing
  `Graph` tape. `Graph`'s shape inference, its checks, `grad`, `print`, `toModule` and `MlirBc` stay
  as they are: the DSL is a front end, not a second implementation.
- **Sharing.** A tensor used twice must become one node. Each tensor carries a structural key, a
  pair of 31-bit hashes built when it is made from its operation and its operands' keys, so
  lowering memoises by key: linear in the graph, never a tree walk, and deterministic. Equal keys
  mean equal expressions (pure operations), so this is also common-subexpression elimination.
- **dtype as a phantom type.** `Tensor F32`, `Tensor U8`, `Tensor I64`, `Tensor Bool`: binary
  operations need equal dtypes, so `matmul` of raw `u8` pixels by an `f32` weight is an Elm compile
  error. Shapes stay values (Elm has no type-level numbers); `Graph` checks them when the graph is
  lowered, and `Tensor.graph` returns `Err` before MAX sees anything, as today.
- **Autodiff.** `grad loss wrt` returns placeholder tensors; lowering resolves each group with one
  `Graph.grad` call, so the existing rules (including the softmax-cross-entropy rule) are reused.
- **Parameters** (new `Param.elm`), described once in the style of `elm/json` decoders:
  `Param.record Params |> Param.weights "w1" .w1 [ 784, 128 ] |> Param.zeros "b1" .b1 [ 128 ] ...`.
  One description gives the graph inputs, the SGD update and its `_next` outputs, the host specs,
  the packed byte layout and the initial values (He-uniform weights, zero biases, the same LCG).
- **Building at run time** is free: a graph is a pure function of its arguments, so it can depend
  on flags; identical graphs give identical bytes, which MAX's cache keys on. Each op is not run
  eagerly (a cold MAX compile is about 20 s per new graph).

Not in Elm's reach: user-defined operators (`@`, `+`) and in-place updates (`weight -= ...`);
pipelines and returned parameters stand in. The training loop stays an Elm program (TEA); a
`Train` module hiding the ports is a later step.

## 2. API sketch

```elm
network : Params (Tensor F32) -> Tensor U8 -> Tensor F32
network p pixels =
    pixels
        |> T.toFloat |> T.scale (1 / 255)
        |> T.matmul p.w1 |> T.plus p.b1 |> T.relu
        |> T.matmul p.w2 |> T.plus p.b2

trainStep =
    let
        p = Param.inputs params
        x = T.input "x" T.u8 [ batchSize, 784 ]
        y = T.input "y" T.u8 [ batchSize ]
        loss = network p x |> T.crossEntropy (T.oneHot 10 y)
    in
    T.graph "train_step"
        (Param.list params p ++ [ T.any x, T.any y ])
        (Param.sgd learningRate loss params p ++ [ ( "loss", loss ) ])
```

`T.graph name inputs outputs` takes the inputs in order (the host's byte layout is positional) and
checks that every input the outputs reach is listed, that every listed tensor is an input, and that
input names are unique. The result carries the `Graph` tape plus the host's input and output specs,
so `Mnist.elm` no longer writes the specs by hand.

## 3. Lowering order

Lowering is a post-order walk (operands left to right) from the outputs in order, after the listed
inputs. Written as in §2, the MNIST graphs lower to the same tape order as the hand-threaded code,
so the bytecode should be **byte-identical** to the current one: the strongest check that the DSL
changes nothing.

## 4. Validation

1. `make run-mnist` with `FORMAT=bytecode`, `generic` and `text`: graph files identical to the
   baseline from the current code (saved to `/tmp/eco-tensor-dsl/baseline/`), and the expected run:
   14.78% untrained, then 92.52, 94.31, 95.24, 95.60, 95.87%, mean train loss 0.4225 → 0.1334.
2. `make check-bytecode` passes.
3. A deliberately wrong graph (a bias with a batch dimension; an unlisted input) is refused by
   `Tensor.graph` with a readable error; a dtype mismatch fails to compile in Elm.
4. Line counts of the graph code before and after.

## 5. Results (2026-11-11)

Done as designed: `Tensor.elm` (the DSL and its lowering), `Param.elm` (parameter descriptions),
`Mnist.elm` rewritten on them; `Graph.elm` gains `dtypeOf`, exposes `negative`, and its shape errors
name the shapes.

- **Byte-identical graphs.** For all three formats, both graphs are identical to the baseline from
  the hand-threaded code, so MAX's cache hit (0.0 s compiles) and the run is exact: 14.78%
  untrained, then 92.52, 94.31, 95.24, 95.60, 95.87%; mean train loss 0.4225 → 0.1334.
  `check-bytecode` passes (60 and 21 lines).
- **Errors.** A bias of shape `[10]` on a 128-unit layer: `bad_bias: node 4: add: shapes [100, 128]
  and [10] do not broadcast`. An input the outputs use but the list omits: `the outputs use input
  w, which is not in the input list`. A non-input in the list: `input 2 is not made by
  Tensor.input`. `u8` pixels piped into `matmul` with an `f32` weight: an Elm `TYPE MISMATCH`
  (`T.Tensor T.U8` where `T.Tensor T.F32` is expected). Scratch programs in `/tmp/eco-tensor-dsl/`.
- **Size.** The graph code (parameters, network, both graphs) is 59 non-blank lines against 119;
  the hand-written host specs (now `inputSpecs`/`outputSpecs`) and the initialisation code (now
  `Param.initial`) are gone from `Mnist.elm` too.
- Errors from `Graph` still name tape nodes (`node 4`), not source positions; a later step could
  carry a label on each tensor.

Next steps, not planned: a `Train` module hiding the ports loop (`Train.program { params, loss,
optimizer, data }`); more operations and gradient rules as networks need them; source labels in
errors.
