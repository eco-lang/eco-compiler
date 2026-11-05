module Mlir.MlirEncodingCoverageTest exposing (suite)

{-| Writes a hand-built MLIR module, as text with `Mlir.Pretty` and as
bytecode with `Mlir.Bytecode.StreamEncode`, so that the encodings no compiled
program produces are written under test: a region with labelled blocks and a
terminator with successors, `i8` types and integer attributes typed `i8`,
`f64` and a dialect type, dense arrays of `i1`, `i8` and `i32` and an
empty one, a dense array holding a non-integer element, negative and negative
zero floats, a dialect type and an operation name without a `.`, an operand
that is never defined, a file location, and string attributes holding every
kind of escape both writers convert, well formed or not.

The module is one function-like operation, `test.func`, whose region has an
entry block and two labelled blocks, `bb1` and `bb2`, each with an `i8`
argument. The entry block's operation, `test.probe`, carries all of the
attributes; its terminator, `test.br`, names both labelled blocks as
successors, the first with MLIR's leading `^` and the second without it, which
the bytecode writer accepts and the text printer prints as given. The function has a location in a named file.

The tests:

  - "text": the text `Mlir.Pretty` prints for the module (its header, each
    top-level operation, its footer) contains the
    successor list as given, the labelled blocks, an `i8` result, an empty dense
    array, a negative zero, and the conversions of the escapes (`é` to
    the character, `\u000A` to `\0A`, `\` to `\5C`, an incomplete or
    malformed `\u` kept as written, `\r` to `\0D`, an unknown escape losing
    its backslash, and an unescaped `"` gaining one).
  - "bytecode": the bytes `StreamEncode.assembleModule` writes for the module
    start with MLIR's bytecode magic number, `M`, `L`, `0xEF`, `R`.
  - "variable-length integer widths": `Mlir.Bytecode.VarInt.varIntWidth`
    gives 4 bytes for 2^27, and 9 for 2^28 and for a negative number.
  - "unknown operation index": `Mlir.Bytecode.DialectSection.opIndex` gives
    -1 for an operation the registry does not hold.

Among what is not tested: reading the bytecode back, which needs MLIR itself.

-}

import Bytes.Decode as BD
import Dict
import Expect exposing (Expectation)
import Mlir.Bytecode.DialectSection as DialectSection
import Mlir.Bytecode.StreamEncode as StreamEncode
import Mlir.Bytecode.VarInt as VarInt
import Mlir.Loc as Loc
import Mlir.Mlir exposing (MlirAttr(..), MlirBlock, MlirModule, MlirOp, MlirRegion(..), MlirType(..))
import Mlir.Pretty as Pretty
import OrderedDict
import Test exposing (Test)


{-| The four tests, under a label that contains "coverage run" so that the
coverage loop's quick run includes them.
-}
suite : Test
suite =
    Test.describe "MLIR encodings (coverage run)"
        [ Test.test "text" <|
            \_ ->
                expectText
                    (Pretty.ppModuleHeader
                        ++ String.concat (List.map Pretty.ppTopLevelOp testModule.body)
                        ++ Pretty.ppModuleFooter
                    )
        , Test.test "bytecode" <|
            \_ ->
                StreamEncode.collectAndEncodeOps testModule.body StreamEncode.emptyStreamTables
                    |> (\tables -> StreamEncode.assembleModule tables testModule.loc)
                    |> BD.decode magic
                    |> Expect.equal (Just [ 0x4D, 0x4C, 0xEF, 0x52 ])
        , Test.test "variable-length integer widths" <|
            \_ ->
                Expect.equal [ 4, 9, 9 ]
                    (List.map VarInt.varIntWidth [ 0x08000000, 0x10000000, -1 ])
        , Test.test "unknown operation index" <|
            \_ ->
                Expect.equal -1
                    (DialectSection.opIndex "test.missing" (DialectSection.buildRegistry { dialects = [], dialectIndices = Dict.empty, opGroups = [], opIndexMap = Dict.empty }))
        ]


{-| Passes when `text` contains every expected fragment, and otherwise fails
naming the first missing one.
-}
expectText : String -> Expectation
expectText text =
    case List.filter (\fragment -> not (String.contains fragment text)) expectedFragments of
        [] ->
            Expect.pass

        missing :: _ ->
            Expect.fail ("missing " ++ missing ++ " in:\n" ++ text)


{-| Fragments of the printed module, as the module documentation lists them.
-}
expectedFragments : List String
expectedFragments =
    [ "[^bb1, bb2]"
    , "^bb1("
    , "^bb2("
    , ": i8"
    , "array<i8>"
    , "-0.0"
    , "é"
    , "\\0A"
    , "\\5C"
    , "\\uZZZZ"
    , "\\0D"
    , "\\\""
    ]


{-| Decodes the first four bytes.
-}
magic : BD.Decoder (List Int)
magic =
    BD.map4 (\a b c d -> [ a, b, c, d ]) BD.unsignedInt8 BD.unsignedInt8 BD.unsignedInt8 BD.unsignedInt8


{-| The module: the one `test.func` operation.
-}
testModule : MlirModule
testModule =
    { body = [ funcOp ], loc = Loc.unknown }


{-| An operation with the given name, operands, results and attributes, and no
regions or successors.
-}
mkOp : String -> List String -> List ( String, MlirType ) -> List ( String, MlirAttr ) -> MlirOp
mkOp name operands results attrs =
    { name = name
    , id = name
    , operands = operands
    , results = results
    , attrs = Dict.fromList attrs
    , regions = []
    , isTerminator = False
    , loc = Loc.unknown
    , successors = []
    }


{-| A terminator with the given name, operands and successors.
-}
terminator : String -> List String -> List String -> MlirOp
terminator name operands successors =
    let
        op =
            mkOp name operands [] []
    in
    { op | isTerminator = True, successors = successors }


{-| A block with one `i8` argument `arg` that returns it.
-}
labelledBlock : String -> MlirBlock
labelledBlock arg =
    { args = [ ( arg, I8 ) ]
    , body = []
    , terminator = terminator "test.return" [ arg ] []
    }


{-| The function: a region of an entry block holding `probeOp` and branching
to `bb1` or `bb2`, both labelled blocks, at a location in `Test.elm`.
-}
funcOp : MlirOp
funcOp =
    let
        op =
            mkOp "test.func" [] [] [ ( "sym_name", StringAttr "f" ) ]

        region =
            MlirRegion
                { entry =
                    { args = []
                    , body = [ probeOp, mkOp "nodot" [] [] [] ]
                    , terminator = terminator "test.br" [ "%p", "%undefined" ] [ "^bb1", "bb2" ]
                    }
                , blocks =
                    OrderedDict.empty
                        |> OrderedDict.insert "bb1" (labelledBlock "%a")
                        |> OrderedDict.insert "bb2" (labelledBlock "%b")
                }
    in
    { op
        | regions = [ region ]
        , loc = Loc.Loc { name = "Test.elm", start = { row = 3, col = 1 }, end = { row = 3, col = 9 } }
    }


{-| The operation that carries every attribute and type the module is about.
-}
probeOp : MlirOp
probeOp =
    mkOp "test.probe"
        []
        [ ( "%p", I8 ), ( "%q", NamedStruct "plain" ) ]
        [ ( "int8", IntAttr (Just I8) 5 )
        , ( "intFloat", IntAttr (Just F64) 1 )
        , ( "intNamed", IntAttr (Just (NamedStruct "eco.value")) 2 )
        , ( "big", IntAttr (Just I64) 0x1000000000000000 )
        , ( "negZero", TypedFloatAttr -0.0 F64 )
        , ( "negative", TypedFloatAttr -1.5 F64 )
        , ( "dense1", ArrayAttr (Just I1) [ IntAttr Nothing 1, IntAttr Nothing 0 ] )
        , ( "dense8", ArrayAttr (Just I8) [ IntAttr Nothing 7, StringAttr "x" ] )
        , ( "dense32", ArrayAttr (Just I32) [ IntAttr Nothing 3 ] )
        , ( "denseEmpty", ArrayAttr (Just I8) [] )
        , ( "types", ArrayAttr Nothing [ TypeAttr I8, TypeAttr I32 ] )
        , ( "_operand_types", ArrayAttr Nothing [ UnitAttr ] )
        , ( "unicode", StringAttr "caf\\u00e9 \\u00E9" )
        , ( "control", StringAttr "line\\u000Aend" )
        , ( "backslash", StringAttr "slash\\u005c" )
        , ( "malformed", StringAttr "bad\\uZZZZ short\\u12" )
        , ( "carriage", StringAttr "cr\\r" )
        , ( "unknownEscape", StringAttr "q\\q" )
        , ( "quote", StringAttr "say \"hi\"" )
        , ( "trailing", StringAttr "end\\" )
        , ( "hexByte", StringAttr "byte\\041 \\0zz \\0a" )
        , ( "hex4", StringAttr "lower\\u00ff \\u12zz \\uzz12" )
        ]
