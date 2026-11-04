module SourceIR.AccessorPlaceholderCases exposing (expectSuite)

{-| A program that passes a record accessor of a function field as a value, in
tail calls and in ordinary calls (finding F8, fixed). The accessor's field is a
function, so monomorphization defers it as a placeholder
(`Compiler.Monomorphize.ResolveAccessorValues.accessorTypeNeedsDefer`), which
`ResolveAccessorValues` must replace by a closure, using the type of the
parameter the tail call passes it to. Before F8 was fixed, tail-call arguments
were rewritten with no expected type, the placeholder survived, and MLIR
generation crashed on it ("MonoAccessorValue .f should have been eliminated by
ResolveAccessorValues"). It comes from the former unit test
`Compiler.Monomorphize.AccessorPlaceholderCoverageTest`, which only compiled it
to MLIR, as several catalogue logics do.

This module asserts nothing itself. `expectSuite` hands each program to the
caller's expectation, which decides what the program is run through and what
counts as passing.

The program is the source text of a module named `Test`, parsed as an
application module, with the default imports of modules that
`Compiler.Elm.Interface.Basic.testIfaces` lacks dropped. The case, by label:

  - "Accessor of a function field passed in tail calls": `loop` takes a
    function from `Ops = { f : Int -> Int }` and calls itself with the
    accessor `.f`. `loop` is also called with a lambda literal, so that the
    inliner loopifies the call and copies `loop`'s body, and `wrapper`, a
    small function the inliner inlines, holds a local tail-recursive function
    with the same kind of tail call, after a partial application bound by a
    `let` and used once in that tail call. `loop2` passes a function
    parameter unchanged and the accessor in another argument, so that a call
    of it with a lambda literal is loopified.

-}

import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Compiler.Core.Annotation as A
import Compiler.Elm.Interface.Basic as Basic
import Compiler.IR.Source as Src
import Compiler.Parse.Module as Parse
import Dict
import Expect exposing (Expectation)
import Test exposing (Test)


{-| Builds one test, named "Accessor placeholder programs " followed by `condStr`, that
passes `expectFn` each program in order through
`Compiler.BulkCheck.bulkCheck`, so the first failing program ends the test and
is the one reported.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Accessor placeholder programs " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


{-| Returns one case per program, each running `expectFn` on it.
-}
testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    List.map (\( label, text ) -> { label = label, run = \_ -> runSource expectFn text }) programs


{-| Runs `expectFn` on the module parsed from `text` as an application module,
with the imports of modules the mock interfaces lack dropped, or fails when
`text` does not parse.
-}
runSource : (Src.Module -> Expectation) -> String -> Expectation
runSource expectFn text =
    case Parse.fromByteString Parse.Application text of
        Ok (Src.Module m) ->
            expectFn (Src.Module { m | imports = List.filter isMockImport m.imports })

        Err _ ->
            Expect.fail ("fixture does not parse:\n" ++ text)


{-| Whether an import names one of the mock interfaces.
-}
isMockImport : Src.Import -> Bool
isMockImport (Src.Import ( _, A.At _ name ) _ _) =
    Dict.member name Basic.testIfaces


{-| The programs, by label, as source text.
-}
programs : List ( String, String )
programs =
    [ ( "Accessor of a function field passed in tail calls"
      , """module Test exposing (..)

type alias Ops =
    { f : Int -> Int }


loop : (Ops -> Int -> Int) -> Int -> Int
loop g n =
    if n <= 0 then
        g { f = \\x -> x + 1 } 1

    else
        loop .f (n - 1)


add3 : Int -> Int -> Int -> Int
add3 a b c =
    a + b + c


wrapper : Int -> Int
wrapper n =
    let
        z =
            n + 1

        inner g k =
            let
                p =
                    add3 k
            in
            if k <= 0 then
                g { f = \\x -> x * 2 } 1

            else
                inner .f (p 1 -2)
    in
    inner .f z


loop2 : (Int -> Int) -> (Ops -> Int -> Int) -> Int -> Int
loop2 k h n =
    if n <= 0 then
        k (h { f = \\x -> x } 1)

    else
        loop2 k .f (n - 1)


testValue : Int
testValue =
    loop .f 3 + loop (\\o x -> o.f x) 2 + wrapper 2 + loop2 (\\x -> x + 1) .f 2
"""
      )
    ]
