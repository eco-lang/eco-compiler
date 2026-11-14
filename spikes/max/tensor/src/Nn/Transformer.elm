module Nn.Transformer exposing
    ( EncoderLayer, DecoderLayer, encoderParams, decoderParams
    , encode, decode
    )

{-| This module builds the two kinds of layer in a transformer, an encoder layer and a decoder
layer, from attention (`Nn.Attention`), layer normalisation (`Nn.LayerNorm`) and dense layers
(`Nn.Linear`). For each kind it provides the parameter record, a description of that record for
`Param`, and the function that applies it.

A layer reads a sequence `x` of `s` positions, each a row of `m` features (the _model width_), and
returns a sequence of the same shape. It is made of _blocks_, each of which computes something from
the sequence and adds it to the sequence. Adding a block's output to its input is the _residual_
connection, and the sum is the sequence the next block reads. An encoder layer has two blocks:
self-attention, in which the positions of `x` attend to one another (each only to itself and the
positions before it, if `encode` asks for that), and then a feed-forward block. A decoder layer has
three: self-attention in which each position attends only to itself and the positions before it,
attention from `x` to a second sequence, the _memory_, and then the feed-forward block.

The layers are _pre-norm_: each block normalises its input with its own layer normalisation before
computing from it, and its output is added to the input as it was before normalising. A layer's
result is that sum, and is not normalised.

The feed-forward block maps each row from `m` features to `f` with one dense layer, applies GELU to
each element as `Tensor.gelu` computes it, and maps the row back to `m` features with a second dense
layer. The attention blocks are those of `Nn.Attention`, with `h` heads of `j` features;
`Nn.Attention` says when a model width that is not h × j is a build error.

Each block's output passes through dropout (`Nn.dropout`) before it is added, at the rate in the
layer's `dropout` field. Nothing else in a layer is dropped: not the attention weights, and not the
feed-forward block's `f` features. The function that applies a layer takes one seed and draws each
block's mask on that seed salted (`Tensor.Random.salt`) with the block's position: 0, 1 and, in a
decoder layer, 2. Two layers given one seed therefore draw their masks on the same seeds.

In the types, `d` is the dtype, `m` the model width, `h` the number of heads, `j` the features of
a head, `f` the width of the feed-forward block, `s` the number of positions of `x` and `t` the
number of positions of the memory.


# Layers

@docs EncoderLayer, DecoderLayer, encoderParams, decoderParams


# Applying

@docs encode, decode

-}

import Nn
import Nn.Attention as Attention exposing (Attention)
import Nn.LayerNorm as LayerNorm exposing (LayerNorm)
import Nn.Linear as Linear exposing (Linear)
import Param
import Tensor as T exposing (DType, Dim, R2, Tensor)
import Tensor.Random exposing (Seed)


{-| The parameters of one encoder layer.

`norm1` normalises the input of the self-attention block and `norm2` that of the feed-forward
block, whose two dense layers are `up`, from `m` features to `f`, and `down`, from `f` back to `m`.
`dropout` is the rate `Nn.dropout` is given for every block: for a rate between 0 and 1, the
probability that each element of a block's output is dropped while training.

-}
type alias EncoderLayer d m h j f =
    { norm1 : LayerNorm d m
    , attention : Attention d m h j
    , norm2 : LayerNorm d m
    , up : Linear d m f
    , down : Linear d f m
    , dropout : Float
    }


{-| The parameters of one decoder layer.

`self` holds the self-attention block's attention parameters and `cross` those of the attention to
the memory. Both are an `Attention d m h j`, so the memory has `m` features, like the input.
`norm1`, `norm2` and `norm3` normalise the inputs of the self-attention, the attention to the memory
and the feed-forward block, in that order. `up`, `down` and `dropout` are as in `EncoderLayer`.

-}
type alias DecoderLayer d m h j f =
    { norm1 : LayerNorm d m
    , self : Attention d m h j
    , norm2 : LayerNorm d m
    , cross : Attention d m h j
    , norm3 : LayerNorm d m
    , up : Linear d m f
    , down : Linear d f m
    , dropout : Float
    }


{-| Returns the description of an `EncoderLayer` of width `model` with `heads` heads of `headDim`
features and a feed-forward block of width `feedForward`.

Each part is described by its own module: the layer normalisations by `Nn.LayerNorm.params`, the
attention by `Nn.Attention.params` and the two dense layers by `Nn.Linear.params`, so every
projection and dense layer has a trainable bias. The tensor fields are those of `norm1`,
`attention`, `norm2`, `up` and `down`, in that order. `dropout` is a config field holding the given
rate, so the rate is part of the description: `Param.config` says where a record holding a
different rate is refused.

-}
encoderParams : DType Float d -> { model : Dim m, heads : Dim h, headDim : Dim j, feedForward : Dim f, dropout : Float } -> Param.Spec (EncoderLayer d m h j f)
encoderParams dt c =
    Param.record EncoderLayer
        |> Param.sub .norm1 (LayerNorm.params dt c.model)
        |> Param.sub .attention (Attention.params dt c.model c.heads c.headDim)
        |> Param.sub .norm2 (LayerNorm.params dt c.model)
        |> Param.sub .up (Linear.params dt c.model c.feedForward)
        |> Param.sub .down (Linear.params dt c.feedForward c.model)
        |> Param.config .dropout c.dropout


{-| Returns the description of a `DecoderLayer`, made as `encoderParams` makes an encoder layer's,
with both attention blocks described by `Nn.Attention.params`. The tensor fields are those of
`norm1`, `self`, `norm2`, `cross`, `norm3`, `up` and `down`, in that order, and `dropout` is a
config field holding the given rate.
-}
decoderParams : DType Float d -> { model : Dim m, heads : Dim h, headDim : Dim j, feedForward : Dim f, dropout : Float } -> Param.Spec (DecoderLayer d m h j f)
decoderParams dt c =
    Param.record DecoderLayer
        |> Param.sub .norm1 (LayerNorm.params dt c.model)
        |> Param.sub .self (Attention.params dt c.model c.heads c.headDim)
        |> Param.sub .norm2 (LayerNorm.params dt c.model)
        |> Param.sub .cross (Attention.params dt c.model c.heads c.headDim)
        |> Param.sub .norm3 (LayerNorm.params dt c.model)
        |> Param.sub .up (Linear.params dt c.model c.feedForward)
        |> Param.sub .down (Linear.params dt c.feedForward c.model)
        |> Param.config .dropout c.dropout


{-| Returns `x` after the encoder layer `p`:

    h1 =
        x + dropout (attention (norm1 x))

    result =
        h1 + dropout (down (gelu (up (norm2 h1))))

With `causal` True each position attends only to itself and the positions before it, and with it
False every position attends to every position, as `Nn.Attention.self` describes. The two dropouts
draw on `seed` salted with 0 and 1. With `training` False nothing is dropped and the result does
not depend on `seed`.

-}
encode : { causal : Bool, training : Bool } -> Seed -> EncoderLayer d m h j f -> Tensor Float d (R2 s m) -> Tensor Float d (R2 s m)
encode cfg seed p x =
    let
        drop i =
            Nn.dropout { rate = p.dropout, training = cfg.training } (Tensor.Random.salt i seed)

        h =
            x |> T.plus (x |> LayerNorm.apply p.norm1 |> Attention.self { causal = cfg.causal } p.attention |> drop 0)
    in
    h |> T.plus (h |> LayerNorm.apply p.norm2 |> Linear.apply p.up |> T.gelu |> Linear.apply p.down |> drop 1)


{-| Returns `x` after the decoder layer `p`, which attends to `memory`, a sequence of `t` positions
of `m` features:

    h1 =
        x + dropout (self (norm1 x))

    h2 =
        h1 + dropout (cross memory (norm2 h1))

    result =
        h2 + dropout (down (gelu (up (norm3 h2))))

In the self-attention each position attends only to itself and the positions before it. In the
attention to `memory` every position of `x` attends to every position of `memory`, which is used
as given: the layer does not normalise it. The three dropouts draw on `seed` salted with 0, 1
and 2. With `training` False nothing is dropped and the result does not depend on `seed`.

-}
decode : { training : Bool } -> Seed -> DecoderLayer d m h j f -> Tensor Float d (R2 t m) -> Tensor Float d (R2 s m) -> Tensor Float d (R2 s m)
decode cfg seed p memory x =
    let
        drop i =
            Nn.dropout { rate = p.dropout, training = cfg.training } (Tensor.Random.salt i seed)

        h1 =
            x |> T.plus (x |> LayerNorm.apply p.norm1 |> Attention.self { causal = True } p.self |> drop 0)

        h2 =
            h1 |> T.plus (h1 |> LayerNorm.apply p.norm2 |> Attention.cross p.cross memory |> drop 1)
    in
    h2 |> T.plus (h2 |> LayerNorm.apply p.norm3 |> Linear.apply p.up |> T.gelu |> Linear.apply p.down |> drop 2)
