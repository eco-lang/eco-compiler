module Finetune.Lora exposing
    ( Lora, params
    , delta, apply
    , merge, unmerge
    )

{-| LoRA (low-rank adaptation) adapts a dense layer by training a small update beside its weight
rather than the weight itself. This module is the _adapter_ that makes that update: its parameters,
their description, and the functions that apply it or fold it into a weight.

The layer's weight W has shape (i, o), from `i` input features to `o` output features, as in
`Nn.Linear`. The adapter holds two factors, A of shape (i, r) and B of shape (r, o), and the update
it makes to W is (alpha / rank) · A · B. The product A · B has W's shape but a matrix rank of at
most r, and it is described by r · (i + o) numbers instead of i · o. The _rank_ is a number in the
adapter's record, which `params` sets to the size r, and _alpha_ is a constant chosen with the
adapter; the factor alpha / rank scales the product. Both are plain numbers in the adapter's record,
not tensors, so neither is trained.

`params` describes the adapter alone, with A and B both trainable. A's first values are drawn from a
normal distribution and B's are zero, so the product A · B is zero at first unless one of A's first
values is not finite, and training moves it from there. The base layer is not part of that
description. It has its own, such as `Nn.Linear.params`, whose fields are trainable unless the
description is passed to `Param.frozen`.

Besides `delta` itself, this module offers two ways to use the adapter. `apply` computes the base
layer's output and adds the update's contribution to it, without forming the (i, o) update. `merge`
adds the update to a weight, which can then serve as an ordinary `Linear`'s weight, and `unmerge`
takes it out again. The two ways agree mathematically but compute in different orders, so their
results can differ by rounding.


# Parameters

@docs Lora, params


# Applying

@docs delta, apply


# Merging

@docs merge, unmerge

-}

import Nn.Linear exposing (Linear)
import Param
import Tensor as T exposing (DType, Dim, R2, Tensor)
import Tensor.Internal.Expr as E
import Tensor.Internal.Types as I


{-| A low-rank adapter for an (i, o) weight in dtype `d`: the factors A (`a`) and B (`b`) and the
two numbers that scale their product by alpha / rank.

`params` sets `rank` to the size of `r`. A record made any other way can hold any `Int` there, but
`delta`, `apply`, `merge` and `unmerge` give a build error when it differs from the size of `a`'s
second axis, unless their result already carries one.

-}
type alias Lora d i r o =
    { a : Tensor Float d (R2 i r), b : Tensor Float d (R2 r o), alpha : Float, rank : Int }


{-| Returns the description of an adapter for an (i, o) weight in dtype `dt`, with the given `rank`,
`alpha` and `initStd`.

`a` and `b` are trainable fields, in that order. `a`'s first values are drawn as `Param.normal`
describes, with standard deviation `initStd`, and `b`'s are all 0. `alpha` and `rank` are config
fields holding the given `alpha` and the size of the given `rank`: they have no buffers, and every
record the description builds holds those values.

-}
params : DType Float d -> { rank : Dim r, alpha : Float, initStd : Float } -> Dim i -> Dim o -> Param.Spec (Lora d i r o)
params dt c i o =
    Param.record Lora
        |> Param.normal c.initStd .a dt (T.r2 i c.rank)
        |> Param.zeros .b dt (T.r2 c.rank o)
        |> Param.config .alpha c.alpha
        |> Param.config .rank (T.size c.rank)


{-| Returns the adapter's update to an (i, o) weight, (alpha / rank) · A · B, with the scale
taken from `p.alpha` and `p.rank`. A `p.rank` other than the size of A's second axis is a build
error, unless the result already carries one.
-}
delta : Lora d i r o -> Tensor Float d (R2 i o)
delta p =
    p.a |> T.matmul p.b |> T.scale (p.alpha / toFloat p.rank) |> checkRank p


{-| Returns `t`, failed with a build error when `p.rank` differs from the size of `p.a`'s second
axis, unless `t` already carries a build error.
-}
checkRank : Lora d i r o -> Tensor Float d s -> Tensor Float d s
checkRank p t =
    case T.shapeOf p.a of
        [ _, r ] ->
            if r == p.rank || E.poisoned (I.tensor t) then
                t

            else
                I.Tensor (E.failWith ("Lora: the rank field is " ++ String.fromInt p.rank ++ ", but A has " ++ String.fromInt r ++ " columns") (I.tensor t))

        _ ->
            t


{-| Returns `base` applied to the `n` rows of `x`, as `Nn.Linear.apply` computes it (x · weight +
bias), plus the adapter's contribution (alpha / rank) · x · A · B.

`x` is multiplied by A first, so the contribution goes through an (n, r) intermediate and the
(i, o) update is never formed. A `p.rank` other than the size of A's second axis is a build
error, as in `delta`. Applying `merge p base.weight` with the same bias gives the same
result mathematically, but can differ from this one by rounding.

-}
apply : Linear d i o -> Lora d i r o -> Tensor Float d (R2 n i) -> Tensor Float d (R2 n o)
apply base p x =
    x |> Nn.Linear.apply base |> T.plus (x |> T.matmul p.a |> T.matmul p.b |> T.scale (p.alpha / toFloat p.rank)) |> checkRank p


{-| Returns the weight `w` with the adapter's update, `delta p`, added.
-}
merge : Lora d i r o -> Tensor Float d (R2 i o) -> Tensor Float d (R2 i o)
merge p w =
    w |> T.plus (delta p)


{-| Returns the weight `w` with the adapter's update, `delta p`, subtracted. Given the adapter that
`merge` added, this recovers the original weight up to rounding wherever the merged weight `w` is
finite.
-}
unmerge : Lora d i r o -> Tensor Float d (R2 i o) -> Tensor Float d (R2 i o)
unmerge p w =
    w |> T.minus (delta p)
