module SourceIR.CovMonoSettleCases exposing (expectSuite)

{-| Source programs written in the third round of the coverage loop to reach the
solver's lambda-set handling and η-expansion from the shapes of real
programs: function values made by every expression form and passed to one
higher-order function, and cycle values referred to from definitions that
η-expansion rewrites.

These cases assert nothing themselves. Each one builds a program and hands it
to the expectation function the caller supplies, so what is checked, and at
which stage, is decided by that function.

Every program is written as Elm source text and parsed with
`Compiler.Parse.Module.fromByteString`; a text that does not parse fails its
case with the message "fixture failed to parse". Each is a module named
`Test` that defines `testValue`. Its imports, including the default ones the
parser adds, are replaced by those of `makeKernelModule`: `Basics`, `Maybe`,
`List`, `Elm.JsArray as JsArray`, `String`, `Char`, `Bitwise`, `Tuple`,
`Bytes`, `Bytes.Encode` and `Bytes.Decode`, all exposing everything. A
`port module` gets those of `makePortModule` instead, which add `Array`,
`Json.Encode`, `Json.Decode`, `Platform.Cmd` and `Platform.Sub` to the
standard set.

The cases, by label:

  - "function values from every expression form": Function values produced by a
    call, an `if`, a `case`, a `let`, a lambda literal, a parameter and a
    record field, each passed to the higher-order `apply` and stored in a list,
    so that their classified types are demanded of `apply`'s specializations.
  - "cycle values referenced from definitions with a deficit": `step` and
    `stepCall`, annotated `Int -> Fn` with `Fn` an alias of `Int -> Int` and
    written with one parameter, are cycle members together with the
    zero-argument values `viaCall` and `viaOther`, which they refer to through
    `VarCycle`. `step`'s branches are bare references to those values, so its
    body is cheap and is expanded and minted; `stepCall` passes a call of one
    to `add`, which is not cheap.

All cases run inside one test through `Compiler.BulkCheck.bulkCheck`, which
stops at the first case that fails and reports its label.

-}

import Compiler.AST.SourceBuilder exposing (makeKernelModule, makePortModule, unitExpr)
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Compiler.IR.Source as Src
import Compiler.Parse.Module as M
import Expect exposing (Expectation)
import Test exposing (Test)


{-| Builds one test, named "Mono settle coverage programs " followed by
`condStr`, that passes when `expectFn` passes on every case's program and
otherwise fails with the label of the first case whose program it fails on.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Mono settle coverage programs " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


{-| Returns every case, each running `expectFn` on its parsed program.
-}
testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    List.map
        (\( label, source ) -> { label = label, run = \_ -> runSource expectFn source })
        [ ( "function values from every expression form", fnFromEachForm )
        , ( "cycle values referenced from definitions with a deficit", cycleValuesInDeficitBodies )
        ]


{-| Runs `expectFn` on the program `source` parses to, with its imports
replaced by those of `makeKernelModule`, or of `makePortModule` for a
`port module`, or fails when it does not parse.
-}
runSource : (Src.Module -> Expectation) -> String -> Expectation
runSource expectFn source =
    case M.fromByteString M.Application source of
        Ok (Src.Module m) ->
            let
                (Src.Module template) =
                    if String.startsWith "\nport module" source then
                        makePortModule "unused" [] unitExpr

                    else
                        makeKernelModule "unused" unitExpr
            in
            expectFn (Src.Module { m | imports = template.imports })

        Err _ ->
            Expect.fail "fixture failed to parse"



{-| Function values produced by a call, an `if`, a `case`, a `let`, a lambda
literal, a parameter and a record field, each passed to the higher-order
`apply` and stored in a list, so that their classified types are demanded of
`apply`'s specializations.
-}
fnFromEachForm : String
fnFromEachForm =
    """
module Test exposing (..)


apply : (Int -> Int) -> Int -> Int
apply f x =
    f x


makeAdder : Int -> (Int -> Int)
makeAdder n =
    \\x -> x + n


pass : (Int -> Int) -> Int -> Int
pass g y =
    apply g y


run : Int -> Int
run c =
    let
        viaLet =
            let
                h =
                    makeAdder 2
            in
            h

        rec =
            { fn = makeAdder 3 }

        all =
            [ makeAdder 1
            , if c > 0 then makeAdder 4 else negate
            , case c of
                0 ->
                    makeAdder 5

                _ ->
                    \\z -> z * 2
            , viaLet
            , rec.fn
            ]
    in
    apply (makeAdder 1) 2
        + apply (if c > 0 then makeAdder 4 else negate) 3
        + apply
            (case c of
                0 ->
                    makeAdder 5

                _ ->
                    \\z -> z * 2
            )
            4
        + apply viaLet 5
        + apply (\\w -> w - 1) 6
        + pass negate 7
        + apply rec.fn 8
        + List.foldl (\\f acc -> f acc) 0 all


testValue : Int
testValue =
    run 0 + run 1
"""


{-| `step` and `stepCall`, annotated `Int -> Fn` with `Fn` an alias of `Int -> Int`
and written with one parameter, are cycle members together with the
zero-argument values `viaCall` and `viaOther`, which they refer to through
`VarCycle`. `step`'s branches are bare references to those values, so its body
is cheap and is expanded and minted; `stepCall` passes a call of one to `add`,
which is not cheap.
-}
cycleValuesInDeficitBodies : String
cycleValuesInDeficitBodies =
    """
module Test exposing (..)


type alias Fn =
    Int -> Int


add : Int -> Int -> Int
add a b =
    a + b


viaCall : Fn
viaCall =
    add 1


viaOther : Fn
viaOther =
    stepCall 0


step : Int -> Fn
step k =
    case k of
        0 ->
            viaCall

        _ ->
            viaOther


stepCall : Int -> Fn
stepCall k =
    case k of
        0 ->
            add k

        1 ->
            add (viaOther k)

        _ ->
            step (k - 1)


testValue : Int
testValue =
    step 0 1 + step 1 2
"""
