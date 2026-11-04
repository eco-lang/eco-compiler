module Compiler.GenerateMlir.OpsUserListCtorTest exposing (suite)

{-| Pins that a program's own constructors named `Cons` and `Nil` are built as
ordinary custom values, with `eco.construct.custom`, and are not taken for the
list constructors, which the eco dialect builds with `eco.construct.list` and
an `eco.constant`.

The program is also a catalogue case of `SourceIR.CaseCases`, where
`TestLogic.Generate.CodeGen.ListConstructionTest` (CGEN\_016) checks that no
`eco.construct.custom` names a list constructor (`::` or `[]`). Here it is
compiled with `TestLogic.TestPipeline.runToMlir`, and the test passes when the
MLIR holds an `eco.construct.custom` whose `constructor` attribute is `Cons`.

Among what is not tested: how `Nil`, a nullary constructor, is represented.

-}

import Compiler.AST.SourceBuilder
    exposing
        ( TypedDef
        , UnionDef
        , callExpr
        , ctorExpr
        , intExpr
        , listExpr
        , makeModuleWithTypedDefsUnionsAliases
        , tType
        )
import Compiler.IR.Source as Src
import Expect
import Test exposing (Test)
import TestLogic.Generate.CodeGen.Invariants exposing (findOpsNamed, getStringAttr)
import TestLogic.TestPipeline exposing (runToMlir)


{-| The pin of the module docstring.
-}
suite : Test
suite =
    Test.test "a program's own Cons is built with eco.construct.custom" <|
        \_ ->
            case runToMlir userConsAndNil of
                Err err ->
                    Expect.fail ("Compilation failed: " ++ err)

                Ok { mlirModule } ->
                    findOpsNamed "eco.construct.custom" mlirModule
                        |> List.any (\op -> getStringAttr "constructor" op == Just "Cons")
                        |> Expect.equal True
                        |> Expect.onFail "the program's own Cons was not built with eco.construct.custom"


{-| `type MyList = Cons Int MyList | Nil` and
`testValue : List MyList = [ Cons 1 (Cons 2 Nil), Nil ]`.
-}
userConsAndNil : Src.Module
userConsAndNil =
    let
        myList =
            tType "MyList" []

        myListUnion : UnionDef
        myListUnion =
            { name = "MyList"
            , args = []
            , ctors =
                [ { name = "Cons", args = [ tType "Int" [], myList ] }
                , { name = "Nil", args = [] }
                ]
            }

        mainDef : TypedDef
        mainDef =
            { name = "testValue"
            , args = []
            , tipe = tType "List" [ myList ]
            , body =
                listExpr
                    [ callExpr (ctorExpr "Cons") [ intExpr 1, callExpr (ctorExpr "Cons") [ intExpr 2, ctorExpr "Nil" ] ]
                    , ctorExpr "Nil"
                    ]
            }
    in
    makeModuleWithTypedDefsUnionsAliases "TestMod" [ mainDef ] [ myListUnion ] []
