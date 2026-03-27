module TestLogic.Generate.CodeGen.SafepointRegionScopingTest exposing (suite)

{-| Test suite for safepoint region scoping invariant.

Verifies that eco.safepoint operands never reference SSA values from sibling
regions of eco.case or other branching constructs.  Cross-sibling references
are a codegen bug that causes MLIR parse failures.

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


suite : Test
suite =
    Test.describe "Safepoint Region Scoping"
        [ StandardTestSuites.expectSuite expectSafepointRegionScoping "passes safepoint region scoping invariant"
        , TailRecCaseCases.expectSuite expectSafepointRegionScoping "passes safepoint region scoping for tail-rec cases"
        , IfLetSafepointCases.expectSuite expectSafepointRegionScoping "passes safepoint region scoping for if-let cases"
        , CaseSafepointLeakCases.expectSuite expectSafepointRegionScoping "passes safepoint region scoping for case-leak cases"
        , tailRecFanOutWithAllocationSuite
        ]


{-| Focused test: tail-recursive function with 3+ constructor case where
multiple branches allocate.  This specifically targets the
compileCaseFanOutStep code path.
-}
tailRecFanOutWithAllocationSuite : Test
tailRecFanOutWithAllocationSuite =
    Test.describe "TailRec fan-out with allocation (safepoint scoping)"
        [ Test.test "3-ctor case with allocation in each branch" <|
            \_ ->
                expectSafepointRegionScoping tailRecFanOutAllocModule
        ]


{-| Source module: a tail-recursive function matching on a 3-constructor type
where every branch allocates (producing safepoints in each eco.case region).

    type Doc = Empty | Text String Doc | Line Int Doc

    flatten : Doc -> List String -> List String
    flatten doc acc =
        case doc of
            Empty -> acc
            Text s rest -> flatten rest (s :: acc)
            Line _ rest -> flatten rest ("*" :: acc)

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
