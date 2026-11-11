module Finetune.Lora exposing (Lora, params, delta, apply, merge, unmerge)

{-| LoRA (Hu et al. 2021): a frozen weight plus a trainable low-rank update (alpha / rank) A B, with
A normal and B zero, so training starts from the frozen network.
-}

import Nn.Linear exposing (Linear)
import Param
import Tensor as T exposing (DType, Dim, Floating, R2, Tensor)


type alias Lora d i r o =
    { a : Tensor Floating d (R2 i r), b : Tensor Floating d (R2 r o), alpha : Float, rank : Int }


params : DType Floating d -> { rank : Dim r, alpha : Float, initStd : Float } -> Dim i -> Dim o -> Param.Spec (Lora d i r o)
params dt c i o =
    Param.record Lora
        |> Param.normal c.initStd .a dt (T.r2 i c.rank)
        |> Param.zeros .b dt (T.r2 c.rank o)
        |> Param.config .alpha c.alpha
        |> Param.config .rank (T.size c.rank)


delta : Lora d i r o -> Tensor Floating d (R2 i o)
delta p =
    p.a |> T.matmul p.b |> T.scale (p.alpha / toFloat p.rank)


apply : Linear d i o -> Lora d i r o -> Tensor Floating d (R2 n i) -> Tensor Floating d (R2 n o)
apply base p x =
    x |> Nn.Linear.apply base |> T.plus (x |> T.matmul p.a |> T.matmul p.b |> T.scale (p.alpha / toFloat p.rank))


merge : Lora d i r o -> Tensor Floating d (R2 i o) -> Tensor Floating d (R2 i o)
merge p w =
    w |> T.plus (delta p)


unmerge : Lora d i r o -> Tensor Floating d (R2 i o) -> Tensor Floating d (R2 i o)
unmerge p w =
    w |> T.minus (delta p)
