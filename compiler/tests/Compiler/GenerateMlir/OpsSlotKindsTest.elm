module Compiler.GenerateMlir.OpsSlotKindsTest exposing (suite)

{-| Pins the `slot_kinds` that `Compiler.GenerateMlir.Ops` gives a record or
custom construct op wider than the 26 slots the old Elm-side bitmap could
describe: every primitive field is unboxed, with no cap on its index, and a
record's kinds follow `Compiler.GenerateMlir.Types.computeRecordLayout`, which
puts the primitive fields first, sorted by name, and the boxed fields after.

The three programs are also catalogue cases of `SourceIR.WideObjectCases`,
where `TestLogic.Generate.CodeGen.UnboxedBitmapTest` checks that each construct
op's kinds agree with its operand types. Here each is compiled with
`TestLogic.TestPipeline.runToMlir`, and every op of the named kind
(`TestLogic.Generate.CodeGen.UnboxedBitmap.expectSlotKinds`; constant-thunk
folding can emit one construction more than once) must carry exactly:

  - `record30Int`, a record literal of 30 `Int` fields: an
    `eco.construct.record` with 30 kinds 1 (`Int`);
  - `ctor30Int`, `W 0 1 ... 29` for `type W = W Int ... Int` (30 fields): an
    `eco.construct.custom` with 30 kinds 1;
  - `recordMixed28`, a record of `Char` `c0`, `c1`, `Int` `f00`..`f13`,
    `Float` `g00`..`g09` and `String` `s0`, `s1`: an `eco.construct.record`
    with kinds 3, 3, then fourteen 1, then ten 2 (`Float`), then 0, 0
    (boxed).

Among what is not tested: tuples, which carry an integer bitmap, and list
cons cells.

-}

import Compiler.AST.SourceBuilder
    exposing
        ( callExpr
        , chrExpr
        , ctorExpr
        , floatExpr
        , intExpr
        , makeModuleWithTypedDefs
        , makeModuleWithTypedDefsUnionsAliases
        , recordExpr
        , strExpr
        , tRecord
        , tType
        )
import Compiler.IR.Source as Src
import Test exposing (Test)
import TestLogic.Generate.CodeGen.UnboxedBitmap exposing (expectSlotKinds)


{-| The three pins of the module docstring.
-}
suite : Test
suite =
    Test.describe "Construct op slot_kinds past the old record bitmap"
        [ Test.test "a record with 30 Int fields is fully unboxed in slot_kinds"
            (\_ -> expectSlotKinds "eco.construct.record" (List.repeat 30 1) record30Int)
        , Test.test "a constructor with 30 Int fields is fully unboxed in slot_kinds"
            (\_ -> expectSlotKinds "eco.construct.custom" (List.repeat 30 1) ctor30Int)
        , Test.test "mixed record kinds past slot 26"
            (\_ -> expectSlotKinds "eco.construct.record" ([ 3, 3 ] ++ List.repeat 14 1 ++ List.repeat 10 2 ++ [ 0, 0 ]) recordMixed28)
        ]


{-| `prefix` followed by `i`, padded to two digits.
-}
numbered : String -> Int -> String
numbered prefix i =
    prefix ++ String.padLeft 2 '0' (String.fromInt i)


{-| `testValue` is a record literal with `Int` fields `i00` to `i29`.
-}
record30Int : Src.Module
record30Int =
    let
        names =
            List.map (numbered "i") (List.range 0 29)
    in
    makeModuleWithTypedDefs "TestMod"
        [ { name = "testValue"
          , args = []
          , tipe = tRecord (List.map (\n -> ( n, tType "Int" [] )) names)
          , body = recordExpr (List.indexedMap (\i n -> ( n, intExpr i )) names)
          }
        ]


{-| `type W = W Int ... Int` with 30 `Int` fields, and `testValue = W 0 1 ... 29`.
-}
ctor30Int : Src.Module
ctor30Int =
    makeModuleWithTypedDefsUnionsAliases "TestMod"
        [ { name = "testValue"
          , args = []
          , tipe = tType "W" []
          , body = callExpr (ctorExpr "W") (List.map intExpr (List.range 0 29))
          }
        ]
        [ { name = "W"
          , args = []
          , ctors = [ { name = "W", args = List.repeat 30 (tType "Int" []) } ]
          }
        ]
        []


{-| `testValue` is a record literal of `Int` `f00`..`f13`, `Float`
`g00`..`g09`, `Char` `c0`, `c1` and `String` `s0`, `s1`.
-}
recordMixed28 : Src.Module
recordMixed28 =
    let
        intNames =
            List.map (numbered "f") (List.range 0 13)

        floatNames =
            List.map (numbered "g") (List.range 0 9)

        charNames =
            [ "c0", "c1" ]

        strNames =
            [ "s0", "s1" ]
    in
    makeModuleWithTypedDefs "TestMod"
        [ { name = "testValue"
          , args = []
          , tipe =
                tRecord
                    (List.map (\n -> ( n, tType "Int" [] )) intNames
                        ++ List.map (\n -> ( n, tType "Float" [] )) floatNames
                        ++ List.map (\n -> ( n, tType "Char" [] )) charNames
                        ++ List.map (\n -> ( n, tType "String" [] )) strNames
                    )
          , body =
                recordExpr
                    (List.indexedMap (\i n -> ( n, intExpr i )) intNames
                        ++ List.indexedMap (\i n -> ( n, floatExpr (toFloat i + 0.5) )) floatNames
                        ++ List.map (\n -> ( n, chrExpr "x" )) charNames
                        ++ List.map (\n -> ( n, strExpr n )) strNames
                    )
          }
        ]
