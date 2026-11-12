module Finetune.Lora exposing
    ( Lora, params
    , delta, apply
    , merge, unmerge
    )

{-| LoRA (Hu et al. 2021): a frozen weight plus a trainable low-rank update (alpha / rank) A B, with
A normal and B zero, so training starts from the frozen network.


# Parameters

@docs Lora, params


# Applying

@docs delta, apply


# Merging

@docs merge, unmerge

-}

import Nn.Linear exposing (Linear)
import Param
import Tensor as T exposing (DType, Dim, R2, Tensor)


{-| The adapter's `a` (i, r) and `b` (r, o), and `alpha` and `rank` (r), which scale A B by
alpha / rank.
-}
type alias Lora d i r o =
    { a : Tensor Float d (R2 i r), b : Tensor Float d (R2 r o), alpha : Float, rank : Int }


{-| `a` normal with standard deviation `initStd`, `b` zeros.
-}
params : DType Float d -> { rank : Dim r, alpha : Float, initStd : Float } -> Dim i -> Dim o -> Param.Spec (Lora d i r o)
params dt c i o =
    Param.record Lora
        |> Param.normal c.initStd .a dt (T.r2 i c.rank)
        |> Param.zeros .b dt (T.r2 c.rank o)
        |> Param.config .alpha c.alpha
        |> Param.config .rank (T.size c.rank)


{-| The weight update (alpha / rank) A B, (i, o).
-}
delta : Lora d i r o -> Tensor Float d (R2 i o)
delta p =
    p.a |> T.matmul p.b |> T.scale (p.alpha / toFloat p.rank)


{-| `apply base lora x`: the frozen `base` layer plus the adapter's update, rows (n, i) to (n, o).
-}
apply : Linear d i o -> Lora d i r o -> Tensor Float d (R2 n i) -> Tensor Float d (R2 n o)
apply base p x =
    x |> Nn.Linear.apply base |> T.plus (x |> T.matmul p.a |> T.matmul p.b |> T.scale (p.alpha / toFloat p.rank))


{-| A weight (i, o) with `delta` added, folding the adapter in.
-}
merge : Lora d i r o -> Tensor Float d (R2 i o) -> Tensor Float d (R2 i o)
merge p w =
    w |> T.plus (delta p)


{-| A merged weight with `delta` taken out again.
-}
unmerge : Lora d i r o -> Tensor Float d (R2 i o) -> Tensor Float d (R2 i o)
unmerge p w =
    w |> T.minus (delta p)
