module Nn.RmsNorm exposing
    ( RmsNorm, params
    , apply, apply3
    )

{-| Root-mean-square normalisation: a layer that divides each vector of features by its root mean
square, after adding a constant to the mean square, and multiplies each feature by a weight of its
own.

The features are the elements along the last axis of the input `x`, and each vector of them is
normalised separately:

    y = x / sqrt (mean (x²) + ε) · scale

The mean is taken over the last axis, ε is `epsilon`, and `scale` holds one weight per feature.
The types tie `scale` to the last axis's tag only, so a `scale` whose length differs from that
axis's size is a build error. Unlike `Nn.LayerNorm`, it subtracts no mean and adds no bias.

For an `f16` or `bf16` `x`, everything before the multiplication by `scale` is computed in `f32`,
and the result is cast back to `x`'s dtype before it is multiplied by `scale`. An `f32` or `f64`
`x` is computed in its own dtype throughout.


# Parameters

@docs RmsNorm, params


# Applying

@docs apply, apply3

-}

import Param
import Tensor as T exposing (DType, Dim, R1, R2, R3, Tensor)
import Tensor.Internal.Expr as E exposing (Expr)
import Tensor.Internal.Ops as O
import Tensor.Internal.Prim as P
import Tensor.Internal.Types as I


{-| The parameters of one root-mean-square normalisation over `m` features of dtype `d`: the
`scale` each normalised feature is multiplied by, and the `epsilon` (ε) added to the mean square.

`params` makes `epsilon` a config field rather than a parameter. `apply` and `apply3` use the value
the record holds; `Param.config` says where a record whose `epsilon` differs from the one `params`
was given is refused.

-}
type alias RmsNorm d m =
    { scale : Tensor Float d (R1 m), epsilon : Float }


{-| Describes the parameters of a normalisation over `m` features: `scale` is a trainable field of
dtype `dt` whose first values are all 1, and `epsilon` is a config field holding `cfg.epsilon`.
-}
params : DType Float d -> { epsilon : Float } -> Dim m -> Param.Spec (RmsNorm d m)
params dt cfg m =
    Param.record RmsNorm
        |> Param.ones .scale dt (T.r1 m)
        |> Param.config .epsilon cfg.epsilon


{-| Returns `x` with each of its `n` rows normalised over its `m` features and multiplied by the
layer's `scale`.
-}
apply : RmsNorm d m -> Tensor Float d (R2 n m) -> Tensor Float d (R2 n m)
apply p x =
    I.Tensor (normalise p.epsilon (I.tensor p.scale) (I.tensor x))


{-| Returns `x` with each of its `b × n` vectors of `m` features normalised and multiplied by the
layer's `scale`, as `apply` does for each row of a matrix.
-}
apply3 : RmsNorm d m -> Tensor Float d (R3 b n m) -> Tensor Float d (R3 b n m)
apply3 p x =
    I.Tensor (normalise p.epsilon (I.tensor p.scale) (I.tensor x))


{-| Returns `x` normalised over its last axis with `epsilon` and multiplied by `scale`, a vector as
long as that axis. `scale` is given a pending axis in front for each other axis of `x`, so that the
product takes `x`'s sizes there.
-}
normalise : Float -> Expr -> Expr -> Expr
normalise epsilon scale x =
    let
        last =
            E.rank x - 1

        norm v =
            let
                inv =
                    O.unary P.Rsqrt (O.add (O.reduce P.ReduceMean last (O.square v)) (O.scalarLike epsilon v))
            in
            -- The mean removed the last axis; a pending axis there takes `v`'s size in the product.
            O.mul v (O.broadcastAxis last inv)
    in
    O.mul (O.inF32 norm x) (O.leadingAxes last scale)
