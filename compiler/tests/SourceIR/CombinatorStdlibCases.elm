module SourceIR.CombinatorStdlibCases exposing (expectSuite)

{-| Source programs in which combinators are applied to helpers that call `List`
functions and operators, for an expectation function to check.

A combinator is a function that only rearranges and applies its arguments.
These programs exist to give whichever compiler stage `expectFn` runs them
through library calls that are reached only through higher-order let-bound
functions: each `List` function or operator is called inside a helper, and the
helpers are passed as arguments to a combinator.
In three of the programs the combinators are themselves partial applications,
which type-check only because let-bound definitions are generalised.

Each case is a module built with `makeModule`, whose one top-level value,
`testValue`, is a `let` that defines the combinators and helpers it needs and
then applies them to literals. Some combinators are derived from two that are
written out, `k a _ = a` and `s bf uf x = bf x (uf x)`:

  - `b = s (k s) k`, so `b f g x = f (g x)`;
  - `c = s (b b s) (k k)`, so `c f a b = f b a`;
  - `i = s k k`, so `i x = x`;
  - `t = c i`, so `t x f = f x`.

These four take no arguments; their values are partial applications. In
`b = s (k s) k` the first `k` returns `s` and the second returns `b`'s first
argument, which in these programs has a different type from `s`, so they rely
on `k` being generalised.

The cases only build programs. Each hands its module to the `expectFn` given to
`expectSuite`, which decides what is checked. The value a program evaluates to
is given below to describe it; nothing in this module compares it.

  - `bComposeListOps`: `b mySum mapInc [ 1, 2, 3 ]`, where `mySum` sums a
    list with `List.foldl` and a lambda applying `+`, and `mapInc` adds 1 to
    each element. Evaluates to 9.
  - `tPipeList`: `t [ 1, 2, 3 ] composed`, where `composed = b mySum mapDouble`
    and `mapDouble` doubles each element. Defines `k`, `s` and all four
    derived combinators, and evaluates to 12.
  - `pAddLengths`: `p add len [ 1, 2, 3 ] [ 4, 5 ]`, with `p` written out as
    `p bf uf x y = bf (uf x) (uf y)` and `len` calling `List.length`.
    Evaluates to 5.
  - `wDuplicateString`: `w myAppend "hi"`, with `w bf x = bf x x` and
    `myAppend` applying `++`. Evaluates to `"hihi"`.
  - `sPalindromeList`: `s myAppend rev [ 3, 2, 1 ]`, with `rev` calling
    `List.reverse`. Evaluates to `[ 3, 2, 1, 1, 2, 3 ]`, a list, not a string.
  - `spWithOperators`: `sp mul inc double 6`, with
    `sp bf uf1 uf2 x = bf (uf1 x) (uf2 x)` written out. Evaluates to 84.
  - `cFlipCons`: `c cons [ 2, 3 ] 1`, with `c` derived and `cons x xs` built
    as `[ x ] ++ xs`. Evaluates to `[ 1, 2, 3 ]`.

Among what is not covered: a library function passed as a value (every `List`
function is called with all its arguments inside a named helper); any `String`
function; the `::` operator; and `p`, `w` and `sp` derived from `k` and `s`.

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


{-| Builds one test, named `"SKI combinator stdlib tests "` followed by
`condStr`, that hands every case in this module, each applying `expectFn`, to
`bulkCheck`. Which cases run and how a failure is reported are as
`Compiler.BulkCheck` describes.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("SKI combinator stdlib tests " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


{-| Returns every case in this module, each applying `expectFn` to its program:
the list cases, then the append cases, then the multi-argument ones.
-}
testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    listCombinatorCases expectFn
        ++ stringCombinatorCases expectFn
        ++ multiArgCombinatorCases expectFn



-- ============================================================================
-- COMBINATORS WITH LIST OPERATIONS (3 cases)
-- ============================================================================


{-| Returns the three cases whose combinators are applied to helpers calling
`List.foldl`, `List.map` and `List.length`.
-}
listCombinatorCases : (Src.Module -> Expectation) -> List TestCase
listCombinatorCases expectFn =
    [ { label = "B combinator: compose foldl and map on list", run = bComposeListOps expectFn }
    , { label = "T combinator: pipe list into composed ops", run = tPipeList expectFn }
    , { label = "P combinator: add lengths of two lists", run = pAddLengths expectFn }
    ]


{-| Applies `expectFn` to a program that composes a sum with a map using the
derived `b`. Its `testValue` is `b mySum mapInc [ 1, 2, 3 ]`, where `mySum`
folds `\a acc -> a + acc` over a list from 0 with `List.foldl` and `mapInc`
adds 1 to each element with `List.map`, so it evaluates to 9.
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
            define "b"
                []
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


{-| Applies `expectFn` to a program that pipes a list into a composition through
the derived `t`, whose definition needs `b`, `c` and `i` as well. Its
`testValue` is `t [ 1, 2, 3 ] composed`, where `composed = b mySum mapDouble`,
`mySum` sums a list as in `bComposeListOps` and `mapDouble` doubles each
element with `List.map`, so it evaluates to 12.
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
            define "composed"
                []
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


{-| Applies `expectFn` to a program that adds the lengths of two lists with a
`p` written out in full, `p bf uf x y = bf (uf x) (uf y)`. Its `testValue` is
`p add len [ 1, 2, 3 ] [ 4, 5 ]`, where `add` applies `+` and `len` calls
`List.length`, so it evaluates to 5.
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
-- COMBINATORS WITH APPEND (2 cases)
-- ============================================================================


{-| Returns the two cases whose combinators are applied to a helper calling
`++`, one on a string and one on a list.
-}
stringCombinatorCases : (Src.Module -> Expectation) -> List TestCase
stringCombinatorCases expectFn =
    [ { label = "W combinator: duplicate string via append", run = wDuplicateString expectFn }
    , { label = "S combinator: palindrome via list reverse", run = sPalindromeList expectFn }
    ]


{-| Applies `expectFn` to a program that appends a string to itself with a `w`
written out in full, `w bf x = bf x x`. Its `testValue` is `w myAppend "hi"`,
where `myAppend` applies `++`, so it evaluates to `"hihi"`.
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


{-| Applies `expectFn` to a program that appends a list to its own reverse with
`s bf uf x = bf x (uf x)`. Its `testValue` is `s myAppend rev [ 3, 2, 1 ]`,
where `myAppend` applies `++` and `rev` calls `List.reverse`, so it evaluates
to `[ 3, 2, 1, 1, 2, 3 ]`. No string is involved.
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
-- MULTI-ARG COMBINATORS: SP with operators, C with cons (2 cases)
-- ============================================================================


{-| Returns the two cases whose combinators take three or more arguments: `sp`
applied to arithmetic helpers, and the derived `c` applied to a cons helper.
-}
multiArgCombinatorCases : (Src.Module -> Expectation) -> List TestCase
multiArgCombinatorCases expectFn =
    [ { label = "SP combinator: combine projections with operators", run = spWithOperators expectFn }
    , { label = "C combinator: flip cons onto list", run = cFlipCons expectFn }
    ]


{-| Applies `expectFn` to a program that multiplies the results of two
functions of one number with an `sp` written out in full,
`sp bf uf1 uf2 x = bf (uf1 x) (uf2 x)`. Its `testValue` is
`sp mul inc double 6`, where `mul` applies `*`, `inc` adds 1 and `double`
multiplies by 2, so it evaluates to 84.
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


{-| Applies `expectFn` to a program that conses onto a list with its arguments
flipped by the derived `c`, which needs `b` as well. Its `testValue` is
`c cons [ 2, 3 ] 1`, where `cons x xs` is `[ x ] ++ xs` rather than `::`, so it
evaluates to `[ 1, 2, 3 ]`.
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
