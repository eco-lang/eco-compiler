module Calculus exposing (..)

import Graph exposing (Graph)
import Signature as Sig
import Tensor as T exposing (Dim, F32, Floating, Mask, R0, R1, R2, Tensor)
import Tensor.Axis as Axis
import Tensor.Control as Control
import Transform


type N
    = N


n : Dim N
n =
    T.dim N 16


rosenbrock : Tensor Floating F32 (R1 N) -> Tensor Floating F32 R0
rosenbrock x =
    x |> T.times x |> T.sumAll


{-| Second derivatives: the gradient of a gradient, and a Hessian-vector product.
-}
newtonStep : Result (List String) Graph
newtonStep =
    Graph.build "newton"
        (Sig.pair (Sig.f32 (T.r1 n)) (Sig.f32 (T.r1 n)))
        (Sig.pair (Sig.f32 (T.r1 n)) (Sig.f32 (T.r2 n n)))
        (\( x, v ) ->
            ( Transform.hessianVector rosenbrock x v
            , Transform.jacobian (Transform.grad rosenbrock) x
            )
        )


{-| Halve until small: a loop MAX runs (forward only).
-}
shrink : Result (List String) Graph
shrink =
    Graph.function "shrink" (Sig.f32 (T.r1 n)) <|
        \x ->
            Control.whileLoop (Sig.f32 (T.r1 n))
                (\v -> v |> T.maximumAll |> T.greaterThan (T.float 1.0e-3))
                (T.scale 0.5)
                x


clipped : Result (List String) Graph
clipped =
    Graph.function "clipped" (Sig.f32 (T.r1 n)) <|
        \x ->
            Control.cond (x |> T.sumAll |> T.greaterThan (T.float 0))
                (Sig.f32 (T.r1 n))
                (Sig.f32 (T.r1 n))
                T.relu
                T.negate
                x
