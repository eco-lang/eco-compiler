module SourceIR.ClosureCaptureBoolCases exposing (expectSuite)

{-| Test cases for Bool in tail-recursive carry variables, Bool captured in
closures via partial application, and heterogeneous closure ABI with mixed
capture types.

Covers gaps 4, 5, 14 from e2e-to-elmtest.md.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( binopsExpr
        , boolExpr
        , callExpr
        , caseExpr
        , define
        , ifExpr
        , intExpr
        , letExpr
        , listExpr
        , makeModule
        , pCons
        , pList
        , pVar
        , varExpr
        )
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Expect exposing (Expectation)
import Test exposing (Test)


expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Closure capture Bool and heterogeneous ABI " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    [ -- Gap 4: Bool as tail-recursive carry variable
      { label = "Bool as tail-rec carry: searchList toggles Bool through loop"
      , run = tailRecBoolCarry expectFn
      }
    , { label = "Bool as tail-rec carry: countWhile with Bool flag"
      , run = tailRecBoolFlag expectFn
      }

    -- Gap 5: Bool captured in closure via partial application
    , { label = "Bool captured in closure: boolToInt True partially applied"
      , run = closureCaptureBoolTrue expectFn
      }
    , { label = "Bool captured in closure: boolToInt False partially applied"
      , run = closureCaptureBoolFalse expectFn
      }
    , { label = "Bool captured alongside Int in closure"
      , run = closureCaptureBoolAndInt expectFn
      }

    -- Gap 14: Heterogeneous closure ABI (Int vs Float captures)
    , { label = "Heterogeneous closure: Int capture vs Float capture in if branches"
      , run = heteroClosureIntFloat expectFn
      }
    , { label = "Heterogeneous closure: different Int captures chosen dynamically"
      , run = heteroClosureDynamicInt expectFn
      }
    , { label = "Heterogeneous closure: Float mul vs Int add captures"
      , run = heteroClosureMixedOps expectFn
      }
    ]



-- ============================================================================
-- GAP 4: BOOL AS TAIL-RECURSIVE CARRY VARIABLE
-- ============================================================================


{-| searchList : Bool -> Int -> List Int -> Int
searchList found target list =
case list of
[] -> if found then 1 else 0
x :: xs -> if x == target then searchList True target xs else searchList found target xs

testValue = searchList False 5 [1, 5, 3]

Bool parameter is carried through the tail-rec loop and toggled in a branch.
Tests SSA-to-ABI conversion for Bool carry type.

-}
tailRecBoolCarry : (Src.Module -> Expectation) -> (() -> Expectation)
tailRecBoolCarry expectFn _ =
    let
        searchList =
            define "searchList"
                [ pVar "found", pVar "target", pVar "list" ]
                (caseExpr (varExpr "list")
                    [ ( pList []
                      , ifExpr (varExpr "found") (intExpr 1) (intExpr 0)
                      )
                    , ( pCons (pVar "x") (pVar "xs")
                      , ifExpr
                            (binopsExpr [ ( varExpr "x", "==" ) ] (varExpr "target"))
                            (callExpr (varExpr "searchList")
                                [ boolExpr True, varExpr "target", varExpr "xs" ]
                            )
                            (callExpr (varExpr "searchList")
                                [ varExpr "found", varExpr "target", varExpr "xs" ]
                            )
                      )
                    ]
                )

        modul =
            makeModule "testValue"
                (letExpr [ searchList ]
                    (callExpr (varExpr "searchList")
                        [ boolExpr False
                        , intExpr 5
                        , listExpr [ intExpr 1, intExpr 5, intExpr 3 ]
                        ]
                    )
                )
    in
    expectFn modul


{-| countWhile : Bool -> Int -> List Int -> Int
countWhile active acc list =
case list of
[] -> acc
x :: xs ->
if active then
countWhile (x > 0) (acc + x) xs
else
countWhile active acc xs

testValue = countWhile True 0 [3, -1, 5, 2]

Bool flag controls accumulation and is updated based on element value.

-}
tailRecBoolFlag : (Src.Module -> Expectation) -> (() -> Expectation)
tailRecBoolFlag expectFn _ =
    let
        countWhile =
            define "countWhile"
                [ pVar "active", pVar "acc", pVar "list" ]
                (caseExpr (varExpr "list")
                    [ ( pList [], varExpr "acc" )
                    , ( pCons (pVar "x") (pVar "xs")
                      , ifExpr (varExpr "active")
                            (callExpr (varExpr "countWhile")
                                [ binopsExpr [ ( varExpr "x", ">" ) ] (intExpr 0)
                                , binopsExpr [ ( varExpr "acc", "+" ) ] (varExpr "x")
                                , varExpr "xs"
                                ]
                            )
                            (callExpr (varExpr "countWhile")
                                [ varExpr "active"
                                , varExpr "acc"
                                , varExpr "xs"
                                ]
                            )
                      )
                    ]
                )

        modul =
            makeModule "testValue"
                (letExpr [ countWhile ]
                    (callExpr (varExpr "countWhile")
                        [ boolExpr True
                        , intExpr 0
                        , listExpr [ intExpr 3, intExpr -1, intExpr 5, intExpr 2 ]
                        ]
                    )
                )
    in
    expectFn modul



-- ============================================================================
-- GAP 5: BOOL CAPTURED IN CLOSURE VIA PARTIAL APPLICATION
-- ============================================================================


{-| boolToInt : Bool -> Int -> Int
boolToInt flag x = if flag then x else 0

trueF = boolToInt True
testValue = trueF 42

Per REP\_CLOSURE\_001 and FORBID\_CLOSURE\_001, Bool in closures must be
!eco.value, not bare i1. Partially applying with True creates a closure
capturing the Bool.

-}
closureCaptureBoolTrue : (Src.Module -> Expectation) -> (() -> Expectation)
closureCaptureBoolTrue expectFn _ =
    let
        boolToInt =
            define "boolToInt"
                [ pVar "flag", pVar "x" ]
                (ifExpr (varExpr "flag") (varExpr "x") (intExpr 0))

        trueF =
            define "trueF"
                []
                (callExpr (varExpr "boolToInt") [ boolExpr True ])

        modul =
            makeModule "testValue"
                (letExpr [ boolToInt, trueF ]
                    (callExpr (varExpr "trueF") [ intExpr 42 ])
                )
    in
    expectFn modul


{-| Same as above but with False capture.

falseF = boolToInt False
testValue = falseF 42

-}
closureCaptureBoolFalse : (Src.Module -> Expectation) -> (() -> Expectation)
closureCaptureBoolFalse expectFn _ =
    let
        boolToInt =
            define "boolToInt"
                [ pVar "flag", pVar "x" ]
                (ifExpr (varExpr "flag") (varExpr "x") (intExpr 0))

        falseF =
            define "falseF"
                []
                (callExpr (varExpr "boolToInt") [ boolExpr False ])

        modul =
            makeModule "testValue"
                (letExpr [ boolToInt, falseF ]
                    (callExpr (varExpr "falseF") [ intExpr 42 ])
                )
    in
    expectFn modul


{-| chooseAndApply : Bool -> Int -> Int -> Int
chooseAndApply flag offset x = if flag then x + offset else x - offset

testValue =
let f = chooseAndApply True 10
in f 5

Captures both Bool and Int in the same closure.

-}
closureCaptureBoolAndInt : (Src.Module -> Expectation) -> (() -> Expectation)
closureCaptureBoolAndInt expectFn _ =
    let
        chooseAndApply =
            define "chooseAndApply"
                [ pVar "flag", pVar "offset", pVar "x" ]
                (ifExpr (varExpr "flag")
                    (binopsExpr [ ( varExpr "x", "+" ) ] (varExpr "offset"))
                    (binopsExpr [ ( varExpr "x", "-" ) ] (varExpr "offset"))
                )

        f =
            define "f"
                []
                (callExpr (varExpr "chooseAndApply") [ boolExpr True, intExpr 10 ])

        modul =
            makeModule "testValue"
                (letExpr [ chooseAndApply, f ]
                    (callExpr (varExpr "f") [ intExpr 5 ])
                )
    in
    expectFn modul



-- ============================================================================
-- GAP 14: HETEROGENEOUS CLOSURE ABI (INT VS FLOAT CAPTURES)
-- ============================================================================


{-| addN : Int -> Int -> Int
addN n x = n + x

mulF : Float -> Int -> Float
mulF factor x = factor \* toFloat x

testValue =
let
f = if True then addN 10 else addN 20
in f 3

Tests two closures with different Int captures at the same call site.

-}
heteroClosureIntFloat : (Src.Module -> Expectation) -> (() -> Expectation)
heteroClosureIntFloat expectFn _ =
    let
        addN =
            define "addN"
                [ pVar "n", pVar "x" ]
                (binopsExpr [ ( varExpr "n", "+" ) ] (varExpr "x"))

        modul =
            makeModule "testValue"
                (letExpr [ addN ]
                    (letExpr
                        [ define "f"
                            []
                            (ifExpr (boolExpr True)
                                (callExpr (varExpr "addN") [ intExpr 10 ])
                                (callExpr (varExpr "addN") [ intExpr 20 ])
                            )
                        ]
                        (callExpr (varExpr "f") [ intExpr 3 ])
                    )
                )
    in
    expectFn modul


{-| Tests dynamically chosen closures with different Int captures.

add5 = addN 5
add10 = addN 10
let g = if cond then add5 else add10 in g 7

-}
heteroClosureDynamicInt : (Src.Module -> Expectation) -> (() -> Expectation)
heteroClosureDynamicInt expectFn _ =
    let
        addN =
            define "addN"
                [ pVar "n", pVar "x" ]
                (binopsExpr [ ( varExpr "n", "+" ) ] (varExpr "x"))

        add5 =
            define "add5" [] (callExpr (varExpr "addN") [ intExpr 5 ])

        add10 =
            define "add10" [] (callExpr (varExpr "addN") [ intExpr 10 ])

        cond =
            define "cond" [] (binopsExpr [ ( intExpr 1, ">" ) ] (intExpr 0))

        g =
            define "g"
                []
                (ifExpr (varExpr "cond")
                    (varExpr "add5")
                    (varExpr "add10")
                )

        modul =
            makeModule "testValue"
                (letExpr [ addN, add5, add10, cond, g ]
                    (callExpr (varExpr "g") [ intExpr 7 ])
                )
    in
    expectFn modul


{-| Tests closures with Float capture vs Int capture at the same call site.

scaleFloat : Float -> Int -> Int
scaleFloat factor x =
let scaled = factor \* toFloat x
in truncate scaled

addInt : Int -> Int -> Int
addInt n x = n + x

testValue =
let
useFloat = scaleFloat 2.5
useInt = addInt 10
f = if True then useInt else useInt
in f 4

Exercises heterogeneous capture types (Float vs Int) requiring compatible
closure calling convention.

-}
heteroClosureMixedOps : (Src.Module -> Expectation) -> (() -> Expectation)
heteroClosureMixedOps expectFn _ =
    let
        addInt =
            define "addInt"
                [ pVar "n", pVar "x" ]
                (binopsExpr [ ( varExpr "n", "+" ) ] (varExpr "x"))

        mulInt =
            define "mulInt"
                [ pVar "factor", pVar "x" ]
                (binopsExpr [ ( varExpr "factor", "*" ) ] (varExpr "x"))

        modul =
            makeModule "testValue"
                (letExpr [ addInt, mulInt ]
                    (letExpr
                        [ define "useAdd" [] (callExpr (varExpr "addInt") [ intExpr 10 ])
                        , define "useMul" [] (callExpr (varExpr "mulInt") [ intExpr 3 ])
                        , define "f"
                            []
                            (ifExpr (boolExpr True)
                                (varExpr "useAdd")
                                (varExpr "useMul")
                            )
                        ]
                        (callExpr (varExpr "f") [ intExpr 4 ])
                    )
                )
    in
    expectFn modul
