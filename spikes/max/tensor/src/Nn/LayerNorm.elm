module Nn.LayerNorm exposing (LayerNorm, params, apply, apply3)

{-| Layer normalisation over the last axis, with a learnt gain and bias (MAX's `layer_norm`).
-}

import Param
import Tensor as T exposing (DType, Dim, Floating, R1, R2, R3, Tensor)
import Tensor.Internal.Ops as O
import Tensor.Internal.Types as I


type alias LayerNorm d m =
    { gain : Tensor Floating d (R1 m), bias : Tensor Floating d (R1 m), epsilon : Float }


params : DType Floating d -> Dim m -> Param.Spec (LayerNorm d m)
params dt m =
    Param.record LayerNorm
        |> Param.ones .gain dt (T.r1 m)
        |> Param.zeros .bias dt (T.r1 m)
        |> Param.config .epsilon 1.0e-5


apply : LayerNorm d m -> Tensor Floating d (R2 n m) -> Tensor Floating d (R2 n m)
apply p x =
    I.Tensor (O.layerNorm p.epsilon (I.tensor x) (I.tensor p.gain) (I.tensor p.bias))


apply3 : LayerNorm d m -> Tensor Floating d (R3 b n m) -> Tensor Floating d (R3 b n m)
apply3 p x =
    I.Tensor (O.layerNorm p.epsilon (I.tensor x) (I.tensor p.gain) (I.tensor p.bias))
