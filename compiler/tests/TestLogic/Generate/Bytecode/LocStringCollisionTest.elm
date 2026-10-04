module TestLogic.Generate.Bytecode.LocStringCollisionTest exposing (suite)

{-| Checks that a dictionary attribute whose string value is shaped like a
location name is still indexed by the bytecode attribute table. The encoder
does not report a dictionary the table misses: it writes the index -1 into the
op's encoding, and the bytecode is wrong with no error raised.

The attribute table of `Mlir.Bytecode.AttrType` gives each collected
attribute, type and location an index, and the bytecode encoder looks
dictionaries up in it with `dictAttrIndex`, which answers -1 for a dictionary
the table does not hold. The table keys a location and a string differently, so
text such as `__mlir_unknown_loc__` or `__mlir_loc__:test:1:2` is an ordinary
string to it. These tests pin that a dictionary holding such text is indexed
like any other.

Every test builds its ops with `makeStringLiteralOp`: an op named
`eco.string_literal` whose only attribute is `value`, a `StringAttr`. Each
test collects one or two such ops into a fresh streaming accumulator, finalizes
it into a table, and looks up the dictionary `{ value = StringAttr s }` by its
contents.

What the tests establish:

  - With ops for `"hello"` and `"__mlir_unknown_loc__"` collected into one
    table, the dictionary for each has an index other than -1.
  - With an op for `"__mlir_loc__:test:1:2"` collected, its dictionary has an
    index other than -1.

Among what is not tested: the value of any index, whether the string inside
the dictionary has an entry of its own distinct from the unknown location's,
and the encoded bytes. The dictionary is keyed by the same function when it is
collected and when it is looked up, so these assertions hold whatever key its
string value receives.

-}

import Dict
import Expect
import Mlir.Bytecode.AttrType as AttrType
import Mlir.Loc
import Mlir.Mlir exposing (MlirAttr(..), MlirOp, MlirType(..))
import Test exposing (Test)


{-| Builds an op named `eco.string_literal` whose only attribute is `value`,
holding the given string. It has the unknown location, one `eco.value` result,
and no operands, regions or successors.
-}
makeStringLiteralOp : String -> MlirOp
makeStringLiteralOp value =
    { name = "eco.string_literal"
    , id = "op_0"
    , operands = []
    , results = [ ( "%0", NamedStruct "eco.value" ) ]
    , attrs = Dict.singleton "value" (StringAttr value)
    , regions = []
    , isTerminator = False
    , loc = Mlir.Loc.unknown
    , successors = []
    }


{-| A string literal op holding `"hello"`, the ordinary string the first test
sets beside the location-shaped one.
-}
makeNormalStringOp : MlirOp
makeNormalStringOp =
    makeStringLiteralOp "hello"


{-| The two tests described in the module docstring.
-}
suite : Test
suite =
    Test.describe "Bytecode AttrType location/string collision"
        [ Test.test "Dict with '__mlir_unknown_loc__' value has same dictAttrIndex behavior as normal string dict" <|
            \_ ->
                let
                    tables0 =
                        AttrType.initStreamAccum

                    normalOp =
                        makeNormalStringOp

                    magicOp =
                        makeStringLiteralOp "__mlir_unknown_loc__"

                    tables1 =
                        tables0
                            |> AttrType.streamCollectOp normalOp
                            |> AttrType.streamCollectOp magicOp

                    tbl =
                        AttrType.finalizeStreamAccum tables1

                    normalDictIdx =
                        AttrType.dictAttrIndex (Dict.singleton "value" (StringAttr "hello")) tbl

                    magicDictIdx =
                        AttrType.dictAttrIndex (Dict.singleton "value" (StringAttr "__mlir_unknown_loc__")) tbl
                in
                Expect.all
                    [ \_ ->
                        Expect.notEqual normalDictIdx -1
                    , \_ ->
                        Expect.notEqual magicDictIdx -1
                    ]
                    ()
        , Test.test "Dict with '__mlir_loc__:...' value has valid dictAttrIndex" <|
            \_ ->
                let
                    tables0 =
                        AttrType.initStreamAccum

                    magicOp =
                        makeStringLiteralOp "__mlir_loc__:test:1:2"

                    tables1 =
                        AttrType.streamCollectOp magicOp tables0

                    tbl =
                        AttrType.finalizeStreamAccum tables1

                    dictIdx =
                        AttrType.dictAttrIndex (Dict.singleton "value" (StringAttr "__mlir_loc__:test:1:2")) tbl
                in
                Expect.notEqual dictIdx -1
        ]
