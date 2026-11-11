module BadArgMaxAxis exposing (..)

import MnistNet exposing (..)
import Nn
import Nn.Linear as Linear exposing (Linear)
import Optim
import Param
import Signature as Sig
import Tensor as T exposing (F32, Floating, I64, Integral, R0, R1, R2, Tensor, U8)
import Tensor.Axis as Axis
import Train


f : Params -> Tensor Integral U8 (R2 Test Pixels) -> Tensor Integral U8 (R1 Test) -> Tensor Floating F32 R0
f p x y =
    network p x |> T.argMax Axis.axis0of2 |> T.equals (T.toInt y) |> T.indicator T.float32 |> T.sumAll
