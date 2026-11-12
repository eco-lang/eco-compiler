module ValuesTests exposing (suite)

{-| Element values typed by kind (plans/tensor-eval-in-elm.md, V0): constants' values, their keys,
their MLIR text and the range refusal. Values stay within 2⁵³, so these hold under Node too; the
64-bit cases are the E2E suite `test/eco-tensor`.
-}

import Expect
import Graph
import Signature as Sig
import Tensor as T exposing (Dim)
import Tensor.Axis as Axis
import Tensor.Internal.Expr as E
import Tensor.Internal.Key as K
import Tensor.Internal.Mo as Mo
import Tensor.Internal.Prim exposing (DT(..))
import Tensor.Internal.Types as I
import Tensor.Internal.Values as Values exposing (Values(..))
import Test exposing (Test, describe, test)


type N
    = N


two : Dim N
two =
    T.dim N 2


suite : Test
suite =
    describe "element values"
        [ describe "Values"
            [ test "forDtype: integer dtypes round to Ints" <|
                \_ -> Values.forDtype SI64 [ 3, -2 ] |> Expect.equal (IntValues [ 3, -2 ])
            , test "forDtype: floating dtypes keep Floats" <|
                \_ -> Values.forDtype F32 [ 3 ] |> Expect.equal (FloatValues [ 3 ])
            , test "forDtype: Bool is integer" <|
                \_ -> Values.forDtype Bool [ 1, 0 ] |> Expect.equal (IntValues [ 1, 0 ])
            , test "fitsDtype refuses 300 for ui8" <|
                \_ -> Values.fitsDtype UI8 (IntValues [ 300 ]) |> Expect.equal (Just "value 300 does not fit ui8")
            , test "fitsDtype takes -128 for si8" <|
                \_ -> Values.fitsDtype SI8 (IntValues [ -128 ]) |> Expect.equal Nothing
            , test "fitsDtype refuses -1 for ui8 and 2 for bool" <|
                \_ ->
                    ( Values.fitsDtype UI8 (IntValues [ -1 ]), Values.fitsDtype Bool (IntValues [ 2 ]) )
                        |> Expect.equal ( Just "value -1 does not fit ui8", Just "value 2 does not fit bool" )
            , test "u64Text of a non-negative Int" <|
                \_ -> Values.u64Text 5 |> Expect.equal "5"
            , test "limbs are floored: -1 is four 65535s" <|
                \_ -> Values.limbs -1 |> Expect.equal [ 65535, 65535, 65535, 65535 ]
            , test "altHash tells apart values of one length" <|
                \_ -> Values.altHash (IntValues [ 1, 2 ]) |> Expect.notEqual (Values.altHash (IntValues [ 2, 1 ]))
            ]
        , describe "keys"
            [ test "mixInt64s: -1 and 65535 differ" <|
                \_ -> K.mixInt64s [ -1 ] ( 1, 2 ) |> Expect.notEqual (K.mixInt64s [ 65535 ] ( 1, 2 ))
            , test "mixInt64s: 0 and 65536 differ" <|
                \_ -> K.mixInt64s [ 0 ] ( 1, 2 ) |> Expect.notEqual (K.mixInt64s [ 65536 ] ( 1, 2 ))
            , test "an integer constant from Floats and from Ints is one expression" <|
                \_ -> E.key (E.const SI64 [ 2 ] [ 7, -3 ]) |> Expect.equal (E.key (E.constValues SI64 [ 2 ] (IntValues [ 7, -3 ])))
            , test "an int constant's key is the one a float of the same value had (shared subgraphs are named by key)" <|
                \_ -> K.mixInt64s [ 7, -3 ] ( 1, 2 ) |> Expect.equal (K.mixFloats [ 7, -3 ] ( 1, 2 ))
            , test "the shallow text tells two constants of one shape apart" <|
                \_ ->
                    Tuple.first (E.shallow (E.constValues SI64 [ 1 ] (IntValues [ 1 ])))
                        |> Expect.notEqual (Tuple.first (E.shallow (E.constValues SI64 [ 1 ] (IntValues [ 2 ]))))
            ]
        , describe "MLIR text"
            [ test "integers are written exactly" <|
                \_ -> Mo.constText SI64 [ 2 ] (IntValues [ 7, -3 ]) |> Expect.equal "#M.dense_array<7, -3> : tensor<2xsi64>"
            , test "u64: small values as they are" <|
                \_ -> Mo.constText UI64 [ 1 ] (IntValues [ 5 ]) |> Expect.equal "#M.dense_array<5> : tensor<1xui64>"
            , test "bool as true/false" <|
                \_ -> Mo.constText Bool [ 2 ] (IntValues [ 1, 0 ]) |> Expect.equal "#M.dense_array<true, false> : tensor<2xi1>"
            , test "floats as before" <|
                \_ -> Mo.constText F32 [ 2 ] (FloatValues [ 1, 0.5 ]) |> Expect.equal "#M.dense_array<1.0, 0.5> : tensor<2xf32>"
            , test "fromList int64 reaches the graph text exactly" <|
                \_ ->
                    case Graph.function "c" Sig.unit (\_ -> T.fromList T.int64 (T.r1 two) [ 4503599627370497, -9 ]) of
                        Ok g ->
                            Graph.toGenericText g
                                |> String.contains "#M.dense_array<4503599627370497, -9> : tensor<2xsi64>"
                                |> Expect.equal True

                        Err e ->
                            Expect.fail (String.join "; " e)
            ]
        , describe "range refusal"
            [ test "fromList uint8 [ 300 ] is a build error" <|
                \_ ->
                    Graph.function "c" Sig.unit (\_ -> T.fromList T.uint8 (T.r1 (T.dim N 1)) [ 300 ])
                        |> Result.mapError (List.any (String.contains "value 300 does not fit ui8"))
                        |> Expect.equal (Err True)
            , test "constant int8 -129 is a build error" <|
                \_ ->
                    Graph.function "c" Sig.unit (\_ -> T.constant T.int8 -129)
                        |> Result.mapError (List.any (String.contains "value -129 does not fit si8"))
                        |> Expect.equal (Err True)
            , test "padInt with a value outside the dtype is a build error" <|
                \_ ->
                    Graph.function "c"
                        Sig.unit
                        (\_ -> T.fromList T.uint8 (T.r1 two) [ 1, 2 ] |> T.padInt Axis.retag0of1 { before = 1, after = 0, value = 256 } (T.dim N 3))
                        |> Result.mapError (List.any (String.contains "value 256 does not fit ui8"))
                        |> Expect.equal (Err True)
            , test "internal constants are not range-checked" <|
                \_ -> E.problem (E.const UI8 [ 1 ] [ 300 ]) |> Expect.equal Nothing
            , test "DType carries its conversion" <|
                \_ -> I.valuesOf T.int64 [ 1, 2 ] |> Expect.equal (IntValues [ 1, 2 ])
            ]
        ]
