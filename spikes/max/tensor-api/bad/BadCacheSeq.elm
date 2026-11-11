module BadCacheSeq exposing (..)

import Nn.KvCache as KvCache
import Round2 exposing (..)
import Tensor as T exposing (F32, Floating, I64, Integral, R0, R3, Tensor)


-- keys with all four query heads, written into a cache of two key/value heads
f : Cache -> Tensor Integral I64 R0 -> Tensor Floating F32 (R3 Heads Seq HeadDim) -> Cache
f cache position keys =
    KvCache.write position keys keys cache
