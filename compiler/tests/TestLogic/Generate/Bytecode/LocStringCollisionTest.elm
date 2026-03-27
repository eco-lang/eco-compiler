module TestLogic.Generate.Bytecode.LocStringCollisionTest exposing (suite)

{-| Test that the bytecode AttrType table keeps location entries separate
from string entries whose values happen to match internal magic prefixes.

Regression test for: bytecode encoder conflating StringAttr values
containing "\_\_mlir\_unknown\_loc\_\_" or "\_\_mlir\_loc\_\_:" with location attrs.

The bug: dictToKey uses attrToKey internally. When attrToKey maps
StringAttr "\_\_mlir\_unknown\_loc\_\_" to "loc:unknown", the dictToKey becomes
"d:{value=loc:unknown}". But during collection, collectDictContents calls
addAttrEntry(StringAttr "\_\_mlir\_unknown\_loc\_\_"), which maps to key
"loc:unknown" and finds it already exists (from the location init).
So the STRING attr entry is never added to the table. Later, when encoding
the DictAttr, it tries to reference attrIndex(StringAttr "\_\_mlir\_unknown\_loc\_\_")
which returns the location entry index. The C++ parser then sees a location
where it expects a string.

-}

import Dict
import Expect
import Mlir.Bytecode.AttrType as AttrType
import Mlir.Loc
import Mlir.Mlir exposing (MlirAttr(..), MlirOp, MlirRegion(..), MlirType(..))
import OrderedDict
import Test exposing (Test)


{-| Create a minimal MlirOp that looks like eco.string\_literal with the given value.
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


{-| Create a normal string literal op for comparison.
-}
makeNormalStringOp : MlirOp
makeNormalStringOp =
    makeStringLiteralOp "hello"


suite : Test
suite =
    Test.describe "Bytecode AttrType location/string collision"
        [ Test.test "Dict with '__mlir_unknown_loc__' value has same dictAttrIndex behavior as normal string dict" <|
            \_ ->
                let
                    -- Build table with both a normal string literal and the magic-prefix string
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

                    -- Both dict indices should be valid (not -1)
                    normalDictIdx =
                        AttrType.dictAttrIndex (Dict.singleton "value" (StringAttr "hello")) tbl

                    magicDictIdx =
                        AttrType.dictAttrIndex (Dict.singleton "value" (StringAttr "__mlir_unknown_loc__")) tbl
                in
                Expect.all
                    [ \_ ->
                        -- Normal string dict has valid index
                        Expect.notEqual normalDictIdx -1
                    , \_ ->
                        -- Magic-prefix string dict ALSO has valid index (not -1)
                        -- Before fix: this fails because the dict key uses attrToKey which
                        -- maps the magic prefix differently, causing lookup failure
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
                -- Should have a valid index
                Expect.notEqual dictIdx -1
        ]
