module Mlir.OpaqueAndDictTest exposing (suite)

{-| Tests of the attributes and types added for programs of other dialects: `DictAttr`, `OpaqueAttr`,
`IndexType`, `SignedIntegerType`, and `StreamEncode.isolating`.

  - Text: each prints as MLIR spells it, a `DictAttr` in key order with a `UnitAttr` entry as its
    key alone.
  - Bytecode: an `OpaqueAttr` is written as its text, and its dialect is listed in the dialect
    section even when no operation belongs to it.
  - Isolation: naming an operation with `isolating` changes the bytes written for it, and naming
    one that is not used changes nothing.

Whether MLIR reads the bytecode back as the same module is checked outside these tests, with
`mlir-opt`, by the programs that use the package.

-}

import Bytes exposing (Bytes)
import Bytes.Decode as BD
import Dict
import Expect
import Mlir.Bytecode.StreamEncode as StreamEncode
import Mlir.Loc as Loc
import Mlir.Mlir exposing (MlirAttr(..), MlirOp, MlirRegion(..), MlirType(..))
import Mlir.Pretty as Pretty
import OrderedDict
import Test exposing (Test, describe, test)


op : String -> MlirOp
op name =
    { name = name
    , id = ""
    , operands = []
    , results = []
    , attrs = Dict.empty
    , regions = []
    , isTerminator = False
    , loc = Loc.unknown
    , successors = []
    }


{-| An op `name` with the given attributes and one region holding a single op that reads the
region's argument.
-}
withRegion : String -> List ( String, MlirAttr ) -> MlirOp
withRegion name attrs =
    let
        base =
            op name

        ret =
            op "test.ret"

        terminator =
            { ret | operands = [ "%a" ], isTerminator = True }
    in
    { base
        | attrs = Dict.fromList attrs
        , regions =
            [ MlirRegion
                { entry = { args = [ ( "%a", IndexType ) ], body = [], terminator = terminator }
                , blocks = OrderedDict.empty
                }
            ]
    }


bytecode : List String -> List MlirOp -> Bytes
bytecode isolated ops =
    StreamEncode.assembleModule
        (StreamEncode.emptyStreamTables
            |> StreamEncode.isolating isolated
            |> StreamEncode.collectAndEncodeOps ops
        )
        Loc.unknown


{-| The bytes as a list, to compare: `==` on two `Bytes` does not compare their contents.
-}
bytecodeList : List String -> List MlirOp -> List Int
bytecodeList isolated ops =
    let
        b =
            bytecode isolated ops
    in
    BD.decode
        (BD.loop ( Bytes.width b, [] )
            (\( n, acc ) ->
                if n <= 0 then
                    BD.succeed (BD.Done (List.reverse acc))

                else
                    BD.map (\x -> BD.Loop ( n - 1, x :: acc )) BD.unsignedInt8
            )
        )
        b
        |> Maybe.withDefault []


{-| The bytes, as text where they are printable ASCII and `.` elsewhere, to look for strings in.
-}
asText : Bytes -> String
asText b =
    BD.decode
        (BD.loop ( Bytes.width b, [] )
            (\( n, acc ) ->
                if n <= 0 then
                    BD.succeed (BD.Done (String.fromList (List.reverse acc)))

                else
                    BD.map
                        (\x ->
                            BD.Loop
                                ( n - 1
                                , if x >= 32 && x < 127 then
                                    Char.fromCode x :: acc

                                  else
                                    '.' :: acc
                                )
                        )
                        BD.unsignedInt8
            )
        )
        b
        |> Maybe.withDefault ""


suite : Test
suite =
    describe "DictAttr, OpaqueAttr, IndexType, SignedIntegerType and isolating"
        [ test "the new types and attributes print as MLIR spells them" <|
            \_ ->
                Pretty.ppTopLevelOp
                    (withRegion "test.op"
                        [ ( "d", DictAttr (Dict.fromList [ ( "z", UnitAttr ), ( "a", IntAttr (Just (SignedIntegerType 64)) -7 ) ]) )
                        , ( "o", OpaqueAttr "#mosh<ape[2]> : !mosh.ape" )
                        ]
                    )
                    |> String.contains "{d = {a = -7 : si64, z}, o = #mosh<ape[2]> : !mosh.ape}"
                    |> Expect.equal True
        , test "an index argument prints as index" <|
            \_ ->
                Pretty.ppTopLevelOp (withRegion "test.op" [])
                    |> String.contains "%a: index"
                    |> Expect.equal True
        , test "an opaque attribute is written as its text, and its op-less dialect is listed" <|
            \_ ->
                let
                    text =
                        asText (bytecode [] [ withRegion "test.op" [ ( "o", OpaqueAttr "#nodialectops<x>" ) ] ])
                in
                Expect.equal ( String.contains "#nodialectops<x>" text, String.contains "nodialectops." text )
                    ( True, True )
        , test "isolating an op changes how its region is written" <|
            \_ ->
                let
                    other =
                        withRegion "test.other" []
                in
                let
                    plain =
                        bytecodeList [] [ withRegion "test.graph" [], other ]

                    isolated =
                        bytecodeList [ "test.graph" ] [ withRegion "test.graph" [], other ]
                in
                Expect.notEqual plain isolated
        , test "isolating an op that is not used changes nothing" <|
            \_ ->
                Expect.equal
                    (bytecodeList [] [ withRegion "test.op" [] ])
                    (bytecodeList [ "test.unused" ] [ withRegion "test.op" [] ])
        ]
