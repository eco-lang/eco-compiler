module FixEVALTests exposing (suite)

{-| Regression tests for the evaluator (`Tensor.Eval` and the modules under
`Tensor.Internal.Eval`) and for `Tensor.Check`.

Most of them are about integers under JavaScript, where an `Int` is a double that holds every
integer only up to 2⁵³. Their expectations are written to pass both there and natively, where an
`Int` has 64 bits: a 64-bit result that a JavaScript `Int` cannot hold exactly must be refused
there, and must be the exact wrapped value natively (`exactOrRefused`).

-}

import Dict
import Expect exposing (Expectation)
import Graph
import Signature as Sig
import Tensor as T
import Tensor.Check as Check
import Tensor.Eval as Eval exposing (Data(..))
import Tensor.Internal.Expr as E exposing (Expr)
import Tensor.Internal.Ops as O
import Tensor.Internal.Prim as P exposing (DT(..), Prim(..))
import Tensor.Internal.Types as I
import Tensor.Internal.Values exposing (Values(..))
import Tensor.Random as Random
import Test exposing (Test, describe, test)


evI : Expr -> Result (List String) (List Int)
evI e =
    Eval.ints (I.Tensor e)


evF : Expr -> Result (List String) (List Float)
evF e =
    Eval.floats (I.Tensor e)


ints : DT -> List Int -> Expr
ints dt l =
    E.constValues dt [ List.length l ] (IntValues l)


f32 : List Int -> List Float -> Expr
f32 shape l =
    E.const F32 shape l


seedInts : Random.Seed -> Result (List String) (List Int)
seedInts (I.Seed e) =
    evI e


{-| Passes when `r` is `Ok [want]`, or an `Err` saying that the result cannot be held exactly under
JavaScript. Only the second is accepted where `want` itself is not an exact `Int`, as under
JavaScript for a `want` past 2⁵³ that a double cannot hold.
-}
exactOrRefused : Int -> Result (List String) (List Int) -> Expectation
exactOrRefused want r =
    case r of
        Ok got ->
            Expect.equal [ want ] got

        Err es ->
            if List.any (String.contains "JavaScript") es && not (heldExactly want) then
                Expect.pass

            else
                Expect.fail (String.join "; " es)


{-| Whether `n` is held exactly: always natively; under JavaScript only when its neighbour n + 1
differs from it, or `n` is small.
-}
heldExactly : Int -> Bool
heldExactly n =
    let
        lim =
            2 ^ 53
    in
    (n < lim && n > -lim) || ((n + 1) - n == 1)


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


{-| 1 / x for each element, which tells −0 (−∞) from +0 (+∞).
-}
signs : Result (List String) (List Float) -> Result (List String) (List Float)
signs =
    Result.map (List.map (\r -> 1 / r))


suite : Test
suite =
    describe "FixEVAL"
        [ describe "B023 si32 products wrap exactly"
            [ test "123456789 * 987654321" <|
                \_ -> evI (O.mul (ints SI32 [ 123456789 ]) (ints SI32 [ 987654321 ])) |> Expect.equal (Ok [ -67153019 ])
            , test "2147483647 squared" <|
                \_ -> evI (O.mul (ints SI32 [ 2147483647 ]) (ints SI32 [ 2147483647 ])) |> Expect.equal (Ok [ 1 ])
            , test "883301182 * 20394401" <|
                \_ -> evI (O.mul (ints SI32 [ 883301182 ]) (ints SI32 [ 20394401 ])) |> Expect.equal (Ok [ -2 ])
            , test "-2147483648 * -2147483648" <|
                \_ -> evI (O.mul (ints SI32 [ -2147483648 ]) (ints SI32 [ -2147483648 ])) |> Expect.equal (Ok [ 0 ])
            , test "si32 matmul dot product" <|
                \_ ->
                    evI (O.matmul (E.constValues SI32 [ 1, 2 ] (IntValues [ 2147483647, 123456789 ])) (E.constValues SI32 [ 2, 1 ] (IntValues [ 2147483647, 987654321 ])))
                        |> Expect.equal (Ok [ -67153018 ])
            , test "si8 product still wraps" <|
                \_ -> evI (O.mul (ints SI8 [ 100 ]) (ints SI8 [ 3 ])) |> Expect.equal (Ok [ 44 ])
            ]
        , describe "B025 si64 and ui64 results"
            [ test "si64 mean of [3e9, 3e9]" <|
                \_ -> evI (O.reduce ReduceMean 0 (ints SI64 [ 3000000000, 3000000000 ])) |> Expect.equal (Ok [ 3000000000 ])
            , test "si64 mean of [-3e9, -3e9, 1] truncates toward zero" <|
                \_ -> evI (O.reduce ReduceMean 0 (ints SI64 [ -3000000000, -3000000000, 1 ])) |> Expect.equal (Ok [ -1999999999 ])
            , test "si64 2^62 + 2^62 wraps to -2^63" <|
                \_ -> evI (O.add (ints SI64 [ 2 ^ 62 ]) (ints SI64 [ 2 ^ 62 ])) |> Expect.equal (Ok [ -(2 ^ 62) * 2 ])
            , test "si64 (2^40 + 1)^2 wraps to 2^41 + 1" <|
                \_ -> evI (O.mul (ints SI64 [ 2 ^ 40 + 1 ]) (ints SI64 [ 2 ^ 40 + 1 ])) |> Expect.equal (Ok [ 2 ^ 41 + 1 ])
            , test "ui64 -2^62 * 4 wraps to 0" <|
                \_ -> evI (O.mul (ints UI64 [ -(2 ^ 62) ]) (ints UI64 [ 4 ])) |> Expect.equal (Ok [ 0 ])
            , test "si64 3^20 * 3^20: exact or refused" <|
                \_ -> evI (O.mul (ints SI64 [ 3 ^ 20 ]) (ints SI64 [ 3 ^ 20 ])) |> exactOrRefused -6289078614652622815
            , test "si64 2^53 + 1: exact or refused" <|
                \_ -> evI (O.add (ints SI64 [ 2 ^ 53 ]) (ints SI64 [ 1 ])) |> exactOrRefused (2 ^ 53 + 1)
            , test "si64 sum wraps" <|
                \_ -> evI (O.reduce ReduceSum 0 (ints SI64 [ 2 ^ 62, 2 ^ 62, 2 ^ 62, 2 ^ 62 ])) |> Expect.equal (Ok [ 0 ])
            , test "si64 cumsum wraps" <|
                \_ -> evI (O.cumsum 0 False False (ints SI64 [ 2 ^ 62, 2 ^ 62, 2 ^ 62 ])) |> Expect.equal (Ok [ 2 ^ 62, -(2 ^ 62) * 2, -(2 ^ 62) ])
            , test "si64 matmul wraps" <|
                \_ ->
                    evI (O.matmul (E.constValues SI64 [ 1, 2 ] (IntValues [ 2 ^ 40 + 1, 2 ^ 31 ])) (E.constValues SI64 [ 2, 1 ] (IntValues [ 2 ^ 40 + 1, 2 ^ 33 ])))
                        |> Expect.equal (Ok [ 2 ^ 41 + 1 ])
            , test "si64 negate of -2^63 wraps to -2^63" <|
                \_ -> evI (O.unary Neg (ints SI64 [ -(2 ^ 62) * 2 ])) |> Expect.equal (Ok [ -(2 ^ 62) * 2 ])
            ]
        , describe "B021 salted seeds"
            [ test "salt 0 and salt 1 of (salt 0 (seed 42)) differ, or are refused" <|
                \_ ->
                    let
                        s =
                            Random.salt 0 (Random.seed (T.int 42))
                    in
                    distinctOrRefused (seedInts (Random.salt 0 s)) (seedInts (Random.salt 1 s))
            , test "salt 0 and salt 1 of seed 2e6 differ, or are refused" <|
                \_ ->
                    let
                        s =
                            Random.seed (T.int 2000000)
                    in
                    distinctOrRefused (seedInts (Random.salt 0 s)) (seedInts (Random.salt 1 s))
            , test "salt 1 of seed 3 is exact" <|
                \_ -> seedInts (Random.salt 1 (Random.seed (T.int 3))) |> Expect.equal (Ok [ 3 * 25214903917 + 3 ])
            ]
        , describe "B017 stride 0"
            [ test "convTranspose with stride 0 is refused" <|
                \_ ->
                    evF (O.convTranspose [ 0, 0, 0, 0, 0, 0 ] (f32 [ 1, 2, 2, 1 ] [ 1, 2, 3, 4 ]) (f32 [ 2, 2, 1, 1 ] [ 1, 1, 1, 1 ]))
                        |> failsWith "stride"
            , test "conv with stride 0 is refused" <|
                \_ ->
                    evF (O.conv [ 0, 1, 0, 0, 0, 0 ] (f32 [ 1, 2, 2, 1 ] [ 1, 2, 3, 4 ]) (f32 [ 1, 1, 1, 1 ] [ 1 ]))
                        |> failsWith "stride"
            ]
        , describe "B044 ui64 remainder"
            [ test "(2^64 - 2) mod 10 is 4" <|
                \_ -> evI (O.binary Mod (ints UI64 [ -2 ]) (ints UI64 [ 10 ])) |> Expect.equal (Ok [ 4 ])
            , test "(2^64 - 1) mod (2^32 + 1) is 0" <|
                \_ -> evI (O.binary Mod (ints UI64 [ -1 ]) (ints UI64 [ 2 ^ 32 + 1 ])) |> Expect.equal (Ok [ 0 ])
            , test "2^63 mod 3 is 2" <|
                \_ -> evI (O.binary Mod (ints UI64 [ -(2 ^ 62) * 2 ]) (ints UI64 [ 3 ])) |> Expect.equal (Ok [ 2 ])
            , test "(2^64 - 1) mod (2^64 - 2) is 1" <|
                \_ -> evI (O.binary Mod (ints UI64 [ -1 ]) (ints UI64 [ -2 ])) |> Expect.equal (Ok [ 1 ])
            , test "5 mod (2^64 - 1) is 5" <|
                \_ -> evI (O.binary Mod (ints UI64 [ 5 ]) (ints UI64 [ -1 ])) |> Expect.equal (Ok [ 5 ])
            , test "(2^64 - 2^40) mod 1000003" <|
                \_ -> evI (O.binary Mod (ints UI64 [ -(2 ^ 40) ]) (ints UI64 [ 1000003 ])) |> Expect.equal (Ok [ modBy 1000003 (2 ^ 24 * modBy 1000003 (2 ^ 40) - modBy 1000003 (2 ^ 40)) ])
            ]
        , describe "B041 rounding keeps the sign of zero"
            [ test "floor -0 is -0" <|
                \_ -> evF (E.prim Floor [ f32 [ 1 ] [ -0.0 ] ] P.noParams) |> signs |> Expect.equal (Ok [ -1 / 0 ])
            , test "trunc -0.5 is -0" <|
                \_ -> evF (E.prim Trunc [ f32 [ 1 ] [ -0.5 ] ] P.noParams) |> signs |> Expect.equal (Ok [ -1 / 0 ])
            , test "round -0.4 is -0" <|
                \_ -> evF (E.prim Round [ f32 [ 1 ] [ -0.4 ] ] P.noParams) |> signs |> Expect.equal (Ok [ -1 / 0 ])
            , test "round -0.5 is -0" <|
                \_ -> evF (E.prim Round [ f32 [ 1 ] [ -0.5 ] ] P.noParams) |> signs |> Expect.equal (Ok [ -1 / 0 ])
            , test "floor, trunc and round of 0.3 are +0" <|
                \_ -> List.map (\p -> evF (E.prim p [ f32 [ 1 ] [ 0.3 ] ] P.noParams) |> signs) [ Floor, Trunc, Round ] |> Expect.equal (List.repeat 3 (Ok [ 1 / 0 ]))
            , test "floor -0.5 is -1" <|
                \_ -> evF (E.prim Floor [ f32 [ 1 ] [ -0.5 ] ] P.noParams) |> Expect.equal (Ok [ -1 ])
            ]
        , describe "B049 allClose with an infinite expected value"
            [ test "-inf is not close to +inf" <|
                \_ -> Check.allClose { rtol = 1.0e-5, atol = 0 } [ -1 / 0 ] [ 1 / 0 ] |> Expect.err
            , test "a finite value is not close to +inf" <|
                \_ -> Check.allClose { rtol = 1.0e-5, atol = 1 } [ 1.0e308 ] [ 1 / 0 ] |> Expect.err
            , test "+inf is close to +inf" <|
                \_ -> Check.allClose { rtol = 0, atol = 0 } [ 1 / 0, -1 / 0 ] [ 1 / 0, -1 / 0 ] |> Expect.equal (Ok ())
            , test "a negative tolerance is refused" <|
                \_ -> Check.allClose { rtol = -1, atol = 0 } [ 1 ] [ 1 ] |> Expect.err
            ]
        , describe "B070 integer means"
            [ test "ui64 mean of [2^63, 2^62] is unsigned" <|
                \_ -> evI (O.reduce ReduceMean 0 (ints UI64 [ -(2 ^ 62) * 2, 2 ^ 62 ])) |> Expect.equal (Ok [ 2 ^ 62 + 2 ^ 61 ])
            , test "ui64 mean of [2^64 - 2, 0]: exact or refused" <|
                \_ -> evI (O.reduce ReduceMean 0 (ints UI64 [ -2, 0 ])) |> exactOrRefused (2 ^ 62 - 1 + 2 ^ 62)
            , test "si8 mean of [100, 100] is 100" <|
                \_ -> evI (O.reduce ReduceMean 0 (ints SI8 [ 100, 100 ])) |> Expect.equal (Ok [ 100 ])
            ]
        , describe "B093 negative maxIterations"
            [ test "runWith refuses a negative maxIterations" <|
                \_ ->
                    case Graph.function "twice" (Sig.label "x" (Sig.f32 T.scalar)) (\x -> T.plus x x) of
                        Ok g ->
                            Eval.runWith { maxIterations = -1 } g (Dict.singleton "x" { dtype = "f32", shape = [], data = Floats [ 1 ] })
                                |> failsWith "maxIterations"

                        Err e ->
                            Expect.fail (String.join "; " e)
            , test "runPreparedWith refuses a negative maxIterations" <|
                \_ ->
                    case Graph.function "twice" (Sig.label "x" (Sig.f32 T.scalar)) (\x -> T.plus x x) of
                        Ok g ->
                            Eval.runPreparedWith { maxIterations = -1 } (Eval.prepare g) (Dict.singleton "x" { dtype = "f32", shape = [], data = Floats [ 1 ] })
                                |> failsWith "maxIterations"

                        Err e ->
                            Expect.fail (String.join "; " e)
            , test "maxIterations 0 runs a graph without loops" <|
                \_ ->
                    case Graph.function "twice" (Sig.label "x" (Sig.f32 T.scalar)) (\x -> T.plus x x) of
                        Ok g ->
                            Eval.runWith { maxIterations = 0 } g (Dict.singleton "x" { dtype = "f32", shape = [], data = Floats [ 1 ] })
                                |> Result.map Dict.values
                                |> Expect.equal (Ok [ { dtype = "f32", shape = [], data = Floats [ 2 ] } ])

                        Err e ->
                            Expect.fail (String.join "; " e)
            , test "a run error carries the graph name, a missing input too" <|
                \_ ->
                    case Graph.function "twice" (Sig.label "x" (Sig.f32 T.scalar)) (\x -> T.plus x x) of
                        Ok g ->
                            Eval.run g Dict.empty |> Expect.equal (Err [ "twice: missing input x" ])

                        Err e ->
                            Expect.fail (String.join "; " e)
            ]
        , describe "B057 messages"
            [ test "one element differs" <|
                \_ -> Check.allClose { rtol = 1.0e-3, atol = 0 } [ 1, 2.1 ] [ 1, 2 ] |> Expect.equal (Err "1 element differs; first at 1: 2.1 vs 2")
            , test "two elements differ" <|
                \_ -> Check.allClose { rtol = 1.0e-3, atol = 0 } [ 1.1, 2.1 ] [ 1, 2 ] |> Expect.equal (Err "2 elements differ; first at 0: 1.1 vs 1")
            , test "a run-time error from ints starts with eval:" <|
                \_ -> Eval.ints (T.fromList T.int64 (T.r1 (T.dim () 1)) [ 1 ] |> T.modBy (T.fromList T.int64 (T.r1 (T.dim () 1)) [ 0 ])) |> Expect.equal (Err [ "eval: modBy: integer division by zero" ])
            ]
        ]


{-| Passes when `a` and `b` are both `Ok` and differ, or when either is refused as not exact under
JavaScript.
-}
distinctOrRefused : Result (List String) (List Int) -> Result (List String) (List Int) -> Expectation
distinctOrRefused a b =
    case ( a, b ) of
        ( Ok x, Ok y ) ->
            Expect.notEqual x y

        _ ->
            if List.any (String.contains "JavaScript") (errs a ++ errs b) then
                Expect.pass

            else
                Expect.fail (Debug.toString ( a, b ))


errs : Result (List String) a -> List String
errs r =
    case r of
        Err es ->
            es

        Ok _ ->
            []
