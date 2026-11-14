module FixVMAPTests exposing (suite)

{-| Regression tests for the control-flow and `vmap` fixes (`Tensor.Internal.Control`,
`Tensor.Control`, `Tensor.Internal.Batch`). Each group is named after the issue it pins (B019, …).
-}

import Expect
import Graph
import Signature as Sig
import Tensor as T exposing (Dim, F32, R1, R2, Tensor)
import Tensor.Axis as Axis
import Tensor.Control as Control
import Tensor.Eval as Eval
import Tensor.Internal.Batch as B
import Tensor.Internal.Expr as E exposing (Expr)
import Tensor.Internal.Ops as O
import Tensor.Internal.Prim exposing (DT(..))
import Tensor.Internal.Types as I
import Tensor.Random as Random
import Test exposing (Test, describe, test)
import Transform


type A
    = A


type B
    = B


a0 : Dim A
a0 =
    T.dim A 0


a3 : Dim A
a3 =
    T.dim A 3


a4 : Dim A
a4 =
    T.dim A 4


b2 : Dim B
b2 =
    T.dim B 2


b3 : Dim B
b3 =
    T.dim B 3


f32 : List Int -> List Float -> Expr
f32 =
    E.const F32


{-| Returns the elements of `e`, run by `Tensor.Eval`.
-}
evalE : Expr -> Result (List String) (List Float)
evalE e =
    Eval.floats (I.Tensor e)


{-| Returns an expectation that passes when `r` is an error list with a message containing
`fragment`.
-}
expectErr : String -> Result (List String) x -> Expect.Expectation
expectErr fragment r =
    case r of
        Err e ->
            if List.any (String.contains fragment) e then
                Expect.pass

            else
                Expect.fail ("no error containing \"" ++ fragment ++ "\" in: " ++ String.join " | " e)

        Ok _ ->
            Expect.fail ("no error; expected one containing \"" ++ fragment ++ "\"")


{-| Returns an expectation that passes when `r` is `Ok`.
-}
expectOk : Result (List String) x -> Expect.Expectation
expectOk r =
    case r of
        Ok _ ->
            Expect.pass

        Err e ->
            Expect.fail (String.join " | " e)


{-| Returns the outputs of `vmapRule` on `leaves` for a per-example function `f` of the batched
leaves' placeholders.
-}
vmapE : List ( Expr, Bool ) -> (List Expr -> List Expr) -> List Expr
vmapE leaves f =
    Tuple.second (B.vmapRule leaves (\vs -> ( (), f vs )))


{-| Returns `f` applied to each example of `x`, the results stacked: what `vmap` must equal.
-}
looped : (Expr -> Expr) -> Expr -> Expr
looped f x =
    B.stack (List.map f (B.unstack x))


draw : Tensor Int T.I64 T.R0 -> Tensor Float F32 (R1 B)
draw i =
    Random.uniform { low = 0, high = 1 } T.float32 (T.r1 b3) (Random.seed i)


{-| A loop that adds `a` to a zero accumulator three times, so it gives `3a`. Its initial state does
not depend on `a`; only its step reads `a`.
-}
addThrice : Tensor Float F32 (R1 B) -> Tensor Float F32 (R1 B)
addThrice a =
    Control.whileLoop (Sig.pair Sig.anyTensor Sig.anyTensor)
        (\( i, _ ) -> i |> T.lessThan (T.int 3))
        (\( i, acc ) -> ( T.plus i (T.int 1), T.plus acc a ))
        ( T.int 0, T.zeros T.float32 (T.r1 b3) )
        |> Tuple.second


x3 : Tensor Float F32 (R1 B)
x3 =
    T.fromList T.float32 (T.r1 b3) [ 1, -2, 3 ]


positive : Tensor Float F32 (R1 B) -> T.Mask T.R0
positive x =
    T.sumAll x |> T.greaterThan (T.float -100)


zeros43 : Tensor Float F32 (R2 A B)
zeros43 =
    T.zeros T.float32 (T.r2 a4 b3)


{-| One draw of the whole batch's shape on the seed `draw (T.int 7)` uses: what a draw of `draw`'s
shape on that seed becomes under `vmap` over four examples.
-}
batchDraw : Tensor Float F32 (R2 A B)
batchDraw =
    Random.uniform { low = 0, high = 1 } T.float32 (T.r2 a4 b3) (Random.seed (T.int 7))


suite : Test
suite =
    describe "VMAP fixes"
        [ describe "B019 a draw on a seed that does not depend on the batch is drawn for each example"
            [ test "a draw made outside vmap and captured is redrawn for each example" <|
                \_ ->
                    let
                        r =
                            Transform.vmap Axis.liftRank1 Axis.liftRank1 (\x -> T.plus x (draw (T.int 7))) zeros43
                    in
                    Eval.floats r |> Expect.equal (Eval.floats batchDraw)
            , test "a draw passed in through keep is redrawn for each example" <|
                \_ ->
                    let
                        r =
                            Transform.vmapWith (Transform.pair (Transform.tensor Axis.liftRank1) Transform.keep)
                                (Transform.tensor Axis.liftRank1)
                                (\( x, e ) -> T.plus x e)
                                ( zeros43, draw (T.int 7) )
                    in
                    Eval.floats r |> Expect.equal (Eval.floats batchDraw)
            , test "a draw made in the mapped function on a fixed seed is drawn for each example" <|
                \_ ->
                    let
                        r =
                            Transform.vmap Axis.liftRank1 Axis.liftRank1 (\x -> T.plus x (draw (T.int 7))) zeros43
                    in
                    Eval.floats r |> Expect.equal (Eval.floats batchDraw)
            , test "the examples' draws differ" <|
                \_ ->
                    let
                        rows =
                            Transform.vmap Axis.liftRank1 Axis.liftRank1 (\x -> T.plus x (draw (T.int 7))) zeros43
                                |> Eval.floats
                                |> Result.map (\v -> [ List.take 3 v, List.take 3 (List.drop 3 v) ])
                    in
                    case rows of
                        Ok [ r0, r1 ] ->
                            Expect.notEqual r0 r1

                        _ ->
                            Expect.fail "no rows"
            , test "a draw inside a whileLoop step is the same for every example" <|
                \_ ->
                    let
                        stepDraw x =
                            Control.whileLoop (Sig.pair Sig.anyTensor Sig.anyTensor)
                                (\( i, _ ) -> i |> T.lessThan (T.int 1))
                                (\( i, acc ) -> ( T.plus i (T.int 1), T.plus acc (draw (T.int 7)) ))
                                ( T.int 0, x )
                                |> Tuple.second

                        r =
                            Transform.vmap Axis.liftRank1 Axis.liftRank1 stepDraw zeros43
                    in
                    Eval.floats r |> Expect.equal (Eval.floats (draw (T.int 7)) |> Result.map (List.repeat 4 >> List.concat))
            ]
        , describe "B020 a seed computed from a batched argument"
            [ test "each example draws on its own seed" <|
                \_ ->
                    let
                        r =
                            Transform.vmap Axis.liftRank0 Axis.liftRank1 draw (T.fromList T.int64 (T.r1 a3) [ 1, 2, 3 ])

                        expected =
                            List.foldr (Result.map2 (++)) (Ok []) (List.map (\k -> Eval.floats (draw (T.int k))) [ 1, 2, 3 ])
                    in
                    Eval.floats r |> Expect.equal expected
            , test "the graph builds" <|
                \_ ->
                    Graph.function "g" (Sig.tensor T.int64 (T.r1 a3)) (Transform.vmap Axis.liftRank0 Axis.liftRank1 draw)
                        |> expectOk
            ]
        , describe "B022 batched arguments are checked"
            [ test "leading sizes that differ are refused" <|
                \_ ->
                    Graph.function "g"
                        (Sig.pair (Sig.f32 (T.r2 a3 b2)) (Sig.f32 (T.r2 a4 b2)))
                        (\( x, y ) ->
                            Transform.vmap2 Axis.liftRank1
                                Axis.liftRank1
                                Axis.liftRank1
                                (\a b -> Control.cond (T.sumAll b |> T.greaterThan (T.float 0)) Sig.anyTensor Sig.anyTensor identity T.negate a)
                                x
                                y
                        )
                        |> expectErr "vmap: batched arguments have leading sizes 3 and 4"
            , test "every output carries the error, even one that reads no batched argument" <|
                \_ ->
                    vmapE [ ( f32 [ 3, 2 ] [ 1, 2, 3, 4, 5, 6 ], True ), ( f32 [ 4, 2 ] [ 1, 2, 3, 4, 5, 6, 7, 8 ], True ) ]
                        (\_ -> [ f32 [ 2 ] [ 1, 2 ] ])
                        |> List.map evalE
                        |> List.map (expectErr "leading sizes 3 and 4")
                        |> (\es -> Expect.all (List.map always es) ())
            , test "a batched argument of rank 0 is refused" <|
                \_ ->
                    vmapE [ ( E.scalar F32 1, True ) ] (\vs -> List.map O.neg vs)
                        |> List.map evalE
                        |> List.head
                        |> Maybe.withDefault (Ok [])
                        |> expectErr "vmap: a batched argument has no axes"
            , test "a batched argument with a broadcast axis is refused" <|
                \_ ->
                    Eval.floats (Transform.vmap Axis.liftRank1 Axis.liftRank1 T.negate (T.rows x3))
                        |> expectErr "vmap: a batched argument has a broadcast axis"
            , test "a batched argument with no examples is refused" <|
                \_ ->
                    Eval.floats (Transform.vmap Axis.liftRank1 Axis.liftRank1 T.negate (T.zeros T.float32 (T.r2 a0 b3)))
                        |> expectErr "vmap: a batched argument has no examples"
            ]
        , describe "B036 rank-0 and broadcast-axis cases"
            [ test "a per-example scalar times a per-example vector" <|
                \_ ->
                    let
                        s =
                            f32 [ 4 ] [ 1, 2, 3, 4 ]

                        v =
                            f32 [ 4, 3 ] (List.map toFloat (List.range 1 12))
                    in
                    vmapE [ ( s, True ), ( v, True ) ] (\vs -> [ List.foldl O.mul (E.scalar F32 1) vs ])
                        |> List.map evalE
                        |> Expect.equal [ evalE (B.stack (List.map2 O.mul (B.unstack s) (B.unstack v))) ]
            , test "a per-example scalar times a plain vector" <|
                \_ ->
                    let
                        s =
                            f32 [ 4 ] [ 1, 2, 3, 4 ]

                        c =
                            f32 [ 3 ] [ 1, 10, 100 ]
                    in
                    vmapE [ ( s, True ) ] (\vs -> List.map (\p -> O.mul p c) vs)
                        |> List.map evalE
                        |> Expect.equal [ evalE (looped (\p -> O.mul p c) s) ]
            , test "a product with a broadcast batch axis keeps it" <|
                \_ ->
                    let
                        x =
                            f32 [ 2, 3, 4 ] (List.map toFloat (List.range 1 24))

                        w =
                            f32 [ 4, 5 ] (List.map toFloat (List.range 1 20))

                        f p =
                            O.add (O.matmul (O.broadcastAxis 0 p) (O.broadcastAxis 0 w)) (f32 [ 2, 3, 5 ] (List.repeat 30 0))
                    in
                    vmapE [ ( x, True ) ] (List.map f)
                        |> List.map evalE
                        |> Expect.equal [ evalE (looped f x) ]
            , test "an output with a broadcast axis that reads no batched argument" <|
                \_ ->
                    vmapE [ ( f32 [ 4, 3 ] (List.repeat 12 0), True ) ] (\_ -> [ O.broadcastAxis 0 (f32 [ 3 ] [ 1, 2, 3 ]) ])
                        |> List.map (\e -> ( E.shape e, E.pending e, E.poisoned e ))
                        |> Expect.equal [ ( [ 4, 1, 3 ], [ 1 ], False ) ]
            ]
        , describe "B034 a loop inside a cond branch"
            [ test "a loop whose step reads the branch's argument stays in the branch" <|
                \_ ->
                    Eval.floats (Control.cond (positive x3) Sig.anyTensor Sig.anyTensor (\a -> T.plus a (addThrice a)) identity x3)
                        |> Expect.equal (Ok [ 4, -8, 12 ])
            , test "its graph builds" <|
                \_ ->
                    Graph.function "g" (Sig.f32 (T.r1 b3)) (\x -> Control.cond (positive x) Sig.anyTensor Sig.anyTensor (\a -> T.plus a (addThrice a)) identity x)
                        |> expectOk
            , test "a tensor read only by a nested loop's step is an operand of the If" <|
                \_ ->
                    let
                        c =
                            T.scale 2 x3

                        loop a =
                            Control.whileLoop (Sig.pair Sig.anyTensor Sig.anyTensor)
                                (\( i, _ ) -> i |> T.lessThan (T.int 3))
                                (\( i, acc ) -> ( T.plus i (T.int 1), T.plus acc c ))
                                ( T.int 0, a )
                                |> Tuple.second

                        r =
                            Control.cond (positive x3) Sig.anyTensor Sig.anyTensor loop identity x3

                        operandKeys =
                            case E.op (I.tensor r) of
                                E.Proj node _ ->
                                    List.map E.key (E.operands node)

                                _ ->
                                    []
                    in
                    ( List.member (E.key (I.tensor c)) operandKeys, Eval.floats r )
                        |> Expect.equal ( True, Ok [ 7, -14, 21 ] )
            , test "a gradient through a loop nested in a branch carries the loop's error" <|
                \_ ->
                    let
                        loop c a =
                            Control.whileLoop (Sig.pair Sig.anyTensor Sig.anyTensor)
                                (\( i, _ ) -> i |> T.lessThan (T.int 3))
                                (\( i, acc ) -> ( T.plus i (T.int 1), T.plus acc c ))
                                ( T.int 0, a )
                                |> Tuple.second
                    in
                    Transform.grad (\c -> T.sumAll (Control.cond (positive x3) Sig.anyTensor Sig.anyTensor (loop c) identity x3)) x3
                        |> Eval.floats
                        |> expectErr "whileLoop: a loop cannot be differentiated"
            ]
        , describe "B035 broadcast axes of captured tensors"
            [ test "a captured tensor's broadcast axis takes its partner's size" <|
                \_ ->
                    let
                        c =
                            T.rows x3

                        x =
                            T.fromList T.float32 (T.r2 b2 b3) [ 1, 2, 3, 4, 5, 6 ]
                    in
                    Eval.floats (Control.cond (T.sumAll x |> T.greaterThan (T.float 0)) Sig.anyTensor Sig.anyTensor (\a -> T.plus a c) identity x)
                        |> Expect.equal (Eval.floats (T.plus x c))
            , test "the argument's broadcast axis takes its partner's size in a branch" <|
                \_ ->
                    let
                        c =
                            T.rows x3

                        x =
                            T.fromList T.float32 (T.r2 b2 b3) [ 1, 2, 3, 4, 5, 6 ]
                    in
                    Eval.floats (Control.cond (positive x3) Sig.anyTensor Sig.anyTensor (\a -> T.plus a x) (\a -> T.plus a (T.zerosLike x)) c)
                        |> Expect.equal (Eval.floats (T.plus x c))
            , test "a captured tensor returned as it is keeps its broadcast axis" <|
                \_ ->
                    let
                        c =
                            T.rows x3
                    in
                    Control.cond (positive x3) Sig.anyTensor Sig.anyTensor (\_ -> c) (\_ -> c) x3
                        |> I.tensor
                        |> (\e -> ( E.pending e, E.poisoned e ))
                        |> Expect.equal ( [ 0 ], False )
            , test "branches that differ only in a broadcast axis are refused" <|
                \_ ->
                    Control.cond (positive x3) Sig.anyTensor Sig.anyTensor (\_ -> T.rows x3) (\_ -> T.reshape (T.r2 (T.dim A 1) b3) x3) x3
                        |> Eval.floats
                        |> expectErr "cond: the two branches' results differ"
            , test "a loop whose step makes a broadcast axis an ordinary one is refused" <|
                \_ ->
                    Control.whileLoop Sig.anyTensor (\_ -> T.int 0 |> T.greaterThan (T.int 1)) (\s -> T.plus s (T.zeros T.float32 (T.r2 (T.dim A 1) b3))) (T.rows x3)
                        |> Eval.floats
                        |> expectErr "whileLoop: the body must keep the state's shapes and dtypes"
            , test "a step that failed to build gives the loop's results its error" <|
                \_ ->
                    Control.whileLoop Sig.anyTensor (\_ -> T.int 0 |> T.greaterThan (T.int 1)) (\s -> T.reshape (T.r1 (T.dim B 4)) s) x3
                        |> Eval.floats
                        |> expectErr "reshape: cannot reshape"
            , test "a predicate that failed to build reports only its own error" <|
                \_ ->
                    Control.cond (positive (T.reshape (T.r1 (T.dim B 4)) x3)) Sig.anyTensor Sig.anyTensor identity T.negate x3
                        |> Eval.floats
                        |> (\r ->
                                case r of
                                    Err e ->
                                        Expect.equal ( List.any (String.contains "reshape: cannot reshape") e, List.any (String.contains "cond:") e ) ( True, False )

                                    Ok _ ->
                                        Expect.fail "no error"
                           )
            , test "a loop over a state with a broadcast axis keeps it" <|
                \_ ->
                    Control.whileLoop Sig.anyTensor (\_ -> T.int 0 |> T.greaterThan (T.int 1)) identity (T.rows x3)
                        |> I.tensor
                        |> (\e -> ( E.pending e, E.poisoned e ))
                        |> Expect.equal ( [ 0 ], False )
            ]
        , describe "B033 a loop under vmap whose step reads the argument"
            [ test "vmap matches a loop over the examples" <|
                \_ ->
                    let
                        xs =
                            T.fromList T.float32 (T.r2 b2 b3) [ 1, 2, 3, 4, 5, 6 ]
                    in
                    Eval.floats (Transform.vmap Axis.liftRank1 Axis.liftRank1 addThrice xs)
                        |> Expect.equal (Ok [ 3, 6, 9, 12, 15, 18 ])
            , test "its graph builds" <|
                \_ ->
                    Graph.function "g" (Sig.f32 (T.r2 b2 b3)) (Transform.vmap Axis.liftRank1 Axis.liftRank1 addThrice)
                        |> expectOk
            ]
        , describe "Batch rules keep a failWith check"
            [ test "a failed element-wise expression stays failed when batched" <|
                \_ ->
                    vmapE [ ( f32 [ 2, 3 ] (List.repeat 6 1), True ) ] (List.map (O.neg >> E.failWith "boom"))
                        |> List.map evalE
                        |> List.map (expectErr "boom")
                        |> (\es -> Expect.all (List.map always es) ())
            ]
        ]
