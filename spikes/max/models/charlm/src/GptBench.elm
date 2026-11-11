port module GptBench exposing (main)

{-| Builds (does not run) the training step of a GPT-sized model in Elm, with its blocks shared as
one MAX subgraph or inlined, and reports the graph's size: the Elm-side cost of very large graphs.

Flags: { layers, shared, model, heads, headDim, ffn, vocab, seq, batch }.

-}

import Bytes
import Graph exposing (Graph)
import Json.Decode as D
import Json.Encode as E
import Nn
import Nn.Embedding as Embedding exposing (Embedding)
import Nn.LayerNorm as LayerNorm exposing (LayerNorm)
import Nn.Linear as Linear exposing (Linear)
import Nn.Transformer as Transformer exposing (EncoderLayer)
import Optim
import Param
import Platform
import Signature as Sig
import Tensor as T exposing (Dim, F32, Floating, I64, Integral, R2, R3, Tensor)
import Tensor.Axis as Axis
import Tensor.Random as Random exposing (Seed)
import Train
import Transform


port report : E.Value -> Cmd msg


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


type Tokens
    = Tokens


type alias Cfg =
    { layers : Int, shared : Bool, model : Int, heads : Int, headDim : Int, ffn : Int, vocab : Int, seq : Int, batch : Int }


type alias Block =
    EncoderLayer F32 Model Heads HeadDim Ffn


type alias Params =
    { embed : Embedding F32 Vocab Model
    , blocks : List Block
    , final : LayerNorm F32 Model
    , unembed : Linear F32 Model Vocab
    }


type alias Hidden =
    Tensor Floating F32 (R3 Batch Seq Model)


build : Cfg -> Result (List String) Graph
build cfg =
    let
        seq =
            T.dim Seq cfg.seq

        model =
            T.dim Model cfg.model

        batch =
            T.dim Batch cfg.batch

        vocab =
            T.dim Vocab cfg.vocab

        tokens =
            T.dim Tokens (cfg.batch * cfg.seq)

        blockSpec =
            Transformer.encoderParams T.float32 { model = model, heads = T.dim Heads cfg.heads, headDim = T.dim HeadDim cfg.headDim, feedForward = T.dim Ffn cfg.ffn, dropout = 0.1 }

        params =
            Param.record Params
                |> Param.sub .embed (Embedding.params T.float32 vocab model)
                |> Param.sub .blocks (Param.list cfg.layers blockSpec)
                |> Param.sub .final (LayerNorm.params T.float32 model)
                |> Param.sub .unembed (Linear.params T.float32 model vocab)

        layer ( s, p, h ) =
            Transform.vmap Axis.liftRank2 Axis.liftRank2 (Transformer.encode { causal = True, training = True } s p) h

        shared =
            Transform.shared "block" (Sig.triple Random.sig (Param.sig blockSpec) (Sig.f32 (T.r3 batch seq model))) (Sig.f32 (T.r3 batch seq model)) layer

        apply ( i, bp ) h =
            if cfg.shared then
                Transform.call shared ( Random.salt i (Random.seed (T.int 0)), bp, h )

            else
                layer ( Random.salt i (Random.seed (T.int 0)), bp, h )

        loss : Params -> ( Tensor Integral I64 (R2 Batch Seq), Tensor Integral I64 (R2 Batch Seq) ) -> Tensor Floating F32 T.R0
        loss p ( inputs, targets ) =
            p.embed.table
                |> T.rowsAt (T.flatten tokens inputs)
                |> T.reshape (T.r3 batch seq model)
                |> (\h -> List.foldl apply h (List.indexedMap Tuple.pair p.blocks))
                |> Transform.vmap Axis.liftRank2 Axis.liftRank2 (LayerNorm.apply p.final >> Linear.apply p.unembed)
                |> T.reshape (T.r2 tokens vocab)
                |> Nn.crossEntropyIndices (T.flatten tokens targets)
    in
    Train.step params (Optim.adamW 3.0e-4) (Sig.pair (Sig.i64 (T.r2 batch seq)) (Sig.i64 (T.r2 batch seq))) loss


main : Program D.Value () ()
main =
    Platform.worker
        { init =
            \flags ->
                let
                    int name default =
                        Result.withDefault default (D.decodeValue (D.field name D.int) flags)

                    cfg =
                        { layers = int "layers" 96
                        , shared = Result.withDefault True (D.decodeValue (D.field "shared" D.bool) flags)
                        , model = int "model" 768
                        , heads = int "heads" 12
                        , headDim = int "headDim" 64
                        , ffn = int "ffn" 3072
                        , vocab = int "vocab" 50257
                        , seq = int "seq" 1024
                        , batch = int "batch" 8
                        }
                in
                ( ()
                , report
                    (case build cfg of
                        Ok g ->
                            let
                                bytes =
                                    Graph.toBytecode g
                            in
                            E.object
                                [ ( "bytecode", E.int (Bytes.width bytes) )
                                , ( "inputs", E.int (List.length (Graph.inputs g)) )
                                ]

                        Err e ->
                            E.object [ ( "errors", E.list E.string (List.take 5 e) ) ]
                    )
                )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
