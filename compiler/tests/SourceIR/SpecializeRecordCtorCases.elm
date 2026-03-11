module SourceIR.SpecializeRecordCtorCases exposing (expectSuite, suite)

{-| Test cases for specialization of constructors containing record types.

These tests cover the interaction between custom type constructors and
record types during monomorphization, specifically:

  - Constructor with a record-typed field
  - Single-constructor wrapper over a record alias with a union field
  - Multi-constructor union with record-typed fields
  - Nested record-through-union patterns
  - Polymorphic wrapper over record alias with union field

The bootstrap crash in Specialize.computeCustomFieldType ("Expected MCustom
but got MRecord") is triggered when pattern matching traverses through a
single-constructor wrapper into a record alias and then into a union field.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( AliasDef
        , TypedDef
        , UnionDef
        , accessExpr
        , callExpr
        , caseExpr
        , ctorExpr
        , intExpr
        , makeModuleWithTypedDefsUnionsAliases
        , pCtor
        , pRecord
        , pVar
        , recordExpr
        , tLambda
        , tRecord
        , tType
        , tVar
        , varExpr
        )
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Expect exposing (Expectation)
import Test exposing (Test)
import TestLogic.TestPipeline exposing (expectMonomorphization)


suite : Test
suite =
    Test.describe "Specialize.elm record+constructor coverage"
        [ expectSuite expectMonomorphization "monomorphizes record+constructor combos"
        ]


{-| Test suite that can be used with different expectation functions.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Record+constructor specialization " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    List.concat
        [ ctorWithRecordFieldCases expectFn
        , wrapperOverRecordAliasCases expectFn
        , multiCtorRecordCases expectFn
        , nestedRecordUnionCases expectFn
        , polyWrapperRecordCases expectFn
        ]



-- ============================================================================
-- CONSTRUCTOR WITH RECORD FIELD
-- ============================================================================


ctorWithRecordFieldCases : (Src.Module -> Expectation) -> List TestCase
ctorWithRecordFieldCases expectFn =
    [ { label = "Constructor with record field", run = ctorWithRecordField expectFn }
    ]


{-| A union constructor whose argument is a record type.
Pattern match extracts a field from the record via access.

    type Wrapper
        = Wrap { name : String, value : Int }

    getValue : Wrapper -> Int
    getValue w =
        case w of
            Wrap r ->
                r.value

-}
ctorWithRecordField : (Src.Module -> Expectation) -> (() -> Expectation)
ctorWithRecordField expectFn _ =
    let
        wrapperUnion : UnionDef
        wrapperUnion =
            { name = "Wrapper"
            , args = []
            , ctors =
                [ { name = "Wrap"
                  , args = [ tRecord [ ( "value", tType "Int" [] ) ] ]
                  }
                ]
            }

        -- getValue : Wrapper -> Int
        getValueDef : TypedDef
        getValueDef =
            { name = "getValue"
            , args = [ pVar "w" ]
            , tipe = tLambda (tType "Wrapper" []) (tType "Int" [])
            , body =
                caseExpr (varExpr "w")
                    [ ( pCtor "Wrap" [ pVar "r" ]
                      , accessExpr (varExpr "r") "value"
                      )
                    ]
            }

        -- testValue : Int
        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body =
                callExpr (varExpr "getValue")
                    [ callExpr (ctorExpr "Wrap")
                        [ recordExpr [ ( "value", intExpr 42 ) ] ]
                    ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ getValueDef, testValueDef ]
                [ wrapperUnion ]
                []
    in
    expectFn modul



-- ============================================================================
-- SINGLE-CONSTRUCTOR WRAPPER OVER RECORD ALIAS WITH UNION FIELD
-- ============================================================================


wrapperOverRecordAliasCases : (Src.Module -> Expectation) -> List TestCase
wrapperOverRecordAliasCases expectFn =
    [ { label = "Wrapper over record alias with union field (access)", run = wrapperOverRecordAliasAccess expectFn }
    , { label = "Wrapper over record alias with union field (record destruct)", run = wrapperOverRecordAliasDestruct expectFn }
    ]


{-| Wrapper over record alias: access pattern.

    type alias Props = { tag : Kind, count : Int }
    type Error = Error Props
    type Kind = A | B Int

    getTag e = case e of Error props -> case props.tag of A -> 0 ; B n -> n

-}
wrapperOverRecordAliasAccess : (Src.Module -> Expectation) -> (() -> Expectation)
wrapperOverRecordAliasAccess expectFn _ =
    let
        kindUnion : UnionDef
        kindUnion =
            { name = "Kind"
            , args = []
            , ctors =
                [ { name = "A", args = [] }
                , { name = "B", args = [ tType "Int" [] ] }
                ]
            }

        propsAlias : AliasDef
        propsAlias =
            { name = "Props"
            , args = []
            , tipe = tRecord [ ( "tag", tType "Kind" [] ), ( "count", tType "Int" [] ) ]
            }

        errorUnion : UnionDef
        errorUnion =
            { name = "Error"
            , args = []
            , ctors =
                [ { name = "Error", args = [ tType "Props" [] ] } ]
            }

        -- getTag : Error -> Int
        getTagDef : TypedDef
        getTagDef =
            { name = "getTag"
            , args = [ pVar "e" ]
            , tipe = tLambda (tType "Error" []) (tType "Int" [])
            , body =
                caseExpr (varExpr "e")
                    [ ( pCtor "Error" [ pVar "props" ]
                      , caseExpr (accessExpr (varExpr "props") "tag")
                            [ ( pCtor "A" [], intExpr 0 )
                            , ( pCtor "B" [ pVar "n" ], varExpr "n" )
                            ]
                      )
                    ]
            }

        -- testValue : Int
        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body =
                callExpr (varExpr "getTag")
                    [ callExpr (ctorExpr "Error")
                        [ recordExpr
                            [ ( "tag", callExpr (ctorExpr "B") [ intExpr 7 ] )
                            , ( "count", intExpr 1 )
                            ]
                        ]
                    ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ getTagDef, testValueDef ]
                [ kindUnion, errorUnion ]
                [ propsAlias ]
    in
    expectFn modul


{-| Direct reproduction of the bootstrap crash pattern.
Record destructuring inside constructor pattern, then case on the bound variable.

    type alias Props = { tag : Kind, count : Int }
    type Error = Error Props
    type Kind = A | B Int

    getTag e = case e of Error { tag } -> case tag of A -> 0 ; B n -> n

This mirrors the pattern in Import.elm:
toReport source (Error { region, name, unimportedModules, problem }) =
case problem of AmbiguousLocal path1 path2 paths -> ...

-}
wrapperOverRecordAliasDestruct : (Src.Module -> Expectation) -> (() -> Expectation)
wrapperOverRecordAliasDestruct expectFn _ =
    let
        kindUnion : UnionDef
        kindUnion =
            { name = "Kind"
            , args = []
            , ctors =
                [ { name = "A", args = [] }
                , { name = "B", args = [ tType "Int" [] ] }
                ]
            }

        propsAlias : AliasDef
        propsAlias =
            { name = "Props"
            , args = []
            , tipe = tRecord [ ( "tag", tType "Kind" [] ), ( "count", tType "Int" [] ) ]
            }

        errorUnion : UnionDef
        errorUnion =
            { name = "Error"
            , args = []
            , ctors =
                [ { name = "Error", args = [ tType "Props" [] ] } ]
            }

        -- getTag : Error -> Int
        -- Uses record destructuring inside constructor pattern
        getTagDef : TypedDef
        getTagDef =
            { name = "getTag"
            , args = [ pVar "e" ]
            , tipe = tLambda (tType "Error" []) (tType "Int" [])
            , body =
                caseExpr (varExpr "e")
                    [ ( pCtor "Error" [ pRecord [ "tag", "count" ] ]
                      , caseExpr (varExpr "tag")
                            [ ( pCtor "A" [], intExpr 0 )
                            , ( pCtor "B" [ pVar "n" ], varExpr "n" )
                            ]
                      )
                    ]
            }

        -- testValue : Int
        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body =
                callExpr (varExpr "getTag")
                    [ callExpr (ctorExpr "Error")
                        [ recordExpr
                            [ ( "tag", callExpr (ctorExpr "B") [ intExpr 7 ] )
                            , ( "count", intExpr 1 )
                            ]
                        ]
                    ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ getTagDef, testValueDef ]
                [ kindUnion, errorUnion ]
                [ propsAlias ]
    in
    expectFn modul



-- ============================================================================
-- MULTI-CONSTRUCTOR UNION WITH RECORD FIELD
-- ============================================================================


multiCtorRecordCases : (Src.Module -> Expectation) -> List TestCase
multiCtorRecordCases expectFn =
    [ { label = "Multi-constructor union with record field", run = multiCtorWithRecord expectFn }
    ]


{-| Multiple constructors where one holds a record.

    type Result
        = Ok { value : Int }
        | Err Int

    extract : Result -> Int

-}
multiCtorWithRecord : (Src.Module -> Expectation) -> (() -> Expectation)
multiCtorWithRecord expectFn _ =
    let
        resultUnion : UnionDef
        resultUnion =
            { name = "Result"
            , args = []
            , ctors =
                [ { name = "Ok"
                  , args = [ tRecord [ ( "value", tType "Int" [] ) ] ]
                  }
                , { name = "Err", args = [ tType "Int" [] ] }
                ]
            }

        -- extract : Result -> Int
        extractDef : TypedDef
        extractDef =
            { name = "extract"
            , args = [ pVar "r" ]
            , tipe = tLambda (tType "Result" []) (tType "Int" [])
            , body =
                caseExpr (varExpr "r")
                    [ ( pCtor "Ok" [ pVar "rec" ]
                      , accessExpr (varExpr "rec") "value"
                      )
                    , ( pCtor "Err" [ pVar "code" ], varExpr "code" )
                    ]
            }

        -- testValue : Int
        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body =
                callExpr (varExpr "extract")
                    [ callExpr (ctorExpr "Ok")
                        [ recordExpr [ ( "value", intExpr 99 ) ] ]
                    ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ extractDef, testValueDef ]
                [ resultUnion ]
                []
    in
    expectFn modul



-- ============================================================================
-- NESTED RECORD ALIAS THROUGH UNION FIELD
-- ============================================================================


nestedRecordUnionCases : (Src.Module -> Expectation) -> List TestCase
nestedRecordUnionCases expectFn =
    [ { label = "Nested record-through-union (access)", run = nestedRecordUnionAccess expectFn }
    , { label = "Nested record-through-union (destruct)", run = nestedRecordUnionDestruct expectFn }
    ]


{-| Two levels of record-through-union nesting, access pattern.

    type alias Inner = { x : Int }
    type Outer = Leaf | Node Inner
    type alias Container = { item : Outer }
    type Box = Box Container

    unbox box = case box of Box c -> case c.item of Node inner -> inner.x ; Leaf -> 0

-}
nestedRecordUnionAccess : (Src.Module -> Expectation) -> (() -> Expectation)
nestedRecordUnionAccess expectFn _ =
    let
        innerAlias : AliasDef
        innerAlias =
            { name = "Inner"
            , args = []
            , tipe = tRecord [ ( "x", tType "Int" [] ) ]
            }

        outerUnion : UnionDef
        outerUnion =
            { name = "Outer"
            , args = []
            , ctors =
                [ { name = "Leaf", args = [] }
                , { name = "Node", args = [ tType "Inner" [] ] }
                ]
            }

        containerAlias : AliasDef
        containerAlias =
            { name = "Container"
            , args = []
            , tipe = tRecord [ ( "item", tType "Outer" [] ) ]
            }

        boxUnion : UnionDef
        boxUnion =
            { name = "Box"
            , args = []
            , ctors =
                [ { name = "Box", args = [ tType "Container" [] ] } ]
            }

        -- unbox : Box -> Int
        unboxDef : TypedDef
        unboxDef =
            { name = "unbox"
            , args = [ pVar "box" ]
            , tipe = tLambda (tType "Box" []) (tType "Int" [])
            , body =
                caseExpr (varExpr "box")
                    [ ( pCtor "Box" [ pVar "c" ]
                      , caseExpr (accessExpr (varExpr "c") "item")
                            [ ( pCtor "Node" [ pVar "inner" ]
                              , accessExpr (varExpr "inner") "x"
                              )
                            , ( pCtor "Leaf" [], intExpr 0 )
                            ]
                      )
                    ]
            }

        -- testValue : Int
        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body =
                callExpr (varExpr "unbox")
                    [ callExpr (ctorExpr "Box")
                        [ recordExpr
                            [ ( "item"
                              , callExpr (ctorExpr "Node")
                                    [ recordExpr [ ( "x", intExpr 55 ) ] ]
                              )
                            ]
                        ]
                    ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ unboxDef, testValueDef ]
                [ outerUnion, boxUnion ]
                [ innerAlias, containerAlias ]
    in
    expectFn modul


{-| Same pattern but with record destructuring inside the constructor pattern.

    unbox box = case box of Box { item } -> case item of Node { x } -> x ; Leaf -> 0

-}
nestedRecordUnionDestruct : (Src.Module -> Expectation) -> (() -> Expectation)
nestedRecordUnionDestruct expectFn _ =
    let
        innerAlias : AliasDef
        innerAlias =
            { name = "Inner"
            , args = []
            , tipe = tRecord [ ( "x", tType "Int" [] ) ]
            }

        outerUnion : UnionDef
        outerUnion =
            { name = "Outer"
            , args = []
            , ctors =
                [ { name = "Leaf", args = [] }
                , { name = "Node", args = [ tType "Inner" [] ] }
                ]
            }

        containerAlias : AliasDef
        containerAlias =
            { name = "Container"
            , args = []
            , tipe = tRecord [ ( "item", tType "Outer" [] ) ]
            }

        boxUnion : UnionDef
        boxUnion =
            { name = "Box"
            , args = []
            , ctors =
                [ { name = "Box", args = [ tType "Container" [] ] } ]
            }

        -- unbox : Box -> Int
        -- Uses record destructuring inside constructor patterns
        unboxDef : TypedDef
        unboxDef =
            { name = "unbox"
            , args = [ pVar "box" ]
            , tipe = tLambda (tType "Box" []) (tType "Int" [])
            , body =
                caseExpr (varExpr "box")
                    [ ( pCtor "Box" [ pRecord [ "item" ] ]
                      , caseExpr (varExpr "item")
                            [ ( pCtor "Node" [ pRecord [ "x" ] ]
                              , varExpr "x"
                              )
                            , ( pCtor "Leaf" [], intExpr 0 )
                            ]
                      )
                    ]
            }

        -- testValue : Int
        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body =
                callExpr (varExpr "unbox")
                    [ callExpr (ctorExpr "Box")
                        [ recordExpr
                            [ ( "item"
                              , callExpr (ctorExpr "Node")
                                    [ recordExpr [ ( "x", intExpr 55 ) ] ]
                              )
                            ]
                        ]
                    ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ unboxDef, testValueDef ]
                [ outerUnion, boxUnion ]
                [ innerAlias, containerAlias ]
    in
    expectFn modul



-- ============================================================================
-- POLYMORPHIC WRAPPER OVER RECORD ALIAS WITH UNION FIELD
-- ============================================================================


polyWrapperRecordCases : (Src.Module -> Expectation) -> List TestCase
polyWrapperRecordCases expectFn =
    [ { label = "Poly wrapper over record alias with union field (access)", run = polyWrapperRecordAccess expectFn }
    , { label = "Poly wrapper over record alias with union field (destruct)", run = polyWrapperRecordDestruct expectFn }
    ]


{-| Polymorphic wrapper: access pattern.

    type alias Pair a = { first : a, second : Int }
    type Kind = A | B
    type Wrap a = Wrap (Pair a)

    unwrap w = case w of Wrap p -> case p.first of A -> p.second ; B -> 0

-}
polyWrapperRecordAccess : (Src.Module -> Expectation) -> (() -> Expectation)
polyWrapperRecordAccess expectFn _ =
    let
        kindUnion : UnionDef
        kindUnion =
            { name = "Kind"
            , args = []
            , ctors =
                [ { name = "A", args = [] }
                , { name = "B", args = [] }
                ]
            }

        pairAlias : AliasDef
        pairAlias =
            { name = "Pair"
            , args = [ "a" ]
            , tipe = tRecord [ ( "first", tVar "a" ), ( "second", tType "Int" [] ) ]
            }

        wrapUnion : UnionDef
        wrapUnion =
            { name = "Wrap"
            , args = [ "a" ]
            , ctors =
                [ { name = "Wrap", args = [ tType "Pair" [ tVar "a" ] ] } ]
            }

        -- unwrap : Wrap Kind -> Int
        unwrapDef : TypedDef
        unwrapDef =
            { name = "unwrap"
            , args = [ pVar "w" ]
            , tipe = tLambda (tType "Wrap" [ tType "Kind" [] ]) (tType "Int" [])
            , body =
                caseExpr (varExpr "w")
                    [ ( pCtor "Wrap" [ pVar "p" ]
                      , caseExpr (accessExpr (varExpr "p") "first")
                            [ ( pCtor "A" [], accessExpr (varExpr "p") "second" )
                            , ( pCtor "B" [], intExpr 0 )
                            ]
                      )
                    ]
            }

        -- testValue : Int
        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body =
                callExpr (varExpr "unwrap")
                    [ callExpr (ctorExpr "Wrap")
                        [ recordExpr
                            [ ( "first", ctorExpr "A" )
                            , ( "second", intExpr 42 )
                            ]
                        ]
                    ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ unwrapDef, testValueDef ]
                [ kindUnion, wrapUnion ]
                [ pairAlias ]
    in
    expectFn modul


{-| Polymorphic wrapper: record destructuring pattern.

    unwrap w = case w of Wrap { first, second } -> case first of A -> second ; B -> 0

-}
polyWrapperRecordDestruct : (Src.Module -> Expectation) -> (() -> Expectation)
polyWrapperRecordDestruct expectFn _ =
    let
        kindUnion : UnionDef
        kindUnion =
            { name = "Kind"
            , args = []
            , ctors =
                [ { name = "A", args = [] }
                , { name = "B", args = [] }
                ]
            }

        pairAlias : AliasDef
        pairAlias =
            { name = "Pair"
            , args = [ "a" ]
            , tipe = tRecord [ ( "first", tVar "a" ), ( "second", tType "Int" [] ) ]
            }

        wrapUnion : UnionDef
        wrapUnion =
            { name = "Wrap"
            , args = [ "a" ]
            , ctors =
                [ { name = "Wrap", args = [ tType "Pair" [ tVar "a" ] ] } ]
            }

        -- unwrap : Wrap Kind -> Int
        -- Uses record destructuring inside constructor pattern
        unwrapDef : TypedDef
        unwrapDef =
            { name = "unwrap"
            , args = [ pVar "w" ]
            , tipe = tLambda (tType "Wrap" [ tType "Kind" [] ]) (tType "Int" [])
            , body =
                caseExpr (varExpr "w")
                    [ ( pCtor "Wrap" [ pRecord [ "first", "second" ] ]
                      , caseExpr (varExpr "first")
                            [ ( pCtor "A" [], varExpr "second" )
                            , ( pCtor "B" [], intExpr 0 )
                            ]
                      )
                    ]
            }

        -- testValue : Int
        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body =
                callExpr (varExpr "unwrap")
                    [ callExpr (ctorExpr "Wrap")
                        [ recordExpr
                            [ ( "first", ctorExpr "A" )
                            , ( "second", intExpr 42 )
                            ]
                        ]
                    ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ unwrapDef, testValueDef ]
                [ kindUnion, wrapUnion ]
                [ pairAlias ]
    in
    expectFn modul
