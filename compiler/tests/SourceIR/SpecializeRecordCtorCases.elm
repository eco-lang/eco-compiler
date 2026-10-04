module SourceIR.SpecializeRecordCtorCases exposing (expectSuite, suite)

{-| Programs in which a `case` matches a constructor whose argument is a
record, so that the pipeline stage a caller checks, monomorphization in
particular, meets records as constructor arguments.

When a pattern takes an argument out of a constructor, monomorphization types
that argument from the type of the value being matched. The substitution
engine, in `Compiler.Monomorphize.Specialize`, requires that type to be a custom
type and crashes on any other. In six of the eight programs the record a
constructor takes has a field holding a custom-type value, which is matched in
turn, so the patterns alternate between custom types and records on the way
down.

Each case builds one module named `Test` with
`Compiler.AST.SourceBuilder.makeModuleWithTypedDefsUnionsAliases`. It declares
its own custom types and, in most cases, record aliases, one function that
pattern matches, and `testValue : Int`, which applies that function to a value
built from constructors and record literals. The function and `testValue` are
both annotated, and their annotations name only concrete types. The sketches in
the case docstrings are written as Elm source, not as the tree the builders
make.

Most shapes come in two forms. In the _access_ form the constructor pattern
binds the record to a variable and the body reads a field with `.field`. In
the _destruct_ form the constructor pattern holds a record pattern such as
`{ tag, count }`, and the body reads fields through the names the pattern
binds rather than with `.field`.

The module asserts nothing itself. `expectSuite` applies the caller's
expectation to the programs in turn, stopping at the first that fails, and
`suite` applies `TestLogic.TestPipeline.expectMonomorphization`. The cases are:

  - A constructor whose argument is an inline record type, matched in access
    form (`ctorWithRecordField`).
  - A single-constructor type wrapping a record alias whose `tag` field is a
    custom type, matched in access form and in destruct form, followed by a
    `case` on `tag` (`wrapperOverRecordAliasAccess`,
    `wrapperOverRecordAliasDestruct`).
  - A two-constructor type, one of whose constructors takes an inline record
    type, matched in access form (`multiCtorWithRecord`).
  - A wrapper over a record alias whose field is a custom type, one of whose
    constructors wraps a second record alias, matched in access form and in
    destruct form at both levels (`nestedRecordUnionAccess`,
    `nestedRecordUnionDestruct`).
  - A wrapper with a type parameter over a record alias with the same
    parameter, used at a concrete custom type, matched in access form and in
    destruct form (`polyWrapperRecordAccess`, `polyWrapperRecordDestruct`).

Among what is not tested by `suite`: the solver engine
(`Compiler.MonoSolver`), since `expectMonomorphization` monomorphizes with the
substitution engine only; the value `testValue` computes; a function that is
itself polymorphic, since every annotation is concrete; extensible records; and
a record reached through a constructor of a type from another module.

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


{-| The cases of this module, checked with
`TestLogic.TestPipeline.expectMonomorphization`.
-}
suite : Test
suite =
    Test.describe "Specialize.elm record+constructor coverage"
        [ expectSuite expectMonomorphization "monomorphizes record+constructor combos"
        ]


{-| Builds one test, named "Record+constructor specialization " followed by
`condStr`, that checks the cases of this module in order with `expectFn`
through `Compiler.BulkCheck.bulkCheck`. It stops at the first case that fails
and reports only that one.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Record+constructor specialization " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


{-| Returns all eight cases, in the order of the sections below, each checking
its program with `expectFn`.
-}
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


{-| Returns the case of a constructor with an inline record argument, checked
with `expectFn`.
-}
ctorWithRecordFieldCases : (Src.Module -> Expectation) -> List TestCase
ctorWithRecordFieldCases expectFn =
    [ { label = "Constructor with record field", run = ctorWithRecordField expectFn }
    ]


{-| Applies `expectFn` to a program whose constructor takes an inline record
type, matched in access form:

    type Wrapper
        = Wrap { value : Int }

    getValue : Wrapper -> Int
    getValue w =
        case w of
            Wrap r ->
                r.value

    testValue : Int
    testValue =
        getValue (Wrap { value = 42 })

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


{-| Returns the access-form and destruct-form cases of a single-constructor
wrapper over a record alias with a custom-typed field, checked with `expectFn`.
-}
wrapperOverRecordAliasCases : (Src.Module -> Expectation) -> List TestCase
wrapperOverRecordAliasCases expectFn =
    [ { label = "Wrapper over record alias with union field (access)", run = wrapperOverRecordAliasAccess expectFn }
    , { label = "Wrapper over record alias with union field (record destruct)", run = wrapperOverRecordAliasDestruct expectFn }
    ]


{-| Applies `expectFn` to a program in which a single-constructor type wraps a
record alias whose `tag` field is a custom type, matched in access form:

    type Kind
        = A
        | B Int

    type alias Props =
        { tag : Kind, count : Int }

    type Error
        = Error Props

    getTag : Error -> Int
    getTag e =
        case e of
            Error props ->
                case props.tag of
                    A ->
                        0

                    B n ->
                        n

    testValue : Int
    testValue =
        getTag (Error { tag = B 7, count = 1 })

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


{-| Applies `expectFn` to the program of `wrapperOverRecordAliasAccess` with
`getTag` in destruct form: the record pattern binds both fields, and the
`case` is on the bound `tag`.

    getTag : Error -> Int
    getTag e =
        case e of
            Error { tag, count } ->
                case tag of
                    A ->
                        0

                    B n ->
                        n

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


{-| Returns the case of a two-constructor type with an inline record argument,
checked with `expectFn`.
-}
multiCtorRecordCases : (Src.Module -> Expectation) -> List TestCase
multiCtorRecordCases expectFn =
    [ { label = "Multi-constructor union with record field", run = multiCtorWithRecord expectFn }
    ]


{-| Applies `expectFn` to a program with a two-constructor type of its own,
named `Result`, whose `Ok` takes an inline record type, matched in access form:

    type Result
        = Ok { value : Int }
        | Err Int

    extract : Result -> Int
    extract r =
        case r of
            Ok rec ->
                rec.value

            Err code ->
                code

    testValue : Int
    testValue =
        extract (Ok { value = 99 })

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


{-| Returns the access-form and destruct-form cases of two levels of a record
inside a constructor, checked with `expectFn`.
-}
nestedRecordUnionCases : (Src.Module -> Expectation) -> List TestCase
nestedRecordUnionCases expectFn =
    [ { label = "Nested record-through-union (access)", run = nestedRecordUnionAccess expectFn }
    , { label = "Nested record-through-union (destruct)", run = nestedRecordUnionDestruct expectFn }
    ]


{-| Applies `expectFn` to a program with two levels of a record inside
a constructor, matched in access form: `Box` wraps the record alias `Container`,
whose `item` field is an `Outer`, and `Outer`'s `Node` wraps the record alias
`Inner`.

    type alias Inner =
        { x : Int }

    type Outer
        = Leaf
        | Node Inner

    type alias Container =
        { item : Outer }

    type Box
        = Box Container

    unbox : Box -> Int
    unbox box =
        case box of
            Box c ->
                case c.item of
                    Node inner ->
                        inner.x

                    Leaf ->
                        0

    testValue : Int
    testValue =
        unbox (Box { item = Node { x = 55 } })

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


{-| Applies `expectFn` to the program of `nestedRecordUnionAccess` with `unbox`
in destruct form at both levels:

    unbox : Box -> Int
    unbox box =
        case box of
            Box { item } ->
                case item of
                    Node { x } ->
                        x

                    Leaf ->
                        0

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


{-| Returns the access-form and destruct-form cases of a wrapper with a type
parameter over a record alias, checked with `expectFn`.
-}
polyWrapperRecordCases : (Src.Module -> Expectation) -> List TestCase
polyWrapperRecordCases expectFn =
    [ { label = "Poly wrapper over record alias with union field (access)", run = polyWrapperRecordAccess expectFn }
    , { label = "Poly wrapper over record alias with union field (destruct)", run = polyWrapperRecordDestruct expectFn }
    ]


{-| Applies `expectFn` to a program in which a wrapper with a type parameter
holds a record alias with the same parameter, used at the custom type `Kind`
and matched in access form:

    type Kind
        = A
        | B

    type alias Pair a =
        { first : a, second : Int }

    type Wrap a
        = Wrap (Pair a)

    unwrap : Wrap Kind -> Int
    unwrap w =
        case w of
            Wrap p ->
                case p.first of
                    A ->
                        p.second

                    B ->
                        0

    testValue : Int
    testValue =
        unwrap (Wrap { first = A, second = 42 })

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


{-| Applies `expectFn` to the program of `polyWrapperRecordAccess` with `unwrap`
in destruct form:

    unwrap : Wrap Kind -> Int
    unwrap w =
        case w of
            Wrap { first, second } ->
                case first of
                    A ->
                        second

                    B ->
                        0

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
