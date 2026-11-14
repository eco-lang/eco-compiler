module ValuesTests exposing (suite)

{-| Integer constants are held as `Int`s rather than `Float`s, so that a 64-bit element is not
rounded (`Tensor.Internal.Values` states the rule). The tests are in four groups: values, keys
(the structural hash that stands for an expression's identity, `Tensor.Internal.Key`), MLIR text,
and range refusal. Without them, a change could hold a constant as the wrong kind of values, key
an `si64` constant made from floats differently from one made from the same `Int`s, write a
constant's text wrongly or let an out-of-range integer constant build, and no error would show it.

`N` is an axis tag and `two` a size of 2 along it. Graphs are built with `Graph.function` from
`Signature.unit`, so they have no inputs. Every integer used but one lies within ±2⁵³ (the largest
is 2⁵² + 1), so each is exact as a JavaScript `Int`; the other, −2⁶³ given to `Values.u64Text`, is
a power of two and so exact as well.

`Expr`, `Key`, `Mo`, `Types` and `Values` below are the modules of those names under
`Tensor.Internal`.

What the tests establish, group by group:

  - **Values.** `Values.forDtype` gives `IntValues` for `si64`, rounding `[3, -2, 2.4, -1.6, 0.6]`
    to `[3, -2, 2, -2, 1]`, and for `bool` (`[1, 0]`), and `FloatValues` for `f32`.
    `Values.fitsDtype` refuses 300 and −1 for `ui8` and 2 for `bool`, with messages such as
    `"value 300 does not fit ui8"`, and accepts −128 for `si8`. `Values.u64Text` gives `"5"` for
    5, `"18446744073709551615"` for −1 and `"9223372036854775808"` for −2⁶³. `Values.limbs -1` is
    four 65535s. `Values.altHash` differs for `[1, 2]` and `[2, 1]`.
  - **Keys.** `Key.mixInt64s` gives different keys for `[-1]` and `[65535]`, and for `[0]` and
    `[65536]`, and mixes `[7, -3]` exactly as `Key.mixFloats` mixes the same numbers as floats.
    `Expr.shallow` describes an expression without its key, as a string paired with its operands'
    keys, so that a key collision can be noticed. An `si64` constant made by `Expr.const` from
    floats has the same key and the same `Expr.shallow` description as one made by
    `Expr.constValues` from the same `Int`s; the string differs for two one-element `si64`
    constants holding 1 and 2.
  - **MLIR text.** `Mo.constText` writes `si64` values `[7, -3]`, a `ui64` 5, `bool` values as
    `true`/`false` with element type `i1`, and `f32` values `[1, 0.5]` as `1.0, 0.5`, each
    compared with the whole expected `#M.dense_array<…> : tensor<…>` string. The MLIR generic op
    text `Max.toGenericText` writes for a graph returning `Tensor.fromList` of `int64` values
    `[2⁵² + 1, -9]` contains those two integers in decimal.
  - **Range refusal.** Building a graph fails, with the range message among its errors, for
    `Tensor.fromList uint8` holding 300, `Tensor.constant int8 -129`, and `Tensor.padInt` with a
    fill of 256 on a `uint8` tensor. A `ui8` constant of 300 made by `Expr.const` records no build
    error. `Types.valuesOf int64` turns `[1, 2]` into `IntValues [1, 2]`.

Among what is not tested: `Key.mixInt64s` of integers beyond ±2⁵³, which it mixes as a marker and
four 16-bit pieces rather than as floats; `ui64` elements of 2⁶³ or more, which are negative `Int`s,
in `Mo.constText`; `Values.forDtype` given NaN, an infinity, an out-of-range float or a value
halfway between two integers; the `si32` range and the upper end of the `si8` range; that the
`int64` constant made by `Tensor.fromList` does not pass through `Float` on its way to the text,
since every value here is exact as a `Float`; that constants of an integer dtype and of a float
dtype holding equal values have different keys; and float text for NaN, an infinity or `-0.0`.

-}

import Expect
import Graph
import Max
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


{-| The axis tag of the rank-1 tensors the tests build.
-}
type N
    = N


{-| A size of 2 along the axis `N`.
-}
two : Dim N
two =
    T.dim N 2


{-| The tests of element values, in the four groups the module docstring lists.
-}
suite : Test
suite =
    describe "element values"
        [ describe "Values"
            [ test "forDtype: integer dtypes round to Ints" <|
                \_ -> Values.forDtype SI64 [ 3, -2, 2.4, -1.6, 0.6 ] |> Expect.equal (IntValues [ 3, -2, 2, -2, 1 ])
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
            , test "u64Text of a negative Int adds 2^64" <|
                \_ ->
                    ( Values.u64Text -1, Values.u64Text (-9223372036854775807 - 1) )
                        |> Expect.equal ( "18446744073709551615", "9223372036854775808" )
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
            , test "an integer constant from Floats and from Ints has one key and one shallow description" <|
                \_ ->
                    ( E.key (E.const SI64 [ 2 ] [ 7, -3 ]), E.shallow (E.const SI64 [ 2 ] [ 7, -3 ]) )
                        |> Expect.equal ( E.key (E.constValues SI64 [ 2 ] (IntValues [ 7, -3 ])), E.shallow (E.constValues SI64 [ 2 ] (IntValues [ 7, -3 ])) )
            , test "mixInt64s mixes small Ints as mixFloats mixes the same numbers" <|
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
            , test "f32 as decimal floats" <|
                \_ -> Mo.constText F32 [ 2 ] (FloatValues [ 1, 0.5 ]) |> Expect.equal "#M.dense_array<1.0, 0.5> : tensor<2xf32>"
            , test "fromList int64 reaches the graph text exactly" <|
                \_ ->
                    case Graph.function "c" Sig.unit (\_ -> T.fromList T.int64 (T.r1 two) [ 4503599627370497, -9 ]) of
                        Ok g ->
                            Max.toGenericText g
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
