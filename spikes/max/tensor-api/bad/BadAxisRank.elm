module BadAxisRank exposing (..)

import MnistNet exposing (..)
import Tensor as T exposing (F32, R1, R2, Tensor)
import Tensor.Axis as Axis


m : Tensor Float F32 (R2 n Classes) -> Tensor Float F32 (R1 n)
m logits =
    logits |> T.sum Axis.last3
