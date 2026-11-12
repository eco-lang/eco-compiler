module EcoTensorInt64TextTest exposing (main)

{-| `fromList int64` writes its values exactly into the graph's MLIR text, beyond 2^53: ±(2^62 + 1),
the most negative and the most positive `Int` (plans/tensor-eval-in-elm.md, V0). Before V0 the
values went through `Float` and came out rounded.
-}

-- CHECK: const: "#M.dense_array<4611686018427387905, -4611686018427387905, -9223372036854775808, 9223372036854775807> : tensor<4xsi64>"

import EcoTensorSupport exposing (constants, graphText, two64)
import Graph
import Html
import Signature as Sig
import Tensor as T


type N
    = N


main =
    let
        big =
            two64 62 + 1

        minInt =
            two64 63

        graph =
            Graph.function "c" Sig.unit (\() -> T.fromList T.int64 (T.r1 (T.dim N 4)) [ big, negate big, minInt, minInt - 1 ])

        _ =
            List.map (Debug.log "const") (constants (graphText graph))
    in
    Html.text "done"
