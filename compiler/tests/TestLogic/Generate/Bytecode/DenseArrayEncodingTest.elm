module TestLogic.Generate.Bytecode.DenseArrayEncodingTest exposing (suite)

{-| Without these tests, a dense array could be written with the wrong
element width and the data section would still encode without error; the
mismatch would only show when the back end read the bytecode.

A dense array here is an `ArrayAttr (Just t) …`, written as MLIR's
`DenseArrayAttr`: code 17, the index of the element type `t`, the element
count, the length of the blob, and the blob, which holds each element in the
width of `t`. `Mlir.Bytecode.AttrType` owns that layout.

The fixture is one op, `eco.probe`, whose only attribute is the dense array.
Each test collects that op into a fresh table, encodes the attribute data
section, and looks for the array's whole entry anywhere in it, after checking
that the element type was given an index.

What the tests establish:

  - an `i8` array of 0, 1, 2, 3 is written with count 4, blob length 4 and blob
    `00 01 02 03`, one byte per element;
  - an `i64` array of 5 is written with count 1, blob length 8 and blob
    `05 00 00 00 00 00 00 00`, eight little-endian bytes.

Among what is not tested: `i1`, `i16` and `i32` arrays, negative values or
values too wide for the element type, an empty array, and the offset section.

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


{-| The two element-width tests, one for `i8` and one for `i64`.
-}
suite : Test
suite =
    Test.describe "Bytecode dense array element widths"
        [ Test.test "dense i8 array encodes one byte per element" <|
            \_ -> expectEntry I8 [ 0, 1, 2, 3 ] [ 0, 1, 2, 3 ]
        , Test.test "dense i64 array still encodes eight bytes per element" <|
            \_ -> expectEntry I64 [ 5 ] [ 5, 0, 0, 0, 0, 0, 0, 0 ]
        ]


{-| Builds an op whose only attribute is `kinds`, the dense array of `ty`
holding `vals`.
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


{-| Returns the bytes of `bytes` as a list of integers from 0 to 255, in
order.
-}
toList : Bytes -> List Int
toList bytes =
    BD.decode (BD.loop ( Bytes.width bytes, [] ) step) bytes
        |> Maybe.withDefault []


{-| Returns the decoder for one step of `toList`'s loop: with `n` bytes left
to read it reads one more, and at zero it finishes with the bytes read so far.
-}
step : ( Int, List Int ) -> BD.Decoder (BD.Step ( Int, List Int ) (List Int))
step ( n, acc ) =
    if n <= 0 then
        BD.succeed (BD.Done (List.reverse acc))

    else
        BD.map (\b -> BD.Loop ( n - 1, b :: acc )) BD.unsignedInt8


{-| Returns whether `needle` occurs as a contiguous run anywhere in `hay`. An
empty `needle` always occurs.
-}
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


{-| Expects that the data section encoded for `denseOp ty vals` gives `ty` an
index and contains the entry 17, that index, the count of `vals`, the length of
`blob`, then `blob` itself.
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
