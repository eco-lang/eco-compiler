module Nn.GroupNorm exposing (GroupNorm, params, apply)

{-| Group normalisation of NHWC images (diffusion UNets and VAEs): the channels are split into
`groups` groups, each normalised over its channels and all positions, then scaled and shifted per
channel. The channel axis is factored in place, keeping channel order, so a PyTorch (NCHW) model's
groups carry over. Half-precision inputs are normalised in f32 and cast back.
-}

import Param
import Tensor as T exposing (DType, Dim, Floating, R1, R4, Tensor)
import Tensor.Internal.Expr as E exposing (Expr)
import Tensor.Internal.Ops as O
import Tensor.Internal.Prim as P
import Tensor.Internal.Types as I


type alias GroupNorm d c =
    { scale : Tensor Floating d (R1 c), bias : Tensor Floating d (R1 c), groups : Int, epsilon : Float }


{-| Scale ones, bias zeros.
-}
params : DType Floating d -> { groups : Int, epsilon : Float } -> Dim c -> Param.Spec (GroupNorm d c)
params dt cfg c =
    Param.record GroupNorm
        |> Param.ones .scale dt (T.r1 c)
        |> Param.zeros .bias dt (T.r1 c)
        |> Param.config .groups cfg.groups
        |> Param.config .epsilon cfg.epsilon


apply : GroupNorm d c -> Tensor Floating d (R4 n h w c) -> Tensor Floating d (R4 n h w c)
apply p x =
    I.Tensor (groupNorm p.groups p.epsilon (I.tensor p.scale) (I.tensor p.bias) (I.tensor x))


groupNorm : Int -> Float -> Expr -> Expr -> Expr -> Expr
groupNorm groups epsilon scale bias x =
    case E.shape x of
        [ n, h, w, c ] ->
            if groups <= 0 || modBy groups c /= 0 then
                E.failWith ("GroupNorm: " ++ String.fromInt groups ++ " groups do not divide " ++ String.fromInt c ++ " channels") x

            else
                let
                    -- [n, positions, group, channel in group]; statistics over axes 1 and 3
                    stat v =
                        O.reduce P.ReduceMean 1 (O.reduce P.ReduceMean 3 v)
                            |> O.broadcastAxis 1
                            |> O.broadcastAxis 3

                    norm v =
                        let
                            r =
                                O.reshape [ n, h * w, groups, c // groups ] v

                            centred =
                                O.sub r (stat r)

                            inv =
                                O.unary P.Rsqrt (O.add (stat (O.square centred)) (O.scalarLike epsilon centred))
                        in
                        O.reshape [ n, h, w, c ] (O.mul centred inv)
                in
                O.add (O.mul (O.inF32 norm x) (O.leadingAxes 3 scale)) (O.leadingAxes 3 bias)

        _ ->
            E.failWith "GroupNorm: needs an NHWC tensor" x
