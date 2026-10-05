module TestLogic.Generate.Bytecode.LocStringCollisionTest exposing (suite)

{-| Checks that a string attribute whose text is shaped like a location, or
like the key the attribute table gives a location, gets an entry of its own in
the bytecode attribute table instead of being merged with a location's entry.

The attribute table of `Mlir.Bytecode.AttrType` gives each collected
attribute, location and attribute dictionary an index in one numbering, and
collection skips a value whose key is already in the table. If a string's key
could equal a location's key, the string would be dropped and every op that
used it would refer to the location instead, with no error raised.

The table does not expose the index of a plain attribute, but indices are
handed out in collection order. So each test collects the same sequence of ops
twice, once with the location-shaped string and once with an ordinary string of
the same role (the _control_), and then collects a _probe_ op whose location is
new. The probe's location index counts the entries added before it: if the
location-shaped string had been merged with a location, the probe's index
would be one lower than in the control.

Every op is built with `makeStringLiteralOp`: an op named
`eco.string_literal` whose only attribute is `value`, a `StringAttr`.

What the tests establish:

  - `"__mlir_unknown_loc__"` and `"LOC:unknown"` (the table's key for the
    unknown location), collected beside an op at the unknown location, each
    get an entry of their own; their dictionaries are found, and are distinct
    from each other's and from the unknown location's index.
  - `"LOC:test:1:2"` (the key for the location `test` 1:2), collected in an
    op at that location, gets an entry of its own.

Not tested: the encoded bytes.

-}

import Dict
import Expect
import Mlir.Bytecode.AttrType as AttrType
import Mlir.Loc exposing (Loc(..))
import Mlir.Mlir exposing (MlirAttr(..), MlirOp, MlirType(..))
import Test exposing (Test)


{-| Builds an op named `eco.string_literal` at `loc` whose only attribute is
`value`, holding the given string. It has one `eco.value` result and no
operands, regions or successors.
-}
makeStringLiteralOp : Loc -> String -> MlirOp
makeStringLiteralOp loc value =
    { name = "eco.string_literal"
    , id = "op_0"
    , operands = []
    , results = [ ( "%0", NamedStruct "eco.value" ) ]
    , attrs = Dict.singleton "value" (StringAttr value)
    , regions = []
    , isTerminator = False
    , loc = loc
    , successors = []
    }


{-| A file location `name` at `row`:`col`, ending where it starts.
-}
fileLoc : String -> Int -> Int -> Loc
fileLoc name row col =
    Loc { name = name, start = { row = row, col = col }, end = { row = row, col = col } }


{-| The location of the probe op, which no other op uses.
-}
probeLoc : Loc
probeLoc =
    fileLoc "probe" 99 1


{-| Collects `ops` and then a probe op at `probeLoc` into a fresh table.
-}
collectWithProbe : List MlirOp -> AttrType.AttrTypeTable
collectWithProbe ops =
    (ops ++ [ { name = "eco.probe", id = "op_p", operands = [], results = [], attrs = Dict.empty, regions = [], isTerminator = False, loc = probeLoc, successors = [] } ])
        |> List.foldl AttrType.streamCollectOp AttrType.initStreamAccum
        |> AttrType.finalizeStreamAccum


{-| The index of the dictionary `{ value = StringAttr s }` in `tbl`.
-}
valueDictIndex : String -> AttrType.AttrTypeTable -> Int
valueDictIndex s tbl =
    AttrType.dictAttrIndex (Dict.singleton "value" (StringAttr s)) tbl


{-| Collects `[ op at loc holding "hello", op at loc holding magic ]` and the
same with `"world"` in place of `magic`, and expects the probe location to get
the same index in both, the dictionaries to be found, and the dictionary of
`magic` to have an index distinct from the other dictionary's and from `loc`'s.
-}
expectOwnEntry : Loc -> String -> Expect.Expectation
expectOwnEntry loc magic =
    let
        tbl =
            collectWithProbe [ makeStringLiteralOp loc "hello", makeStringLiteralOp loc magic ]

        control =
            collectWithProbe [ makeStringLiteralOp loc "hello", makeStringLiteralOp loc "world" ]

        locIdx =
            AttrType.locIndex loc tbl

        normalDictIdx =
            valueDictIndex "hello" tbl

        magicDictIdx =
            valueDictIndex magic tbl
    in
    Expect.all
        [ \_ -> Expect.notEqual -1 locIdx
        , \_ -> Expect.notEqual -1 normalDictIdx
        , \_ -> Expect.notEqual -1 magicDictIdx
        , \_ -> Expect.notEqual locIdx magicDictIdx
        , \_ -> Expect.notEqual normalDictIdx magicDictIdx
        , \_ ->
            AttrType.locIndex probeLoc tbl
                |> Expect.equal (AttrType.locIndex probeLoc control)
                |> Expect.onFail ("the string " ++ magic ++ " did not get an entry of its own")
        ]
        ()


{-| The tests described in the module docstring.
-}
suite : Test
suite =
    Test.describe "Bytecode AttrType location/string collision"
        [ Test.test "'__mlir_unknown_loc__' string gets its own entry beside the unknown location" <|
            \_ -> expectOwnEntry Mlir.Loc.unknown "__mlir_unknown_loc__"
        , Test.test "'LOC:unknown' string gets its own entry beside the unknown location" <|
            \_ -> expectOwnEntry Mlir.Loc.unknown "LOC:unknown"
        , Test.test "'LOC:test:1:2' string gets its own entry beside location test 1:2" <|
            \_ -> expectOwnEntry (fileLoc "test" 1 2) "LOC:test:1:2"
        ]
