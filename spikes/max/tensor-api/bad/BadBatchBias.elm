module BadBatchBias exposing (..)

import MnistNet exposing (..)
import Nn
import Nn.Linear as Linear exposing (Linear)
import Optim
import Param
import Signature as Sig
import Tensor as T exposing (F32, I64, R0, R1, R2, Tensor, U8)
import Tensor.Axis as Axis
import Train


f : Tensor Float F32 (R2 Pixels Hidden) -> Tensor Float F32 (R2 Batch Hidden) -> Tensor Float F32 (R2 n Pixels) -> Tensor Float F32 (R2 n Hidden)
f w b x =
    x |> T.matmul w |> T.plus b
