module BadGroupedHeadDim exposing (..)

import Nn.Attention as Attention
import Round2 exposing (..)
import Tensor as T exposing (F32)


-- keys and values projected with the query heads' tags (Heads instead of KvHeads)
bad : Attention.Grouped F32 Model KvW Heads Heads HeadDim -> Attention.Grouped F32 Model KvW Heads KvHeads HeadDim
bad g =
    g
