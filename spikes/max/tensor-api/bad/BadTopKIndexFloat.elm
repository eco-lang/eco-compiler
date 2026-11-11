module BadTopKIndexFloat exposing (..)

import Round2 exposing (..)
import Tensor as T exposing (F32, Floating, R2, Tensor)
import Tensor.Axis as Axis


-- topK's indices are integers: they cannot be added to logits
f : Tensor Floating F32 (R2 Seq Vocab) -> Tensor Floating F32 (R2 Seq Top)
f logits =
    let
        ( values, indices ) =
            T.topK Axis.retag1of2 (T.dim Top 5) logits
    in
    values |> T.plus indices
