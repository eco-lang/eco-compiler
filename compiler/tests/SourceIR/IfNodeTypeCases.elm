module SourceIR.IfNodeTypeCases exposing (expectSuite)

{-| Test cases for if-expression node types with structured annotation types.

These tests exercise the constraint generation path in constrainIfWithIdsProg
where the annotation type is a structured type (not a bare VarN). The case
expression's constrainCaseWithIdsProg adds a CEqual constraint for the fresh
flex var in this scenario, but the if expression path historically did not.

Tests cover:

  - If returning List a inside a polymorphic function
  - If returning Maybe a with constructor branches
  - Nested if expressions with parameterized types
  - If in a let binding with structured type annotation
  - If returning function types (closure-producing branches)
  - Polymorphic function with if body, specialized at concrete type (MONO\_025 trigger)

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( TypedDef
        , binopsExpr
        , boolExpr
        , callExpr
        , caseExpr
        , ctorExpr
        , define
        , ifExpr
        , intExpr
        , lambdaExpr
        , letExpr
        , listExpr
        , makeModuleWithTypedDefsUnionsAliases
        , pCtor
        , pVar
        , tLambda
        , tType
        , tVar
        , varExpr
        )
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Expect exposing (Expectation)
import Test exposing (Test)


expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("If node type " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    [ { label = "If returning List a in polymorphic fn", run = ifReturningListA expectFn }
    , { label = "If returning Maybe a with constructors", run = ifReturningMaybeA expectFn }
    , { label = "Nested if with parameterized type", run = nestedIfParameterized expectFn }
    , { label = "If in let with structured annotation", run = ifInLetStructuredAnnotation expectFn }
    , { label = "If returning function type", run = ifReturningFunctionType expectFn }
    , { label = "Polymorphic if body specialized at Int", run = polyIfBodySpecialized expectFn }
    ]



-- ============================================================================
-- TYPE HELPERS
-- ============================================================================


tInt : Src.Type
tInt =
    tType "Int" []


tBool : Src.Type
tBool =
    tType "Bool" []


tList : Src.Type -> Src.Type
tList a =
    tType "List" [ a ]


tMaybe : Src.Type -> Src.Type
tMaybe a =
    tType "Maybe" [ a ]



-- ============================================================================
-- TEST A: If returning List a inside a polymorphic function
-- ============================================================================
-- identity : List a -> List a
-- identity xs =
--     if True then xs else xs
--
-- testValue : List Int
-- testValue = identity [1, 2]


ifReturningListA : (Src.Module -> Expectation) -> (() -> Expectation)
ifReturningListA expectFn _ =
    let
        identityDef : TypedDef
        identityDef =
            { name = "identity"
            , args = [ pVar "xs" ]
            , tipe = tLambda (tList (tVar "a")) (tList (tVar "a"))
            , body =
                ifExpr
                    (boolExpr True)
                    (varExpr "xs")
                    (varExpr "xs")
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tList tInt
            , body = callExpr (varExpr "identity") [ listExpr [ intExpr 1, intExpr 2 ] ]
            }
    in
    expectFn
        (makeModuleWithTypedDefsUnionsAliases "Test"
            [ identityDef, testValueDef ]
            []
            []
        )



-- ============================================================================
-- TEST B: If returning Maybe a with constructors
-- ============================================================================
-- keepPositive : Maybe Int -> Maybe Int
-- keepPositive mx =
--     case mx of
--         Just x ->
--             if x > 0 then mx else Nothing
--         Nothing ->
--             Nothing
--
-- testValue : Maybe Int
-- testValue = keepPositive (Just 42)


ifReturningMaybeA : (Src.Module -> Expectation) -> (() -> Expectation)
ifReturningMaybeA expectFn _ =
    let
        keepPositiveDef : TypedDef
        keepPositiveDef =
            { name = "keepPositive"
            , args = [ pVar "mx" ]
            , tipe = tLambda (tMaybe tInt) (tMaybe tInt)
            , body =
                caseExpr (varExpr "mx")
                    [ ( pCtor "Just" [ pVar "x" ]
                      , ifExpr
                            (binopsExpr [ ( varExpr "x", ">" ) ] (intExpr 0))
                            (varExpr "mx")
                            (ctorExpr "Nothing")
                      )
                    , ( pCtor "Nothing" [], ctorExpr "Nothing" )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tMaybe tInt
            , body = callExpr (varExpr "keepPositive") [ callExpr (ctorExpr "Just") [ intExpr 42 ] ]
            }
    in
    expectFn
        (makeModuleWithTypedDefsUnionsAliases "Test"
            [ keepPositiveDef, testValueDef ]
            []
            []
        )



-- ============================================================================
-- TEST C: Nested if expressions with parameterized types
-- ============================================================================
-- choose : Bool -> Bool -> Maybe a -> Maybe a -> Maybe a
-- choose x y a b =
--     if x then
--         if y then a else b
--     else
--         if y then b else a
--
-- testValue : Maybe Int
-- testValue = choose True False (Just 1) (Just 2)


nestedIfParameterized : (Src.Module -> Expectation) -> (() -> Expectation)
nestedIfParameterized expectFn _ =
    let
        chooseDef : TypedDef
        chooseDef =
            { name = "choose"
            , args = [ pVar "x", pVar "y", pVar "a", pVar "b" ]
            , tipe =
                tLambda tBool
                    (tLambda tBool
                        (tLambda (tMaybe (tVar "t"))
                            (tLambda (tMaybe (tVar "t")) (tMaybe (tVar "t")))
                        )
                    )
            , body =
                ifExpr
                    (varExpr "x")
                    (ifExpr (varExpr "y") (varExpr "a") (varExpr "b"))
                    (ifExpr (varExpr "y") (varExpr "b") (varExpr "a"))
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tMaybe tInt
            , body =
                callExpr (varExpr "choose")
                    [ boolExpr True
                    , boolExpr False
                    , callExpr (ctorExpr "Just") [ intExpr 1 ]
                    , callExpr (ctorExpr "Just") [ intExpr 2 ]
                    ]
            }
    in
    expectFn
        (makeModuleWithTypedDefsUnionsAliases "Test"
            [ chooseDef, testValueDef ]
            []
            []
        )



-- ============================================================================
-- TEST D: If in a let binding with structured type annotation
-- ============================================================================
-- pick : Bool -> List Int
-- pick flag =
--     let
--         result : List Int
--         result =
--             if flag then [1, 2] else [3, 4]
--     in
--     result
--
-- testValue : List Int
-- testValue = pick True


ifInLetStructuredAnnotation : (Src.Module -> Expectation) -> (() -> Expectation)
ifInLetStructuredAnnotation expectFn _ =
    let
        pickDef : TypedDef
        pickDef =
            { name = "pick"
            , args = [ pVar "flag" ]
            , tipe = tLambda tBool (tList tInt)
            , body =
                letExpr
                    [ define "result"
                        []
                        (ifExpr
                            (varExpr "flag")
                            (listExpr [ intExpr 1, intExpr 2 ])
                            (listExpr [ intExpr 3, intExpr 4 ])
                        )
                    ]
                    (varExpr "result")
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tList tInt
            , body = callExpr (varExpr "pick") [ boolExpr True ]
            }
    in
    expectFn
        (makeModuleWithTypedDefsUnionsAliases "Test"
            [ pickDef, testValueDef ]
            []
            []
        )



-- ============================================================================
-- TEST E: If expression returning function type
-- ============================================================================
-- pickFn : Bool -> (List a -> List a)
-- pickFn flag =
--     if flag then
--         \xs -> xs
--     else
--         \xs -> xs
--
-- testValue : List Int
-- testValue = pickFn True [1, 2, 3]


ifReturningFunctionType : (Src.Module -> Expectation) -> (() -> Expectation)
ifReturningFunctionType expectFn _ =
    let
        pickFnDef : TypedDef
        pickFnDef =
            { name = "pickFn"
            , args = [ pVar "flag" ]
            , tipe = tLambda tBool (tLambda (tList (tVar "a")) (tList (tVar "a")))
            , body =
                ifExpr
                    (varExpr "flag")
                    (lambdaExpr [ pVar "xs" ] (varExpr "xs"))
                    (lambdaExpr [ pVar "xs" ] (varExpr "xs"))
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tList tInt
            , body =
                callExpr
                    (callExpr (varExpr "pickFn") [ boolExpr True ])
                    [ listExpr [ intExpr 1, intExpr 2, intExpr 3 ] ]
            }
    in
    expectFn
        (makeModuleWithTypedDefsUnionsAliases "Test"
            [ pickFnDef, testValueDef ]
            []
            []
        )



-- ============================================================================
-- TEST F: Polymorphic function with if body, specialized at concrete type
-- ============================================================================
-- transform : (a -> a) -> List a -> List a
-- transform f xs =
--     if True then
--         xs
--     else
--         xs
--
-- testValue : List Int
-- testValue = transform (\x -> x + 1) [1, 2, 3]


polyIfBodySpecialized : (Src.Module -> Expectation) -> (() -> Expectation)
polyIfBodySpecialized expectFn _ =
    let
        transformDef : TypedDef
        transformDef =
            { name = "transform"
            , args = [ pVar "f", pVar "xs" ]
            , tipe =
                tLambda (tLambda (tVar "a") (tVar "a"))
                    (tLambda (tList (tVar "a")) (tList (tVar "a")))
            , body =
                ifExpr
                    (boolExpr True)
                    (varExpr "xs")
                    (varExpr "xs")
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tList tInt
            , body =
                callExpr (varExpr "transform")
                    [ lambdaExpr [ pVar "x" ] (binopsExpr [ ( varExpr "x", "+" ) ] (intExpr 1))
                    , listExpr [ intExpr 1, intExpr 2, intExpr 3 ]
                    ]
            }
    in
    expectFn
        (makeModuleWithTypedDefsUnionsAliases "Test"
            [ transformDef, testValueDef ]
            []
            []
        )
