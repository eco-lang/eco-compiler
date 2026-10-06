module SourceIR.TypeAliasCtorCases exposing (expectSuite, suite)

{-| Programs that call a record type alias's name as a function, so that a
pipeline stage can be checked on a record alias's constructor and not only on
the constructors of custom types.

In Elm, a type alias whose body is a closed record also defines a _record
constructor_: a function with the alias's name that takes one argument per
field and returns the record. Given

    type alias Style =
        { bold : Bool, count : Int }

`Style True 42` is a `Style` whose `bold` is `True` and whose `count` is `42`.
Typed local optimization gives each such constructor a top-level definition
of its own: an ordinary function that builds the record, with an annotation of
its own. A custom type's constructor gets a constructor node instead, so a call
to `Style` reaches monomorphization as a call to a function, not to a
constructor.

The fixture is the same in both cases: a module `Test` that declares `Style`
as above and an annotated `testValue : Int`. The constructor is referred to as
an unqualified `Style`, and its `Bool` argument is the qualified constructor
`Basics.True`.

This module asserts nothing itself. `expectSuite` hands each program to the
expectation function its caller supplies, and `suite` supplies
`TestLogic.TestPipeline.expectMonomorphization`. The cases are:

  - "Simple type alias used as record constructor": `testValue` binds
    `Style True 42` in a `let` and returns its `count` field.
  - "Type alias constructor passed to a function": `testValue` passes
    `Style True 7` to a top-level `getCount : Style -> Int` that returns the
    `count` field.

Among what is not tested: an alias with type parameters, a constructor
applied to fewer arguments than it has fields or passed as a function value,
a constructor imported from another module, and the value `testValue`
computes.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( AliasDef
        , TypedDef
        , accessExpr
        , boolExpr
        , callExpr
        , ctorExpr
        , define
        , intExpr
        , letExpr
        , makeModuleWithTypedDefsUnionsAliases
        , pVar
        , tLambda
        , tRecord
        , tType
        , varExpr
        )
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Expect exposing (Expectation)
import Test exposing (Test)
import TestLogic.TestPipeline exposing (expectMonomorphization)


{-| A test that applies `TestLogic.TestPipeline.expectMonomorphization` to both
programs. That expectation runs the program through `runToMono`, the
production pipeline, and passes when monomorphization succeeds and gives a graph
with a `main` and at least one node.
-}
suite : Test
suite =
    Test.describe "Type alias as record constructor"
        [ expectSuite expectMonomorphization "monomorphizes type alias constructors"
        ]


{-| Builds one test, named "Type alias constructor " followed by `condStr`,
that passes when `expectFn` passes on both programs. The cases run in order
under `Compiler.BulkCheck.bulkCheck`, so a failure names the first case that
failed.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Type alias constructor " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


{-| Returns the two labelled cases, each applying `expectFn` to its program.
-}
testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    [ { label = "Simple type alias used as record constructor"
      , run = simpleAliasAsCtor expectFn
      }
    , { label = "Type alias constructor passed to a function"
      , run = aliasCtorPassedToFunction expectFn
      }
    ]



-- ============================================================================
-- SIMPLE TYPE ALIAS USED AS RECORD CONSTRUCTOR
-- ============================================================================


{-| Returns a check that applies `expectFn` to a module whose `testValue`
binds the result of the record constructor `Style` in a `let` and reads a field
of it:

    type alias Style =
        { bold : Bool, count : Int }

    testValue : Int
    testValue =
        let
            s =
                Style True 42
        in
        s.count

-}
simpleAliasAsCtor : (Src.Module -> Expectation) -> (() -> Expectation)
simpleAliasAsCtor expectFn _ =
    let
        styleAlias : AliasDef
        styleAlias =
            { name = "Style"
            , args = []
            , tipe =
                tRecord
                    [ ( "bold", tType "Bool" [] )
                    , ( "count", tType "Int" [] )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body =
                letExpr
                    [ define "s"
                        []
                        (callExpr (ctorExpr "Style")
                            [ boolExpr True, intExpr 42 ]
                        )
                    ]
                    (accessExpr (varExpr "s") "count")
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ testValueDef ]
                []
                [ styleAlias ]
    in
    expectFn modul



-- ============================================================================
-- TYPE ALIAS CONSTRUCTOR PASSED TO A FUNCTION
-- ============================================================================


{-| Returns a check that applies `expectFn` to a module whose `testValue` passes
the result of the record constructor `Style` straight to a top-level function
that reads a field of it:

    type alias Style =
        { bold : Bool, count : Int }

    getCount : Style -> Int
    getCount s =
        s.count

    testValue : Int
    testValue =
        getCount (Style True 7)

-}
aliasCtorPassedToFunction : (Src.Module -> Expectation) -> (() -> Expectation)
aliasCtorPassedToFunction expectFn _ =
    let
        styleAlias : AliasDef
        styleAlias =
            { name = "Style"
            , args = []
            , tipe =
                tRecord
                    [ ( "bold", tType "Bool" [] )
                    , ( "count", tType "Int" [] )
                    ]
            }

        getCountDef : TypedDef
        getCountDef =
            { name = "getCount"
            , args = [ pVar "s" ]
            , tipe =
                tLambda
                    (tType "Style" [])
                    (tType "Int" [])
            , body =
                accessExpr (varExpr "s") "count"
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body =
                callExpr (varExpr "getCount")
                    [ callExpr (ctorExpr "Style")
                        [ boolExpr True, intExpr 7 ]
                    ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ getCountDef, testValueDef ]
                []
                [ styleAlias ]
    in
    expectFn modul
