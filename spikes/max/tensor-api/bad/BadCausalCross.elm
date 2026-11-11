module BadCausalCross exposing (..)

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


f : Tensor Floating F32 (R3 h s j) -> Tensor Floating F32 (R3 h t j) -> Tensor Floating F32 (R3 h t e) -> Tensor Floating F32 (R3 h s e)
f q k v =
    q |> Nn.causalAttention k v
