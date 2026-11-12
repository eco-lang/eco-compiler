module Nn.LayerNorm exposing
    ( LayerNorm, params
    , apply, apply3
    )

{-| Layer normalisation over the last axis, with a learnt gain and bias (MAX's `layer_norm`).


# Parameters

@docs LayerNorm, params


# Applying

@docs apply, apply3

-}

import Param
import Tensor as T exposing (DType, Dim, R1, R2, R3, Tensor)
import Tensor.Internal.Ops as O
import Tensor.Internal.Types as I


{-| Per-feature `gain` and `bias` over `m` features, and the `epsilon` added to the variance.
-}
type alias LayerNorm d m =
    { gain : Tensor Float d (R1 m), bias : Tensor Float d (R1 m), epsilon : Float }


{-| Gain ones, bias zeros, epsilon 1e-5.
-}
params : DType Float d -> Dim m -> Param.Spec (LayerNorm d m)
params dt m =
    Param.record LayerNorm
        |> Param.ones .gain dt (T.r1 m)
        |> Param.zeros .bias dt (T.r1 m)
        |> Param.config .epsilon 1.0e-5


{-| Each row (n, m) normalised over its `m` features.
-}
apply : LayerNorm d m -> Tensor Float d (R2 n m) -> Tensor Float d (R2 n m)
apply p x =
    I.Tensor (O.layerNorm p.epsilon (I.tensor x) (I.tensor p.gain) (I.tensor p.bias))


{-| The same over a batch of sequences.
-}
apply3 : LayerNorm d m -> Tensor Float d (R3 b n m) -> Tensor Float d (R3 b n m)
apply3 p x =
    I.Tensor (O.layerNorm p.epsilon (I.tensor x) (I.tensor p.gain) (I.tensor p.bias))
