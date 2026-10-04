module SourceIR.CombinatorCases exposing (expectSuite)

{-| Small integer programs built from combinators, for a caller to push through
whichever compiler stage it tests.

A combinator is a function that only rearranges and applies its arguments. Two
are enough to build many others: K takes two arguments and returns the first,
and S takes `bf`, `uf` and `x` and returns `bf x (uf x)`. The four programs
built from S and K (I, B, C and T) consist of little but functions passed as
arguments, partial applications, and definitions with no arguments of their own
whose value is a function. They give a stage under test those shapes in
concentrated form.

Each program is a module named `Test`, built with
`Compiler.AST.SourceBuilder.makeModule`, whose one top-level value `testValue`
has no annotation. Its body is a single `let` holding every combinator and
helper the program uses, around one application whose result is an `Int`. The
arithmetic uses only `+`, `-` and `*`.

This module builds the programs and nothing more. `expectSuite` hands each one
to the caller's `expectFn`, which decides what is checked. The values given
below are what each `testValue` evaluates to; no case here compares them.

The programs, in the order they run:

  - K: `k 42 99`, which is `42`.
  - S: `s add double 5` with a local `add a b = a + b` and `double x = x * 2`,
    which is `add 5 (double 5)`, `15`.
  - I, defined as `s k k`: `i 42`, which is `42`.
  - B, the composition combinator, defined as `s (k s) k`:
    `b square inc 4`, which is `square (inc 4)`, `25`.
  - C, the argument-flipping combinator, defined as `s (b b s) (k k)` from
    local S, K and B: `c sub 10 3` with `sub x y = x - y`, which is
    `sub 3 10`, `-7`.
  - SP, defined directly as `sp bf uf1 uf2 x = bf (uf1 x) (uf2 x)`:
    `sp mul inc double 6`, which is `mul 7 12`, `84`.
  - T, defined as `c i` from local S, K, B, C and I: `t 7 (\x -> x * 3)`,
    which is `21`.
  - W, defined directly as `w bf x = bf x x`: `w mul 9`, which is `81`.

Among what is not tested: combinators at the top level of a module, or with
type annotations; an operator such as `(+)` passed as a function value; and a
`testValue` of any type other than `Int`.

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


{-| Builds one test, named `"SKI combinator tests "` followed by `condStr`, that
hands each program in turn to `expectFn` and passes when every result passes.
The cases run through `Compiler.BulkCheck.bulkCheck`, so a failure names only the
first failing case.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("SKI combinator tests " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


{-| Returns all eight labelled cases: K and S, then I, B and C, then SP, T and W.
-}
testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    baseCombinatorCases expectFn
        ++ derivedCombinatorCases expectFn
        ++ appliedCombinatorCases expectFn



-- ============================================================================
-- BASE COMBINATORS: K and S (2 cases)
-- ============================================================================


{-| Returns the labelled K and S cases.
-}
baseCombinatorCases : (Src.Module -> Expectation) -> List TestCase
baseCombinatorCases expectFn =
    [ { label = "K combinator (always)", run = kCombinator expectFn }
    , { label = "S combinator (feed same input)", run = sCombinator expectFn }
    ]


{-| Builds the K program, `k 42 99` with a local `k a _ = a`, and hands it to
`expectFn`.
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


{-| Builds the S program and hands it to `expectFn`. Local `s`, `double` and
`add` are applied as `s add double 5`; `add` is a two-argument local function,
not the `(+)` operator.
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
-- DERIVED COMBINATORS: I, B, C (3 cases)
-- ============================================================================


{-| Returns the labelled I, B and C cases, each built from local S and K (C also
through a local B).
-}
derivedCombinatorCases : (Src.Module -> Expectation) -> List TestCase
derivedCombinatorCases expectFn =
    [ { label = "I combinator (identity via S K K)", run = iCombinator expectFn }
    , { label = "B combinator (compose via S (K S) K)", run = bCombinator expectFn }
    , { label = "C combinator (flip via S (B B S) (K K))", run = cCombinator expectFn }
    ]


{-| Builds the I program, `i 42` with `i` defined without arguments as
`s k k`, and hands it to `expectFn`.
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


{-| Builds the B program, `b square inc 4` with `b` defined without arguments
as `s (k s) k`, and hands it to `expectFn`.
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
            define "b"
                []
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


{-| Builds the C program, `c sub 10 3` with `c` defined without arguments as
`s (b b s) (k k)`, and hands it to `expectFn`.
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
            define "b"
                []
                (callExpr (varExpr "s")
                    [ callExpr (varExpr "k") [ varExpr "s" ]
                    , varExpr "k"
                    ]
                )

        cDef =
            define "c"
                []
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
-- APPLIED COMBINATORS: SP, T, W (3 cases)
-- ============================================================================


{-| Returns the labelled SP, T and W cases.
-}
appliedCombinatorCases : (Src.Module -> Expectation) -> List TestCase
appliedCombinatorCases expectFn =
    [ { label = "SP combinator (combine two projections)", run = spCombinator expectFn }
    , { label = "T combinator (thrush / pipe-forward)", run = tCombinator expectFn }
    , { label = "W combinator (duplicate argument)", run = wCombinator expectFn }
    ]


{-| Builds the SP program, `sp mul inc double 6` with `sp` taking its four
arguments directly, and hands it to `expectFn`.
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


{-| Builds the T program, `t 7 (\x -> x * 3)` with `t` defined without
arguments as `c i`, and hands it to `expectFn`. T applies its second argument to
its first, as `|>` does.
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
            define "b"
                []
                (callExpr (varExpr "s")
                    [ callExpr (varExpr "k") [ varExpr "s" ]
                    , varExpr "k"
                    ]
                )

        cDef =
            define "c"
                []
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


{-| Builds the W program, `w mul 9` with `w` taking its two arguments
directly, and hands it to `expectFn`.
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
