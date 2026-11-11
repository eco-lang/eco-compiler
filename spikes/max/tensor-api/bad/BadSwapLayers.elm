module BadSwapLayers exposing (..)

import MnistNet exposing (..)
import Nn
import Nn.Linear as Linear exposing (Linear)
import Optim
import Param
import Signature as Sig
import Tensor as T exposing (F32, Floating, I64, Integral, R0, R1, R2, Tensor, U8)
import Tensor.Axis as Axis
import Train


f : Params -> Tensor Integral U8 (R2 n Pixels) -> Tensor Floating F32 (R2 n Classes)
f p x =
    x |> T.toFloat |> Linear.apply p.l2 |> T.relu |> Linear.apply p.l1
