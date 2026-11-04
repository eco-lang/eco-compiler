module SourceIR.Suite.Rejection exposing
    ( Rejection, rejectedWith, rejectedWithFragment
    , RejectedCase, fromModule, fromSource, knownBug
    , expectSuiteOf, expectRejectedSuiteOf
    )

{-| The case format of the negative catalogue: programs the compiler must
reject, each with the rejection it must give.

A negative case module (`SourceIR.CanonicalizeFailsCases`,
`SourceIR.LimitFailsCases`, `SourceIR.TypeCheckFailsCases`,
`SourceIR.PatternFailsCases`, `SourceIR.MainFailsCases`,
`SourceIR.MonoFailsCases`) holds a list of `RejectedCase`s and exposes two
suites built from it here: `expectSuite`, which gives a check only each program,
as every case module does, and `expectRejectedSuite`, which also gives the
check the `Rejection` the case records. Which stage must reject a program is
not part of the case: it is the stage the case's module is named for, which
`SourceIR.Suite.RejectedSuites` passes on.

A `Rejection` is recorded as the user sees it: the title of the first report,
such as `TYPE MISMATCH`, and optionally a fragment of the rendered reports that
tells apart errors sharing a title, such as the name that clashes.

A case builds its program on demand (`fromModule`, with
`Compiler.AST.SourceBuilder`, or `fromSource`, from Elm source text), so that a
large generated program costs nothing until a check runs it. A case known to
expose a compiler bug carries the bug's id (`knownBug`); in
`expectRejectedSuiteOf` it is wrapped with `Compiler.BulkCheck.expectFailure`.


# Rejections

@docs Rejection, rejectedWith, rejectedWithFragment


# Cases

@docs RejectedCase, fromModule, fromSource, knownBug


# Suites

@docs expectSuiteOf, expectRejectedSuiteOf

-}

import Compiler.BulkCheck exposing (TestCase, bulkCheck, expectFailure)
import Compiler.Core.Annotation as A
import Compiler.Elm.Interface.Basic as Basic
import Compiler.IR.Source as Src
import Compiler.Parse.Module as Parse
import Dict
import Expect exposing (Expectation)
import Test exposing (Test)


{-| The rejection a program must get: `title`, the title of the first report,
and `fragment`, text that must appear in the rendered reports when it is given.
-}
type alias Rejection =
    { title : String
    , fragment : Maybe String
    }


{-| A rejection whose first report has the title `title`.
-}
rejectedWith : String -> Rejection
rejectedWith title =
    { title = title, fragment = Nothing }


{-| A rejection whose first report has the title `title`, with `fragment` in
the rendered reports.
-}
rejectedWithFragment : String -> String -> Rejection
rejectedWithFragment title fragment =
    { title = title, fragment = Just fragment }


{-| One case: its label, the program, built when a check runs it (or a message
saying why it could not be built), the rejection it must get, and the finding
it is a known failure for, if any.
-}
type alias RejectedCase =
    { label : String
    , program : () -> Result String Src.Module
    , rejection : Rejection
    , knownBug : Maybe String
    }


{-| A case whose program `build` makes.
-}
fromModule : String -> Rejection -> (() -> Src.Module) -> RejectedCase
fromModule label rejection build =
    { label = label
    , program = \() -> Ok (build ())
    , rejection = rejection
    , knownBug = Nothing
    }


{-| A case whose program is the Elm source text `source`, parsed as an
application module. When `source` does not start with its own `module` line,
the header `module Test exposing (..)` and a blank line are put before it.

The parser gives every application module Elm's default imports. Those of
modules the mock interfaces of `Compiler.Elm.Interface.Basic.testIfaces` lack
(`Debug`, `Result`, `Platform` and others) are dropped, as canonicalization
would otherwise fail on them; an import the source writes of such a module is
dropped too. The rows of the program's regions are those of the full source,
header included.

-}
fromSource : String -> Rejection -> String -> RejectedCase
fromSource label rejection source =
    { label = label
    , program = \() -> parseApplication source
    , rejection = rejection
    , knownBug = Nothing
    }


{-| `rejectedCase` marked as reproducing the finding `reason` (an id and a
short description), so that `expectRejectedSuiteOf` expects its check to fail.
-}
knownBug : String -> RejectedCase -> RejectedCase
knownBug reason rejectedCase =
    { rejectedCase | knownBug = Just reason }


{-| One test named `name`, running `expectFn` on the program of every case in
order under `Compiler.BulkCheck.bulkCheck`, so that it stops at the first that
fails and names it. A case whose program cannot be built fails.
-}
expectSuiteOf : String -> List RejectedCase -> (Src.Module -> Expectation) -> Test
expectSuiteOf name cases expectFn =
    Test.test name <|
        \() ->
            bulkCheck
                (List.map
                    (\c -> { label = c.label, run = \() -> withProgram c expectFn })
                    cases
                )


{-| `expectSuiteOf`, giving `expectFn` the case's `Rejection` as well. A case
with a `knownBug` is wrapped with `Compiler.BulkCheck.expectFailure`, so that
it passes while `expectFn` fails on it and fails once `expectFn` passes.
-}
expectRejectedSuiteOf : String -> List RejectedCase -> (Src.Module -> Rejection -> Expectation) -> Test
expectRejectedSuiteOf name cases expectFn =
    Test.test name <|
        \() ->
            bulkCheck (List.map (toRejectedTestCase expectFn) cases)


{-| The test case of `c` for `expectRejectedSuiteOf`.
-}
toRejectedTestCase : (Src.Module -> Rejection -> Expectation) -> RejectedCase -> TestCase
toRejectedTestCase expectFn c =
    let
        testCase =
            { label = c.label, run = \() -> withProgram c (\m -> expectFn m c.rejection) }
    in
    case c.knownBug of
        Just reason ->
            expectFailure reason testCase

        Nothing ->
            testCase


{-| Runs `expectFn` on the program of `c`, or fails saying why the program
could not be built.
-}
withProgram : RejectedCase -> (Src.Module -> Expectation) -> Expectation
withProgram c expectFn =
    case c.program () of
        Ok modul ->
            expectFn modul

        Err message ->
            Expect.fail message


{-| Parses `source` as `fromSource` describes.
-}
parseApplication : String -> Result String Src.Module
parseApplication source =
    let
        fullSource =
            if String.startsWith "module " source then
                source

            else
                "module Test exposing (..)\n\n" ++ source
    in
    case Parse.fromByteString Parse.Application fullSource of
        Ok (Src.Module m) ->
            Ok (Src.Module { m | imports = List.filter isMockImport m.imports })

        Err _ ->
            Err ("the program does not parse:\n" ++ fullSource)


{-| Whether an import names one of the mock interfaces.
-}
isMockImport : Src.Import -> Bool
isMockImport (Src.Import ( _, A.At _ name ) _ _) =
    Dict.member name Basic.testIfaces
