module CharModel exposing
    ( Params, Config, params, optimizer, trainStep, validate, unigramEntropy
    , seqLen, batchSize, vocabSize
    )

{-| A character (byte) language model: a pre-norm transformer over windows of 64 bytes.

The batch is embedded with one gather, then the per-sequence layers are `vmap`ped over it. With
`shared` set, every layer is one call of a single MAX subgraph (`Transform.shared`) whose body is
the vmapped block; the layers' results are the same as inlined (the same graph, called).

-}

import Array
import Graph exposing (Graph)
import Nn
import Nn.Embedding as Embedding exposing (Embedding)
import Nn.LayerNorm as LayerNorm exposing (LayerNorm)
import Nn.Linear as Linear exposing (Linear)
import Nn.Transformer as Transformer exposing (EncoderLayer)
import Optim
import Param
import Signature as Sig
import Tensor as T exposing (Dim, F32, Floating, I64, Integral, R1, R2, R3, Tensor, U8)
import Tensor.Axis as Axis
import Tensor.Random as Random exposing (Seed)
import Train
import Transform


type Seq
    = Seq


type Window
    = Window


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


type Tokens
    = Tokens


seqLen : Int
seqLen =
    64


batchSize : Int
batchSize =
    16


vocabSize : Int
vocabSize =
    256


seq : Dim Seq
seq =
    T.dim Seq seqLen


window : Dim Window
window =
    T.dim Window (seqLen + 1)


model : Dim Model
model =
    T.dim Model 64


heads : Dim Heads
heads =
    T.dim Heads 4


headDim : Dim HeadDim
headDim =
    T.dim HeadDim 16


ffn : Dim Ffn
ffn =
    T.dim Ffn 256


vocab : Dim Vocab
vocab =
    T.dim Vocab vocabSize


batch : Dim Batch
batch =
    T.dim Batch batchSize


tokens : Dim Tokens
tokens =
    T.dim Tokens (batchSize * seqLen)


type alias Block =
    EncoderLayer F32 Model Heads HeadDim Ffn


type alias Params =
    { embed : Embedding F32 Vocab Model
    , position : Tensor Floating F32 (R2 Seq Model)
    , blocks : List Block
    , final : LayerNorm F32 Model
    , unembed : Linear F32 Model Vocab
    }


type alias Config =
    { layers : Int, shared : Bool }


blockParams : Param.Spec Block
blockParams =
    Transformer.encoderParams T.float32 { model = model, heads = heads, headDim = headDim, feedForward = ffn, dropout = 0.1 }


params : Config -> Param.Spec Params
params cfg =
    Param.record Params
        |> Param.sub .embed (Embedding.params T.float32 vocab model)
        |> Param.normal 0.02 .position T.float32 (T.r2 seq model)
        |> Param.sub .blocks (Param.list cfg.layers blockParams)
        |> Param.sub .final (LayerNorm.params T.float32 model)
        |> Param.sub .unembed (Linear.params T.float32 model vocab)


type alias Hidden =
    Tensor Floating F32 (R3 Batch Seq Model)


{-| One layer over the whole batch: the per-sequence layer, vmapped.
-}
layer : Bool -> ( Seed, Block, Hidden ) -> Hidden
layer training ( s, p, h ) =
    Transform.vmap Axis.liftRank2 Axis.liftRank2 (Transformer.encode { causal = True, training = training } s p) h


sharedLayer : Bool -> Transform.Shared ( Seed, Block, Hidden ) Hidden
sharedLayer training =
    Transform.shared "layer"
        (Sig.triple Random.sig (Param.sig blockParams) (Sig.f32 (T.r3 batch seq model)))
        (Sig.f32 (T.r3 batch seq model))
        (layer training)


trainingLayer : Transform.Shared ( Seed, Block, Hidden ) Hidden
trainingLayer =
    sharedLayer True


evalLayer : Transform.Shared ( Seed, Block, Hidden ) Hidden
evalLayer =
    sharedLayer False


{-| The mean next-byte cross-entropy of a batch of windows (each 65 bytes: 64 inputs, and the 64
bytes after each as targets).
-}
loss : Config -> Bool -> Seed -> Params -> Tensor Integral U8 (R2 Batch Window) -> Tensor Floating F32 T.R0
loss cfg training s p windows =
    let
        inputs =
            windows |> T.slice Axis.retag1of2 0 seq |> T.toInt

        targets =
            windows |> T.slice Axis.retag1of2 1 seq |> T.toInt |> T.flatten tokens

        embedded =
            p.embed.table
                |> T.rowsAt (T.flatten tokens inputs)
                |> T.reshape (T.r3 batch seq model)
                |> T.plus (T.broadcast Axis.axis0of3 p.position)

        apply ( i, bp ) h =
            let
                arg =
                    ( Random.salt i s, bp, h )
            in
            if cfg.shared then
                Transform.call
                    (if training then
                        trainingLayer

                     else
                        evalLayer
                    )
                    arg

            else
                layer training arg

        hidden =
            List.foldl apply embedded (List.indexedMap Tuple.pair p.blocks)

        logits =
            hidden
                |> Transform.vmap Axis.liftRank2 Axis.liftRank2 (LayerNorm.apply p.final >> Linear.apply p.unembed)
                |> T.reshape (T.r2 tokens vocab)
    in
    logits |> Nn.crossEntropyIndices targets


optimizer : Optim.Optimizer
optimizer =
    Optim.adamWWith { rate = Optim.Fixed 3.0e-3, beta1 = 0.9, beta2 = 0.99, epsilon = 1.0e-8, weightDecay = 0.01, biasCorrection = True }
        |> Optim.clipGlobalNorm 1.0


trainStep : Config -> Result (List String) Graph
trainStep cfg =
    Train.step (params cfg)
        optimizer
        (Sig.pair (Sig.u8 (T.r2 batch window)) Random.sig)
        (\p ( w, s ) -> loss cfg True s p w)


validate : Config -> Result (List String) Graph
validate cfg =
    Train.measure (params cfg) (Sig.u8 (T.r2 batch window)) (\p w -> loss cfg False (Random.seed (T.int 0)) p w)


{-| H = -Σ p log p of the bytes, in nats: the loss of predicting each byte by its frequency alone.
-}
unigramEntropy : List Int -> Float
unigramEntropy bytes =
    let
        counts =
            List.foldl (\b acc -> Array.set b (Maybe.withDefault 0 (Array.get b acc) + 1) acc) (Array.repeat 256 0) bytes
                |> Array.toList

        n =
            toFloat (List.length bytes)
    in
    counts
        |> List.filter (\c -> c > 0)
        |> List.map (\c -> -(toFloat c / n) * logBase e (toFloat c / n))
        |> List.sum
