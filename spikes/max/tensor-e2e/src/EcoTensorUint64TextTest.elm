module EcoTensorUint64TextTest exposing (main)

{-| A u64 element is the `Int` with the same 64 bits, and the MLIR text shows its unsigned decimal:
`fromList uint64 [ -1, minInt, 5 ]` writes 2^64 − 1, 2^63 and 5 (plans/tensor-eval-in-elm.md, V0).
-}

-- CHECK: const: "#M.dense_array<18446744073709551615, 9223372036854775808, 5> : tensor<3xui64>"

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
            Graph.function "c" Sig.unit (\() -> T.fromList T.uint64 (T.r1 (T.dim N 3)) [ -1, two64 63, 5 ])

        _ =
            List.map (Debug.log "const") (constants (graphText graph))
    in
    Html.text "done"
