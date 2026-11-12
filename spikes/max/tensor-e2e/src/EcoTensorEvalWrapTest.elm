module EcoTensorEvalWrapTest exposing (main)

{-| `Tensor.Eval` wraps integers as MAX does, on native code where `Int` is 64-bit
(plans/tensor-eval-in-elm.md, E2): i64 `maxInt + 1` is `minInt`, `negate` and `abs` of `minInt`
are `minInt` (the op-check family `pins64` checks MAX does the same), products wrap mod 2^64, and
i32 and u8 wrap at their widths.
-}

-- CHECK: plus: Ok [-9223372036854775808]
-- CHECK: negate: Ok [-9223372036854775808]
-- CHECK: abs: Ok [-9223372036854775808]
-- CHECK: times: Ok [8589934593]
-- CHECK: i32: Ok [-2147483648]
-- CHECK: u8: Ok [255]
-- CHECK: sum: Ok [-9223372036854775807]

import EcoTensorSupport exposing (two64)
import Html
import Tensor as T
import Tensor.Eval as Eval


type N
    = N


main =
    let
        minInt =
            two64 63

        maxInt =
            minInt - 1

        big =
            two64 32 + 1

        _ =
            Debug.log "plus" (Eval.ints (T.int maxInt |> T.plus (T.int 1)))

        _ =
            Debug.log "negate" (Eval.ints (T.negate (T.int minInt)))

        _ =
            Debug.log "abs" (Eval.ints (T.abs (T.int minInt)))

        _ =
            Debug.log "times" (Eval.ints (T.int big |> T.times (T.int big)))

        _ =
            Debug.log "i32" (Eval.ints (T.constant T.int32 2147483647 |> T.plus (T.constant T.int32 1)))

        _ =
            Debug.log "u8" (Eval.ints (T.constant T.uint8 0 |> T.minus (T.constant T.uint8 1)))

        _ =
            Debug.log "sum" (Eval.ints (T.sumAll (T.fromList T.int64 (T.r1 (T.dim N 3)) [ maxInt, 1, 1 ])))
    in
    Html.text "done"
