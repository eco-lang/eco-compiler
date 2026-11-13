module Graph.Max exposing
    ( toBytecode, toGenericText
    , Device(..), toBytecodeOn, toGenericTextOn
    )

{-| A `Graph` written for Modular MAX: its `mo` dialect, as the MLIR bytecode MAX loads, or as
MLIR's generic op text to read. What carries the bytes to MAX, and how they are run there, is up to
the application.

The bytecode is MLIR's version 6, with the `mo` and `rmo` op and attribute forms of the MAX release
built on LLVM 24 (commit 8d4fc8f1d17e). `Graph.build` has already checked the graph, so writing it
for the CPU cannot fail; writing it for a GPU can, when the GPU cannot run something.


# For the CPU

@docs toBytecode, toGenericText


# For a device

@docs Device, toBytecodeOn, toGenericTextOn

-}

import Bytes exposing (Bytes)
import Graph exposing (Graph)
import Tensor.Internal.Device as Device
import Tensor.Internal.MlirBc as Bc
import Tensor.Internal.Types as I


{-| The graph as MLIR bytecode, for the CPU: what MAX's graph compiler loads.

Two graphs that write the same bytes are the same graph, which makes this the cheap way to compare
graphs (see `Graph.Graph`).

-}
toBytecode : Graph -> Bytes
toBytecode (I.Graph g) =
    Bc.encode (cpuOps g.ops)


{-| The graph `toBytecode` writes, as MLIR's generic op text (what `mlir-opt
--mlir-print-op-generic` prints, give or take spacing and value names).
-}
toGenericText : Graph -> String
toGenericText (I.Graph g) =
    Bc.printGeneric (cpuOps g.ops)


cpuOps : List Bc.Op -> List Bc.Op
cpuOps ops =
    Device.place Device.Cpu ops |> Result.withDefault ops


{-| Where a graph runs: the CPU, or GPU `n`.
-}
type Device
    = Cpu
    | Gpu Int


internal : Device -> Device.Device
internal d =
    case d of
        Cpu ->
            Device.Cpu

        Gpu n ->
            Device.Gpu n


{-| The graph written for a device. On a GPU every tensor lives on the GPU except the small operands
MAX keeps on the CPU (shapes, axes, bounds). Refused, with the reasons, when the device cannot run
something (a top-k off the last axis on a GPU). `toBytecodeOn Cpu` is `toBytecode`.
-}
toBytecodeOn : Device -> Graph -> Result (List String) Bytes
toBytecodeOn d (I.Graph g) =
    Device.place (internal d) g.ops |> Result.map Bc.encode


{-| `toBytecodeOn`, as generic op text (`toGenericText`).
-}
toGenericTextOn : Device -> Graph -> Result (List String) String
toGenericTextOn d (I.Graph g) =
    Device.place (internal d) g.ops |> Result.map Bc.printGeneric
