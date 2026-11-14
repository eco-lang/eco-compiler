module FixCORETests exposing (suite)

{-| Regression tests for the shared-core fixes: expressions (`Tensor.Internal.Expr`), shape rules,
the internal builders (`Tensor.Internal.Ops`) and the public `Tensor` and `Tensor.Random` builders.
Each test is named after the issue it pins (B026, …).
-}

import Dict
import Expect
import Graph
import Signature as Sig
import Tensor as T exposing (Dim, F32, R1, Tensor)
import Tensor.Axis as Axis
import Tensor.Control as Control
import Tensor.Eval as Eval
import Tensor.Internal.Expr as E exposing (Expr)
import Tensor.Internal.Grad as Grad
import Tensor.Internal.Key as K
import Tensor.Internal.Ops as O
import Tensor.Internal.Prim as P exposing (DT(..), Prim(..))
import Tensor.Internal.Types as I
import Tensor.Random as Random
import Test exposing (Test, describe, test)
import Transform


type B
    = B


b3 : Dim B
b3 =
    T.dim B 3


b4 : Dim B
b4 =
    T.dim B 4


b6 : Dim B
b6 =
    T.dim B 6


f32 : List Int -> List Float -> Expr
f32 =
    E.const F32


{-| Returns an expectation that passes when the build was refused with at least one error
containing `fragment`.
-}
expectError : String -> Result (List String) Graph.Graph -> Expect.Expectation
expectError fragment r =
    case r of
        Err e ->
            if List.any (String.contains fragment) e then
                Expect.pass

            else
                Expect.fail ("no error containing \"" ++ fragment ++ "\" in: " ++ String.join " | " e)

        Ok _ ->
            Expect.fail ("the graph was built; expected an error containing \"" ++ fragment ++ "\"")


{-| Returns the errors of a refused build, or none.
-}
errorsOf : Result (List String) Graph.Graph -> List String
errorsOf r =
    case r of
        Ok _ ->
            []

        Err e ->
            e


{-| A cond whose two branches give different shapes: [3] and [4].
-}
mismatched : Tensor Float F32 (R1 B) -> Tensor Float F32 (R1 B) -> Tensor Float F32 (R1 B)
mismatched v c =
    Control.cond (T.sumAll v |> T.greaterThan (T.float 0))
        Sig.anyTensor
        Sig.anyTensor
        identity
        (\_ -> T.fromList T.float32 (T.r1 b4) [ 1, 2, 3, 4 ])
        c


{-| A reshape of a [3] tensor to [4], refused.
-}
badReshape : Tensor Float F32 (R1 B) -> Tensor Float F32 (R1 B)
badReshape x =
    T.reshape (T.r1 b4) x


suite : Test
suite =
    describe "CORE fixes"
        [ describe "B026 rebuild keeps failWith"
            [ test "rebuild of a failWith node keeps its message" <|
                \_ ->
                    let
                        e =
                            E.prim Add [ f32 [ 2 ] [ 1, 2 ], f32 [ 2 ] [ 3, 4 ] ] P.noParams

                        failed =
                            E.failWith "boom" e
                    in
                    E.rebuild failed (E.operands failed)
                        |> (\r -> ( E.problem r, E.poisoned r, E.key r == E.key failed ))
                        |> Expect.equal ( Just "boom", True, True )
            , test "keepCheck carries a failWith message onto a fresh node" <|
                \_ ->
                    let
                        e =
                            E.prim Add [ f32 [ 2 ] [ 1, 2 ], f32 [ 2 ] [ 3, 4 ] ] P.noParams
                    in
                    E.keepCheck (E.failWith "boom" e) (E.prim Neg [ e ] P.noParams)
                        |> E.problem
                        |> Expect.equal (Just "boom")
            , test "a vmapped mismatched cond is refused" <|
                \_ ->
                    Graph.function "g"
                        (Sig.f32 (T.r2 (T.dim B 2) b3))
                        (\x -> Transform.vmap Axis.liftRank1 Axis.liftRank1 (\v -> mismatched v v) x)
                        |> expectError "cond: the two branches' results differ"
            , test "a mismatched cond nested in a branch that captures a tensor is refused" <|
                \_ ->
                    Graph.function "g"
                        (Sig.f32 (T.r1 b3))
                        (\x ->
                            let
                                c =
                                    T.scale 2 (T.fromList T.float32 (T.r1 b3) [ 1, 2, 3 ])
                            in
                            Control.cond (T.sumAll x |> T.greaterThan (T.float 0))
                                Sig.anyTensor
                                Sig.anyTensor
                                (\v -> T.plus v (mismatched v c))
                                identity
                                x
                        )
                        |> expectError "cond: the two branches' results differ"
            ]
        , describe "B028 failWith keeps the root cause"
            [ test "failWith on a failed expression keeps the first message" <|
                \_ ->
                    E.failWith "second" (E.failWith "first" (f32 [ 1 ] [ 1 ]))
                        |> E.problem
                        |> Expect.equal (Just "first")
            , test "failWith on an expression poisoned through an operand records nothing" <|
                \_ ->
                    let
                        bad =
                            E.prim Add [ f32 [ 2 ] [ 1, 2 ], f32 [ 3 ] [ 3, 4, 5 ] ] P.noParams

                        e =
                            E.prim Neg [ bad ] P.noParams
                    in
                    E.failWith "derived" e |> E.problem |> Expect.equal Nothing
            , test "sliceUpdate out of range on a failed reshape reports only the reshape" <|
                \_ ->
                    Graph.function "g"
                        (Sig.f32 (T.r1 b3))
                        (\x -> T.sliceUpdate Axis.retag0of1 9 (T.zeros T.float32 (T.r1 (T.dim B 1))) (badReshape x))
                        |> errorsOf
                        |> List.map (\m -> ( String.contains "reshape" m, String.contains "sliceUpdate" m ))
                        |> Expect.equal [ ( True, False ) ]
            ]
        , describe "B027 *Like builders keep a failed template's error"
            [ test "zerosLike of a failed reshape is refused" <|
                \_ ->
                    Graph.function "g" (Sig.f32 (T.r1 b3)) (\x -> T.zerosLike (badReshape x))
                        |> expectError "reshape"
            , test "fillLike of a failed reshape is refused" <|
                \_ ->
                    Graph.function "g" (Sig.f32 (T.r1 b3)) (\x -> T.fillLike (T.float 2) (badReshape x))
                        |> expectError "reshape"
            , test "castLike to a failed template is refused" <|
                \_ ->
                    Graph.function "g" (Sig.f32 (T.r1 b3)) (\x -> T.castLike (badReshape x) x)
                        |> expectError "reshape"
            , test "lowerTriangle of a failed template is refused" <|
                \_ ->
                    Graph.function "g"
                        (Sig.f32 (T.r1 b3))
                        (\x -> T.indicator T.float32 (T.lowerTriangle (T.reshape (T.r2 b4 b4) x)) |> T.sumAll)
                        |> expectError "reshape"
            , test "Random.uniformLike of a failed template is refused" <|
                \_ ->
                    Graph.function "g"
                        (Sig.f32 (T.r1 b3))
                        (\x -> Random.uniformLike { low = 0, high = 1 } (badReshape x) (Random.seed (T.int 1)))
                        |> expectError "reshape"
            , test "Random.bernoulliLike of a failed template is refused" <|
                \_ ->
                    Graph.function "g"
                        (Sig.f32 (T.r1 b3))
                        (\x -> Random.bernoulliLike 0.5 (badReshape x) (Random.seed (T.int 1)) |> T.indicator T.float32)
                        |> expectError "reshape"
            , test "E.inherit carries the template's root message" <|
                \_ ->
                    let
                        bad =
                            E.prim Add [ f32 [ 2 ] [ 1, 2 ], f32 [ 3 ] [ 3, 4, 5 ] ] P.noParams
                    in
                    E.inherit (E.prim Neg [ bad ] P.noParams) (f32 [ 1 ] [ 0 ])
                        |> E.problem
                        |> Expect.equal (E.problem bad)
            ]
        , describe "B033 mapBodies rewrites loop bodies"
            [ test "a placeholder read in a loop step is replaced by mapBodies" <|
                \_ ->
                    let
                        v =
                            E.var (K.start "outer") 0 F32 [ 3 ]

                        x =
                            f32 [ 3 ] [ 1, 2, 3 ]

                        cs =
                            K.start "c"

                        bs =
                            K.start "b"

                        s c =
                            E.var c 0 F32 [ 3 ]

                        cond =
                            { scope = cs, arity = 1, outputs = [ O.lt (O.sumAll (s cs)) (E.scalar F32 10) ] }

                        step =
                            { scope = bs, arity = 1, outputs = [ O.add (s bs) v ] }

                        w =
                            E.while cond step [ x ]

                        mapping =
                            Dict.singleton (E.key v) x

                        reads e =
                            List.any (\o -> E.key o == E.key v) (Grad.postorder (List.concatMap .outputs (E.bodies e)))

                        w2 =
                            E.mapBodies (\body -> { body | outputs = Grad.substitute mapping body.outputs }) w
                    in
                    ( reads w, reads w2, List.length (E.bodies w2) )
                        |> Expect.equal ( True, False, 2 )
            , test "mapBodies keeps a failWith message" <|
                \_ ->
                    let
                        sc =
                            K.start "c"

                        body =
                            { scope = sc, arity = 1, outputs = [ E.var sc 0 F32 [ 3 ] ] }

                        w =
                            E.failWith "loop check" (E.while body body [ f32 [ 3 ] [ 1, 2, 3 ] ])
                    in
                    E.mapBodies identity w |> E.problem |> Expect.equal (Just "loop check")
            ]
        , describe "B035 varMeta keeps pending axes"
            [ test "a placeholder made with a pending axis keeps it" <|
                \_ ->
                    let
                        v =
                            E.varMeta (K.start "s") 0 { shape = [ 1, 4 ], pending = [ 0 ], dtype = F32 }

                        sum =
                            O.add v (O.zerosLike (f32 [ 3, 4 ] (List.repeat 12 0)))
                    in
                    ( E.pending v, E.shape sum, E.poisoned sum )
                        |> Expect.equal ( [ 0 ], [ 3, 4 ], False )
            , test "var and varMeta with no pending axes are one expression" <|
                \_ ->
                    E.key (E.var (K.start "s") 1 F32 [ 2 ])
                        |> Expect.equal (E.key (E.varMeta (K.start "s") 1 { shape = [ 2 ], pending = [], dtype = F32 }))
            , test "pending axes tell placeholders apart" <|
                \_ ->
                    E.key (E.var (K.start "s") 0 F32 [ 1 ])
                        |> Expect.notEqual (E.key (E.varMeta (K.start "s") 0 { shape = [ 1 ], pending = [ 0 ], dtype = F32 }))
            ]
        , describe "B047 a failed body poisons the node"
            [ test "a shared function whose body fails gives one message" <|
                \_ ->
                    let
                        sh =
                            Transform.shared "f" (Sig.f32 (T.r1 b3)) (Sig.f32 (T.r1 b6)) (\v -> T.reshape (T.r1 b6) v)
                    in
                    Graph.function "g"
                        (Sig.f32 (T.r1 b3))
                        (\x -> Transform.call sh x |> T.plus (T.ones T.float32 (T.r1 b6)))
                        |> errorsOf
                        |> List.length
                        |> Expect.equal 1
            , test "a body output that failed poisons the If node" <|
                \_ ->
                    let
                        sc =
                            K.start "t"

                        bad =
                            E.prim Add [ E.var sc 0 F32 [ 2 ], f32 [ 3 ] [ 3, 4, 5 ] ] P.noParams

                        t =
                            { scope = sc, arity = 1, outputs = [ bad ] }
                    in
                    E.ifThen (E.scalar Bool 1) t t [ f32 [ 2 ] [ 1, 2 ] ]
                        |> E.poisoned
                        |> Expect.equal True
            ]
        , rest
        , evalSmoke
        ]


{-| Returns whether `r` is an `Err` with a message containing `fragment`.
-}
errContains : String -> Result (List String) a -> Bool
errContains fragment r =
    case r of
        Err e ->
            List.any (String.contains fragment) e

        Ok _ ->
            False


{-| Returns the problem recorded on `e`, or "clean" when it is not poisoned, or "poisoned" when it
is poisoned with no message of its own.
-}
status : Expr -> String
status e =
    case ( E.poisoned e, E.problem e ) of
        ( False, _ ) ->
            "clean"

        ( True, Just m ) ->
            m

        ( True, Nothing ) ->
            "poisoned"


img : Expr
img =
    f32 [ 1, 3, 3, 1 ] (List.range 1 9 |> List.map toFloat)


ker : Expr
ker =
    f32 [ 2, 2, 1, 1 ] [ 1, 1, 1, 1 ]


rest : Test
rest =
    describe "shape rules and builders"
        [ describe "B017 stride 0 never reaches the evaluator"
            [ test "Eval of a stride-0 transposed conv is a build error" <|
                \_ ->
                    Eval.floats (I.Tensor (O.convTranspose [ 0, 0, 0, 0, 0, 0 ] (f32 [ 1, 2, 2, 1 ] [ 1, 2, 3, 4 ]) ker))
                        |> errContains "strides must be positive"
                        |> Expect.equal True
            , test "Eval of a stride-0 conv is a build error" <|
                \_ ->
                    Eval.floats (I.Tensor (O.conv [ 0, 0, 0, 0, 0, 0 ] img ker))
                        |> errContains "strides must be positive"
                        |> Expect.equal True
            ]
        , describe "B030 conv refuses bad parameters"
            [ test "stride 0" <|
                \_ -> status (O.conv [ 0, 1, 0, 0, 0, 0 ] img ker) |> Expect.equal "conv2d: the strides must be positive, not [0, 1]"
            , test "dilation 0" <|
                \_ -> status (O.conv [ 1, 1, 0, 0, 0, 0, 0, 1 ] img ker) |> Expect.equal "conv2d: the dilations must be positive, not [0, 1]"
            , test "seven parameters" <|
                \_ -> status (O.conv [ 1, 1, 0, 0, 0, 0, 2 ] img ker) |> String.contains "needs 6 geometry parameters" |> Expect.equal True
            , test "five parameters" <|
                \_ -> status (O.conv [ 1, 1, 0, 0, 0 ] img ker) |> String.contains "needs 6 geometry parameters" |> Expect.equal True
            , test "input and filter dtypes differ" <|
                \_ -> status (O.conv [ 1, 1, 0, 0, 0, 0 ] img (E.const F64 [ 2, 2, 1, 1 ] [ 1, 1, 1, 1 ])) |> Expect.equal "conv2d: the input is f32 but the filter is f64"
            , test "a transposed conv whose paddings remove every row" <|
                \_ -> status (O.convTranspose [ 1, 1, 3, 3, 0, 0 ] (f32 [ 1, 2, 2, 1 ] [ 1, 2, 3, 4 ]) ker) |> String.contains "paddings remove every row" |> Expect.equal True
            , test "a good conv still builds" <|
                \_ -> E.shape (O.conv [ 1, 1, 0, 0, 0, 0 ] img ker) |> Expect.equal [ 1, 2, 2, 1 ]
            ]
        , describe "B015 a kernel overrunning the padded input is refused"
            [ test "stride 2, 3 × 3 input, 4 × 4 kernel" <|
                \_ ->
                    status (O.conv [ 2, 2, 0, 0, 0, 0 ] img (f32 [ 4, 4, 1, 1 ] (List.repeat 16 1)))
                        |> Expect.equal "conv2d: the kernel is larger than the padded input"
            , test "stride 2 with a kernel that just fits" <|
                \_ ->
                    E.shape (O.conv [ 2, 2, 0, 0, 0, 0 ] img (f32 [ 3, 3, 1, 1 ] (List.repeat 9 1)))
                        |> Expect.equal [ 1, 1, 1, 1 ]
            ]
        , describe "B016 pick ignores the other elements of a row"
            [ test "a row holding -inf elsewhere" <|
                \_ ->
                    T.pick (T.fromList T.int64 (T.r1 (T.dim () 1)) [ 0 ]) (T.fromList T.float32 (T.r2 (T.dim () 1) (T.dim () 2)) [ 1, -1 / 0 ])
                        |> Eval.floats
                        |> Expect.equal (Ok [ 1 ])
            , test "the gradient reaches the picked element only" <|
                \_ ->
                    Transform.grad (\x -> T.pick (T.fromList T.int64 (T.r1 (T.dim () 2)) [ 1, 0 ]) x |> T.sumAll)
                        (T.fromList T.float32 (T.r2 (T.dim () 2) (T.dim () 2)) [ 1, 2, 3, 4 ])
                        |> Eval.floats
                        |> Expect.equal (Ok [ 0, 1, 1, 0 ])
            ]
        , describe "B012 sliceUpdate over a whole axis checks the update"
            [ test "an update of other sizes off the axis is refused" <|
                \_ ->
                    T.sliceUpdate Axis.retag0of2 0 (T.zeros T.float32 (T.r2 (T.dim B 2) (T.dim B 3))) (T.zeros T.float32 (T.r2 (T.dim B 2) (T.dim B 5)))
                        |> Eval.floats
                        |> errContains "sliceUpdate: the update is f32[2, 3] but x is f32[2, 5]"
                        |> Expect.equal True
            , test "a matching update replaces x" <|
                \_ ->
                    T.sliceUpdate Axis.retag0of2 0 (T.ones T.float32 (T.r2 (T.dim B 2) (T.dim B 2))) (T.zeros T.float32 (T.r2 (T.dim B 2) (T.dim B 2)))
                        |> Eval.floats
                        |> Expect.equal (Ok [ 1, 1, 1, 1 ])
            ]
        , describe "B050 empty axes"
            [ test "sort along an axis of size 0" <|
                \_ ->
                    T.sort { descending = False } (I.Axis 0) (T.fromList T.float32 (T.r1 (T.dim () 0)) [])
                        |> (\( v, i ) -> ( Eval.floats v, Eval.ints i ))
                        |> Expect.equal ( Ok [], Ok [] )
            , test "sliceUpdate of an empty update into an empty axis" <|
                \_ ->
                    T.sliceUpdate Axis.retag0of1 0 (T.fromList T.float32 (T.r1 (T.dim B 0)) []) (T.fromList T.float32 (T.r1 (T.dim B 0)) [])
                        |> Eval.floats
                        |> Expect.equal (Ok [])
            ]
        , describe "B013 Random.sig with no tensor"
            [ test "fails instead of giving seed 0" <|
                \_ ->
                    let
                        (I.SigBuilder sb) =
                            Random.sig
                    in
                    sb.build [] |> Tuple.first |> (\(I.Seed e) -> status e) |> Expect.equal "Tensor.Random.sig: no tensor to build the seed from"
            ]
        , describe "B051 pending axes"
            [ test "sign keeps a broadcast axis" <|
                \_ ->
                    Graph.function "g"
                        (Sig.f32 (T.r1 b3))
                        (\v -> T.sign (T.broadcast Axis.axis0of2 v) |> T.plus (T.ones T.float32 (T.r2 b4 b3)))
                        |> errorsOf
                        |> Expect.equal []
            , test "matmul refuses a pending inner axis as pending" <|
                \_ ->
                    status (O.matmul (O.broadcastAxis 1 (f32 [ 2 ] [ 1, 2 ])) (f32 [ 4, 5 ] (List.repeat 20 1)))
                        |> String.contains "has no size here"
                        |> Expect.equal True
            , test "matmul keeps a pending batch axis pending against an absent one" <|
                \_ ->
                    O.matmul (O.broadcastAxis 0 (f32 [ 2, 3 ] (List.repeat 6 1))) (f32 [ 3, 4 ] (List.repeat 12 1))
                        |> (\e -> ( E.shape e, E.pending e, E.poisoned e ))
                        |> Expect.equal ( [ 1, 2, 4 ], [ 0 ], False )
            , test "dropAxis refuses a pending axis even beside another" <|
                \_ ->
                    status (O.dropAxis 0 (O.broadcastAxis 0 (O.broadcastAxis 0 (f32 [ 3 ] [ 1, 2, 3 ]))))
                        |> String.contains "has no size here"
                        |> Expect.equal True
            , test "the pending message names maskBroadcast" <|
                \_ ->
                    status (E.prim ReduceSum [ O.broadcastAxis 0 (f32 [ 3 ] [ 1, 2, 3 ]) ] (P.ints [ 0 ]))
                        |> String.contains "maskBroadcast"
                        |> Expect.equal True
            ]
        , describe "B048 negative sizes"
            [ test "zeros of a negative size" <|
                \_ ->
                    Graph.function "g" (Sig.f32 (T.r1 b3)) (\_ -> T.zeros T.float32 (T.r1 (T.dim B -3)))
                        |> expectError "negative size"
            , test "reshape to [-2, -3]" <|
                \_ -> status (O.reshape [ -2, -3 ] (f32 [ 6 ] (List.repeat 6 1))) |> Expect.equal "reshape: negative size in [-2, -3]"
            , test "a constant of a negative shape" <|
                \_ -> status (f32 [ -1, -1 ] [ 1 ]) |> String.contains "negative size" |> Expect.equal True
            , test "arange of a negative length" <|
                \_ -> status (O.range 0 1 -2) |> String.contains "negative size" |> Expect.equal True
            , test "a draw of a negative size" <|
                \_ ->
                    Random.uniform { low = 0, high = 1 } T.float32 (T.r1 (T.dim B -2)) (Random.seed (T.int 1))
                        |> Eval.floats
                        |> errContains "negative size"
                        |> Expect.equal True
            , test "size 0 is accepted" <|
                \_ -> T.zeros T.float32 (T.r1 (T.dim B 0)) |> Eval.floats |> Expect.equal (Ok [])
            ]
        , describe "B040 lowest"
            [ test "bf16's lowest finite value" <|
                \_ -> O.lowest BF16 |> Expect.within (Expect.Absolute 0) -3.3895313892515355e38
            , test "f32's is kept" <|
                \_ -> O.lowest F32 |> Expect.within (Expect.Absolute 0) -3.4028234663852886e38
            ]
        , describe "B068 concat2 retags"
            [ test "retags naming different axes are refused" <|
                \_ ->
                    T.concat2 Axis.retag0of2 Axis.retag1of2 (T.dim B 4) (T.zeros T.float32 (T.r2 (T.dim B 2) (T.dim B 2))) (T.zeros T.float32 (T.r2 (T.dim B 2) (T.dim B 2)))
                        |> Eval.floats
                        |> errContains "concat2: the retags name different axes, 0 and 1"
                        |> Expect.equal True
            ]
        , describe "B089 topK axis"
            [ test "a negative axis is refused" <|
                \_ ->
                    status (Tuple.first (O.topK True -1 1 (f32 [ 3 ] [ 1, 2, 3 ])))
                        |> Expect.equal "topKValues: axis -1 is outside [3]"
            ]
        , describe "B057 names"
            [ test "row scatters are not named after put" <|
                \_ -> ( P.name ScatterRows, P.name ScatterRowsAdd ) |> Expect.equal ( "scatterRows", "scatterRowsAdd" )
            ]
        ]


{-| A check that a plain tensor built through the changed builders still evaluates.
-}
evalSmoke : Test
evalSmoke =
    test "zerosLike of a good tensor evaluates" <|
        \_ ->
            T.zerosLike (T.fromList T.float32 (T.r1 b3) [ 1, 2, 3 ])
                |> Eval.floats
                |> Expect.equal (Ok [ 0, 0, 0 ])
