module Nn.Transformer exposing (EncoderLayer, DecoderLayer, encoderParams, decoderParams, encode, decode)

{-| Pre-norm transformer layers: attention and a GELU feed-forward block, each with a residual.
-}

import Nn
import Nn.Attention as Attention exposing (Attention)
import Nn.LayerNorm as LayerNorm exposing (LayerNorm)
import Nn.Linear as Linear exposing (Linear)
import Param
import Tensor as T exposing (DType, Dim, Floating, R2, Tensor)
import Tensor.Random exposing (Seed)


type alias EncoderLayer d m h j f =
    { norm1 : LayerNorm d m
    , attention : Attention d m h j
    , norm2 : LayerNorm d m
    , up : Linear d m f
    , down : Linear d f m
    , dropout : Float
    }


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


encoderParams : DType Floating d -> { model : Dim m, heads : Dim h, headDim : Dim j, feedForward : Dim f, dropout : Float } -> Param.Spec (EncoderLayer d m h j f)
encoderParams dt c =
    Param.record EncoderLayer
        |> Param.sub .norm1 (LayerNorm.params dt c.model)
        |> Param.sub .attention (Attention.params dt c.model c.heads c.headDim)
        |> Param.sub .norm2 (LayerNorm.params dt c.model)
        |> Param.sub .up (Linear.params dt c.model c.feedForward)
        |> Param.sub .down (Linear.params dt c.feedForward c.model)
        |> Param.config .dropout c.dropout


decoderParams : DType Floating d -> { model : Dim m, heads : Dim h, headDim : Dim j, feedForward : Dim f, dropout : Float } -> Param.Spec (DecoderLayer d m h j f)
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


{-| Pre-norm encoder block; `training` and `seed` drive dropout.
-}
encode : { causal : Bool, training : Bool } -> Seed -> EncoderLayer d m h j f -> Tensor Floating d (R2 s m) -> Tensor Floating d (R2 s m)
encode cfg seed p x =
    let
        drop i =
            Nn.dropout { rate = p.dropout, training = cfg.training } (Tensor.Random.salt i seed)

        h =
            x |> T.plus (x |> LayerNorm.apply p.norm1 |> Attention.self { causal = cfg.causal } p.attention |> drop 0)
    in
    h |> T.plus (h |> LayerNorm.apply p.norm2 |> Linear.apply p.up |> T.gelu |> Linear.apply p.down |> drop 1)


decode : { training : Bool } -> Seed -> DecoderLayer d m h j f -> Tensor Floating d (R2 t m) -> Tensor Floating d (R2 s m) -> Tensor Floating d (R2 s m)
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
