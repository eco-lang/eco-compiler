module BadRotarySeq exposing (..)

import Nn.Rotary as Rotary
import Round2 exposing (..)
import Tensor as T exposing (F32, Floating, R3, Tensor)


-- rotary positions of the context, applied to queries of the sequence
f : Tensor Floating F32 (R3 Heads Seq HeadDim) -> Tensor Floating F32 (R3 Heads Seq HeadDim)
f q =
    Rotary.apply rotary (T.iota context) q
