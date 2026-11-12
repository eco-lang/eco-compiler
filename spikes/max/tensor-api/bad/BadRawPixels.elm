module BadRawPixels exposing (..)

import MnistNet exposing (..)
import Nn
import Nn.Linear as Linear exposing (Linear)
import Optim
import Param
import Signature as Sig
import Tensor as T exposing (F32, I64, R0, R1, R2, Tensor, U8)
import Tensor.Axis as Axis
import Train


f : Params -> Tensor Int U8 (R2 n Pixels) -> Tensor Float F32 (R2 n Hidden)
f p x =
    x |> Linear.apply p.l1
