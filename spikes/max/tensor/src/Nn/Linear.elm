module Nn.Linear exposing
    ( Linear, params, paramsWithoutBias
    , apply, apply3
    )

{-| A dense layer: x @ weight + bias.


# Parameters

@docs Linear, params, paramsWithoutBias


# Applying

@docs apply, apply3

-}

import Param
import Tensor as T exposing (DType, Dim, R1, R2, R3, Tensor)
import Tensor.Axis as Axis


{-| A layer from `i` to `o` features: `weight` (i, o) and `bias` (o).
-}
type alias Linear d i o =
    { weight : Tensor Float d (R2 i o), bias : Tensor Float d (R1 o) }


{-| He-uniform weights, zero biases.
-}
params : DType Float d -> Dim i -> Dim o -> Param.Spec (Linear d i o)
params dt i o =
    Param.record Linear
        |> Param.heUniform .weight dt (T.r2 i o)
        |> Param.zeros .bias dt (T.r1 o)


{-| He-uniform weights and no bias: the bias is a constant zero, not a parameter (nothing is stored,
loaded or trained for it). The record is the same, so every layer built on `Linear` accepts it.
-}
paramsWithoutBias : DType Float d -> Dim i -> Dim o -> Param.Spec (Linear d i o)
paramsWithoutBias dt i o =
    Param.record Linear
        |> Param.heUniform .weight dt (T.r2 i o)
        |> Param.config .bias (T.zeros dt (T.r1 o))


{-| Rows of `i` features (n, i) to rows of `o` features (n, o).
-}
apply : Linear d i o -> Tensor Float d (R2 n i) -> Tensor Float d (R2 n o)
apply p x =
    x |> T.matmul p.weight |> T.plus (T.rows p.bias)


{-| The same over a batch of sequences.
-}
apply3 : Linear d i o -> Tensor Float d (R3 b n i) -> Tensor Float d (R3 b n o)
apply3 p x =
    x |> T.matmul3By2 p.weight |> T.plus (p.bias |> T.rows |> T.broadcast Axis.axis0of3)
