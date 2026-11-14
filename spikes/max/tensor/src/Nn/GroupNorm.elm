module Nn.GroupNorm exposing
    ( GroupNorm, params
    , apply
    )

{-| Group normalisation of images: each image is normalised by statistics of its own, taken over
groups of its channels, and never by statistics of the other images in its batch, so one image's
result does not depend on the rest of the batch.

Images here are NHWC: rank-4 tensors of (images, height, width, channels). The `c` channels are
split into `groups` _groups_ of `c / groups` consecutive channels, in their order on the last axis:
group `g` holds channels `g * c / groups` up to, but not including, `(g + 1) * c / groups`. Within
one image, each group is normalised over all of its positions and all of its channels together:
its mean is subtracted, and the difference is multiplied by `1 / sqrt (variance + epsilon)`, where
the variance is the mean of the squared differences (divided by the number of elements, not by one
less). Each channel is then multiplied by its own `scale` and shifted by its own `bias`.

For an `f16` or `bf16` image, the normalisation is computed in `f32` and its result cast back to the
image's dtype; the scale and bias are then applied in the image's dtype.


# Parameters

@docs GroupNorm, params


# Applying

@docs apply

-}

import Param
import Tensor as T exposing (DType, Dim, R1, R4, Tensor)
import Tensor.Internal.Expr as E exposing (Expr)
import Tensor.Internal.Ops as O
import Tensor.Internal.Prim as P
import Tensor.Internal.Types as I


{-| The scale, bias, group count and epsilon of one group normalisation over `c` channels of dtype
`d`.

`groups` is the number of groups the channels are split into, not the number of channels in each.
`epsilon` is added to each group's variance before the square root is taken.

-}
type alias GroupNorm d c =
    { scale : Tensor Float d (R1 c), bias : Tensor Float d (R1 c), groups : Int, epsilon : Float }


{-| Describes a `GroupNorm` over `c` channels of dtype `dt`, with `groups` and `epsilon` taken from
`cfg`.

`scale` and `bias` are trainable, `scale` starting at 1 and `bias` at 0, so with its first values
the layer only normalises. `groups` and `epsilon` are config fields: values fixed by the
description, with no buffer, never trained. Nothing here checks `groups`; `apply` does.

-}
params : DType Float d -> { groups : Int, epsilon : Float } -> Dim c -> Param.Spec (GroupNorm d c)
params dt cfg c =
    Param.record GroupNorm
        |> Param.ones .scale dt (T.r1 c)
        |> Param.zeros .bias dt (T.r1 c)
        |> Param.config .groups cfg.groups
        |> Param.config .epsilon cfg.epsilon


{-| Returns each image of `x` normalised group by group, then scaled and shifted channel by channel,
as `p` gives.

It is a build error when `p.groups` is less than 1 or does not divide the size of `x`'s last axis.

-}
apply : GroupNorm d c -> Tensor Float d (R4 n h w c) -> Tensor Float d (R4 n h w c)
apply p x =
    I.Tensor (groupNorm p.groups p.epsilon (I.tensor p.scale) (I.tensor p.bias) (I.tensor x))


{-| Returns the group normalisation of the NHWC expression `x` by `groups` groups, with `epsilon`,
`scale` and `bias`, or `x` with a build error when `x` is not rank 4, or when `groups` is less than
1 or does not divide its channel count.

Both checks record the error on `x` itself with `failWith`, which records nothing on an `x` that
has already failed, so that `x`'s own error is the one reported.

-}
groupNorm : Int -> Float -> Expr -> Expr -> Expr -> Expr
groupNorm groups epsilon scale bias x =
    case E.shape x of
        [ n, h, w, c ] ->
            if groups <= 0 then
                E.failWith ("GroupNorm: " ++ String.fromInt groups ++ " groups, but there must be at least 1") x

            else if modBy groups c /= 0 then
                E.failWith ("GroupNorm: " ++ String.fromInt groups ++ " groups do not divide " ++ String.fromInt c ++ " channels") x

            else
                let
                    -- [n, positions, group, channel in group]; statistics over axes 1 and 3
                    stat v =
                        O.reduce P.ReduceMean 1 (O.reduce P.ReduceMean 3 v)
                            |> O.broadcastAxis 1
                            |> O.broadcastAxis 3

                    norm v =
                        let
                            r =
                                O.reshape [ n, h * w, groups, c // groups ] v

                            centred =
                                O.sub r (stat r)

                            inv =
                                O.unary P.Rsqrt (O.add (stat (O.square centred)) (O.scalarLike epsilon centred))
                        in
                        O.reshape [ n, h, w, c ] (O.mul centred inv)
                in
                O.add (O.mul (O.inF32 norm x) (O.leadingAxes 3 scale)) (O.leadingAxes 3 bias)

        _ ->
            E.failWith "GroupNorm: needs an NHWC tensor" x
