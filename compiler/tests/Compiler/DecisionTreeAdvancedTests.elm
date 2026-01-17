module Compiler.DecisionTreeAdvancedTests exposing (expectSuite)

{-| Advanced test cases for decision tree compilation and pattern matching.

These tests exercise various pattern matching scenarios to improve coverage of:

  - Compiler.Optimize.Typed.DecisionTree.toRelevantBranch
  - Compiler.Optimize.Typed.DecisionTree.toDecisionTree
  - Compiler.Optimize.Typed.DecisionTree.isComplete
  - Compiler.Optimize.Typed.DecisionTree.flatten
  - Compiler.Optimize.Typed.DecisionTree.gatherEdges
  - Compiler.Optimize.Typed.Case

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( AliasDef
        , TypedDef
        , UnionCtor
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
        , pStr
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
import Expect exposing (Expectation)
import Test exposing (Test)


expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.describe ("Decision tree advanced " ++ condStr)
        [ constructorPatternTests expectFn condStr
        , listPatternTests expectFn condStr
        , literalPatternTests expectFn condStr
        , tuplePatternTests expectFn condStr
        , recordPatternTests expectFn condStr
        , wildcardAndVarPatternTests expectFn condStr
        , aliasPatternTests expectFn condStr
        , nestedPatternTests expectFn condStr
        , complexDecisionTreeTests expectFn condStr
        , edgeCasePatternTests expectFn condStr
        ]



-- ============================================================================
-- CONSTRUCTOR PATTERN TESTS (8 tests)
-- ============================================================================


constructorPatternTests : (Src.Module -> Expectation) -> String -> Test
constructorPatternTests expectFn condStr =
    Test.describe ("Constructor patterns " ++ condStr)
        [ Test.test ("Single constructor " ++ condStr) (singleConstructorPattern expectFn)
        , Test.test ("Two constructors " ++ condStr) (twoConstructorPattern expectFn)
        , Test.test ("Three constructors " ++ condStr) (threeConstructorPattern expectFn)
        , Test.test ("Constructor with one arg " ++ condStr) (constructorWithOneArg expectFn)
        , Test.test ("Constructor with multiple args " ++ condStr) (constructorWithMultipleArgs expectFn)
        , Test.test ("Nested constructor " ++ condStr) (nestedConstructorPattern expectFn)
        , Test.test ("Maybe Just pattern " ++ condStr) (maybeJustPattern expectFn)
        , Test.test ("Maybe Nothing pattern " ++ condStr) (maybeNothingPattern expectFn)
        ]


singleConstructorPattern : (Src.Module -> Expectation) -> (() -> Expectation)
singleConstructorPattern expectFn _ =
    let
        -- type Unit = Unit
        unitUnion : UnionDef
        unitUnion =
            { name = "MyUnit"
            , args = []
            , ctors = [ { name = "MyUnit", args = [] } ]
            }

        -- f : MyUnit -> Int
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


twoConstructorPattern : (Src.Module -> Expectation) -> (() -> Expectation)
twoConstructorPattern expectFn _ =
    let
        -- type Bool2 = True2 | False2
        bool2Union : UnionDef
        bool2Union =
            { name = "Bool2"
            , args = []
            , ctors =
                [ { name = "True2", args = [] }
                , { name = "False2", args = [] }
                ]
            }

        -- toBool : Bool2 -> Bool
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


threeConstructorPattern : (Src.Module -> Expectation) -> (() -> Expectation)
threeConstructorPattern expectFn _ =
    let
        -- type Color = Red | Green | Blue
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

        -- toInt : Color -> Int
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


constructorWithOneArg : (Src.Module -> Expectation) -> (() -> Expectation)
constructorWithOneArg expectFn _ =
    let
        -- type Box = Box Int
        boxUnion : UnionDef
        boxUnion =
            { name = "Box"
            , args = []
            , ctors = [ { name = "Box", args = [ tType "Int" [] ] } ]
            }

        -- unbox : Box -> Int
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


constructorWithMultipleArgs : (Src.Module -> Expectation) -> (() -> Expectation)
constructorWithMultipleArgs expectFn _ =
    let
        -- type Pair = Pair Int Int
        pairUnion : UnionDef
        pairUnion =
            { name = "Pair"
            , args = []
            , ctors = [ { name = "Pair", args = [ tType "Int" [], tType "Int" [] ] } ]
            }

        -- sum : Pair -> Int
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


nestedConstructorPattern : (Src.Module -> Expectation) -> (() -> Expectation)
nestedConstructorPattern expectFn _ =
    let
        -- type Wrap = Wrap Box
        -- type Box = Box Int
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

        -- unwrap : Wrap -> Int
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


maybeJustPattern : (Src.Module -> Expectation) -> (() -> Expectation)
maybeJustPattern expectFn _ =
    let
        -- withDefault : Int -> Maybe Int -> Int
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


maybeNothingPattern : (Src.Module -> Expectation) -> (() -> Expectation)
maybeNothingPattern expectFn _ =
    let
        -- isNothing : Maybe Int -> Bool
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
-- LIST PATTERN TESTS (6 tests)
-- ============================================================================


listPatternTests : (Src.Module -> Expectation) -> String -> Test
listPatternTests expectFn condStr =
    Test.describe ("List patterns " ++ condStr)
        [ Test.test ("Empty list pattern " ++ condStr) (emptyListPattern expectFn)
        , Test.test ("Singleton list pattern " ++ condStr) (singletonListPattern expectFn)
        , Test.test ("Two element list pattern " ++ condStr) (twoElementListPattern expectFn)
        , Test.test ("Cons pattern " ++ condStr) (consPattern expectFn)
        , Test.test ("Multiple cons pattern " ++ condStr) (multipleConsPattern expectFn)
        , Test.test ("List pattern with fallback " ++ condStr) (listPatternWithFallback expectFn)
        ]


emptyListPattern : (Src.Module -> Expectation) -> (() -> Expectation)
emptyListPattern expectFn _ =
    let
        -- isEmpty : List Int -> Bool
        isEmptyDef : TypedDef
        isEmptyDef =
            { name = "isEmpty"
            , args = [ pVar "xs" ]
            , tipe = tLambda (tType "List" [ tType "Int" [] ]) (tType "Bool" [])
            , body =
                caseExpr (varExpr "xs")
                    [ ( pList [], boolExpr True )
                    , ( pCons pAnything pAnything, boolExpr False )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Bool" []
            , body = callExpr (varExpr "isEmpty") [ listExpr [] ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ isEmptyDef, testValueDef ]
                []
                []
    in
    expectFn modul


singletonListPattern : (Src.Module -> Expectation) -> (() -> Expectation)
singletonListPattern expectFn _ =
    let
        -- isSingleton : List Int -> Bool
        isSingletonDef : TypedDef
        isSingletonDef =
            { name = "isSingleton"
            , args = [ pVar "xs" ]
            , tipe = tLambda (tType "List" [ tType "Int" [] ]) (tType "Bool" [])
            , body =
                caseExpr (varExpr "xs")
                    [ ( pList [ pVar "_" ], boolExpr True )
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


twoElementListPattern : (Src.Module -> Expectation) -> (() -> Expectation)
twoElementListPattern expectFn _ =
    let
        -- sumTwo : List Int -> Int
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


consPattern : (Src.Module -> Expectation) -> (() -> Expectation)
consPattern expectFn _ =
    let
        -- head : List Int -> Int
        headDef : TypedDef
        headDef =
            { name = "head"
            , args = [ pVar "xs" ]
            , tipe = tLambda (tType "List" [ tType "Int" [] ]) (tType "Int" [])
            , body =
                caseExpr (varExpr "xs")
                    [ ( pCons (pVar "x") (pVar "_"), varExpr "x" )
                    , ( pList [], intExpr 0 )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "head") [ listExpr [ intExpr 10, intExpr 20 ] ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ headDef, testValueDef ]
                []
                []
    in
    expectFn modul


multipleConsPattern : (Src.Module -> Expectation) -> (() -> Expectation)
multipleConsPattern expectFn _ =
    let
        -- sumFirstTwo : List Int -> Int
        sumFirstTwoDef : TypedDef
        sumFirstTwoDef =
            { name = "sumFirstTwo"
            , args = [ pVar "xs" ]
            , tipe = tLambda (tType "List" [ tType "Int" [] ]) (tType "Int" [])
            , body =
                caseExpr (varExpr "xs")
                    [ ( pCons (pVar "a") (pCons (pVar "b") (pVar "_")), binopsExpr [ ( varExpr "a", "+" ) ] (varExpr "b") )
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


listPatternWithFallback : (Src.Module -> Expectation) -> (() -> Expectation)
listPatternWithFallback expectFn _ =
    let
        -- classify : List Int -> String
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
-- LITERAL PATTERN TESTS (6 tests)
-- ============================================================================


literalPatternTests : (Src.Module -> Expectation) -> String -> Test
literalPatternTests expectFn condStr =
    Test.describe ("Literal patterns " ++ condStr)
        [ Test.test ("Int literal pattern " ++ condStr) (intLiteralPattern expectFn)
        , Test.test ("Multiple int patterns " ++ condStr) (multipleIntPatterns expectFn)
        , Test.test ("String literal pattern " ++ condStr) (stringLiteralPattern expectFn)
        , Test.test ("Char literal pattern " ++ condStr) (charLiteralPattern expectFn)
        , Test.test ("Multiple char patterns " ++ condStr) (multipleCharPatterns expectFn)
        , Test.test ("Unit pattern " ++ condStr) (unitPattern expectFn)
        ]


intLiteralPattern : (Src.Module -> Expectation) -> (() -> Expectation)
intLiteralPattern expectFn _ =
    let
        -- isZero : Int -> Bool
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


multipleIntPatterns : (Src.Module -> Expectation) -> (() -> Expectation)
multipleIntPatterns expectFn _ =
    let
        -- describe : Int -> String
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


stringLiteralPattern : (Src.Module -> Expectation) -> (() -> Expectation)
stringLiteralPattern expectFn _ =
    let
        -- greet : String -> String
        greetDef : TypedDef
        greetDef =
            { name = "greet"
            , args = [ pVar "name" ]
            , tipe = tLambda (tType "String" []) (tType "String" [])
            , body =
                caseExpr (varExpr "name")
                    [ ( pStr "Alice", strExpr "Hello Alice!" )
                    , ( pStr "Bob", strExpr "Hi Bob!" )
                    , ( pAnything, strExpr "Hello stranger!" )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "String" []
            , body = callExpr (varExpr "greet") [ strExpr "Alice" ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ greetDef, testValueDef ]
                []
                []
    in
    expectFn modul


charLiteralPattern : (Src.Module -> Expectation) -> (() -> Expectation)
charLiteralPattern expectFn _ =
    let
        -- isVowel : Char -> Bool
        isVowelDef : TypedDef
        isVowelDef =
            { name = "isVowel"
            , args = [ pVar "c" ]
            , tipe = tLambda (tType "Char" []) (tType "Bool" [])
            , body =
                caseExpr (varExpr "c")
                    [ ( pChr "a", boolExpr True )
                    , ( pChr "e", boolExpr True )
                    , ( pChr "i", boolExpr True )
                    , ( pChr "o", boolExpr True )
                    , ( pChr "u", boolExpr True )
                    , ( pAnything, boolExpr False )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Bool" []
            , body = callExpr (varExpr "isVowel") [ chrExpr "e" ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ isVowelDef, testValueDef ]
                []
                []
    in
    expectFn modul


multipleCharPatterns : (Src.Module -> Expectation) -> (() -> Expectation)
multipleCharPatterns expectFn _ =
    let
        -- charType : Char -> Int
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


unitPattern : (Src.Module -> Expectation) -> (() -> Expectation)
unitPattern expectFn _ =
    let
        -- Test matching against unit pattern using a simple let
        -- let _ = () in 0
        modul =
            letExpr
                [ define "result" [ pUnit ] (intExpr 42) ]
                (callExpr (varExpr "result") [ unitExpr ])
                |> makeModule "testValue"
    in
    expectFn modul



-- ============================================================================
-- TUPLE PATTERN TESTS (4 tests)
-- ============================================================================


tuplePatternTests : (Src.Module -> Expectation) -> String -> Test
tuplePatternTests expectFn condStr =
    Test.describe ("Tuple patterns " ++ condStr)
        [ Test.test ("Tuple2 pattern " ++ condStr) (tuple2Pattern expectFn)
        , Test.test ("Tuple3 pattern " ++ condStr) (tuple3Pattern expectFn)
        , Test.test ("Nested tuple pattern " ++ condStr) (nestedTuplePattern expectFn)
        , Test.test ("Tuple with literals " ++ condStr) (tupleWithLiterals expectFn)
        ]


tuple2Pattern : (Src.Module -> Expectation) -> (() -> Expectation)
tuple2Pattern expectFn _ =
    let
        -- swap : ( Int, Int ) -> ( Int, Int )
        swapDef : TypedDef
        swapDef =
            { name = "swap"
            , args = [ pVar "t" ]
            , tipe = tLambda (tTuple (tType "Int" []) (tType "Int" [])) (tTuple (tType "Int" []) (tType "Int" []))
            , body =
                caseExpr (varExpr "t")
                    [ ( pTuple (pVar "a") (pVar "b"), tupleExpr (varExpr "b") (varExpr "a") )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tTuple (tType "Int" []) (tType "Int" [])
            , body = callExpr (varExpr "swap") [ tupleExpr (intExpr 1) (intExpr 2) ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ swapDef, testValueDef ]
                []
                []
    in
    expectFn modul


tuple3Pattern : (Src.Module -> Expectation) -> (() -> Expectation)
tuple3Pattern expectFn _ =
    let
        -- Test 3-tuple pattern matching using let with a case
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


nestedTuplePattern : (Src.Module -> Expectation) -> (() -> Expectation)
nestedTuplePattern expectFn _ =
    let
        -- extractInner : ( ( Int, Int ), Int ) -> Int
        extractInnerDef : TypedDef
        extractInnerDef =
            { name = "extractInner"
            , args = [ pVar "t" ]
            , tipe = tLambda (tTuple (tTuple (tType "Int" []) (tType "Int" [])) (tType "Int" [])) (tType "Int" [])
            , body =
                caseExpr (varExpr "t")
                    [ ( pTuple (pTuple (pVar "a") (pVar "b")) (pVar "c")
                      , binopsExpr [ ( varExpr "a", "+" ), ( varExpr "b", "+" ) ] (varExpr "c")
                      )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "extractInner") [ tupleExpr (tupleExpr (intExpr 1) (intExpr 2)) (intExpr 3) ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ extractInnerDef, testValueDef ]
                []
                []
    in
    expectFn modul


tupleWithLiterals : (Src.Module -> Expectation) -> (() -> Expectation)
tupleWithLiterals expectFn _ =
    let
        -- checkPair : ( Int, Int ) -> String
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
-- RECORD PATTERN TESTS (4 tests)
-- ============================================================================


recordPatternTests : (Src.Module -> Expectation) -> String -> Test
recordPatternTests expectFn condStr =
    Test.describe ("Record patterns " ++ condStr)
        [ Test.test ("Simple record pattern " ++ condStr) (simpleRecordPattern expectFn)
        , Test.test ("Multi-field record pattern " ++ condStr) (multiFieldRecordPattern expectFn)
        , Test.test ("Partial record pattern " ++ condStr) (partialRecordPattern expectFn)
        , Test.test ("Nested record pattern " ++ condStr) (nestedRecordPattern expectFn)
        ]


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
-- WILDCARD AND VAR PATTERN TESTS (4 tests)
-- ============================================================================


wildcardAndVarPatternTests : (Src.Module -> Expectation) -> String -> Test
wildcardAndVarPatternTests expectFn condStr =
    Test.describe ("Wildcard and var patterns " ++ condStr)
        [ Test.test ("Wildcard pattern " ++ condStr) (wildcardPattern expectFn)
        , Test.test ("Variable pattern " ++ condStr) (variablePattern expectFn)
        , Test.test ("Mixed wildcard and var " ++ condStr) (mixedWildcardAndVar expectFn)
        , Test.test ("All wildcards " ++ condStr) (allWildcards expectFn)
        ]


wildcardPattern : (Src.Module -> Expectation) -> (() -> Expectation)
wildcardPattern expectFn _ =
    let
        -- always : Int -> Int -> Int
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


variablePattern : (Src.Module -> Expectation) -> (() -> Expectation)
variablePattern expectFn _ =
    let
        -- id : Int -> Int
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


mixedWildcardAndVar : (Src.Module -> Expectation) -> (() -> Expectation)
mixedWildcardAndVar expectFn _ =
    let
        -- first : ( Int, Int ) -> Int
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


allWildcards : (Src.Module -> Expectation) -> (() -> Expectation)
allWildcards expectFn _ =
    let
        -- ignore : Int -> Int -> Int
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
-- ALIAS PATTERN TESTS (3 tests)
-- ============================================================================


aliasPatternTests : (Src.Module -> Expectation) -> String -> Test
aliasPatternTests expectFn condStr =
    Test.describe ("Alias patterns " ++ condStr)
        [ Test.test ("Simple alias pattern " ++ condStr) (simpleAliasPattern expectFn)
        , Test.test ("Alias with constructor " ++ condStr) (aliasWithConstructor expectFn)
        , Test.test ("Alias with tuple " ++ condStr) (aliasWithTuple expectFn)
        ]


simpleAliasPattern : (Src.Module -> Expectation) -> (() -> Expectation)
simpleAliasPattern expectFn _ =
    let
        -- useAlias : Int -> Int
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


aliasWithConstructor : (Src.Module -> Expectation) -> (() -> Expectation)
aliasWithConstructor expectFn _ =
    let
        -- extractWithAlias : Maybe Int -> Int
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


aliasWithTuple : (Src.Module -> Expectation) -> (() -> Expectation)
aliasWithTuple expectFn _ =
    let
        -- sumWithAlias : ( Int, Int ) -> Int
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
-- NESTED PATTERN TESTS (4 tests)
-- ============================================================================


nestedPatternTests : (Src.Module -> Expectation) -> String -> Test
nestedPatternTests expectFn condStr =
    Test.describe ("Nested patterns " ++ condStr)
        [ Test.test ("Deeply nested constructor " ++ condStr) (deeplyNestedConstructor expectFn)
        , Test.test ("List of tuples pattern " ++ condStr) (listOfTuplesPattern expectFn)
        , Test.test ("Tuple of lists pattern " ++ condStr) (tupleOfListsPattern expectFn)
        , Test.test ("Constructor with list " ++ condStr) (constructorWithList expectFn)
        ]


deeplyNestedConstructor : (Src.Module -> Expectation) -> (() -> Expectation)
deeplyNestedConstructor expectFn _ =
    let
        -- type Nest = Leaf Int | Node Nest Nest
        nestUnion : UnionDef
        nestUnion =
            { name = "Nest"
            , args = []
            , ctors =
                [ { name = "Leaf", args = [ tType "Int" [] ] }
                , { name = "Node", args = [ tType "Nest" [], tType "Nest" [] ] }
                ]
            }

        -- extractLeft : Nest -> Int
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


listOfTuplesPattern : (Src.Module -> Expectation) -> (() -> Expectation)
listOfTuplesPattern expectFn _ =
    let
        -- firstPairSum : List ( Int, Int ) -> Int
        firstPairSumDef : TypedDef
        firstPairSumDef =
            { name = "firstPairSum"
            , args = [ pVar "xs" ]
            , tipe = tLambda (tType "List" [ tTuple (tType "Int" []) (tType "Int" []) ]) (tType "Int" [])
            , body =
                caseExpr (varExpr "xs")
                    [ ( pCons (pTuple (pVar "a") (pVar "b")) (pVar "_"), binopsExpr [ ( varExpr "a", "+" ) ] (varExpr "b") )
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


tupleOfListsPattern : (Src.Module -> Expectation) -> (() -> Expectation)
tupleOfListsPattern expectFn _ =
    let
        -- bothHeads : ( List Int, List Int ) -> Int
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


constructorWithList : (Src.Module -> Expectation) -> (() -> Expectation)
constructorWithList expectFn _ =
    let
        -- type Container = Container (List Int)
        containerUnion : UnionDef
        containerUnion =
            { name = "Container"
            , args = []
            , ctors = [ { name = "Container", args = [ tType "List" [ tType "Int" [] ] ] } ]
            }

        -- headOfContainer : Container -> Int
        headOfContainerDef : TypedDef
        headOfContainerDef =
            { name = "headOfContainer"
            , args = [ pVar "c" ]
            , tipe = tLambda (tType "Container" []) (tType "Int" [])
            , body =
                caseExpr (varExpr "c")
                    [ ( pCtor "Container" [ pCons (pVar "x") (pVar "_") ], varExpr "x" )
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
-- COMPLEX DECISION TREE TESTS (4 tests)
-- ============================================================================


complexDecisionTreeTests : (Src.Module -> Expectation) -> String -> Test
complexDecisionTreeTests expectFn condStr =
    Test.describe ("Complex decision trees " ++ condStr)
        [ Test.test ("Multiple fallbacks " ++ condStr) (multipleFallbacks expectFn)
        , Test.test ("Overlapping patterns " ++ condStr) (overlappingPatterns expectFn)
        , Test.test ("Many branches " ++ condStr) (manyBranches expectFn)
        , Test.test ("Deep nesting with fallback " ++ condStr) (deepNestingWithFallback expectFn)
        ]


multipleFallbacks : (Src.Module -> Expectation) -> (() -> Expectation)
multipleFallbacks expectFn _ =
    let
        -- classify : ( Int, Int ) -> String
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


overlappingPatterns : (Src.Module -> Expectation) -> (() -> Expectation)
overlappingPatterns expectFn _ =
    let
        -- match : ( Maybe Int, Maybe Int ) -> Int
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


manyBranches : (Src.Module -> Expectation) -> (() -> Expectation)
manyBranches expectFn _ =
    let
        -- type Day = Mon | Tue | Wed | Thu | Fri | Sat | Sun
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

        -- isWeekend : Day -> Bool
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


deepNestingWithFallback : (Src.Module -> Expectation) -> (() -> Expectation)
deepNestingWithFallback expectFn _ =
    let
        -- extract : ( ( Int, Int ), ( Int, Int ) ) -> Int
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
-- EDGE CASE PATTERN TESTS (3 tests)
-- ============================================================================


edgeCasePatternTests : (Src.Module -> Expectation) -> String -> Test
edgeCasePatternTests expectFn condStr =
    Test.describe ("Edge case patterns " ++ condStr)
        [ Test.test ("Empty union case " ++ condStr) (emptyUnionCase expectFn)
        , Test.test ("Single branch case " ++ condStr) (singleBranchCase expectFn)
        , Test.test ("Redundant wildcard " ++ condStr) (redundantWildcard expectFn)
        ]


emptyUnionCase : (Src.Module -> Expectation) -> (() -> Expectation)
emptyUnionCase expectFn _ =
    let
        -- type Void = Void
        voidUnion : UnionDef
        voidUnion =
            { name = "Void"
            , args = []
            , ctors = [ { name = "Void", args = [] } ]
            }

        -- absurd : Void -> Int
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


redundantWildcard : (Src.Module -> Expectation) -> (() -> Expectation)
redundantWildcard expectFn _ =
    let
        -- Note: This pattern has a wildcard that matches everything after specific cases
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
