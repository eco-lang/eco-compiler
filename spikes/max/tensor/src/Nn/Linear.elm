module Nn.Linear exposing (Linear, params, paramsWithoutBias, apply, apply3)

{-| A dense layer: x @ weight + bias.
-}

import Param
import Tensor as T exposing (DType, Dim, Floating, R1, R2, R3, Tensor)
import Tensor.Axis as Axis


type alias Linear d i o =
    { weight : Tensor Floating d (R2 i o), bias : Tensor Floating d (R1 o) }


{-| He-uniform weights, zero biases.
-}
params : DType Floating d -> Dim i -> Dim o -> Param.Spec (Linear d i o)
params dt i o =
    Param.record Linear
        |> Param.heUniform .weight dt (T.r2 i o)
        |> Param.zeros .bias dt (T.r1 o)


{-| He-uniform weights and no bias: the bias is a constant zero, not a parameter (nothing is stored,
loaded or trained for it). The record is the same, so every layer built on `Linear` accepts it.
-}
paramsWithoutBias : DType Floating d -> Dim i -> Dim o -> Param.Spec (Linear d i o)
paramsWithoutBias dt i o =
    Param.record Linear
        |> Param.heUniform .weight dt (T.r2 i o)
        |> Param.config .bias (T.zeros dt (T.r1 o))


apply : Linear d i o -> Tensor Floating d (R2 n i) -> Tensor Floating d (R2 n o)
apply p x =
    x |> T.matmul p.weight |> T.plus (T.rows p.bias)


{-| The same over a batch of sequences.
-}
apply3 : Linear d i o -> Tensor Floating d (R3 b n i) -> Tensor Floating d (R3 b n o)
apply3 p x =
    x |> T.matmul3By2 p.weight |> T.plus (p.bias |> T.rows |> T.broadcast Axis.axis0of3)
