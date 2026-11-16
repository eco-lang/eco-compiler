# eco-lab/tensor

Write neural networks, their training and their inference in Elm, as typed tensor graphs that
Modular MAX can compile and run on a CPU or a GPU, or that run in plain Elm for tests and small
examples. A tensor's type carries its element type, its dtype and the named axes of its shape, so
mixing up axes, ranks or dtypes is a compile error, and the sizes the types cannot hold are checked
as the graph is built, before anything runs it.

```sh
elm install eco-lab/tensor
```

## The idea

A tensor is a description of a computation, not its elements. Making one works out its shape and
dtype but computes no element values; those are computed only when it is run, by MAX or by
`Tensor.Eval`.

A tensor's type, `Tensor kind dtype shape`, has three parameters. The _kind_ is the Elm type of its
elements, `Float` or `Int`. The _dtype_ is a tag such as `F32`, `BF16`, `I64` or `U8`. The shape is
a _rank type_, `R0` to `R5`, which fixes the number of axes and gives each a _tag_: a type you
declare, such as `type Batch = Batch`, that names an axis without giving its size. So
`Tensor Float F32 (R2 Batch Hidden)` is a matrix of `f32` elements whose rows are tagged `Batch`.

Sizes are not in the types: they are held by `Dim` values, such as `T.dim Batch 64`. An operation
whose operands do not fit in size still gives a tensor, but one carrying a _build error_ that says
what did not fit. `Graph.build` returns either a `Graph` or the list of what it found wrong, which
can include build errors.

A built `Graph` can be run in two ways:

- **on MAX**: `Max` writes it as MLIR bytecode or text, for the CPU or a GPU, and `Max.Session`
  compiles and runs it there, through a host program the application is linked with.
- **in plain Elm**: `Tensor.Eval` computes it with ordinary Elm arithmetic, wherever Elm runs.
  This suits small graphs: tests that check values, examples, a page in the browser.

## Getting started

A classifier of 28 × 28 images into 10 classes, and the graph that trains it:

```elm
import Graph exposing (Graph)
import Nn
import Nn.Linear as Linear exposing (Linear)
import Optim
import Param
import Signature as Sig
import Tensor as T exposing (F32, R2, Tensor, U8)
import Train


type Batch = Batch
type Pixels = Pixels
type Hidden = Hidden
type Classes = Classes

batch = T.dim Batch 64
pixels = T.dim Pixels 784
hidden = T.dim Hidden 128
classes = T.dim Classes 10


type alias Params =
    { l1 : Linear F32 Pixels Hidden
    , l2 : Linear F32 Hidden Classes
    }


params : Param.Spec Params
params =
    Param.record Params
        |> Param.sub .l1 (Linear.params T.float32 pixels hidden)
        |> Param.sub .l2 (Linear.params T.float32 hidden classes)


network : Params -> Tensor Int U8 (R2 n Pixels) -> Tensor Float F32 (R2 n Classes)
network p images =
    images |> T.toFloat |> T.scale (1 / 255) |> Linear.apply p.l1 |> T.relu |> Linear.apply p.l2


trainStep : Result (List String) Graph
trainStep =
    Train.step params
        (Optim.adamW 1.0e-3)
        (Sig.pair (Sig.u8 (T.r2 batch pixels)) (Sig.u8 (T.r1 batch)))
        (\p ( images, labels ) -> network p images |> Nn.crossEntropyIndices labels)
```

`params` describes the parameter record once; `Param` derives from it the graph inputs that carry
the parameters, their first values and their gradient. The `Signature` says how the batch, here a
pair of tensors, becomes the graph's inputs. Handing `network` the labels where it expects images is
a compile error. Declaring the labels with 32 rows instead of 64 compiles, and `trainStep` is then
an `Err` whose messages say which sizes differ.

Each run of the graph `trainStep` builds updates the parameters. They live in _resident buffers_:
buffers that whatever runs the graph keeps from one run to the next, which an input reads and an
output with the same _resident name_ replaces. So the only inputs given with each run of this graph
are the batch's two tensors, and its only output handed back is the loss. `Train.initial` gives the
buffers' first contents as bytes; `Graph.Role` and the `Train` documentation say how the inputs and
outputs are named.

To write the graph for MAX:

```elm
Result.map Max.toBytecode trainStep                           -- for the CPU
Result.andThen (Max.toBytecodeOn (Max.Gpu 0)) trainStep  -- for a GPU
```

To compute in Elm instead, `Tensor.Eval` takes a tensor that reads no graph input, or a graph and
its inputs by name. With `Tensor.Eval` imported as `Eval` and `three` a `Dim` of size 3:

```elm
x = T.fromList T.float32 (T.r1 three) [ 1, 2, 3 ]

Eval.floats (x |> T.times x |> T.plus x)    --> Ok [ 2, 6, 12 ]
```

The `Tensor.Eval` documentation shows a whole training loop run that way.

### Writing tensor code

Functions take the tensor they act on last, so a pipeline reads left to right: `x |> minus y` is
x − y, and `x |> matmul w` is x @ w.

An element-wise operation does no implicit broadcasting. Its operands must have one shape, except
that a scalar is spread over the other operand. To add a vector `v` to every row of a matrix, make
a broadcast axis for the rows: `m |> T.plus (T.rows v)`. `Tensor` describes where a broadcast axis
may appear.

## Modules

| Module | What it provides |
|---|---|
| `Tensor` | The `Tensor` type, axis tags, dimensions and dtypes; construction, casts, element-wise functions and activations, arithmetic, comparisons and masks, linear algebra, reductions, sorting and top-k, softmax, reshaping, slicing and indexing |
| `Tensor.Axis` | Values naming the axes an operation acts on (`last1`, `axis1of2`, `swap12of4` ...), typed by the shapes before and after it |
| `Tensor.Control` | Branches and loops decided when the graph runs (`cond`, `whileLoop`), and loops of a known count written out in Elm (`repeat`, `scan`) |
| `Tensor.Random` | Random draws computed from a seed tensor: uniform, normal, Bernoulli and Gumbel, and `categorical` sampling |
| `Signature` | How a record, tuple or list of tensors corresponds to a graph's ordered inputs or outputs |
| `Graph` | Building and checking a graph; the names, dtypes, shapes and roles of its inputs and outputs |
| `Max` | Writing a graph for MAX: MLIR bytecode or generic text, for the CPU or a GPU |
| `Max.Session` | Compiling and running graphs and keeping their resident buffers, on MAX through the host or in Elm |
| `Max.Safetensors` | Reading a `.safetensors` checkpoint into a session's resident buffers |
| `Transform` | Derivatives (`grad`, `valueAndGrad`, `vjp`, `jvp`, `jacobian`, `hessianVector` ...), `vmap`, and shared subgraphs |
| `Param` | Parameter records, described once: their graph inputs, resident names, first values (computed in Elm or drawn by a graph), checkpoint import graphs and gradients |
| `Optim` | SGD, AdamW, optimizers with an update written by hand, and global-norm gradient clipping |
| `Train` | The training-step graph, a graph that evaluates a function of the parameters and a batch, and the buffers' first contents |
| `Infer` | Graphs that run a model again and again, keeping its parameters and its state, such as key/value caches, where the graph runs |
| `Nn` | Parts without parameters: losses, dropout, attention, pooling and upsampling, timestep embeddings, causal masks and repeated attention heads |
| `Nn.Linear` | Dense layers, with or without a bias |
| `Nn.LayerNorm`, `Nn.RmsNorm`, `Nn.GroupNorm` | Normalisation layers |
| `Nn.Embedding` | Token embedding tables, and `unembed`, which scores against the same table |
| `Nn.Attention` | Multi-head, grouped-query (with a key/value cache) and cross-attention layers |
| `Nn.Rotary` | Rotary position embeddings |
| `Nn.KvCache` | A fixed-size key/value cache, from which attention reads the keys and values of earlier positions |
| `Nn.FeedForward` | Gated feed-forward blocks, such as SwiGLU and GEGLU |
| `Nn.Transformer` | Pre-norm transformer encoder and decoder layers |
| `Nn.Conv2d` | 2-D convolution and transposed convolution of NHWC images |
| `Nn.Stack` | Multilayer perceptrons whose hidden widths need no axis tags |
| `Nn.Sampling` | Choosing the next token in the graph: greedy, sampled, top-k and nucleus |
| `Finetune.Lora` | LoRA adapters beside a dense layer |
| `Finetune.Qlora` | NF4-quantized frozen weights, applied together with a trained LoRA adapter (QLoRA) |
| `Tensor.Eval` | Computing tensors and graphs in plain Elm |
| `Tensor.Check` | Comparing lists of floats under a tolerance |

## Running on MAX

A `Max.Session` compiles graphs, runs them, and keeps their resident buffers from one run to the
next. The program compiles a graph into it, sends it commands (`run`, `put`, `get`, `save`,
`loadInto`, `load` ...), and reads the replies as `Event`s in its `update`. A run is given only its
fed inputs, by name, and gives back only its fed outputs. A session has two backends, and the
program's code is the same for both.

**The host backend** runs the graphs on MAX, in the C++ host `host/max_host.cpp`. Only an eco
native program can use it, because the two talk over ports that carry `Bytes`. The program declares
two ports, with exactly these names, since the host finds them by name:

```elm
port maxOut : Bytes -> Cmd msg

port maxIn : (Bytes -> msg) -> Sub msg
```

and makes its session from them:

```elm
session = Max.Session.host { send = maxOut, receive = maxIn } GotMax
```

The program, compiled by eco to a shared library, is linked with `host/max_host.cpp` and MAX's
`libmax`, and started as `max_host WORKDIR FLAGS-JSON`: compiled graphs are written to `WORKDIR`,
and `FLAGS-JSON` is the program's flags. The command `finish` ends the program with an exit code.
A program that also declares `port logOut : String -> Cmd msg` has each string it sends there
printed by the host.

**The in-Elm backend** (`Max.Session.inElm GotMax`) runs the graphs with `Tensor.Eval` and keeps the
resident buffers in the session. It needs no ports and works wherever Elm runs, in tests or in a
browser, at `Tensor.Eval`'s speed. It reads no files: `save` and `loadInto` work only over the
files the session itself saved.

### Writing graphs for MAX

`Max.toBytecode` writes MLIR bytecode, the binary form MAX's graph compiler loads, and
`toGenericText` writes the same module as text. Both are written with
`the-sett/elm-mlir`. The bytecode is
version 4 of MLIR's bytecode format, which the MLIR inside MAX 26.7.0 reads (it reads every version
up to 6).

Writing for the CPU cannot fail. Writing for a GPU (`toBytecodeOn`, `toGenericTextOn`) refuses a
graph that uses `cond` or `whileLoop`, or a top-k along any axis but the last (from `topK`,
`bottomK` or `sort`).

The bytes hold the graph's name and the names, dtypes and shapes of its inputs and outputs, but not
their roles. Whatever runs the graph can learn which ones are resident from `Graph.inputs` and
`Graph.outputs`.

## Running in Elm: `Tensor.Eval`

`Tensor.Eval` computes graphs that use gradients, `vmap`, branches, loops and shared functions. It
computes each element with ordinary Elm arithmetic, so it is not a fast way to run a large graph.
Three things about what it computes:

- **Floats** are computed as 64-bit doubles whatever their dtype, and are not rounded to it, so an
  `f32`, `f16` or `bf16` result can differ from one computed in the dtype's own precision.
- **Random draws** are not the values MAX draws for the same seed.
- **Errors** found only while computing, such as an index outside its axis or an integer `modBy 0`,
  are returned as an `Err`.

## Integers

Integer elements are given and read as Elm `Int`s. With a compiler whose `Int` has 64 bits, every
`i64` and `u64` value is held exactly. Compiled to JavaScript, an `Int` holds every integer exactly
only up to 2⁵³, so larger values, and some `Tensor.Eval` results, can come out wrong; `Tensor.Eval`
lists some of them.

A `u64` element is the `Int` with the same 64 bits, so values from 2⁶³ up are given and read as
negative `Int`s.

## Randomness

A random draw is a pure function of its seed, distribution, parameters, dtype and shape: two draws
equal in all of these are the same tensor, with the same values. Draws that should be independent
need separate seeds, which `Tensor.Random.salt` derives from one seed inside the graph.
