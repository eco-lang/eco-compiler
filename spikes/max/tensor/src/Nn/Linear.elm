module Nn.Linear exposing
    ( Linear, params, paramsWithoutBias
    , apply, apply3
    )

{-| A dense layer maps each row of `i` input features to a row of `o` output features by the affine
map x · weight + bias. This module is that layer: the record of its parameters, two descriptions of
that record (`Param.Spec` values), and the functions that apply it.

The weight has shape (i, o): its rows index the inputs and its columns the outputs, so a row of `i`
features times the weight is a row of `o` features. A weight stored the other way round, (o, i),
has to be transposed before it can be used here.

The bias is `o` values added to every output row. `params` describes it as a trainable field and
`paramsWithoutBias` as a constant zero vector. Both descriptions describe the same record type, so a
`Linear` is applied in the same way whichever of them made it.


# Parameters

@docs Linear, params, paramsWithoutBias


# Applying

@docs apply, apply3

-}

import Param
import Tensor as T exposing (DType, Dim, R1, R2, R3, Tensor)
import Tensor.Axis as Axis


{-| The weight and bias of a dense layer from `i` input features to `o` output features, in dtype
`d`.
-}
type alias Linear d i o =
    { weight : Tensor Float d (R2 i o), bias : Tensor Float d (R1 o) }


{-| Returns the description of a layer's parameters, both trainable: the weight, then the bias.

The weight's first values are drawn as `Param.heUniform` describes, with the input size `i` as the
fan-in (1 when `i` is less than 1). The bias's first values are all 0.

-}
params : DType Float d -> Dim i -> Dim o -> Param.Spec (Linear d i o)
params dt i o =
    Param.record Linear
        |> Param.heUniform .weight dt (T.r2 i o)
        |> Param.zeros .bias dt (T.r1 o)


{-| Returns the description of a layer whose only parameter is the weight, first drawn as in
`params`.

The bias is a `Param.config` field holding a zero vector of dtype `d`. Every record the description
builds holds that zero vector, so training never changes it. `apply` and `apply3` still add it. As
`Param.config` says, `Param.importGraph` does not read this field of the record its conversion
returns, so a bias supplied there is ignored.

-}
paramsWithoutBias : DType Float d -> Dim i -> Dim o -> Param.Spec (Linear d i o)
paramsWithoutBias dt i o =
    Param.record Linear
        |> Param.heUniform .weight dt (T.r2 i o)
        |> Param.config .bias (T.zeros dt (T.r1 o))


{-| Returns x · weight + bias for the `n` rows of `x`, each mapped from `i` to `o` features. The
one bias is added to every row.
-}
apply : Linear d i o -> Tensor Float d (R2 n i) -> Tensor Float d (R2 n o)
apply p x =
    x |> T.matmul p.weight |> T.plus (T.rows p.bias)


{-| Returns `apply` of each of the `b` matrices of `x`, with the one weight and bias: every row of
every matrix is mapped from `i` to `o` features.
-}
apply3 : Linear d i o -> Tensor Float d (R3 b n i) -> Tensor Float d (R3 b n o)
apply3 p x =
    x |> T.matmul3By2 p.weight |> T.plus (p.bias |> T.rows |> T.broadcast Axis.axis0of3)
