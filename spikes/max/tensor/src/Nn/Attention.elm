module Nn.Attention exposing (Attention, params, self, cross)

{-| Multi-head attention: query, key, value and output projections of width `m`, split into `h`
heads of `j` (build time checks h × j = m).
-}

import Nn
import Nn.Linear as Linear exposing (Linear)
import Param
import Tensor as T exposing (DType, Dim, Floating, R2, R3, Tensor)
import Tensor.Axis as Axis


type alias Attention d m h j =
    { query : Linear d m m
    , key : Linear d m m
    , value : Linear d m m
    , out : Linear d m m
    , model : Dim m
    , heads : Dim h
    , headDim : Dim j
    }


params : DType Floating d -> Dim m -> Dim h -> Dim j -> Param.Spec (Attention d m h j)
params dt m h j =
    Param.record Attention
        |> Param.sub .query (Linear.params dt m m)
        |> Param.sub .key (Linear.params dt m m)
        |> Param.sub .value (Linear.params dt m m)
        |> Param.sub .out (Linear.params dt m m)
        |> Param.config .model m
        |> Param.config .heads h
        |> Param.config .headDim j


heads : Attention d m h j -> Linear d m m -> Tensor Floating d (R2 s m) -> Tensor Floating d (R3 h s j)
heads p l x =
    x |> Linear.apply l |> T.factorLast3 p.heads p.headDim |> T.permute Axis.swap01of3


merge : Attention d m h j -> Tensor Floating d (R3 h s j) -> Tensor Floating d (R2 s m)
merge p o =
    o |> T.permute Axis.swap01of3 |> T.mergeLast3 p.model |> Linear.apply p.out


{-| Self-attention over one sequence.
-}
self : { causal : Bool } -> Attention d m h j -> Tensor Floating d (R2 s m) -> Tensor Floating d (R2 s m)
self cfg p x =
    let
        q =
            heads p p.query x

        k =
            heads p p.key x

        v =
            heads p p.value x
    in
    merge p
        (if cfg.causal then
            q |> Nn.causalAttention k v

         else
            q |> Nn.attention { mask = Nothing, bias = Nothing } k v
        )


{-| Attention from a sequence to a memory (`cross attention memory x`).
-}
cross : Attention d m h j -> Tensor Floating d (R2 t m) -> Tensor Floating d (R2 s m) -> Tensor Floating d (R2 s m)
cross p memory x =
    heads p p.query x
        |> Nn.attention { mask = Nothing, bias = Nothing } (heads p p.key memory) (heads p p.value memory)
        |> merge p
