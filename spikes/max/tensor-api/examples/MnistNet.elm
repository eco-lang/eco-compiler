module MnistNet exposing (..)

import Graph exposing (Graph)
import Nn
import Nn.Linear as Linear exposing (Linear)
import Optim
import Param
import Signature as Sig
import Tensor as T exposing (Dim, F32, Floating, I64, Integral, R2, Tensor, U8)
import Tensor.Axis as Axis
import Train


type Pixels
    = Pixels


type Hidden
    = Hidden


type Classes
    = Classes


type Batch
    = Batch


type Test
    = Test


pixels : Dim Pixels
pixels =
    T.dim Pixels 784


hidden : Dim Hidden
hidden =
    T.dim Hidden 128


classes : Dim Classes
classes =
    T.dim Classes 10


batch : Dim Batch
batch =
    T.dim Batch 100


test : Dim Test
test =
    T.dim Test 10000


type alias Params =
    { l1 : Linear F32 Pixels Hidden
    , l2 : Linear F32 Hidden Classes
    }


params : Param.Spec Params
params =
    Param.record Params
        |> Param.sub .l1 (Linear.params T.float32 pixels hidden)
        |> Param.sub .l2 (Linear.params T.float32 hidden classes)


network : Params -> Tensor Integral U8 (R2 n Pixels) -> Tensor Floating F32 (R2 n Classes)
network p images =
    images
        |> T.toFloat
        |> T.scale (1 / 255)
        |> Linear.apply p.l1
        |> T.relu
        |> Linear.apply p.l2


optimizer : Optim.Optimizer
optimizer =
    Optim.adamWWith { rate = Optim.PerStep, beta1 = 0.9, beta2 = 0.999, epsilon = 1.0e-8, weightDecay = 0, biasCorrection = True }


trainStep : Result (List String) Graph
trainStep =
    Train.step params optimizer (Sig.pair (Sig.u8 (T.r2 batch pixels)) (Sig.u8 (T.r1 batch))) <|
        \p ( x, y ) -> network p x |> Nn.crossEntropyIndices y


evaluate : Result (List String) Graph
evaluate =
    Train.measure params (Sig.pair (Sig.u8 (T.r2 test pixels)) (Sig.u8 (T.r1 test))) <|
        \p ( x, y ) ->
            network p x
                |> T.argMax Axis.last2
                |> T.equals (T.toInt y)
                |> T.indicator T.float32
                |> T.sumAll
