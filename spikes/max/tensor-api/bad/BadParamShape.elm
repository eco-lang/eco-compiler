module BadParamShape exposing (..)

import MnistNet exposing (..)
import Nn
import Nn.Linear as Linear exposing (Linear)
import Optim
import Param
import Signature as Sig
import Tensor as T exposing (F32, Floating, I64, Integral, R0, R1, R2, Tensor, U8)
import Tensor.Axis as Axis
import Train


type alias P2 =
    { w : Tensor Floating F32 (R2 Pixels Hidden) }


p2 : Param.Spec P2
p2 =
    Param.record P2 |> Param.heUniform .w T.float32 (T.r2 hidden pixels)
