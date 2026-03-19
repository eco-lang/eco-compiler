module SourceIR.CombinatorStdlibCases exposing (expectSuite)

{-| Tests for SKI-style combinators applied to stdlib operations (lists, strings).

These test cases correspond to the E2E tests in test/elm/src/CombinatorListStringTest.elm,
using combinators with List.map, List.foldl, List.length, String.reverse, etc.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( binopsExpr
        , callExpr
        , define
        , intExpr
        , lambdaExpr
        , letExpr
        , listExpr
        , makeModule
        , pAnything
        , pVar
        , qualVarExpr
        , strExpr
        , varExpr
        )
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Expect exposing (Expectation)
import Test exposing (Test)


expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("SKI combinator stdlib tests " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    listCombinatorCases expectFn
        ++ stringCombinatorCases expectFn
        ++ multiArgCombinatorCases expectFn



-- ============================================================================
-- COMBINATORS WITH LIST OPERATIONS (3 tests)
-- ============================================================================


listCombinatorCases : (Src.Module -> Expectation) -> List TestCase
listCombinatorCases expectFn =
    [ { label = "B combinator: compose foldl and map on list", run = bComposeListOps expectFn }
    , { label = "T combinator: pipe list into composed ops", run = tPipeList expectFn }
    , { label = "P combinator: add lengths of two lists", run = pAddLengths expectFn }
    ]


{-| b f g x = f (g x)
sum xs = List.foldl (+) 0 xs
testValue = b sum (List.map (\x -> x + 1)) [1, 2, 3]
-- [1,2,3] -> [2,3,4] -> 9
-}
bComposeListOps : (Src.Module -> Expectation) -> (() -> Expectation)
bComposeListOps expectFn _ =
    let
        kDef =
            define "k" [ pVar "a", pAnything ] (varExpr "a")

        sDef =
            define "s"
                [ pVar "bf", pVar "uf", pVar "x" ]
                (callExpr (varExpr "bf")
                    [ varExpr "x"
                    , callExpr (varExpr "uf") [ varExpr "x" ]
                    ]
                )

        bDef =
            define "b" []
                (callExpr (varExpr "s")
                    [ callExpr (varExpr "k") [ varExpr "s" ]
                    , varExpr "k"
                    ]
                )

        sumDef =
            define "mySum"
                [ pVar "xs" ]
                (callExpr (qualVarExpr "List" "foldl")
                    [ lambdaExpr [ pVar "a", pVar "acc" ] (binopsExpr [ ( varExpr "a", "+" ) ] (varExpr "acc"))
                    , intExpr 0
                    , varExpr "xs"
                    ]
                )

        mapInc =
            define "mapInc"
                [ pVar "xs" ]
                (callExpr (qualVarExpr "List" "map")
                    [ lambdaExpr [ pVar "x" ] (binopsExpr [ ( varExpr "x", "+" ) ] (intExpr 1))
                    , varExpr "xs"
                    ]
                )

        modul =
            makeModule "testValue"
                (letExpr [ kDef, sDef, bDef, sumDef, mapInc ]
                    (callExpr (varExpr "b")
                        [ varExpr "mySum"
                        , varExpr "mapInc"
                        , listExpr [ intExpr 1, intExpr 2, intExpr 3 ]
                        ]
                    )
                )
    in
    expectFn modul


{-| t x f = f x (thrush / pipe-forward)
b f g x = f (g x)
sum xs = List.foldl (+) 0 xs
testValue = t [1,2,3] (b sum (List.map (\x -> x * 2)))
-- [1,2,3] -> [2,4,6] -> 12
-}
tPipeList : (Src.Module -> Expectation) -> (() -> Expectation)
tPipeList expectFn _ =
    let
        kDef =
            define "k" [ pVar "a", pAnything ] (varExpr "a")

        sDef =
            define "s"
                [ pVar "bf", pVar "uf", pVar "x" ]
                (callExpr (varExpr "bf")
                    [ varExpr "x"
                    , callExpr (varExpr "uf") [ varExpr "x" ]
                    ]
                )

        bDef =
            define "b" []
                (callExpr (varExpr "s")
                    [ callExpr (varExpr "k") [ varExpr "s" ]
                    , varExpr "k"
                    ]
                )

        cDef =
            define "c" []
                (callExpr (varExpr "s")
                    [ callExpr (varExpr "b") [ varExpr "b", varExpr "s" ]
                    , callExpr (varExpr "k") [ varExpr "k" ]
                    ]
                )

        iDef =
            define "i" [] (callExpr (varExpr "s") [ varExpr "k", varExpr "k" ])

        tDef =
            define "t" [] (callExpr (varExpr "c") [ varExpr "i" ])

        sumDef =
            define "mySum"
                [ pVar "xs" ]
                (callExpr (qualVarExpr "List" "foldl")
                    [ lambdaExpr [ pVar "a", pVar "acc" ] (binopsExpr [ ( varExpr "a", "+" ) ] (varExpr "acc"))
                    , intExpr 0
                    , varExpr "xs"
                    ]
                )

        mapDouble =
            define "mapDouble"
                [ pVar "xs" ]
                (callExpr (qualVarExpr "List" "map")
                    [ lambdaExpr [ pVar "x" ] (binopsExpr [ ( varExpr "x", "*" ) ] (intExpr 2))
                    , varExpr "xs"
                    ]
                )

        composed =
            define "composed" []
                (callExpr (varExpr "b") [ varExpr "mySum", varExpr "mapDouble" ])

        modul =
            makeModule "testValue"
                (letExpr [ kDef, sDef, bDef, cDef, iDef, tDef, sumDef, mapDouble, composed ]
                    (callExpr (varExpr "t")
                        [ listExpr [ intExpr 1, intExpr 2, intExpr 3 ]
                        , varExpr "composed"
                        ]
                    )
                )
    in
    expectFn modul


{-| p bf uf x y = bf (uf x) (uf y)
add a b = a + b
testValue = p add List.length [1,2,3] [4,5]
-- length [1,2,3] + length [4,5] = 3 + 2 = 5
-}
pAddLengths : (Src.Module -> Expectation) -> (() -> Expectation)
pAddLengths expectFn _ =
    let
        pDef =
            define "p"
                [ pVar "bf", pVar "uf", pVar "x", pVar "y" ]
                (callExpr (varExpr "bf")
                    [ callExpr (varExpr "uf") [ varExpr "x" ]
                    , callExpr (varExpr "uf") [ varExpr "y" ]
                    ]
                )

        addDef =
            define "add"
                [ pVar "a", pVar "b" ]
                (binopsExpr [ ( varExpr "a", "+" ) ] (varExpr "b"))

        lenDef =
            define "len"
                [ pVar "xs" ]
                (callExpr (qualVarExpr "List" "length") [ varExpr "xs" ])

        modul =
            makeModule "testValue"
                (letExpr [ pDef, addDef, lenDef ]
                    (callExpr (varExpr "p")
                        [ varExpr "add"
                        , varExpr "len"
                        , listExpr [ intExpr 1, intExpr 2, intExpr 3 ]
                        , listExpr [ intExpr 4, intExpr 5 ]
                        ]
                    )
                )
    in
    expectFn modul



-- ============================================================================
-- COMBINATORS WITH STRING OPERATIONS (2 tests)
-- ============================================================================


stringCombinatorCases : (Src.Module -> Expectation) -> List TestCase
stringCombinatorCases expectFn =
    [ { label = "W combinator: duplicate string via append", run = wDuplicateString expectFn }
    , { label = "S combinator: palindrome via list reverse", run = sPalindromeList expectFn }
    ]


{-| w bf x = bf x x
append a b = a ++ b
testValue = w append "hi" -- "hihi"
-}
wDuplicateString : (Src.Module -> Expectation) -> (() -> Expectation)
wDuplicateString expectFn _ =
    let
        wDef =
            define "w"
                [ pVar "bf", pVar "x" ]
                (callExpr (varExpr "bf") [ varExpr "x", varExpr "x" ])

        appendDef =
            define "myAppend"
                [ pVar "a", pVar "b" ]
                (binopsExpr [ ( varExpr "a", "++" ) ] (varExpr "b"))

        modul =
            makeModule "testValue"
                (letExpr [ wDef, appendDef ]
                    (callExpr (varExpr "w") [ varExpr "myAppend", strExpr "hi" ])
                )
    in
    expectFn modul


{-| s bf uf x = bf x (uf x)
append a b = a ++ b
testValue = s append List.reverse [3,2,1]
-- [3,2,1] ++ [1,2,3] = [3,2,1,1,2,3]
-}
sPalindromeList : (Src.Module -> Expectation) -> (() -> Expectation)
sPalindromeList expectFn _ =
    let
        sDef =
            define "s"
                [ pVar "bf", pVar "uf", pVar "x" ]
                (callExpr (varExpr "bf")
                    [ varExpr "x"
                    , callExpr (varExpr "uf") [ varExpr "x" ]
                    ]
                )

        appendDef =
            define "myAppend"
                [ pVar "a", pVar "b" ]
                (binopsExpr [ ( varExpr "a", "++" ) ] (varExpr "b"))

        revDef =
            define "rev"
                [ pVar "xs" ]
                (callExpr (qualVarExpr "List" "reverse") [ varExpr "xs" ])

        modul =
            makeModule "testValue"
                (letExpr [ sDef, appendDef, revDef ]
                    (callExpr (varExpr "s")
                        [ varExpr "myAppend"
                        , varExpr "rev"
                        , listExpr [ intExpr 3, intExpr 2, intExpr 1 ]
                        ]
                    )
                )
    in
    expectFn modul



-- ============================================================================
-- MULTI-ARG COMBINATORS: SP with operators, C with cons (2 tests)
-- ============================================================================


multiArgCombinatorCases : (Src.Module -> Expectation) -> List TestCase
multiArgCombinatorCases expectFn =
    [ { label = "SP combinator: combine projections with operators", run = spWithOperators expectFn }
    , { label = "C combinator: flip cons onto list", run = cFlipCons expectFn }
    ]


{-| sp bf uf1 uf2 x = bf (uf1 x) (uf2 x)
mul a b = a * b
inc x = x + 1
double x = x * 2
testValue = sp mul inc double 6 -- (6+1) * (6*2) = 7 * 12 = 84
-}
spWithOperators : (Src.Module -> Expectation) -> (() -> Expectation)
spWithOperators expectFn _ =
    let
        spDef =
            define "sp"
                [ pVar "bf", pVar "uf1", pVar "uf2", pVar "x" ]
                (callExpr (varExpr "bf")
                    [ callExpr (varExpr "uf1") [ varExpr "x" ]
                    , callExpr (varExpr "uf2") [ varExpr "x" ]
                    ]
                )

        mulDef =
            define "mul"
                [ pVar "a", pVar "b" ]
                (binopsExpr [ ( varExpr "a", "*" ) ] (varExpr "b"))

        incDef =
            define "inc" [ pVar "x" ] (binopsExpr [ ( varExpr "x", "+" ) ] (intExpr 1))

        doubleDef =
            define "double" [ pVar "x" ] (binopsExpr [ ( varExpr "x", "*" ) ] (intExpr 2))

        modul =
            makeModule "testValue"
                (letExpr [ spDef, mulDef, incDef, doubleDef ]
                    (callExpr (varExpr "sp") [ varExpr "mul", varExpr "inc", varExpr "double", intExpr 6 ])
                )
    in
    expectFn modul


{-| c f a b = f b a (flip)
cons x xs = x :: xs -- represented as a list literal [x] ++ xs
testValue = c cons [2,3] 1 -- cons 1 [2,3] = [1,2,3]
-}
cFlipCons : (Src.Module -> Expectation) -> (() -> Expectation)
cFlipCons expectFn _ =
    let
        kDef =
            define "k" [ pVar "a", pAnything ] (varExpr "a")

        sDef =
            define "s"
                [ pVar "bf", pVar "uf", pVar "x" ]
                (callExpr (varExpr "bf")
                    [ varExpr "x"
                    , callExpr (varExpr "uf") [ varExpr "x" ]
                    ]
                )

        bDef =
            define "b" []
                (callExpr (varExpr "s")
                    [ callExpr (varExpr "k") [ varExpr "s" ]
                    , varExpr "k"
                    ]
                )

        cDef =
            define "c" []
                (callExpr (varExpr "s")
                    [ callExpr (varExpr "b") [ varExpr "b", varExpr "s" ]
                    , callExpr (varExpr "k") [ varExpr "k" ]
                    ]
                )

        -- cons x xs = [x] ++ xs
        consDef =
            define "cons"
                [ pVar "x", pVar "xs" ]
                (binopsExpr [ ( listExpr [ varExpr "x" ], "++" ) ] (varExpr "xs"))

        modul =
            makeModule "testValue"
                (letExpr [ kDef, sDef, bDef, cDef, consDef ]
                    (callExpr (varExpr "c") [ varExpr "cons", listExpr [ intExpr 2, intExpr 3 ], intExpr 1 ])
                )
    in
    expectFn modul
