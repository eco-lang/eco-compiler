module LoraTune exposing (..)

import Finetune.Lora as Lora exposing (Lora)
import Graph exposing (Graph)
import MnistNet exposing (Classes, Hidden, Pixels, classes, hidden, pixels)
import Nn
import Nn.Linear as Linear exposing (Linear)
import Optim
import Param
import Signature as Sig
import Tensor as T exposing (Dim, F32, Floating, Integral, R2, Tensor, U8)
import Train


type Rank
    = Rank


rank : Dim Rank
rank =
    T.dim Rank 8


type alias Params =
    { base1 : Linear F32 Pixels Hidden
    , base2 : Linear F32 Hidden Classes
    , adapt1 : Lora F32 Pixels Rank Hidden
    }


params : Param.Spec Params
params =
    Param.record Params
        |> Param.sub .base1 (Param.frozen (Linear.params T.float32 pixels hidden))
        |> Param.sub .base2 (Param.frozen (Linear.params T.float32 hidden classes))
        |> Param.sub .adapt1 (Lora.params T.float32 { rank = rank, alpha = 16, initStd = 0.01 } pixels hidden)


network : Params -> Tensor Integral U8 (R2 n Pixels) -> Tensor Floating F32 (R2 n Classes)
network p x =
    x |> T.toFloat |> T.scale (1 / 255) |> Lora.apply p.base1 p.adapt1 |> T.relu |> Linear.apply p.base2


tune : Result (List String) Graph
tune =
    Train.step params (Optim.adamW 1.0e-3) (Sig.pair (Sig.u8 (T.r2 MnistNet.batch pixels)) (Sig.u8 (T.r1 MnistNet.batch))) <|
        \p ( x, y ) -> network p x |> Nn.crossEntropyIndices y
