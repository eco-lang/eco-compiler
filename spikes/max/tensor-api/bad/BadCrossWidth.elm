module BadCrossWidth exposing (..)

import Nn.Attention as Attention
import Round2 exposing (..)
import Tensor as T exposing (F32, Floating, R2, Tensor)


-- the memory (text, TextWidth wide) and the attending sequence (Ch wide) swapped
f : Block -> Tensor Floating F32 (R2 Text TextWidth) -> Tensor Floating F32 (R2 Seq Ch) -> Tensor Floating F32 (R2 Seq Ch)
f p text x =
    text |> Attention.attendTo p.cross x
