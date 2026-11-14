module Nn.Attention exposing
    ( Attention, params, paramsWith, self, cross
    , Grouped, groupedParams, selfGrouped, selfCached
    , Cross, crossParams, attendTo
    )

{-| `Nn.attention` computes attention from queries, keys and values that are already split into
heads, and holds no parameters. An attention layer adds the parameters around it, and this module
provides three such layers: for each, the record of its parameters, descriptions of that record
(`Param.Spec` values) and the functions that apply it.

A layer reads a sequence `x` of `s` positions, each a row of `m` features (the _model width_), and
returns a sequence of the same shape, which `selfCached` pairs with the updated cache. Its
parameters are those of four dense layers (`Nn.Linear`). The _query_, _key_ and _value_ projections
map rows of features to queries, keys and values, and the _output_ projection maps the attention's
result back to rows of `m` features.

Between the projections and the attention, each row of a projection's output is split into _heads_:
its features are read as `h` heads of `j` features each, the first `j` features making the first
head, and each head attends separately. The heads' results are then joined back into one row each
before the output projection. Splitting and joining are reshapes, so a projection whose width is not
its number of heads times `j`, or a model width that is not h × j, is a build error when the layer
is applied, as `Tensor.factorLast3` and `Tensor.mergeLast3` describe. Their exception means here
that a split or join of a sequence with no positions accepts any sizes: `x`, or, for the keys and
values of `cross` and `attendTo`, the memory. The sizes used for this are read from the record's
`heads`, `headDim` and `model` fields (and, in `Grouped`, `kvHeads`), which a description from this
module holds as `Param.config` fields.

The three layers differ in where the keys and values come from and how many heads they have.

  - `Attention` is multi-head attention, with `h` heads for queries, keys and values alike. `self`
    projects all three from `x`. `cross` projects the keys and values from a second sequence, the
    _memory_, of the same width `m` and any length `t`.
  - `Grouped` is _grouped-query attention_: the queries have `h` heads and the keys and values
    `g`, and each key/value head serves a group of h / g query heads. Its key and value
    projections map to g × j features rather than `m`. Its queries and keys can be rotated by
    position (`Nn.Rotary`), and `selfCached` lets new positions attend to themselves and to the
    positions before them, reading the keys and values from a key/value cache (`Nn.KvCache`) into
    which it first writes their own.
  - `Cross` attends from a sequence of width `m` to a memory of another width `c`.

A description chooses which projections have a bias. `params` gives all four a trainable bias.
`paramsWith`, `groupedParams` and `crossParams` take two switches: `projectionBias` for the query,
key and value projections together, and `outBias` for the output projection. A projection without
a bias has a constant zero bias, as `Nn.Linear.paramsWithoutBias` describes.

The functions take the sequence last, so that `x |> self { causal = True } layer` reads left to
right.


# Multi-head attention

@docs Attention, params, paramsWith, self, cross


# Grouped-query attention

@docs Grouped, groupedParams, selfGrouped, selfCached


# Cross-attention to another width

@docs Cross, crossParams, attendTo

-}

import Nn
import Nn.KvCache as KvCache
import Nn.Linear as Linear exposing (Linear)
import Nn.Rotary as Rotary exposing (Rotary)
import Param
import Tensor as T exposing (DType, Dim, I64, R0, R1, R2, R3, Tensor)
import Tensor.Axis as Axis
import Tensor.Internal.Expr as E
import Tensor.Internal.Ops as O
import Tensor.Internal.Types as I


{-| The parameters of a multi-head attention layer of model width `m`, with `h` heads of `j`
features, in dtype `d`.

The four projections each map `m` features to `m`; `out` is the output projection. `model`,
`heads` and `headDim` hold `m`, `h` and `j`, and `self` and `cross` split and join the heads by
these sizes, not by the projections' own.

-}
type alias Attention d m h j =
    { query : Linear d m m
    , key : Linear d m m
    , value : Linear d m m
    , out : Linear d m m
    , model : Dim m
    , heads : Dim h
    , headDim : Dim j
    }


{-| Returns the description of an `Attention` layer of width `m` with `h` heads of `j` features,
each projection described by `Nn.Linear.params`, so with a trainable weight and a trainable bias.

Its tensor fields are those of `query`, `key`, `value` and `out`, in that order, and `model`,
`heads` and `headDim` are config fields holding `m`, `h` and `j`.

-}
params : DType Float d -> Dim m -> Dim h -> Dim j -> Param.Spec (Attention d m h j)
params dt m h j =
    Param.record Attention
        |> Param.sub .query (Linear.params dt m m)
        |> Param.sub .key (Linear.params dt m m)
        |> Param.sub .value (Linear.params dt m m)
        |> Param.sub .out (Linear.params dt m m)
        |> Param.config .model m
        |> Param.config .heads h
        |> Param.config .headDim j


{-| Returns `x` projected by `l` and split into the heads of `p`: an `h` × `s` × `j` tensor, heads
first.
-}
heads : Attention d m h j -> Linear d m m -> Tensor Float d (R2 s m) -> Tensor Float d (R3 h s j)
heads p =
    split p.heads p.headDim


{-| Returns the heads of `o` joined back into rows of `p`'s model width, mapped by `p`'s output
projection.
-}
merge : Attention d m h j -> Tensor Float d (R3 h s j) -> Tensor Float d (R2 s m)
merge p =
    mergeOut p.model p.out


{-| Returns the self-attention of the sequence `x`: its queries, keys and values are all
projected from `x`, the heads attend as `Nn.attention` describes, and the result is their output
projected back to rows of `m` features.

With `causal` True, position i attends only to positions 0 … i, as `Nn.causalAttention`
describes. With it False, every position attends to every position.

-}
self : { causal : Bool } -> Attention d m h j -> Tensor Float d (R2 s m) -> Tensor Float d (R2 s m)
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


{-| Returns the attention of the sequence `x` to `memory`, a sequence of `t` positions of `m`
features: the queries are projected from `x`, the keys and values from `memory`, and every position
of `x` attends to every position of `memory`. The result is projected back as in `self`.
-}
cross : Attention d m h j -> Tensor Float d (R2 t m) -> Tensor Float d (R2 s m) -> Tensor Float d (R2 s m)
cross p memory x =
    heads p p.query x
        |> Nn.attention { mask = Nothing, bias = Nothing } (heads p p.key memory) (heads p p.value memory)
        |> merge p



-- BIASES, AND HEADS FOR PROJECTIONS OF ANY WIDTH


{-| Returns the description of a dense layer from `i` to `o` features: `Nn.Linear.params` when
`bias` is True, and `Nn.Linear.paramsWithoutBias` when it is False.
-}
linearSpec : DType Float d -> Bool -> Dim i -> Dim o -> Param.Spec (Linear d i o)
linearSpec dt bias i o =
    if bias then
        Linear.params dt i o

    else
        Linear.paramsWithoutBias dt i o


{-| Returns the description of an `Attention` layer as `params` does, except that the biases are
chosen: when `projectionBias` is True the query, key and value projections have a trainable bias,
and when `outBias` is True the output projection has one. A projection without one has a constant
zero bias, as `Nn.Linear.paramsWithoutBias` describes. With both True this is the description
`params` returns.
-}
paramsWith : DType Float d -> { projectionBias : Bool, outBias : Bool } -> Dim m -> Dim h -> Dim j -> Param.Spec (Attention d m h j)
paramsWith dt cfg m h j =
    Param.record Attention
        |> Param.sub .query (linearSpec dt cfg.projectionBias m m)
        |> Param.sub .key (linearSpec dt cfg.projectionBias m m)
        |> Param.sub .value (linearSpec dt cfg.projectionBias m m)
        |> Param.sub .out (linearSpec dt cfg.outBias m m)
        |> Param.config .model m
        |> Param.config .heads h
        |> Param.config .headDim j


{-| Returns `x` projected by `l` and split into `hd` heads of `jd` features: a tensor of heads ×
positions × features. A projection width other than the product of the two sizes is a build error,
as `Tensor.factorLast3` describes.
-}
split : Dim heads -> Dim j -> Linear d m w -> Tensor Float d (R2 s m) -> Tensor Float d (R3 heads s j)
split hd jd l x =
    x |> Linear.apply l |> T.factorLast3 hd jd |> T.permute Axis.swap01of3


{-| Returns the heads of `o` joined back into rows of `md` features, as `Tensor.mergeLast3` joins
them, and mapped by `l`.
-}
mergeOut : Dim m -> Linear d m m -> Tensor Float d (R3 h s j) -> Tensor Float d (R2 s m)
mergeOut md l o =
    o |> T.permute Axis.swap01of3 |> T.mergeLast3 md |> Linear.apply l



-- GROUPED-QUERY SELF-ATTENTION


{-| The parameters of a grouped-query attention layer of model width `m`, in dtype `d`, with `h`
query heads and `g` key/value heads, all of `j` features.

The query and output projections map `m` features to `m`, and the key and value projections map
`m` to `kv`, which is to be g × j. Each key/value head is repeated for h / g query heads, as
`Nn.repeatHeads` describes, so an `h` that is not a multiple of `g` is a build error when the layer
is applied, and with `g` equal to `h` this is the attention of `Attention`. The heads are split and
joined by `heads`, `kvHeads`, `headDim` and `model`. Nothing here reads `kvWidth`: a key or value
projection whose width is not g × j is a build error where it is split into heads, unless `x` has
no positions, as `Tensor.factorLast3` describes, whatever `kvWidth` holds.

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


{-| Returns the description of a `Grouped` layer, with its biases chosen as in `paramsWith`.

Its tensor fields are those of `query`, `key`, `value` and `out`, in that order, and `model`,
`kvWidth`, `heads`, `kvHeads` and `headDim` are config fields holding `m`, `kv`, `h`, `g` and `j`.

-}
groupedParams : DType Float d -> { projectionBias : Bool, outBias : Bool } -> Dim m -> Dim kv -> Dim h -> Dim g -> Dim j -> Param.Spec (Grouped d m kv h g j)
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


{-| Returns the grouped-query self-attention of the sequence `x`: as `self` does, except that the
keys and values are split into `g` heads and each is repeated for its group of query heads.

When `rotary` holds a `Rotary` and a positions tensor, the queries and keys are rotated as
`Nn.Rotary.apply` describes, position i of `x` being rotated for the value at index i of the
positions tensor. The values are not rotated. `causal` is as in `self`.

-}
selfGrouped : { causal : Bool, rotary : Maybe ( Rotary, Tensor Int I64 (R1 s) ) } -> Grouped d m kv h g j -> Tensor Float d (R2 s m) -> Tensor Float d (R2 s m)
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


{-| Returns `cache` with the keys and values of `x` written into it, together with the
grouped-query self-attention of `x`, its `s` positions attending to the cache's.

Position i of `x` is taken to be position p + i of the sequence, where p is the value of
`position`. The keys and values of `x` are written into the cache at positions p … p + s − 1, as
`Nn.KvCache.write` describes; with `rotary`, the queries and keys are first rotated for those
position values, so the keys written are the rotated ones. Position p + i then attends to the
cache's positions 0 … p + i, whatever the cache holds there, through the mask `Nn.causalMaskAt`
makes. There is no `causal` switch.

A written position outside the cache's 0 … t − 1 is not a build error; `Tensor.Eval` refuses the
write when it runs, as `Nn.KvCache.write` says.

-}
selfCached : { rotary : Maybe Rotary } -> Grouped d m kv h g j -> Tensor Int I64 R0 -> KvCache.Cache d g t j -> Tensor Float d (R2 s m) -> ( KvCache.Cache d g t j, Tensor Float d (R2 s m) )
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


{-| The parameters of a cross-attention layer from a sequence of width `m` to a memory of width
`c`, in dtype `d`, with `h` heads of `j` features.

The query and output projections map `m` features to `m`, and the key and value projections map
the memory's `c` features to `m`, so that its keys and values are split into heads as the queries
are.

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


{-| Returns the description of a `Cross` layer, with its biases chosen as in `paramsWith`.

Its tensor fields are those of `query`, `key`, `value` and `out`, in that order, and `model`,
`heads` and `headDim` are config fields holding `m`, `h` and `j`.

-}
crossParams : DType Float d -> { projectionBias : Bool, outBias : Bool } -> Dim m -> Dim c -> Dim h -> Dim j -> Param.Spec (Cross d m c h j)
crossParams dt cfg m c h j =
    Param.record Cross
        |> Param.sub .query (linearSpec dt cfg.projectionBias m m)
        |> Param.sub .key (linearSpec dt cfg.projectionBias c m)
        |> Param.sub .value (linearSpec dt cfg.projectionBias c m)
        |> Param.sub .out (linearSpec dt cfg.outBias m m)
        |> Param.config .model m
        |> Param.config .heads h
        |> Param.config .headDim j


{-| Returns the attention of the sequence `x` to `memory`, a sequence of `t` positions of `c`
features: as `cross` does, with the keys and values projected from `c` features to `m`. Every
position of `x` attends to every position of `memory`.
-}
attendTo : Cross d m c h j -> Tensor Float d (R2 t c) -> Tensor Float d (R2 s m) -> Tensor Float d (R2 s m)
attendTo p memory x =
    split p.heads p.headDim p.query x
        |> Nn.attention { mask = Nothing, bias = Nothing } (split p.heads p.headDim p.key memory) (split p.heads p.headDim p.value memory)
        |> mergeOut p.model p.out
