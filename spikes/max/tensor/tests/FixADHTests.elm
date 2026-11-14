module FixADHTests exposing (suite)

{-| Regression tests for four autodiff issues: a loop body that reads the tensor being
differentiated (B001), `jvp` through an operation that has no gradient (B002), the cross-entropy
gradient for targets whose rows do not sum to 1 (B004), and a second derivative through a strided
convolution's filter (B003).

Each failing case must give an error that `Tensor.Eval` reports, not a silent zero; each control
case must still give the right numbers.

-}

import Expect exposing (Expectation)
import Nn
import Signature as Sig
import Tensor as T exposing (Dim)
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


type A
    = A


type B
    = B


a1 : Dim A
a1 =
    T.dim A 1


a2 : Dim A
a2 =
    T.dim A 2


a3 : Dim A
a3 =
    T.dim A 3


b2 : Dim B
b2 =
    T.dim B 2


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


loopMessage : String
loopMessage =
    "whileLoop: a loop cannot be differentiated"


suite : Test
suite =
    describe "FixADH"
        [ b001, b002, b004, b003 ]


{-| B001: a loop whose step body reads the tensor being differentiated directly.
-}
b001 : Test
b001 =
    describe "B001 loop body reading wrt"
        [ test "grad of a loop whose body adds the argument is an error, not 0" <|
            \_ ->
                let
                    f y =
                        Control.whileLoop (Sig.f32 T.scalar) (\s -> T.lessThan (T.float 3) s) (\s -> T.plus y s) (T.float 0)
                in
                Eval.floats (Transform.grad f (T.float 1)) |> failsWith loopMessage
        , test "grad of a loop whose body reads a tensor computed from the argument is an error" <|
            \_ ->
                let
                    f y =
                        let
                            z =
                                T.times y y
                        in
                        Control.whileLoop (Sig.f32 T.scalar) (\s -> T.lessThan (T.float 3) s) (\s -> T.plus z s) (T.float 0)
                in
                Eval.floats (Transform.grad f (T.float 1)) |> failsWith loopMessage
        , test "grad through a loop nested in a loop body that reads the argument is an error" <|
            \_ ->
                let
                    inner y s =
                        Control.whileLoop (Sig.f32 T.scalar) (\t -> T.lessThan (T.float 2) t) (\t -> T.plus y t) s

                    f y =
                        Control.whileLoop (Sig.f32 T.scalar) (\s -> T.lessThan (T.float 5) s) (\s -> inner y s) (T.float 0)
                in
                Eval.floats (Transform.grad f (T.float 1)) |> failsWith loopMessage
        , test "the pullback of a loop whose body reads the argument is an error" <|
            \_ ->
                let
                    ( _, pullback ) =
                        Transform.vjp (Sig.f32 T.scalar)
                            (Sig.f32 T.scalar)
                            (\y -> Control.whileLoop (Sig.f32 T.scalar) (\s -> T.lessThan (T.float 3) s) (\s -> T.plus y s) (T.float 0))
                            (T.float 1)
                in
                Eval.floats (pullback (T.float 1)) |> failsWith loopMessage
        , test "control: a loop that reads no argument adds nothing and no error" <|
            \_ ->
                let
                    loop =
                        Control.whileLoop (Sig.f32 T.scalar) (\s -> T.lessThan (T.float 3) s) (\s -> T.plus (T.float 1) s) (T.float 0)

                    f y =
                        T.plus (T.times y (T.float 2)) loop
                in
                Eval.floats (Transform.grad f (T.float 1)) |> close 1.0e-12 [ 2 ]
        , test "control: the argument read only in the loop's condition gets no error" <|
            \_ ->
                let
                    f y =
                        T.plus (T.times y (T.float 2))
                            (Control.whileLoop (Sig.f32 T.scalar) (\s -> T.lessThan y s) (\s -> T.plus (T.float 1) s) (T.float 0))
                in
                Eval.floats (Transform.grad f (T.float 2.5)) |> close 1.0e-12 [ 2 ]
        ]


{-| B002: jvp through an operation whose pullback is a failed cotangent.
-}
b002 : Test
b002 =
    describe "B002 jvp of a failed cotangent"
        [ test "jvp through sort's values is an error, not 0" <|
            \_ ->
                let
                    ( _, tangent ) =
                        Transform.jvp (Sig.f32 (T.r1 a3))
                            (Sig.f32 (T.r1 a3))
                            (\x -> Tuple.first (T.sort { descending = False } Axis.axis0of1 x))
                            (T.fromList T.float32 (T.r1 a3) [ 3, 1, 2 ])
                            (T.ones T.float32 (T.r1 a3))
                in
                Eval.floats tangent |> failsWith "topK: cannot be differentiated"
        , test "jvp through a float loop's state is an error, not 0" <|
            \_ ->
                let
                    ( _, tangent ) =
                        Transform.jvp (Sig.f32 T.scalar)
                            (Sig.f32 T.scalar)
                            (\x -> Control.whileLoop (Sig.f32 T.scalar) (\s -> T.lessThan (T.float 100) s) (\s -> T.times s (T.float 2)) x)
                            (T.float 3)
                            (T.float 1)
                in
                Eval.floats tangent |> failsWith loopMessage
        , test "jvp of a loop whose body reads the argument is an error" <|
            \_ ->
                let
                    ( _, tangent ) =
                        Transform.jvp (Sig.f32 T.scalar)
                            (Sig.f32 T.scalar)
                            (\y -> Control.whileLoop (Sig.f32 T.scalar) (\s -> T.lessThan (T.float 3) s) (\s -> T.plus y s) (T.float 0))
                            (T.float 1)
                            (T.float 1)
                in
                Eval.floats tangent |> failsWith loopMessage
        , test "only the tangent of the output that reads the failed operation fails" <|
            \_ ->
                let
                    x =
                        f32 [ 3 ] [ 3, 1, 2 ]

                    ( _, tangents ) =
                        Grad.jvp (\vs -> List.concatMap (\v -> [ Tuple.first (O.topK True 0 3 v), O.mul v (O.scalarLike 2 v) ]) vs) [ x ] [ O.onesLike x ]
                in
                case tangents of
                    [ t0, t1 ] ->
                        Expect.all
                            [ \_ -> evF t0 |> failsWith "topK: cannot be differentiated"
                            , \_ -> evF t1 |> close 1.0e-12 [ 2, 2, 2 ]
                            ]
                            ()

                    _ ->
                        Expect.fail "expected two tangents"
        , test "control: jvp of a product is its derivative" <|
            \_ ->
                let
                    ( _, tangent ) =
                        Transform.jvp (Sig.f32 (T.r1 a3))
                            (Sig.f32 (T.r1 a3))
                            (\x -> T.times x x)
                            (T.fromList T.float32 (T.r1 a3) [ 3, 1, 2 ])
                            (T.ones T.float32 (T.r1 a3))
                in
                Eval.floats tangent |> close 1.0e-12 [ 6, 2, 4 ]
        ]


{-| The cross-entropy loss written out of other operations, for finite differences.
-}
xentByHand : List (List Float) -> List (List Float) -> Float
xentByHand targets logits =
    let
        row t l =
            let
                m =
                    List.maximum l |> Maybe.withDefault 0

                lse =
                    m + logBase e (List.sum (List.map (\v -> Basics.e ^ (v - m)) l))
            in
            -(List.sum (List.map2 (\ti li -> ti * (li - lse)) t l))
    in
    List.sum (List.map2 row targets logits) / toFloat (List.length logits)


{-| B004: the logits gradient of the cross-entropy for targets of any row sums.
-}
b004 : Test
b004 =
    describe "B004 cross-entropy logits gradient"
        [ test "targets [[1, 1]] at logits [[0, 0]] give a zero gradient" <|
            \_ ->
                Eval.floats
                    (Transform.grad (Nn.crossEntropy (T.fromList T.float32 (T.r2 a1 b2) [ 1, 1 ]))
                        (T.zeros T.float32 (T.r2 a1 b2))
                    )
                    |> close 1.0e-12 [ 0, 0 ]
        , test "an out-of-range label gives its row a zero gradient" <|
            \_ ->
                Eval.floats
                    (Transform.grad (Nn.crossEntropyIndices (T.fromList T.int64 (T.r1 a2) [ -1, 0 ]))
                        (T.zeros T.float32 (T.r2 a2 b2))
                    )
                    |> close 1.0e-12 [ 0, 0, -0.25, 0.25 ]
        , test "non-normalised targets: the gradient matches finite differences" <|
            \_ ->
                let
                    targets =
                        [ [ 0.2, 0.5, 0.1 ], [ 1, 0, 0.3 ] ]

                    logits =
                        [ [ 1, 2, 3 ], [ 0.5, -1, 0 ] ]

                    h =
                        1.0e-5

                    bump i j d =
                        List.indexedMap
                            (\r row ->
                                List.indexedMap
                                    (\c v ->
                                        if r == i && c == j then
                                            v + d

                                        else
                                            v
                                    )
                                    row
                            )
                            logits

                    fd =
                        List.concatMap
                            (\i -> List.map (\j -> (xentByHand targets (bump i j h) - xentByHand targets (bump i j -h)) / (2 * h)) (List.range 0 2))
                            (List.range 0 1)

                    got =
                        Grad.grad (\l -> O.xent l (f32 [ 2, 3 ] (List.concat targets))) (f32 [ 2, 3 ] (List.concat logits))
                in
                evF got |> close 1.0e-6 fd
        , test "control: one-hot targets keep softmax − target over n" <|
            \_ ->
                evF (Grad.grad (\l -> O.xent l (f32 [ 1, 2 ] [ 1, 0 ])) (f32 [ 1, 2 ] [ 0, 0 ]))
                    |> close 1.0e-12 [ -0.5, 0.5 ]
        , test "control: the target gradient is unchanged (−logSoftmax / n)" <|
            \_ ->
                evF (Grad.grad (\t -> O.xent (f32 [ 1, 2 ] [ 0, 0 ]) t) (f32 [ 1, 2 ] [ 1, 1 ]))
                    |> close 1.0e-12 [ logBase e 2, logBase e 2 ]
        ]


{-| B003: second derivatives through the filter of a strided convolution.
-}
b003 : Test
b003 =
    describe "B003 strided conv filter gradient differentiated again"
        [ test "hessianVector through a stride-2 conv's filter is an error, not a silent partial result" <|
            \_ ->
                let
                    x =
                        f32 [ 1, 4, 4, 1 ] (List.map toFloat (List.range 1 16))

                    loss filt =
                        O.sumAll (O.square (O.conv [ 2, 2, 0, 0, 0, 0 ] x filt))

                    filt0 =
                        f32 [ 2, 2, 1, 1 ] [ 1, 0, 0, 1 ]

                    v =
                        O.onesLike filt0
                in
                evF (Grad.grad (\y -> O.sumAll (O.mul (Grad.grad loss y) v)) filt0)
                    |> failsWith "cannot be differentiated"
        , test "jvp through a stride-2 conv's filter is an error, not 0" <|
            \_ ->
                let
                    x =
                        f32 [ 1, 4, 4, 1 ] (List.map toFloat (List.range 1 16))

                    filt0 =
                        f32 [ 2, 2, 1, 1 ] [ 1, 0, 0, 1 ]

                    ( _, tangents ) =
                        Grad.jvp (List.map (\filt -> O.sumAll (O.conv [ 2, 2, 0, 0, 0, 0 ] x filt))) [ filt0 ] [ O.onesLike filt0 ]
                in
                evF (List.head tangents |> Maybe.withDefault filt0) |> failsWith "cannot be differentiated"
        , test "control: jvp through a stride-1 conv's filter is the derivative" <|
            \_ ->
                let
                    x =
                        f32 [ 1, 3, 3, 1 ] (List.map toFloat (List.range 1 9))

                    filt0 =
                        f32 [ 2, 2, 1, 1 ] [ 1, 0, 0, 1 ]

                    ( _, tangents ) =
                        Grad.jvp (List.map (\filt -> O.sumAll (O.conv [ 1, 1, 0, 0, 0, 0 ] x filt))) [ filt0 ] [ O.onesLike filt0 ]
                in
                -- d/dt sum (conv x (f + t·1)) = sum over the 4 windows of their 4 elements
                evF (List.head tangents |> Maybe.withDefault filt0) |> close 1.0e-12 [ 12 + 16 + 24 + 28 ]
        , test "control: the first-order filter gradient of a stride-2 conv is unchanged" <|
            \_ ->
                let
                    x =
                        f32 [ 1, 4, 4, 1 ] (List.map toFloat (List.range 1 16))

                    filt0 =
                        f32 [ 2, 2, 1, 1 ] [ 1, 0, 0, 1 ]
                in
                -- windows at (0,0),(0,2),(2,0),(2,2): sums of the filter-position elements
                evF (Grad.grad (\filt -> O.sumAll (O.conv [ 2, 2, 0, 0, 0, 0 ] x filt)) filt0)
                    |> close 1.0e-12 [ 1 + 3 + 9 + 11, 2 + 4 + 10 + 12, 5 + 7 + 13 + 15, 6 + 8 + 14 + 16 ]
        ]
