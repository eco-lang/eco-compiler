module SourceIR.MonoCompoundCases exposing (expectSuite)

{-| Test cases targeting compound type specialization in monomorphization.

Exercises:

  - Polymorphic functions with record/tuple result types
  - Record update expressions through mono pipeline
  - Unused top-level definitions (for Prune coverage)
  - Nested polymorphic type instantiation
  - List operations with compound element types

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( TypedDef
        , UnionDef
        , accessExpr
        , binopsExpr
        , callExpr
        , caseExpr
        , ctorExpr
        , intExpr
        , letExpr
        , listExpr
        , makeModuleWithTypedDefs
        , makeModuleWithTypedDefsUnionsAliases
        , pAnything
        , pCtor
        , pTuple
        , pVar
        , recordExpr
        , strExpr
        , tLambda
        , tRecord
        , tTuple
        , tType
        , tVar
        , tupleExpr
        , updateExpr
        , varExpr
        )
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Expect exposing (Expectation)
import Test exposing (Test)


expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Mono compound type specialization " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    [ { label = "poly record builder", run = polyRecordBuilder expectFn }
    , { label = "poly tuple builder", run = polyTupleBuilder expectFn }
    , { label = "record update in let", run = recordUpdateInLet expectFn }
    , { label = "unused poly function (prune)", run = unusedPolyFunction expectFn }
    , { label = "list of records", run = listOfRecords expectFn }
    , { label = "nested maybe pattern", run = nestedMaybePattern expectFn }
    , { label = "poly function with record arg", run = polyFunctionWithRecordArg expectFn }
    , { label = "multi-field record specialization", run = multiFieldRecordSpecialization expectFn }
    , { label = "tuple in list specialization", run = tupleInListSpecialization expectFn }
    , { label = "poly function three specializations", run = polyThreeSpecs expectFn }
    , { label = "custom type with poly field", run = customTypePolyField expectFn }
    , { label = "nested let with shadowing", run = nestedLetWithShadowing expectFn }
    ]



-- ============================================================================
-- Polymorphic function returning a record
-- ============================================================================


polyRecordBuilder : (Src.Module -> Expectation) -> (() -> Expectation)
polyRecordBuilder expectFn _ =
    let
        -- makeRec : a -> b -> { first : a, second : b }
        makeRecDef : TypedDef
        makeRecDef =
            { name = "makeRec"
            , args = [ pVar "x", pVar "y" ]
            , tipe =
                tLambda (tVar "a")
                    (tLambda (tVar "b")
                        (tRecord [ ( "first", tVar "a" ), ( "second", tVar "b" ) ])
                    )
            , body = recordExpr [ ( "first", varExpr "x" ), ( "second", varExpr "y" ) ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tRecord [ ( "first", tType "Int" [] ), ( "second", tType "String" [] ) ]
            , body = callExpr (varExpr "makeRec") [ intExpr 1, strExpr "hello" ]
            }

        modul =
            makeModuleWithTypedDefs "Test" [ makeRecDef, testValueDef ]
    in
    expectFn modul



-- ============================================================================
-- Polymorphic function returning a tuple
-- ============================================================================


polyTupleBuilder : (Src.Module -> Expectation) -> (() -> Expectation)
polyTupleBuilder expectFn _ =
    let
        -- swap : (a, b) -> (b, a)
        swapDef : TypedDef
        swapDef =
            { name = "swap"
            , args = [ pTuple (pVar "x") (pVar "y") ]
            , tipe =
                tLambda (tTuple (tVar "a") (tVar "b"))
                    (tTuple (tVar "b") (tVar "a"))
            , body = tupleExpr (varExpr "y") (varExpr "x")
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tTuple (tType "String" []) (tType "Int" [])
            , body = callExpr (varExpr "swap") [ tupleExpr (intExpr 42) (strExpr "answer") ]
            }

        modul =
            makeModuleWithTypedDefs "Test" [ swapDef, testValueDef ]
    in
    expectFn modul



-- ============================================================================
-- Record update expression through mono pipeline
-- ============================================================================


recordUpdateInLet : (Src.Module -> Expectation) -> (() -> Expectation)
recordUpdateInLet expectFn _ =
    let
        -- increment : { x : Int, y : Int } -> { x : Int, y : Int }
        incrementDef : TypedDef
        incrementDef =
            { name = "increment"
            , args = [ pVar "r" ]
            , tipe =
                tLambda (tRecord [ ( "x", tType "Int" [] ), ( "y", tType "Int" [] ) ])
                    (tRecord [ ( "x", tType "Int" [] ), ( "y", tType "Int" [] ) ])
            , body =
                updateExpr (varExpr "r")
                    [ ( "x", binopsExpr [ ( accessExpr (varExpr "r") "x", "+" ) ] (intExpr 1) )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tRecord [ ( "x", tType "Int" [] ), ( "y", tType "Int" [] ) ]
            , body =
                letExpr
                    [ { name = "p", args = [], body = recordExpr [ ( "x", intExpr 0 ), ( "y", intExpr 10 ) ] } |> (\d -> Compiler.AST.SourceBuilder.define d.name d.args d.body) ]
                    (callExpr (varExpr "increment") [ varExpr "p" ])
            }

        modul =
            makeModuleWithTypedDefs "Test" [ incrementDef, testValueDef ]
    in
    expectFn modul



-- ============================================================================
-- Unused top-level function (tests Prune dead-code elimination)
-- ============================================================================


unusedPolyFunction : (Src.Module -> Expectation) -> (() -> Expectation)
unusedPolyFunction expectFn _ =
    let
        -- unusedId : a -> a (never called from testValue)
        unusedDef : TypedDef
        unusedDef =
            { name = "unusedId"
            , args = [ pVar "x" ]
            , tipe = tLambda (tVar "a") (tVar "a")
            , body = varExpr "x"
            }

        -- used : Int -> Int
        usedDef : TypedDef
        usedDef =
            { name = "used"
            , args = [ pVar "n" ]
            , tipe = tLambda (tType "Int" []) (tType "Int" [])
            , body = binopsExpr [ ( varExpr "n", "+" ) ] (intExpr 1)
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "used") [ intExpr 5 ]
            }

        modul =
            makeModuleWithTypedDefs "Test" [ unusedDef, usedDef, testValueDef ]
    in
    expectFn modul



-- ============================================================================
-- List of records
-- ============================================================================


listOfRecords : (Src.Module -> Expectation) -> (() -> Expectation)
listOfRecords expectFn _ =
    let
        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "List" [ tRecord [ ( "x", tType "Int" [] ) ] ]
            , body =
                listExpr
                    [ recordExpr [ ( "x", intExpr 1 ) ]
                    , recordExpr [ ( "x", intExpr 2 ) ]
                    , recordExpr [ ( "x", intExpr 3 ) ]
                    ]
            }

        modul =
            makeModuleWithTypedDefs "Test" [ testValueDef ]
    in
    expectFn modul



-- ============================================================================
-- Nested Maybe-like pattern matching
-- ============================================================================


nestedMaybePattern : (Src.Module -> Expectation) -> (() -> Expectation)
nestedMaybePattern expectFn _ =
    let
        maybeDef : UnionDef
        maybeDef =
            { name = "MyMaybe"
            , args = [ "a" ]
            , ctors =
                [ { name = "MyJust", args = [ tVar "a" ] }
                , { name = "MyNothing", args = [] }
                ]
            }

        -- fromMyMaybe : a -> MyMaybe a -> a
        fromDef : TypedDef
        fromDef =
            { name = "fromMyMaybe"
            , args = [ pVar "default", pVar "m" ]
            , tipe =
                tLambda (tVar "a")
                    (tLambda (tType "MyMaybe" [ tVar "a" ]) (tVar "a"))
            , body =
                caseExpr (varExpr "m")
                    [ ( pCtor "MyJust" [ pVar "val" ], varExpr "val" )
                    , ( pCtor "MyNothing" [], varExpr "default" )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body =
                callExpr (varExpr "fromMyMaybe")
                    [ intExpr 0
                    , ctorExpr "MyJust" |> (\c -> callExpr c [ intExpr 42 ])
                    ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ fromDef, testValueDef ]
                [ maybeDef ]
                []
    in
    expectFn modul



-- ============================================================================
-- Polymorphic function taking a record argument
-- ============================================================================


polyFunctionWithRecordArg : (Src.Module -> Expectation) -> (() -> Expectation)
polyFunctionWithRecordArg expectFn _ =
    let
        -- getFirst : { first : a, second : b } -> a
        getDef : TypedDef
        getDef =
            { name = "getFirst"
            , args = [ pVar "r" ]
            , tipe =
                tLambda (tRecord [ ( "first", tVar "a" ), ( "second", tVar "b" ) ])
                    (tVar "a")
            , body = accessExpr (varExpr "r") "first"
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body =
                callExpr (varExpr "getFirst")
                    [ recordExpr [ ( "first", intExpr 99 ), ( "second", strExpr "ignore" ) ] ]
            }

        modul =
            makeModuleWithTypedDefs "Test" [ getDef, testValueDef ]
    in
    expectFn modul



-- ============================================================================
-- Multi-field record with multiple specializations
-- ============================================================================


multiFieldRecordSpecialization : (Src.Module -> Expectation) -> (() -> Expectation)
multiFieldRecordSpecialization expectFn _ =
    let
        -- wrap3 : a -> b -> c -> { x : a, y : b, z : c }
        wrap3Def : TypedDef
        wrap3Def =
            { name = "wrap3"
            , args = [ pVar "a", pVar "b", pVar "c" ]
            , tipe =
                tLambda (tVar "a")
                    (tLambda (tVar "b")
                        (tLambda (tVar "c")
                            (tRecord [ ( "x", tVar "a" ), ( "y", tVar "b" ), ( "z", tVar "c" ) ])
                        )
                    )
            , body = recordExpr [ ( "x", varExpr "a" ), ( "y", varExpr "b" ), ( "z", varExpr "c" ) ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tRecord [ ( "x", tType "Int" [] ), ( "y", tType "String" [] ), ( "z", tType "Int" [] ) ]
            , body = callExpr (varExpr "wrap3") [ intExpr 1, strExpr "mid", intExpr 3 ]
            }

        modul =
            makeModuleWithTypedDefs "Test" [ wrap3Def, testValueDef ]
    in
    expectFn modul



-- ============================================================================
-- Tuple inside list specialization
-- ============================================================================


tupleInListSpecialization : (Src.Module -> Expectation) -> (() -> Expectation)
tupleInListSpecialization expectFn _ =
    let
        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "List" [ tTuple (tType "Int" []) (tType "String" []) ]
            , body =
                listExpr
                    [ tupleExpr (intExpr 1) (strExpr "one")
                    , tupleExpr (intExpr 2) (strExpr "two")
                    ]
            }

        modul =
            makeModuleWithTypedDefs "Test" [ testValueDef ]
    in
    expectFn modul



-- ============================================================================
-- Polymorphic function specialized at three types
-- ============================================================================


polyThreeSpecs : (Src.Module -> Expectation) -> (() -> Expectation)
polyThreeSpecs expectFn _ =
    let
        -- wrap : a -> List a
        wrapDef : TypedDef
        wrapDef =
            { name = "wrap"
            , args = [ pVar "x" ]
            , tipe = tLambda (tVar "a") (tType "List" [ tVar "a" ])
            , body = listExpr [ varExpr "x" ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "List" [ tType "Int" [] ]
            , body =
                letExpr
                    [ Compiler.AST.SourceBuilder.define "ints" [] (callExpr (varExpr "wrap") [ intExpr 1 ])
                    , Compiler.AST.SourceBuilder.define "strs" [] (callExpr (varExpr "wrap") [ strExpr "hi" ])
                    , Compiler.AST.SourceBuilder.define "bools" [] (callExpr (varExpr "wrap") [ Compiler.AST.SourceBuilder.boolExpr True ])
                    ]
                    (varExpr "ints")
            }

        modul =
            makeModuleWithTypedDefs "Test" [ wrapDef, testValueDef ]
    in
    expectFn modul



-- ============================================================================
-- Custom type with polymorphic field
-- ============================================================================


customTypePolyField : (Src.Module -> Expectation) -> (() -> Expectation)
customTypePolyField expectFn _ =
    let
        pairDef : UnionDef
        pairDef =
            { name = "Pair"
            , args = [ "a", "b" ]
            , ctors =
                [ { name = "MkPair", args = [ tVar "a", tVar "b" ] }
                ]
            }

        -- fstPair : Pair a b -> a
        fstDef : TypedDef
        fstDef =
            { name = "fstPair"
            , args = [ pVar "p" ]
            , tipe =
                tLambda (tType "Pair" [ tVar "a", tVar "b" ]) (tVar "a")
            , body =
                caseExpr (varExpr "p")
                    [ ( pCtor "MkPair" [ pVar "x", pAnything ], varExpr "x" ) ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body =
                callExpr (varExpr "fstPair")
                    [ callExpr (ctorExpr "MkPair") [ intExpr 10, strExpr "world" ] ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ fstDef, testValueDef ]
                [ pairDef ]
                []
    in
    expectFn modul



-- ============================================================================
-- Nested let with variable shadowing
-- ============================================================================


nestedLetWithShadowing : (Src.Module -> Expectation) -> (() -> Expectation)
nestedLetWithShadowing expectFn _ =
    let
        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body =
                letExpr
                    [ Compiler.AST.SourceBuilder.define "x" [] (intExpr 1) ]
                    (letExpr
                        [ Compiler.AST.SourceBuilder.define "y" [] (binopsExpr [ ( varExpr "x", "+" ) ] (intExpr 2)) ]
                        (letExpr
                            [ Compiler.AST.SourceBuilder.define "z" [] (binopsExpr [ ( varExpr "y", "*" ) ] (intExpr 3)) ]
                            (varExpr "z")
                        )
                    )
            }

        modul =
            makeModuleWithTypedDefs "Test" [ testValueDef ]
    in
    expectFn modul
