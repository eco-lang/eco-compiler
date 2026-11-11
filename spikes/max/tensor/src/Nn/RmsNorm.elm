module Nn.RmsNorm exposing (RmsNorm, params, apply, apply3)

{-| Root-mean-square normalisation over the last axis with a learned scale (Llama and its family):
y = x / sqrt (mean x² + ε) · scale. Half-precision inputs are normalised in f32 and cast back.
-}

import Param
import Tensor as T exposing (DType, Dim, Floating, R1, R2, R3, Tensor)
import Tensor.Internal.Expr as E exposing (Expr)
import Tensor.Internal.Ops as O
import Tensor.Internal.Prim as P
import Tensor.Internal.Types as I


type alias RmsNorm d m =
    { scale : Tensor Floating d (R1 m), epsilon : Float }


{-| Scale ones.
-}
params : DType Floating d -> { epsilon : Float } -> Dim m -> Param.Spec (RmsNorm d m)
params dt cfg m =
    Param.record RmsNorm
        |> Param.ones .scale dt (T.r1 m)
        |> Param.config .epsilon cfg.epsilon


apply : RmsNorm d m -> Tensor Floating d (R2 n m) -> Tensor Floating d (R2 n m)
apply p x =
    I.Tensor (normalise p.epsilon (I.tensor p.scale) (I.tensor x))


{-| The same over a batch of sequences.
-}
apply3 : RmsNorm d m -> Tensor Floating d (R3 b n m) -> Tensor Floating d (R3 b n m)
apply3 p x =
    I.Tensor (normalise p.epsilon (I.tensor p.scale) (I.tensor x))


normalise : Float -> Expr -> Expr -> Expr
normalise epsilon scale x =
    let
        last =
            E.rank x - 1

        norm v =
            let
                inv =
                    O.unary P.Rsqrt (O.add (O.reduce P.ReduceMean last (O.square v)) (O.scalarLike epsilon v))
            in
            O.mul v (O.broadcastAxis last inv)
    in
    O.mul (O.inF32 norm x) (O.leadingAxes last scale)
