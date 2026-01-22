module Compiler.BulkCheck exposing (TestCase, bulkCheck)

{-| Bulk test checking module for running multiple test cases as a single test.
This reduces test node count by ~96% while preserving failure information.
-}

import Expect exposing (Expectation)
import Test.Runner


{-| A single test case with a label and a function to run.
-}
type alias TestCase =
    { label : String
    , run : () -> Expectation
    }


{-| Run multiple test cases as a single bulk test.
Fails on first failure, reporting the label of the failing case.
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
