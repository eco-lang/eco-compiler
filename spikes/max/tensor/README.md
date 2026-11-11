# eco-lab/tensor

Typed tensor graphs for Modular MAX, written in Elm: the API of Nabla
(<https://www.nablaml.com/api/>) as an Elm package that writes MAX's `mo` graphs directly, as MLIR
bytecode or generic text. The plan, design and results are in `plans/nabla-api-in-elm.md`.

```elm
network : Params -> Tensor Integral U8 (R2 n Pixels) -> Tensor Floating F32 (R2 n Classes)
network p images =
    images |> T.toFloat |> T.scale (1 / 255) |> Linear.apply p.l1 |> T.relu |> Linear.apply p.l2

trainStep =
    Train.step params (Optim.adamW 1.0e-3) (Sig.pair (Sig.u8 (T.r2 batch pixels)) (Sig.u8 (T.r1 batch))) <|
        \p ( x, y ) -> network p x |> Nn.crossEntropyIndices y
```

A tensor's type carries its kind (`Floating`, `Integral`), dtype and shape, a fixed rank of named
dimensions (`R2 Batch Hidden`), so mixing up dimensions, axes or dtypes is a compile error at the
faulty line; what types cannot express (a reshape's element count, a declared size) is checked when
the graph is built, before MAX sees it.

## Modules

| Module | What |
|---|---|
| `Tensor` | types, dimensions, dtypes; construction, element-wise, comparisons and masks, linear algebra, reductions, shape |
| `Tensor.Axis` | generated witnesses: which axis an operation acts on (`last2`, `axis0of3`, `retag1of2`, `liftRank1`, `swap12of4`) |
| `Signature` | two-way descriptions of structured values: graph inputs and outputs, function arguments |
| `Graph` | building, checking and writing a graph; its inputs' and outputs' specs and roles |
| `Transform` | `grad`, `valueAndGrad`, `gradOf`, `vjp`, `jvp`, `jacobian`, `hessianVector`; `vmap`; shared subgraphs |
| `Tensor.Control` | `cond` (`mo.if`), `whileLoop` (`mo.while`), `repeat`, `scan` |
| `Tensor.Random` | counter-based randomness from a seed tensor |
| `Param` | parameter records: initialisation, layouts, frozen and data fields, gradients |
| `Optim` | SGD, AdamW, element-wise custom optimizers, global-norm clipping |
| `Train` | the training step and evaluation graphs, with host-resident parameters and state |
| `Nn`, `Nn.*` | losses, dropout, attention, pooling; linear, layer-norm, embedding, attention, transformer, convolution, stacks |
| `Finetune.Lora`, `Finetune.Qlora` | LoRA adapters; NF4-quantised frozen weights |
| `Tensor.Check` | numerical comparison |

The internals (`Tensor.Internal.*`, not exposed): expressions with structural keys and value-level
shapes (`Expr`, `Shape`), the primitives (`Prim`), their gradient rules (`Vjp`), reverse mode and
tracing (`Grad`), batching rules (`Batch`), branches and loops (`Control`), shared subgraphs
(`Shared`), lowering to MAX ops (`Lower`, `Mo`) and MLIR bytecode (`MlirBc`).

## Use

An application lists `"eco-lab/tensor": "1.0.0"` among its dependencies and is built with
`--local-package eco-lab/tensor=<this directory>` (see `spikes/max/Makefile`).

## Checks (from `spikes/max`)

- `make check-tensor`: this package's tests (`tests/`, elm-test-rs).
- `make check-api`: the example programs in `../tensor-api/examples` compile against the package, and
  every program in `../tensor-api/bad` is refused.
- `make check-ops`: every operation and gradient run on MAX against NumPy (`../opcheck`);
  `make check-opcheck-bytecode` then compares the bytecode and text of every graph.
- The models: `make run-mnist MODEL=sgd|adamw|stack|cnn|lora`, `make run-charlm`.

`scripts/gen_axis.py` writes `src/Tensor/Axis.elm`; `scripts/gen_support.py` writes
`src/Tensor/Internal/Support.elm` from the dtype probe (`../capi/scripts/inventory/support_probe.py`).
