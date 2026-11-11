module Round2 exposing (..)

{-| Round 2's API used correctly (plans/tensor-api-round2.md): a Llama-style decoder layer with a KV
cache, a UNet-style block, sampling, an import. The programs in bad/ make one mistake each here.
-}

import Infer
import Nn
import Nn.Attention as Attention
import Nn.Conv2d as Conv2d exposing (Conv2d)
import Nn.Embedding as Embedding exposing (Embedding)
import Nn.FeedForward as FeedForward
import Nn.GroupNorm as GroupNorm exposing (GroupNorm)
import Nn.KvCache as KvCache
import Nn.Linear as Linear exposing (Linear)
import Nn.RmsNorm as RmsNorm exposing (RmsNorm)
import Nn.Rotary as Rotary exposing (Rotary)
import Nn.Sampling as Sampling
import Param
import Signature as Sig exposing (Sig)
import Tensor as T exposing (Dim, F32, Floating, I64, Integral, R0, R1, R2, R3, R4, Tensor)
import Tensor.Axis as Axis
import Tensor.Random as Random


type Vocab
    = Vocab


type Model
    = Model


type KvW
    = KvW


type Heads
    = Heads


type KvHeads
    = KvHeads


type HeadDim
    = HeadDim


type Ffn
    = Ffn


type Seq
    = Seq


type Context
    = Context


type Text
    = Text


type TextWidth
    = TextWidth


type Batch
    = Batch


type H
    = H


type W
    = W


type H2
    = H2


type W2
    = W2


type Ch
    = Ch


type Top
    = Top


model : Dim Model
model =
    T.dim Model 64


kvW : Dim KvW
kvW =
    T.dim KvW 32


heads : Dim Heads
heads =
    T.dim Heads 4


kvHeads : Dim KvHeads
kvHeads =
    T.dim KvHeads 2


headDim : Dim HeadDim
headDim =
    T.dim HeadDim 16


context : Dim Context
context =
    T.dim Context 32


rotary : Rotary
rotary =
    { base = 10000, pairing = Rotary.Interleaved }


type alias Layer =
    { norm : RmsNorm F32 Model
    , attn : Attention.Grouped F32 Model KvW Heads KvHeads HeadDim
    , ff : FeedForward.Gated F32 Model Ffn
    }


layerSpec : Param.Spec Layer
layerSpec =
    Param.record Layer
        |> Param.sub .norm (RmsNorm.params T.float32 { epsilon = 1.0e-5 } model)
        |> Param.sub .attn (Attention.groupedParams T.float32 { projectionBias = False, outBias = False } model kvW heads kvHeads headDim)
        |> Param.sub .ff (FeedForward.gatedParams T.float32 { bias = False } model (T.dim Ffn 128))


{-| A whole sequence, causal, rotary at positions 0 ..
-}
layer : Layer -> Tensor Floating F32 (R2 Seq Model) -> Tensor Floating F32 (R2 Seq Model)
layer l x =
    let
        positions =
            T.iota (T.dim Seq (List.head (T.shapeOf x) |> Maybe.withDefault 1))

        h =
            x |> T.plus (x |> RmsNorm.apply l.norm |> Attention.selfGrouped { causal = True, rotary = Just ( rotary, positions ) } l.attn)
    in
    h |> T.plus (FeedForward.applyGated T.silu l.ff h)


type alias Cache =
    KvCache.Cache F32 KvHeads Context HeadDim


{-| One cached step.
-}
step : Layer -> Cache -> Tensor Integral I64 R0 -> Tensor Floating F32 (R2 Seq Model) -> ( Cache, Tensor Floating F32 (R2 Seq Model) )
step l cache position x =
    Attention.selfCached { rotary = Just rotary } l.attn position cache (RmsNorm.apply l.norm x)
        |> Tuple.mapSecond (T.plus x)


decode : Embedding F32 Vocab Model -> Layer -> Cache -> Tensor Integral I64 R0 -> Tensor Integral I64 (R1 Seq) -> ( Cache, Tensor Integral I64 (R1 Seq) )
decode e l cache position tokens =
    step l cache position (Embedding.apply e tokens)
        |> Tuple.mapSecond (Embedding.unembed e >> Sampling.keepTopK 40 >> (\logits -> Sampling.sample logits (Random.seed position)))


stepGraph =
    Infer.step "step" layerSpec (KvCache.sig T.float32 kvHeads context headDim) (Sig.pair (Sig.i64 T.scalar) (Sig.f32 (T.r2 (T.dim Seq 1) model))) (Sig.f32 (T.r2 (T.dim Seq 1) model)) (\l c ( p, x ) -> step l c p x)


type alias Block =
    { conv : Conv2d F32 Ch Ch, norm : GroupNorm F32 Ch, cross : Attention.Cross F32 Ch TextWidth Heads HeadDim }


block : Block -> Tensor Floating F32 (R2 Text TextWidth) -> Tensor Floating F32 (R4 Batch H W Ch) -> Tensor Floating F32 (R4 Batch H2 W2 Ch)
block p text x =
    x
        |> Conv2d.applySame p.conv
        |> GroupNorm.apply p.norm
        |> T.silu
        |> Nn.upsampleNearest2d 2 (T.dim H2 16) (T.dim W2 16)


topTokens : Tensor Floating F32 (R2 Seq Vocab) -> Tensor Integral I64 (R2 Seq Top)
topTokens logits =
    T.topK Axis.retag1of2 (T.dim Top 5) logits |> Tuple.second
