module Nn.Attention exposing
    ( Attention, params, paramsWith, self, cross
    , Grouped, groupedParams, selfGrouped, selfCached
    , Cross, crossParams, attendTo
    )

{-| Multi-head attention: query, key, value and output projections of width `m`, split into `h`
heads of `j` (build time checks h × j = m).
-}

import Nn
import Nn.KvCache as KvCache
import Nn.Linear as Linear exposing (Linear)
import Nn.Rotary as Rotary exposing (Rotary)
import Param
import Tensor as T exposing (DType, Dim, Floating, I64, Integral, R0, R1, R2, R3, Tensor)
import Tensor.Internal.Expr as E
import Tensor.Internal.Ops as O
import Tensor.Internal.Types as I
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



-- PROJECTIONS WITH OR WITHOUT BIASES


linearSpec : DType Floating d -> Bool -> Dim i -> Dim o -> Param.Spec (Linear d i o)
linearSpec dt bias i o =
    if bias then
        Linear.params dt i o

    else
        Linear.paramsWithoutBias dt i o


{-| As `params`, choosing which projections have biases (CLIP and GPT-2: all; Llama: none; Stable
Diffusion: only the output).
-}
paramsWith : DType Floating d -> { projectionBias : Bool, outBias : Bool } -> Dim m -> Dim h -> Dim j -> Param.Spec (Attention d m h j)
paramsWith dt cfg m h j =
    Param.record Attention
        |> Param.sub .query (linearSpec dt cfg.projectionBias m m)
        |> Param.sub .key (linearSpec dt cfg.projectionBias m m)
        |> Param.sub .value (linearSpec dt cfg.projectionBias m m)
        |> Param.sub .out (linearSpec dt cfg.outBias m m)
        |> Param.config .model m
        |> Param.config .heads h
        |> Param.config .headDim j


{-| x projected by `l` and split into `heads` heads of `j` (build time checks heads × j is the
projection's width).
-}
split : Dim heads -> Dim j -> Linear d m w -> Tensor Floating d (R2 s m) -> Tensor Floating d (R3 heads s j)
split hd jd l x =
    x |> Linear.apply l |> T.factorLast3 hd jd |> T.permute Axis.swap01of3


mergeOut : Dim m -> Linear d m m -> Tensor Floating d (R3 h s j) -> Tensor Floating d (R2 s m)
mergeOut md l o =
    o |> T.permute Axis.swap01of3 |> T.mergeLast3 md |> Linear.apply l



-- GROUPED-QUERY SELF-ATTENTION


{-| Self-attention with `h` query heads sharing `g` key/value heads (g divides h; g = h is ordinary
multi-head attention), heads of `j` features: queries project to m = h × j, keys and values to
kv = g × j.
-}
type alias Grouped d m kv h g j =
    { query : Linear d m m
    , key : Linear d m kv
    , value : Linear d m kv
    , out : Linear d m m
    , model : Dim m
    , kvWidth : Dim kv
    , heads : Dim h
    , kvHeads : Dim g
    , headDim : Dim j
    }


groupedParams : DType Floating d -> { projectionBias : Bool, outBias : Bool } -> Dim m -> Dim kv -> Dim h -> Dim g -> Dim j -> Param.Spec (Grouped d m kv h g j)
groupedParams dt cfg m kv h g j =
    Param.record Grouped
        |> Param.sub .query (linearSpec dt cfg.projectionBias m m)
        |> Param.sub .key (linearSpec dt cfg.projectionBias m kv)
        |> Param.sub .value (linearSpec dt cfg.projectionBias m kv)
        |> Param.sub .out (linearSpec dt cfg.outBias m m)
        |> Param.config .model m
        |> Param.config .kvWidth kv
        |> Param.config .heads h
        |> Param.config .kvHeads g
        |> Param.config .headDim j


{-| Self-attention over one sequence; with `rotary`, queries and keys are rotated for the given
positions.
-}
selfGrouped : { causal : Bool, rotary : Maybe ( Rotary, Tensor Integral I64 (R1 s) ) } -> Grouped d m kv h g j -> Tensor Floating d (R2 s m) -> Tensor Floating d (R2 s m)
selfGrouped cfg p x =
    let
        q0 =
            split p.heads p.headDim p.query x

        k0 =
            split p.kvHeads p.headDim p.key x

        ( q, k1 ) =
            case cfg.rotary of
                Just ( r, positions ) ->
                    ( Rotary.apply r positions q0, Rotary.apply r positions k0 )

                Nothing ->
                    ( q0, k0 )

        k =
            Nn.repeatHeads p.heads k1

        v =
            split p.kvHeads p.headDim p.value x |> Nn.repeatHeads p.heads
    in
    mergeOut p.model
        p.out
        (if cfg.causal then
            q |> Nn.causalAttention k v

         else
            q |> Nn.attention { mask = Nothing, bias = Nothing } k v
        )


{-| One generation step with a cache: `s` new tokens at `position` (each attends to the cache's
earlier positions and to the new ones up to itself). Returns the cache with their keys and values
written, and their outputs. Positions past the cache's end are the caller's to prevent.
-}
selfCached : { rotary : Maybe Rotary } -> Grouped d m kv h g j -> Tensor Integral I64 R0 -> KvCache.Cache d g t j -> Tensor Floating d (R2 s m) -> ( KvCache.Cache d g t j, Tensor Floating d (R2 s m) )
selfCached cfg p position cache x =
    let
        steps =
            List.head (E.shape (I.tensor x)) |> Maybe.withDefault 1

        length =
            List.drop 1 (E.shape (I.tensor cache.keys)) |> List.head |> Maybe.withDefault 1

        positions =
            I.Tensor (O.add (O.range 0 1 steps) (O.broadcastAxis 0 (I.tensor position)))

        q0 =
            split p.heads p.headDim p.query x

        k0 =
            split p.kvHeads p.headDim p.key x

        ( q, k ) =
            case cfg.rotary of
                Just r ->
                    ( Rotary.apply r positions q0, Rotary.apply r positions k0 )

                Nothing ->
                    ( q0, k0 )

        cache2 =
            KvCache.write position k (split p.kvHeads p.headDim p.value x) cache

        mask =
            Nn.causalMaskAt position (I.Dim steps) (I.Dim length)
    in
    ( cache2
    , q
        |> Nn.attention { mask = Just mask, bias = Nothing } (Nn.repeatHeads p.heads cache2.keys) (Nn.repeatHeads p.heads cache2.values)
        |> mergeOut p.model p.out
    )



-- CROSS-ATTENTION TO A MEMORY OF ANOTHER WIDTH


{-| Attention from a sequence of width m to a memory of width c (Stable Diffusion: image features
attending to text states): keys and values project the memory from c to m.
-}
type alias Cross d m c h j =
    { query : Linear d m m
    , key : Linear d c m
    , value : Linear d c m
    , out : Linear d m m
    , model : Dim m
    , heads : Dim h
    , headDim : Dim j
    }


crossParams : DType Floating d -> { projectionBias : Bool, outBias : Bool } -> Dim m -> Dim c -> Dim h -> Dim j -> Param.Spec (Cross d m c h j)
crossParams dt cfg m c h j =
    Param.record Cross
        |> Param.sub .query (linearSpec dt cfg.projectionBias m m)
        |> Param.sub .key (linearSpec dt cfg.projectionBias c m)
        |> Param.sub .value (linearSpec dt cfg.projectionBias c m)
        |> Param.sub .out (linearSpec dt cfg.outBias m m)
        |> Param.config .model m
        |> Param.config .heads h
        |> Param.config .headDim j


{-| `x |> attendTo p memory`.
-}
attendTo : Cross d m c h j -> Tensor Floating d (R2 t c) -> Tensor Floating d (R2 s m) -> Tensor Floating d (R2 s m)
attendTo p memory x =
    split p.heads p.headDim p.query x
        |> Nn.attention { mask = Nothing, bias = Nothing } (split p.heads p.headDim p.key memory) (split p.heads p.headDim p.value memory)
        |> mergeOut p.model p.out
