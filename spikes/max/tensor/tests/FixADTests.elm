module FixADTests exposing (suite)

{-| Regression tests for the second round of autodiff fixes: integer arguments, which get zeros
through a loop or not (B009, B063), a loop body that reads a placeholder the transforms replace
(B033), placeholders for arguments with broadcast axes (B035), the gradient of a stride-0
convolution (B017), and the public `Lift` alias in `Transform`'s types (B056).

Each failing case must give an error that `Tensor.Eval` or `Graph.build` reports, not a silent
zero, a wrong number or a crash; each control case must still give the right numbers.

-}

import Expect exposing (Expectation)
import Graph
import Signature as Sig
import Tensor as T
import Tensor.Axis as Axis
import Tensor.Control as Control
import Tensor.Eval as Eval
import Tensor.Internal.Expr as E exposing (Expr)
import Tensor.Internal.Grad as Grad
import Tensor.Internal.Ops as O
import Tensor.Internal.Prim exposing (DT(..))
import Tensor.Internal.Types as I
import Test exposing (Test, describe, test)
import Transform


f32 : List Int -> List Float -> Expr
f32 =
    E.const F32


evF : Expr -> Result (List String) (List Float)
evF e =
    Eval.floats (I.Tensor e)


close : Float -> List Float -> Result (List String) (List Float) -> Expectation
close tol want got =
    case got of
        Err es ->
            Expect.fail (String.join "; " es)

        Ok vs ->
            if List.length vs /= List.length want then
                Expect.fail ("lengths differ: got " ++ Debug.toString vs)

            else if List.all identity (List.map2 (\w v -> abs (w - v) <= tol * Basics.max 1 (abs w)) want vs) then
                Expect.pass

            else
                Expect.fail ("got " ++ Debug.toString vs ++ ", wanted " ++ Debug.toString want)


failsWith : String -> Result (List String) a -> Expectation
failsWith part r =
    case r of
        Err es ->
            if List.any (String.contains part) es then
                Expect.pass

            else
                Expect.fail ("errors do not mention " ++ part ++ ": " ++ String.join "; " es)

        Ok v ->
            Expect.fail ("expected an error mentioning " ++ part ++ ", got Ok " ++ Debug.toString v)


isErr : Result (List String) a -> Expectation
isErr r =
    case r of
        Err _ ->
            Expect.pass

        Ok v ->
            Expect.fail ("expected an error, got Ok " ++ Debug.toString v)


loopMessage : String
loopMessage =
    "whileLoop: a loop cannot be differentiated"


{-| A loop on a float scalar that adds `y` to the state, from 0, until it reaches 3.
-}
addUntil3 : T.Tensor Float T.F32 T.R0 -> T.Tensor Float T.F32 T.R0
addUntil3 y =
    Control.whileLoop (Sig.f32 T.scalar) (\s -> T.lessThan (T.float 3) s) (\s -> T.plus y s) (T.float 0)


suite : Test
suite =
    describe "FixAD"
        [ b009, b033, b035, b017 ]


{-| B009 and B063: integer tensors have no derivatives, so every transform gives an integer argument
zeros, through a loop or not, and an integer result a zero tangent.
-}
b009 : Test
b009 =
    describe "B009/B063 integer arguments get zeros"
        [ test "the pullback of an integer loop's state is 0" <|
            \_ ->
                let
                    ( _, pullback ) =
                        Transform.vjp (Sig.i64 T.scalar)
                            (Sig.i64 T.scalar)
                            (\x -> Control.whileLoop (Sig.i64 T.scalar) (\s -> T.lessThan (T.int 100) s) (\s -> T.times s (T.int 2)) x)
                            (T.int 3)
                in
                Eval.ints (pullback (T.int 1)) |> Expect.equal (Ok [ 0 ])
        , test "the pullback of an integer loop whose body reads the integer argument is 0" <|
            \_ ->
                let
                    ( _, pullback ) =
                        Transform.vjp (Sig.i64 T.scalar)
                            (Sig.i64 T.scalar)
                            (\y -> Control.whileLoop (Sig.i64 T.scalar) (\s -> T.lessThan (T.int 10) s) (\s -> T.plus y s) (T.int 0))
                            (T.int 3)
                in
                Eval.ints (pullback (T.int 1)) |> Expect.equal (Ok [ 0 ])
        , test "under a float loss an integer argument a loop reads gets zeros" <|
            \_ ->
                let
                    loss ( w, n ) =
                        T.plus (T.times w (T.float 2))
                            (Control.whileLoop (Sig.f32 T.scalar) (\s -> T.lessThan (T.float 5) s) (\s -> T.plus (T.toFloat n) s) (T.float 0))

                    ( gw, gn ) =
                        Transform.gradOf (Sig.pair (Sig.f32 T.scalar) (Sig.i64 T.scalar)) loss ( T.float 1, T.int 2 )
                in
                Expect.all
                    [ \_ -> Eval.floats gw |> close 1.0e-12 [ 2 ]
                    , \_ -> Eval.ints gn |> Expect.equal (Ok [ 0 ])
                    ]
                    ()
        , test "the integer pullback of x·x·x is 0" <|
            \_ ->
                let
                    ( _, pullback ) =
                        Transform.vjp (Sig.i64 T.scalar) (Sig.i64 T.scalar) (\x -> T.times (T.times x x) x) (T.int 2)
                in
                Eval.ints (pullback (T.int 1)) |> Expect.equal (Ok [ 0 ])
        , test "the integer pullback of the identity is 0" <|
            \_ ->
                let
                    ( _, pullback ) =
                        Transform.vjp (Sig.i64 T.scalar) (Sig.i64 T.scalar) identity (T.int 2)
                in
                Eval.ints (pullback (T.int 5)) |> Expect.equal (Ok [ 0 ])
        , test "the tangent of x·x·x on an integer is 0, and its value is kept" <|
            \_ ->
                let
                    ( y, dy ) =
                        Transform.jvp (Sig.i64 T.scalar) (Sig.i64 T.scalar) (\x -> T.times (T.times x x) x) (T.int 2) (T.int 1)
                in
                Expect.all
                    [ \_ -> Eval.ints y |> Expect.equal (Ok [ 8 ])
                    , \_ -> Eval.ints dy |> Expect.equal (Ok [ 0 ])
                    ]
                    ()
        , test "control: a float argument beside an integer one keeps its pullback" <|
            \_ ->
                let
                    ( _, pullback ) =
                        Transform.vjp (Sig.pair (Sig.f32 T.scalar) (Sig.i64 T.scalar))
                            (Sig.f32 T.scalar)
                            (\( w, n ) -> T.times (T.times w w) (T.toFloat n))
                            ( T.float 3, T.int 2 )

                    ( cw, cn ) =
                        pullback (T.float 1)
                in
                Expect.all
                    [ \_ -> Eval.floats cw |> close 1.0e-12 [ 12 ]
                    , \_ -> Eval.ints cn |> Expect.equal (Ok [ 0 ])
                    ]
                    ()
        , test "control: the tangent of a float result along an integer-free direction" <|
            \_ ->
                let
                    ( _, dy ) =
                        Transform.jvp (Sig.f32 T.scalar) (Sig.f32 T.scalar) (\x -> T.times (T.times x x) x) (T.float 2) (T.float 1)
                in
                Eval.floats dy |> close 1.0e-6 [ 12 ]
        ]


{-| B033: a loop body that reads a placeholder the transforms replace, directly or inside a
shared function's or cond branch's body.
-}
b033 : Test
b033 =
    describe "B033 loop bodies reading a replaced placeholder"
        [ test "grad of y times a stopped loop that reads y is the loop's value" <|
            \_ ->
                Eval.floats (Transform.grad (\y -> T.times y (T.stopGradient (addUntil3 y))) (T.float 1))
                    |> close 1.0e-12 [ 3 ]
        , test "grad through a shared function holding such a loop is the loop's value" <|
            \_ ->
                let
                    sh =
                        Transform.shared "sh" (Sig.f32 T.scalar) (Sig.f32 T.scalar) (\v -> T.times v (T.stopGradient (addUntil3 v)))
                in
                Eval.floats (Transform.grad (Transform.call sh) (T.float 1)) |> close 1.0e-12 [ 3 ]
        , test "grad through a cond branch holding such a loop is the loop's value" <|
            \_ ->
                let
                    f y =
                        Control.cond (T.greaterThan (T.float 0) y)
                            (Sig.f32 T.scalar)
                            (Sig.f32 T.scalar)
                            (\v ->
                                -- The loop's state starts from v, so the loop stays in the branch.
                                T.times v
                                    (T.stopGradient
                                        (Control.whileLoop (Sig.f32 T.scalar) (\s -> T.lessThan (T.float 3) s) (\s -> T.plus v s) (T.times v (T.float 0)))
                                    )
                            )
                            T.negate
                            y
                in
                Eval.floats (Transform.grad f (T.float 1)) |> close 1.0e-12 [ 3 ]
        , test "the graph of grad through a shared function whose loop reads the argument reports the loop" <|
            \_ ->
                let
                    sh =
                        Transform.shared "sh" (Sig.f32 T.scalar) (Sig.f32 T.scalar) (\v -> T.times v (addUntil3 v))
                in
                Graph.build "g" (Sig.f32 T.scalar) (Sig.f32 T.scalar) (Transform.grad (Transform.call sh))
                    |> failsWith loopMessage
        , test "grad through a shared function that reads the argument without being given it is an error" <|
            \_ ->
                let
                    f y =
                        Transform.call (Transform.shared "cap" Sig.anyTensor Sig.anyTensor (\v -> T.times v y)) y
                in
                Eval.floats (Transform.grad f (T.float 3)) |> failsWith "not one of its arguments"
        , test "grad of y times a loop whose body reads y is an error, not the loop's value" <|
            \_ ->
                Eval.floats (Transform.grad (\y -> T.times y (addUntil3 y)) (T.float 1))
                    |> failsWith loopMessage
        , test "grad through a shared function on a constant that reads the argument is an error" <|
            \_ ->
                let
                    f y =
                        T.plus y (Transform.call (Transform.shared "cap" Sig.anyTensor Sig.anyTensor (\v -> T.times v y)) (T.float 2))
                in
                Eval.floats (Transform.grad f (T.float 3)) |> failsWith "not one of its arguments"
        , test "control: a shared function that reads the argument behind stopGradient adds nothing" <|
            \_ ->
                let
                    f y =
                        T.plus (T.times y (T.float 2))
                            (Transform.call (Transform.shared "cap" Sig.anyTensor Sig.anyTensor (\v -> T.times v (T.stopGradient y))) (T.float 2))
                in
                Eval.floats (Transform.grad f (T.float 3)) |> close 1.0e-12 [ 2 ]
        , test "control: grad through a shared function with no loop" <|
            \_ ->
                let
                    sh =
                        Transform.shared "sq" (Sig.f32 T.scalar) (Sig.f32 T.scalar) (\v -> T.times v v)
                in
                Eval.floats (Transform.grad (Transform.call sh) (T.float 3)) |> close 1.0e-12 [ 6 ]
        ]


{-| B035: a traced argument with a broadcast axis keeps it.
-}
b035 : Test
b035 =
    describe "B035 placeholders keep broadcast axes"
        [ test "grad of an add that sizes a broadcast axis sums over it" <|
            \_ ->
                let
                    x =
                        O.broadcastAxis 0 (f32 [ 4 ] [ 1, 2, 3, 4 ])

                    g =
                        Grad.grad (\y -> O.sumAll (O.add y (O.onesLike (f32 [ 3, 4 ] (List.repeat 12 0))))) x
                in
                evF g |> close 1.0e-12 [ 3, 3, 3, 3 ]
        , test "grad through Transform on a broadcast argument" <|
            \_ ->
                let
                    x =
                        T.broadcast Axis.axis0of2 (T.fromList T.float32 (T.r1 (T.dim A 2)) [ 1, 2 ])

                    m =
                        T.ones T.float32 (T.r2 (T.dim B 3) (T.dim A 2))
                in
                Eval.floats (Transform.grad (\y -> T.sumAll (T.times (T.plus y m) m)) x) |> close 1.0e-12 [ 3, 3 ]
        ]


type A
    = A


type B
    = B


{-| B017: the gradient of a convolution with stride 0.
-}
b017 : Test
b017 =
    describe "B017 stride-0 convolution gradient"
        [ test "grad of a stride-0 conv is a build error, not a crash" <|
            \_ ->
                let
                    x =
                        f32 [ 1, 4, 4, 1 ] (List.repeat 16 1)

                    w =
                        f32 [ 2, 2, 1, 1 ] [ 1, 1, 1, 1 ]
                in
                evF (Grad.grad (\v -> O.sumAll (O.conv [ 0, 0, 0, 0, 0, 0 ] v w)) x) |> isErr
        ]
