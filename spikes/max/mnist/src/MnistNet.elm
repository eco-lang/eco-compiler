module MnistNet exposing
    ( Params, params, network, trainStep, evaluate
    , Pixels, Hidden, Classes, Batch, Test, pixels, hidden, classes, batch, test
    , batchSize, testSize, learningRate, epochs
    )

{-| The MNIST network (784 → 128 ReLU → 10) and its training, written with the typed tensor API
(`eco-lab/tensor`): the parameters, the forward pass, the training step and the evaluation.

Dimensions are types: swapping the layers, feeding raw pixels to a layer, or a bias with a batch
dimension does not compile. The network is generic in the number of images `n`, so the training
batch and the test set use the same function.

-}

import Graph exposing (Graph)
import Nn
import Nn.Linear as Linear exposing (Linear)
import Optim
import Param
import Signature as Sig
import Tensor as T exposing (Dim, F32, Floating, Integral, R2, Tensor, U8)
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


batchSize : Int
batchSize =
    100


testSize : Int
testSize =
    10000


learningRate : Float
learningRate =
    0.1


epochs : Int
epochs =
    5


batch : Dim Batch
batch =
    T.dim Batch batchSize


test : Dim Test
test =
    T.dim Test testSize


type alias Params =
    { l1 : Linear F32 Pixels Hidden
    , l2 : Linear F32 Hidden Classes
    }


params : Param.Spec Params
params =
    Param.record Params
        |> Param.sub .l1 (Linear.params T.float32 pixels hidden)
        |> Param.sub .l2 (Linear.params T.float32 hidden classes)


{-| Any number of images `n`.
-}
network : Params -> Tensor Integral U8 (R2 n Pixels) -> Tensor Floating F32 (R2 n Classes)
network p images =
    images
        |> T.toFloat
        |> T.scale (1 / 255)
        |> Linear.apply p.l1
        |> T.relu
        |> Linear.apply p.l2


trainStep : Result (List String) Graph
trainStep =
    Train.step params (Optim.sgd learningRate) (Sig.pair (Sig.u8 (T.r2 batch pixels)) (Sig.u8 (T.r1 batch))) <|
        \p ( x, y ) -> network p x |> Nn.crossEntropyIndices y


{-| The number of test images the network classifies correctly.
-}
evaluate : Result (List String) Graph
evaluate =
    Train.measure params (Sig.pair (Sig.u8 (T.r2 test pixels)) (Sig.u8 (T.r1 test))) <|
        \p ( x, y ) ->
            network p x
                |> T.argMax Axis.last2
                |> T.equals (T.toInt y)
                |> T.indicator T.float32
                |> T.sumAll
