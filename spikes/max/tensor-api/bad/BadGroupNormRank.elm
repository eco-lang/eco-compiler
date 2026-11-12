module BadGroupNormRank exposing (..)

import Nn.GroupNorm as GroupNorm exposing (GroupNorm)
import Round2 exposing (..)
import Tensor as T exposing (F32, R2, Tensor)


-- GroupNorm normalises NHWC images, not matrices
f : GroupNorm F32 Ch -> Tensor Float F32 (R2 Batch Ch) -> Tensor Float F32 (R2 Batch Ch)
f p x =
    GroupNorm.apply p x
