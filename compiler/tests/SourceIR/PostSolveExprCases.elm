module SourceIR.PostSolveExprCases exposing (expectSuite)

{-| The type checker records a type for each expression node, and after solving
the post-solve pass (`Compiler.Type.PostSolve`) rewrites some of them, such as
those of string, character, float and unit literals. A form of expression that
no test program contains is a form whose node types no checker ever sees. This
module supplies small programs, grouped by expression form, so that a checker
can be run over each form.

The tests assert nothing themselves. Every test builds a `Src.Module` with
`Compiler.AST.SourceBuilder` and hands it to the expectation function given to
`expectSuite`, which decides which compiler stages run and what is checked.
Most programs are built with `makeModule`: a module `Test`, importing `Basics`
and `List`, whose one value `testValue` is an unannotated expression. The rest
are built with `makeModuleWithTypedDefs` or
`makeModuleWithTypedDefsUnionsAliases`, where every top-level value is
annotated, `testValue` included. An integer literal has type `number` unless
something fixes it to `Int`, such as an annotation or an integer pattern in a
`case`; in most of the unannotated programs nothing does.

The groups, each a `Test.describe`, are:

  - Literals: `testValue` is a string, a character, a float, `()`, an integer
    and `True`, one per test.
  - Structures: an empty list annotated `List Int`, lists of one and of three
    integers, a pair, a triple, a record with one field, a record inside a
    record, and a record with an integer, a string and a `Bool` field.
  - Functions: annotated top-level functions that `testValue` calls. They take
    one argument (`increment`) or two (`add`), return a lambda (`makeAdder`,
    the only one whose body is a lambda expression), are polymorphic
    (`identity : a -> a`, applied to an integer), take a record (`getX`) or
    return a pair (`pair`).
  - Accessors: one field access on a record literal, chains of two and three
    accesses into nested records, and the accessor `.field` as the whole body
    of an annotated top-level value that `testValue` calls.
  - Let: one definition, a `let` nested in a `let` body, a local function,
    destructuring of a pair and of a record, and three definitions used in one
    sum.
  - Control flow: an `if`, an `if` nested in a `then` branch, an `if` whose two
    branches are records of the same type `{ value : Int }`, and three `case`
    expressions: on an integer with two literal branches and a wildcard, on an
    integer with five literal branches and a wildcard, and on a pair with tuple
    patterns.
  - Record update: one field replaced, two fields of three replaced, a field
    replaced by a value computed from its old value, and a field holding a
    record replaced by a new record.
  - Calls, all to annotated top-level functions: a plain call to the
    module's own `negate`, a call as another call's argument, a function
    passed to a higher-order function, a partial application bound to a
    top-level value and then called, and a call with a record argument.
  - Operators: `1 + 2`, `5 > 3`, `True && False`, `1 + 2 + 3 + 4` and
    `2 * 3 + 4`, each one flat operator chain.
  - Negation: of an integer literal, of a float literal, and of a negation.
    The last is a `Negate` directly inside a `Negate`, a shape the parser
    never builds, since it negates only a term.
  - Annotation forms: annotations containing `()`, a type alias of a record,
    and an extensible record. When the program is type checked, each of these
    is converted by `Compiler.Type.Instantiate.fromSrcType`, which has a
    separate arm for unit, alias and record types.

Among what is not tested: `case` on a custom type or on string, character or
list patterns; operators used as values; qualified references other than
`True` and `False`; annotated or recursive `let` definitions; kernel
references.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( AliasDef
        , TypedDef
        , accessExpr
        , accessorExpr
        , binopsExpr
        , boolExpr
        , callExpr
        , caseExpr
        , chrExpr
        , define
        , destruct
        , floatExpr
        , ifExpr
        , intExpr
        , lambdaExpr
        , letExpr
        , listExpr
        , makeModule
        , makeModuleWithTypedDefs
        , makeModuleWithTypedDefsUnionsAliases
        , negateExpr
        , pAnything
        , pInt
        , pRecord
        , pTuple
        , pVar
        , recordExpr
        , strExpr
        , tExtRecord
        , tLambda
        , tRecord
        , tTuple
        , tType
        , tUnit
        , tVar
        , tuple3Expr
        , tupleExpr
        , unitExpr
        , updateExpr
        , varExpr
        )
import Expect exposing (Expectation)
import Test exposing (Test)


{-| Builds the whole suite: one group per expression form, each test applying
`expectFn` to its program. `condStr` is appended to the name of every group
and every test, so it should say what `expectFn` checks.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.describe ("PostSolve expression types " ++ condStr)
        [ literalTypeTests expectFn condStr
        , structuralTypeTests expectFn condStr
        , lambdaTypeTests expectFn condStr
        , accessorTypeTests expectFn condStr
        , letBindingTypeTests expectFn condStr
        , controlFlowTypeTests expectFn condStr
        , recordUpdateTypeTests expectFn condStr
        , callTypeTests expectFn condStr
        , binopTypeTests expectFn condStr
        , negateTypeTests expectFn condStr
        , instantiateEdgeCaseTests expectFn condStr
        ]



-- ============================================================================
-- LITERAL TYPE TESTS (6 tests)
-- ============================================================================


{-| Groups the literal tests, with `condStr` appended to every name.
-}
literalTypeTests : (Src.Module -> Expectation) -> String -> Test
literalTypeTests expectFn condStr =
    Test.describe ("Literal types " ++ condStr)
        [ Test.test ("String literal type " ++ condStr) (stringLiteralType expectFn)
        , Test.test ("Char literal type " ++ condStr) (charLiteralType expectFn)
        , Test.test ("Float literal type " ++ condStr) (floatLiteralType expectFn)
        , Test.test ("Unit literal type " ++ condStr) (unitLiteralType expectFn)
        , Test.test ("Int literal type " ++ condStr) (intLiteralType expectFn)
        , Test.test ("Bool literal type " ++ condStr) (boolLiteralType expectFn)
        ]


{-| Passes `expectFn` a module whose `testValue` is the string literal
`"hello world"`.
-}
stringLiteralType : (Src.Module -> Expectation) -> (() -> Expectation)
stringLiteralType expectFn _ =
    let
        modul =
            makeModule "testValue" (strExpr "hello world")
    in
    expectFn modul


{-| Passes `expectFn` a module whose `testValue` is the character literal `'x'`.
-}
charLiteralType : (Src.Module -> Expectation) -> (() -> Expectation)
charLiteralType expectFn _ =
    let
        modul =
            makeModule "testValue" (chrExpr "x")
    in
    expectFn modul


{-| Passes `expectFn` a module whose `testValue` is the float literal `3.14159`.
-}
floatLiteralType : (Src.Module -> Expectation) -> (() -> Expectation)
floatLiteralType expectFn _ =
    let
        modul =
            makeModule "testValue" (floatExpr 3.14159)
    in
    expectFn modul


{-| Passes `expectFn` a module whose `testValue` is `()`.
-}
unitLiteralType : (Src.Module -> Expectation) -> (() -> Expectation)
unitLiteralType expectFn _ =
    let
        modul =
            makeModule "testValue" unitExpr
    in
    expectFn modul


{-| Passes `expectFn` a module whose `testValue` is the integer literal `42`,
unannotated, so of type `number`.
-}
intLiteralType : (Src.Module -> Expectation) -> (() -> Expectation)
intLiteralType expectFn _ =
    let
        modul =
            makeModule "testValue" (intExpr 42)
    in
    expectFn modul


{-| Passes `expectFn` a module whose `testValue` is `True`, built as the
qualified constructor `Basics.True`.
-}
boolLiteralType : (Src.Module -> Expectation) -> (() -> Expectation)
boolLiteralType expectFn _ =
    let
        modul =
            makeModule "testValue" (boolExpr True)
    in
    expectFn modul



-- ============================================================================
-- STRUCTURAL TYPE TESTS (8 tests)
-- ============================================================================


{-| Groups the list, tuple and record literal tests, with `condStr` appended to
every name.
-}
structuralTypeTests : (Src.Module -> Expectation) -> String -> Test
structuralTypeTests expectFn condStr =
    Test.describe ("Structural types " ++ condStr)
        [ Test.test ("Empty list type " ++ condStr) (emptyListType expectFn)
        , Test.test ("Singleton list type " ++ condStr) (singletonListType expectFn)
        , Test.test ("Multiple element list type " ++ condStr) (multipleElementListType expectFn)
        , Test.test ("Tuple2 type " ++ condStr) (tuple2Type expectFn)
        , Test.test ("Tuple3 type " ++ condStr) (tuple3Type expectFn)
        , Test.test ("Simple record type " ++ condStr) (simpleRecordType expectFn)
        , Test.test ("Nested record type " ++ condStr) (nestedRecordType expectFn)
        , Test.test ("Multi-field record type " ++ condStr) (multiFieldRecordType expectFn)
        ]


{-| Passes `expectFn` a module whose `testValue` is `[]`, annotated `List Int`
so that the element type is fixed.
-}
emptyListType : (Src.Module -> Expectation) -> (() -> Expectation)
emptyListType expectFn _ =
    let
        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "List" [ tType "Int" [] ]
            , body = listExpr []
            }

        modul =
            makeModuleWithTypedDefs "Test" [ testValueDef ]
    in
    expectFn modul


{-| Passes `expectFn` a module whose `testValue` is `[ 1 ]`.
-}
singletonListType : (Src.Module -> Expectation) -> (() -> Expectation)
singletonListType expectFn _ =
    let
        modul =
            makeModule "testValue" (listExpr [ intExpr 1 ])
    in
    expectFn modul


{-| Passes `expectFn` a module whose `testValue` is `[ 1, 2, 3 ]`.
-}
multipleElementListType : (Src.Module -> Expectation) -> (() -> Expectation)
multipleElementListType expectFn _ =
    let
        modul =
            makeModule "testValue" (listExpr [ intExpr 1, intExpr 2, intExpr 3 ])
    in
    expectFn modul


{-| Passes `expectFn` a module whose `testValue` is `( 1, "hello" )`.
-}
tuple2Type : (Src.Module -> Expectation) -> (() -> Expectation)
tuple2Type expectFn _ =
    let
        modul =
            makeModule "testValue" (tupleExpr (intExpr 1) (strExpr "hello"))
    in
    expectFn modul


{-| Passes `expectFn` a module whose `testValue` is `( 1, "hello", True )`.
-}
tuple3Type : (Src.Module -> Expectation) -> (() -> Expectation)
tuple3Type expectFn _ =
    let
        modul =
            makeModule "testValue" (tuple3Expr (intExpr 1) (strExpr "hello") (boolExpr True))
    in
    expectFn modul


{-| Passes `expectFn` a module whose `testValue` is `{ x = 10 }`.
-}
simpleRecordType : (Src.Module -> Expectation) -> (() -> Expectation)
simpleRecordType expectFn _ =
    let
        modul =
            makeModule "testValue" (recordExpr [ ( "x", intExpr 10 ) ])
    in
    expectFn modul


{-| Passes `expectFn` a module whose `testValue` is
`{ outer = { inner = 42 } }`.
-}
nestedRecordType : (Src.Module -> Expectation) -> (() -> Expectation)
nestedRecordType expectFn _ =
    let
        modul =
            makeModule "testValue"
                (recordExpr
                    [ ( "outer"
                      , recordExpr
                            [ ( "inner", intExpr 42 )
                            ]
                      )
                    ]
                )
    in
    expectFn modul


{-| Passes `expectFn` a module whose `testValue` is
`{ a = 1, b = "two", c = True }`.
-}
multiFieldRecordType : (Src.Module -> Expectation) -> (() -> Expectation)
multiFieldRecordType expectFn _ =
    let
        modul =
            makeModule "testValue"
                (recordExpr
                    [ ( "a", intExpr 1 )
                    , ( "b", strExpr "two" )
                    , ( "c", boolExpr True )
                    ]
                )
    in
    expectFn modul



-- ============================================================================
-- LAMBDA TYPE TESTS (6 tests)
-- ============================================================================


{-| Groups the tests of annotated top-level functions, with `condStr` appended to
every name. Despite the group's name, only one of them contains a lambda
expression.
-}
lambdaTypeTests : (Src.Module -> Expectation) -> String -> Test
lambdaTypeTests expectFn condStr =
    Test.describe ("Lambda types " ++ condStr)
        [ Test.test ("Simple lambda type " ++ condStr) (simpleLambdaType expectFn)
        , Test.test ("Multi-arg lambda type " ++ condStr) (multiArgLambdaType expectFn)
        , Test.test ("Lambda returning lambda type " ++ condStr) (lambdaReturningLambdaType expectFn)
        , Test.test ("Identity lambda type " ++ condStr) (identityLambdaType expectFn)
        , Test.test ("Lambda with record arg type " ++ condStr) (lambdaWithRecordArgType expectFn)
        , Test.test ("Lambda with tuple result type " ++ condStr) (lambdaWithTupleResultType expectFn)
        ]


{-| Passes `expectFn` a module with `increment : Int -> Int`, defined as
`increment x = x + 1`, and `testValue : Int` defined as `increment 5`.
-}
simpleLambdaType : (Src.Module -> Expectation) -> (() -> Expectation)
simpleLambdaType expectFn _ =
    let
        incrementDef : TypedDef
        incrementDef =
            { name = "increment"
            , args = [ pVar "x" ]
            , tipe = tLambda (tType "Int" []) (tType "Int" [])
            , body = binopsExpr [ ( varExpr "x", "+" ) ] (intExpr 1)
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "increment") [ intExpr 5 ]
            }

        modul =
            makeModuleWithTypedDefs "Test" [ incrementDef, testValueDef ]
    in
    expectFn modul


{-| Passes `expectFn` a module with `add : Int -> Int -> Int`, defined as
`add a b = a + b`, and `testValue : Int` defined as `add 3 4`.
-}
multiArgLambdaType : (Src.Module -> Expectation) -> (() -> Expectation)
multiArgLambdaType expectFn _ =
    let
        addDef : TypedDef
        addDef =
            { name = "add"
            , args = [ pVar "a", pVar "b" ]
            , tipe = tLambda (tType "Int" []) (tLambda (tType "Int" []) (tType "Int" []))
            , body = binopsExpr [ ( varExpr "a", "+" ) ] (varExpr "b")
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "add") [ intExpr 3, intExpr 4 ]
            }

        modul =
            makeModuleWithTypedDefs "Test" [ addDef, testValueDef ]
    in
    expectFn modul


{-| Passes `expectFn` a module with `makeAdder : Int -> Int -> Int`, defined as
`makeAdder n = \x -> x + n`, and `testValue : Int` defined as
`(makeAdder 10) 5`, a call whose function is itself a call.
-}
lambdaReturningLambdaType : (Src.Module -> Expectation) -> (() -> Expectation)
lambdaReturningLambdaType expectFn _ =
    let
        makeAdderDef : TypedDef
        makeAdderDef =
            { name = "makeAdder"
            , args = [ pVar "n" ]
            , tipe = tLambda (tType "Int" []) (tLambda (tType "Int" []) (tType "Int" []))
            , body = lambdaExpr [ pVar "x" ] (binopsExpr [ ( varExpr "x", "+" ) ] (varExpr "n"))
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (callExpr (varExpr "makeAdder") [ intExpr 10 ]) [ intExpr 5 ]
            }

        modul =
            makeModuleWithTypedDefs "Test" [ makeAdderDef, testValueDef ]
    in
    expectFn modul


{-| Passes `expectFn` a module with `identity : a -> a`, defined as
`identity x = x`, and `testValue : Int` defined as `identity 42`.
-}
identityLambdaType : (Src.Module -> Expectation) -> (() -> Expectation)
identityLambdaType expectFn _ =
    let
        identityDef : TypedDef
        identityDef =
            { name = "identity"
            , args = [ pVar "x" ]
            , tipe = tLambda (tVar "a") (tVar "a")
            , body = varExpr "x"
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "identity") [ intExpr 42 ]
            }

        modul =
            makeModuleWithTypedDefs "Test" [ identityDef, testValueDef ]
    in
    expectFn modul


{-| Passes `expectFn` a module with `getX : { x : Int } -> Int`, defined as
`getX r = r.x`, and `testValue : Int` defined as `getX { x = 10 }`.
-}
lambdaWithRecordArgType : (Src.Module -> Expectation) -> (() -> Expectation)
lambdaWithRecordArgType expectFn _ =
    let
        getXDef : TypedDef
        getXDef =
            { name = "getX"
            , args = [ pVar "r" ]
            , tipe = tLambda (tRecord [ ( "x", tType "Int" [] ) ]) (tType "Int" [])
            , body = accessExpr (varExpr "r") "x"
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "getX") [ recordExpr [ ( "x", intExpr 10 ) ] ]
            }

        modul =
            makeModuleWithTypedDefs "Test" [ getXDef, testValueDef ]
    in
    expectFn modul


{-| Passes `expectFn` a module with `pair : Int -> ( Int, Int )`, defined as
`pair x = ( x, x )`, and `testValue : ( Int, Int )` defined as `pair 7`.
-}
lambdaWithTupleResultType : (Src.Module -> Expectation) -> (() -> Expectation)
lambdaWithTupleResultType expectFn _ =
    let
        pairDef : TypedDef
        pairDef =
            { name = "pair"
            , args = [ pVar "x" ]
            , tipe = tLambda (tType "Int" []) (tTuple (tType "Int" []) (tType "Int" []))
            , body = tupleExpr (varExpr "x") (varExpr "x")
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tTuple (tType "Int" []) (tType "Int" [])
            , body = callExpr (varExpr "pair") [ intExpr 7 ]
            }

        modul =
            makeModuleWithTypedDefs "Test" [ pairDef, testValueDef ]
    in
    expectFn modul



-- ============================================================================
-- ACCESSOR TYPE TESTS (4 tests)
-- ============================================================================


{-| Groups the field access and accessor function tests, with `condStr`
appended to every name.
-}
accessorTypeTests : (Src.Module -> Expectation) -> String -> Test
accessorTypeTests expectFn condStr =
    Test.describe ("Accessor types " ++ condStr)
        [ Test.test ("Simple accessor type " ++ condStr) (simpleAccessorType expectFn)
        , Test.test ("Accessor on nested record type " ++ condStr) (accessorOnNestedRecordType expectFn)
        , Test.test ("Accessor function type " ++ condStr) (accessorFunctionType expectFn)
        , Test.test ("Multiple accessor chain type " ++ condStr) (multipleAccessorChainType expectFn)
        ]


{-| Passes `expectFn` a module whose `testValue` is `{ name = "Alice" }.name`.
-}
simpleAccessorType : (Src.Module -> Expectation) -> (() -> Expectation)
simpleAccessorType expectFn _ =
    let
        modul =
            makeModule "testValue"
                (accessExpr (recordExpr [ ( "name", strExpr "Alice" ) ]) "name")
    in
    expectFn modul


{-| Passes `expectFn` a module whose `testValue` is
`{ person = { age = 30 } }.person.age`.
-}
accessorOnNestedRecordType : (Src.Module -> Expectation) -> (() -> Expectation)
accessorOnNestedRecordType expectFn _ =
    let
        modul =
            makeModule "testValue"
                (accessExpr
                    (accessExpr
                        (recordExpr
                            [ ( "person"
                              , recordExpr [ ( "age", intExpr 30 ) ]
                              )
                            ]
                        )
                        "person"
                    )
                    "age"
                )
    in
    expectFn modul


{-| Passes `expectFn` a module with `getField : { field : Int } -> Int`, defined
with no arguments as the accessor `.field`, and `testValue : Int` defined as
`getField { field = 99 }`.
-}
accessorFunctionType : (Src.Module -> Expectation) -> (() -> Expectation)
accessorFunctionType expectFn _ =
    let
        getFieldDef : TypedDef
        getFieldDef =
            { name = "getField"
            , args = []
            , tipe = tLambda (tRecord [ ( "field", tType "Int" [] ) ]) (tType "Int" [])
            , body = accessorExpr "field"
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "getField") [ recordExpr [ ( "field", intExpr 99 ) ] ]
            }

        modul =
            makeModuleWithTypedDefs "Test" [ getFieldDef, testValueDef ]
    in
    expectFn modul


{-| Passes `expectFn` a module whose `testValue` reads `value` out of three
nested records, `{ level1 = { level2 = { value = 123 } } }.level1.level2.value`.
-}
multipleAccessorChainType : (Src.Module -> Expectation) -> (() -> Expectation)
multipleAccessorChainType expectFn _ =
    let
        modul =
            makeModule "testValue"
                (accessExpr
                    (accessExpr
                        (accessExpr
                            (recordExpr
                                [ ( "level1"
                                  , recordExpr
                                        [ ( "level2"
                                          , recordExpr [ ( "value", intExpr 123 ) ]
                                          )
                                        ]
                                  )
                                ]
                            )
                            "level1"
                        )
                        "level2"
                    )
                    "value"
                )
    in
    expectFn modul



-- ============================================================================
-- LET BINDING TYPE TESTS (6 tests)
-- ============================================================================


{-| Groups the `let` tests, with `condStr` appended to every name.
-}
letBindingTypeTests : (Src.Module -> Expectation) -> String -> Test
letBindingTypeTests expectFn condStr =
    Test.describe ("Let binding types " ++ condStr)
        [ Test.test ("Simple let type " ++ condStr) (simpleLetType expectFn)
        , Test.test ("Nested let type " ++ condStr) (nestedLetType expectFn)
        , Test.test ("Let with function type " ++ condStr) (letWithFunctionType expectFn)
        , Test.test ("Let destruct tuple type " ++ condStr) (letDestructTupleType expectFn)
        , Test.test ("Let destruct record type " ++ condStr) (letDestructRecordType expectFn)
        , Test.test ("Multiple let bindings type " ++ condStr) (multipleLetBindingsType expectFn)
        ]


{-| Passes `expectFn` a module whose `testValue` is `let x = 42 in x`.
-}
simpleLetType : (Src.Module -> Expectation) -> (() -> Expectation)
simpleLetType expectFn _ =
    let
        modul =
            makeModule "testValue"
                (letExpr
                    [ define "x" [] (intExpr 42) ]
                    (varExpr "x")
                )
    in
    expectFn modul


{-| Passes `expectFn` a module whose `testValue` is
`let x = 10 in let y = x + 5 in y`, the second `let` being the first one's
body.
-}
nestedLetType : (Src.Module -> Expectation) -> (() -> Expectation)
nestedLetType expectFn _ =
    let
        modul =
            makeModule "testValue"
                (letExpr
                    [ define "x" [] (intExpr 10) ]
                    (letExpr
                        [ define "y" [] (binopsExpr [ ( varExpr "x", "+" ) ] (intExpr 5)) ]
                        (varExpr "y")
                    )
                )
    in
    expectFn modul


{-| Passes `expectFn` a module whose `testValue` is
`let double n = n * 2 in double 21`.
-}
letWithFunctionType : (Src.Module -> Expectation) -> (() -> Expectation)
letWithFunctionType expectFn _ =
    let
        modul =
            makeModule "testValue"
                (letExpr
                    [ define "double" [ pVar "n" ] (binopsExpr [ ( varExpr "n", "*" ) ] (intExpr 2)) ]
                    (callExpr (varExpr "double") [ intExpr 21 ])
                )
    in
    expectFn modul


{-| Passes `expectFn` a module whose `testValue` is
`let ( a, b ) = ( 1, 2 ) in a + b`.
-}
letDestructTupleType : (Src.Module -> Expectation) -> (() -> Expectation)
letDestructTupleType expectFn _ =
    let
        modul =
            makeModule "testValue"
                (letExpr
                    [ destruct (pTuple (pVar "a") (pVar "b")) (tupleExpr (intExpr 1) (intExpr 2)) ]
                    (binopsExpr [ ( varExpr "a", "+" ) ] (varExpr "b"))
                )
    in
    expectFn modul


{-| Passes `expectFn` a module whose `testValue` is
`let { x, y } = { x = 3, y = 4 } in x + y`.
-}
letDestructRecordType : (Src.Module -> Expectation) -> (() -> Expectation)
letDestructRecordType expectFn _ =
    let
        modul =
            makeModule "testValue"
                (letExpr
                    [ destruct (pRecord [ "x", "y" ]) (recordExpr [ ( "x", intExpr 3 ), ( "y", intExpr 4 ) ]) ]
                    (binopsExpr [ ( varExpr "x", "+" ) ] (varExpr "y"))
                )
    in
    expectFn modul


{-| Passes `expectFn` a module whose `testValue` is a single `let` that
defines `a = 1`, `b = 2` and `c = 3` and whose body is `a + b + c`.
-}
multipleLetBindingsType : (Src.Module -> Expectation) -> (() -> Expectation)
multipleLetBindingsType expectFn _ =
    let
        modul =
            makeModule "testValue"
                (letExpr
                    [ define "a" [] (intExpr 1)
                    , define "b" [] (intExpr 2)
                    , define "c" [] (intExpr 3)
                    ]
                    (binopsExpr [ ( varExpr "a", "+" ), ( varExpr "b", "+" ) ] (varExpr "c"))
                )
    in
    expectFn modul



-- ============================================================================
-- CONTROL FLOW TYPE TESTS (6 tests)
-- ============================================================================


{-| Groups the `if` and `case` tests, with `condStr` appended to every name.
-}
controlFlowTypeTests : (Src.Module -> Expectation) -> String -> Test
controlFlowTypeTests expectFn condStr =
    Test.describe ("Control flow types " ++ condStr)
        [ Test.test ("Simple if type " ++ condStr) (simpleIfType expectFn)
        , Test.test ("Nested if type " ++ condStr) (nestedIfType expectFn)
        , Test.test ("If with record result type " ++ condStr) (ifWithRecordResultType expectFn)
        , Test.test ("Simple case type " ++ condStr) (simpleCaseType expectFn)
        , Test.test ("Multi-branch case type " ++ condStr) (multiBranchCaseType expectFn)
        , Test.test ("Case with nested patterns type " ++ condStr) (caseWithNestedPatternsType expectFn)
        ]


{-| Passes `expectFn` a module whose `testValue` is `if True then 1 else 0`.
-}
simpleIfType : (Src.Module -> Expectation) -> (() -> Expectation)
simpleIfType expectFn _ =
    let
        modul =
            makeModule "testValue"
                (ifExpr (boolExpr True) (intExpr 1) (intExpr 0))
    in
    expectFn modul


{-| Passes `expectFn` a module whose `testValue` is
`if True then if False then 1 else 2 else 3`.
-}
nestedIfType : (Src.Module -> Expectation) -> (() -> Expectation)
nestedIfType expectFn _ =
    let
        modul =
            makeModule "testValue"
                (ifExpr (boolExpr True)
                    (ifExpr (boolExpr False) (intExpr 1) (intExpr 2))
                    (intExpr 3)
                )
    in
    expectFn modul


{-| Passes `expectFn` a module whose `testValue` is
`if True then { value = 1 } else { value = 2 }`. Both branches are records of
type `{ value : Int }`.
-}
ifWithRecordResultType : (Src.Module -> Expectation) -> (() -> Expectation)
ifWithRecordResultType expectFn _ =
    let
        modul =
            makeModule "testValue"
                (ifExpr (boolExpr True)
                    (recordExpr [ ( "value", intExpr 1 ) ])
                    (recordExpr [ ( "value", intExpr 2 ) ])
                )
    in
    expectFn modul


{-| Passes `expectFn` a module whose `testValue` is a `case` on the integer `1`
with branches `0`, `1` and `_`, each giving a string.
-}
simpleCaseType : (Src.Module -> Expectation) -> (() -> Expectation)
simpleCaseType expectFn _ =
    let
        modul =
            makeModule "testValue"
                (caseExpr (intExpr 1)
                    [ ( pInt 0, strExpr "zero" )
                    , ( pInt 1, strExpr "one" )
                    , ( pAnything, strExpr "other" )
                    ]
                )
    in
    expectFn modul


{-| Passes `expectFn` a module whose `testValue` is a `case` on the integer `5`
with branches `0` to `4` and `_`, each giving an integer.
-}
multiBranchCaseType : (Src.Module -> Expectation) -> (() -> Expectation)
multiBranchCaseType expectFn _ =
    let
        modul =
            makeModule "testValue"
                (caseExpr (intExpr 5)
                    [ ( pInt 0, intExpr 100 )
                    , ( pInt 1, intExpr 101 )
                    , ( pInt 2, intExpr 102 )
                    , ( pInt 3, intExpr 103 )
                    , ( pInt 4, intExpr 104 )
                    , ( pAnything, intExpr 999 )
                    ]
                )
    in
    expectFn modul


{-| Passes `expectFn` a module whose `testValue` is a `case` on `( 1, 2 )` with
the branches `( 0, y ) -> y`, `( x, 0 ) -> x` and `( x, y ) -> x + y`.
-}
caseWithNestedPatternsType : (Src.Module -> Expectation) -> (() -> Expectation)
caseWithNestedPatternsType expectFn _ =
    let
        modul =
            makeModule "testValue"
                (caseExpr (tupleExpr (intExpr 1) (intExpr 2))
                    [ ( pTuple (pInt 0) (pVar "y"), varExpr "y" )
                    , ( pTuple (pVar "x") (pInt 0), varExpr "x" )
                    , ( pTuple (pVar "x") (pVar "y"), binopsExpr [ ( varExpr "x", "+" ) ] (varExpr "y") )
                    ]
                )
    in
    expectFn modul



-- ============================================================================
-- RECORD UPDATE TYPE TESTS (4 tests)
-- ============================================================================


{-| Groups the record update tests, with `condStr` appended to every name.
-}
recordUpdateTypeTests : (Src.Module -> Expectation) -> String -> Test
recordUpdateTypeTests expectFn condStr =
    Test.describe ("Record update types " ++ condStr)
        [ Test.test ("Simple record update type " ++ condStr) (simpleRecordUpdateType expectFn)
        , Test.test ("Multi-field record update type " ++ condStr) (multiFieldRecordUpdateType expectFn)
        , Test.test ("Record update with expression type " ++ condStr) (recordUpdateWithExpressionType expectFn)
        , Test.test ("Nested record update type " ++ condStr) (nestedRecordUpdateType expectFn)
        ]


{-| Passes `expectFn` a module whose `testValue` is
`let r = { x = 1, y = 2 } in { r | x = 10 }`.
-}
simpleRecordUpdateType : (Src.Module -> Expectation) -> (() -> Expectation)
simpleRecordUpdateType expectFn _ =
    let
        modul =
            makeModule "testValue"
                (letExpr
                    [ define "r" [] (recordExpr [ ( "x", intExpr 1 ), ( "y", intExpr 2 ) ]) ]
                    (updateExpr (varExpr "r") [ ( "x", intExpr 10 ) ])
                )
    in
    expectFn modul


{-| Passes `expectFn` a module whose `testValue` is
`let r = { a = 1, b = 2, c = 3 } in { r | a = 100, c = 300 }`.
-}
multiFieldRecordUpdateType : (Src.Module -> Expectation) -> (() -> Expectation)
multiFieldRecordUpdateType expectFn _ =
    let
        modul =
            makeModule "testValue"
                (letExpr
                    [ define "r" [] (recordExpr [ ( "a", intExpr 1 ), ( "b", intExpr 2 ), ( "c", intExpr 3 ) ]) ]
                    (updateExpr (varExpr "r") [ ( "a", intExpr 100 ), ( "c", intExpr 300 ) ])
                )
    in
    expectFn modul


{-| Passes `expectFn` a module whose `testValue` is
`let r = { count = 5 } in { r | count = r.count + 1 }`.
-}
recordUpdateWithExpressionType : (Src.Module -> Expectation) -> (() -> Expectation)
recordUpdateWithExpressionType expectFn _ =
    let
        modul =
            makeModule "testValue"
                (letExpr
                    [ define "r" [] (recordExpr [ ( "count", intExpr 5 ) ]) ]
                    (updateExpr (varExpr "r")
                        [ ( "count", binopsExpr [ ( accessExpr (varExpr "r") "count", "+" ) ] (intExpr 1) ) ]
                    )
                )
    in
    expectFn modul


{-| Passes `expectFn` a module whose `testValue` is
`let outer = { inner = { value = 1 } } in { outer | inner = { value = 99 } }`.
-}
nestedRecordUpdateType : (Src.Module -> Expectation) -> (() -> Expectation)
nestedRecordUpdateType expectFn _ =
    let
        modul =
            makeModule "testValue"
                (letExpr
                    [ define "outer"
                        []
                        (recordExpr
                            [ ( "inner", recordExpr [ ( "value", intExpr 1 ) ] )
                            ]
                        )
                    ]
                    (updateExpr (varExpr "outer")
                        [ ( "inner", recordExpr [ ( "value", intExpr 99 ) ] ) ]
                    )
                )
    in
    expectFn modul



-- ============================================================================
-- CALL TYPE TESTS (5 tests)
-- ============================================================================


{-| Groups the function call tests, with `condStr` appended to every name.
-}
callTypeTests : (Src.Module -> Expectation) -> String -> Test
callTypeTests expectFn condStr =
    Test.describe ("Call types " ++ condStr)
        [ Test.test ("Simple call type " ++ condStr) (simpleCallType expectFn)
        , Test.test ("Nested call type " ++ condStr) (nestedCallType expectFn)
        , Test.test ("Higher-order call type " ++ condStr) (higherOrderCallType expectFn)
        , Test.test ("Partial application type " ++ condStr) (partialApplicationType expectFn)
        , Test.test ("Call with complex arg type " ++ condStr) (callWithComplexArgType expectFn)
        ]


{-| Passes `expectFn` a module with its own `negate : Int -> Int`, defined as
`negate x = 0 - x`, and `testValue : Int` defined as `negate 42`.
-}
simpleCallType : (Src.Module -> Expectation) -> (() -> Expectation)
simpleCallType expectFn _ =
    let
        negateDef : TypedDef
        negateDef =
            { name = "negate"
            , args = [ pVar "x" ]
            , tipe = tLambda (tType "Int" []) (tType "Int" [])
            , body = binopsExpr [ ( intExpr 0, "-" ) ] (varExpr "x")
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "negate") [ intExpr 42 ]
            }

        modul =
            makeModuleWithTypedDefs "Test" [ negateDef, testValueDef ]
    in
    expectFn modul


{-| Passes `expectFn` a module with `double : Int -> Int`, defined as
`double x = x * 2`, and `testValue : Int` defined as `double (double 5)`.
-}
nestedCallType : (Src.Module -> Expectation) -> (() -> Expectation)
nestedCallType expectFn _ =
    let
        doubleDef : TypedDef
        doubleDef =
            { name = "double"
            , args = [ pVar "x" ]
            , tipe = tLambda (tType "Int" []) (tType "Int" [])
            , body = binopsExpr [ ( varExpr "x", "*" ) ] (intExpr 2)
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "double") [ callExpr (varExpr "double") [ intExpr 5 ] ]
            }

        modul =
            makeModuleWithTypedDefs "Test" [ doubleDef, testValueDef ]
    in
    expectFn modul


{-| Passes `expectFn` a module with `apply : (Int -> Int) -> Int -> Int`, defined
as `apply f x = f x`, `inc : Int -> Int`, defined as `inc n = n + 1`, and
`testValue : Int` defined as `apply inc 10`.
-}
higherOrderCallType : (Src.Module -> Expectation) -> (() -> Expectation)
higherOrderCallType expectFn _ =
    let
        applyDef : TypedDef
        applyDef =
            { name = "apply"
            , args = [ pVar "f", pVar "x" ]
            , tipe = tLambda (tLambda (tType "Int" []) (tType "Int" [])) (tLambda (tType "Int" []) (tType "Int" []))
            , body = callExpr (varExpr "f") [ varExpr "x" ]
            }

        incDef : TypedDef
        incDef =
            { name = "inc"
            , args = [ pVar "n" ]
            , tipe = tLambda (tType "Int" []) (tType "Int" [])
            , body = binopsExpr [ ( varExpr "n", "+" ) ] (intExpr 1)
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "apply") [ varExpr "inc", intExpr 10 ]
            }

        modul =
            makeModuleWithTypedDefs "Test" [ applyDef, incDef, testValueDef ]
    in
    expectFn modul


{-| Passes `expectFn` a module with `add : Int -> Int -> Int`, defined as
`add a b = a + b`, `add5 : Int -> Int`, defined with no arguments as `add 5`,
and `testValue : Int` defined as `add5 10`.
-}
partialApplicationType : (Src.Module -> Expectation) -> (() -> Expectation)
partialApplicationType expectFn _ =
    let
        addDef : TypedDef
        addDef =
            { name = "add"
            , args = [ pVar "a", pVar "b" ]
            , tipe = tLambda (tType "Int" []) (tLambda (tType "Int" []) (tType "Int" []))
            , body = binopsExpr [ ( varExpr "a", "+" ) ] (varExpr "b")
            }

        add5Def : TypedDef
        add5Def =
            { name = "add5"
            , args = []
            , tipe = tLambda (tType "Int" []) (tType "Int" [])
            , body = callExpr (varExpr "add") [ intExpr 5 ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "add5") [ intExpr 10 ]
            }

        modul =
            makeModuleWithTypedDefs "Test" [ addDef, add5Def, testValueDef ]
    in
    expectFn modul


{-| Passes `expectFn` a module with `sumRecord : { x : Int, y : Int } -> Int`,
defined as `sumRecord r = r.x + r.y`, and `testValue : Int` defined as
`sumRecord { x = 3, y = 4 }`.
-}
callWithComplexArgType : (Src.Module -> Expectation) -> (() -> Expectation)
callWithComplexArgType expectFn _ =
    let
        sumRecordDef : TypedDef
        sumRecordDef =
            { name = "sumRecord"
            , args = [ pVar "r" ]
            , tipe = tLambda (tRecord [ ( "x", tType "Int" [] ), ( "y", tType "Int" [] ) ]) (tType "Int" [])
            , body = binopsExpr [ ( accessExpr (varExpr "r") "x", "+" ) ] (accessExpr (varExpr "r") "y")
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "sumRecord") [ recordExpr [ ( "x", intExpr 3 ), ( "y", intExpr 4 ) ] ]
            }

        modul =
            makeModuleWithTypedDefs "Test" [ sumRecordDef, testValueDef ]
    in
    expectFn modul



-- ============================================================================
-- BINOP TYPE TESTS (5 tests)
-- ============================================================================


{-| Groups the binary operator tests, with `condStr` appended to every name.
-}
binopTypeTests : (Src.Module -> Expectation) -> String -> Test
binopTypeTests expectFn condStr =
    Test.describe ("Binop types " ++ condStr)
        [ Test.test ("Addition binop type " ++ condStr) (additionBinopType expectFn)
        , Test.test ("Comparison binop type " ++ condStr) (comparisonBinopType expectFn)
        , Test.test ("Logical binop type " ++ condStr) (logicalBinopType expectFn)
        , Test.test ("Chained binop type " ++ condStr) (chainedBinopType expectFn)
        , Test.test ("Mixed binop type " ++ condStr) (mixedBinopType expectFn)
        ]


{-| Passes `expectFn` a module whose `testValue` is `1 + 2`.
-}
additionBinopType : (Src.Module -> Expectation) -> (() -> Expectation)
additionBinopType expectFn _ =
    let
        modul =
            makeModule "testValue" (binopsExpr [ ( intExpr 1, "+" ) ] (intExpr 2))
    in
    expectFn modul


{-| Passes `expectFn` a module whose `testValue` is `5 > 3`.
-}
comparisonBinopType : (Src.Module -> Expectation) -> (() -> Expectation)
comparisonBinopType expectFn _ =
    let
        modul =
            makeModule "testValue" (binopsExpr [ ( intExpr 5, ">" ) ] (intExpr 3))
    in
    expectFn modul


{-| Passes `expectFn` a module whose `testValue` is `True && False`.
-}
logicalBinopType : (Src.Module -> Expectation) -> (() -> Expectation)
logicalBinopType expectFn _ =
    let
        modul =
            makeModule "testValue" (binopsExpr [ ( boolExpr True, "&&" ) ] (boolExpr False))
    in
    expectFn modul


{-| Passes `expectFn` a module whose `testValue` is `1 + 2 + 3 + 4`, stored as
one flat chain of four operands.
-}
chainedBinopType : (Src.Module -> Expectation) -> (() -> Expectation)
chainedBinopType expectFn _ =
    let
        modul =
            makeModule "testValue"
                (binopsExpr [ ( intExpr 1, "+" ), ( intExpr 2, "+" ), ( intExpr 3, "+" ) ] (intExpr 4))
    in
    expectFn modul


{-| Passes `expectFn` a module whose `testValue` is `2 * 3 + 4`, stored as one
flat chain whose precedence is settled during canonicalization.
-}
mixedBinopType : (Src.Module -> Expectation) -> (() -> Expectation)
mixedBinopType expectFn _ =
    let
        modul =
            makeModule "testValue"
                (binopsExpr [ ( intExpr 2, "*" ), ( intExpr 3, "+" ) ] (intExpr 4))
    in
    expectFn modul



-- ============================================================================
-- NEGATE TYPE TESTS (3 tests)
-- ============================================================================


{-| Groups the negation tests, with `condStr` appended to every name.
-}
negateTypeTests : (Src.Module -> Expectation) -> String -> Test
negateTypeTests expectFn condStr =
    Test.describe ("Negate types " ++ condStr)
        [ Test.test ("Negate int type " ++ condStr) (negateIntType expectFn)
        , Test.test ("Negate float type " ++ condStr) (negateFloatType expectFn)
        , Test.test ("Double negate type " ++ condStr) (doubleNegateType expectFn)
        ]


{-| Passes `expectFn` a module whose `testValue` is `-42`, a negation of the
integer literal `42`.
-}
negateIntType : (Src.Module -> Expectation) -> (() -> Expectation)
negateIntType expectFn _ =
    let
        modul =
            makeModule "testValue" (negateExpr (intExpr 42))
    in
    expectFn modul


{-| Passes `expectFn` a module whose `testValue` is `-3.14`, a negation of the
float literal `3.14`.
-}
negateFloatType : (Src.Module -> Expectation) -> (() -> Expectation)
negateFloatType expectFn _ =
    let
        modul =
            makeModule "testValue" (negateExpr (floatExpr 3.14))
    in
    expectFn modul


{-| Passes `expectFn` a module whose `testValue` is the negation of the
negation of `10`. The inner negation is not wrapped in parentheses, a shape
the parser never builds, since it negates only a term.
-}
doubleNegateType : (Src.Module -> Expectation) -> (() -> Expectation)
doubleNegateType expectFn _ =
    let
        modul =
            makeModule "testValue" (negateExpr (negateExpr (intExpr 10)))
    in
    expectFn modul



-- ============================================================================
-- INSTANTIATE EDGE CASE TESTS
-- ============================================================================


{-| Groups the tests of annotation forms, with `condStr` appended to every name.
When the program is type checked, each annotation is converted by
`Compiler.Type.Instantiate.fromSrcType`, and each test reaches a different arm
of it: unit, alias and record.
-}
instantiateEdgeCaseTests : (Src.Module -> Expectation) -> String -> Test
instantiateEdgeCaseTests expectFn condStr =
    Test.describe ("Instantiate edge cases " ++ condStr)
        [ Test.test ("Unit in type annotation " ++ condStr) (unitAnnotationType expectFn)
        , Test.test ("Type alias annotation " ++ condStr) (typeAliasAnnotationType expectFn)
        , Test.test ("Extensible record annotation " ++ condStr) (extensibleRecordAnnotationType expectFn)
        ]


{-| Passes `expectFn` a module with `f : () -> Int`, defined as `f _ = 42`, and
`testValue : Int` defined as `f ()`.
-}
unitAnnotationType : (Src.Module -> Expectation) -> (() -> Expectation)
unitAnnotationType expectFn _ =
    let
        fDef : TypedDef
        fDef =
            { name = "f"
            , args = [ pAnything ]
            , tipe = tLambda tUnit (tType "Int" [])
            , body = intExpr 42
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "f") [ unitExpr ]
            }

        modul =
            makeModuleWithTypedDefs "Test" [ fDef, testValueDef ]
    in
    expectFn modul


{-| Passes `expectFn` a module that declares
`type alias Point = { x : Int, y : Int }` and has `getX : Point -> Int`,
defined as `getX p = p.x`, and `testValue : Int` defined as
`getX { x = 10, y = 20 }`.
-}
typeAliasAnnotationType : (Src.Module -> Expectation) -> (() -> Expectation)
typeAliasAnnotationType expectFn _ =
    let
        pointAlias : AliasDef
        pointAlias =
            { name = "Point"
            , args = []
            , tipe = tRecord [ ( "x", tType "Int" [] ), ( "y", tType "Int" [] ) ]
            }

        getXDef : TypedDef
        getXDef =
            { name = "getX"
            , args = [ pVar "p" ]
            , tipe = tLambda (tType "Point" []) (tType "Int" [])
            , body = accessExpr (varExpr "p") "x"
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "getX") [ recordExpr [ ( "x", intExpr 10 ), ( "y", intExpr 20 ) ] ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ getXDef, testValueDef ]
                []
                [ pointAlias ]
    in
    expectFn modul


{-| Passes `expectFn` a module with `getX : { a | x : Int } -> Int`, defined as
`getX r = r.x`, and `testValue : Int` defined as `getX { x = 5, y = 10 }`, a
record with a field the annotation does not name.
-}
extensibleRecordAnnotationType : (Src.Module -> Expectation) -> (() -> Expectation)
extensibleRecordAnnotationType expectFn _ =
    let
        getXDef : TypedDef
        getXDef =
            { name = "getX"
            , args = [ pVar "r" ]
            , tipe = tLambda (tExtRecord "a" [ ( "x", tType "Int" [] ) ]) (tType "Int" [])
            , body = accessExpr (varExpr "r") "x"
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "getX") [ recordExpr [ ( "x", intExpr 5 ), ( "y", intExpr 10 ) ] ]
            }

        modul =
            makeModuleWithTypedDefs "Test" [ getXDef, testValueDef ]
    in
    expectFn modul
