module BadNoFlatten exposing (..)

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


k : Conv2d.Conv2d F32 Classes Hidden -> Linear F32 Hidden Classes -> Tensor Floating F32 (R4 n a b Classes) -> Tensor Floating F32 (R2 n Classes)
k conv out x =
    x |> Conv2d.applySame conv |> T.relu |> Linear.apply out
