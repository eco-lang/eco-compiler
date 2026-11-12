module EvalTests exposing (suite)

{-| `Tensor.Eval`, the pure-Elm evaluator (plans/tensor-eval-in-elm.md, E0–E2): each primitive on
small hand-computed cases, control flow, randomness, gradients against finite differences, `vmap`
against a loop, training a small network, and the refusals. Values stay within 2⁵³ (these run under
Node); the 64-bit cases are the E2E suite `test/eco-tensor`.
-}

import Dict
import Expect exposing (Expectation)
import Graph
import Nn
import Nn.Linear as Linear exposing (Linear)
import Optim
import Param
import Signature as Sig
import Tensor as T exposing (Dim, R1, R2, Tensor)
import Tensor.Axis as Axis
import Tensor.Control as Control
import Tensor.Eval as Eval exposing (Data(..))
import Tensor.Internal.Expr as E exposing (Expr)
import Tensor.Internal.Ops as O
import Tensor.Internal.Prim as P exposing (DT(..), Prim(..))
import Tensor.Internal.Types as I
import Tensor.Random as Random
import Test exposing (Test, describe, test)
import Train
import Transform


type A
    = A


type B
    = B


type C
    = C


a2 : Dim A
a2 =
    T.dim A 2


b3 : Dim B
b3 =
    T.dim B 3


c4 : Dim C
c4 =
    T.dim C 4



-- HELPERS


f32 : List Int -> List Float -> Expr
f32 =
    E.const F32


i64 : List Int -> List Float -> Expr
i64 =
    E.const SI64


evF : Expr -> Result (List String) (List Float)
evF e =
    Eval.floats (I.Tensor e)


evI : Expr -> Result (List String) (List Int)
evI e =
    Eval.ints (I.Tensor e)


evB : Expr -> Result (List String) (List Bool)
evB e =
    Eval.mask (I.Mask e)


{-| Equal within a relative (and absolute, near 0) tolerance, NaN equal to NaN.
-}
close : Float -> List Float -> Result (List String) (List Float) -> Expectation
close tol want got =
    case got of
        Err es ->
            Expect.fail (String.join "; " es)

        Ok vs ->
            if List.length vs /= List.length want then
                Expect.fail ("lengths differ: got " ++ Debug.toString vs)

            else if
                List.all identity
                    (List.map2
                        (\w v ->
                            (isNaN w && isNaN v) || w == v || Basics.abs (w - v) <= tol * Basics.max 1 (Basics.abs w)
                        )
                        want
                        vs
                    )
            then
                Expect.pass

            else
                Expect.fail ("want " ++ Debug.toString want ++ ", got " ++ Debug.toString vs)


exactly : List Float -> Result (List String) (List Float) -> Expectation
exactly =
    close 0


failsWith : String -> Result (List String) a -> Expectation
failsWith part r =
    case r of
        Err es ->
            if List.any (String.contains part) es then
                Expect.pass

            else
                Expect.fail ("errors do not mention " ++ part ++ ": " ++ String.join "; " es)

        Ok _ ->
            Expect.fail ("expected an error mentioning " ++ part)


suite : Test
suite =
    describe "Tensor.Eval"
        [ plumbing
        , elementwise
        , reductions
        , shapes
        , indexing
        , layers
        , control
        , randomness
        , verification
        ]



-- E0


plumbing : Test
plumbing =
    describe "plumbing"
        [ test "a float constant round-trips" <|
            \_ -> Eval.floats (T.fromList T.float32 (T.r1 b3) [ 1, 2.5, -3 ]) |> exactly [ 1, 2.5, -3 ]
        , test "an int constant round-trips" <|
            \_ -> Eval.ints (T.fromList T.int64 (T.r1 b3) [ 7, -3, 0 ]) |> Expect.equal (Ok [ 7, -3, 0 ])
        , test "a mask round-trips" <|
            \_ -> Eval.mask (T.fromList T.int64 (T.r1 b3) [ 1, 2, 3 ] |> T.greaterThan (T.full T.int64 1 (T.r1 b3))) |> Expect.equal (Ok [ False, True, True ])
        , test "run: an output that is its input" <|
            \_ ->
                case Graph.function "id" (Sig.label "x" (Sig.f32 (T.r1 b3))) identity of
                    Ok g ->
                        Eval.run g (Dict.singleton "x" { dtype = "f32", shape = [ 3 ], data = Floats [ 1, 2, 3 ] })
                            |> Result.map Dict.values
                            |> Expect.equal (Ok [ { dtype = "f32", shape = [ 3 ], data = Floats [ 1, 2, 3 ] } ])

                    Err e ->
                        Expect.fail (String.join "; " e)
        , test "run: a missing input is an error naming it" <|
            \_ ->
                case Graph.function "id" (Sig.label "x" (Sig.f32 (T.r1 b3))) identity of
                    Ok g ->
                        Eval.run g Dict.empty |> failsWith "missing input x"

                    Err e ->
                        Expect.fail (String.join "; " e)
        , test "run: a wrong shape is an error" <|
            \_ ->
                case Graph.function "id" (Sig.label "x" (Sig.f32 (T.r1 b3))) identity of
                    Ok g ->
                        Eval.run g (Dict.singleton "x" { dtype = "f32", shape = [ 2 ], data = Floats [ 1, 2 ] }) |> failsWith "shape [2]"

                    Err e ->
                        Expect.fail (String.join "; " e)
        , test "floats refuses a tensor that reads a graph input" <|
            \_ ->
                Eval.floats (I.Tensor (E.input "g" 0 F32 [ 2 ])) |> failsWith "input"
        , test "residentZeros lists every resident buffer of a training step" <|
            \_ ->
                case mlpStep of
                    Ok g ->
                        Eval.residentZeros g
                            |> Dict.keys
                            |> List.sort
                            |> Expect.equal (List.sort (Graph.inputs g |> List.filterMap residentName))

                    Err e ->
                        Expect.fail (String.join "; " e)
        , test "residentZeros covers Train.initial's names" <|
            \_ ->
                case mlpStep of
                    Ok g ->
                        Eval.residentZeros g
                            |> Dict.keys
                            |> List.sort
                            |> Expect.equal (List.sort (List.map Tuple.first (Train.initial mlpParams (Optim.sgd 0.5) 1)))

                    Err e ->
                        Expect.fail (String.join "; " e)
        ]


residentName : Graph.Spec -> Maybe String
residentName s =
    case s.role of
        Graph.Resident n ->
            Just n

        Graph.Fed ->
            Nothing



-- E1.1


elementwise : Test
elementwise =
    describe "element-wise"
        [ test "add with a scalar broadcast" <|
            \_ -> evF (O.add (f32 [ 3 ] [ 1, 2, 3 ]) (f32 [] [ 1 ])) |> exactly [ 2, 3, 4 ]
        , test "sub, mul, div" <|
            \_ ->
                evF (O.div (O.mul (O.sub (f32 [ 2 ] [ 5, 1 ]) (f32 [ 2 ] [ 1, 2 ])) (f32 [ 2 ] [ 3, 4 ])) (f32 [ 2 ] [ 2, 8 ]))
                    |> exactly [ 6, -0.5 ]
        , test "pow" <|
            \_ -> evF (O.binary Pow (f32 [ 2 ] [ 2, 9 ]) (f32 [ 2 ] [ 10, 0.5 ])) |> exactly [ 1024, 3 ]
        , test "i8 wraps" <|
            \_ -> evI (O.add (E.const SI8 [ 2 ] [ 127, -128 ]) (E.const SI8 [ 2 ] [ 1, -1 ])) |> Expect.equal (Ok [ -128, 127 ])
        , test "u8 wraps" <|
            \_ -> evI (O.sub (E.const UI8 [ 2 ] [ 0, 200 ]) (E.const UI8 [ 2 ] [ 1, 100 ])) |> Expect.equal (Ok [ 255, 100 ])
        , test "i32 wraps" <|
            \_ -> evI (O.add (E.const SI32 [ 1 ] [ 2147483647 ]) (E.const SI32 [ 1 ] [ 1 ])) |> Expect.equal (Ok [ -2147483648 ])
        , test "u8 products wrap" <|
            \_ -> evI (O.mul (E.const UI8 [ 1 ] [ 16 ]) (E.const UI8 [ 1 ] [ 17 ])) |> Expect.equal (Ok [ 16 ])
        , test "modBy has the divisor's sign" <|
            \_ ->
                Eval.ints (T.fromList T.int64 (T.r1 c4) [ -7, 7, -7, 7 ] |> T.modBy (T.fromList T.int64 (T.r1 c4) [ 3, 3, -3, -3 ]))
                    |> Expect.equal (Ok [ 2, 1, -1, -2 ])
        , test "modBy 0 is refused" <|
            \_ -> Eval.ints (T.fromList T.int64 (T.r1 a2) [ 1, 2 ] |> T.modBy (T.fromList T.int64 (T.r1 a2) [ 1, 0 ])) |> failsWith "modBy: integer division by zero"
        , test "u64 modBy (small values)" <|
            \_ -> evI (O.binary Mod (E.const UI64 [ 1 ] [ 10 ]) (E.const UI64 [ 1 ] [ 4 ])) |> Expect.equal (Ok [ 2 ])
        , test "abs, negate (ints)" <|
            \_ -> evI (O.neg (O.unary Abs (i64 [ 2 ] [ -3, 4 ]))) |> Expect.equal (Ok [ -3, -4 ])
        , test "relu" <|
            \_ -> evF (O.unary Relu (f32 [ 3 ] [ -1, 0, 2 ])) |> exactly [ 0, 0, 2 ]
        , test "exp, log, sqrt, rsqrt" <|
            \_ ->
                evF (O.concat 0 [ O.unary Exp (f32 [ 2 ] [ 1, -20 ]), O.unary Log (f32 [ 1 ] [ 10 ]), O.unary Sqrt (f32 [ 1 ] [ 2 ]), O.unary Rsqrt (f32 [ 1 ] [ 4 ]) ])
                    |> close 1.0e-15 [ 2.718281828459045, 2.061153622438558e-9, 2.302585092994046, 1.4142135623730951, 0.5 ]
        , test "exp at its range limits" <|
            \_ -> evF (O.unary Exp (f32 [ 4 ] [ 700, -740, 710, -800 ])) |> close 1.0e-14 [ 1.0142320547350045e304, 4.2e-322, 1 / 0, 0 ]
        , test "erf (Cody)" <|
            \_ ->
                evF (O.unary Erf (f32 [ 7 ] [ 0.1, 0.5, 1, 2, 3.5, 5, -1.5 ]))
                    |> close 2.0e-15 [ 0.1124629160182849, 0.5204998778130465, 0.8427007929497149, 0.9953222650189527, 0.9999992569016276, 0.9999999999984626, -0.9661051464753108 ]
        , test "tanh, sigmoid, log1p, atanh" <|
            \_ ->
                evF (O.concat 0 [ O.unary Tanh (f32 [ 2 ] [ 0.5, -30 ]), O.unary Sigmoid (f32 [ 2 ] [ 0, -800 ]), O.unary Log1p (f32 [ 1 ] [ 1.0e-10 ]), O.unary Atanh (f32 [ 1 ] [ 0.5 ]) ])
                    |> close 1.0e-15 [ 0.46211715726000974, -1, 0.5, 0, 9.9999999995e-11, 0.5493061443340549 ]
        , test "gelu, geluTanh, silu" <|
            \_ ->
                evF (O.concat 0 [ O.unary Gelu (f32 [ 1 ] [ 1 ]), O.unary GeluTanh (f32 [ 1 ] [ 1 ]), O.unary Silu (f32 [ 1 ] [ 1 ]) ])
                    |> close 1.0e-14 [ 0.8413447460685429, 0.8411919906082768, 0.7310585786300049 ]
        , test "floor, truncate" <|
            \_ -> evF (O.concat 0 [ O.unary Floor (f32 [ 2 ] [ 1.5, -1.5 ]), O.unary Trunc (f32 [ 2 ] [ 1.5, -1.5 ]) ]) |> exactly [ 1, -2, 1, -1 ]
        , test "round is half to even" <|
            \_ -> evF (O.unary Round (f32 [ 6 ] [ 0.5, 1.5, 2.5, -0.5, -1.5, 2.6 ])) |> exactly [ 0, 2, 2, 0, -2, 3 ]
        , test "isNaN, isInfinite" <|
            \_ -> evB (O.binary Or (O.unary IsNaN (f32 [ 3 ] [ 0 / 0, 1, 1 / 0 ])) (O.unary IsInf (f32 [ 3 ] [ 0 / 0, 1, 1 / 0 ]))) |> Expect.equal (Ok [ True, False, True ])
        , test "max and min ignore NaN, as MAX does" <|
            \_ -> evF (O.concat 0 [ O.binary Max2 (f32 [ 3 ] [ 0 / 0, 1, 0 / 0 ]) (f32 [ 3 ] [ 1, 0 / 0, 0 / 0 ]), O.binary Min2 (f32 [ 2 ] [ 0 / 0, 3 ]) (f32 [ 2 ] [ -1, 0 / 0 ]) ]) |> exactly [ 1, 1, 0 / 0, -1, 3 ]
        , test "comparisons with NaN are false, not-equal too (ordered, as MAX)" <|
            \_ ->
                evB (O.concat 0 [ O.binary Gt (f32 [ 1 ] [ 0 / 0 ]) (f32 [ 1 ] [ 0 ]), O.binary Eq (f32 [ 1 ] [ 0 / 0 ]) (f32 [ 1 ] [ 0 / 0 ]), O.binary Ne (f32 [ 1 ] [ 0 / 0 ]) (f32 [ 1 ] [ 0 ]) ])
                    |> Expect.equal (Ok [ False, False, False ])
        , test "u64 compares unsigned" <|
            \_ -> evB (O.binary Gt (E.const UI64 [ 2 ] [ -1, 1 ]) (E.const UI64 [ 2 ] [ 1, -1 ])) |> Expect.equal (Ok [ True, False ])
        , test "u64 max is unsigned" <|
            \_ -> evI (O.binary Max2 (E.const UI64 [ 1 ] [ -1 ]) (E.const UI64 [ 1 ] [ 1 ])) |> Expect.equal (Ok [ -1 ])
        , test "select" <|
            \_ ->
                Eval.floats (T.select (T.fromList T.int64 (T.r1 b3) [ 1, 5, 3 ] |> T.greaterThan (T.full T.int64 2 (T.r1 b3))) (T.full T.float32 1 (T.r1 b3)) (T.zeros T.float32 (T.r1 b3)))
                    |> exactly [ 0, 1, 1 ]
        , test "and, or, xor, not" <|
            \_ ->
                let
                    m l =
                        O.cast Bool (i64 [ 4 ] l)
                in
                evI (O.concat 0 [ O.cast SI64 (O.binary And (m [ 0, 0, 1, 1 ]) (m [ 0, 1, 0, 1 ])), O.cast SI64 (O.binary Xor (m [ 0, 0, 1, 1 ]) (m [ 0, 1, 0, 1 ])), O.cast SI64 (O.unary Not (m [ 0, 0, 1, 1 ])) ])
                    |> Expect.equal (Ok [ 0, 0, 0, 1, 0, 1, 1, 0, 1, 1, 0, 0 ])
        , test "cast float to int truncates" <|
            \_ -> evI (O.cast SI32 (f32 [ 3 ] [ 1.7, -1.7, 0.2 ])) |> Expect.equal (Ok [ 1, -1, 0 ])
        , test "cast int to int wraps" <|
            \_ -> evI (O.cast UI8 (i64 [ 2 ] [ 257, -1 ])) |> Expect.equal (Ok [ 1, 255 ])
        , test "cast to bool is x ≠ 0 (NaN is true)" <|
            \_ -> evB (O.cast Bool (f32 [ 3 ] [ 0, 0.5, 0 / 0 ])) |> Expect.equal (Ok [ False, True, True ])
        , test "cast of NaN to an integer is refused" <|
            \_ -> evI (O.cast SI64 (f32 [ 1 ] [ 0 / 0 ])) |> failsWith "cast: cannot convert NaN"
        , test "cast out of range is refused" <|
            \_ -> evI (O.cast UI8 (f32 [ 1 ] [ 256 ])) |> failsWith "out of range"
        , test "u64 to float is unsigned" <|
            \_ -> evF (O.cast F64 (E.const UI64 [ 1 ] [ -1 ])) |> exactly [ 2 ^ 64 ]
        ]



-- E1.2


reductions : Test
reductions =
    let
        m =
            f32 [ 2, 3 ] [ 1, 5, 3, 4, 2, 6 ]
    in
    describe "reductions"
        [ test "sum over each axis" <|
            \_ -> evF (O.concat 0 [ O.reduce ReduceSum 0 m, O.reduce ReduceSum 1 m ]) |> exactly [ 5, 7, 9, 9, 12 ]
        , test "keep the axis" <|
            \_ -> Eval.floats (I.Tensor (O.reduceKeep ReduceSum 1 m)) |> exactly [ 9, 12 ]
        , test "mean, max, min" <|
            \_ -> evF (O.concat 0 [ O.reduce ReduceMean 1 m, O.reduce ReduceMax 1 m, O.reduce ReduceMin 0 m ]) |> exactly [ 3, 4, 5, 6, 1, 2, 3 ]
        , test "int sums wrap" <|
            \_ -> evI (O.reduce ReduceSum 0 (E.const SI8 [ 2 ] [ 100, 100 ])) |> Expect.equal (Ok [ -56 ])
        , test "argMax and argMin: lowest index on ties" <|
            \_ -> evI (O.concat 0 [ O.reduce ArgMax 1 (f32 [ 2, 3 ] [ 1, 5, 5, 4, 2, 6 ]), O.reduce ArgMin 1 (f32 [ 2, 3 ] [ 1, 1, 5, 4, 2, 2 ]) ]) |> Expect.equal (Ok [ 1, 2, 0, 1 ])
        , test "argMax and max skip NaN, as MAX does" <|
            \_ ->
                Expect.equal ( evI (O.reduce ArgMax 0 (f32 [ 4 ] [ 1, 0 / 0, 3, 0 / 0 ])), evF (O.reduce ReduceMax 0 (f32 [ 3 ] [ 0 / 0, 2, 0 / 0 ])) )
                    ( Ok [ 2 ], Ok [ 2 ] )
        , test "softmax" <|
            \_ -> Eval.floats (T.fromList T.float32 (T.r1 b3) [ 0, 0, 1000 ] |> T.softmax Axis.last1) |> close 1.0e-15 [ 0, 0, 1 ]
        , test "logSoftmax" <|
            \_ -> Eval.floats (T.fromList T.float32 (T.r1 a2) [ 0, 0 ] |> T.logSoftmax Axis.last1) |> close 1.0e-15 [ -0.6931471805599453, -0.6931471805599453 ]
        , test "cumsum, exclusive, reverse" <|
            \_ ->
                evF (O.concat 0 [ O.cumsum 0 False False (f32 [ 3 ] [ 1, 2, 3 ]), O.cumsum 0 True False (f32 [ 3 ] [ 1, 2, 3 ]), O.cumsum 0 False True (f32 [ 3 ] [ 1, 2, 3 ]), O.cumsum 0 True True (f32 [ 3 ] [ 1, 2, 3 ]) ])
                    |> exactly [ 1, 3, 6, 0, 1, 3, 6, 5, 3, 5, 3, 0 ]
        , test "cumsum along axis 1" <|
            \_ -> evF (O.cumsum 1 False False m) |> exactly [ 1, 6, 9, 4, 6, 12 ]
        , test "matmul 2×3 @ 3×2" <|
            \_ -> evF (O.matmul m (f32 [ 3, 2 ] [ 1, 0, 0, 1, 1, 1 ])) |> exactly [ 4, 8, 10, 8 ]
        , test "matmul with rank-1 operands" <|
            \_ -> evF (O.concat 0 [ O.matmul (f32 [ 3 ] [ 1, 1, 1 ]) (f32 [ 3, 2 ] [ 1, 2, 3, 4, 5, 6 ]), O.matmul m (f32 [ 3 ] [ 1, 0, 1 ]), O.reshape [ 1 ] (O.matmul (f32 [ 3 ] [ 1, 2, 3 ]) (f32 [ 3 ] [ 4, 5, 6 ])) ]) |> exactly [ 9, 12, 4, 10, 32 ]
        , test "batched matmul broadcasts the batch" <|
            \_ -> evF (O.matmul (f32 [ 2, 1, 2 ] [ 1, 2, 3, 4 ]) (f32 [ 2, 1 ] [ 1, 1 ])) |> exactly [ 3, 7 ]
        , test "int matmul" <|
            \_ -> evI (O.matmul (i64 [ 1, 2 ] [ 2, 3 ]) (i64 [ 2, 1 ] [ 4, 5 ])) |> Expect.equal (Ok [ 23 ])
        ]



-- E1.3


shapes : Test
shapes =
    let
        m =
            f32 [ 2, 3 ] [ 1, 2, 3, 4, 5, 6 ]
    in
    describe "shapes"
        [ test "reshape keeps the data" <|
            \_ -> evF (O.reshape [ 3, 2 ] m) |> exactly [ 1, 2, 3, 4, 5, 6 ]
        , test "transpose" <|
            \_ -> evF (O.transpose [ 1, 0 ] m) |> exactly [ 1, 4, 2, 5, 3, 6 ]
        , test "transpose of rank 3" <|
            \_ -> evF (O.transpose [ 2, 0, 1 ] (f32 [ 2, 1, 2 ] [ 1, 2, 3, 4 ])) |> exactly [ 1, 3, 2, 4 ]
        , test "broadcastTo" <|
            \_ -> evF (O.broadcastTo [ 2, 3 ] (f32 [ 3 ] [ 1, 2, 3 ])) |> exactly [ 1, 2, 3, 1, 2, 3 ]
        , test "broadcastTo a column" <|
            \_ -> evF (O.broadcastTo [ 2, 3 ] (f32 [ 2, 1 ] [ 1, 2 ])) |> exactly [ 1, 1, 1, 2, 2, 2 ]
        , test "slice" <|
            \_ -> evF (O.slice [ 0, 1 ] [ 2, 2 ] m) |> exactly [ 2, 3, 5, 6 ]
        , test "concat along axis 1" <|
            \_ -> evF (O.concat 1 [ m, f32 [ 2, 1 ] [ 7, 8 ] ]) |> exactly [ 1, 2, 3, 7, 4, 5, 6, 8 ]
        , test "pad" <|
            \_ -> Eval.floats (T.fromList T.float32 (T.r1 a2) [ 1, 2 ] |> T.pad Axis.retag0of1 { before = 1, after = 1, value = 9 } c4) |> exactly [ 9, 1, 2, 9 ]
        , test "padInt" <|
            \_ -> Eval.ints (T.fromList T.int64 (T.r1 a2) [ 1, 2 ] |> T.padInt Axis.retag0of1 { before = 2, after = 0, value = -5 } c4) |> Expect.equal (Ok [ -5, -5, 1, 2 ])
        , test "pad along axis 1" <|
            \_ -> evF (O.pad 1 0 1 0 m) |> exactly [ 1, 2, 3, 0, 4, 5, 6, 0 ]
        , test "flip" <|
            \_ -> Eval.floats (T.fromList T.float32 (T.r1 b3) [ 1, 2, 3 ] |> T.flip Axis.axis0of1) |> exactly [ 3, 2, 1 ]
        , test "stack and unstack" <|
            \_ ->
                Eval.floats (T.stack Axis.liftRank1 a2 (T.unstack Axis.liftRank1 (T.fromList T.float32 (T.r2 a2 b3) [ 1, 2, 3, 4, 5, 6 ]) |> List.reverse))
                    |> exactly [ 4, 5, 6, 1, 2, 3 ]
        ]



-- E1.4


indexing : Test
indexing =
    describe "indexing"
        [ test "gather along axis 0 with repeats" <|
            \_ -> evF (O.gather 0 (f32 [ 3, 2 ] [ 1, 2, 3, 4, 5, 6 ]) (i64 [ 3 ] [ 2, 0, 2 ])) |> exactly [ 5, 6, 1, 2, 5, 6 ]
        , test "gather along axis 1 with rank-2 indices" <|
            \_ -> evF (O.gather 1 (f32 [ 2, 3 ] [ 1, 2, 3, 4, 5, 6 ]) (i64 [ 2, 2 ] [ 0, 2, 1, 1 ])) |> exactly [ 1, 3, 2, 2, 4, 6, 5, 5 ]
        , test "gather refuses an index out of range" <|
            \_ -> evF (O.gather 0 (f32 [ 3 ] [ 1, 2, 3 ]) (i64 [ 1 ] [ 3 ])) |> failsWith "index 3 is outside"
        , test "gather refuses a negative index" <|
            \_ -> evF (O.gather 0 (f32 [ 3 ] [ 1, 2, 3 ]) (i64 [ 1 ] [ -1 ])) |> failsWith "index -1"
        , test "pick" <|
            \_ -> Eval.floats (T.fromList T.float32 (T.r2 a2 b3) [ 1, 2, 3, 4, 5, 6 ] |> T.pick (T.fromList T.int64 (T.r1 a2) [ 2, 0 ])) |> exactly [ 3, 4 ]
        , test "scatter rows: the last duplicate wins" <|
            \_ -> evF (O.scatterRows (f32 [ 3, 1 ] [ 0, 0, 0 ]) (f32 [ 3, 1 ] [ 1, 2, 3 ]) (i64 [ 3, 1 ] [ 1, 1, 0 ])) |> exactly [ 3, 2, 0 ]
        , test "scatter rows add: duplicates sum" <|
            \_ -> evF (O.scatterRowsAdd (f32 [ 3, 1 ] [ 1, 1, 1 ]) (f32 [ 3, 1 ] [ 1, 2, 3 ]) (i64 [ 3, 1 ] [ 1, 1, 0 ])) |> exactly [ 4, 4, 1 ]
        , test "put along axis 1" <|
            \_ ->
                Eval.floats (T.zeros T.float32 (T.r2 a2 b3) |> T.put Axis.retag1of2 (T.fromList T.int64 (T.r1 a2) [ 2, 0 ]) (T.fromList T.float32 (T.r2 a2 a2) [ 1, 2, 3, 4 ]))
                    |> exactly [ 2, 0, 1, 4, 0, 3 ]
        , test "putAdd along axis 0" <|
            \_ ->
                Eval.floats (T.ones T.float32 (T.r2 a2 b3) |> T.putAdd Axis.retag0of2 (T.fromList T.int64 (T.r1 a2) [ 1, 1 ]) (T.fromList T.float32 (T.r2 a2 b3) [ 1, 2, 3, 4, 5, 6 ]))
                    |> exactly [ 1, 1, 1, 6, 8, 10 ]
        , test "triu and tril" <|
            \_ ->
                let
                    m =
                        T.fromList T.float32 (T.r2 b3 b3) [ 1, 2, 3, 4, 5, 6, 7, 8, 9 ]
                in
                Eval.floats (T.plus (T.triu 1 m) (T.tril -1 m |> T.scale 10))
                    |> exactly [ 0, 2, 3, 40, 0, 6, 70, 80, 0 ]
        , test "iota and arange" <|
            \_ -> Eval.ints (T.arange { start = 5, step = -2 } c4 |> T.plus (T.iota c4)) |> Expect.equal (Ok [ 5, 4, 3, 2 ])
        ]



-- E1.5


layers : Test
layers =
    describe "layers"
        [ test "cross-entropy from logits" <|
            \_ ->
                evF (O.xent (f32 [ 2, 2 ] [ 0, 0, 1, 3 ]) (f32 [ 2, 2 ] [ 1, 0, 0, 1 ]))
                    |> close 1.0e-14 [ (logBase e 2 + logBase e (1 + e ^ -2)) / 2 ]
        , test "layer norm" <|
            \_ ->
                evF (O.layerNorm 0 (f32 [ 1, 2 ] [ 1, 3 ]) (f32 [ 2 ] [ 2, 1 ]) (f32 [ 2 ] [ 0, 10 ]))
                    |> close 1.0e-15 [ -2, 11 ]
        , test "conv: 3×3 input, 2×2 filter, stride 1, no padding" <|
            \_ ->
                evF (O.conv [ 1, 1, 0, 0, 0, 0 ] (f32 [ 1, 3, 3, 1 ] [ 1, 2, 3, 4, 5, 6, 7, 8, 9 ]) (f32 [ 2, 2, 1, 1 ] [ 1, 0, 0, 1 ]))
                    |> exactly [ 6, 8, 12, 14 ]
        , test "conv: padding 1, stride 2, two output channels" <|
            \_ ->
                -- out (3 × 3 × 2): xpad[2y − 1, 2x − 1], so only (1, 1) reads the input (5)
                evF (O.conv [ 2, 2, 1, 1, 1, 1 ] (f32 [ 1, 3, 3, 1 ] [ 1, 2, 3, 4, 5, 6, 7, 8, 9 ]) (f32 [ 1, 1, 1, 2 ] [ 1, -1 ]))
                    |> exactly [ 0, 0, 0, 0, 0, 0, 0, 0, 5, -5, 0, 0, 0, 0, 0, 0, 0, 0 ]
        , test "conv: dilation 2" <|
            \_ ->
                evF (O.conv [ 1, 1, 0, 0, 0, 0, 2, 2 ] (f32 [ 1, 3, 3, 1 ] [ 1, 2, 3, 4, 5, 6, 7, 8, 9 ]) (f32 [ 2, 2, 1, 1 ] [ 1, 1, 1, 1 ]))
                    |> exactly [ 20 ]
        , test "conv transpose is conv's adjoint: <conv x, y> = <x, convT y>" <|
            \_ ->
                let
                    geometry =
                        [ 2, 1, 1, 0, 0, 1, 1, 2 ]

                    -- 5 × 3: conv's output (3 × 2) maps back to exactly 5 × 3
                    x =
                        f32 [ 1, 5, 3, 2 ] (List.map (\i -> toFloat (modBy 7 (i * 3)) - 3) (List.range 0 29))

                    f =
                        f32 [ 2, 2, 2, 3 ] (List.map (\i -> toFloat (modBy 5 (i * 2)) - 2) (List.range 0 23))

                    cx =
                        O.conv geometry x f

                    y =
                        f32 (E.shape cx) (List.map (\i -> toFloat (modBy 3 i) - 1) (List.range 0 (List.product (E.shape cx) - 1)))

                    ct =
                        O.convTranspose geometry y f
                in
                Expect.equal ( E.shape ct, evF (O.reduce ReduceSum 0 (O.reshape [ List.product (E.shape cx) ] (O.mul cx y))) )
                    ( E.shape x, evF (O.reduce ReduceSum 0 (O.reshape [ 30 ] (O.mul x ct))) )
        , test "max and average pooling" <|
            \_ ->
                let
                    x =
                        f32 [ 1, 2, 4, 1 ] [ 1, 2, 3, 4, 5, 6, 7, 9 ]
                in
                evF (O.concat 0 [ O.reshape [ 2 ] (O.maxPool 2 x), O.reshape [ 2 ] (O.avgPool 2 x) ]) |> exactly [ 6, 9, 3.5, 5.75 ]
        , test "topK: largest first, ties lowest index first" <|
            \_ ->
                let
                    ( v, i ) =
                        O.topK True 0 3 (f32 [ 5 ] [ 3, 1, 4, 1, 4 ])
                in
                Expect.equal ( evF v, evI i ) ( Ok [ 4, 4, 3 ], Ok [ 2, 4, 0 ] )
        , test "bottomK: smallest first" <|
            \_ ->
                let
                    ( v, i ) =
                        O.topK False 0 2 (f32 [ 5 ] [ 3, 1, 4, 1, 4 ])
                in
                Expect.equal ( evF v, evI i ) ( Ok [ 1, 1 ], Ok [ 1, 3 ] )
        , test "sort along axis 1" <|
            \_ ->
                let
                    ( v, i ) =
                        T.sort { descending = False } Axis.last2 (T.fromList T.int64 (T.r2 a2 b3) [ 3, 1, 2, 0, 9, 5 ])
                in
                Expect.equal ( Eval.ints v, Eval.ints i ) ( Ok [ 1, 2, 3, 0, 5, 9 ], Ok [ 1, 2, 0, 0, 2, 1 ] )
        ]



-- E1.6


control : Test
control =
    describe "control"
        [ test "a shared function called twice gives two results" <|
            \_ ->
                let
                    sq =
                        Transform.shared "sq" (Sig.f32 (T.r1 a2)) (Sig.f32 (T.r1 a2)) (\x -> T.times x x)
                in
                Eval.floats (T.plus (Transform.call sq (T.fromList T.float32 (T.r1 a2) [ 1, 2 ])) (Transform.call sq (T.fromList T.float32 (T.r1 a2) [ 3, 4 ])))
                    |> exactly [ 10, 20 ]
        , test "cond runs only the chosen branch" <|
            \_ ->
                let
                    x =
                        T.fromList T.float32 (T.r1 b3) [ 1, 2, 3 ]

                    bad v =
                        -- an index out of range: refused if it ran
                        v |> T.take Axis.retag0of1 (T.fromList T.int64 (T.r1 b3) [ 0, 1, 7 ])
                in
                Eval.floats (Control.cond (T.float 1 |> T.lessThan (T.float 0)) (Sig.f32 (T.r1 b3)) (Sig.f32 (T.r1 b3)) bad (T.scale 2) x)
                    |> exactly [ 2, 4, 6 ]
        , test "whileLoop counts up" <|
            \_ ->
                Eval.ints
                    (Control.whileLoop (Sig.i64 T.scalar) (\i -> T.lessThan (T.int 10) i) (T.plus (T.int 3)) (T.int 0))
                    |> Expect.equal (Ok [ 12 ])
        , test "a whileLoop over two values (Fibonacci)" <|
            \_ ->
                Eval.ints
                    (Control.whileLoop (Sig.pair (Sig.i64 T.scalar) (Sig.i64 T.scalar))
                        (\( a, _ ) -> T.lessThan (T.int 50) a)
                        (\( a, b ) -> ( b, T.plus a b ))
                        ( T.int 0, T.int 1 )
                        |> Tuple.first
                    )
                    |> Expect.equal (Ok [ 55 ])
        , test "a whileLoop body reads an outer tensor" <|
            \_ ->
                let
                    step =
                        T.fromList T.int64 (T.r1 a2) [ 1, 2 ]
                in
                Eval.ints
                    (Control.whileLoop (Sig.i64 (T.r1 a2)) (\v -> T.lessThan (T.int 6) (T.sumAll v)) (T.plus step) (T.zeros T.int64 (T.r1 a2)))
                    |> Expect.equal (Ok [ 2, 4 ])
        , test "nested whileLoops" <|
            \_ ->
                let
                    inner n =
                        Control.whileLoop (Sig.pair (Sig.i64 T.scalar) (Sig.i64 T.scalar)) (\( i, _ ) -> T.lessThan n i) (\( i, s ) -> ( T.plus (T.int 1) i, T.plus i s )) ( T.int 0, T.int 0 ) |> Tuple.second
                in
                Eval.ints
                    (Control.whileLoop (Sig.pair (Sig.i64 T.scalar) (Sig.i64 T.scalar)) (\( n, _ ) -> T.lessThan (T.int 4) n) (\( n, acc ) -> ( T.plus (T.int 1) n, T.plus acc (inner n) )) ( T.int 0, T.int 0 ) |> Tuple.second)
                    |> Expect.equal (Ok [ 0 + 0 + 1 + 3 ])
        , test "repeat and scan" <|
            \_ ->
                let
                    ( total, partial ) =
                        Control.scan Axis.liftRank0 Axis.liftRank0 (\c x -> ( T.plus x c, T.plus x c )) (T.float 0) (T.fromList T.float32 (T.r1 c4) [ 1, 2, 3, 4 ])
                in
                Expect.equal ( Eval.floats total, Eval.floats partial, Eval.floats (Control.repeat 3 (Sig.f32 T.scalar) (T.scale 2) (T.float 1)) )
                    ( Ok [ 10 ], Ok [ 1, 3, 6, 10 ], Ok [ 8 ] )
        , test "a runaway whileLoop stops at the guard" <|
            \_ ->
                case Graph.function "loop" Sig.unit (\() -> Control.whileLoop (Sig.i64 T.scalar) (\_ -> T.lessThan (T.int 1) (T.int 0)) (T.plus (T.int 1)) (T.int 0)) of
                    Ok g ->
                        Eval.runWith { maxIterations = 10 } g Dict.empty |> failsWith "more than 10 iterations"

                    Err e ->
                        Expect.fail (String.join "; " e)
        ]



-- E1.7


randomness : Test
randomness =
    let
        draws s =
            Eval.floats (Random.uniform { low = 0, high = 1 } T.float32 (T.r1 c4) s)

        seed n =
            Random.seed (T.int n)
    in
    describe "randomness"
        [ test "the same seed gives the same draws" <|
            \_ -> Expect.equal (draws (seed 3)) (draws (seed 3))
        , test "another seed gives other draws" <|
            \_ -> Expect.notEqual (draws (seed 3)) (draws (seed 4))
        , test "a salted seed gives other draws" <|
            \_ -> Expect.notEqual (draws (seed 3)) (draws (Random.salt 1 (seed 3)))
        , test "uniform draws lie in [low, high)" <|
            \_ ->
                Eval.floats (Random.uniform { low = -2, high = 3 } T.float32 (T.r1 (T.dim A 200)) (seed 9))
                    |> Result.map (List.all (\v -> v >= -2 && v < 3))
                    |> Expect.equal (Ok True)
        , test "salt computes seed · 25214903917 + (2i + 1), wrapping" <|
            \_ ->
                Eval.ints
                    (T.cast T.int64
                        (I.Tensor
                            (case Random.salt 2 (seed 5) of
                                I.Seed e ->
                                    e
                            )
                        )
                    )
                    |> Expect.equal (Ok [ 5 * 25214903917 + 5 ])
        ]



-- E2.1


type Hidden
    = Hidden


type Classes
    = Classes


type Pts
    = Pts


type Feat
    = Feat


verification : Test
verification =
    describe "verification"
        [ test "grad of a scalar function against central differences" <|
            \_ ->
                let
                    f x =
                        x |> T.times x |> T.sin |> T.plus (T.exp (T.scale 0.5 x)) |> T.times (T.tanh x) |> T.sumAll

                    point =
                        [ 0.3, -0.7, 1.1 ]

                    at l =
                        T.fromList T.float64 (T.r1 b3) l

                    value l =
                        Eval.floats (f (at l)) |> Result.withDefault [] |> List.head |> Maybe.withDefault 0

                    h =
                        1.0e-6

                    numeric =
                        List.indexedMap
                            (\i _ ->
                                let
                                    bump d =
                                        List.indexedMap
                                            (\j v ->
                                                if i == j then
                                                    v + d

                                                else
                                                    v
                                            )
                                            point
                                in
                                (value (bump h) - value (bump -h)) / (2 * h)
                            )
                            point
                in
                Eval.floats (Transform.grad f (at point)) |> close 1.0e-6 numeric
        , test "a second derivative (grad of grad)" <|
            \_ ->
                Eval.floats (Transform.grad (\x -> Transform.grad (\y -> T.sumAll (T.times y (T.times y y))) x |> T.sumAll) (T.fromList T.float64 (T.r1 a2) [ 1, 2 ]))
                    |> close 1.0e-12 [ 6, 12 ]
        , test "vmap against a loop over examples" <|
            \_ ->
                let
                    w =
                        T.fromList T.float32 (T.r2 b3 a2) [ 1, -1, 2, 0.5, 0, 3 ]

                    f x =
                        T.vecMat w x |> T.tanh

                    xs =
                        T.fromList T.float32 (T.r2 c4 b3) (List.map toFloat (List.range -5 6) |> List.map (\v -> v / 4))

                    looped =
                        T.stack Axis.liftRank1 c4 (List.map f (T.unstack Axis.liftRank1 xs))
                in
                Expect.equal (Eval.floats (Transform.vmap Axis.liftRank1 Axis.liftRank1 f xs)) (Eval.floats looped)
        , test "uniform draws: mean and variance of 10⁴" <|
            \_ ->
                stats (Eval.floats (Random.uniform { low = 0, high = 1 } T.float32 (T.r1 (T.dim A 10000)) (Random.seed (T.int 1))))
                    |> Expect.all
                        [ \( m, _ ) -> Expect.within (Expect.Absolute (3 * sqrt (1 / 12 / 10000))) 0.5 m
                        , \( _, v ) -> Expect.within (Expect.Absolute 0.005) (1 / 12) v
                        ]
        , test "normal draws: mean and variance of 10⁴" <|
            \_ ->
                stats (Eval.floats (Random.normal { mean = 2, std = 3 } T.float32 (T.r1 (T.dim A 10000)) (Random.seed (T.int 2))))
                    |> Expect.all
                        [ \( m, _ ) -> Expect.within (Expect.Absolute (3 * 3 / 100)) 2 m
                        , \( _, v ) -> Expect.within (Expect.Absolute (3 * 9 * sqrt (2 / 10000))) 9 v
                        ]
        , test "training a 4 → 8 → 3 MLP in Elm lowers the loss" <|
            \_ ->
                case trainMlp of
                    Ok losses ->
                        let
                            mean5 l =
                                List.sum l / 5
                        in
                        Expect.lessThan (mean5 (List.take 5 losses) / 2) (mean5 (List.drop 45 losses))

                    Err e ->
                        Expect.fail (String.join "; " e)
        , test "categorical draws pick the dominant logit" <|
            \_ ->
                Eval.ints (Random.categorical (T.fromList T.float32 (T.r2 a2 b3) [ 0, 50, 0, 50, 0, 0 ]) (Random.seed (T.int 4)))
                    |> Expect.equal (Ok [ 1, 0 ])
        ]


stats : Result (List String) (List Float) -> ( Float, Float )
stats r =
    let
        l =
            Result.withDefault [] r

        n =
            toFloat (Basics.max 1 (List.length l))

        m =
            List.sum l / n
    in
    ( m, List.sum (List.map (\v -> (v - m) ^ 2) l) / n )



-- THE MLP


feat : Dim Feat
feat =
    T.dim Feat 4


hidden : Dim Hidden
hidden =
    T.dim Hidden 8


classes : Dim Classes
classes =
    T.dim Classes 3


pts : Dim Pts
pts =
    T.dim Pts 12


mlpParams : Param.Spec { l1 : Linear T.F32 Feat Hidden, l2 : Linear T.F32 Hidden Classes }
mlpParams =
    Param.record (\l1 l2 -> { l1 = l1, l2 = l2 })
        |> Param.sub .l1 (Linear.params T.float32 feat hidden)
        |> Param.sub .l2 (Linear.params T.float32 hidden classes)


mlpStep : Result (List String) Graph.Graph
mlpStep =
    Train.step mlpParams
        (Optim.sgd 0.5)
        (Sig.pair (Sig.label "x" (Sig.f32 (T.r2 pts feat))) (Sig.label "y" (Sig.i64 (T.r1 pts))))
        (\p ( x, y ) -> x |> Linear.apply p.l1 |> T.tanh |> Linear.apply p.l2 |> Nn.crossEntropyIndices y)


{-| 12 fixed points in 3 classes: the class is which of three directions the point leans to.
-}
points : ( List Float, List Int )
points =
    let
        one i =
            let
                c =
                    modBy 3 i

                s =
                    toFloat (i // 3) / 4
            in
            ( List.indexedMap
                (\j _ ->
                    if j == c then
                        1 + s

                    else
                        s - 0.5
                )
                [ (), (), (), () ]
            , c
            )

        all =
            List.map one (List.range 0 11)
    in
    ( List.concatMap Tuple.first all, List.map Tuple.second all )


trainMlp : Result (List String) (List Float)
trainMlp =
    Result.map2 Tuple.pair (Param.initInPlace "init" mlpParams) mlpStep
        |> Result.andThen
            (\( init, step ) ->
                Eval.run init (Dict.singleton "seed" { dtype = "ui64", shape = [ 1 ], data = Ints [ 42 ] })
                    |> Result.andThen
                        (\params ->
                            let
                                fedNames =
                                    Graph.inputs step |> List.filter (\s -> s.role == Graph.Fed) |> List.map .name

                                batch =
                                    Dict.fromList
                                        (List.map2 Tuple.pair
                                            fedNames
                                            [ { dtype = "f32", shape = [ 12, 4 ], data = Floats (Tuple.first points) }
                                            , { dtype = "si64", shape = [ 12 ], data = Ints (Tuple.second points) }
                                            ]
                                        )

                                lossName =
                                    Graph.outputs step |> List.filter (\s -> s.role == Graph.Fed) |> List.map .name |> List.head |> Maybe.withDefault "?"
                            in
                            List.foldl
                                (\_ acc ->
                                    acc
                                        |> Result.andThen
                                            (\( residents, losses ) ->
                                                Eval.run step (Dict.union batch residents)
                                                    |> Result.map
                                                        (\outs ->
                                                            ( Dict.union outs residents
                                                            , case Dict.get lossName outs of
                                                                Just { data } ->
                                                                    case data of
                                                                        Floats [ l ] ->
                                                                            losses ++ [ l ]

                                                                        _ ->
                                                                            losses

                                                                Nothing ->
                                                                    losses
                                                            )
                                                        )
                                            )
                                )
                                (Ok ( Dict.union params (Eval.residentZeros step), [] ))
                                (List.range 1 50)
                                |> Result.map Tuple.second
                        )
            )
