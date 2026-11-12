module EcoTensorEvalSaltTest exposing (main)

{-| A salted seed, `Random.salt 3 (Random.salt 2 s)`, computed by `Tensor.Eval` in u64 is
((s · c + 5) · c + 7) mod 2^64 with c = 25214903917, the same as wrapping `Int` arithmetic gives,
for a seed beyond 2^53 (plans/tensor-eval-in-elm.md, E2). The seed is the graph's output
(`Random.sig`).
-}

-- CHECK: salted: [5161068236832670089]
-- CHECK: same: True

import Dict
import EcoTensorSupport exposing (two64)
import Graph
import Html
import Signature as Sig
import Tensor as T
import Tensor.Eval as Eval
import Tensor.Random as Random


main =
    let
        s =
            two64 60 + 12345

        c =
            25214903917

        expected =
            (s * c + 5) * c + 7

        got =
            Graph.build "salt" Sig.unit Random.sig (\() -> Random.salt 3 (Random.salt 2 (Random.seed (T.int s))))
                |> Result.andThen (\g -> Eval.run g Dict.empty)
                |> Result.map Dict.values
                |> Result.map
                    (List.concatMap
                        (\v ->
                            case v.data of
                                Eval.Ints l ->
                                    l

                                _ ->
                                    []
                        )
                    )
                |> Result.withDefault []

        _ =
            Debug.log "salted" got

        _ =
            Debug.log "same" (got == [ expected ])
    in
    Html.text "done"
