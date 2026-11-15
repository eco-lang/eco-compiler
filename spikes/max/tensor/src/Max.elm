module Max exposing
    ( toBytecode, toGenericText
    , Device(..), toBytecodeOn, toGenericTextOn
    )

{-| Modular MAX compiles a graph given to it as an _MLIR_ module, and this module writes a built
`Graph` as one. MLIR is a compiler framework in which a program is a tree of operations, each named
after the _dialect_ it belongs to, as `mo.graph` belongs to `mo`. The module is written either as
MLIR bytecode, a binary form, or as MLIR's generic op text, the same module as text that a person
can read and MLIR can parse.

`Graph.build` has already checked the graph and translated it into operations of MAX's graph
dialects, `mo` and `rmo`, so what is left here is to place those operations on a device and write
them, which the-sett/elm-mlir does. The bytecode is version 4 of MLIR's bytecode format, which the
MLIR inside MAX 26.7.0 reads (it reads every version up to 6).

_Placing_ the operations for a GPU writes into them where their tensors live; placing them for the
CPU writes no device into them. Placing for the CPU cannot fail, so `toBytecode` and
`toGenericText` write for the CPU and return no `Result`. Placing for a GPU can fail. A GPU with a
negative index is refused with one message, before any operation is looked at. Otherwise some
operations are not written for a GPU, and a graph holding any of them is refused with one message
for each such operation. They are a top-k along any axis but the last (from `Tensor.topK`,
`bottomK` or `sort`), and the operations of every `cond` and every `whileLoop` (`Tensor.Control`),
wherever in the graph they appear. One call can give several: the gradient of a `cond` adds
another, and under `Transform.vmap` a `cond` or `whileLoop` that reads the batch is written once
per example.

What is written depends on the graph and the device alone, so writing one graph twice gives the
same bytes. The bytes hold the graph's name and the names, dtypes and shapes of its inputs and
outputs, but not their roles (`Graph.Role`), so not which of them are resident or the buffers they
name.

`Max.Session` compiles and runs graphs, and on its host backend it sends what this module writes.


# For the CPU

@docs toBytecode, toGenericText


# For a device

@docs Device, toBytecodeOn, toGenericTextOn

-}

import Bytes exposing (Bytes)
import Graph exposing (Graph)
import Tensor.Internal.Device as Device
import Tensor.Internal.Ir as Ir
import Tensor.Internal.Types as I


{-| Writes the graph as MLIR bytecode, placed for the CPU.

Two graphs that differ only in the roles of their inputs or outputs write the same bytes.

-}
toBytecode : Graph -> Bytes
toBytecode (I.Graph g) =
    Ir.encode (cpuOps g.ops)


{-| Writes the module `toBytecode` writes as MLIR's generic op text: each operation with its quoted
name, its operands, its regions, its attributes and its types, the one text form MLIR reads for an
operation of any dialect.
-}
toGenericText : Graph -> String
toGenericText (I.Graph g) =
    Ir.printGeneric (cpuOps g.ops)


{-| Returns `ops` placed for the CPU. Placing for the CPU never fails, so the fallback to the
unplaced `ops` is never taken.
-}
cpuOps : List Ir.Op -> List Ir.Op
cpuOps ops =
    Device.place Device.Cpu ops |> Result.withDefault ops


{-| The device a graph is written for.

`Cpu` is the CPU. Writing a graph for it never fails.

`Gpu n` is the GPU with index `n`, and the index is written into the graph as given.
`toBytecodeOn` and `toGenericTextOn` refuse a negative `n`; nothing checks that a GPU with a
non-negative `n` exists.

-}
type Device
    = Cpu
    | Gpu Int


{-| Returns the device `Tensor.Internal.Device.place` takes for `d`, with the same GPU index.
-}
internal : Device -> Device.Device
internal d =
    case d of
        Cpu ->
            Device.Cpu

        Gpu n ->
            Device.Gpu n


{-| Writes the graph as MLIR bytecode, placed for the given device, or returns why it cannot be
placed there.

For `Gpu n`, the graph's inputs and the tensors its operations compute, constants included, are
placed on GPU `n`, except values such as shapes and axes that other operations read as operands,
which stay on the CPU. A negative `n` gives `Err` with one message, "Max: there is no GPU with the
negative index n", and no other. Otherwise the result is `Err` when the graph holds a top-k along
any axis but the last (from `Tensor.topK`, `bottomK` or `sort`), a `cond` or a `whileLoop`,
anywhere in it, with one message for each MLIR operation refused, naming it.

`toBytecodeOn Cpu g` is always `Ok (toBytecode g)`.

-}
toBytecodeOn : Device -> Graph -> Result (List String) Bytes
toBytecodeOn d (I.Graph g) =
    place d g.ops |> Result.map Ir.encode


{-| Writes the graph, placed for the given device, as MLIR's generic op text (see `toGenericText`),
or returns the refusals `toBytecodeOn` returns.
-}
toGenericTextOn : Device -> Graph -> Result (List String) String
toGenericTextOn d (I.Graph g) =
    place d g.ops |> Result.map Ir.printGeneric


{-| Returns `ops` placed for `d`, or the refusals `Tensor.Internal.Device.place` gives. For a GPU
with a negative index it returns instead the one message "Max: there is no GPU with the negative
index n", without placing the ops.
-}
place : Device -> List Ir.Op -> Result (List String) (List Ir.Op)
place d ops =
    case d of
        Gpu n ->
            if n < 0 then
                Err [ "Max: there is no GPU with the negative index " ++ String.fromInt n ]

            else
                Device.place (internal d) ops

        Cpu ->
            Device.place (internal d) ops
