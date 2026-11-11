module BadIntSoftmax exposing (..)

import Finetune.Lora as Lora exposing (Lora)
import MnistNet exposing (..)
import Nn
import Nn.Conv2d as Conv2d
import Nn.Linear as Linear exposing (Linear)
import Param
import Signature as Sig
import Tensor as T exposing (Dim, F32, Floating, I64, Integral, Mask, R0, R1, R2, R3, R4, Tensor, U8)
import Tensor.Axis as Axis
import Transform


r : Tensor Integral I64 (R2 n Classes) -> Tensor Integral I64 (R2 n Classes)
r x =
    x |> T.softmax Axis.last2
