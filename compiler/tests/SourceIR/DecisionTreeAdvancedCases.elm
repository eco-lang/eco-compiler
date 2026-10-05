module SourceIR.DecisionTreeAdvancedCases exposing (expectSuite)

{-| Programs whose `case` expressions take the shapes a decision tree has to
handle, so that a stage check run over them meets each shape in a small
program.

A decision tree is what the optimizer turns a `case` into: a tree of tests on
parts of the value being matched, each test leading either to a branch or to
further tests. On the typed path it is built by
`Compiler.LocalOpt.Typed.DecisionTree.compile`, which
`Compiler.LocalOpt.Typed.Case` calls. This module asserts nothing about it.
`expectSuite` hands each program to the expectation function its caller
supplies, and that function decides which stages run and what is checked.

Eleven of the forty cases have no `case`: the unit pattern, the four record
cases, the four variable and wildcard cases, and the as-patterns around a
variable and around a tuple. Each puts its pattern in a function argument,
which the typed optimizer turns into bindings through
`Compiler.LocalOpt.Typed.Expression.destructArgs`, building no decision tree.

Each case builds one module named `Test` that has a top-level `testValue`, in
one of two ways. Thirty-two cases use `makeModuleWithTypedDefsUnionsAliases`:
every top-level definition is annotated, the module imports `Basics`, `Maybe`,
`List`, `Elm.JsArray as JsArray`, `String` and `Char`, and declares any union
type the case needs, and `testValue` applies a function holding the pattern to
concrete arguments. The cases on `Maybe` declare no union and use the
imported one. The other eight use `makeModule`: `testValue` is the only
top-level value and has no annotation, the module imports only `Basics` and
`List`, and the pattern is in a `let`-bound function or in a `case` directly
in `testValue`.

What the tests establish: `expectSuite` returns one test that runs the forty
cases below in order through `Compiler.BulkCheck.bulkCheck`, so it passes when
`expectFn` passes on every module, and a failure names only the first case
that failed.

  - Constructor patterns (8 cases): a union with one constructor, unions with
    two and three nullary constructors, a constructor with one argument and
    one with two, a constructor pattern inside another, and `Maybe` matched
    `Just` first and `Nothing` first.
  - List patterns (4 cases): a one-element list, a two-element list, two
    nested `::` patterns, and `[]`, one-element and two-element patterns
    followed by a wildcard.
  - Literal patterns (4 cases): one `Int` literal, four `Int` literals and six
    `Char` literals, each followed by a wildcard, and a unit pattern as the
    argument of a `let`-bound function.
  - Tuple patterns (2 cases): a three-tuple in an unannotated `let`-bound
    function, and pairs mixing `Int` literals and wildcards.
  - Record patterns (4 cases): each the argument of a `let`-bound function,
    naming one field, two fields, or one field of a two-field record. None is
    nested in another pattern.
  - Variable and wildcard patterns (4 cases): function arguments only, with no
    `case`.
  - As-patterns (3 cases): `as` around a variable argument, around a `Just`
    pattern in a `case`, and around a tuple argument.
  - Nested patterns (4 cases): a constructor inside a constructor of a
    recursive union, a tuple at the head of a `::` pattern, `::` patterns
    inside a tuple, and `::` and `[]` inside a constructor.
  - Larger matches (4 cases): pairs of `Int` literals ending in a
    wildcard, every combination of `Just` and `Nothing` in a pair, a
    seven-constructor union with one branch per constructor, and a pair of
    pairs with a branch of literals and a branch that matches every value.
  - Edge cases (3 cases): a one-constructor union, a `case` whose only branch
    is a wildcard, and two `Int` literal branches followed by a variable.

Among what is not tested:

  - a union type with no constructors, and a redundant branch, although two
    case labels name them;
  - string literal patterns;
  - a record pattern in a `case` or inside another pattern;
  - a `case` that does not cover every value;
  - the value `testValue` evaluates to, unless `expectFn` checks it.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( TypedDef
        , UnionDef
        , binopsExpr
        , boolExpr
        , callExpr
        , caseExpr
        , chrExpr
        , ctorExpr
        , define
        , intExpr
        , letExpr
        , listExpr
        , makeModule
        , makeModuleWithTypedDefsUnionsAliases
        , pAlias
        , pAnything
        , pChr
        , pCons
        , pCtor
        , pInt
        , pList
        , pRecord
        , pTuple
        , pTuple3
        , pUnit
        , pVar
        , recordExpr
        , strExpr
        , tLambda
        , tTuple
        , tType
        , tuple3Expr
        , tupleExpr
        , unitExpr
        , varExpr
        )
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Expect exposing (Expectation)
import Test exposing (Test)


{-| Returns one test, named "Decision tree advanced " followed by `condStr`,
that passes when `expectFn` passes on the module of every case in this file.
The cases run in order and a failure reports only the first failing case, by
its label and the description of its failure, as `Compiler.BulkCheck.bulkCheck`
describes.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Decision tree advanced " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


{-| Returns every case in this file, group by group, each passing its module to
`expectFn`.
-}
testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    List.concat
        [ constructorPatternCases expectFn
        , listPatternCases expectFn
        , literalPatternCases expectFn
        , tuplePatternCases expectFn
        , recordPatternCases expectFn
        , wildcardAndVarPatternCases expectFn
        , aliasPatternCases expectFn
        , nestedPatternCases expectFn
        , complexDecisionTreeCases expectFn
        , edgeCasePatternCases expectFn
        ]



-- ============================================================================
-- CONSTRUCTOR PATTERN TESTS
-- ============================================================================


{-| Returns the cases that match constructors of declared unions and of
`Maybe`.
-}
constructorPatternCases : (Src.Module -> Expectation) -> List TestCase
constructorPatternCases expectFn =
    [ { label = "Single constructor", run = singleConstructorPattern expectFn }
    , { label = "Two constructors", run = twoConstructorPattern expectFn }
    , { label = "Three constructors", run = threeConstructorPattern expectFn }
    , { label = "Constructor with one arg", run = constructorWithOneArg expectFn }
    , { label = "Constructor with multiple args", run = constructorWithMultipleArgs expectFn }
    , { label = "Nested constructor", run = nestedConstructorPattern expectFn }
    , { label = "Maybe Just pattern", run = maybeJustPattern expectFn }
    , { label = "Maybe Nothing pattern", run = maybeNothingPattern expectFn }
    ]


{-| Applies `expectFn` to a module declaring `type MyUnit = MyUnit` and
`f : MyUnit -> Int`, whose body is a `case` with the one branch
`MyUnit -> 42`. `testValue` is `f MyUnit`.
-}
singleConstructorPattern : (Src.Module -> Expectation) -> (() -> Expectation)
singleConstructorPattern expectFn _ =
    let
        unitUnion : UnionDef
        unitUnion =
            { name = "MyUnit"
            , args = []
            , ctors = [ { name = "MyUnit", args = [] } ]
            }

        fDef : TypedDef
        fDef =
            { name = "f"
            , args = [ pVar "u" ]
            , tipe = tLambda (tType "MyUnit" []) (tType "Int" [])
            , body =
                caseExpr (varExpr "u")
                    [ ( pCtor "MyUnit" [], intExpr 42 )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "f") [ ctorExpr "MyUnit" ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ fDef, testValueDef ]
                [ unitUnion ]
                []
    in
    expectFn modul


{-| Applies `expectFn` to a module declaring `type Bool2 = True2 | False2` and
`toBool : Bool2 -> Bool`, which maps `True2` to `True` and `False2` to
`False`. `testValue` is `toBool True2`.
-}
twoConstructorPattern : (Src.Module -> Expectation) -> (() -> Expectation)
twoConstructorPattern expectFn _ =
    let
        bool2Union : UnionDef
        bool2Union =
            { name = "Bool2"
            , args = []
            , ctors =
                [ { name = "True2", args = [] }
                , { name = "False2", args = [] }
                ]
            }

        toBoolDef : TypedDef
        toBoolDef =
            { name = "toBool"
            , args = [ pVar "b" ]
            , tipe = tLambda (tType "Bool2" []) (tType "Bool" [])
            , body =
                caseExpr (varExpr "b")
                    [ ( pCtor "True2" [], boolExpr True )
                    , ( pCtor "False2" [], boolExpr False )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Bool" []
            , body = callExpr (varExpr "toBool") [ ctorExpr "True2" ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ toBoolDef, testValueDef ]
                [ bool2Union ]
                []
    in
    expectFn modul


{-| Applies `expectFn` to a module declaring `type Color = Red | Green | Blue`
and `toInt : Color -> Int`, which maps them to 0, 1 and 2. `testValue` is
`toInt Green`.
-}
threeConstructorPattern : (Src.Module -> Expectation) -> (() -> Expectation)
threeConstructorPattern expectFn _ =
    let
        colorUnion : UnionDef
        colorUnion =
            { name = "Color"
            , args = []
            , ctors =
                [ { name = "Red", args = [] }
                , { name = "Green", args = [] }
                , { name = "Blue", args = [] }
                ]
            }

        toIntDef : TypedDef
        toIntDef =
            { name = "toInt"
            , args = [ pVar "c" ]
            , tipe = tLambda (tType "Color" []) (tType "Int" [])
            , body =
                caseExpr (varExpr "c")
                    [ ( pCtor "Red" [], intExpr 0 )
                    , ( pCtor "Green" [], intExpr 1 )
                    , ( pCtor "Blue" [], intExpr 2 )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "toInt") [ ctorExpr "Green" ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ toIntDef, testValueDef ]
                [ colorUnion ]
                []
    in
    expectFn modul


{-| Applies `expectFn` to a module declaring `type Box = Box Int` and
`unbox : Box -> Int`, whose one branch `Box x` returns `x`. `testValue` is
`unbox (Box 99)`.
-}
constructorWithOneArg : (Src.Module -> Expectation) -> (() -> Expectation)
constructorWithOneArg expectFn _ =
    let
        boxUnion : UnionDef
        boxUnion =
            { name = "Box"
            , args = []
            , ctors = [ { name = "Box", args = [ tType "Int" [] ] } ]
            }

        unboxDef : TypedDef
        unboxDef =
            { name = "unbox"
            , args = [ pVar "b" ]
            , tipe = tLambda (tType "Box" []) (tType "Int" [])
            , body =
                caseExpr (varExpr "b")
                    [ ( pCtor "Box" [ pVar "x" ], varExpr "x" )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "unbox") [ callExpr (ctorExpr "Box") [ intExpr 99 ] ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ unboxDef, testValueDef ]
                [ boxUnion ]
                []
    in
    expectFn modul


{-| Applies `expectFn` to a module declaring `type Pair = Pair Int Int` and
`sum : Pair -> Int`, whose one branch `Pair a b` returns `a + b`. `testValue`
is `sum (Pair 3 4)`.
-}
constructorWithMultipleArgs : (Src.Module -> Expectation) -> (() -> Expectation)
constructorWithMultipleArgs expectFn _ =
    let
        pairUnion : UnionDef
        pairUnion =
            { name = "Pair"
            , args = []
            , ctors = [ { name = "Pair", args = [ tType "Int" [], tType "Int" [] ] } ]
            }

        sumDef : TypedDef
        sumDef =
            { name = "sum"
            , args = [ pVar "p" ]
            , tipe = tLambda (tType "Pair" []) (tType "Int" [])
            , body =
                caseExpr (varExpr "p")
                    [ ( pCtor "Pair" [ pVar "a", pVar "b" ], binopsExpr [ ( varExpr "a", "+" ) ] (varExpr "b") )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "sum") [ callExpr (ctorExpr "Pair") [ intExpr 3, intExpr 4 ] ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ sumDef, testValueDef ]
                [ pairUnion ]
                []
    in
    expectFn modul


{-| Applies `expectFn` to a module declaring `type Box = Box Int`,
`type Wrap = Wrap Box` and `unwrap : Wrap -> Int`, whose one branch
`Wrap (Box x)` returns `x`. `testValue` is `unwrap (Wrap (Box 42))`.
-}
nestedConstructorPattern : (Src.Module -> Expectation) -> (() -> Expectation)
nestedConstructorPattern expectFn _ =
    let
        boxUnion : UnionDef
        boxUnion =
            { name = "Box"
            , args = []
            , ctors = [ { name = "Box", args = [ tType "Int" [] ] } ]
            }

        wrapUnion : UnionDef
        wrapUnion =
            { name = "Wrap"
            , args = []
            , ctors = [ { name = "Wrap", args = [ tType "Box" [] ] } ]
            }

        unwrapDef : TypedDef
        unwrapDef =
            { name = "unwrap"
            , args = [ pVar "w" ]
            , tipe = tLambda (tType "Wrap" []) (tType "Int" [])
            , body =
                caseExpr (varExpr "w")
                    [ ( pCtor "Wrap" [ pCtor "Box" [ pVar "x" ] ], varExpr "x" )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "unwrap") [ callExpr (ctorExpr "Wrap") [ callExpr (ctorExpr "Box") [ intExpr 42 ] ] ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ unwrapDef, testValueDef ]
                [ boxUnion, wrapUnion ]
                []
    in
    expectFn modul


{-| Applies `expectFn` to a module with
`withDefault : Int -> Maybe Int -> Int`, which matches `Just x` to `x` and
then `Nothing` to its first argument. `testValue` is
`withDefault 0 (Just 5)`.
-}
maybeJustPattern : (Src.Module -> Expectation) -> (() -> Expectation)
maybeJustPattern expectFn _ =
    let
        withDefaultDef : TypedDef
        withDefaultDef =
            { name = "withDefault"
            , args = [ pVar "default", pVar "m" ]
            , tipe = tLambda (tType "Int" []) (tLambda (tType "Maybe" [ tType "Int" [] ]) (tType "Int" []))
            , body =
                caseExpr (varExpr "m")
                    [ ( pCtor "Just" [ pVar "x" ], varExpr "x" )
                    , ( pCtor "Nothing" [], varExpr "default" )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "withDefault") [ intExpr 0, callExpr (ctorExpr "Just") [ intExpr 5 ] ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ withDefaultDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Applies `expectFn` to a module with `isNothing : Maybe Int -> Bool`, which
matches `Nothing` to `True` and then `Just _` to `False`. `testValue` is
`isNothing Nothing`.
-}
maybeNothingPattern : (Src.Module -> Expectation) -> (() -> Expectation)
maybeNothingPattern expectFn _ =
    let
        isNothingDef : TypedDef
        isNothingDef =
            { name = "isNothing"
            , args = [ pVar "m" ]
            , tipe = tLambda (tType "Maybe" [ tType "Int" [] ]) (tType "Bool" [])
            , body =
                caseExpr (varExpr "m")
                    [ ( pCtor "Nothing" [], boolExpr True )
                    , ( pCtor "Just" [ pAnything ], boolExpr False )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Bool" []
            , body = callExpr (varExpr "isNothing") [ ctorExpr "Nothing" ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ isNothingDef, testValueDef ]
                []
                []
    in
    expectFn modul



-- ============================================================================
-- LIST PATTERN TESTS
-- ============================================================================


{-| Returns the cases that match list literal patterns and `::` patterns.
-}
listPatternCases : (Src.Module -> Expectation) -> List TestCase
listPatternCases expectFn =
    [ { label = "Singleton list pattern", run = singletonListPattern expectFn }
    , { label = "Two element list pattern", run = twoElementListPattern expectFn }
    , { label = "Multiple cons pattern", run = multipleConsPattern expectFn }
    , { label = "List pattern with fallback", run = listPatternWithFallback expectFn }
    ]


{-| Applies `expectFn` to a module with `isSingleton : List Int -> Bool`, which
matches a one-element list pattern to `True` and then a wildcard to `False`.
`testValue` is `isSingleton [ 1 ]`.
-}
singletonListPattern : (Src.Module -> Expectation) -> (() -> Expectation)
singletonListPattern expectFn _ =
    let
        isSingletonDef : TypedDef
        isSingletonDef =
            { name = "isSingleton"
            , args = [ pVar "xs" ]
            , tipe = tLambda (tType "List" [ tType "Int" [] ]) (tType "Bool" [])
            , body =
                caseExpr (varExpr "xs")
                    [ ( pList [ pAnything ], boolExpr True )
                    , ( pAnything, boolExpr False )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Bool" []
            , body = callExpr (varExpr "isSingleton") [ listExpr [ intExpr 1 ] ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ isSingletonDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Applies `expectFn` to a module with `sumTwo : List Int -> Int`, which
matches `[ a, b ]` to `a + b` and then a wildcard to 0. `testValue` is
`sumTwo [ 3, 4 ]`.
-}
twoElementListPattern : (Src.Module -> Expectation) -> (() -> Expectation)
twoElementListPattern expectFn _ =
    let
        sumTwoDef : TypedDef
        sumTwoDef =
            { name = "sumTwo"
            , args = [ pVar "xs" ]
            , tipe = tLambda (tType "List" [ tType "Int" [] ]) (tType "Int" [])
            , body =
                caseExpr (varExpr "xs")
                    [ ( pList [ pVar "a", pVar "b" ], binopsExpr [ ( varExpr "a", "+" ) ] (varExpr "b") )
                    , ( pAnything, intExpr 0 )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "sumTwo") [ listExpr [ intExpr 3, intExpr 4 ] ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ sumTwoDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Applies `expectFn` to a module with `sumFirstTwo : List Int -> Int`, which
matches `a :: b :: _` to `a + b` and then a wildcard to 0. `testValue` is
`sumFirstTwo [ 5, 6, 7 ]`.
-}
multipleConsPattern : (Src.Module -> Expectation) -> (() -> Expectation)
multipleConsPattern expectFn _ =
    let
        sumFirstTwoDef : TypedDef
        sumFirstTwoDef =
            { name = "sumFirstTwo"
            , args = [ pVar "xs" ]
            , tipe = tLambda (tType "List" [ tType "Int" [] ]) (tType "Int" [])
            , body =
                caseExpr (varExpr "xs")
                    [ ( pCons (pVar "a") (pCons (pVar "b") pAnything), binopsExpr [ ( varExpr "a", "+" ) ] (varExpr "b") )
                    , ( pAnything, intExpr 0 )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "sumFirstTwo") [ listExpr [ intExpr 5, intExpr 6, intExpr 7 ] ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ sumFirstTwoDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Applies `expectFn` to a module with `classify : List Int -> String`, which
matches `[]`, `[ _ ]` and `[ _, _ ]` to "empty", "one" and "two", and then a
wildcard to "many". `testValue` is `classify [ 1, 2, 3, 4 ]`.
-}
listPatternWithFallback : (Src.Module -> Expectation) -> (() -> Expectation)
listPatternWithFallback expectFn _ =
    let
        classifyDef : TypedDef
        classifyDef =
            { name = "classify"
            , args = [ pVar "xs" ]
            , tipe = tLambda (tType "List" [ tType "Int" [] ]) (tType "String" [])
            , body =
                caseExpr (varExpr "xs")
                    [ ( pList [], strExpr "empty" )
                    , ( pList [ pAnything ], strExpr "one" )
                    , ( pList [ pAnything, pAnything ], strExpr "two" )
                    , ( pAnything, strExpr "many" )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "String" []
            , body = callExpr (varExpr "classify") [ listExpr [ intExpr 1, intExpr 2, intExpr 3, intExpr 4 ] ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ classifyDef, testValueDef ]
                []
                []
    in
    expectFn modul



-- ============================================================================
-- LITERAL PATTERN TESTS
-- ============================================================================


{-| Returns the cases that match `Int` and `Char` literals and the unit pattern.
-}
literalPatternCases : (Src.Module -> Expectation) -> List TestCase
literalPatternCases expectFn =
    [ { label = "Int literal pattern", run = intLiteralPattern expectFn }
    , { label = "Multiple int patterns", run = multipleIntPatterns expectFn }
    , { label = "Multiple char patterns", run = multipleCharPatterns expectFn }
    , { label = "Unit pattern", run = unitPattern expectFn }
    ]


{-| Applies `expectFn` to a module with `isZero : Int -> Bool`, which matches
the literal 0 to `True` and then a wildcard to `False`. `testValue` is
`isZero 0`.
-}
intLiteralPattern : (Src.Module -> Expectation) -> (() -> Expectation)
intLiteralPattern expectFn _ =
    let
        isZeroDef : TypedDef
        isZeroDef =
            { name = "isZero"
            , args = [ pVar "n" ]
            , tipe = tLambda (tType "Int" []) (tType "Bool" [])
            , body =
                caseExpr (varExpr "n")
                    [ ( pInt 0, boolExpr True )
                    , ( pAnything, boolExpr False )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Bool" []
            , body = callExpr (varExpr "isZero") [ intExpr 0 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ isZeroDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Applies `expectFn` to a module with `describe : Int -> String`, which
matches the literals 0 to 3 to their names and then a wildcard to "other".
`testValue` is `describe 2`.
-}
multipleIntPatterns : (Src.Module -> Expectation) -> (() -> Expectation)
multipleIntPatterns expectFn _ =
    let
        describeDef : TypedDef
        describeDef =
            { name = "describe"
            , args = [ pVar "n" ]
            , tipe = tLambda (tType "Int" []) (tType "String" [])
            , body =
                caseExpr (varExpr "n")
                    [ ( pInt 0, strExpr "zero" )
                    , ( pInt 1, strExpr "one" )
                    , ( pInt 2, strExpr "two" )
                    , ( pInt 3, strExpr "three" )
                    , ( pAnything, strExpr "other" )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "String" []
            , body = callExpr (varExpr "describe") [ intExpr 2 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ describeDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Applies `expectFn` to a module with `charType : Char -> Int`, which matches
the characters '0' to '5' to the numbers they show and then a wildcard to -1.
`testValue` is `charType '3'`.
-}
multipleCharPatterns : (Src.Module -> Expectation) -> (() -> Expectation)
multipleCharPatterns expectFn _ =
    let
        charTypeDef : TypedDef
        charTypeDef =
            { name = "charType"
            , args = [ pVar "c" ]
            , tipe = tLambda (tType "Char" []) (tType "Int" [])
            , body =
                caseExpr (varExpr "c")
                    [ ( pChr "0", intExpr 0 )
                    , ( pChr "1", intExpr 1 )
                    , ( pChr "2", intExpr 2 )
                    , ( pChr "3", intExpr 3 )
                    , ( pChr "4", intExpr 4 )
                    , ( pChr "5", intExpr 5 )
                    , ( pAnything, intExpr -1 )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "charType") [ chrExpr "3" ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ charTypeDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Applies `expectFn` to a module built with `makeModule` whose `testValue` is
`let result () = 42 in result ()`, a unit pattern as the argument of a
`let`-bound function. There is no `case`.
-}
unitPattern : (Src.Module -> Expectation) -> (() -> Expectation)
unitPattern expectFn _ =
    let
        modul =
            letExpr
                [ define "result" [ pUnit ] (intExpr 42) ]
                (callExpr (varExpr "result") [ unitExpr ])
                |> makeModule "testValue"
    in
    expectFn modul



-- ============================================================================
-- TUPLE PATTERN TESTS
-- ============================================================================


{-| Returns the cases that match a three-tuple and pairs holding literals.
-}
tuplePatternCases : (Src.Module -> Expectation) -> List TestCase
tuplePatternCases expectFn =
    [ { label = "Tuple3 pattern", run = tuple3Pattern expectFn }
    , { label = "Tuple with literals", run = tupleWithLiterals expectFn }
    ]


{-| Applies `expectFn` to a module built with `makeModule` whose `testValue`
defines, unannotated in a `let`, a `sumTriple` that matches its argument with
the single branch `( a, b, c )` and returns `a + b + c`. `testValue` is the
result of `sumTriple ( 1, 2, 3 )`.
-}
tuple3Pattern : (Src.Module -> Expectation) -> (() -> Expectation)
tuple3Pattern expectFn _ =
    let
        modul =
            letExpr
                [ define "sumTriple"
                    [ pVar "t" ]
                    (caseExpr (varExpr "t")
                        [ ( pTuple3 (pVar "a") (pVar "b") (pVar "c")
                          , binopsExpr [ ( varExpr "a", "+" ), ( varExpr "b", "+" ) ] (varExpr "c")
                          )
                        ]
                    )
                ]
                (callExpr (varExpr "sumTriple") [ tuple3Expr (intExpr 1) (intExpr 2) (intExpr 3) ])
                |> makeModule "testValue"
    in
    expectFn modul


{-| Applies `expectFn` to a module with `checkPair : ( Int, Int ) -> String`,
which matches `( 0, 0 )`, `( 0, _ )` and `( _, 0 )` to "origin", "y-axis"
and "x-axis", and then a wildcard to "other". `testValue` is
`checkPair ( 0, 5 )`.
-}
tupleWithLiterals : (Src.Module -> Expectation) -> (() -> Expectation)
tupleWithLiterals expectFn _ =
    let
        checkPairDef : TypedDef
        checkPairDef =
            { name = "checkPair"
            , args = [ pVar "t" ]
            , tipe = tLambda (tTuple (tType "Int" []) (tType "Int" [])) (tType "String" [])
            , body =
                caseExpr (varExpr "t")
                    [ ( pTuple (pInt 0) (pInt 0), strExpr "origin" )
                    , ( pTuple (pInt 0) pAnything, strExpr "y-axis" )
                    , ( pTuple pAnything (pInt 0), strExpr "x-axis" )
                    , ( pAnything, strExpr "other" )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "String" []
            , body = callExpr (varExpr "checkPair") [ tupleExpr (intExpr 0) (intExpr 5) ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ checkPairDef, testValueDef ]
                []
                []
    in
    expectFn modul



-- ============================================================================
-- RECORD PATTERN TESTS
-- ============================================================================


{-| Returns the cases that destructure a record in a function argument.
-}
recordPatternCases : (Src.Module -> Expectation) -> List TestCase
recordPatternCases expectFn =
    [ { label = "Simple record pattern", run = simpleRecordPattern expectFn }
    , { label = "Multi-field record pattern", run = multiFieldRecordPattern expectFn }
    , { label = "Partial record pattern", run = partialRecordPattern expectFn }
    , { label = "Nested record pattern", run = nestedRecordPattern expectFn }
    ]


{-| Applies `expectFn` to a module built with `makeModule` whose `testValue` is
`let getX { x } = x in getX { x = 10 }`.
-}
simpleRecordPattern : (Src.Module -> Expectation) -> (() -> Expectation)
simpleRecordPattern expectFn _ =
    let
        modul =
            letExpr
                [ define "getX" [ pRecord [ "x" ] ] (varExpr "x") ]
                (callExpr (varExpr "getX") [ recordExpr [ ( "x", intExpr 10 ) ] ])
                |> makeModule "testValue"
    in
    expectFn modul


{-| Applies `expectFn` to a module built with `makeModule` whose `testValue` is
`let sumXY { x, y } = x + y in sumXY { x = 3, y = 4 }`.
-}
multiFieldRecordPattern : (Src.Module -> Expectation) -> (() -> Expectation)
multiFieldRecordPattern expectFn _ =
    let
        modul =
            letExpr
                [ define "sumXY" [ pRecord [ "x", "y" ] ] (binopsExpr [ ( varExpr "x", "+" ) ] (varExpr "y")) ]
                (callExpr (varExpr "sumXY") [ recordExpr [ ( "x", intExpr 3 ), ( "y", intExpr 4 ) ] ])
                |> makeModule "testValue"
    in
    expectFn modul


{-| Applies `expectFn` to a module built with `makeModule` whose `testValue` is
`let getA { a } = a in getA { a = 1, b = 2 }`, a pattern naming one field of
a two-field record.
-}
partialRecordPattern : (Src.Module -> Expectation) -> (() -> Expectation)
partialRecordPattern expectFn _ =
    let
        modul =
            letExpr
                [ define "getA" [ pRecord [ "a" ] ] (varExpr "a") ]
                (callExpr (varExpr "getA") [ recordExpr [ ( "a", intExpr 1 ), ( "b", intExpr 2 ) ] ])
                |> makeModule "testValue"
    in
    expectFn modul


{-| Applies `expectFn` to a module built with `makeModule` whose `testValue` is
`let extract { outer } = outer in extract { outer = 99 }`. Despite the case's
label, nothing is nested: the one field holds an `Int`.
-}
nestedRecordPattern : (Src.Module -> Expectation) -> (() -> Expectation)
nestedRecordPattern expectFn _ =
    let
        modul =
            letExpr
                [ define "extract" [ pRecord [ "outer" ] ] (varExpr "outer") ]
                (callExpr (varExpr "extract") [ recordExpr [ ( "outer", intExpr 99 ) ] ])
                |> makeModule "testValue"
    in
    expectFn modul



-- ============================================================================
-- WILDCARD AND VAR PATTERN TESTS
-- ============================================================================


{-| Returns the cases whose function arguments are variables and wildcards.
-}
wildcardAndVarPatternCases : (Src.Module -> Expectation) -> List TestCase
wildcardAndVarPatternCases expectFn =
    [ { label = "Wildcard pattern", run = wildcardPattern expectFn }
    , { label = "Variable pattern", run = variablePattern expectFn }
    , { label = "Mixed wildcard and var", run = mixedWildcardAndVar expectFn }
    , { label = "All wildcards", run = allWildcards expectFn }
    ]


{-| Applies `expectFn` to a module with `always : Int -> Int -> Int`, defined
as `always x _ = x`. `testValue` is `always 42 0`.
-}
wildcardPattern : (Src.Module -> Expectation) -> (() -> Expectation)
wildcardPattern expectFn _ =
    let
        alwaysDef : TypedDef
        alwaysDef =
            { name = "always"
            , args = [ pVar "x", pAnything ]
            , tipe = tLambda (tType "Int" []) (tLambda (tType "Int" []) (tType "Int" []))
            , body = varExpr "x"
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "always") [ intExpr 42, intExpr 0 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ alwaysDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Applies `expectFn` to a module with `id : Int -> Int`, defined as
`id x = x`. `testValue` is `id 123`.
-}
variablePattern : (Src.Module -> Expectation) -> (() -> Expectation)
variablePattern expectFn _ =
    let
        idDef : TypedDef
        idDef =
            { name = "id"
            , args = [ pVar "x" ]
            , tipe = tLambda (tType "Int" []) (tType "Int" [])
            , body = varExpr "x"
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "id") [ intExpr 123 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ idDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Applies `expectFn` to a module with `first : ( Int, Int ) -> Int`, defined
as `first ( a, _ ) = a`. `testValue` is `first ( 1, 2 )`.
-}
mixedWildcardAndVar : (Src.Module -> Expectation) -> (() -> Expectation)
mixedWildcardAndVar expectFn _ =
    let
        firstDef : TypedDef
        firstDef =
            { name = "first"
            , args = [ pTuple (pVar "a") pAnything ]
            , tipe = tLambda (tTuple (tType "Int" []) (tType "Int" [])) (tType "Int" [])
            , body = varExpr "a"
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "first") [ tupleExpr (intExpr 1) (intExpr 2) ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ firstDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Applies `expectFn` to a module with `ignore : Int -> Int -> Int`, defined
as `ignore _ _ = 0`. `testValue` is `ignore 1 2`.
-}
allWildcards : (Src.Module -> Expectation) -> (() -> Expectation)
allWildcards expectFn _ =
    let
        ignoreDef : TypedDef
        ignoreDef =
            { name = "ignore"
            , args = [ pAnything, pAnything ]
            , tipe = tLambda (tType "Int" []) (tLambda (tType "Int" []) (tType "Int" []))
            , body = intExpr 0
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "ignore") [ intExpr 1, intExpr 2 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ ignoreDef, testValueDef ]
                []
                []
    in
    expectFn modul



-- ============================================================================
-- ALIAS PATTERN TESTS
-- ============================================================================


{-| Returns the cases that use `as` patterns.
-}
aliasPatternCases : (Src.Module -> Expectation) -> List TestCase
aliasPatternCases expectFn =
    [ { label = "Simple alias pattern", run = simpleAliasPattern expectFn }
    , { label = "Alias with constructor", run = aliasWithConstructor expectFn }
    , { label = "Alias with tuple", run = aliasWithTuple expectFn }
    ]


{-| Applies `expectFn` to a module with `useAlias : Int -> Int`, defined as
`useAlias (x as whole) = x + whole`. `testValue` is `useAlias 5`.
-}
simpleAliasPattern : (Src.Module -> Expectation) -> (() -> Expectation)
simpleAliasPattern expectFn _ =
    let
        useAliasDef : TypedDef
        useAliasDef =
            { name = "useAlias"
            , args = [ pAlias (pVar "x") "whole" ]
            , tipe = tLambda (tType "Int" []) (tType "Int" [])
            , body = binopsExpr [ ( varExpr "x", "+" ) ] (varExpr "whole")
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "useAlias") [ intExpr 5 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ useAliasDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Applies `expectFn` to a module with `extractWithAlias : Maybe Int -> Int`,
which matches `(Just x as whole)` to `x`, leaving `whole` unused, and then
`Nothing` to 0. `testValue` is `extractWithAlias (Just 42)`.
-}
aliasWithConstructor : (Src.Module -> Expectation) -> (() -> Expectation)
aliasWithConstructor expectFn _ =
    let
        extractWithAliasDef : TypedDef
        extractWithAliasDef =
            { name = "extractWithAlias"
            , args = [ pVar "m" ]
            , tipe = tLambda (tType "Maybe" [ tType "Int" [] ]) (tType "Int" [])
            , body =
                caseExpr (varExpr "m")
                    [ ( pAlias (pCtor "Just" [ pVar "x" ]) "whole", varExpr "x" )
                    , ( pCtor "Nothing" [], intExpr 0 )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "extractWithAlias") [ callExpr (ctorExpr "Just") [ intExpr 42 ] ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ extractWithAliasDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Applies `expectFn` to a module with `sumWithAlias : ( Int, Int ) -> Int`,
defined as `sumWithAlias (( a, b ) as pair) = a + b`. `testValue` is
`sumWithAlias ( 3, 7 )`.
-}
aliasWithTuple : (Src.Module -> Expectation) -> (() -> Expectation)
aliasWithTuple expectFn _ =
    let
        sumWithAliasDef : TypedDef
        sumWithAliasDef =
            { name = "sumWithAlias"
            , args = [ pAlias (pTuple (pVar "a") (pVar "b")) "pair" ]
            , tipe = tLambda (tTuple (tType "Int" []) (tType "Int" [])) (tType "Int" [])
            , body = binopsExpr [ ( varExpr "a", "+" ) ] (varExpr "b")
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "sumWithAlias") [ tupleExpr (intExpr 3) (intExpr 7) ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ sumWithAliasDef, testValueDef ]
                []
                []
    in
    expectFn modul



-- ============================================================================
-- NESTED PATTERN TESTS
-- ============================================================================


{-| Returns the cases that put constructor, tuple and list patterns inside one
another.
-}
nestedPatternCases : (Src.Module -> Expectation) -> List TestCase
nestedPatternCases expectFn =
    [ { label = "Deeply nested constructor", run = deeplyNestedConstructor expectFn }
    , { label = "List of tuples pattern", run = listOfTuplesPattern expectFn }
    , { label = "Tuple of lists pattern", run = tupleOfListsPattern expectFn }
    , { label = "Constructor with list", run = constructorWithList expectFn }
    ]


{-| Applies `expectFn` to a module declaring
`type Nest = Leaf Int | Node Nest Nest` and `extractLeft : Nest -> Int`,
which matches `Leaf x` to `x`, `Node (Leaf x) _` to `x`, and then a wildcard
to 0. `testValue` is `extractLeft (Leaf 99)`.
-}
deeplyNestedConstructor : (Src.Module -> Expectation) -> (() -> Expectation)
deeplyNestedConstructor expectFn _ =
    let
        nestUnion : UnionDef
        nestUnion =
            { name = "Nest"
            , args = []
            , ctors =
                [ { name = "Leaf", args = [ tType "Int" [] ] }
                , { name = "Node", args = [ tType "Nest" [], tType "Nest" [] ] }
                ]
            }

        extractLeftDef : TypedDef
        extractLeftDef =
            { name = "extractLeft"
            , args = [ pVar "n" ]
            , tipe = tLambda (tType "Nest" []) (tType "Int" [])
            , body =
                caseExpr (varExpr "n")
                    [ ( pCtor "Leaf" [ pVar "x" ], varExpr "x" )
                    , ( pCtor "Node" [ pCtor "Leaf" [ pVar "x" ], pAnything ], varExpr "x" )
                    , ( pAnything, intExpr 0 )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "extractLeft") [ callExpr (ctorExpr "Leaf") [ intExpr 99 ] ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ extractLeftDef, testValueDef ]
                [ nestUnion ]
                []
    in
    expectFn modul


{-| Applies `expectFn` to a module with `firstPairSum : List ( Int, Int ) ->
Int`, which matches `( a, b ) :: _` to `a + b` and then `[]` to 0. `testValue`
is `firstPairSum [ ( 2, 3 ) ]`.
-}
listOfTuplesPattern : (Src.Module -> Expectation) -> (() -> Expectation)
listOfTuplesPattern expectFn _ =
    let
        firstPairSumDef : TypedDef
        firstPairSumDef =
            { name = "firstPairSum"
            , args = [ pVar "xs" ]
            , tipe = tLambda (tType "List" [ tTuple (tType "Int" []) (tType "Int" []) ]) (tType "Int" [])
            , body =
                caseExpr (varExpr "xs")
                    [ ( pCons (pTuple (pVar "a") (pVar "b")) pAnything, binopsExpr [ ( varExpr "a", "+" ) ] (varExpr "b") )
                    , ( pList [], intExpr 0 )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "firstPairSum") [ listExpr [ tupleExpr (intExpr 2) (intExpr 3) ] ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ firstPairSumDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Applies `expectFn` to a module with
`bothHeads : ( List Int, List Int ) -> Int`, which matches
`( a :: _, b :: _ )` to `a + b` and then a wildcard to 0. `testValue` is
`bothHeads ( [ 1 ], [ 2 ] )`.
-}
tupleOfListsPattern : (Src.Module -> Expectation) -> (() -> Expectation)
tupleOfListsPattern expectFn _ =
    let
        bothHeadsDef : TypedDef
        bothHeadsDef =
            { name = "bothHeads"
            , args = [ pVar "t" ]
            , tipe = tLambda (tTuple (tType "List" [ tType "Int" [] ]) (tType "List" [ tType "Int" [] ])) (tType "Int" [])
            , body =
                caseExpr (varExpr "t")
                    [ ( pTuple (pCons (pVar "a") pAnything) (pCons (pVar "b") pAnything)
                      , binopsExpr [ ( varExpr "a", "+" ) ] (varExpr "b")
                      )
                    , ( pAnything, intExpr 0 )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "bothHeads") [ tupleExpr (listExpr [ intExpr 1 ]) (listExpr [ intExpr 2 ]) ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ bothHeadsDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Applies `expectFn` to a module declaring `type Container = Container (List
Int)` and `headOfContainer : Container -> Int`, which matches `Container (x ::
_)` to `x` and then `Container []` to 0. `testValue` is `headOfContainer
(Container [ 42 ])`.
-}
constructorWithList : (Src.Module -> Expectation) -> (() -> Expectation)
constructorWithList expectFn _ =
    let
        containerUnion : UnionDef
        containerUnion =
            { name = "Container"
            , args = []
            , ctors = [ { name = "Container", args = [ tType "List" [ tType "Int" [] ] ] } ]
            }

        headOfContainerDef : TypedDef
        headOfContainerDef =
            { name = "headOfContainer"
            , args = [ pVar "c" ]
            , tipe = tLambda (tType "Container" []) (tType "Int" [])
            , body =
                caseExpr (varExpr "c")
                    [ ( pCtor "Container" [ pCons (pVar "x") pAnything ], varExpr "x" )
                    , ( pCtor "Container" [ pList [] ], intExpr 0 )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "headOfContainer") [ callExpr (ctorExpr "Container") [ listExpr [ intExpr 42 ] ] ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ headOfContainerDef, testValueDef ]
                [ containerUnion ]
                []
    in
    expectFn modul



-- ============================================================================
-- COMPLEX DECISION TREE TESTS
-- ============================================================================


{-| Returns the cases with larger matches: pairs of `Int` literals, pairs of
`Maybe` values, a seven-constructor union and a pair of pairs.
-}
complexDecisionTreeCases : (Src.Module -> Expectation) -> List TestCase
complexDecisionTreeCases expectFn =
    [ { label = "Multiple fallbacks", run = multipleFallbacks expectFn }
    , { label = "Overlapping patterns", run = overlappingPatterns expectFn }
    , { label = "Many branches", run = manyBranches expectFn }
    , { label = "Deep nesting with fallback", run = deepNestingWithFallback expectFn }
    ]


{-| Applies `expectFn` to a module with `classify : ( Int, Int ) -> String`,
which matches `( 0, 0 )`, `( 0, _ )`, `( _, 0 )` and `( 1, 1 )` to "origin",
"y-axis", "x-axis" and "unit", and then a wildcard to "general". `testValue`
is `classify ( 5, 5 )`.
-}
multipleFallbacks : (Src.Module -> Expectation) -> (() -> Expectation)
multipleFallbacks expectFn _ =
    let
        classifyDef : TypedDef
        classifyDef =
            { name = "classify"
            , args = [ pVar "t" ]
            , tipe = tLambda (tTuple (tType "Int" []) (tType "Int" [])) (tType "String" [])
            , body =
                caseExpr (varExpr "t")
                    [ ( pTuple (pInt 0) (pInt 0), strExpr "origin" )
                    , ( pTuple (pInt 0) pAnything, strExpr "y-axis" )
                    , ( pTuple pAnything (pInt 0), strExpr "x-axis" )
                    , ( pTuple (pInt 1) (pInt 1), strExpr "unit" )
                    , ( pAnything, strExpr "general" )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "String" []
            , body = callExpr (varExpr "classify") [ tupleExpr (intExpr 5) (intExpr 5) ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ classifyDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Applies `expectFn` to a module with
`match : ( Maybe Int, Maybe Int ) -> Int`, which has one branch for each of
the four combinations of `Just` and `Nothing` and no wildcard. Despite the
case's label, no two branches match the same value. `testValue` is
`match ( Just 3, Just 4 )`.
-}
overlappingPatterns : (Src.Module -> Expectation) -> (() -> Expectation)
overlappingPatterns expectFn _ =
    let
        matchDef : TypedDef
        matchDef =
            { name = "match"
            , args = [ pVar "t" ]
            , tipe = tLambda (tTuple (tType "Maybe" [ tType "Int" [] ]) (tType "Maybe" [ tType "Int" [] ])) (tType "Int" [])
            , body =
                caseExpr (varExpr "t")
                    [ ( pTuple (pCtor "Just" [ pVar "a" ]) (pCtor "Just" [ pVar "b" ])
                      , binopsExpr [ ( varExpr "a", "+" ) ] (varExpr "b")
                      )
                    , ( pTuple (pCtor "Just" [ pVar "a" ]) (pCtor "Nothing" []), varExpr "a" )
                    , ( pTuple (pCtor "Nothing" []) (pCtor "Just" [ pVar "b" ]), varExpr "b" )
                    , ( pTuple (pCtor "Nothing" []) (pCtor "Nothing" []), intExpr 0 )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "match") [ tupleExpr (callExpr (ctorExpr "Just") [ intExpr 3 ]) (callExpr (ctorExpr "Just") [ intExpr 4 ]) ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ matchDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Applies `expectFn` to a module declaring
`type Day = Mon | Tue | Wed | Thu | Fri | Sat | Sun` and
`isWeekend : Day -> Bool`, which has one branch per constructor and no
wildcard, `True` for `Sat` and `Sun`. `testValue` is `isWeekend Sat`.
-}
manyBranches : (Src.Module -> Expectation) -> (() -> Expectation)
manyBranches expectFn _ =
    let
        dayUnion : UnionDef
        dayUnion =
            { name = "Day"
            , args = []
            , ctors =
                [ { name = "Mon", args = [] }
                , { name = "Tue", args = [] }
                , { name = "Wed", args = [] }
                , { name = "Thu", args = [] }
                , { name = "Fri", args = [] }
                , { name = "Sat", args = [] }
                , { name = "Sun", args = [] }
                ]
            }

        isWeekendDef : TypedDef
        isWeekendDef =
            { name = "isWeekend"
            , args = [ pVar "d" ]
            , tipe = tLambda (tType "Day" []) (tType "Bool" [])
            , body =
                caseExpr (varExpr "d")
                    [ ( pCtor "Mon" [], boolExpr False )
                    , ( pCtor "Tue" [], boolExpr False )
                    , ( pCtor "Wed" [], boolExpr False )
                    , ( pCtor "Thu" [], boolExpr False )
                    , ( pCtor "Fri" [], boolExpr False )
                    , ( pCtor "Sat" [], boolExpr True )
                    , ( pCtor "Sun" [], boolExpr True )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Bool" []
            , body = callExpr (varExpr "isWeekend") [ ctorExpr "Sat" ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ isWeekendDef, testValueDef ]
                [ dayUnion ]
                []
    in
    expectFn modul


{-| Applies `expectFn` to a module with
`extract : ( ( Int, Int ), ( Int, Int ) ) -> Int`, which matches
`( ( 0, 0 ), ( 0, 0 ) )` to 0 and then `( ( a, _ ), ( _, d ) )`, which
matches every value, to `a + d`. `testValue` is
`extract ( ( 1, 2 ), ( 3, 4 ) )`.
-}
deepNestingWithFallback : (Src.Module -> Expectation) -> (() -> Expectation)
deepNestingWithFallback expectFn _ =
    let
        extractDef : TypedDef
        extractDef =
            { name = "extract"
            , args = [ pVar "t" ]
            , tipe = tLambda (tTuple (tTuple (tType "Int" []) (tType "Int" [])) (tTuple (tType "Int" []) (tType "Int" []))) (tType "Int" [])
            , body =
                caseExpr (varExpr "t")
                    [ ( pTuple (pTuple (pInt 0) (pInt 0)) (pTuple (pInt 0) (pInt 0)), intExpr 0 )
                    , ( pTuple (pTuple (pVar "a") pAnything) (pTuple pAnything (pVar "d"))
                      , binopsExpr [ ( varExpr "a", "+" ) ] (varExpr "d")
                      )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "extract") [ tupleExpr (tupleExpr (intExpr 1) (intExpr 2)) (tupleExpr (intExpr 3) (intExpr 4)) ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ extractDef, testValueDef ]
                []
                []
    in
    expectFn modul



-- ============================================================================
-- EDGE CASE PATTERN TESTS
-- ============================================================================


{-| Returns the cases with a one-constructor union, a single wildcard branch,
and a variable branch after literal branches.
-}
edgeCasePatternCases : (Src.Module -> Expectation) -> List TestCase
edgeCasePatternCases expectFn =
    [ { label = "Empty union case", run = emptyUnionCase expectFn }
    , { label = "Single branch case", run = singleBranchCase expectFn }
    , { label = "Redundant wildcard", run = redundantWildcard expectFn }
    ]


{-| Applies `expectFn` to a module declaring `type Void = Void` and
`absurd : Void -> Int`, whose one branch is `Void -> 0`. Despite the case's
label, the union has one constructor, not none. `testValue` is
`absurd Void`.
-}
emptyUnionCase : (Src.Module -> Expectation) -> (() -> Expectation)
emptyUnionCase expectFn _ =
    let
        voidUnion : UnionDef
        voidUnion =
            { name = "Void"
            , args = []
            , ctors = [ { name = "Void", args = [] } ]
            }

        absurdDef : TypedDef
        absurdDef =
            { name = "absurd"
            , args = [ pVar "v" ]
            , tipe = tLambda (tType "Void" []) (tType "Int" [])
            , body =
                caseExpr (varExpr "v")
                    [ ( pCtor "Void" [], intExpr 0 )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "absurd") [ ctorExpr "Void" ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ absurdDef, testValueDef ]
                [ voidUnion ]
                []
    in
    expectFn modul


{-| Applies `expectFn` to a module built with `makeModule` whose `testValue` is
`case 42 of _ -> 0`.
-}
singleBranchCase : (Src.Module -> Expectation) -> (() -> Expectation)
singleBranchCase expectFn _ =
    let
        modul =
            makeModule "testValue"
                (caseExpr (intExpr 42)
                    [ ( pAnything, intExpr 0 )
                    ]
                )
    in
    expectFn modul


{-| Applies `expectFn` to a module built with `makeModule` whose `testValue`
matches 5 against the literals 1 and 2 and then the variable `n`, which it
returns. Despite the case's label, the last branch is a variable, not a
wildcard, and no branch is redundant.
-}
redundantWildcard : (Src.Module -> Expectation) -> (() -> Expectation)
redundantWildcard expectFn _ =
    let
        modul =
            makeModule "testValue"
                (caseExpr (intExpr 5)
                    [ ( pInt 1, intExpr 10 )
                    , ( pInt 2, intExpr 20 )
                    , ( pVar "n", varExpr "n" )
                    ]
                )
    in
    expectFn modul
