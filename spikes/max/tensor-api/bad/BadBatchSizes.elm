module BadBatchSizes exposing (..)

import MnistNet exposing (..)
import Nn
import Nn.Linear as Linear exposing (Linear)
import Optim
import Param
import Signature as Sig
import Tensor as T exposing (F32, Floating, I64, Integral, R0, R1, R2, Tensor, U8)
import Tensor.Axis as Axis
import Train


g =
    Train.step params (Optim.sgd 0.1) (Sig.pair (Sig.u8 (T.r2 batch pixels)) (Sig.u8 (T.r1 test))) <|
        \p ( x, y ) -> network p x |> Nn.crossEntropyIndices y
