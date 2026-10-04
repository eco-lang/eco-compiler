module TestLogic.Generate.CodeGen.SafepointRegionScopingTest exposing (suite)

{-| Runs the GC root scoping check over four catalogues of test programs and
one fixture of its own, so that generated MLIR in which an op uses an SSA value
defined in a sibling region of a branching op, which MLIR does not allow, is
caught by the test suite.

A branching op such as `eco.case` has one region per alternative, and a value
defined in one of those regions is out of scope in the others. The check is
`TestLogic.Generate.CodeGen.SafepointRegionScoping.expectSafepointRegionScoping`,
whose module docstring defines its terms and lists what it leaves out. It
compiles a program to MLIR and fails if compilation fails, or if an operand of
a _GC root carrier_ (`eco.call`, `eco.papExtend`, `eco.papCreate` or one of
five `eco.construct` ops) in a top-level `func.func` is out of scope where the
op sits.

A _GC root hint_ is an extra operand the code generator may append to a
carrier, naming a value the garbage collector must keep alive across it. The
"safepoint" in this module's name is the point at which an allocation may run
the collector. The code generator currently appends no hints
(`Compiler.Generate.MLIR.Context.liveEcoValueVars` returns none), so the
operands the check examines are the carriers' ordinary ones.

`suite` runs the check on:

  - the standard catalogue, `SourceIR.Suite.StandardTestSuites`, which
    includes `SourceIR.TailRecCaseCases` and `SourceIR.IfLetSafepointCases`;
  - `SourceIR.TailRecCaseCases` again: self-recursive functions that make
    their recursive call from a branch of a `case`;
  - `SourceIR.IfLetSafepointCases` again: a variable bound by a `case`
    pattern inside the `else` branch of an `if`;
  - `SourceIR.CaseSafepointLeakCases`, which the standard catalogue leaves
    out: a `case` bound by a `let`, followed by an allocation;
  - the fixture `tailRecFanOutAllocModule`, in which a self-tail-recursive
    function matches on a three-constructor type, aimed at the loop-step code
    of `Compiler.Generate.MLIR.TailRec` that branches on a constructor tag
    (`compileCaseFanOutStep`).

Among what is not tested:

  - that the fixture's `case` is compiled by `compileCaseFanOutStep`; no test
    looks at which code path is taken;
  - GC root hints themselves, since none are generated;
  - what the check does not examine, as its module docstring lists.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( TypedDef
        , UnionDef
        , binopsExpr
        , callExpr
        , caseExpr
        , ctorExpr
        , listExpr
        , makeModuleWithTypedDefsUnionsAliases
        , pAnything
        , pCtor
        , pVar
        , strExpr
        , tLambda
        , tType
        , varExpr
        )
import SourceIR.CaseSafepointLeakCases as CaseSafepointLeakCases
import SourceIR.IfLetSafepointCases as IfLetSafepointCases
import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import SourceIR.TailRecCaseCases as TailRecCaseCases
import Test exposing (Test)
import TestLogic.Generate.CodeGen.SafepointRegionScoping exposing (expectSafepointRegionScoping)


{-| Every test of this module: the scoping check over the standard,
tail-recursive-case, if-let and case-leak catalogues, then over the fixture.
-}
suite : Test
suite =
    Test.describe "Safepoint Region Scoping"
        [ StandardTestSuites.expectSuite expectSafepointRegionScoping "passes safepoint region scoping invariant"
        , TailRecCaseCases.expectSuite expectSafepointRegionScoping "passes safepoint region scoping for tail-rec cases"
        , IfLetSafepointCases.expectSuite expectSafepointRegionScoping "passes safepoint region scoping for if-let cases"
        , CaseSafepointLeakCases.expectSuite expectSafepointRegionScoping "passes safepoint region scoping for case-leak cases"
        , tailRecFanOutWithAllocationSuite
        ]


{-| A group of one test, which passes when `tailRecFanOutAllocModule` compiles
to MLIR and passes the scoping check.
-}
tailRecFanOutWithAllocationSuite : Test
tailRecFanOutWithAllocationSuite =
    Test.describe "TailRec fan-out with allocation (safepoint scoping)"
        [ Test.test "3-ctor case with allocation in each branch" <|
            \_ ->
                expectSafepointRegionScoping tailRecFanOutAllocModule
        ]


{-| The fixture: a module named `Test` holding a self-tail-recursive function
that matches on a three-constructor type, written here as Elm source. The
built tree has no `Parens` node where the source has parentheses.

    type Doc
        = Empty
        | Text String Doc
        | Line Int Doc

    flatten : Doc -> List String -> List String
    flatten doc acc =
        case doc of
            Empty ->
                acc

            Text s rest ->
                flatten rest (s :: acc)

            Line _ rest ->
                flatten rest ("*" :: acc)

    testValue : List String
    testValue =
        flatten (Text "a" (Text "b" Empty)) []

Both recursive calls are tail calls with both arguments, so the MLIR back end
compiles `flatten` as a loop whose step is the `case`. The `Text` and `Line`
branches each build a list cell; the `Empty` branch builds nothing.

-}
tailRecFanOutAllocModule : Src.Module
tailRecFanOutAllocModule =
    let
        unions : List UnionDef
        unions =
            [ { name = "Doc"
              , args = []
              , ctors =
                    [ { name = "Empty", args = [] }
                    , { name = "Text", args = [ tType "String" [], tType "Doc" [] ] }
                    , { name = "Line", args = [ tType "Int" [], tType "Doc" [] ] }
                    ]
              }
            ]

        flattenDef : TypedDef
        flattenDef =
            { name = "flatten"
            , tipe =
                tLambda (tType "Doc" [])
                    (tLambda (tType "List" [ tType "String" [] ])
                        (tType "List" [ tType "String" [] ])
                    )
            , args = [ pVar "doc", pVar "acc" ]
            , body =
                caseExpr (varExpr "doc")
                    [ ( pCtor "Empty" [], varExpr "acc" )
                    , ( pCtor "Text" [ pVar "s", pVar "rest" ]
                      , callExpr (varExpr "flatten")
                            [ varExpr "rest"
                            , binopsExpr [ ( varExpr "s", "::" ) ] (varExpr "acc")
                            ]
                      )
                    , ( pCtor "Line" [ pAnything, pVar "rest" ]
                      , callExpr (varExpr "flatten")
                            [ varExpr "rest"
                            , binopsExpr [ ( strExpr "*", "::" ) ] (varExpr "acc")
                            ]
                      )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "List" [ tType "String" [] ]
            , body =
                callExpr (varExpr "flatten")
                    [ callExpr (ctorExpr "Text")
                        [ strExpr "a"
                        , callExpr (ctorExpr "Text")
                            [ strExpr "b"
                            , ctorExpr "Empty"
                            ]
                        ]
                    , listExpr []
                    ]
            }
    in
    makeModuleWithTypedDefsUnionsAliases "Test"
        [ flattenDef, testValueDef ]
        unions
        []
