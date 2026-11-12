module EcoTensorEvalU64Test exposing (main)

{-| `Tensor.Eval` on u64 around 2^63, where the `Int` holding the bits turns negative
(plans/tensor-eval-in-elm.md, E2): unsigned comparison, `argMax` and `maximumAll`, `modBy`, and
conversions to and from floats.
-}

-- CHECK: greater: Ok [True,False]
-- CHECK: argMax: Ok [1]
-- CHECK: maximum: Ok [-1]
-- CHECK: mod: Ok [5,9223372036854775807]
-- CHECK: toFloat: Ok [True,True]
-- CHECK: fromFloat: Ok [-4611686018427387904]

import EcoTensorSupport exposing (two64)
import Html
import Tensor as T
import Tensor.Axis as Axis
import Tensor.Eval as Eval


type N
    = N


main =
    let
        two =
            T.r1 (T.dim N 2)

        three =
            T.r1 (T.dim N 3)

        top =
            two64 63

        _ =
            Debug.log "greater" (Eval.mask (T.fromList T.uint64 two [ top, 1 ] |> T.greaterThan (T.fromList T.uint64 two [ 1, top ])))

        _ =
            Debug.log "argMax" (Eval.ints (T.fromList T.uint64 three [ 1, top, 5 ] |> T.argMax Axis.last1))

        _ =
            Debug.log "maximum" (Eval.ints (T.maximumAll (T.fromList T.uint64 three [ 1, -1, top ])))

        _ =
            Debug.log "mod" (Eval.ints (T.fromList T.uint64 two [ -1, -1 ] |> T.modBy (T.fromList T.uint64 two [ 10, top ])))

        _ =
            Debug.log "toFloat"
                (Eval.floats (T.fromList T.uint64 two [ top, -1 ] |> T.cast T.float64)
                    |> Result.map (List.map2 (==) [ 2 ^ 63, 2 ^ 64 ])
                )

        _ =
            Debug.log "fromFloat" (Eval.ints (T.constant T.float64 (1.5 * 2 ^ 63) |> T.cast T.uint64))
    in
    Html.text "done"
