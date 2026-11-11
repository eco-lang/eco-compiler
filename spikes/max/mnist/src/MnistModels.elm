module MnistModels exposing (Variant, variant, names)

{-| The MNIST models the runner can train, each as its training step, its evaluation and how its
resident buffers start:

  - `sgd`: `MnistNet` (784 → 128 → 10, SGD 0.1), the spike's reference run.
  - `adamw`: the same network with AdamW 1e-3 (optimizer state resident on the host).
  - `stack`: 784 → 512 → 256 → 10 as an `Nn.Stack`, dropout 0.1, AdamW.
  - `cnn`: conv 32 → pool → conv 64 → pool → dense, AdamW.
  - `lora`: `adamw`'s trained network, frozen, with a rank-8 LoRA adapter on its first layer.

-}

import Bytes exposing (Bytes)
import Finetune.Lora as Lora exposing (Lora)
import Graph exposing (Graph)
import MnistNet as Net exposing (Batch, Classes, Hidden, Pixels, Test, batch, classes, hidden, pixels, test)
import Nn
import Nn.Conv2d as Conv2d exposing (Conv2d)
import Nn.Linear as Linear exposing (Linear)
import Nn.Stack as Stack exposing (Stack)
import Optim exposing (Optimizer)
import Param
import Signature as Sig
import Tensor as T exposing (Dim, F32, Floating, I64, Integral, R2, R4, Tensor, U8)
import Tensor.Axis as Axis
import Tensor.Random as Random
import Train


type alias Variant =
    { train : Result (List String) Graph
    , measure : Result (List String) Graph
    , initial : List ( String, Bytes )
    , seeded : Bool
    , epochs : Int
    , loads : List ( String, String )
    , saves : List String
    , base : Maybe { files : List String, residents : Bytes -> List ( String, Bytes ) }
    }


names : List String
names =
    [ "sgd", "adamw", "stack", "cnn", "lora", "momentum", "lion" ]


variant : String -> Variant
variant name =
    case name of
        "adamw" ->
            adamw

        "stack" ->
            stack

        "cnn" ->
            cnn

        "lora" ->
            lora

        "momentum" ->
            withOptimizer (Optim.sgdWith { rate = Optim.Fixed 0.05, momentum = 0.9, weightDecay = 1.0e-4 })

        "lion" ->
            withOptimizer lion

        _ ->
            sgd


images : Sig.Sig ( Tensor Integral U8 (R2 Batch Pixels), Tensor Integral U8 (T.R1 Batch) )
images =
    Sig.pair (Sig.u8 (T.r2 batch pixels)) (Sig.u8 (T.r1 batch))


testImages : Sig.Sig ( Tensor Integral U8 (R2 Test Pixels), Tensor Integral U8 (T.R1 Test) )
testImages =
    Sig.pair (Sig.u8 (T.r2 test pixels)) (Sig.u8 (T.r1 test))


correct : Tensor Floating F32 (R2 n Classes) -> Tensor Integral U8 (T.R1 n) -> Tensor Floating F32 T.R0
correct logits labels =
    logits |> T.argMax Axis.last2 |> T.equals (T.toInt labels) |> T.indicator T.float32 |> T.sumAll


adam : Optimizer
adam =
    Optim.adamW 1.0e-3


paramNames : Int -> List String
paramNames n =
    List.map (\i -> "param" ++ String.fromInt i) (List.range 0 (n - 1))



-- SGD AND ADAMW: THE SPIKE'S NETWORK


sgd : Variant
sgd =
    { train = Net.trainStep
    , measure = Net.evaluate
    , initial = Train.initial Net.params (Optim.sgd Net.learningRate) 42
    , seeded = False
    , epochs = Net.epochs
    , loads = []
    , saves = []
    , base = Nothing
    }


adamw : Variant
adamw =
    { train = Train.step Net.params adam images (\p ( x, y ) -> Net.network p x |> Nn.crossEntropyIndices y)
    , measure = Net.evaluate
    , initial = Train.initial Net.params adam 42
    , seeded = False
    , epochs = 5
    , loads = []
    , saves = paramNames 4
    , base = Nothing
    }



-- OTHER OPTIMIZERS ON THE SPIKE'S NETWORK


withOptimizer : Optimizer -> Variant
withOptimizer opt =
    { train = Train.step Net.params opt images (\p ( x, y ) -> Net.network p x |> Nn.crossEntropyIndices y)
    , measure = Net.evaluate
    , initial = Train.initial Net.params opt 42
    , seeded = False
    , epochs = 3
    , loads = []
    , saves = []
    , base = Nothing
    }


{-| Lion (Chen et al. 2023), written element-wise as a custom optimizer: the sign of an
interpolated momentum, with decoupled weight decay.
-}
lion : Optimizer
lion =
    Optim.custom
        { rate = Optim.Fixed 1.0e-4
        , slots = 1
        , update =
            \h { param, grad, state } ->
                let
                    m =
                        List.head state |> Maybe.withDefault (T.zerosLike grad)

                    direction =
                        m |> T.scale 0.9 |> T.plus (grad |> T.scale 0.1) |> T.sign
                in
                { param = param |> T.minus (direction |> T.plus (param |> T.scale 0.01) |> T.times (T.fillLike h.rate param))
                , state = [ m |> T.scale 0.99 |> T.plus (grad |> T.scale 0.01) ]
                }
        }



-- A STACK WITH DROPOUT


type alias StackParams =
    { mlp : Stack F32 Pixels Classes }


stackParams : Param.Spec StackParams
stackParams =
    Param.record StackParams
        |> Param.sub .mlp
            (Stack.params T.float32 pixels (Stack.input |> Stack.dense 512 Stack.relu |> Stack.dense 256 Stack.relu |> Stack.denseTo classes Stack.none))


stackNetwork : { training : Bool } -> Random.Seed -> StackParams -> Tensor Integral U8 (R2 n Pixels) -> Tensor Floating F32 (R2 n Classes)
stackNetwork cfg seed p x =
    x |> T.toFloat |> T.scale (1 / 255) |> Stack.applyWithDropout { rate = 0.1, training = cfg.training } seed p.mlp


stack : Variant
stack =
    { train =
        Train.step stackParams adam (Sig.triple (Sig.u8 (T.r2 batch pixels)) (Sig.u8 (T.r1 batch)) Random.sig) <|
            \p ( x, y, seed ) -> stackNetwork { training = True } seed p x |> Nn.crossEntropyIndices y
    , measure = Train.measure stackParams testImages (\p ( x, y ) -> correct (stackNetwork { training = False } (Random.seed (T.int 0)) p x) y)
    , initial = Train.initial stackParams adam 42
    , seeded = True
    , epochs = 5
    , loads = []
    , saves = []
    , base = Nothing
    }



-- A CONVOLUTIONAL NETWORK


type Side
    = Side


type Half
    = Half


type Quarter
    = Quarter


type C32
    = C32


type C64
    = C64


type Flat
    = Flat


type alias CnnParams =
    { conv1 : Conv2d F32 T.One C32, conv2 : Conv2d F32 C32 C64, out : Linear F32 Flat Classes }


side : Dim Side
side =
    T.dim Side 28


half : Dim Half
half =
    T.dim Half 14


quarter : Dim Quarter
quarter =
    T.dim Quarter 7


cnnParams : Param.Spec CnnParams
cnnParams =
    Param.record CnnParams
        |> Param.sub .conv1 (Conv2d.params T.float32 { kernel = ( 3, 3 ) } T.one (T.dim C32 32))
        |> Param.sub .conv2 (Conv2d.params T.float32 { kernel = ( 3, 3 ) } (T.dim C32 32) (T.dim C64 64))
        |> Param.sub .out (Linear.params T.float32 (T.dim Flat (7 * 7 * 64)) classes)


cnnNetwork : CnnParams -> Tensor Integral U8 (R2 n Pixels) -> Tensor Floating F32 (R2 n Classes)
cnnNetwork p x =
    x
        |> T.toFloat
        |> T.scale (1 / 255)
        |> T.factorLast3 side side
        |> T.insertOne Axis.axis3of4
        |> Conv2d.applySame p.conv1
        |> T.relu
        |> Nn.maxPool2d 2 half half
        |> Conv2d.applySame p.conv2
        |> T.relu
        |> Nn.maxPool2d 2 quarter quarter
        |> T.flattenTail4 (T.dim Flat (7 * 7 * 64))
        |> Linear.apply p.out


cnn : Variant
cnn =
    { train = Train.step cnnParams adam images (\p ( x, y ) -> cnnNetwork p x |> Nn.crossEntropyIndices y)
    , measure = Train.measure cnnParams testImages (\p ( x, y ) -> correct (cnnNetwork p x) y)
    , initial = Train.initial cnnParams adam 42
    , seeded = False
    , epochs = 2
    , loads = []
    , saves = []
    , base = Nothing
    }



-- LORA ON A FROZEN, TRAINED NETWORK


type Rank
    = Rank


type alias LoraParams =
    { base1 : Linear F32 Pixels Hidden
    , base2 : Linear F32 Hidden Classes
    , adapt1 : Lora F32 Pixels Rank Hidden
    }


loraParams : Param.Spec LoraParams
loraParams =
    Param.record LoraParams
        |> Param.sub .base1 (Param.frozen (Linear.params T.float32 pixels hidden))
        |> Param.sub .base2 (Param.frozen (Linear.params T.float32 hidden classes))
        |> Param.sub .adapt1 (Lora.params T.float32 { rank = T.dim Rank 8, alpha = 16, initStd = 0.01 } pixels hidden)


loraNetwork : LoraParams -> Tensor Integral U8 (R2 n Pixels) -> Tensor Floating F32 (R2 n Classes)
loraNetwork p x =
    x |> T.toFloat |> T.scale (1 / 255) |> Lora.apply p.base1 p.adapt1 |> T.relu |> Linear.apply p.base2


lora : Variant
lora =
    { train = Train.step loraParams adam images (\p ( x, y ) -> loraNetwork p x |> Nn.crossEntropyIndices y)
    , measure = Train.measure loraParams testImages (\p ( x, y ) -> correct (loraNetwork p x) y)
    , initial = Train.initial loraParams adam 42
    , seeded = False
    , epochs = 1
    , loads = []
    , saves = List.map (\i -> "frozen" ++ String.fromInt i) (List.range 0 3)
    , base =
        Just
            { files = paramNames 4
            , residents =
                \block ->
                    -- the saved network as a parameter block of `MnistNet.params`, through
                    -- Train.initialFrom; its parameters become the frozen layers
                    Train.initialFrom Net.params adam block
                        |> List.filter (\( n, _ ) -> String.startsWith "param" n)
                        |> List.map (\( n, b ) -> ( "frozen" ++ String.dropLeft 5 n, b ))
            }
    }
