module SourceIR.HigherOrderCases exposing (expectSuite)

{-| Source programs that treat functions as values: functions passed as
arguments, returned from other functions, applied partially, and chosen by a
`case`. A compiler stage that mishandled closures or curried calls could pass
every check run on simpler programs, and these give such a check something to
fail on.

This module asserts nothing itself. `expectSuite` hands the programs, in
order, to the expectation function it is given, and stops at the first one that
fails, as `Compiler.BulkCheck` describes. What is checked, and after which
stage, depends on that function.

Each case builds one `Src.Module` with `Compiler.AST.SourceBuilder`, so no
source text is parsed. The cases of the first six groups use `makeModule`: a
module `Test` importing `Basics` and `List`, whose only top-level value is an
unannotated `testValue`. Its body is a `let` that defines the helper
functions, none of them annotated, and then uses them. Several helpers whose
names suggest arithmetic (`makeAdder`, `add`, `mult`, and the `double` of
`functionFactory`) build tuples instead. The three cases of the last group use
`makeModuleWithTypedDefsUnionsAliases`: a module `Test` importing `Basics`,
`Maybe`, `List`, `Elm.JsArray`, `String` and `Char`, with one custom type whose
constructors take no arguments and with annotated top-level definitions, among
them `testValue : Int`.

The docstrings below write each program as Elm source, but the built trees
contain no parentheses. Where the source has a parenthesised lambda or call,
such as the argument in `apply (\n -> n) 42` or the function in
`(makeAdder 5) 3`, the tree has the bare expression where the parser would
give a `Src.Parens` node. Likewise the `h :: t` argument of `mapHead` and the
`x as original` argument of `withOriginal` are bare patterns, where the parser
would give `Src.PParens`. In `caseReturnsDifferentlyStagedLambdas` each
`a + b + c` is an operator chain whose first operand is the chain `a + b`,
where the parser would give one flat chain.

The cases, group by group:

  - Function as argument (5 cases): a lambda and a let-bound function each
    passed to `apply f x = f x`; a lambda passed to `myMap` and one to
    `myFilter`, list functions that do not recurse and so handle only the head;
    and the accessor `.name` passed to `apply` with a record.
  - Function returning function (6 cases): definitions that return a lambda,
    called either with all their arguments at once (`add 1 2`,
    `triple 1 2 3`, `makeClosure 1 2 3 4`) or in two calls
    (`(makeAdder 5) 3`, `(choose True) 42`), and a zero-argument definition
    that holds a returned closure (`double = makeTransform 2`).
  - Composition (5 cases): the combinators `compose` (in two cases), `flip`,
    `const` and `pipe`, each defined in the `let` and then applied.
  - Partial application (4 cases): a two-parameter function applied to one
    argument and stored, a three-parameter function applied one argument at a
    time through two stored partial applications, and partial applications
    that are never applied further, as the elements of a list and as the
    fields of a record.
  - Polymorphic higher-order (3 cases): one let-bound function used at a
    number and at a `String` within one tuple.
  - Higher-order with patterns (4 cases): a function whose first parameter is
    the function it applies and whose second is a tuple, record, `::` or `as`
    pattern.
  - Case returning function (3 cases): typed modules in which each branch of
    a `case` returns a lambda, so that a definition takes fewer arguments than
    its type has.

Among what is not tested: a recursive higher-order function, a fold (the
fold-like case is in `SourceIR.TypeCheckFailsCases`), an operator or a
constructor passed as a function value, and an annotated helper in the cases
built with `makeModule`.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( TypedDef
        , UnionDef
        , accessorExpr
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
        , makeModule
        , makeModuleWithTypedDefsUnionsAliases
        , pAlias
        , pAnything
        , pCons
        , pCtor
        , pList
        , pRecord
        , pTuple
        , pVar
        , recordExpr
        , strExpr
        , tLambda
        , tType
        , tupleExpr
        , varExpr
        )
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Expect exposing (Expectation)
import Test exposing (Test)


{-| Builds one test, named "Higher-order function tests " followed by
`condStr`, that runs `expectFn` on the programs of this module in order. It
stops at the first program `expectFn` rejects and fails under that program's
label.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Higher-order function tests " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


{-| Lists every case of this module, group by group, each with its label.
-}
testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    functionAsArgumentCases expectFn
        ++ functionReturningFunctionCases expectFn
        ++ compositionCases expectFn
        ++ partialApplicationCases expectFn
        ++ polymorphicHigherOrderCases expectFn
        ++ higherOrderWithPatternsCases expectFn
        ++ caseReturningFunctionCases expectFn



-- ============================================================================
-- FUNCTION AS ARGUMENT
-- ============================================================================


{-| Lists the cases that pass a function as an argument.
-}
functionAsArgumentCases : (Src.Module -> Expectation) -> List TestCase
functionAsArgumentCases expectFn =
    [ { label = "Pass lambda to function", run = passLambdaToFunction expectFn }
    , { label = "Pass named function to higher-order", run = passNamedFunctionToHigherOrder expectFn }
    , { label = "Map-like function", run = mapLikeFunction expectFn }
    , { label = "Filter-like function", run = filterLikeFunction expectFn }
    , { label = "Pass accessor function", run = passAccessorFunction expectFn }
    ]


{-| Applies `expectFn` to `apply (\n -> n) 42`, where `apply f x = f x`.
-}
passLambdaToFunction : (Src.Module -> Expectation) -> (() -> Expectation)
passLambdaToFunction expectFn _ =
    let
        applyFn =
            define "apply" [ pVar "f", pVar "x" ] (callExpr (varExpr "f") [ varExpr "x" ])

        fn =
            lambdaExpr [ pVar "n" ] (varExpr "n")

        modul =
            makeModule "testValue"
                (letExpr [ applyFn ]
                    (callExpr (varExpr "apply") [ fn, intExpr 42 ])
                )
    in
    expectFn modul


{-| Applies `expectFn` to `apply identity 42`, where `identity x = x` and
`apply f x = f x` are both let-bound.
-}
passNamedFunctionToHigherOrder : (Src.Module -> Expectation) -> (() -> Expectation)
passNamedFunctionToHigherOrder expectFn _ =
    let
        identity =
            define "identity" [ pVar "x" ] (varExpr "x")

        applyFn =
            define "apply" [ pVar "f", pVar "x" ] (callExpr (varExpr "f") [ varExpr "x" ])

        modul =
            makeModule "testValue"
                (letExpr [ identity, applyFn ]
                    (callExpr (varExpr "apply") [ varExpr "identity", intExpr 42 ])
                )
    in
    expectFn modul


{-| Applies `expectFn` to `myMap (\x -> ( x, x )) [ 1, 2 ]`. `myMap` gives `[]`
for the empty list and `[ f h ]` for `h :: t`, so only the head is mapped.
-}
mapLikeFunction : (Src.Module -> Expectation) -> (() -> Expectation)
mapLikeFunction expectFn _ =
    let
        mapFn =
            define "myMap"
                [ pVar "f", pVar "list" ]
                (caseExpr (varExpr "list")
                    [ ( pList [], listExpr [] )
                    , ( pCons (pVar "h") (pVar "t")
                      , listExpr
                            [ callExpr (varExpr "f") [ varExpr "h" ]
                            ]
                      )
                    ]
                )

        double =
            lambdaExpr [ pVar "x" ] (tupleExpr (varExpr "x") (varExpr "x"))

        modul =
            makeModule "testValue"
                (letExpr [ mapFn ]
                    (callExpr (varExpr "myMap") [ double, listExpr [ intExpr 1, intExpr 2 ] ])
                )
    in
    expectFn modul


{-| Applies `expectFn` to `myFilter (\_ -> True) [ 1 ]`. `myFilter` gives `[]`
for the empty list and, for `h :: t`, `[ h ]` when `pred h` holds and `[]`
otherwise, so the tail is dropped.
-}
filterLikeFunction : (Src.Module -> Expectation) -> (() -> Expectation)
filterLikeFunction expectFn _ =
    let
        filterFn =
            define "myFilter"
                [ pVar "pred", pVar "list" ]
                (caseExpr (varExpr "list")
                    [ ( pList [], listExpr [] )
                    , ( pCons (pVar "h") (pVar "t")
                      , ifExpr
                            (callExpr (varExpr "pred") [ varExpr "h" ])
                            (listExpr [ varExpr "h" ])
                            (listExpr [])
                      )
                    ]
                )

        alwaysTrue =
            lambdaExpr [ pAnything ] (boolExpr True)

        modul =
            makeModule "testValue"
                (letExpr [ filterFn ]
                    (callExpr (varExpr "myFilter") [ alwaysTrue, listExpr [ intExpr 1 ] ])
                )
    in
    expectFn modul


{-| Applies `expectFn` to `apply .name { name = "test" }`, where
`apply f x = f x`.
-}
passAccessorFunction : (Src.Module -> Expectation) -> (() -> Expectation)
passAccessorFunction expectFn _ =
    let
        applyFn =
            define "apply" [ pVar "f", pVar "x" ] (callExpr (varExpr "f") [ varExpr "x" ])

        record =
            recordExpr [ ( "name", strExpr "test" ) ]

        modul =
            makeModule "testValue"
                (letExpr [ applyFn ]
                    (callExpr (varExpr "apply") [ accessorExpr "name", record ])
                )
    in
    expectFn modul



-- ============================================================================
-- FUNCTION RETURNING FUNCTION
-- ============================================================================


{-| Lists the cases whose functions return functions.
-}
functionReturningFunctionCases : (Src.Module -> Expectation) -> List TestCase
functionReturningFunctionCases expectFn =
    [ { label = "Function returning lambda", run = functionReturningLambda expectFn }
    , { label = "Curried function", run = curriedFunction expectFn }
    , { label = "Triple nested function", run = tripleNestedFunction expectFn }
    , { label = "Function factory", run = functionFactory expectFn }
    , { label = "Return lambda based on condition", run = returnLambdaBasedOnCondition expectFn }
    , { label = "Closure over multiple variables", run = closureOverMultipleVariables expectFn }
    ]


{-| Applies `expectFn` to `(makeAdder 5) 3`, where
`makeAdder n = \x -> ( n, x )`: the lambda it returns is applied in a second
call.
-}
functionReturningLambda : (Src.Module -> Expectation) -> (() -> Expectation)
functionReturningLambda expectFn _ =
    let
        makeFn =
            define "makeAdder"
                [ pVar "n" ]
                (lambdaExpr [ pVar "x" ] (tupleExpr (varExpr "n") (varExpr "x")))

        modul =
            makeModule "testValue"
                (letExpr [ makeFn ]
                    (callExpr (callExpr (varExpr "makeAdder") [ intExpr 5 ]) [ intExpr 3 ])
                )
    in
    expectFn modul


{-| Applies `expectFn` to `add 1 2`, one call with two arguments to
`add a = \b -> ( a, b )`, which takes one.
-}
curriedFunction : (Src.Module -> Expectation) -> (() -> Expectation)
curriedFunction expectFn _ =
    let
        addFn =
            define "add"
                [ pVar "a" ]
                (lambdaExpr [ pVar "b" ] (tupleExpr (varExpr "a") (varExpr "b")))

        modul =
            makeModule "testValue"
                (letExpr [ addFn ]
                    (callExpr (varExpr "add") [ intExpr 1, intExpr 2 ])
                )
    in
    expectFn modul


{-| Applies `expectFn` to `triple 1 2 3`, one call with three arguments to
`triple a = \b -> \c -> [ a, b, c ]`, which takes one.
-}
tripleNestedFunction : (Src.Module -> Expectation) -> (() -> Expectation)
tripleNestedFunction expectFn _ =
    let
        fn =
            define "triple"
                [ pVar "a" ]
                (lambdaExpr [ pVar "b" ]
                    (lambdaExpr [ pVar "c" ]
                        (listExpr [ varExpr "a", varExpr "b", varExpr "c" ])
                    )
                )

        modul =
            makeModule "testValue"
                (letExpr [ fn ]
                    (callExpr (varExpr "triple") [ intExpr 1, intExpr 2, intExpr 3 ])
                )
    in
    expectFn modul


{-| Applies `expectFn` to `double 5`, where `double = makeTransform 2` is a
let-bound value holding the closure that
`makeTransform factor = \x -> ( x, factor )` returns.
-}
functionFactory : (Src.Module -> Expectation) -> (() -> Expectation)
functionFactory expectFn _ =
    let
        makeTransform =
            define "makeTransform"
                [ pVar "factor" ]
                (lambdaExpr [ pVar "x" ] (tupleExpr (varExpr "x") (varExpr "factor")))

        double =
            define "double" [] (callExpr (varExpr "makeTransform") [ intExpr 2 ])

        modul =
            makeModule "testValue"
                (letExpr [ makeTransform, double ]
                    (callExpr (varExpr "double") [ intExpr 5 ])
                )
    in
    expectFn modul


{-| Applies `expectFn` to `(choose True) 42`, where
`choose flag = if flag then \x -> x else \_ -> 0`.
-}
returnLambdaBasedOnCondition : (Src.Module -> Expectation) -> (() -> Expectation)
returnLambdaBasedOnCondition expectFn _ =
    let
        chooseFn =
            define "choose"
                [ pVar "flag" ]
                (ifExpr (varExpr "flag")
                    (lambdaExpr [ pVar "x" ] (varExpr "x"))
                    (lambdaExpr [ pAnything ] (intExpr 0))
                )

        modul =
            makeModule "testValue"
                (letExpr [ chooseFn ]
                    (callExpr (callExpr (varExpr "choose") [ boolExpr True ]) [ intExpr 42 ])
                )
    in
    expectFn modul


{-| Applies `expectFn` to `makeClosure 1 2 3 4`, one call with four arguments
to `makeClosure a b c = \x -> [ a, b, c, x ]`, whose lambda captures all three
parameters.
-}
closureOverMultipleVariables : (Src.Module -> Expectation) -> (() -> Expectation)
closureOverMultipleVariables expectFn _ =
    let
        makeClosure =
            define "makeClosure"
                [ pVar "a", pVar "b", pVar "c" ]
                (lambdaExpr [ pVar "x" ]
                    (listExpr [ varExpr "a", varExpr "b", varExpr "c", varExpr "x" ])
                )

        modul =
            makeModule "testValue"
                (letExpr [ makeClosure ]
                    (callExpr (varExpr "makeClosure") [ intExpr 1, intExpr 2, intExpr 3, intExpr 4 ])
                )
    in
    expectFn modul



-- ============================================================================
-- COMPOSITION
-- ============================================================================


{-| Lists the cases that combine functions with other functions.
-}
compositionCases : (Src.Module -> Expectation) -> List TestCase
compositionCases expectFn =
    [ { label = "Compose two functions", run = composeTwoFunctions expectFn }
    , { label = "Flip function", run = flipFunction expectFn }
    , { label = "Const function", run = constFunction expectFn }
    , { label = "Identity composition", run = identityComposition expectFn }
    , { label = "Pipe-like apply", run = pipeLikeApply expectFn }
    ]


{-| Applies `expectFn` to `(compose (\n -> ( n, 0 )) (\n -> n)) 42`, where
`compose f g = \x -> f (g x)`.
-}
composeTwoFunctions : (Src.Module -> Expectation) -> (() -> Expectation)
composeTwoFunctions expectFn _ =
    let
        compose =
            define "compose"
                [ pVar "f", pVar "g" ]
                (lambdaExpr [ pVar "x" ]
                    (callExpr (varExpr "f") [ callExpr (varExpr "g") [ varExpr "x" ] ])
                )

        fn1 =
            lambdaExpr [ pVar "n" ] (tupleExpr (varExpr "n") (intExpr 0))

        fn2 =
            lambdaExpr [ pVar "n" ] (varExpr "n")

        composed =
            callExpr (varExpr "compose") [ fn1, fn2 ]

        modul =
            makeModule "testValue"
                (letExpr [ compose ]
                    (callExpr composed [ intExpr 42 ])
                )
    in
    expectFn modul


{-| Applies `expectFn` to `(flip (\x y -> ( x, y ))) 1 2`, where
`flip f = \a b -> f b a`.
-}
flipFunction : (Src.Module -> Expectation) -> (() -> Expectation)
flipFunction expectFn _ =
    let
        flipFn =
            define "flip"
                [ pVar "f" ]
                (lambdaExpr [ pVar "a", pVar "b" ]
                    (callExpr (varExpr "f") [ varExpr "b", varExpr "a" ])
                )

        pairFn =
            lambdaExpr [ pVar "x", pVar "y" ] (tupleExpr (varExpr "x") (varExpr "y"))

        modul =
            makeModule "testValue"
                (letExpr [ flipFn ]
                    (callExpr (callExpr (varExpr "flip") [ pairFn ]) [ intExpr 1, intExpr 2 ])
                )
    in
    expectFn modul


{-| Applies `expectFn` to `(const 42) "ignored"`, where `const a = \_ -> a`.
-}
constFunction : (Src.Module -> Expectation) -> (() -> Expectation)
constFunction expectFn _ =
    let
        constFn =
            define "const"
                [ pVar "a" ]
                (lambdaExpr [ pAnything ] (varExpr "a"))

        modul =
            makeModule "testValue"
                (letExpr [ constFn ]
                    (callExpr (callExpr (varExpr "const") [ intExpr 42 ]) [ strExpr "ignored" ])
                )
    in
    expectFn modul


{-| Applies `expectFn` to `(compose identity identity) 1`, where
`identity x = x` and `compose f g = \x -> f (g x)`.
-}
identityComposition : (Src.Module -> Expectation) -> (() -> Expectation)
identityComposition expectFn _ =
    let
        identity =
            define "identity" [ pVar "x" ] (varExpr "x")

        compose =
            define "compose"
                [ pVar "f", pVar "g" ]
                (lambdaExpr [ pVar "x" ]
                    (callExpr (varExpr "f") [ callExpr (varExpr "g") [ varExpr "x" ] ])
                )

        modul =
            makeModule "testValue"
                (letExpr [ identity, compose ]
                    (callExpr (callExpr (varExpr "compose") [ varExpr "identity", varExpr "identity" ]) [ intExpr 1 ])
                )
    in
    expectFn modul


{-| Applies `expectFn` to `pipe 5 (\n -> ( n, n ))`, where `pipe x f = f x`.
-}
pipeLikeApply : (Src.Module -> Expectation) -> (() -> Expectation)
pipeLikeApply expectFn _ =
    let
        pipe =
            define "pipe"
                [ pVar "x", pVar "f" ]
                (callExpr (varExpr "f") [ varExpr "x" ])

        fn =
            lambdaExpr [ pVar "n" ] (tupleExpr (varExpr "n") (varExpr "n"))

        modul =
            makeModule "testValue"
                (letExpr [ pipe ]
                    (callExpr (varExpr "pipe") [ intExpr 5, fn ])
                )
    in
    expectFn modul



-- ============================================================================
-- PARTIAL APPLICATION
-- ============================================================================


{-| Lists the cases that apply a function to fewer arguments than it takes.
-}
partialApplicationCases : (Src.Module -> Expectation) -> List TestCase
partialApplicationCases expectFn =
    [ { label = "Partially applied function stored", run = partiallyAppliedFunctionStored expectFn }
    , { label = "Multiple partial applications", run = multiplePartialApplications expectFn }
    , { label = "Partial application in list", run = partialApplicationInList expectFn }
    , { label = "Partial application in record", run = partialApplicationInRecord expectFn }
    ]


{-| Applies `expectFn` to `add5 3`, where `add a b = ( a, b )` and
`add5 = add 5`.
-}
partiallyAppliedFunctionStored : (Src.Module -> Expectation) -> (() -> Expectation)
partiallyAppliedFunctionStored expectFn _ =
    let
        addFn =
            define "add" [ pVar "a", pVar "b" ] (tupleExpr (varExpr "a") (varExpr "b"))

        add5 =
            define "add5" [] (callExpr (varExpr "add") [ intExpr 5 ])

        modul =
            makeModule "testValue"
                (letExpr [ addFn, add5 ]
                    (callExpr (varExpr "add5") [ intExpr 3 ])
                )
    in
    expectFn modul


{-| Applies `expectFn` to `p2 3`, where `fn a b c = [ a, b, c ]`,
`p1 = fn 1` and `p2 = p1 2`.
-}
multiplePartialApplications : (Src.Module -> Expectation) -> (() -> Expectation)
multiplePartialApplications expectFn _ =
    let
        fn =
            define "fn"
                [ pVar "a", pVar "b", pVar "c" ]
                (listExpr [ varExpr "a", varExpr "b", varExpr "c" ])

        p1 =
            define "p1" [] (callExpr (varExpr "fn") [ intExpr 1 ])

        p2 =
            define "p2" [] (callExpr (varExpr "p1") [ intExpr 2 ])

        modul =
            makeModule "testValue"
                (letExpr [ fn, p1, p2 ]
                    (callExpr (varExpr "p2") [ intExpr 3 ])
                )
    in
    expectFn modul


{-| Applies `expectFn` to `[ add 1, add 2, add 3 ]`, a list of partial
applications of `add a b = ( a, b )` that are never applied further.
-}
partialApplicationInList : (Src.Module -> Expectation) -> (() -> Expectation)
partialApplicationInList expectFn _ =
    let
        addFn =
            define "add" [ pVar "a", pVar "b" ] (tupleExpr (varExpr "a") (varExpr "b"))

        modul =
            makeModule "testValue"
                (letExpr [ addFn ]
                    (listExpr
                        [ callExpr (varExpr "add") [ intExpr 1 ]
                        , callExpr (varExpr "add") [ intExpr 2 ]
                        , callExpr (varExpr "add") [ intExpr 3 ]
                        ]
                    )
                )
    in
    expectFn modul


{-| Applies `expectFn` to `{ double = mult 2, triple = mult 3 }`, a record of
partial applications of `mult a b = ( a, b )` that are never applied further.
-}
partialApplicationInRecord : (Src.Module -> Expectation) -> (() -> Expectation)
partialApplicationInRecord expectFn _ =
    let
        multFn =
            define "mult" [ pVar "a", pVar "b" ] (tupleExpr (varExpr "a") (varExpr "b"))

        modul =
            makeModule "testValue"
                (letExpr [ multFn ]
                    (recordExpr
                        [ ( "double", callExpr (varExpr "mult") [ intExpr 2 ] )
                        , ( "triple", callExpr (varExpr "mult") [ intExpr 3 ] )
                        ]
                    )
                )
    in
    expectFn modul



-- ============================================================================
-- POLYMORPHIC HIGHER-ORDER
-- ============================================================================


{-| Lists the cases that use one let-bound function at two different types.
-}
polymorphicHigherOrderCases : (Src.Module -> Expectation) -> List TestCase
polymorphicHigherOrderCases expectFn =
    [ { label = "Identity used with different types", run = identityUsedWithDifferentTypes expectFn }
    , { label = "Apply used with different function types", run = applyUsedWithDifferentFunctionTypes expectFn }
    , { label = "Higher-order function preserving polymorphism", run = higherOrderPreservingPolymorphism expectFn }
    ]


{-| Applies `expectFn` to `( id 1, id "hello" )`, where `id x = x`, so `id` is
used at a number and at a `String`.
-}
identityUsedWithDifferentTypes : (Src.Module -> Expectation) -> (() -> Expectation)
identityUsedWithDifferentTypes expectFn _ =
    let
        idFn =
            define "id" [ pVar "x" ] (varExpr "x")

        body =
            tupleExpr
                (callExpr (varExpr "id") [ intExpr 1 ])
                (callExpr (varExpr "id") [ strExpr "hello" ])

        modul =
            makeModule "testValue"
                (letExpr [ idFn ] body)
    in
    expectFn modul


{-| Applies `expectFn` to `( apply intId 1, apply strId "hi" )`, where
`apply f x = f x`, and `intId n = n` and `strId s = s` are unannotated
identity functions, each used once: `intId` with a number and `strId` with a
`String`.
-}
applyUsedWithDifferentFunctionTypes : (Src.Module -> Expectation) -> (() -> Expectation)
applyUsedWithDifferentFunctionTypes expectFn _ =
    let
        applyFn =
            define "apply"
                [ pVar "f", pVar "x" ]
                (callExpr (varExpr "f") [ varExpr "x" ])

        intIdFn =
            define "intId" [ pVar "n" ] (varExpr "n")

        strIdFn =
            define "strId" [ pVar "s" ] (varExpr "s")

        body =
            tupleExpr
                (callExpr (varExpr "apply") [ varExpr "intId", intExpr 1 ])
                (callExpr (varExpr "apply") [ varExpr "strId", strExpr "hi" ])

        modul =
            makeModule "testValue"
                (letExpr [ applyFn, intIdFn, strIdFn ] body)
    in
    expectFn modul


{-| Applies `expectFn` to `( twice id 1, twice id "hi" )`, where
`twice f x = f (f x)` and `id y = y`.
-}
higherOrderPreservingPolymorphism : (Src.Module -> Expectation) -> (() -> Expectation)
higherOrderPreservingPolymorphism expectFn _ =
    let
        twiceFn =
            define "twice"
                [ pVar "f", pVar "x" ]
                (callExpr (varExpr "f")
                    [ callExpr (varExpr "f") [ varExpr "x" ] ]
                )

        idFn =
            define "id" [ pVar "y" ] (varExpr "y")

        body =
            tupleExpr
                (callExpr (varExpr "twice") [ varExpr "id", intExpr 1 ])
                (callExpr (varExpr "twice") [ varExpr "id", strExpr "hi" ])

        modul =
            makeModule "testValue"
                (letExpr [ twiceFn, idFn ] body)
    in
    expectFn modul



-- ============================================================================
-- HIGHER-ORDER WITH PATTERNS
-- ============================================================================


{-| Lists the cases in which a function that takes a function also takes a
pattern argument.
-}
higherOrderWithPatternsCases : (Src.Module -> Expectation) -> List TestCase
higherOrderWithPatternsCases expectFn =
    [ { label = "Higher-order with tuple pattern", run = higherOrderWithTuplePattern expectFn }
    , { label = "Higher-order with record pattern", run = higherOrderWithRecordPattern expectFn }
    , { label = "Higher-order with list pattern", run = higherOrderWithListPattern expectFn }
    , { label = "Higher-order with alias pattern", run = higherOrderWithAliasPattern expectFn }
    ]


{-| Applies `expectFn` to `applyToPair (\x y -> ( x, y )) ( 1, 2 )`, where
`applyToPair f ( a, b ) = f a b`.
-}
higherOrderWithTuplePattern : (Src.Module -> Expectation) -> (() -> Expectation)
higherOrderWithTuplePattern expectFn _ =
    let
        applyToPair =
            define "applyToPair"
                [ pVar "f", pTuple (pVar "a") (pVar "b") ]
                (callExpr (varExpr "f") [ varExpr "a", varExpr "b" ])

        addFn =
            lambdaExpr [ pVar "x", pVar "y" ] (tupleExpr (varExpr "x") (varExpr "y"))

        modul =
            makeModule "testValue"
                (letExpr [ applyToPair ]
                    (callExpr (varExpr "applyToPair") [ addFn, tupleExpr (intExpr 1) (intExpr 2) ])
                )
    in
    expectFn modul


{-| Applies `expectFn` to `transformRecord (\x -> ( x, x )) { value = 21 }`,
where `transformRecord f { value } = { value = f value }`.
-}
higherOrderWithRecordPattern : (Src.Module -> Expectation) -> (() -> Expectation)
higherOrderWithRecordPattern expectFn _ =
    let
        transformRecord =
            define "transformRecord"
                [ pVar "f", pRecord [ "value" ] ]
                (recordExpr [ ( "value", callExpr (varExpr "f") [ varExpr "value" ] ) ])

        doubleFn =
            lambdaExpr [ pVar "x" ] (tupleExpr (varExpr "x") (varExpr "x"))

        modul =
            makeModule "testValue"
                (letExpr [ transformRecord ]
                    (callExpr (varExpr "transformRecord") [ doubleFn, recordExpr [ ( "value", intExpr 21 ) ] ])
                )
    in
    expectFn modul


{-| Applies `expectFn` to `mapHead (\x -> x) [ 1, 2 ]`, where
`mapHead f (h :: t) = [ f h ]`. The argument pattern does not match the empty
list.
-}
higherOrderWithListPattern : (Src.Module -> Expectation) -> (() -> Expectation)
higherOrderWithListPattern expectFn _ =
    let
        mapHead =
            define "mapHead"
                [ pVar "f", pCons (pVar "h") (pVar "t") ]
                (listExpr [ callExpr (varExpr "f") [ varExpr "h" ] ])

        fn =
            lambdaExpr [ pVar "x" ] (varExpr "x")

        modul =
            makeModule "testValue"
                (letExpr [ mapHead ]
                    (callExpr (varExpr "mapHead") [ fn, listExpr [ intExpr 1, intExpr 2 ] ])
                )
    in
    expectFn modul


{-| Applies `expectFn` to `withOriginal (\n -> n) 42`, where
`withOriginal f (x as original) = ( f x, original )`.
-}
higherOrderWithAliasPattern : (Src.Module -> Expectation) -> (() -> Expectation)
higherOrderWithAliasPattern expectFn _ =
    let
        withOriginal =
            define "withOriginal"
                [ pVar "f", pAlias (pVar "x") "original" ]
                (tupleExpr (callExpr (varExpr "f") [ varExpr "x" ]) (varExpr "original"))

        fn =
            lambdaExpr [ pVar "n" ] (varExpr "n")

        modul =
            makeModule "testValue"
                (letExpr [ withOriginal ]
                    (callExpr (varExpr "withOriginal") [ fn, intExpr 42 ])
                )
    in
    expectFn modul



-- ============================================================================
-- CASE RETURNING FUNCTION
-- ============================================================================


{-| Lists the typed cases in which the branches of a `case` return lambdas.
-}
caseReturningFunctionCases : (Src.Module -> Expectation) -> List TestCase
caseReturningFunctionCases expectFn =
    [ { label = "Case returns curried binary operator", run = caseReturnsCurriedBinaryOp expectFn }
    , { label = "Case returns curried ternary function", run = caseReturnsCurriedTernaryFn expectFn }
    , { label = "Case returns differently staged lambdas", run = caseReturnsDifferentlyStagedLambdas expectFn }
    ]


{-| Applies `expectFn` to a module in which a function whose `case` returns
lambdas is passed where a function of three arguments is expected:

    type Op
        = Add
        | Sub
        | Mul

    getOp : Op -> Int -> Int -> Int
    getOp op =
        case op of
            Add ->
                \a b -> a + b

            Sub ->
                \a b -> a - b

            Mul ->
                \a b -> a * b

    applyOp : (Op -> Int -> Int -> Int) -> Op -> Int -> Int -> Int
    applyOp f op a b =
        f op a b

    testValue : Int
    testValue =
        applyOp getOp Add 3 4

`getOp` takes one argument and the lambdas it returns take the other two, so
the call `f op a b` in `applyOp` is evaluated as a call of `getOp` with `op`
followed by a call of the lambda it returns with `a` and `b`.

-}
caseReturnsCurriedBinaryOp : (Src.Module -> Expectation) -> (() -> Expectation)
caseReturnsCurriedBinaryOp expectFn _ =
    let
        opUnion : UnionDef
        opUnion =
            { name = "Op"
            , args = []
            , ctors =
                [ { name = "Add", args = [] }
                , { name = "Sub", args = [] }
                , { name = "Mul", args = [] }
                ]
            }

        getOpFn : TypedDef
        getOpFn =
            { name = "getOp"
            , args = [ pVar "op" ]
            , tipe = tLambda (tType "Op" []) (tLambda (tType "Int" []) (tLambda (tType "Int" []) (tType "Int" [])))
            , body =
                caseExpr (varExpr "op")
                    [ ( pCtor "Add" []
                      , lambdaExpr [ pVar "a", pVar "b" ]
                            (binopsExpr [ ( varExpr "a", "+" ) ] (varExpr "b"))
                      )
                    , ( pCtor "Sub" []
                      , lambdaExpr [ pVar "a", pVar "b" ]
                            (binopsExpr [ ( varExpr "a", "-" ) ] (varExpr "b"))
                      )
                    , ( pCtor "Mul" []
                      , lambdaExpr [ pVar "a", pVar "b" ]
                            (binopsExpr [ ( varExpr "a", "*" ) ] (varExpr "b"))
                      )
                    ]
            }

        applyOpFn : TypedDef
        applyOpFn =
            { name = "applyOp"
            , args = [ pVar "f", pVar "op", pVar "a", pVar "b" ]
            , tipe =
                tLambda
                    (tLambda (tType "Op" []) (tLambda (tType "Int" []) (tLambda (tType "Int" []) (tType "Int" []))))
                    (tLambda (tType "Op" [])
                        (tLambda (tType "Int" [])
                            (tLambda (tType "Int" []) (tType "Int" []))
                        )
                    )
            , body =
                callExpr (varExpr "f")
                    [ varExpr "op", varExpr "a", varExpr "b" ]
            }

        testValueFn : TypedDef
        testValueFn =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body =
                callExpr (varExpr "applyOp")
                    [ varExpr "getOp", ctorExpr "Add", intExpr 3, intExpr 4 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test" [ getOpFn, applyOpFn, testValueFn ] [ opUnion ] []
    in
    expectFn modul


{-| Applies `expectFn` to a module like the one `caseReturnsCurriedBinaryOp`
builds, with a function of four arguments in place of three:

    type Mode
        = First
        | Second
        | Third

    choose : Mode -> Int -> Int -> Int -> Int
    choose mode =
        case mode of
            First ->
                \a b c -> a

            Second ->
                \a b c -> b

            Third ->
                \a b c -> c

    applyChoice : (Mode -> Int -> Int -> Int -> Int) -> Mode -> Int -> Int -> Int -> Int
    applyChoice f mode a b c =
        f mode a b c

    testValue : Int
    testValue =
        applyChoice choose First 10 20 30

`choose` takes one argument and the lambdas it returns take the other three.

-}
caseReturnsCurriedTernaryFn : (Src.Module -> Expectation) -> (() -> Expectation)
caseReturnsCurriedTernaryFn expectFn _ =
    let
        modeUnion : UnionDef
        modeUnion =
            { name = "Mode"
            , args = []
            , ctors =
                [ { name = "First", args = [] }
                , { name = "Second", args = [] }
                , { name = "Third", args = [] }
                ]
            }

        chooseFn : TypedDef
        chooseFn =
            { name = "choose"
            , args = [ pVar "mode" ]
            , tipe =
                tLambda (tType "Mode" [])
                    (tLambda (tType "Int" [])
                        (tLambda (tType "Int" [])
                            (tLambda (tType "Int" []) (tType "Int" []))
                        )
                    )
            , body =
                caseExpr (varExpr "mode")
                    [ ( pCtor "First" []
                      , lambdaExpr [ pVar "a", pVar "b", pVar "c" ] (varExpr "a")
                      )
                    , ( pCtor "Second" []
                      , lambdaExpr [ pVar "a", pVar "b", pVar "c" ] (varExpr "b")
                      )
                    , ( pCtor "Third" []
                      , lambdaExpr [ pVar "a", pVar "b", pVar "c" ] (varExpr "c")
                      )
                    ]
            }

        applyChoiceFn : TypedDef
        applyChoiceFn =
            { name = "applyChoice"
            , args = [ pVar "f", pVar "mode", pVar "a", pVar "b", pVar "c" ]
            , tipe =
                tLambda
                    (tLambda (tType "Mode" [])
                        (tLambda (tType "Int" [])
                            (tLambda (tType "Int" [])
                                (tLambda (tType "Int" []) (tType "Int" []))
                            )
                        )
                    )
                    (tLambda (tType "Mode" [])
                        (tLambda (tType "Int" [])
                            (tLambda (tType "Int" [])
                                (tLambda (tType "Int" []) (tType "Int" []))
                            )
                        )
                    )
            , body =
                callExpr (varExpr "f")
                    [ varExpr "mode", varExpr "a", varExpr "b", varExpr "c" ]
            }

        testValueFn : TypedDef
        testValueFn =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body =
                callExpr (varExpr "applyChoice")
                    [ varExpr "choose", ctorExpr "First", intExpr 10, intExpr 20, intExpr 30 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test" [ chooseFn, applyChoiceFn, testValueFn ] [ modeUnion ] []
    in
    expectFn modul


{-| Applies `expectFn` to a module in which the two branches of a `case` return
functions of the same type written with different nestings of lambdas:

    type Selector
        = UseFlat
        | UseNested

    selectFn : Selector -> Int -> Int -> Int -> Int
    selectFn sel a =
        case sel of
            UseFlat ->
                \b c -> a + b + c

            UseNested ->
                \b -> \c -> a + b + c

    testValue : Int
    testValue =
        selectFn UseFlat 1 2 3

Both branches have the type `Int -> Int -> Int`, but one is a lambda of two
parameters and the other a lambda of one parameter that returns another, so a
caller of the `case`'s result cannot tell from its type whether `b` and `c` are
taken in one call or in two. Each `a + b + c` is built with the chain `a + b` as its first operand,
not as the flat chain the parser would give.

-}
caseReturnsDifferentlyStagedLambdas : (Src.Module -> Expectation) -> (() -> Expectation)
caseReturnsDifferentlyStagedLambdas expectFn _ =
    let
        selectorUnion : UnionDef
        selectorUnion =
            { name = "Selector"
            , args = []
            , ctors =
                [ { name = "UseFlat", args = [] }
                , { name = "UseNested", args = [] }
                ]
            }

        selectFn : TypedDef
        selectFn =
            { name = "selectFn"
            , args = [ pVar "sel", pVar "a" ]
            , tipe =
                tLambda (tType "Selector" [])
                    (tLambda (tType "Int" [])
                        (tLambda (tType "Int" [])
                            (tLambda (tType "Int" []) (tType "Int" []))
                        )
                    )
            , body =
                caseExpr (varExpr "sel")
                    [ ( pCtor "UseFlat" []
                      , lambdaExpr [ pVar "b", pVar "c" ]
                            (binopsExpr
                                [ ( binopsExpr [ ( varExpr "a", "+" ) ] (varExpr "b"), "+" ) ]
                                (varExpr "c")
                            )
                      )
                    , ( pCtor "UseNested" []
                      , lambdaExpr [ pVar "b" ]
                            (lambdaExpr [ pVar "c" ]
                                (binopsExpr
                                    [ ( binopsExpr [ ( varExpr "a", "+" ) ] (varExpr "b"), "+" ) ]
                                    (varExpr "c")
                                )
                            )
                      )
                    ]
            }

        testValueFn : TypedDef
        testValueFn =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body =
                callExpr (varExpr "selectFn")
                    [ ctorExpr "UseFlat", intExpr 1, intExpr 2, intExpr 3 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test" [ selectFn, testValueFn ] [ selectorUnion ] []
    in
    expectFn modul
