module BadLoraShape exposing (..)

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


type Rank = Rank

g : Linear F32 Pixels Hidden -> Lora F32 Hidden Rank Pixels -> Tensor Floating F32 (R2 n Pixels) -> Tensor Floating F32 (R2 n Hidden)
g base adapter x =
    x |> Lora.apply base adapter
