module EcoTensorInt64KeyTest exposing (main)

{-| Integer constants are keyed by all 64 bits: 2^60 and 2^60 + 1 (one `Float` apart from nothing)
are two constants, not one merged by structural sharing, and so are -1 and 65535 (equal in their
low 16 bits). Each pair is a graph's two outputs (plans/tensor-eval-in-elm.md, V0).
-}

-- CHECK: big: "#M.dense_array<1152921504606846976> : tensor<si64>"
-- CHECK: big: "#M.dense_array<1152921504606846977> : tensor<si64>"
-- CHECK: low: "#M.dense_array<-1> : tensor<si64>"
-- CHECK: low: "#M.dense_array<65535> : tensor<si64>"
-- CHECK: counts: (2,2)

import EcoTensorSupport exposing (constants, graphText, two64)
import Graph
import Html
import Signature as Sig
import Tensor as T


pairGraph : Int -> Int -> List String
pairGraph a b =
    Graph.build "pair" Sig.unit (Sig.pair (Sig.i64 T.scalar) (Sig.i64 T.scalar)) (\() -> ( T.int a, T.int b ))
        |> graphText
        |> constants


main =
    let
        big =
            pairGraph (two64 60) (two64 60 + 1)

        low =
            pairGraph -1 65535

        _ =
            List.map (Debug.log "big") big

        _ =
            List.map (Debug.log "low") low

        _ =
            Debug.log "counts" ( List.length big, List.length low )
    in
    Html.text "done"
