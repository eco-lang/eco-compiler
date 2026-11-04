module SourceIR.CovMonoAccessorCases exposing (expectSuite)

{-| Source programs written to reach the accessor rewrite of monomorphization
(`Compiler.Monomorphize.ResolveAccessorValues`) at expected types the rest of
the catalogue does not give it.

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

  - "accessor values at unusual expected types": Accessors of function-typed
    fields passed to higher-order functions: `.f` where a two-argument function
    of the record is expected (`call2`), `.g` of a record whose field is
    polymorphic (`pass`, at an unresolved element type), and records of
    accessors joined with a record whose field is a parameter.

All cases run inside one test through `Compiler.BulkCheck.bulkCheck`, which
stops at the first case that fails and reports its label.

-}

import Compiler.AST.SourceBuilder exposing (makeKernelModule, makePortModule, unitExpr)
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Compiler.IR.Source as Src
import Compiler.Parse.Module as M
import Expect exposing (Expectation)
import Test exposing (Test)


{-| Builds one test, named "Mono accessor coverage programs " followed by
`condStr`, that passes when `expectFn` passes on every case's program and
otherwise fails with the label of the first case whose program it fails on.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Mono accessor coverage programs " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


{-| Returns every case, each running `expectFn` on its parsed program.
-}
testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    List.map
        (\( label, source ) -> { label = label, run = \_ -> runSource expectFn source })
        [ ( "accessor values at unusual expected types", accessorExpectedShapes )
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



{-| Accessors of function-typed fields passed to higher-order functions: `.f` where
a two-argument function of the record is expected (`call2`), `.g` of a record
whose field is polymorphic (`pass`, at an unresolved element type), and records
of accessors joined with a record whose field is a parameter.
-}
accessorExpectedShapes : String
accessorExpectedShapes =
    """
module Test exposing (..)


type alias Ops =
    { f : Int -> Int, h : Int -> Int }


ops : Ops
ops =
    { f = \\x -> x + 1, h = \\x -> x * 2 }


call2 : (Ops -> Int -> Int) -> Int
call2 k =
    k ops 1


pass : ({ g : a -> a } -> (a -> a)) -> Int
pass _ =
    0


pick : Bool -> (Ops -> Int -> Int) -> Int
pick c other =
    let
        r =
            if c then
                { a = .f }

            else
                { a = other }
    in
    r.a ops 2


testValue : Int
testValue =
    call2 .f + pass .g + pick True .h + pick False .f
"""
