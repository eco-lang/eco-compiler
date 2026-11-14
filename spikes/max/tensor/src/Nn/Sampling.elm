module Nn.Sampling exposing
    ( greedy, sample
    , keepTopK, nucleus
    )

{-| Producing a sequence one token at a time means choosing each next token from a row of scores
over a vocabulary, and this module makes that choice inside the graph.

The scores are a matrix of _logits_, one row per sequence and one column per token of the
vocabulary. A row's logits are unnormalised log-probabilities: the row's softmax is the
probability of each token coming next. A _token_ is a column's position in its row, and every
function here that chooses gives one `int64` position per row.

A choice is either the most likely token (`greedy`) or a token drawn at random from the row's
probabilities (`sample`). A draw can first be confined to the likeliest tokens of the row: those
whose logits are at or above the row's `k`-th largest (_top-k_, `keepTopK`), or the _nucleus_
(_top-p_, `nucleus`), which is the smallest set of most likely tokens whose probabilities add up to
at least a given total, and the whole row when its probabilities add up to less.

Confining a draw does not shorten a row. Each logit left out is replaced by a large negative value,
far below any ordinary logit, so that it keeps no meaningful probability. That value is the lowest
finite value of the logits' dtype: `f16`, `bf16`, `f32` or `f64`.

There is no temperature parameter. Dividing the logits by a temperature first draws at that
temperature. The draws are made by `Tensor.Random.categorical`, whose module says what one seed
gives and when two draws need different seeds.


# Choosing

@docs greedy, sample


# Top-k and top-p

`keepTopK` returns logits; `nucleus` filters and draws in one step.

@docs keepTopK, nucleus

-}

import Tensor as T exposing (F32, I64, R1, R2, Tensor)
import Tensor.Axis as Axis
import Tensor.Internal.Expr as E exposing (Expr)
import Tensor.Internal.Ops as O
import Tensor.Internal.Prim as P
import Tensor.Internal.Types as I
import Tensor.Random as Random exposing (Seed)


{-| Returns, for each row of the logits, the position of its most likely token, the one with the
largest logit.
-}
greedy : Tensor Float d (R2 n v) -> Tensor Int I64 (R1 n)
greedy =
    T.argMax Axis.last2


{-| Returns, for each row of the logits, a token drawn with the seed, with the row's softmax as
its probabilities. It is `Tensor.Random.categorical`.
-}
sample : Tensor Float d (R2 n v) -> Seed -> Tensor Int I64 (R1 n)
sample =
    Random.categorical


{-| The axis tag of the `k` largest logits of each row, which `keepTopK` takes from
`Tensor.topK`.
-}
type K
    = K


{-| Returns `logits` with every logit of a row replaced by the large negative value the module
description gives, except those at or above the row's `k`-th largest.

A logit equal to the `k`-th largest is kept, so a row with ties at the `k`-th place keeps more than
`k` logits. A `k` below 1 or above the number of tokens is a build error, as for `Tensor.topK`.

-}
keepTopK : Int -> Tensor Float d (R2 n v) -> Tensor Float d (R2 n v)
keepTopK k logits =
    let
        ( values, _ ) =
            T.topK Axis.retag1of2 (T.dim K k) logits

        x =
            I.tensor logits

        threshold =
            -- Each row's k-th largest logit, with a broadcast axis that takes the row's length
            -- in `ge`.
            case E.shape (I.tensor values) of
                [ n, _ ] ->
                    O.broadcastAxis 1 (O.reshape [ n ] (O.slice [ 0, k - 1 ] [ n, 1 ] (I.tensor values)))

                _ ->
                    I.tensor values
    in
    I.Tensor (O.select (O.ge x threshold) x (O.fullLike (O.lowest (E.dtype x)) x))


{-| Returns, for each row of `logits`, a token drawn with `seed` from the row with the tokens
outside its nucleus replaced.

A token is in the nucleus when the probabilities of the tokens ranked above it, most likely first,
add up to less than `p`. The draw is made as `sample` makes it, on the row sorted most likely first
with every token outside the nucleus replaced as `keepTopK` replaces them, and the position drawn
is mapped back to the token's position in the row. Because the draw is on the sorted row, one seed
need not give the token `sample` gives, even when the nucleus holds the whole row.

For `f16` and `bf16` logits the probabilities, their running sums and the comparison with `p` are
computed in `f32`; for `f32` and `f64` logits, in the logits' dtype.

A `p` of 0 or less, or NaN, is a build error.

-}
nucleus : Float -> Tensor Float d (R2 n v) -> Seed -> Tensor Int I64 (R1 n)
nucleus p logits seed =
    let
        ( sorted, order ) =
            T.sort { descending = True } Axis.last2 logits

        s =
            I.tensor sorted

        wide : Tensor Float F32 (R2 n v)
        wide =
            if E.dtype s == P.F16 || E.dtype s == P.BF16 then
                I.Tensor (O.cast P.F32 s)

            else
                I.Tensor s

        before =
            T.cumsumWith { exclusive = True, reverse = False } Axis.last2 (T.softmax Axis.last2 wide)

        keep =
            T.lessThan (T.fullLike p before) before

        masked =
            T.select keep sorted (I.Tensor (O.fullLike (O.lowest (E.dtype s)) s))

        result =
            order |> T.pick (Random.categorical masked seed)
    in
    if isNaN p || p <= 0 then
        I.Tensor (E.failWith ("nucleus: p is " ++ String.fromFloat p ++ ", but it must be greater than 0") (I.tensor result))

    else
        result
