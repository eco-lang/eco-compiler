module Nn.FeedForward exposing (Gated, gatedParams, applyGated)

{-| A feed-forward block takes rows of `m` features to rows of `f` hidden features and back to `m`.
This module provides the _gated_ form of that block, with its activation as an argument.

The block is three dense layers (`Nn.Linear`). The _gate_ and _up_ projections each map `m`
features to `f`, and the _down_ projection maps `f` back to `m`. In the gated form the hidden row is
the element-wise product of two projections of the input: the gate projection passed through the
activation, and the up projection as it is. For input x and activation `act`, the block is

    down (act (gate x) · up x)

where · multiplies element by element. With `Tensor.silu` as the activation this is the variant
called SwiGLU, and with `Tensor.gelu` the one called GEGLU, using the erf form of GELU;
`Tensor.geluTanh` gives GEGLU with the tanh approximation instead.


# Gated blocks

@docs Gated, gatedParams, applyGated

-}

import Nn.Linear as Linear exposing (Linear)
import Param
import Tensor as T exposing (DType, Dim, R2, Tensor)


{-| The parameters of a gated feed-forward block in dtype `d`, `m` being the feature size and `f`
the hidden size.
-}
type alias Gated d m f =
    { gate : Linear d m f, up : Linear d m f, down : Linear d f m }


{-| Returns the description of a block's parameters, `m` being the feature size and `f` the hidden
size. Its tensor fields are those of `gate`, then `up`, then `down`.

Each layer is described by `Linear.params` when `bias` is `True`, and by `Linear.paramsWithoutBias`
when it is `False`. In the second case each bias is a config field holding a zero vector, not a
tensor field, so the description has three tensor fields, the weights, instead of six.

-}
gatedParams : DType Float d -> { bias : Bool } -> Dim m -> Dim f -> Param.Spec (Gated d m f)
gatedParams dt cfg m f =
    let
        linear i o =
            if cfg.bias then
                Linear.params dt i o

            else
                Linear.paramsWithoutBias dt i o
    in
    Param.record Gated
        |> Param.sub .gate (linear m f)
        |> Param.sub .up (linear m f)
        |> Param.sub .down (linear f m)


{-| Returns down (act (gate x) · up x) for the `n` rows of `x`, where · multiplies element by
element. `act` is given the whole (n, f) gate projection, and the up projection is not passed
through it.
-}
applyGated : (Tensor Float d (R2 n f) -> Tensor Float d (R2 n f)) -> Gated d m f -> Tensor Float d (R2 n m) -> Tensor Float d (R2 n m)
applyGated act p x =
    act (Linear.apply p.gate x) |> T.times (Linear.apply p.up x) |> Linear.apply p.down
