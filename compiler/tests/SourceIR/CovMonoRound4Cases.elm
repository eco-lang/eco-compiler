module SourceIR.CovMonoRound4Cases exposing (expectSuite)
{-| Source programs written to reach defensive paths of the solver
monomorphizer (`Compiler.Monomorphize.Solver.*`) and of the mono-level
optimizations (`Compiler.MonoOpt.GlobalOptimize`, `Compiler.MonoOpt.AbiCloning`)
that the rest of the catalogue leaves unreached.

These cases assert nothing themselves. Each one builds a program and hands it
to the expectation function the caller supplies, so what is checked, and at
which stage, is decided by that function.

Every program is written as Elm source text and parsed with
`Compiler.Parse.Module.fromByteString`; a text that does not parse fails its
case with the message "fixture failed to parse". Each is a module named
`Test` that defines `testValue`. Its imports are replaced by those of
`makeKernelModule`.

The cases, by label:

  - "over-application into a staged if-of-lambdas body": `pick` takes one
    parameter and returns, from an `if`, closures staged `\b c -> \d -> ...`;
    `let h = pick n 2 3` over-applies it, so the local's source arity is read
    from the later stages of the callee body.
  - "tail functions whose tail call folds away": `loopIf` and `loopCase` are
    tail-recursive only through a branch that a constant condition rules out,
    so after simplification the body may be a lambda; they are over-applied.
  - "locals bound to values defined by if and case": `cafIf` and `cafCase` are
    top-level `Int` values defined by an `if` and by a `case` on `cafIf`,
    bound to locals in `let`s, so the stage arities of a define that is no
    function are asked for.
  - "branches joining lambdas with kernel operators": `pickOp` returns, from a
    `case` and from an `if` chain, two-parameter lambdas, curried lambdas and
    the kernel-backed operators `(+)`, `(-)` and `max`, whose tests call the
    recursive `sumTo` so that eta expansion leaves them alone, so a branch
    with a known lambda set meets branches whose set is a variable; the
    results are applied directly and through a local.

All cases run inside one test through `Compiler.BulkCheck.bulkCheck`, which
stops at the first case that fails and reports its label. A case wrapped in
`expectFailure` reproduces a compiler bug listed in
`compiler/coverage/findings.csv`.

-}
import Compiler.AST.SourceBuilder exposing (makeKernelModule, unitExpr)
import Compiler.BulkCheck exposing (TestCase, bulkCheck, expectFailure)
import Compiler.IR.Source as Src
import Compiler.Parse.Module as M
import Expect exposing (Expectation)
import Test exposing (Test)


{-| Builds one test, named "Mono round-4 coverage programs " followed by
`condStr`, that passes when `expectFn` passes on every case's program and
otherwise fails with the label of the first case whose program it fails on.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Mono round-4 coverage programs " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


{-| Returns every case, each running `expectFn` on its parsed program.
-}
testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    [ { label = "over-application into a staged if-of-lambdas body", run = \_ -> runSource expectFn g01OverapplyStaged }
    , { label = "tail functions whose tail call folds away", run = \_ -> runSource expectFn g03TailFolded }
    , { label = "locals bound to values defined by if and case", run = \_ -> runSource expectFn g04LetboundCaf }
    , { label = "branches joining lambdas with kernel operators", run = \_ -> runSource expectFn t01PartialSets }
    ]


{-| Runs `expectFn` on the program `source` parses to, with its imports
replaced by those of `makeKernelModule`, or fails when it does not parse.
-}
runSource : (Src.Module -> Expectation) -> String -> Expectation
runSource expectFn source =
    case M.fromByteString M.Application source of
        Ok (Src.Module m) ->
            let
                (Src.Module template) =
                    makeKernelModule "unused" unitExpr
            in
            expectFn (Src.Module { m | imports = template.imports })

        Err _ ->
            Expect.fail "fixture failed to parse"


{-| `pick` takes one parameter and returns, from an `if`, closures staged `\b c ->
\d -> ...`; `let h = pick n 2 3` over-applies it, so the local's source arity
is read from the later stages of the callee body.
-}
g01OverapplyStaged : String
g01OverapplyStaged =
    """
module Test exposing (..)


pick : Int -> Int -> Int -> Int -> Int
pick a =
    if a > 0 then
        \\b c -> \\d -> a * 3 + b * 5 + c * 7 + d * 11 + a * b * c * d + (a + b) * (c + d) + (a - b) * (c - d)

    else
        \\b c -> \\d -> a * 13 - b * 17 - c * 19 - d * 23 + a * b - c * d + (a - b) * (c + d) - (a + b) * (c - d)


useIt : Int -> Int
useIt n =
    let
        h =
            pick n 2 3
    in
    h 4 + h 5


testValue : Int
testValue =
    useIt 1 + useIt -1 + pick 2 3 4 5
"""


{-| `loopIf` and `loopCase` are tail-recursive only through a branch that a
constant condition rules out, so after simplification the body may be a
lambda; they are over-applied.
-}
g03TailFolded : String
g03TailFolded =
    """
module Test exposing (..)


loopIf : Int -> Int -> Int
loopIf n =
    if False then
        loopIf (n - 1)

    else
        \\x -> x + n


loopCase : Int -> Int -> Int
loopCase n =
    case True of
        True ->
            \\x -> x * n

        False ->
            loopCase (n + 1)


testValue : Int
testValue =
    loopIf 3 4 + loopCase 5 6 + (let g = loopIf 1 in g 2)
"""


{-| `cafIf` and `cafCase` are top-level `Int` values defined by an `if` and by a
`case` on `cafIf`, bound to locals in `let`s, so the stage arities of a define
that is no function are asked for.
-}
g04LetboundCaf : String
g04LetboundCaf =
    """
module Test exposing (..)


sumTo : Int -> Int
sumTo n =
    if n <= 0 then
        0

    else
        n + sumTo (n - 1)


cafIf : Int
cafIf =
    if sumTo 10 > 20 then
        sumTo 3 * 7 + sumTo 4

    else
        sumTo 5 - sumTo 6 * 11


cafCase : Int
cafCase =
    case cafIf of
        3 ->
            sumTo 7 + sumTo 8 * 13

        _ ->
            sumTo 9 - sumTo 1 * 17


useBoth : Int -> Int
useBoth k =
    let
        a =
            cafIf

        b =
            cafCase
    in
    a * k + b * a + b * k + a * b * k


testValue : Int
testValue =
    useBoth 1 + useBoth 2
"""


{-| `pickOp` returns, from a `case` and from an `if` chain, two-parameter lambdas,
curried lambdas and the kernel-backed operators `(+)`, `(-)` and `max`, whose
tests call the recursive `sumTo` so that eta expansion leaves them alone, so a
branch with a known lambda set meets branches whose set is a variable; the
results are applied directly and through a local.
-}
t01PartialSets : String
t01PartialSets =
    """
module Test exposing (..)


sumTo : Int -> Int
sumTo n =
    if n <= 0 then
        0

    else
        n + sumTo (n - 1)


pickOp : Int -> (Int -> Int -> Int)
pickOp n =
    case sumTo n of
        0 ->
            \\a b -> a * b + n

        1 ->
            (+)

        2 ->
            (-)

        6 ->
            \\a -> \\b -> a - b * n

        _ ->
            max


pickIf : Int -> Int -> Int -> Int
pickIf n =
    if sumTo n > 3 then
        (+)

    else if sumTo n > 2 then
        \\a b -> a * b - n

    else if sumTo n > 1 then
        min

    else
        (-)


testValue : Int
testValue =
    let
        g =
            pickOp 3

        h =
            pickIf 2
    in
    pickOp 0 1 2 + pickOp 1 3 4 + g 5 6 + h 7 8 + pickIf 4 1 2 + List.foldl (pickOp 2) 0 [ 1, 2 ]
"""
