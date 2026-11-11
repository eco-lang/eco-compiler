module BadCategoricalInt exposing (..)

import Round2 exposing (..)
import Tensor as T exposing (I64, Integral, R1, R2, Tensor)
import Tensor.Random as Random


-- sampling needs float logits
f : Tensor Integral I64 (R2 Seq Vocab) -> Random.Seed -> Tensor Integral I64 (R1 Seq)
f counts seed =
    Random.categorical counts seed
