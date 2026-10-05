module TestLogic.Generate.Bytecode.DenseArrayEncodingTest exposing (suite)

{-| Checks that the bytecode attribute section writes each element of a dense
array (`ArrayAttr (Just t) …`, an MLIR `DenseArrayAttr`) in the width of its
element type: one byte for `i8`, eight for `i64`.

Each test collects one op carrying the array into a fresh table, encodes the
attribute data section, and looks for the array's whole entry in it: the
`DenseArrayAttr` code (17), the element type's index, the element count, the
blob length and the blob bytes, all as `Mlir.Bytecode.AttrType` writes them.

What the tests establish:

  - an `i8` array `[0,1,2,3]` is written as count 4, blob length 4, blob
    `00 01 02 03` (the `slot_kinds` form, wide-object Phase 2 step 2.0);
  - an `i64` array `[5]` is still written as count 1, blob length 8, blob
    `05 00 00 00 00 00 00 00` (byte-identical to the encoder before the fix).

-}

import Bytes exposing (Bytes)
import Bytes.Decode as BD
import Bytes.Encode as BE
import Dict
import Expect
import Mlir.Bytecode.AttrType as AttrType
import Mlir.Bytecode.DialectSection as DialectSection
import Mlir.Bytecode.StringTable as StringTable
import Mlir.Bytecode.VarInt exposing (encodeVarInt)
import Mlir.Loc
import Mlir.Mlir exposing (MlirAttr(..), MlirOp, MlirType(..))
import Test exposing (Test)


suite : Test
suite =
    Test.describe "Bytecode dense array element widths"
        [ Test.test "dense i8 array encodes one byte per element" <|
            \_ -> expectEntry I8 [ 0, 1, 2, 3 ] [ 0, 1, 2, 3 ]
        , Test.test "dense i64 array still encodes eight bytes per element" <|
            \_ -> expectEntry I64 [ 5 ] [ 5, 0, 0, 0, 0, 0, 0, 0 ]
        ]


{-| An op whose only attribute is `kinds`, the dense array of `ty` holding `vals`.
-}
denseOp : MlirType -> List Int -> MlirOp
denseOp ty vals =
    { name = "eco.probe"
    , id = "op_0"
    , operands = []
    , results = []
    , attrs = Dict.singleton "kinds" (ArrayAttr (Just ty) (List.map (IntAttr Nothing) vals))
    , regions = []
    , isTerminator = False
    , loc = Mlir.Loc.unknown
    , successors = []
    }


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


{-| Collects `denseOp ty vals`, encodes the data section, and expects it to
contain the entry `17, typeIndex ty, count, blob length, blob`.
-}
expectEntry : MlirType -> List Int -> List Int -> Expect.Expectation
expectEntry ty vals blob =
    let
        tbl =
            [ denseOp ty vals ]
                |> List.foldl AttrType.streamCollectOp AttrType.initStreamAccum
                |> AttrType.finalizeStreamAccum

        ( dataEnc, _ ) =
            AttrType.encodeDataAndOffsets StringTable.empty (DialectSection.registryFromOpMap Dict.empty) tbl

        data =
            toList (BE.encode dataEnc)

        tyIdx =
            AttrType.typeIndex ty tbl

        expected =
            toList
                (BE.encode
                    (BE.sequence
                        ([ encodeVarInt 17
                         , encodeVarInt tyIdx
                         , encodeVarInt (List.length vals)
                         , encodeVarInt (List.length blob)
                         ]
                            ++ List.map BE.unsignedInt8 blob
                        )
                    )
                )
    in
    Expect.all
        [ \_ -> Expect.notEqual -1 tyIdx
        , \_ ->
            isInfixOf expected data
                |> Expect.equal True
                |> Expect.onFail ("entry " ++ Debug.toString expected ++ " not found in data section " ++ Debug.toString data)
        ]
        ()
