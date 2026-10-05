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
import Test.Runner.Failure as Failure


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
case's failure, followed by the compared values when the failure carries them
(see `reasonDetail`). For `Expect.fail` the description is the message itself.

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
                    Expect.fail (label ++ ": " ++ failure.description ++ reasonDetail failure.reason)


{-| Returns the values a failure compared, as text to append to its description,
or `""` when its reason carries none.

A comparison expectation such as `Expect.equal` describes itself only by its
own name (`"Expect.equal"`) and keeps the values it compared in the reason, so
without this a failure would be reported with no values.

-}
reasonDetail : Failure.Reason -> String
reasonDetail reason =
    case reason of
        Failure.Custom ->
            ""

        Failure.Equality expected actual ->
            "\n    expected: " ++ expected ++ "\n    actual:   " ++ actual

        Failure.Comparison first second ->
            "\n    first:  " ++ first ++ "\n    second: " ++ second

        Failure.ListDiff expected actual ->
            "\n    expected: [" ++ String.join ", " expected ++ "]\n    actual:   [" ++ String.join ", " actual ++ "]"

        Failure.CollectionDiff diff ->
            "\n    expected: "
                ++ diff.expected
                ++ "\n    actual:   "
                ++ diff.actual
                ++ "\n    extra:    ["
                ++ String.join ", " diff.extra
                ++ "]\n    missing:  ["
                ++ String.join ", " diff.missing
                ++ "]"

        Failure.TODO ->
            ""

        Failure.Invalid _ ->
            ""
