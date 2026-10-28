module Compiler.AST.CanonicalCodecTest exposing (suite)

{-| Reproduces the bug reported against src/Compiler/AST/Canonical.elm ~1143 /
~1346 (recomment-bugs.txt): `exprEncoder` writes the field keys of `Update`
(tag 23) and `Record` (tag 24) as bare names (`A.toValue >> BE.string`), but
`exprDecoder` reads them as located names (`A.locatedDecoder BD.string`,
region first). So a `FieldUpdate` whose value is a record literal, encoded with
the public `Can.fieldUpdateEncoder` (used by the type-error codec in
Compiler.Reporting.Error.Type for RecordUpdateKeys), does not round-trip.

EXPECTED TO FAIL until the bug is fixed.

-}

import Bytes.Decode
import Bytes.Encode
import Compiler.AST.Canonical as Can
import Compiler.Reporting.Annotation as A
import Data.Map
import Expect
import Test exposing (Test)


intE : Int -> Can.Expr
intE n =
    A.At A.zero { id = n, node = Can.Int n }


recordLiteral : Can.Expr
recordLiteral =
    A.At A.zero
        { id = 10
        , node =
            Can.Record
                (Data.Map.fromList A.toValue
                    [ ( A.At A.zero "x", intE 1 ), ( A.At A.zero "y", intE 2 ) ]
                )
        }


roundTrip : Can.FieldUpdate -> Maybe Can.FieldUpdate
roundTrip fu =
    Bytes.Decode.decode Can.fieldUpdateDecoder
        (Bytes.Encode.encode (Can.fieldUpdateEncoder fu))


suite : Test
suite =
    Test.describe "Regression: Canonical Record/Update field-key codec"
        [ Test.test "FieldUpdate holding a record literal round-trips" <|
            \_ ->
                let
                    fu =
                        Can.FieldUpdate A.zero recordLiteral
                in
                roundTrip fu |> Expect.equal (Just fu)
        ]
