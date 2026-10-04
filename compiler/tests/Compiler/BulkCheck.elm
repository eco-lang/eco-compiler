module Compiler.BulkCheck exposing (TestCase, bulkCheck)

{-| Combines many labelled test cases into one expectation, so that a caller can
put them all in a single elm-test test while a failure still names the case that
caused it.

A case is a label and a deferred expectation (`TestCase`). `bulkCheck` runs the
cases in list order and stops at the first one that fails: the result is a
failure made of that case's label and the description of its failure, and the
cases after it are not run. A passing result therefore says every case passed,
but a failing one reports only the first failure.

A case that crashes, rather than failing, ends the whole test, and its label is
not reported.

-}

import Expect exposing (Expectation)
import Test.Runner


{-| One test case: a name for it, and the check to run.

`label` is what a failure is reported under. `run` is deferred behind `()` so
that a case's check does not run until `bulkCheck` reaches it, and does not run
at all if an earlier case fails.

-}
type alias TestCase =
    { label : String
    , run : () -> Expectation
    }


{-| Returns an expectation that passes when every one of `cases` passes, and an
empty list passes.

Cases run in order, and the first failure ends the run. The failure reported is
`label: description`, where `description` is the description elm-test gives that
case's failure; any other detail of the failure is not carried over.

-}
bulkCheck : List TestCase -> Expectation
bulkCheck cases =
    case cases of
        [] ->
            Expect.pass

        { label, run } :: rest ->
            case Test.Runner.getFailureReason (run ()) of
                Nothing ->
                    bulkCheck rest

                Just failure ->
                    Expect.fail (label ++ ": " ++ failure.description)
