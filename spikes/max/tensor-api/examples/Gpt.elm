module Gpt exposing (..)

import Graph exposing (Graph)
import Nn
import Nn.Embedding as Embedding exposing (Embedding)
import Nn.LayerNorm as LayerNorm exposing (LayerNorm)
import Nn.Linear as Linear exposing (Linear)
import Nn.Transformer as Transformer exposing (EncoderLayer)
import Optim
import Param
import Signature as Sig
import Tensor as T exposing (BF16, Dim, F32, Floating, I64, Integral, R1, R2, R3, Tensor)
import Tensor.Axis as Axis
import Tensor.Random as Random exposing (Seed)
import Train
import Transform


type Seq
    = Seq


type Model
    = Model


type Heads
    = Heads


type HeadDim
    = HeadDim


type Ffn
    = Ffn


type Vocab
    = Vocab


type Batch
    = Batch


seq : Dim Seq
seq =
    T.dim Seq 1024


model : Dim Model
model =
    T.dim Model 768


heads : Dim Heads
heads =
    T.dim Heads 12


headDim : Dim HeadDim
headDim =
    T.dim HeadDim 64


ffn : Dim Ffn
ffn =
    T.dim Ffn 3072


vocab : Dim Vocab
vocab =
    T.dim Vocab 50257


batch : Dim Batch
batch =
    T.dim Batch 8


type alias Block =
    EncoderLayer F32 Model Heads HeadDim Ffn


type alias Params =
    { embed : Embedding F32 Vocab Model
    , blocks : List Block
    , final : LayerNorm F32 Model
    , unembed : Linear F32 Model Vocab
    }


blockParams : Param.Spec Block
blockParams =
    Transformer.encoderParams T.float32 { model = model, heads = heads, headDim = headDim, feedForward = ffn, dropout = 0.1 }


params : Param.Spec Params
params =
    Param.record Params
        |> Param.sub .embed (Embedding.params T.float32 vocab model)
        |> Param.sub .blocks (Param.list 96 blockParams)
        |> Param.sub .final (LayerNorm.params T.float32 model)
        |> Param.sub .unembed (Linear.params T.float32 model vocab)


{-| One block, traced once (this value is a top-level partial application) and emitted as one MAX
subgraph that every layer calls. Everything the block reads is an argument: the seed too.
-}
block : Bool -> Transform.Shared ( Seed, Block, Tensor Floating F32 (R2 Seq Model) ) (Tensor Floating F32 (R2 Seq Model))
block training =
    Transform.shared "block"
        (Sig.triple Random.sig (Param.sig blockParams) (Sig.f32 (T.r2 seq model)))
        (Sig.f32 (T.r2 seq model))
        (\( s, bp, h ) -> Transformer.encode { causal = True, training = training } s bp h)


trainingBlock : Transform.Shared ( Seed, Block, Tensor Floating F32 (R2 Seq Model) ) (Tensor Floating F32 (R2 Seq Model))
trainingBlock =
    block True


forward : Seed -> Params -> Tensor Integral I64 (R1 Seq) -> Tensor Floating F32 (R2 Seq Vocab)
forward s p tokens =
    p.blocks
        |> List.indexedMap Tuple.pair
        |> List.foldl (\( i, bp ) h -> Transform.call trainingBlock ( Random.salt i s, bp, h )) (Embedding.apply p.embed tokens)
        |> LayerNorm.apply p.final
        |> Linear.apply p.unembed


loss : Seed -> Params -> Tensor Integral I64 (R1 Seq) -> Tensor Integral I64 (R1 Seq) -> Tensor Floating F32 T.R0
loss s p tokens targets =
    forward s p tokens |> Nn.crossEntropyIndices targets


trainStep : Result (List String) Graph
trainStep =
    Train.step params (Optim.adamW 3.0e-4) (Sig.triple (Sig.i64 T.scalar) (Sig.i64 (T.r2 batch seq)) (Sig.i64 (T.r2 batch seq))) <|
        \p ( seedInput, tokens, targets ) ->
            Transform.vmap2 Axis.liftRank1 Axis.liftRank1 Axis.liftRank0 (loss (Random.seed seedInput) p) tokens targets
                |> T.mean Axis.last1
