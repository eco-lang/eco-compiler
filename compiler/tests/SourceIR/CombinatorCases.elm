module SourceIR.CombinatorCases exposing (expectSuite)

{-| Tests for SKI-style combinators with integer arithmetic.

These test cases correspond to the E2E tests in test/elm/src/CombinatorTest.elm,
building each combinator from S and K, then applying it to integer operations.

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
        , makeModule
        , pAnything
        , pVar
        , varExpr
        )
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Expect exposing (Expectation)
import Test exposing (Test)


expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("SKI combinator tests " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    baseCombinatorCases expectFn
        ++ derivedCombinatorCases expectFn
        ++ appliedCombinatorCases expectFn



-- ============================================================================
-- BASE COMBINATORS: K and S (2 tests)
-- ============================================================================


baseCombinatorCases : (Src.Module -> Expectation) -> List TestCase
baseCombinatorCases expectFn =
    [ { label = "K combinator (always)", run = kCombinator expectFn }
    , { label = "S combinator (feed same input)", run = sCombinator expectFn }
    ]


{-| k a _ = a; testValue = k 42 99
-}
kCombinator : (Src.Module -> Expectation) -> (() -> Expectation)
kCombinator expectFn _ =
    let
        kDef =
            define "k" [ pVar "a", pAnything ] (varExpr "a")

        modul =
            makeModule "testValue"
                (letExpr [ kDef ]
                    (callExpr (varExpr "k") [ intExpr 42, intExpr 99 ])
                )
    in
    expectFn modul


{-| s bf uf x = bf x (uf x)
double x = x * 2
testValue = s (+) double 5 -- 5 + 10 = 15
-}
sCombinator : (Src.Module -> Expectation) -> (() -> Expectation)
sCombinator expectFn _ =
    let
        sDef =
            define "s"
                [ pVar "bf", pVar "uf", pVar "x" ]
                (callExpr (varExpr "bf")
                    [ varExpr "x"
                    , callExpr (varExpr "uf") [ varExpr "x" ]
                    ]
                )

        doubleDef =
            define "double"
                [ pVar "x" ]
                (binopsExpr [ ( varExpr "x", "*" ) ] (intExpr 2))

        addDef =
            define "add"
                [ pVar "a", pVar "b" ]
                (binopsExpr [ ( varExpr "a", "+" ) ] (varExpr "b"))

        modul =
            makeModule "testValue"
                (letExpr [ sDef, doubleDef, addDef ]
                    (callExpr (varExpr "s") [ varExpr "add", varExpr "double", intExpr 5 ])
                )
    in
    expectFn modul



-- ============================================================================
-- DERIVED COMBINATORS: I, B, C (3 tests)
-- ============================================================================


derivedCombinatorCases : (Src.Module -> Expectation) -> List TestCase
derivedCombinatorCases expectFn =
    [ { label = "I combinator (identity via S K K)", run = iCombinator expectFn }
    , { label = "B combinator (compose via S (K S) K)", run = bCombinator expectFn }
    , { label = "C combinator (flip via S (B B S) (K K))", run = cCombinator expectFn }
    ]


{-| i = s k k; testValue = i 42
-}
iCombinator : (Src.Module -> Expectation) -> (() -> Expectation)
iCombinator expectFn _ =
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

        iDef =
            define "i" [] (callExpr (varExpr "s") [ varExpr "k", varExpr "k" ])

        modul =
            makeModule "testValue"
                (letExpr [ kDef, sDef, iDef ]
                    (callExpr (varExpr "i") [ intExpr 42 ])
                )
    in
    expectFn modul


{-| b = s (k s) k
square x = x * x
inc x = x + 1
testValue = b square inc 4 -- (4+1)^2 = 25
-}
bCombinator : (Src.Module -> Expectation) -> (() -> Expectation)
bCombinator expectFn _ =
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

        squareDef =
            define "square" [ pVar "x" ] (binopsExpr [ ( varExpr "x", "*" ) ] (varExpr "x"))

        incDef =
            define "inc" [ pVar "x" ] (binopsExpr [ ( varExpr "x", "+" ) ] (intExpr 1))

        modul =
            makeModule "testValue"
                (letExpr [ kDef, sDef, bDef, squareDef, incDef ]
                    (callExpr (varExpr "b") [ varExpr "square", varExpr "inc", intExpr 4 ])
                )
    in
    expectFn modul


{-| c = s (b b s) (k k)
sub x y = x - y
testValue = c sub 10 3 -- sub 3 10 = -7
-}
cCombinator : (Src.Module -> Expectation) -> (() -> Expectation)
cCombinator expectFn _ =
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

        subDef =
            define "sub"
                [ pVar "x", pVar "y" ]
                (binopsExpr [ ( varExpr "x", "-" ) ] (varExpr "y"))

        modul =
            makeModule "testValue"
                (letExpr [ kDef, sDef, bDef, cDef, subDef ]
                    (callExpr (varExpr "c") [ varExpr "sub", intExpr 10, intExpr 3 ])
                )
    in
    expectFn modul



-- ============================================================================
-- APPLIED COMBINATORS: SP, T, W (3 tests)
-- ============================================================================


appliedCombinatorCases : (Src.Module -> Expectation) -> List TestCase
appliedCombinatorCases expectFn =
    [ { label = "SP combinator (combine two projections)", run = spCombinator expectFn }
    , { label = "T combinator (thrush / pipe-forward)", run = tCombinator expectFn }
    , { label = "W combinator (duplicate argument)", run = wCombinator expectFn }
    ]


{-| sp bf uf1 uf2 x = bf (uf1 x) (uf2 x)
mul x y = x * y
inc x = x + 1
double x = x * 2
testValue = sp mul inc double 6 -- 7 * 12 = 84
-}
spCombinator : (Src.Module -> Expectation) -> (() -> Expectation)
spCombinator expectFn _ =
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
                [ pVar "x", pVar "y" ]
                (binopsExpr [ ( varExpr "x", "*" ) ] (varExpr "y"))

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


{-| t = c i (thrush / pipe-forward)
testValue = t 7 (\x -> x * 3) -- 21
-}
tCombinator : (Src.Module -> Expectation) -> (() -> Expectation)
tCombinator expectFn _ =
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

        modul =
            makeModule "testValue"
                (letExpr [ kDef, sDef, bDef, cDef, iDef, tDef ]
                    (callExpr (varExpr "t")
                        [ intExpr 7
                        , lambdaExpr [ pVar "x" ] (binopsExpr [ ( varExpr "x", "*" ) ] (intExpr 3))
                        ]
                    )
                )
    in
    expectFn modul


{-| w bf x = bf x x
mul x y = x * y
testValue = w mul 9 -- 81
-}
wCombinator : (Src.Module -> Expectation) -> (() -> Expectation)
wCombinator expectFn _ =
    let
        wDef =
            define "w"
                [ pVar "bf", pVar "x" ]
                (callExpr (varExpr "bf") [ varExpr "x", varExpr "x" ])

        mulDef =
            define "mul"
                [ pVar "x", pVar "y" ]
                (binopsExpr [ ( varExpr "x", "*" ) ] (varExpr "y"))

        modul =
            makeModule "testValue"
                (letExpr [ wDef, mulDef ]
                    (callExpr (varExpr "w") [ varExpr "mul", intExpr 9 ])
                )
    in
    expectFn modul
