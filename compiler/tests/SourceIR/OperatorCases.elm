module SourceIR.OperatorCases exposing (expectSuite)

{-| Supplies small Elm programs built from `if` expressions and unary
negation, alone, nested and combined, for a caller's expectation function to
check.

The module only builds programs. `expectSuite` applies whatever expectation
function it is given to the programs in order, so what is checked, and after
which stage, is decided by the caller. The cases run inside one test through
`Compiler.BulkCheck.bulkCheck`, which stops at the first failing case and
reports only that one.

Despite the module's name, the only operator any program contains is unary
negation (`Src.Negate`); no binary operator appears.

Every program is a module named `Test`, built with `makeModule`, that imports
`Basics` and `List` and defines one value, `testValue`, with no arguments and no
annotation. The literals are `Int`s apart from one `Float`, and a condition is
`True` or `False`, written as the qualified constructor `Basics.True` or
`Basics.False`, or else a variable bound by a `let` to `True`. Every program is
well typed.

The programs are built as Source AST values, not parsed, and three of them have
a shape the parser never produces. Parsing `else if` gives one `Src.If` with
several condition and branch pairs, but `ifInElseBranch` and `deeplyNestedIf`
put a separate one-pair `Src.If` directly in the else branch, which parsed
source gives only with a `Src.Parens` node between, from `else (if ...)`.
`doubleNegate` puts a `Src.Negate` directly inside another, which parsed source
also gives only with a `Src.Parens` node between, as from `-(-42)`.

The cases, in the order they run:

  - `if` expressions (8): a constant condition with `Int` branches, twice, the
    two differing only in the else value; branches that are pairs; branches
    that are lists, one of them empty; an `if` in the then branch; an `if` in
    the else branch; three `if`s, each in the else branch of the one before;
    and a condition that is a `let`-bound variable.
  - Negation (4): of an `Int` literal, of a `Float` literal, of a negation of
    an `Int` literal, and of a `let`-bound variable.
  - Combinations (4): an `if` whose branches are both negations; an `if`
    whose then branch only is a negation; a pair of an `if` and a negation;
    and a list of two `if`s and two negations.

Among what is not tested: binary operators, an `if` with more than one
condition (the parsed `else if` form), a condition that is anything but a
`Basics` constructor or a variable, negation of anything but a literal, a
variable or another negation, and an `if` or a negation in a function argument
or in a `case`.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( boolExpr
        , define
        , floatExpr
        , ifExpr
        , intExpr
        , letExpr
        , listExpr
        , makeModule
        , negateExpr
        , tupleExpr
        , varExpr
        )
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Expect exposing (Expectation)
import Test exposing (Test)


{-| Returns one test, named `"Operator and if expressions "` followed by
`condStr`, that applies `expectFn` to each program in this module in turn,
stopping at the first that fails.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Operator and if expressions " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


{-| Returns every case in this module, paired with its label: the `if` cases,
then the negation cases, then the combined ones.
-}
testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    List.concat
        [ ifCases expectFn
        , negateCases expectFn
        , combinedCases expectFn
        ]



-- ============================================================================
-- IF EXPRESSIONS (8 cases)
-- ============================================================================


{-| Returns the eight cases whose programs are built from `if` expressions with
`Int`, pair or list branches.
-}
ifCases : (Src.Module -> Expectation) -> List TestCase
ifCases expectFn =
    [ { label = "Simple if", run = simpleIf expectFn }
    , { label = "If with int branches", run = ifWithIntBranches expectFn }
    , { label = "If returning tuples", run = ifReturningTuples expectFn }
    , { label = "If returning lists", run = ifReturningLists expectFn }
    , { label = "Nested if", run = nestedIf expectFn }
    , { label = "If in else branch", run = ifInElseBranch expectFn }
    , { label = "Deeply nested if", run = deeplyNestedIf expectFn }
    , { label = "If with variable condition", run = ifWithVariableCondition expectFn }
    ]


{-| Returns the check that applies `expectFn` to a program whose `testValue` is
`if True then 1 else 0`.
-}
simpleIf : (Src.Module -> Expectation) -> (() -> Expectation)
simpleIf expectFn _ =
    let
        modul =
            makeModule "testValue" (ifExpr (boolExpr True) (intExpr 1) (intExpr 0))
    in
    expectFn modul


{-| Returns the check that applies `expectFn` to a program whose `testValue` is
`if True then 1 else 2`.
-}
ifWithIntBranches : (Src.Module -> Expectation) -> (() -> Expectation)
ifWithIntBranches expectFn _ =
    let
        modul =
            makeModule "testValue" (ifExpr (boolExpr True) (intExpr 1) (intExpr 2))
    in
    expectFn modul


{-| Returns the check that applies `expectFn` to a program whose `testValue` is
`if True then ( 1, 2 ) else ( 3, 4 )`.
-}
ifReturningTuples : (Src.Module -> Expectation) -> (() -> Expectation)
ifReturningTuples expectFn _ =
    let
        thenBranch =
            tupleExpr (intExpr 1) (intExpr 2)

        elseBranch =
            tupleExpr (intExpr 3) (intExpr 4)

        modul =
            makeModule "testValue" (ifExpr (boolExpr True) thenBranch elseBranch)
    in
    expectFn modul


{-| Returns the check that applies `expectFn` to a program whose `testValue` is
`if False then [ 1, 2 ] else []`.
-}
ifReturningLists : (Src.Module -> Expectation) -> (() -> Expectation)
ifReturningLists expectFn _ =
    let
        thenBranch =
            listExpr [ intExpr 1, intExpr 2 ]

        elseBranch =
            listExpr []

        modul =
            makeModule "testValue" (ifExpr (boolExpr False) thenBranch elseBranch)
    in
    expectFn modul


{-| Returns the check that applies `expectFn` to a program whose `testValue` is
`if True then if True then 1 else 2 else 0`, the inner `if` being the whole
then branch.
-}
nestedIf : (Src.Module -> Expectation) -> (() -> Expectation)
nestedIf expectFn _ =
    let
        innerIf =
            ifExpr (boolExpr True) (intExpr 1) (intExpr 2)

        modul =
            makeModule "testValue" (ifExpr (boolExpr True) innerIf (intExpr 0))
    in
    expectFn modul


{-| Returns the check that applies `expectFn` to a program whose `testValue` is
an `if` on `False` with then branch `1`, whose else branch is the separate
expression `if True then 2 else 3`.

The inner `if` sits directly in the else branch, with no `Src.Parens` around
it. It is not a second condition of the outer `Src.If`, which is what parsing
`else if` would give.

-}
ifInElseBranch : (Src.Module -> Expectation) -> (() -> Expectation)
ifInElseBranch expectFn _ =
    let
        elseIf =
            ifExpr (boolExpr True) (intExpr 2) (intExpr 3)

        modul =
            makeModule "testValue" (ifExpr (boolExpr False) (intExpr 1) elseIf)
    in
    expectFn modul


{-| Returns the check that applies `expectFn` to a program whose `testValue` is
three `if`s on `True` with then branches `1`, `2` and `3`, each of the
inner two being the else branch of the one before, and `4` as the last else
branch.

As in `ifInElseBranch`, each inner `if` is a separate `Src.If` directly in the
else branch, with no `Src.Parens` around it.

-}
deeplyNestedIf : (Src.Module -> Expectation) -> (() -> Expectation)
deeplyNestedIf expectFn _ =
    let
        level3 =
            ifExpr (boolExpr True) (intExpr 3) (intExpr 4)

        level2 =
            ifExpr (boolExpr True) (intExpr 2) level3

        modul =
            makeModule "testValue" (ifExpr (boolExpr True) (intExpr 1) level2)
    in
    expectFn modul


{-| Returns the check that applies `expectFn` to a program whose `testValue` is
`let cond = True in if cond then 1 else 0`.
-}
ifWithVariableCondition : (Src.Module -> Expectation) -> (() -> Expectation)
ifWithVariableCondition expectFn _ =
    let
        def =
            define "cond" [] (boolExpr True)

        modul =
            makeModule "testValue"
                (letExpr [ def ] (ifExpr (varExpr "cond") (intExpr 1) (intExpr 0)))
    in
    expectFn modul



-- ============================================================================
-- NEGATE EXPRESSIONS (4 cases)
-- ============================================================================


{-| Returns the four cases whose programs are built from unary negation.
-}
negateCases : (Src.Module -> Expectation) -> List TestCase
negateCases expectFn =
    [ { label = "Negate int", run = negateInt expectFn }
    , { label = "Negate float", run = negateFloat expectFn }
    , { label = "Double negate", run = doubleNegate expectFn }
    , { label = "Negate variable", run = negateVariable expectFn }
    ]


{-| Returns the check that applies `expectFn` to a program whose `testValue` is
`-42`, a `Src.Negate` of the literal `42`.
-}
negateInt : (Src.Module -> Expectation) -> (() -> Expectation)
negateInt expectFn _ =
    let
        modul =
            makeModule "testValue" (negateExpr (intExpr 42))
    in
    expectFn modul


{-| Returns the check that applies `expectFn` to a program whose `testValue` is
`-3.14`, a `Src.Negate` of the literal `3.14`.
-}
negateFloat : (Src.Module -> Expectation) -> (() -> Expectation)
negateFloat expectFn _ =
    let
        modul =
            makeModule "testValue" (negateExpr (floatExpr 3.14))
    in
    expectFn modul


{-| Returns the check that applies `expectFn` to a program whose `testValue` is
a `Src.Negate` directly inside another around the literal `42`.

Parsed source gives two nested negations only with a `Src.Parens` node
between them, as from `-(-42)`; this program has none.

-}
doubleNegate : (Src.Module -> Expectation) -> (() -> Expectation)
doubleNegate expectFn _ =
    let
        modul =
            makeModule "testValue" (negateExpr (negateExpr (intExpr 42)))
    in
    expectFn modul


{-| Returns the check that applies `expectFn` to a program whose `testValue` is
`let x = 42 in -x`.
-}
negateVariable : (Src.Module -> Expectation) -> (() -> Expectation)
negateVariable expectFn _ =
    let
        def =
            define "x" [] (intExpr 42)

        modul =
            makeModule "testValue" (letExpr [ def ] (negateExpr (varExpr "x")))
    in
    expectFn modul



-- ============================================================================
-- COMBINED CASES (4 cases)
-- ============================================================================


{-| Returns the four cases whose programs put `if` expressions and negations
together.
-}
combinedCases : (Src.Module -> Expectation) -> List TestCase
combinedCases expectFn =
    [ { label = "If with negate condition", run = ifWithNegateCondition expectFn }
    , { label = "Negate inside if branches", run = negateInsideIfBranches expectFn }
    , { label = "If inside tuple with negate", run = ifInsideTupleWithNegate expectFn }
    , { label = "Multiple ifs and negates in list", run = multipleIfsAndNegatesInList expectFn }
    ]


{-| Returns the check that applies `expectFn` to a program whose `testValue` is
`if True then -1 else -2`.

The condition is not negated, whatever the label says: both negations are in
the branches.

-}
ifWithNegateCondition : (Src.Module -> Expectation) -> (() -> Expectation)
ifWithNegateCondition expectFn _ =
    let
        modul =
            makeModule "testValue"
                (ifExpr (boolExpr True)
                    (negateExpr (intExpr 1))
                    (negateExpr (intExpr 2))
                )
    in
    expectFn modul


{-| Returns the check that applies `expectFn` to a program whose `testValue` is
`if True then -1 else 1`.
-}
negateInsideIfBranches : (Src.Module -> Expectation) -> (() -> Expectation)
negateInsideIfBranches expectFn _ =
    let
        modul =
            makeModule "testValue"
                (ifExpr (boolExpr True)
                    (negateExpr (intExpr 1))
                    (intExpr 1)
                )
    in
    expectFn modul


{-| Returns the check that applies `expectFn` to a program whose `testValue` is
`( if True then 1 else 0, -5 )`.
-}
ifInsideTupleWithNegate : (Src.Module -> Expectation) -> (() -> Expectation)
ifInsideTupleWithNegate expectFn _ =
    let
        if_ =
            ifExpr (boolExpr True) (intExpr 1) (intExpr 0)

        neg =
            negateExpr (intExpr 5)

        modul =
            makeModule "testValue" (tupleExpr if_ neg)
    in
    expectFn modul


{-| Returns the check that applies `expectFn` to a program whose `testValue` is
`[ if True then 1 else 0, if False then 2 else 3, -4, -5 ]`.
-}
multipleIfsAndNegatesInList : (Src.Module -> Expectation) -> (() -> Expectation)
multipleIfsAndNegatesInList expectFn _ =
    let
        if1 =
            ifExpr (boolExpr True) (intExpr 1) (intExpr 0)

        if2 =
            ifExpr (boolExpr False) (intExpr 2) (intExpr 3)

        neg1 =
            negateExpr (intExpr 4)

        neg2 =
            negateExpr (intExpr 5)

        modul =
            makeModule "testValue" (listExpr [ if1, if2, neg1, neg2 ])
    in
    expectFn modul
