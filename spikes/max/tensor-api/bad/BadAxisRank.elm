module BadAxisRank exposing (..)

import MnistNet exposing (..)
import Tensor as T exposing (F32, Floating, R1, R2, Tensor)
import Tensor.Axis as Axis


m : Tensor Floating F32 (R2 n Classes) -> Tensor Floating F32 (R1 n)
m logits =
    logits |> T.sum Axis.last3
