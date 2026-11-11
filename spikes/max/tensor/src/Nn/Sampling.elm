module Nn.Sampling exposing (greedy, sample, keepTopK, nucleus)

{-| Choosing the next token from logits (rows: one distribution each).
-}

import Tensor as T exposing (Floating, I64, Integral, R1, R2, Tensor)
import Tensor.Axis as Axis
import Tensor.Internal.Expr as E exposing (Expr)
import Tensor.Internal.Ops as O
import Tensor.Internal.Types as I
import Tensor.Random as Random exposing (Seed)


{-| The most likely token of each row.
-}
greedy : Tensor Floating d (R2 n v) -> Tensor Integral I64 (R1 n)
greedy =
    T.argMax Axis.last2


{-| A token drawn from each row's softmax (scale the logits by 1 / temperature first).
-}
sample : Tensor Floating d (R2 n v) -> Seed -> Tensor Integral I64 (R1 n)
sample =
    Random.categorical


{-| The module's tag for the k kept logits.
-}
type K
    = K


{-| The logits with all but each row's k largest set to the dtype's lowest finite value (logits
equal to the k-th largest are kept too).
-}
keepTopK : Int -> Tensor Floating d (R2 n v) -> Tensor Floating d (R2 n v)
keepTopK k logits =
    let
        ( values, _ ) =
            T.topK Axis.retag1of2 (T.dim K k) logits

        x =
            I.tensor logits

        threshold =
            -- the k-th largest of each row, broadcast over the row
            case E.shape (I.tensor values) of
                [ n, _ ] ->
                    O.broadcastAxis 1 (O.reshape [ n ] (O.slice [ 0, k - 1 ] [ n, 1 ] (I.tensor values)))

                _ ->
                    I.tensor values
    in
    I.Tensor (O.select (O.ge x threshold) x (O.fullLike (O.lowest (E.dtype x)) x))


{-| Nucleus (top-p) sampling: a token drawn from the smallest set of most likely tokens whose
probabilities reach `p`, renormalised.
-}
nucleus : Float -> Tensor Floating d (R2 n v) -> Seed -> Tensor Integral I64 (R1 n)
nucleus p logits seed =
    let
        ( sorted, order ) =
            T.sort { descending = True } Axis.last2 logits

        before =
            T.cumsumWith { exclusive = True, reverse = False } Axis.last2 (T.softmax Axis.last2 sorted)

        keep =
            T.lessThan (T.fullLike p before) before

        s =
            I.tensor sorted

        masked =
            T.select keep sorted (I.Tensor (O.fullLike (O.lowest (E.dtype s)) s))
    in
    order |> T.pick (Random.categorical masked seed)
