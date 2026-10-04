module SourceIR.MonoCompoundCases exposing (expectSuite)

{-| Small programs whose values have compound types (records, tuples, lists and
custom types with type parameters), most of them with a polymorphic function
that takes or returns a compound type built from its type variables.
Without them, a compiler stage that mishandles a compound type built from a
type variable, or a value of compound type, could go unnoticed by the stage
tests that run this module.

Monomorphization, the stage the test name refers to, makes a separate copy of a
polymorphic function for each concrete type it is used at; each copy is a
_specialization_. This module builds the programs and checks nothing itself:
`expectSuite` hands each program to the expectation function its caller
supplies, and that function decides which stage is run and what is asserted.

Each program is a module named `Test` built with
`Compiler.AST.SourceBuilder`, importing that builder's standard set of
modules. Every top-level value has a type annotation, and every program has a
`testValue` whose annotation has no type variable. The programs, by label:

  - "poly record builder": `makeRec : a -> b -> { first : a, second : b }`,
    with `testValue = makeRec 1 "hello"` at `{ first : Int, second : String }`.
  - "poly tuple builder": `swap : ( a, b ) -> ( b, a )`, taking its argument
    by a tuple pattern, with `testValue = swap ( 42, "answer" )`.
  - "record update in let": `increment : { x : Int, y : Int } -> { x : Int, y : Int }`,
    which is `{ r | x = r.x + 1 }`, and a `testValue` that binds
    `p = { x = 0, y = 10 }` in a `let` and returns `increment p`. The record
    update is in `increment`, which is not polymorphic.
  - "unused poly function (prune)": `unusedId : a -> a`, which nothing
    references, beside `used : Int -> Int` and `testValue = used 5`.
  - "list of records": `testValue` is a literal list of three `{ x : Int }`
    records. There is no polymorphic function.
  - "nested maybe pattern": declares `type MyMaybe a = MyJust a | MyNothing`
    and `fromMyMaybe : a -> MyMaybe a -> a`, a `case` with one branch per
    constructor, with `testValue = fromMyMaybe 0 (MyJust 42)`. No pattern is
    nested.
  - "poly function with record arg": `getFirst : { first : a, second : b } -> a`,
    which is `r.first`, applied to `{ first = 99, second = "ignore" }`.
  - "multi-field record specialization":
    `wrap3 : a -> b -> c -> { x : a, y : b, z : c }`, called once, as
    `wrap3 1 "mid" 3`.
  - "tuple in list specialization": `testValue` is a literal
    `List ( Int, String )` of two tuples. There is no polymorphic function.
  - "poly function three specializations": `wrap : a -> List a`, and a
    `testValue` whose `let` binds `ints = wrap 1`, `strs = wrap "hi"` and
    `bools = wrap True` and returns `ints`. `strs` and `bools` are never used.
  - "custom type with poly field": declares `type Pair a b = MkPair a b` and
    `fstPair : Pair a b -> a`, which matches `MkPair x _`, with
    `testValue = fstPair (MkPair 10 "world")`.
  - "nested let with shadowing": three nested `let`s binding `x = 1`,
    `y = x + 2` and `z = y * 3`, returning `z`. The names are distinct, so
    nothing is shadowed.

Among what is not tested: shadowing; a nested pattern; a polymorphic
function's type variable filled with a compound type; a polymorphic function
used at more than one type, except `wrap`, whose two other uses are bound to
names that are never used; extensible record types; and a record update on a
record of polymorphic type.

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


{-| Builds one test, named "Mono compound type specialization " followed by
`condStr`, that runs `expectFn` on each program of this module in the order
`testCases` lists them.

The test is a `Compiler.BulkCheck.bulkCheck`, so it fails with the label of the
first program whose expectation fails, and the programs after it are not run.

-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Mono compound type specialization " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


{-| Returns the twelve labelled cases, each of which runs `expectFn` on one of
the programs the module docstring lists.
-}
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


{-| Returns the check that runs `expectFn` on a module declaring
`makeRec : a -> b -> { first : a, second : b }` and
`testValue = makeRec 1 "hello"`, annotated `{ first : Int, second : String }`.
-}
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


{-| Returns the check that runs `expectFn` on a module declaring
`swap : ( a, b ) -> ( b, a )`, whose argument is a tuple pattern, and
`testValue = swap ( 42, "answer" )`, annotated `( String, Int )`.
-}
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
-- Record update in a function applied to a let-bound record
-- ============================================================================


{-| Returns the check that runs `expectFn` on a module declaring
`increment r = { r | x = r.x + 1 }` on `{ x : Int, y : Int }`, and a
`testValue` that binds `p = { x = 0, y = 10 }` in a `let` and returns
`increment p`.
-}
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
-- Unused polymorphic top-level function
-- ============================================================================


{-| Returns the check that runs `expectFn` on a module declaring
`unusedId : a -> a`, which nothing references, `used : Int -> Int`, which is
`n + 1`, and `testValue = used 5`.
-}
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


{-| Returns the check that runs `expectFn` on a module whose only value is
`testValue : List { x : Int }`, a literal list of three records.
-}
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
-- Single-level match on a Maybe-like custom type
-- ============================================================================


{-| Returns the check that runs `expectFn` on a module declaring
`type MyMaybe a = MyJust a | MyNothing`, `fromMyMaybe : a -> MyMaybe a -> a`,
which returns the `MyJust` payload or else its first argument, and
`testValue = fromMyMaybe 0 (MyJust 42)`. The `case` has one single-level
branch per constructor; no pattern is nested.
-}
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


{-| Returns the check that runs `expectFn` on a module declaring
`getFirst : { first : a, second : b } -> a`, which is `r.first`, and
`testValue = getFirst { first = 99, second = "ignore" }`.
-}
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
-- Polymorphic function building a three-field record
-- ============================================================================


{-| Returns the check that runs `expectFn` on a module declaring
`wrap3 : a -> b -> c -> { x : a, y : b, z : c }` and
`testValue = wrap3 1 "mid" 3`, annotated `{ x : Int, y : String, z : Int }`.
`wrap3` is called only once.
-}
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
-- List of tuples
-- ============================================================================


{-| Returns the check that runs `expectFn` on a module whose only value is
`testValue : List ( Int, String )`, a literal list of two tuples.
-}
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
-- Polymorphic function applied at three types
-- ============================================================================


{-| Returns the check that runs `expectFn` on a module declaring
`wrap : a -> List a` and a `testValue : List Int` whose `let` binds
`ints = wrap 1`, `strs = wrap "hi"` and `bools = wrap True`, and returns
`ints`. `strs` and `bools` are never used.
-}
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


{-| Returns the check that runs `expectFn` on a module declaring
`type Pair a b = MkPair a b`, `fstPair : Pair a b -> a`, which matches
`MkPair x _`, and `testValue = fstPair (MkPair 10 "world")`.
-}
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
-- Nested lets with distinct names
-- ============================================================================


{-| Returns the check that runs `expectFn` on a module whose only value is a
`testValue : Int` made of three nested `let`s, binding `x = 1`, `y = x + 2`
and `z = y * 3`, and returning `z`. The three names are distinct, so nothing is
shadowed.
-}
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
