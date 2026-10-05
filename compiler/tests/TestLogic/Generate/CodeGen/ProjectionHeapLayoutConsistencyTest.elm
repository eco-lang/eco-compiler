module TestLogic.Generate.CodeGen.ProjectionHeapLayoutConsistencyTest exposing (suite)

{-| Runs the list head layout check on every program in the standard catalogue,
so that a compiler change which hands a list between code expecting its
elements boxed and code expecting them unboxed fails a test, wherever that
check can see it, on many programs rather than on a hand-picked few.

A list element is _unboxed_ when it is held as a raw machine value rather than
as a pointer to a heap object. The check, and the two ways it looks for a
mismatch in the monomorphized graph, are described in
`TestLogic.Generate.CodeGen.ProjectionHeapLayoutConsistency`.

The fixture is the catalogue of source programs that
`SourceIR.Suite.StandardTestSuites` gathers from its case modules.

`suite` establishes, for each program in the catalogue, that it compiles to
MLIR and that `expectProjectionHeapLayoutConsistency` finds no problem in its
monomorphized graph: no call to a global that the checker examines passes a
list whose elements are unboxed where the callee's parameter expects them boxed,
or the reverse.

`separateSpecializations` checks a program, `count [ 1, 2 ] + count []`, whose
`count` gets one specialization for `List Int` and one for a list of an erased
variable. That is valid output, since each specialization only receives lists
of its own element type, and the check must pass on it.

Among what is not tested: any MLIR op, including `eco.project.list_head`
itself; the calls and list positions the checker's docstring lists as
unchecked; and programs outside the catalogue.

-}

import Compiler.AST.SourceBuilder
    exposing
        ( binopsExpr
        , callExpr
        , caseExpr
        , intExpr
        , listExpr
        , makeModuleWithTypedDefs
        , pAnything
        , pCons
        , pList
        , pVar
        , tLambda
        , tType
        , tVar
        , varExpr
        )
import Expect exposing (Expectation)
import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.CodeGen.ProjectionHeapLayoutConsistency exposing (expectProjectionHeapLayoutConsistency)


{-| A test group that checks every program in the standard catalogue with
`expectProjectionHeapLayoutConsistency`.
-}
suite : Test
suite =
    Test.describe "REP_BOUNDARY_003: Projection heap layout consistency"
        [ StandardTestSuites.expectSuite expectProjectionHeapLayoutConsistency "passes projection heap layout consistency"
        , Test.test "List Int and erased-list specializations of one function" separateSpecializations
        ]


{-| `count : List a -> Int`, a recursive length, used as
`count [ 1, 2 ] + count []`, which monomorphizes `count` once at `List Int`
and once at a list of an erased variable.
-}
separateSpecializations : () -> Expectation
separateSpecializations _ =
    let
        countDef =
            { name = "count"
            , args = [ pVar "xs" ]
            , tipe = tLambda (tType "List" [ tVar "a" ]) (tType "Int" [])
            , body =
                caseExpr (varExpr "xs")
                    [ ( pList [], intExpr 0 )
                    , ( pCons pAnything (pVar "rest")
                      , binopsExpr [ ( intExpr 1, "+" ) ] (callExpr (varExpr "count") [ varExpr "rest" ])
                      )
                    ]
            }

        mainDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body =
                binopsExpr [ ( callExpr (varExpr "count") [ listExpr [ intExpr 1, intExpr 2 ] ], "+" ) ]
                    (callExpr (varExpr "count") [ listExpr [] ])
            }
    in
    expectProjectionHeapLayoutConsistency (makeModuleWithTypedDefs "TestMod" [ countDef, mainDef ])
