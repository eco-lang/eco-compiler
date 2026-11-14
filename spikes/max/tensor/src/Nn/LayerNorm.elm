module Nn.LayerNorm exposing
    ( LayerNorm, params
    , apply, apply3
    )

{-| Layer normalisation as a layer with learnt parameters: the parameter record, its description
for `Param`, and the functions that apply it to a tensor whose last axis holds features.

Layer normalisation treats each lane along the last axis on its own, a lane being the `m` features
at one position. It subtracts the lane's mean and divides by √(variance + ε), where the variance is
the mean squared deviation from that mean (a division by `m`, not `m − 1`) and ε is the record's
`epsilon`. The normalised lane is then multiplied element by element by the `gain` and added to the
`bias`, two learnt vectors of length `m`. For an input lane `x` and output lane `y`:

    y = (x − mean) / √(variance + ε) · gain + bias

Each application builds one layer-normalisation primitive, given the input in its own dtype `d`:
unlike `Nn.RmsNorm`, nothing here casts an f16 or bf16 input to f32 first. The types tie the gain
and bias to the last axis's tag only, so a gain or bias whose size differs from that axis is a build
error.


# Parameters

@docs LayerNorm, params


# Applying

@docs apply, apply3

-}

import Param
import Tensor as T exposing (DType, Dim, R1, R2, R3, Tensor)
import Tensor.Internal.Ops as O
import Tensor.Internal.Types as I


{-| The parameters of one layer normalisation over `m` features of dtype `d`: the `gain` each
normalised lane is multiplied by, the `bias` added to it, and the `epsilon` (ε) added to the
variance.

`apply` and `apply3` read ε from the record. On MAX it becomes a constant of dtype `d`, so for f16
or bf16 ε is rounded to that dtype.

-}
type alias LayerNorm d m =
    { gain : Tensor Float d (R1 m), bias : Tensor Float d (R1 m), epsilon : Float }


{-| Describes the parameters of a layer normalisation over `m` features of dtype `dt`: `gain` is a
trainable field whose first values are all 1, `bias` a trainable field whose first values are all 0,
and `epsilon` a config field holding 1e-5.

No other epsilon can be chosen here. `Param.config` says where a record holding a different value is
refused.

-}
params : DType Float d -> Dim m -> Param.Spec (LayerNorm d m)
params dt m =
    Param.record LayerNorm
        |> Param.ones .gain dt (T.r1 m)
        |> Param.zeros .bias dt (T.r1 m)
        |> Param.config .epsilon 1.0e-5


{-| Returns `x` with each of its `n` rows normalised over its `m` features, then multiplied by
`gain` and shifted by `bias`.
-}
apply : LayerNorm d m -> Tensor Float d (R2 n m) -> Tensor Float d (R2 n m)
apply p x =
    I.Tensor (O.layerNorm p.epsilon (I.tensor x) (I.tensor p.gain) (I.tensor p.bias))


{-| Returns `x` with each of its `b × n` lanes along the last axis normalised over its `m`
features, then multiplied by `gain` and shifted by `bias`, as `apply` does for a rank-2 tensor.
-}
apply3 : LayerNorm d m -> Tensor Float d (R3 b n m) -> Tensor Float d (R3 b n m)
apply3 p x =
    I.Tensor (O.layerNorm p.epsilon (I.tensor x) (I.tensor p.gain) (I.tensor p.bias))
