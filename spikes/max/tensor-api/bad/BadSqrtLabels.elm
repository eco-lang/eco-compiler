module BadSqrtLabels exposing (..)

import MnistNet exposing (..)
import Nn
import Nn.Linear as Linear exposing (Linear)
import Optim
import Param
import Signature as Sig
import Tensor as T exposing (F32, Floating, I64, Integral, R0, R1, R2, Tensor, U8)
import Tensor.Axis as Axis
import Train


f : Tensor Integral U8 (R1 Batch) -> Tensor Integral U8 (R1 Batch)
f y =
    y |> T.sqrt
