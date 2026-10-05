module SourceIR.ClosureCaptureBoolCases exposing (expectSuite)

{-| Builds programs that pass a `Bool` across a function or closure boundary,
and programs that choose between two closures at one call site.

In the native back end a `Bool` has two forms: `i1` as an SSA operand, and
`!eco.value`, a boxed value, at function and closure boundaries, as
`Compiler.Generate.MLIR.Types` describes. A `Bool` parameter of a
tail-recursive function and a `Bool` captured by a closure are both at such a
boundary, and inside the function each is the condition of an `if`, where the
`Bool` is an operand. These programs give a pipeline stage those shapes,
together with closures that capture different values and are called from the
same place.

Nothing here asserts anything. `expectSuite` runs the cases in order inside one
test through `Compiler.BulkCheck.bulkCheck`, handing each built module to the
caller's `expectFn` and stopping at the first case that fails, and `expectFn`
decides which stage the module goes through and what passes.

Every program is built by `makeModule "testValue"`: a module named `Test` that
imports only `Basics` and `List` and has one top-level value, `testValue`.
Every function is a `let` definition inside `testValue`. A closure is made by
partial application, giving a function fewer arguments than it takes, either as
a definition with no arguments such as `trueF = boolToInt True` or, in
`heteroClosureIntFloat`, as a branch of an `if`.

A _carry variable_ is a parameter that a tail-recursive function passes,
possibly changed, to its own next call; in both loops here every self-call is
in tail position.

The cases, in the order `testCases` lists them:

  - `tailRecBoolCarry` carries a `Bool` that a branch sets to `True`.
  - `tailRecBoolFlag` carries a `Bool`, recomputed from each element while it
    is `True` and kept `False` once it is not, that decides whether the next
    element is added.
  - `closureCaptureBoolTrue` and `closureCaptureBoolFalse` each make a closure
    that captures only a `Bool`, one `True` and one `False`, and apply it.
  - `closureCaptureBoolAndInt` makes a closure that captures a `Bool` and an
    integer, and applies it.
  - `heteroClosureIntFloat` picks, with an `if` on the constant `True`, one
    of two closures of type `Int -> Int`, one capturing an integer and the
    other a `Float`, and applies it.
  - `heteroClosureDynamicInt` picks between two closures of one function,
    capturing different integers and bound to names, with an `if` on a
    `let`-bound comparison.
  - `heteroClosureMixedOps` picks between `let`-bound closures of two
    different functions, an `Int` addition capturing an integer and a `Float`
    multiplication capturing a `Float`.

Among what is not tested:

  - a `Bool` captured by a lambda rather than by partial application;
  - a `let`-bound function whose result is a `Bool`;
  - a top-level function: every function is `let`-bound.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( binopsExpr
        , boolExpr
        , callExpr
        , caseExpr
        , define
        , floatExpr
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


{-| Returns one test, named `"Closure capture Bool and heterogeneous ABI "`
followed by `condStr`, that hands the cases' modules to `expectFn` in order and
stops at the first case that fails, failing with that case's label.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Closure capture Bool and heterogeneous ABI " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


{-| Returns the eight cases, each a label paired with its program builder
applied to `expectFn`.
-}
testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    [ -- Bool as a tail-recursive carry variable
      { label = "Bool as tail-rec carry: searchList toggles Bool through loop"
      , run = tailRecBoolCarry expectFn
      }
    , { label = "Bool as tail-rec carry: countWhile with Bool flag"
      , run = tailRecBoolFlag expectFn
      }

    -- Bool captured in a closure by partial application
    , { label = "Bool captured in closure: boolToInt True partially applied"
      , run = closureCaptureBoolTrue expectFn
      }
    , { label = "Bool captured in closure: boolToInt False partially applied"
      , run = closureCaptureBoolFalse expectFn
      }
    , { label = "Bool captured alongside Int in closure"
      , run = closureCaptureBoolAndInt expectFn
      }

    -- Closures with different captures, called from one place
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
-- BOOL AS A TAIL-RECURSIVE CARRY VARIABLE
-- ============================================================================


{-| Returns `expectFn` applied to the module whose `testValue` is:

    testValue =
        let
            searchList found target list =
                case list of
                    [] ->
                        if found then
                            1

                        else
                            0

                    x :: xs ->
                        if x == target then
                            searchList True target xs

                        else
                            searchList found target xs
        in
        searchList False 5 [ 1, 5, 3 ]

`found` is the carry variable. It starts `False`, the branch for an element
equal to `target` passes `True` in its place, and the other branch passes it on
unchanged. `testValue` evaluates to 1.

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


{-| Returns `expectFn` applied to the module whose `testValue` is:

    testValue =
        let
            countWhile active acc list =
                case list of
                    [] ->
                        acc

                    x :: xs ->
                        if active then
                            countWhile (x > 0) (acc + x) xs

                        else
                            countWhile active acc xs
        in
        countWhile True 0 [ 3, -1, 5, 2 ]

`active` is the carry variable: while it holds, an element is added to `acc`
and the next `active` is whether that element was positive, and once it is
`False` it stays `False`. So `-1` is still added, and `testValue` evaluates
to 2. The `-1` is built directly as a negative integer literal (`Src.Int`),
which the expression parser does not produce; it parses `-1` as the negation
of `1`.

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
-- BOOL CAPTURED IN A CLOSURE BY PARTIAL APPLICATION
-- ============================================================================


{-| Returns `expectFn` applied to the module whose `testValue` is:

    testValue =
        let
            boolToInt flag x =
                if flag then
                    x

                else
                    0

            trueF =
                boolToInt True
        in
        trueF 42

`trueF` is a closure whose one capture is the `Bool` `True`. `testValue`
evaluates to 42.

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


{-| Returns `expectFn` applied to the module of `closureCaptureBoolTrue` with
`False` captured instead, whose `testValue` is:

    testValue =
        let
            boolToInt flag x =
                if flag then
                    x

                else
                    0

            falseF =
                boolToInt False
        in
        falseF 42

`testValue` evaluates to 0.

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


{-| Returns `expectFn` applied to the module whose `testValue` is:

    testValue =
        let
            chooseAndApply flag offset x =
                if flag then
                    x + offset

                else
                    x - offset

            f =
                chooseAndApply True 10
        in
        f 5

`f` is a closure that captures a `Bool` and an integer. `testValue` evaluates
to 15.

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
-- CLOSURES WITH DIFFERENT CAPTURES, CALLED FROM ONE PLACE
-- ============================================================================


{-| Returns `expectFn` applied to the module whose `testValue` is:

    testValue =
        let
            addN n x =
                n + x

            scaleBy s x =
                round (s * toFloat x)
        in
        let
            f =
                if True then
                    addN 10

                else
                    scaleBy 2.5
        in
        f 3

A closure of `addN` capturing an `Int` and a closure of `scaleBy` capturing a
`Float` have the same type, `Int -> Int`, and meet in `f`, which is called
once. `testValue` evaluates to 13.

-}
heteroClosureIntFloat : (Src.Module -> Expectation) -> (() -> Expectation)
heteroClosureIntFloat expectFn _ =
    let
        addN =
            define "addN"
                [ pVar "n", pVar "x" ]
                (binopsExpr [ ( varExpr "n", "+" ) ] (varExpr "x"))

        scaleBy =
            define "scaleBy"
                [ pVar "s", pVar "x" ]
                (callExpr (varExpr "round")
                    [ binopsExpr [ ( varExpr "s", "*" ) ]
                        (callExpr (varExpr "toFloat") [ varExpr "x" ])
                    ]
                )

        modul =
            makeModule "testValue"
                (letExpr [ addN, scaleBy ]
                    (letExpr
                        [ define "f"
                            []
                            (ifExpr (boolExpr True)
                                (callExpr (varExpr "addN") [ intExpr 10 ])
                                (callExpr (varExpr "scaleBy") [ floatExpr 2.5 ])
                            )
                        ]
                        (callExpr (varExpr "f") [ intExpr 3 ])
                    )
                )
    in
    expectFn modul


{-| Returns `expectFn` applied to the module whose `testValue` is:

    testValue =
        let
            addN n x =
                n + x

            add5 =
                addN 5

            add10 =
                addN 10

            cond =
                1 > 0

            g =
                if cond then
                    add5

                else
                    add10
        in
        g 7

Unlike `heteroClosureIntFloat`, both closures are of one function and capture
an `Int`, they are bound to names before the choice, and the condition is a
`let`-bound comparison rather than the constant `True`. `testValue` evaluates
to 12.

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


{-| Returns `expectFn` applied to the module whose `testValue` is:

    testValue =
        let
            addInt n x =
                n + x

            mulFloat factor x =
                round (factor * toFloat x)
        in
        let
            useAdd =
                addInt 10

            useMul =
                mulFloat 3.0

            f =
                if True then
                    useAdd

                else
                    useMul
        in
        f 4

Unlike `heteroClosureIntFloat`, the closures are bound to names before the
choice: `useAdd` captures the `Int` 10 and `useMul` the `Float` 3.0, and both
are `Int -> Int`. `testValue` evaluates to 14.

-}
heteroClosureMixedOps : (Src.Module -> Expectation) -> (() -> Expectation)
heteroClosureMixedOps expectFn _ =
    let
        addInt =
            define "addInt"
                [ pVar "n", pVar "x" ]
                (binopsExpr [ ( varExpr "n", "+" ) ] (varExpr "x"))

        mulFloat =
            define "mulFloat"
                [ pVar "factor", pVar "x" ]
                (callExpr (varExpr "round")
                    [ binopsExpr [ ( varExpr "factor", "*" ) ]
                        (callExpr (varExpr "toFloat") [ varExpr "x" ])
                    ]
                )

        modul =
            makeModule "testValue"
                (letExpr [ addInt, mulFloat ]
                    (letExpr
                        [ define "useAdd" [] (callExpr (varExpr "addInt") [ intExpr 10 ])
                        , define "useMul" [] (callExpr (varExpr "mulFloat") [ floatExpr 3.0 ])
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
