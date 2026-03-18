module SourceIR.ParamArityCases exposing (expectSuite)

{-| Tests for closure parameter arity propagation in GlobalOpt.

These test programs specifically exercise patterns where function-typed
closure parameters must have correct source arity in varSourceArity:

  - HO parameter calls: `f a`, `f a b` where `f` is a closure parameter
  - Captured parameter staging: captured function called in inner closure
  - Local PAPs through parameters: `let p1 = f x in p1 y`

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( callExpr
        , define
        , intExpr
        , lambdaExpr
        , letExpr
        , makeModule
        , pVar
        , tupleExpr
        , varExpr
        )
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Expect exposing (Expectation)
import Test exposing (Test)


expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Param arity cases " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    hoParamCases expectFn
        ++ capturedParamCases expectFn
        ++ localPapCases expectFn



-- ============================================================================
-- HO PARAMETER CALLS
-- ============================================================================


hoParamCases : (Src.Module -> Expectation) -> List TestCase
hoParamCases expectFn =
    [ { label = "HO param: apply f a b", run = hoParamApplyTwo expectFn }
    , { label = "HO param: flip f b a", run = hoParamFlip expectFn }
    , { label = "HO param: single-arg apply", run = hoParamApplyOne expectFn }
    ]


{-| applyTwo f a b = f a b

Tests that `f` as a closure parameter gets correct first-stage arity (2)
so that `f a b` produces a single saturated call, not a PAP + extend.
-}
hoParamApplyTwo : (Src.Module -> Expectation) -> (() -> Expectation)
hoParamApplyTwo expectFn _ =
    let
        -- applyTwo f a b = f a b
        applyTwoFn =
            define "applyTwo"
                [ pVar "f", pVar "a", pVar "b" ]
                (callExpr (varExpr "f") [ varExpr "a", varExpr "b" ])

        add =
            lambdaExpr [ pVar "x", pVar "y" ] (varExpr "x")

        modul =
            makeModule "testValue"
                (letExpr [ applyTwoFn ]
                    (callExpr (varExpr "applyTwo") [ add, intExpr 1, intExpr 2 ])
                )
    in
    expectFn modul


{-| flip f b a = f a b

Tests that `f` as a closure parameter gets correct arity when args are reordered.
-}
hoParamFlip : (Src.Module -> Expectation) -> (() -> Expectation)
hoParamFlip expectFn _ =
    let
        flipFn =
            define "flip"
                [ pVar "f", pVar "b", pVar "a" ]
                (callExpr (varExpr "f") [ varExpr "a", varExpr "b" ])

        sub =
            lambdaExpr [ pVar "x", pVar "y" ] (varExpr "x")

        modul =
            makeModule "testValue"
                (letExpr [ flipFn ]
                    (callExpr (varExpr "flip") [ sub, intExpr 10, intExpr 3 ])
                )
    in
    expectFn modul


{-| applyOne f x = f x

Tests single-arg function parameter.
-}
hoParamApplyOne : (Src.Module -> Expectation) -> (() -> Expectation)
hoParamApplyOne expectFn _ =
    let
        applyOneFn =
            define "applyOne"
                [ pVar "f", pVar "x" ]
                (callExpr (varExpr "f") [ varExpr "x" ])

        identity =
            lambdaExpr [ pVar "y" ] (varExpr "y")

        modul =
            makeModule "testValue"
                (letExpr [ applyOneFn ]
                    (callExpr (varExpr "applyOne") [ identity, intExpr 42 ])
                )
    in
    expectFn modul



-- ============================================================================
-- CAPTURED PARAMETER STAGING
-- ============================================================================


capturedParamCases : (Src.Module -> Expectation) -> List TestCase
capturedParamCases expectFn =
    [ { label = "Captured param: inner closure calls captured f", run = capturedParamInner expectFn }
    , { label = "Captured param: two-arg captured function", run = capturedParamTwoArg expectFn }
    ]


{-| withF f x = let g y = f y in g x

Tests that `f` is correctly captured in the inner closure `g` with proper arity.
-}
capturedParamInner : (Src.Module -> Expectation) -> (() -> Expectation)
capturedParamInner expectFn _ =
    let
        -- withF f x = let g y = f y in g x
        withFFn =
            define "withF"
                [ pVar "f", pVar "x" ]
                (letExpr
                    [ define "g" [ pVar "y" ] (callExpr (varExpr "f") [ varExpr "y" ]) ]
                    (callExpr (varExpr "g") [ varExpr "x" ])
                )

        identity =
            lambdaExpr [ pVar "z" ] (varExpr "z")

        modul =
            makeModule "testValue"
                (letExpr [ withFFn ]
                    (callExpr (varExpr "withF") [ identity, intExpr 7 ])
                )
    in
    expectFn modul


{-| mapPair f k v = (k, f k v)

Tests that captured two-arg function `f` called with both args in inner
lambda gets correct arity so neither arg is dropped.
-}
capturedParamTwoArg : (Src.Module -> Expectation) -> (() -> Expectation)
capturedParamTwoArg expectFn _ =
    let
        -- mapPair f k v = (k, f k v)
        mapPairFn =
            define "mapPair"
                [ pVar "f", pVar "k", pVar "v" ]
                (tupleExpr (varExpr "k") (callExpr (varExpr "f") [ varExpr "k", varExpr "v" ]))

        add =
            lambdaExpr [ pVar "a", pVar "b" ] (varExpr "a")

        modul =
            makeModule "testValue"
                (letExpr [ mapPairFn ]
                    (callExpr (varExpr "mapPair") [ add, intExpr 1, intExpr 2 ])
                )
    in
    expectFn modul



-- ============================================================================
-- LOCAL PAPs THROUGH PARAMETERS
-- ============================================================================


localPapCases : (Src.Module -> Expectation) -> List TestCase
localPapCases expectFn =
    [ { label = "Local PAP: let p1 = f x in p1 y", run = localPapFromParam expectFn }
    , { label = "Local PAP: let p1 = add 5 in p1 10", run = localPapFromGlobal expectFn }
    ]


{-| makeP1 f x y = let p1 = f x in p1 y

Tests that when a parameter `f` is partially applied to produce a local PAP `p1`,
the PAP's remaining arity is correctly computed and stored in varSourceArity.
-}
localPapFromParam : (Src.Module -> Expectation) -> (() -> Expectation)
localPapFromParam expectFn _ =
    let
        -- makeP1 f x y = let p1 = f x in p1 y
        makeP1Fn =
            define "makeP1"
                [ pVar "f", pVar "x", pVar "y" ]
                (letExpr
                    [ define "p1" [] (callExpr (varExpr "f") [ varExpr "x" ]) ]
                    (callExpr (varExpr "p1") [ varExpr "y" ])
                )

        add =
            lambdaExpr [ pVar "a", pVar "b" ] (varExpr "a")

        modul =
            makeModule "testValue"
                (letExpr [ makeP1Fn ]
                    (callExpr (varExpr "makeP1") [ add, intExpr 5, intExpr 10 ])
                )
    in
    expectFn modul


{-| Tests a local PAP from a known global function:
    let add x y = x
        add5 = add 5
    in add5 10

This verifies annotateDefCalls correctly propagates remaining arity.
-}
localPapFromGlobal : (Src.Module -> Expectation) -> (() -> Expectation)
localPapFromGlobal expectFn _ =
    let
        addFn =
            define "add" [ pVar "x", pVar "y" ] (varExpr "x")

        modul =
            makeModule "testValue"
                (letExpr [ addFn ]
                    (letExpr
                        [ define "add5" [] (callExpr (varExpr "add") [ intExpr 5 ]) ]
                        (callExpr (varExpr "add5") [ intExpr 10 ])
                    )
                )
    in
    expectFn modul
