module Nn.FeedForward exposing (Gated, gatedParams, applyGated)

{-| Gated feed-forward blocks: down (act (gate x) · up x). `applyGated T.silu` is SwiGLU (Llama);
`applyGated T.gelu` is GEGLU (Stable Diffusion's transformer blocks).
-}

import Nn.Linear as Linear exposing (Linear)
import Param
import Tensor as T exposing (DType, Dim, Floating, R2, Tensor)


type alias Gated d m f =
    { gate : Linear d m f, up : Linear d m f, down : Linear d f m }


gatedParams : DType Floating d -> { bias : Bool } -> Dim m -> Dim f -> Param.Spec (Gated d m f)
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


applyGated : (Tensor Floating d (R2 n f) -> Tensor Floating d (R2 n f)) -> Gated d m f -> Tensor Floating d (R2 n m) -> Tensor Floating d (R2 n m)
applyGated act p x =
    act (Linear.apply p.gate x) |> T.times (Linear.apply p.up x) |> Linear.apply p.down
