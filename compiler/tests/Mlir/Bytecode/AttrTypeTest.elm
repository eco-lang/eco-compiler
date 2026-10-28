module Mlir.Bytecode.AttrTypeTest exposing (suite)

{-| Regression tests for `Mlir.Bytecode.AttrType`, for two bugs since fixed:

  - Untyped `ArrayAttr` keys joined their parts with `,` without quoting, so
    `[ "a,s:b" ]` and `[ "a", "b" ]` shared an entry (reached by string case
    patterns: test/elm/src/StringCasePatternCommaTest.elm). Parts are now
    length-prefixed.
  - A dense array element was written as its low 32 bits followed by zero
    bytes, so the `i64` element -1 was written `FF FF FF FF 00 00 00 00`
    instead of eight `FF` bytes, and 2^32 was written as 0. All 64 bits are
    now written.

-}

import Bytes exposing (Bytes)
import Bytes.Decode as BD
import Bytes.Encode as BE
import Dict exposing (Dict)
import Expect
import Mlir.Bytecode.AttrType as AttrType
import Mlir.Bytecode.DialectSection as DialectSection
import Mlir.Bytecode.StringTable as StringTable
import Mlir.Bytecode.VarInt exposing (encodeVarInt)
import Mlir.Loc exposing (Loc)
import Mlir.Mlir exposing (MlirAttr(..), MlirOp, MlirType(..))
import Test exposing (Test)


probeOp : Loc -> Dict String MlirAttr -> MlirOp
probeOp loc attrs =
    { name = "eco.probe"
    , id = "op_0"
    , operands = []
    , results = []
    , attrs = attrs
    , regions = []
    , isTerminator = False
    , loc = loc
    , successors = []
    }


collect : List MlirOp -> AttrType.AttrTypeTable
collect ops =
    ops
        |> List.foldl AttrType.streamCollectOp AttrType.initStreamAccum
        |> AttrType.finalizeStreamAccum


dataSection : AttrType.AttrTypeTable -> List Int
dataSection tbl =
    let
        ( dataEnc, _ ) =
            AttrType.encodeDataAndOffsets StringTable.empty (DialectSection.registryFromOpMap Dict.empty) tbl
    in
    toList (BE.encode dataEnc)


toList : Bytes -> List Int
toList bytes =
    BD.decode (BD.loop ( Bytes.width bytes, [] ) step) bytes
        |> Maybe.withDefault []


step : ( Int, List Int ) -> BD.Decoder (BD.Step ( Int, List Int ) (List Int))
step ( n, acc ) =
    if n <= 0 then
        BD.succeed (BD.Done (List.reverse acc))

    else
        BD.map (\b -> BD.Loop ( n - 1, b :: acc )) BD.unsignedInt8


isInfixOf : List Int -> List Int -> Bool
isInfixOf needle hay =
    if List.take (List.length needle) hay == needle then
        True

    else
        case hay of
            [] ->
                False

            _ :: rest ->
                isInfixOf needle rest


{-| Collects one op per dictionary and expects the two dictionaries to get
distinct indices.
-}
expectDistinctDicts : Dict String MlirAttr -> Dict String MlirAttr -> Expect.Expectation
expectDistinctDicts d1 d2 =
    let
        tbl =
            collect [ probeOp Mlir.Loc.unknown d1, probeOp Mlir.Loc.unknown d2 ]

        i1 =
            AttrType.dictAttrIndex d1 tbl

        i2 =
            AttrType.dictAttrIndex d2 tbl
    in
    Expect.all
        [ \_ -> Expect.notEqual -1 i1
        , \_ -> Expect.notEqual -1 i2
        , \_ -> Expect.notEqual i1 i2 |> Expect.onFail ("two different dictionaries share entry " ++ String.fromInt i1)
        ]
        ()


expectDenseEntry : MlirType -> List Int -> List Int -> Expect.Expectation
expectDenseEntry ty vals blob =
    let
        tbl =
            collect [ probeOp Mlir.Loc.unknown (Dict.singleton "kinds" (ArrayAttr (Just ty) (List.map (IntAttr Nothing) vals))) ]

        expected =
            toList
                (BE.encode
                    (BE.sequence
                        ([ encodeVarInt 17
                         , encodeVarInt (AttrType.typeIndex ty tbl)
                         , encodeVarInt (List.length vals)
                         , encodeVarInt (List.length blob)
                         ]
                            ++ List.map BE.unsignedInt8 blob
                        )
                    )
                )

        data =
            dataSection tbl
    in
    isInfixOf expected data
        |> Expect.equal True
        |> Expect.onFail ("entry " ++ Debug.toString expected ++ " not found in data section " ++ Debug.toString data)


suite : Test
suite =
    Test.describe "Mlir.Bytecode.AttrType regressions"
        [ Test.test "untyped array keys do not collide when a string holds ','" <|
            \_ ->
                expectDistinctDicts
                    (Dict.singleton "v" (ArrayAttr Nothing [ StringAttr "a,s:b" ]))
                    (Dict.singleton "v" (ArrayAttr Nothing [ StringAttr "a", StringAttr "b" ]))
        , Test.test "dense i64 element -1 is written as eight 0xFF bytes" <|
            \_ -> expectDenseEntry I64 [ -1 ] [ 255, 255, 255, 255, 255, 255, 255, 255 ]
        , Test.test "dense i64 element 2^32 is written with its high bytes" <|
            \_ -> expectDenseEntry I64 [ 4294967296 ] [ 0, 0, 0, 0, 1, 0, 0, 0 ]
        ]
