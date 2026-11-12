module EcoTensorRangeTextTest exposing (main)

{-| `arange` writes its bounds exactly beyond 2^53: start 2^60, end 2^60 + 3 and step 1 for three
elements (plans/tensor-eval-in-elm.md, V0). Before V0 the bounds went through `toFloat`.
-}

-- CHECK: const: "#M.dense_array<1152921504606846976> : tensor<si64>"
-- CHECK: const: "#M.dense_array<1152921504606846979> : tensor<si64>"
-- CHECK: const: "#M.dense_array<1> : tensor<si64>"

import EcoTensorSupport exposing (constants, graphText, two64)
import Graph
import Html
import Signature as Sig
import Tensor as T


type N
    = N


main =
    let
        graph =
            Graph.function "r" Sig.unit (\() -> T.arange { start = two64 60, step = 1 } (T.dim N 3))

        _ =
            List.map (Debug.log "const") (constants (graphText graph))
    in
    Html.text "done"
