module SourceIR.LocalMultiEnrichCases exposing (expectSuite)

{-| Programs whose let-bound functions are nested in the shapes the solver
engine's deferred use enrichment (`flushLocalMultiEnrich` in
`Compiler.Monomorphize.Solver.Translate`) has to get right in a single walk of
the outermost body: chains of let-functions, one inside another's right-hand
side, sibling scopes reusing a name, an alias of a let-function, a
tail-recursive local function, and a lambda capturing a let-function. They come
from the former inline programs of
`Compiler.Monomorphize.Solver.LssLocalMultiEnrichTest`, whose check, that each
use of a let-bound name carries its definition's lambda-set annotations, now
runs over the whole catalogue as
`TestLogic.Monomorphize.LocalUseEnrichmentTest`; that unit test now only pins
that each program here has a use whose definition has a lambda set to copy.

This module asserts nothing itself. `expectSuite` hands each program to the
caller's expectation, which decides what the program is run through and what
counts as passing.

Each program is a module named `Test`, built with
`Compiler.AST.SourceBuilder.makeModule`, whose `testValue` is the expression
shown in its docstring. The cases, by label:

  - "nested chain of let-functions": three let-functions, each in the body of
    the one before and calling it, with the innermost used at two types and
    the outermost also used directly.
  - "let-function inside another's RHS": a let-function defined inside
    another's right-hand side rather than its body, with the outer one used at
    two types.
  - "sibling scopes reusing a name": two `case` branches that each bind `f`,
    one to a function used at two types and the other to a number.
  - "alias whose RHS is a bare use": a `let` whose right-hand side is a bare
    use of an enclosing let-function, with both names used.
  - "tail-recursive local with a nested let-function": a local function that
    calls itself in tail position, with a let-function used at two types in
    its body.
  - "lambda capturing a let-function": a let-function used at two types
    inside a lambda passed to `List.map`.
  - "five-deep chain used on several levels": a chain of five let-functions,
    with `e`, `c` and `a` used in the innermost body.

-}

import Compiler.AST.SourceBuilder
    exposing
        ( binopsExpr
        , boolExpr
        , callExpr
        , caseExpr
        , define
        , ifExpr
        , intExpr
        , lambdaExpr
        , letExpr
        , listExpr
        , makeModule
        , pCtor
        , pVar
        , qualVarExpr
        , tupleExpr
        , varExpr
        )
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Compiler.IR.Source as Src
import Expect exposing (Expectation)
import Test exposing (Test)


{-| Builds one test, named "Local let-function enrichment programs " followed
by `condStr`, that passes `expectFn` each program in order through
`Compiler.BulkCheck.bulkCheck`, so the first failing program ends the test and
is the one reported.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Local let-function enrichment programs " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


{-| Returns one case per program, each running `expectFn` on it.
-}
testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    List.map (\( label, modul ) -> { label = label, run = \_ -> expectFn modul })
        [ ( "nested chain of let-functions", nestedChain )
        , ( "let-function inside another's RHS", rhsNested )
        , ( "sibling scopes reusing a name", siblings )
        , ( "alias whose RHS is a bare use", aliasUse )
        , ( "tail-recursive local with a nested let-function", tailNested )
        , ( "lambda capturing a let-function", inLambda )
        , ( "five-deep chain used on several levels", deepChain )
        ]


{-| Builds a let definition of a function `name` with one parameter, the
variable `param`.
-}
fn : String -> String -> Src.Expr -> Src.Def
fn name param body =
    define name [ pVar param ] body


{-| Builds a call of the unqualified name `f` with the single argument `arg`.
-}
call1 : String -> Src.Expr -> Src.Expr
call1 f arg =
    callExpr (varExpr f) [ arg ]


{-| A module whose `testValue` is a chain of three let-functions, the
innermost used at an integer literal and at `Bool` and the outermost at a
list:

    let
        a x =
            x
    in
    let
        b y =
            a y
    in
    let
        c z =
            b z
    in
    ( c 1, ( c True, a [ 2 ] ) )

-}
nestedChain : Src.Module
nestedChain =
    makeModule "testValue"
        (letExpr [ fn "a" "x" (varExpr "x") ]
            (letExpr [ fn "b" "y" (call1 "a" (varExpr "y")) ]
                (letExpr [ fn "c" "z" (call1 "b" (varExpr "z")) ]
                    (tupleExpr (call1 "c" (intExpr 1))
                        (tupleExpr (call1 "c" (boolExpr True)) (call1 "a" (listExpr [ intExpr 2 ])))
                    )
                )
            )
        )


{-| A module whose `testValue` has a let-function, `pick`, inside the right-hand
side of another, `wrap`. `wrap` is used at an integer literal and at `Bool`, and
`pick` at `wrap`'s argument and at `Bool`:

    let
        wrap v =
            let
                pick p =
                    p
            in
            ( pick v, pick True )
    in
    ( wrap 1, wrap False )

-}
rhsNested : Src.Module
rhsNested =
    makeModule "testValue"
        (letExpr
            [ fn "wrap"
                "v"
                (letExpr [ fn "pick" "p" (varExpr "p") ]
                    (tupleExpr (call1 "pick" (varExpr "v")) (call1 "pick" (boolExpr True)))
                )
            ]
            (tupleExpr (call1 "wrap" (intExpr 1)) (call1 "wrap" (boolExpr False)))
        )


{-| A module whose `testValue` binds `f` in two `case` branches, to a function
used at an integer literal and at `Bool` in one and to a number in the other:

    case True of
        True ->
            let
                f x =
                    x
            in
            f 1
                + (if f True then
                    1

                   else
                    0
                  )

        False ->
            let
                f =
                    2
            in
            f + f

-}
siblings : Src.Module
siblings =
    makeModule "testValue"
        (caseExpr (boolExpr True)
            [ ( pCtor "True" []
              , letExpr [ fn "f" "x" (varExpr "x") ]
                    (binopsExpr [ ( call1 "f" (intExpr 1), "+" ) ]
                        (ifExpr (call1 "f" (boolExpr True)) (intExpr 1) (intExpr 0))
                    )
              )
            , ( pCtor "False" []
              , letExpr [ define "f" [] (intExpr 2) ]
                    (binopsExpr [ ( varExpr "f", "+" ) ] (varExpr "f"))
              )
            ]
        )


{-| A module whose `testValue` has a let, `same`, whose right-hand side is a
bare use of the enclosing let-function `base`:

    let
        base x =
            x
    in
    let
        same =
            base
    in
    ( same 1, ( same True, base [ 2 ] ) )

`base` is also used directly, at a list, so the case has a checked use of
`base` itself and not only of `same`.

-}
aliasUse : Src.Module
aliasUse =
    makeModule "testValue"
        (letExpr [ fn "base" "x" (varExpr "x") ]
            (letExpr [ define "same" [] (varExpr "base") ]
                (tupleExpr (call1 "same" (intExpr 1))
                    (tupleExpr (call1 "same" (boolExpr True)) (call1 "base" (listExpr [ intExpr 2 ])))
                )
            )
        )


{-| A module whose `testValue` has a local function `go` that calls itself
in tail position, with a let-function `step` used at `go`'s number argument
and at `Bool` in its body:

    let
        go acc i =
            if i <= 0 then
                acc

            else
                let
                    step k =
                        k
                in
                go (acc + step i)
                    (if step True then
                        i - 1

                     else
                        0
                    )
    in
    go 0 3

-}
tailNested : Src.Module
tailNested =
    makeModule "testValue"
        (letExpr
            [ define "go"
                [ pVar "acc", pVar "i" ]
                (ifExpr (binopsExpr [ ( varExpr "i", "<=" ) ] (intExpr 0))
                    (varExpr "acc")
                    (letExpr [ fn "step" "k" (varExpr "k") ]
                        (callExpr (varExpr "go")
                            [ binopsExpr [ ( varExpr "acc", "+" ) ] (call1 "step" (varExpr "i"))
                            , ifExpr (call1 "step" (boolExpr True)) (binopsExpr [ ( varExpr "i", "-" ) ] (intExpr 1)) (intExpr 0)
                            ]
                        )
                    )
                )
            ]
            (callExpr (varExpr "go") [ intExpr 0, intExpr 3 ])
        )


{-| A module whose `testValue` uses a let-function at an integer and at
`Bool` inside a lambda passed to `List.map`:

    let
        show v =
            v
    in
    List.map (\x -> ( show x, show True )) [ 1, 2 ]

-}
inLambda : Src.Module
inLambda =
    makeModule "testValue"
        (letExpr [ fn "show" "v" (varExpr "v") ]
            (callExpr (qualVarExpr "List" "map")
                [ lambdaExpr [ pVar "x" ] (tupleExpr (call1 "show" (varExpr "x")) (call1 "show" (boolExpr True)))
                , listExpr [ intExpr 1, intExpr 2 ]
                ]
            )
        )


{-| A module whose `testValue` is a chain of five let-functions, each calling
the one before, with `e` used at an integer literal and at `Bool`, `c` at
`Bool` and `a` at an integer literal:

    let
        a x =
            x
    in
    let
        b x =
            a x
    in
    let
        c x =
            b x
    in
    let
        d x =
            c x
    in
    let
        e x =
            d x
    in
    ( e 1, ( e True, ( c False, a 3 ) ) )

-}
deepChain : Src.Module
deepChain =
    makeModule "testValue"
        (letExpr [ fn "a" "x" (varExpr "x") ]
            (letExpr [ fn "b" "x" (call1 "a" (varExpr "x")) ]
                (letExpr [ fn "c" "x" (call1 "b" (varExpr "x")) ]
                    (letExpr [ fn "d" "x" (call1 "c" (varExpr "x")) ]
                        (letExpr [ fn "e" "x" (call1 "d" (varExpr "x")) ]
                            (tupleExpr (call1 "e" (intExpr 1))
                                (tupleExpr (call1 "e" (boolExpr True))
                                    (tupleExpr (call1 "c" (boolExpr False)) (call1 "a" (intExpr 3)))
                                )
                            )
                        )
                    )
                )
            )
        )
