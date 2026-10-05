module TestLogic.Generate.CodeGen.ListConstructionTest exposing (suite)

{-| The eco MLIR dialect has its own operations for lists: `eco.construct.list`
builds a cons cell, and the empty list is an `eco.constant`. These tests look,
across many programs rather than a hand-picked few, for a list constructor
built instead with `eco.construct.custom`, the generic operation for a value of
a custom type.

The fixture is the standard catalogue of `SourceIR` test programs gathered by
`SourceIR.Suite.StandardTestSuites`. Two of its case modules hold fuzz tests,
whose programs can vary from run to run.

What the tests establish:

  - `suite`: for each program in the catalogue, that
    `TestLogic.TestPipeline.runToMlir` succeeds on it and that the MLIR module
    it generates has no `eco.construct.custom` op whose `constructor`
    attribute is `::` or `[]`, as
    `TestLogic.Generate.CodeGen.ListConstruction.expectListConstruction`
    describes.
  - `userConsAndNil`: a program that declares its own `Cons` and `Nil`
    constructors, builds values with them and puts them in a list literal
    compiles to an `eco.construct.custom` named `Cons`, and the check does not
    report it.

Among what is not tested:

  - that cons cells are built with `eco.construct.list`, or that the empty
    list is an `eco.constant`;
  - an `eco.construct.custom` op with no `constructor` attribute.

-}

import Compiler.AST.Source as Src
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
import Expect
import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.CodeGen.Invariants exposing (findOpsNamed, getStringAttr)
import TestLogic.Generate.CodeGen.ListConstruction exposing (expectListConstruction)
import TestLogic.TestPipeline exposing (runToMlir)


{-| The test group that runs the list-construction check on every program in
the standard catalogue.
-}
suite : Test
suite =
    Test.describe "CGEN_016: List Construction"
        [ StandardTestSuites.expectSuite expectListConstruction "passes list construction invariant"
        , Test.test "a program's own Cons and Nil constructors are not list constructors" userConsAndNil
        ]


{-| A program declaring `type MyList = Cons Int MyList | Nil` whose
`testValue` is `[ Cons 1 (Cons 2 Nil), Nil ]`. The test first makes sure the
generated MLIR does build a `Cons` with `eco.construct.custom`, so the second
part, that `expectListConstruction` passes, is not vacuous.
-}
userConsAndNil : () -> Expect.Expectation
userConsAndNil _ =
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

        modul : Src.Module
        modul =
            makeModuleWithTypedDefsUnionsAliases "TestMod" [ mainDef ] [ myListUnion ] []
    in
    case runToMlir modul of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            let
                builtCons =
                    findOpsNamed "eco.construct.custom" mlirModule
                        |> List.any (\op -> getStringAttr "constructor" op == Just "Cons")
            in
            if builtCons then
                expectListConstruction modul

            else
                Expect.fail "fixture did not build its own Cons with eco.construct.custom"
