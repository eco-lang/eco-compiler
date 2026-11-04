module TestLogic.Canonicalize.SizeLimits exposing (expectSizeLimitsEnforced)

{-| The size-limit oracle: canonicalization rejects a program with a `TOO MANY
…` report exactly when the program, read directly, has a size over one of the
runtime's limits (HEAP\_019, HEAP\_078).

`TestLogic.Canonicalize.SourceFacts.sizeViolations` reads the sizes from the
program. `expectSizeLimitsEnforced` runs the program through canonicalization
(`TestLogic.TestPipeline.runToReportsThrough Canonicalize`, with the production
reporters) and compares:

  - when the program has a size over a limit, canonicalization must reject it,
    and one report must have the title of one such violation and contain the
    opening of its message (what is too large, by name, and its size; white
    space is compared collapsed, as the report wraps its lines);
  - otherwise, no report may have the title `TOO MANY PARAMETERS`, `TOO MANY
    CAPTURED VARIABLES` or `TOO MANY FIELDS`. The program may still be
    rejected for something else, as the negative catalogue's programs are.

-}

import Compiler.IR.Source as Src
import Expect exposing (Expectation)
import TestLogic.Canonicalize.SourceFacts as SourceFacts
import TestLogic.TestPipeline as Pipeline exposing (Outcome(..), Stage(..))


{-| Returns an expectation that canonicalization rejects `program` for its
sizes exactly as `SourceFacts.sizeViolations` predicts.
-}
expectSizeLimitsEnforced : Src.Module -> Expectation
expectSizeLimitsEnforced program =
    let
        violations =
            SourceFacts.sizeViolations program
    in
    case ( Pipeline.runToReportsThrough Canonicalize program, violations ) of
        ( Accepted, [] ) ->
            Expect.pass

        ( Accepted, _ ) ->
            Expect.fail ("canonicalization accepted a program with sizes over the limits: " ++ describe violations)

        ( Rejected reports, [] ) ->
            case List.filter (\t -> List.member t sizeTitles) reports.titles of
                [] ->
                    Expect.pass

                _ ->
                    Expect.fail ("a program with no size over a limit got a size-limit report:\n" ++ reports.text)

        ( Rejected reports, _ ) ->
            if
                List.any
                    (\v -> List.member v.title reports.titles && String.contains (collapse v.message) (collapse reports.text))
                    violations
            then
                Expect.pass

            else
                Expect.fail
                    ("expected a report for one of "
                        ++ describe violations
                        ++ ", but "
                        ++ Pipeline.stageName reports.stage
                        ++ " reported:\n"
                        ++ reports.text
                    )


{-| The titles of the size-limit reports.
-}
sizeTitles : List String
sizeTitles =
    [ "TOO MANY PARAMETERS", "TOO MANY CAPTURED VARIABLES", "TOO MANY FIELDS" ]


describe : List SourceFacts.SizeViolation -> String
describe violations =
    String.join "; " (List.map (\v -> v.title ++ " (" ++ v.message ++ ")") violations)


collapse : String -> String
collapse =
    String.words >> String.join " "
