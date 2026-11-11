module MnistNet exposing
    ( Params, params, network, trainStep, evaluate
    , hidden, batchSize, testSize, learningRate, epochs
    )

{-| The MNIST network and its training, and nothing else: 784 pixels → 128 ReLU units → 10 class
scores, trained by stochastic gradient descent on the mean cross-entropy, scored by how many test
images it classifies correctly. `Mnist` runs it on MAX.

-}

import Param
import Tensor as T exposing (F32, Tensor, U8)
import Train


hidden : Int
hidden =
    128


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


type alias Params a =
    { w1 : a, b1 : a, w2 : a, b2 : a }


params : Param.Spec (Params (Tensor F32))
params =
    Param.record Params
        |> Param.weights .w1 [ 784, hidden ]
        |> Param.zeros .b1 [ hidden ]
        |> Param.weights .w2 [ hidden, 10 ]
        |> Param.zeros .b2 [ 10 ]


{-| 784 pixels (bytes 0-255) → 128 ReLU units → 10 class scores.
-}
network : Params (Tensor F32) -> Tensor U8 -> Tensor F32
network p pixels =
    pixels
        |> T.toFloat
        |> T.scale (1 / 255)
        |> T.matmul p.w1
        |> T.plus p.b1
        |> T.relu
        |> T.matmul p.w2
        |> T.plus p.b2


{-| A batch of `n` images (784 pixel bytes each) and their labels (bytes 0-9).
-}
batch : Int -> T.Arg ( Tensor U8, Tensor U8 )
batch n =
    T.pair (T.u8 [ n, 784 ]) (T.u8 [ n ])


{-| One step of stochastic gradient descent on the mean cross-entropy of a batch.
-}
trainStep : Result (List String) T.Graph
trainStep =
    Train.step params (Train.sgd learningRate) (batch batchSize) <|
        \p ( x, y ) -> network p x |> T.crossEntropy (T.oneHot 10 y)


{-| How many of the test images the network classifies correctly.
-}
evaluate : Result (List String) T.Graph
evaluate =
    Train.measure params (batch testSize) <|
        \p ( x, y ) ->
            network p x
                |> T.argMax 1
                |> T.equals (y |> T.toInt |> T.column)
                |> T.toFloat
                |> T.sum 0
