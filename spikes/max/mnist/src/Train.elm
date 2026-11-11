module Train exposing (Optimizer, sgd, step, measure, stepReply, measureReply)

{-| Training graphs from a loss: the user writes the loss, `Train` writes the rest.

    trainStep =
        Train.step params (Train.sgd 0.1) (batch 100) <|
            \p ( x, y ) -> network p x |> T.crossEntropy (T.oneHot 10 y)

`step` declares the inputs (the parameters `param0` .., then the batch `batch0` ..), takes the
gradients of the loss, applies the optimizer and returns the new parameters (`next0` ..) and the
`loss`. The new parameters come back in the packed layout they went out in, so the host's reply
feeds the next step unchanged (`stepReply`).

-}

import Bridge
import Bytes exposing (Bytes, Endianness(..))
import Bytes.Decode as Decode
import Param
import Tensor as T exposing (F32, Tensor)


{-| How parameters move along their gradients: the loss and the parameters to the new parameters.
-}
type Optimizer
    = Optimizer (Tensor F32 -> List (Tensor F32) -> List (Tensor F32))


{-| Stochastic gradient descent: each parameter minus `rate` times its gradient.
-}
sgd : Float -> Optimizer
sgd rate =
    Optimizer
        (\loss ws ->
            List.map2 (\w g -> w |> T.minus (g |> T.scale rate)) ws (T.grad loss ws)
        )


{-| The graph `train_step`: one optimizer step on `loss`, for one batch.
-}
step : Param.Spec r -> Optimizer -> T.Arg batch -> (r -> batch -> Tensor F32) -> Result (List String) T.Graph
step params (Optimizer update) batch loss =
    T.graph "train_step"
        (T.pair (Param.arg params) (T.label "batch" batch))
        (T.outPair (T.labelOut "next" (T.outList T.tensor)) (T.labelOut "loss" T.tensor))
        (\( p, b ) ->
            let
                l =
                    loss p b
            in
            ( update l (Param.toList params p), l )
        )


{-| The graph `measure`: one value computed from the parameters and a batch, such as the number of
examples the network gets right.
-}
measure : Param.Spec r -> T.Arg batch -> (r -> batch -> Tensor a) -> Result (List String) T.Graph
measure params batch f =
    T.function "measure" (T.pair (Param.arg params) (T.label "batch" batch)) (\( p, b ) -> f p b)


{-| A `step` reply (after its 16-byte header): the new parameter block and the f32 loss.
-}
stepReply : Param.Spec r -> Bytes -> ( Bytes, Float )
stepReply params bytes =
    let
        size =
            Param.blockSize params
    in
    ( Bridge.slice 16 size bytes, float (16 + size) bytes )


{-| A `measure` reply: its f32 value.
-}
measureReply : Bytes -> Float
measureReply =
    float 16


float : Int -> Bytes -> Float
float offset bytes =
    Maybe.withDefault 0 (Decode.decode (Decode.float32 LE) (Bridge.slice offset 4 bytes))
