module Extras exposing (..)

import Finetune.Qlora as Qlora exposing (Quantized)
import MnistNet exposing (Hidden, Params, Pixels, hidden, pixels, params)
import Optim
import Param
import Tensor as T exposing (Dim, Elems, F32, Floating, R1, R2, Tensor)
import Tensor.Axis as Axis
import Transform


{-| Lion (Chen et al. 2023), written element-wise: one state slot per parameter.
-}
lion : Optim.Optimizer
lion =
    Optim.custom
        { rate = Optim.Fixed 1.0e-4
        , slots = 1
        , update =
            \h { param, grad, state } ->
                let
                    m =
                        List.head state |> Maybe.withDefault (T.zerosLike grad)

                    direction =
                        m |> T.scale 0.9 |> T.plus (grad |> T.scale 0.1) |> T.sign
                in
                { param = param |> T.minus (direction |> T.times (T.fillLike h.rate direction))
                , state = [ m |> T.scale 0.99 |> T.plus (grad |> T.scale 0.01) ]
                }
        }
        |> Optim.clipGlobalNorm 1.0


{-| Weight decay applied by hand to every parameter of a record.
-}
decayed : Params -> Params
decayed =
    Param.mapElems (T.scale 0.999) params


type Rows
    = Rows


{-| Per-example forward passes of a function of two tensors, one of them shared.
-}
perExample : Tensor Floating F32 (R2 Hidden Pixels) -> Tensor Floating F32 (R2 Rows Pixels) -> Tensor Floating F32 (R2 Rows Hidden)
perExample w =
    Transform.vmapWith (Transform.pair Transform.keep (Transform.tensor Axis.liftRank1)) (Transform.tensor Axis.liftRank1)
        (\( wt, x ) -> wt |> T.matVec x)
        << Tuple.pair w


type alias Frozen =
    { q : Quantized F32 Pixels Hidden }


frozen : Param.Spec Frozen
frozen =
    Param.record Frozen |> Param.sub .q (Qlora.params T.float32 64 pixels hidden)


three : Dim Rows
three =
    T.dim Rows 3


stacked : Tensor Floating F32 (R1 Pixels) -> Tensor Floating F32 (R2 Rows Pixels)
stacked x =
    T.stack Axis.liftRank1 three [ x, x, x ]
